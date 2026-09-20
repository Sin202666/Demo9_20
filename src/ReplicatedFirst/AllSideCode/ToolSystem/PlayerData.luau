--[[
	Module: PlayerData
	Description: 玩家会话数据双端门面——客户端缓存 / 服务端委托 SystemSave，经 NetWork 同步
	Author: 林奥宇
	Created: 2026-02-03
	Last Modified: 2026-08-31

	功能：
	- GetPlrData(plr)                 获取完整数据快照（深拷贝）
	- GetPlrDataByKey(plr, key)       按路径取嵌套值；key 支持 "score" 或 {"stats","level"}
	- ChangePlrData(plr, key, value)  仅服务端：写入 SystemSave.ChangeStat（内部会增量推送）
	- Update(plr, key, value)         仅服务端：向该玩家推送同步（key 为 nil 表示全量）
	- ListenClientSync(listener)      仅客户端：缓存更新后回调，返回取消函数
	- RegisterNetWork()               模块加载时自动调用，可重复调用（仅首次生效）

	与相关模块的关系：
	- 权威读写只在 SystemSave；本模块是查询/同步门面，禁止业务直接写 Player Store
	- ChangePlrData 仅服务端有效；客户端请用 GetPlrData / GetPlrDataByKey 只读
	- 入服全量请求由 StarterPlayerScripts/Manager/PlayerData.client 编排
	- IS_CLIENT / IS_SERVER 仅作门面分流（读本地缓存 vs 读 SystemSave；写口服务端早退），
	  不是两套业务 System，禁止在此模块结算奖励/伤害

	通信：
	- PLAYER_DATA_SYNC（S→C）：Update 推送；客户端写入 _localPlrData
	- PLAYER_DATA_REQUEST（C→S）：请求全量回推；走 NetWork 限频中间件

	端侧约束：
	- 客户端 GetPlrData / GetPlrDataByKey 只服务 LocalPlayer，其它玩家返回 nil
	- 查询 API 对 table 返回深拷贝；ListenClientSync 的 value 也是快照，禁止写回
	- 增量 value 为 nil 表示删除该路径（与 SystemSave.ChangeStat 一致）

	加载方式：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local PlayerData = Utils.PlayerData

	示例：
		local data = PlayerData.GetPlrData(plr)
		local level = PlayerData.GetPlrDataByKey(plr, {"stats", "level"})
		-- 服务端修改并同步（ChangePlrData 已含推送，一般无需再调 Update）
		PlayerData.ChangePlrData(plr, {"stats", "level"}, 10)
		-- 客户端监听（记得在销毁时调用 disconnect）
		local disconnect = PlayerData.ListenClientSync(function(key, value) end)
]]

-- ============================================================================
-- 模块引用
-- ============================================================================

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local Copy = Utils.Copy
local Log = Utils.Log
local NetMsg = Utils.NetMsg
local NetWork = Utils.NetWork
local Players = Utils.Players
local RequestRateLimit = Utils.RequestRateLimit
local RunService = Utils.RunService

-- ============================================================================
-- 模块定义
-- ============================================================================

local PlayerData = {}

-- ============================================================================
-- 常量
-- ============================================================================

local IS_CLIENT = RunService:IsClient()
local IS_SERVER = RunService:IsServer()

local ERROR_SERVER_ONLY = "SERVER_ONLY"

local RATE_LIMIT_MAX_REQUESTS = 5
local RATE_LIMIT_WINDOW_SEC = 10

-- ============================================================================
-- 私有变量
-- ============================================================================

local _localPlrData: any = nil
local _clientSyncListeners: { (key: string | { string }?, value: any) -> () } = {}
local _netRegistered = false

-- ============================================================================
-- 私有函数
-- ============================================================================

--[[
	延迟获取 SystemSave，避免与 SystemSave 顶层引用 PlayerData 形成循环依赖

	@return table - SystemSave 模块表
]]
local function _getSystemSave()
	return Utils.SystemSave
end

