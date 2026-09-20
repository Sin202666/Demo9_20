--[[
	Module: SystemSave
	Description: 玩家会话存档读写、结构补全与 DataStore 持久化
	Author: 林奥宇
	Created: 2026-06-30
	Last Modified: 2026-08-31

	功能：
	- 加载 / 保存玩家会话数据
	- 按 SaveMetaData 补全缺失字段（结构补全；版本迁移见 FixData.luau）
	- 同步 PLAYER_VALUE_LIST 到 Player 下的 Value 实例
	- 自动保存与离站强制保存
	- 双会话互斥：仅当 IsInServer~=1，或 LastSaveTime 超过阈值未刷新时接档；版本号不参与放行
	- 接档成功并完成补全/迁移后立即 Set，把锁写进 Store
	- ChangeStat：顶层键须在 PLAYER_META_DATA；table 深拷贝后写入；拒绝不可序列化值

	调用关系：
	- PlayerManager 在玩家加入时调用 InitialPlayerData，离开时调用 PlayerLeaveSave
	- UpdateManager 启动前调用 Init 注册自动保存定时任务
	- 全局特殊数值见 SystemGlobalData；服务器 BUFF 见 SystemServerBuff
	- 持久化读写经 SystemDataStore 统一网关
	- 其他 System 通过 PlayerData.ChangePlrData / SystemSave.ChangeStat 修改持久化数据

	示例：
	local SystemSave = Utils.SystemSave
	local ok, isNew = SystemSave.InitialPlayerData(player)
	local changed, err = SystemSave.ChangeStat(player, "Bag", bagData)
	local snapshot = SystemSave.GetStat(player)
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Log = Utils.Log
local Players = Utils.Players
local Copy = Utils.Copy
local SystemGameConfig = Utils.SystemGameConfig
local UpdateModule = Utils.UpdateModule
local SystemDataStore = Utils.SystemDataStore

local SaveMetaData = require(script.SaveMetaData)
local FixData = require(script.FixData)
local PLAYER_META_DATA = SaveMetaData.PLAYER_META_DATA
local PLAYER_VALUE_LIST = SaveMetaData.PLAYER_VALUE_LIST
local STAT_KEY = SaveMetaData.STAT_KEY

local PLAYER_STORE = SystemDataStore.STORE.Player

-- ========================================
-- 模块定义
-- ========================================
local SystemSave = {}

-- ========================================
-- 常量定义
-- ========================================
local SAVE_MAX_TRIES = 3
local SAVE_RETRY_INTERVAL_SEC = 2
local LOAD_MAX_TRIES = 1
local STALE_SESSION_THRESHOLD_SEC = 60
local SESSION_RELOAD_WAIT_SEC = 6
local SESSION_RELOAD_MAX_TRIES = 5
local SESSION_CACHE_TTL_SEC = 10
local MAX_SERIALIZE_DEPTH = 4

local ERROR_INVALID_PLAYER = "INVALID_PLAYER"
local ERROR_NO_SESSION_DATA = "NO_SESSION_DATA"
local ERROR_UNKNOWN_STAT_KEY = "UNKNOWN_STAT_KEY"
local ERROR_INVALID_STAT_PATH = "INVALID_STAT_PATH"
local ERROR_UNSERIALIZABLE_VALUE = "UNSERIALIZABLE_VALUE"

local KICK_MSG_LOAD_FAILED = "Can't load your game data ,please login again!"

local SAVE_STORE_OPTIONS = {
	maxTries = SAVE_MAX_TRIES,
	retryIntervalSec = SAVE_RETRY_INTERVAL_SEC,
}

local LOAD_STORE_OPTIONS = {
	maxTries = LOAD_MAX_TRIES,
	retryIntervalSec = 0,
}

local SERIALIZABLE_PRIMITIVE = {
	string = true,
	number = true,
	boolean = true,
}

-- ========================================
-- 私有变量
-- ========================================
local _versionID: string = SystemGameConfig.GetValue("版本号")
local _sessionData: { [string]: any } = {}
local _initialized = false

-- ========================================
-- 私有函数
-- ========================================

--[[
	延迟获取 PlayerData，避免与 PlayerData 顶层引用 SystemSave 形成循环依赖

	@return table - PlayerData 模块表
]]
local function _getPlayerData()
	return Utils.PlayerData
end

--[[
	生成玩家会话键，与 DataStore 键名保持一致

	@param plr Player - 玩家对象
	@return string - 格式 "Player{UserId}"
]]
local function _getPlayerId(plr: Player): string
	return SystemDataStore.BuildPlayerKey(plr.UserId)
end

--[[
	在 Player 下创建 PLAYER_VALUE_LIST 配置的 Value 实例并写入初始值
	仅在 InitialPlayerData 加载完成后调用一次

	@param plr Player - 玩家对象
	@return nil
]]
local function _setPlayerValueInstance(plr: Player)
	local playerId = _getPlayerId(plr)
	local playerStat = _sessionData[playerId]
	if not playerStat then
		return
	end

	for _, valueConfig in pairs(PLAYER_VALUE_LIST) do
		local value = Instance.new(valueConfig[2], plr)
		value.Name = valueConfig[1]
		local statValue = playerStat[valueConfig[1]]
		if statValue ~= nil then
			value.Value = statValue
		end
	end
end

--[[
	按 SaveMetaData 补全玩家存档中缺失的字段（结构补全，非版本迁移）
	版本迁移逻辑见 FixData.luau，禁止在此函数内编写

	@param plr Player - 玩家对象
	@return nil
]]
local function _repairPlayerStat(plr: Player)
	local playerId = _getPlayerId(plr)
	local playerStat = _sessionData[playerId]
	if not playerStat then
		return
	end

	for key, defaultValue in pairs(PLAYER_META_DATA) do
		if playerStat[tostring(key)] == nil then
			if typeof(defaultValue) == "table" then
				playerStat[tostring(key)] = Copy.deepCopy(defaultValue)
			else
				playerStat[tostring(key)] = defaultValue
			end
		end
	end
end

--[[
	将 _sessionData 中的数值同步到 Player 下已存在的 Value 实例
	ChangeStat 修改数据后调用，保持 Instance 与会话表一致

	@param plr Player - 玩家对象
	@return nil
]]
local function _changePlayerValue(plr: Player)
	local playerId = _getPlayerId(plr)
	local playerStat = _sessionData[playerId]
	if not playerStat then
		return
	end

	for _, valueConfig in pairs(PLAYER_VALUE_LIST) do
		local valueIns = plr:FindFirstChild(valueConfig[1])
		if valueIns and valueIns.ClassName ~= "Folder" then
			local statValue = playerStat[valueConfig[1]]
			if statValue ~= nil then
				valueIns.Value = statValue
			end
		end
	end
end

--[[
	将当前游戏版本号写入存档表，供 FixData / 排查使用
	空或非 string 的版本号不覆盖已有值，避免把互斥无关字段写成无效空串

	@param data table - 会话存档表，可原地修改 LAST_VERSION
	@return nil
]]
local function _writeLastVersion(data: any)
	if type(data) ~= "table" then
		return
	end
	if type(_versionID) == "string" and _versionID ~= "" then
		data[STAT_KEY.LAST_VERSION] = _versionID
	end
end

--[[
	将会话标记为在线并写入内存缓存
	同时回写 LAST_VERSION；该字段不作为双会话放行条件

	@param playerId string - 会话键，格式 "Player{UserId}"
	@param data table - 从 DataStore 加载的存档表（会被原地修改 IsInServer、LAST_VERSION）
	@return nil
]]
local function _setSessionData(playerId: string, data: any)
	data[STAT_KEY.IsInServer] = 1
	_writeLastVersion(data)
	_sessionData[playerId] = data
end

--[[
	从 DataStore 读取指定玩家的原始存档

	@param playerId string - 会话键，格式 "Player{UserId}"
	@return boolean, any? - 读取成功返回 true 与数据（无存档时为 nil）；失败返回 false 与错误信息
]]
local function _loadSessionFromStore(playerId: string): (boolean, any?)
	local ok, data, err = SystemDataStore.Get(PLAYER_STORE, playerId, LOAD_STORE_OPTIONS)
	if not ok then
		return false, err
	end
	return true, data
end

--[[
	判断从 DataStore 拉取的存档是否可接受为当前会话
	互斥只看心跳：上一会话仍标记在线且 LastSaveTime 未超过阈值时拒绝，触发等待重试
	超时视为旧会话已死，回收僵尸锁。LAST_VERSION / 游戏版本号不参与本判断

	@param playerId string - 会话键
	@param data table - DataStore 返回的存档表
	@return boolean - 可接受并写入 _sessionData 时返回 true；需等待重试时返回 false
]]
local function _tryAcceptSessionData(playerId: string, data: any): boolean
	local isInServer = data[STAT_KEY.IsInServer]
	local lastSaveTime = data[STAT_KEY.LastSaveTime]

	if isInServer and isInServer == 1 then
		local nowTime = os.time()
		if lastSaveTime and (nowTime - lastSaveTime) > STALE_SESSION_THRESHOLD_SEC then
			_setSessionData(playerId, data)
			return true
		end

		return false
	end

	_setSessionData(playerId, data)
	return true
end

--[[
	将会话数据写入 DataStore，失败时按 SAVE_MAX_TRIES 重试

	@param plrId string - 会话键，格式 "Player{UserId}"
	@param isLeave boolean? - 为 true 时将 IsInServer 置 0，表示正常离站
	@return boolean - 保存成功返回 true；重试耗尽返回 false
]]
local function _savePlayerStat(plrId: string, isLeave: boolean?): boolean
	local data = _sessionData[plrId]
	if not data then
		Log.warn("SaveData skipped, no session:", plrId)
		return false
	end

	if isLeave == true then
		data[STAT_KEY.IsInServer] = 0
	end
	data[STAT_KEY.LastSaveTime] = os.time()
	_writeLastVersion(data)

	local ok, err = SystemDataStore.Set(PLAYER_STORE, plrId, data, SAVE_STORE_OPTIONS)
	if ok then
		Log.print("SaveData Suc:" .. plrId)
		return true
	end

	Log.warn("SaveData failed:", plrId, err)
	return false
end

--[[
	加载或恢复玩家会话数据，执行结构补全、版本迁移后立即持久化锁
	新玩家写入 PLAYER_META_DATA 默认值；加载失败或会话冲突重试耗尽时踢出玩家

	@param plr Player - 玩家对象
	@return boolean? - 是否新玩家；加载失败并已 Kick 时返回 nil
]]
local function _setPlayerStat(plr: Player): boolean?
	local playerId = _getPlayerId(plr)
	local isNewPlayer = false

	if _sessionData[playerId] == nil then
		local sessionReloadTries = 0

		while true do
			local success, data = _loadSessionFromStore(playerId)
			if not success then
				Log.warn("无法加载玩家数据:", playerId, data)
				plr:Kick(KICK_MSG_LOAD_FAILED)
				return nil
			end

			if data then
				if _tryAcceptSessionData(playerId, data) then
					break
				end

				sessionReloadTries += 1
				if sessionReloadTries >= SESSION_RELOAD_MAX_TRIES then
					Log.warn("会话冲突重试耗尽:", playerId)
					plr:Kick(KICK_MSG_LOAD_FAILED)
					return nil
				end

				task.wait(SESSION_RELOAD_WAIT_SEC)
			else
				_setSessionData(playerId, SaveMetaData.GetDefaultPlayerMeta())
				isNewPlayer = true
				break
			end
		end
	else
		_setSessionData(playerId, _sessionData[playerId])
	end

	_repairPlayerStat(plr)
	FixData.Run(plr, _sessionData[playerId])
	_savePlayerStat(playerId)
	return isNewPlayer
end

--[[
	玩家离开时的保存与内存清理：强制同步存档，延迟清除 _sessionData 缓存
	延迟 SESSION_CACHE_TTL_SEC 秒后再清理，避免同 UserId 快速重连时重复拉取

	@param plr Player - 离开服务器的玩家对象
	@return nil
]]
local function _saveOnRemoving(plr: Player)
	local key = _getPlayerId(plr)
	_savePlayerStat(key, true)

	local delUserID = plr.UserId
	task.delay(SESSION_CACHE_TTL_SEC, function()
		for _, player: Player in ipairs(Players:GetPlayers()) do
			if player.UserId == delUserID then
				return
			end
		end
		_sessionData[key] = nil
	end)
end

--[[
	判断值是否可写入 DataStore（string / number / boolean / 嵌套表；nil 表示删除）

	@param value any - 待写入值
	@param depth number - 当前嵌套深度，0 为写入根值
	@param seen table - 已访问表，用于拒绝循环引用
	@return boolean - 可序列化时 true
]]
local function _isSerializable(value: any, depth: number, seen: { [any]: boolean }): boolean
	if value == nil then
		return true
	end

	local valueType = typeof(value)
	if SERIALIZABLE_PRIMITIVE[valueType] then
		return true
	end
	if valueType ~= "table" then
		return false
	end
	if depth > MAX_SERIALIZE_DEPTH then
		return false
	end
	if seen[value] then
		return false
	end
	seen[value] = true

	for key, child in pairs(value) do
		local keyType = type(key)
		if keyType ~= "string" and keyType ~= "number" then
			return false
		end
		if not _isSerializable(child, depth + 1, seen) then
			return false
		end
	end
	return true
end

--[[
	解析 ChangeStat 路径的顶层存档键

	@param statName string|{string} - 字段名或嵌套路径（如 "Bag" / {"Bag","1","count"}）
	@return string? - 顶层键；路径为空或含非法段时为 nil
]]
local function _resolveStatRootKey(statName: string | { string }): string?
	if type(statName) == "table" then
		if #statName < 1 then
			return nil
		end
		for _, key in ipairs(statName) do
			local keyType = type(key)
			if keyType ~= "string" and keyType ~= "number" then
				return nil
			end
		end
		return tostring(statName[1])
	end
	if type(statName) ~= "string" and type(statName) ~= "number" then
		return nil
	end
	return tostring(statName)
end

-- ========================================
-- 公共函数
-- ========================================

--[[
	初始化玩家会话数据并同步到 PlayerData

	@param plr Player - 玩家对象
	@return boolean, boolean? - 是否成功；成功时第二值为是否新玩家
]]
function SystemSave.InitialPlayerData(plr: Player): (boolean, boolean?)
	local isNewPlayer = _setPlayerStat(plr)
	if isNewPlayer == nil then
		return false, nil
	end

	_setPlayerValueInstance(plr)
	_changePlayerValue(plr)

	local data = SystemSave.GetStat(plr)
	if data then
		_getPlayerData().Update(plr, nil, data)
	end

	return true, isNewPlayer
end

--[[
	获取玩家数据快照（深拷贝，禁止直接修改内部会话表）

	@param plr Player? - 玩家对象；省略时返回全部在线会话快照
	@return table? - 传入 plr 时为该玩家存档深拷贝（与 PLAYER_META_DATA 同形）；省略 plr 时为 { [playerId]: 存档拷贝 }，仅服内使用，禁止下发客户端
]]
function SystemSave.GetStat(plr: Player?): any
	if plr then
		local data = _sessionData[_getPlayerId(plr)]
		if data then
			return Copy.deepCopy(data)
		end
		return nil
	end

	local snapshot = {}
	for playerId, data in pairs(_sessionData) do
		snapshot[playerId] = Copy.deepCopy(data)
	end
	return snapshot
end

--[[
	修改玩家持久化数据并同步 Value 实例与客户端缓存

	@param plr Player - 玩家对象；须在线且已加载会话
	@param statName string|{string} - 顶层键或嵌套路径；第一段须为 PLAYER_META_DATA 键（如 "Bag" / {"Bag","1","count"}）
	@param value any - 新值；nil 表示删除该路径；table 会深拷贝后写入；须可 DataStore 序列化（禁止 Instance / Vector3 / 函数 / 循环引用，嵌套不超过 4 层）
	@return boolean, string? - 成功 true；失败 false 与 INVALID_PLAYER / NO_SESSION_DATA / UNKNOWN_STAT_KEY / INVALID_STAT_PATH / UNSERIALIZABLE_VALUE
]]
function SystemSave.ChangeStat(plr: Player, statName: string | { string }, value: any): (boolean, string?)
	if not plr or not plr:IsA("Player") then
		return false, ERROR_INVALID_PLAYER
	end

	local playerId = _getPlayerId(plr)
	local data = _sessionData[playerId]
	if not data then
		return false, ERROR_NO_SESSION_DATA
	end

	local rootKey = _resolveStatRootKey(statName)
	if not rootKey then
		return false, ERROR_INVALID_STAT_PATH
	end
	if PLAYER_META_DATA[rootKey] == nil then
		return false, ERROR_UNKNOWN_STAT_KEY
	end
	if not _isSerializable(value, 0, {}) then
		return false, ERROR_UNSERIALIZABLE_VALUE
	end

	local writeValue = value
	if type(value) == "table" then
		writeValue = Copy.deepCopy(value)
	end

	if type(statName) == "table" then
		local cur = data
		for i = 1, #statName - 1 do
			local key = statName[i]
			if cur[key] == nil or type(cur[key]) ~= "table" then
				cur[key] = {}
			end
			cur = cur[key]
		end
		cur[statName[#statName]] = writeValue
	else
		data[tostring(statName)] = writeValue
	end

	_changePlayerValue(plr)
	_getPlayerData().Update(plr, statName, writeValue)
	return true
end

--[[
	玩家离开时强制保存并延迟清理会话缓存

	@param plr Player - 玩家对象
	@return nil
]]
function SystemSave.PlayerLeaveSave(plr: Player)
	_saveOnRemoving(plr)
end

--[[
	交易等场景下的即时保存

	@param plr Player - 玩家对象
	@return boolean - 是否保存成功
]]
function SystemSave.TradeSave(plr: Player): boolean
	return _savePlayerStat(_getPlayerId(plr))
end

--[[
	自动保存所有在线玩家会话数据到 DataStore

	@return nil - 无返回值；失败玩家由内部 Log 记录
]]
function SystemSave.AutoSave()
	for key: string, _data in pairs(_sessionData) do
		local userId = SystemDataStore.ParsePlayerKey(key)
		if userId and Players:GetPlayerByUserId(userId) then
			_savePlayerStat(key)
		end
	end
end

-- ========================================
-- 初始化
-- ========================================

--[[
	注册玩家会话自动保存定时任务，由 UpdateManager 在 Start 前调用一次

	@return nil
]]
function SystemSave.Init()
	if _initialized then
		return
	end
	_initialized = true

	UpdateModule.Register(UpdateModule.INTERVAL.SEC_30, function(_elapsed: number)
		SystemSave.AutoSave()
	end, { spawn = true })
end

return SystemSave