--[[
	校验玩家实例仍在游戏中

	@param plr any - 待校验对象
	@return boolean - 是 Player 且 Parent 非 nil
]]
local function _isValidPlayer(plr: any): boolean
	return typeof(plr) == "Instance" and plr:IsA("Player") and plr.Parent ~= nil
end

--[[
	对 table 做深拷贝，其余类型原样返回（避免把缓存原表交给调用方）

	@param value any - 源值；nil 原样返回
	@return any - table 为深拷贝，其余为原值（含 nil）
]]
local function _snapshotValue(value: any): any
	if type(value) == "table" then
		return Copy.deepCopy(value)
	end
	return value
end

--[[
	按路径从表中读取嵌套字段

	@param tbl table? - 源表
	@param key string|{string} - 单层 key 或路径数组
	@return any? - 路径上的值；tbl/key 无效或路径不存在时为 nil
]]
local function _getNested(tbl: any, key: string | { string }): any?
	if type(tbl) ~= "table" then
		return nil
	end
	if type(key) == "string" then
		return tbl[key]
	end
	if type(key) == "table" and #key > 0 then
		local cur = tbl
		for i = 1, #key do
			if cur == nil or type(cur) ~= "table" then
				return nil
			end
			cur = cur[key[i]]
		end
		return cur
	end
	return nil
end

--[[
	按路径在表中写入嵌套字段（中间缺失节点自动建表；value 为 nil 时删除叶节点）

	@param tbl table - 目标表
	@param key string|{string} - 单层 key 或路径数组
	@param value any - 要写入的值；nil 表示删除该路径
	@return nil - 无返回值；key 无效时静默忽略
]]
local function _setNested(tbl: { [any]: any }, key: string | { string }, value: any)
	if type(key) == "string" then
		tbl[key] = value
		return
	end
	if type(key) == "table" and #key > 0 then
		local cur = tbl
		for i = 1, #key - 1 do
			local k = key[i]
			if cur[k] == nil or type(cur[k]) ~= "table" then
				cur[k] = {}
			end
			cur = cur[k]
		end
		cur[key[#key]] = value
	end
end

--[[
	将 S→C 同步写入本地缓存并通知监听者（table 均深拷贝，不暴露缓存原表）

	@param key string|{string}|nil - nil 表示全量覆盖；否则为增量路径
	@param value any - 同步值；全量时不可为 nil；增量且 nil 表示删除该路径
	@return nil - 全量且 value 为 nil 时忽略
]]
local function _applyClientSync(key: string | { string }?, value: any)
	local stored: any
	if key == nil then
		if value == nil then
			return
		end
		stored = _snapshotValue(value)
		_localPlrData = stored
	else
		if type(_localPlrData) ~= "table" then
			_localPlrData = {}
		end
		stored = _snapshotValue(value)
		_setNested(_localPlrData, key, stored)
	end

	local notifyValue = _snapshotValue(stored)
	for _, listener in _clientSyncListeners do
		task.defer(listener, key, notifyValue)
	end
end

-- ============================================================================
-- 公共 API - 通信注册
-- ============================================================================

--[[
	注册 PlayerData 相关 NetWork 路由（双端各注册一次；可重复调用，仅首次生效）

	@return nil - 无返回值
]]
function PlayerData.RegisterNetWork()
	if _netRegistered then
		return
	end
	_netRegistered = true

	if IS_CLIENT then
		NetWork.RegisterClientRemoteEvent(NetMsg.PLAYER_DATA_SYNC, function(key: string | { string }?, value: any)
			_applyClientSync(key, value)
		end)
		return
	end

	if not IS_SERVER then
		return
	end

	if RequestRateLimit and RequestRateLimit.SetRateLimitConfig then
		RequestRateLimit.SetRateLimitConfig(NetMsg.PLAYER_DATA_REQUEST, {
			maxRequests = RATE_LIMIT_MAX_REQUESTS,
			timeWindow = RATE_LIMIT_WINDOW_SEC,
		})
	end

	NetWork.RegisterServerRemoteEvent(NetMsg.PLAYER_DATA_REQUEST, function(plr: Player)
		if not _isValidPlayer(plr) then
			Log.warn("[PlayerData] PLAYER_DATA_REQUEST 无效玩家")
			return
		end
		local nowData = PlayerData.GetPlrData(plr)
		if nowData then
			PlayerData.Update(plr, nil, nowData)
		end
	end)
end

-- ============================================================================
-- 公共 API - 客户端同步监听
-- ============================================================================

--[[
	客户端注册 PLAYER_DATA_SYNC 推送后的回调（本地缓存已更新后触发）

	@param listener (key: string|{string}|nil, value: any) -> () - 同步回调；key 为 nil 表示全量；value 为快照（table 已深拷贝），禁止写回缓存
	@return (() -> ())? - 取消监听函数；非客户端或 listener 非 function 时为 nil
]]
function PlayerData.ListenClientSync(listener: (key: string | { string }?, value: any) -> ()): (() -> ())?
	if not IS_CLIENT then
		return nil
	end
	if type(listener) ~= "function" then
		return nil
	end
	table.insert(_clientSyncListeners, listener)
	return function()
		local index = table.find(_clientSyncListeners, listener)
		if index then
			table.remove(_clientSyncListeners, index)
		end
	end
end

-- ============================================================================
-- 公共 API - 数据读写
-- ============================================================================

--[[
	获取指定玩家的完整数据快照

	@param plr Player - 玩家实例；客户端仅允许 LocalPlayer，其它玩家返回 nil
	@return table? - 完整数据深拷贝（与存档 PLAYER_META_DATA 同形）；客户端未收到首次同步前为 nil
]]
function PlayerData.GetPlrData(plr: Player): any?
	if IS_CLIENT then
		if plr ~= Players.LocalPlayer then
			return nil
		end
		if _localPlrData == nil then
			return nil
		end
		return _snapshotValue(_localPlrData)
	end
	return _getSystemSave().GetStat(plr)
end

--[[
	按路径读取玩家数据中的嵌套值（table 结果为深拷贝）

	@param plr Player - 玩家实例；客户端仅允许 LocalPlayer
	@param key string|{string} - 单层如 "score"，多层如 {"stats","level"}
	@return any? - 路径上的值；数据未加载或路径不存在时为 nil；table 为深拷贝
]]
function PlayerData.GetPlrDataByKey(plr: Player, key: string | { string }): any?
	if IS_CLIENT then
		if plr ~= Players.LocalPlayer then
			return nil
		end
		return _snapshotValue(_getNested(_localPlrData, key))
	end
	local data = PlayerData.GetPlrData(plr)
	return _getNested(data, key)
end

--[[
	服务端专用：修改玩家持久化数据（委托 SystemSave.ChangeStat，内部会推送客户端）

	@param plr Player - 玩家实例；须在线且已加载会话
	@param key string|{string} - 要修改的路径
	@param value any - 新值；nil 表示删除该路径；table 字段须可序列化
	@return boolean, string? - 成功 true；失败 false 与 errorCode（非服务端为 SERVER_ONLY）
]]
function PlayerData.ChangePlrData(plr: Player, key: string | { string }, value: any): (boolean, string?)
	if not IS_SERVER then
		return false, ERROR_SERVER_ONLY
	end
	return _getSystemSave().ChangeStat(plr, key, value)
end

--[[
	服务端专用：向指定玩家推送数据同步（全量或按路径增量）

	@param plr Player - 目标玩家；须在线
	@param key string|{string}|nil - nil 表示全量；否则为增量路径
	@param value any - 要同步的值；全量时传整张数据表；增量 nil 表示删除该路径
	@return nil - 非服务端或玩家无效时静默忽略
]]
function PlayerData.Update(plr: Player, key: string | { string }?, value: any)
	if not IS_SERVER then
		return
	end
	if not _isValidPlayer(plr) then
		return
	end
	NetWork.FireClient(plr, NetMsg.PLAYER_DATA_SYNC, key, value)
end

-- ============================================================================
-- 初始化
-- ============================================================================

PlayerData.RegisterNetWork()

return PlayerData
