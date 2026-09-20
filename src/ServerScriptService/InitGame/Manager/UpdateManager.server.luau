--[[
	Module: UpdateManager
	Description: 服务端定时调度与关服编排——预加载 Register 定时任务的 System、启动调度循环、处理关服与地理信息
	Author: 林奥宇
	Created: 2026-07-03
	Last Modified: 2026-09-04

	功能：
	- 预加载已在模块加载期 Register 定时任务或 Remote 的 System，确保 Start 前完成注册
	- 按序调用 SystemSave / SystemGlobalData / SystemServerBuff / SystemRank / DataCache / SystemInputBind 的 Init
	- CombatWorld.Init + SkillBuffUtil.Init（战斗仿真调度）
	- 怪物系统启用时：EnemyLogicalSync.Init → SystemEnemy.Init → EnemySim.Init（只 register）
	- 维护 workspace「服务器存在时间」NumberValue
	- 生产环境 BindToClose：存档、SDK 上报、私服 Global 记录清理、提示并传送在线玩家
	- Studio BindToClose 只 AutoSave，不传送、不清私服记录
	- 异步获取服务器地理位置写入 workspace（失败重试，不阻塞启动）

	预加载（require 时完成 Register 或 Remote 注册，变量仅用于强制加载）：
	- SystemBUFF / SystemLeaderstats / SystemRecord / SystemDailyAward / SystemOnlineAward / SystemCode / SystemFeedback / SystemSet / SystemUpdateLog
	- SystemInputBind 在模块加载时 RegisterNetWork（与 SystemCode / SystemSet 相同，避免 Init 晚于客户端 GET）

	Init 顺序（Register 在 Init 内的模块须先于 Start）：
	1. SystemSave → SystemGlobalData → SystemServerBuff → SystemRank（Studio 随后立即 UpdateRank）→ DataCache → SystemInputBind.Init（限频）
	2. CombatWorld；SystemCharacterMotion；怪物启用时 EnemyLogicalSync → SystemEnemy → EnemySim；SkillBuffUtil
	3. UpdateModule.Start()

	与相关模块的关系：
	- UpdateModule：本脚本是服侧唯一 Start 入口；各 System 只 Register
	- SystemDataStore：关服清预留服 Global 键，键格式 {sceneId}VIPServer{ownerUserId}，与创房写入约定一致
	- WorldUtil：用 GetServerType / GetSceneId 判断是否 Official 预留服；owner 镜像已存在才清，不在此创建
	- UIManager：FireClient SHOW_LOCAL_UI 打开名为「关服提示」的 Frame，本脚本不写 UI Instance

	端侧 / 调用约束：
	- 本文件是 ServerScript（InitGame/Manager），不是 Utils 可 require 的模块；由服务器启动自动运行
	- 禁止其它模块再调 UpdateModule.Start 或互调上述 System.Init
	- 地理信息为尽力而为；ip-api 失败只 Log，不影响游玩

	加载方式：
		本脚本位于 ServerScriptService/InitGame/Manager，服务器启动时自动运行。
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

	示例：
	-- 新增定时 System 时，在下方「预加载」区增加一行 side-effect require：
	local _SystemFoo = Utils.SystemFoo
]]

-- ========================================
-- 服务引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local Players = Utils.Players
local RunService = Utils.RunService
local HttpService = Utils.HttpService

-- ========================================
-- 模块引用
-- ========================================
local UpdateModule = Utils.UpdateModule
local SystemSave = Utils.SystemSave
local SystemGlobalData = Utils.SystemGlobalData
local SystemServerBuff = Utils.SystemServerBuff
local SystemDataStore = Utils.SystemDataStore
local SystemRank = Utils.SystemRank
local SystemTeleport = Utils.SystemTeleport
local SystemSDK = Utils.SystemSDK
local WorldUtil = Utils.WorldUtil
local InsMgr = Utils.InsMgr
local Log = Utils.Log
local NetMsg = Utils.NetMsg
local NetWork = Utils.NetWork
local DataCache = Utils.DataCache
local ServerStorage = Utils.ServerStorage
local SkillBuffUtil = Utils.SkillBuffUtil
local CombatWorld = Utils.CombatWorld
local SystemCharacterMotion = Utils.SystemCharacterMotion
local EnemyLogicalSync = Utils.EnemyLogicalSync
local SystemEnemy = Utils.SystemEnemy
local EnemySim = Utils.EnemySim

-- 预加载：require 时完成 UpdateModule.Register 或 Remote 注册
local _SystemBUFF = Utils.SystemBUFF
local _SystemLeaderstats = Utils.SystemLeaderstats
local _SystemRecord = Utils.SystemRecord
local _SystemDailyAward = Utils.SystemDailyAward
local _SystemOnlineAward = Utils.SystemOnlineAward
local _SystemCode = Utils.SystemCode
local _SystemFeedback = Utils.SystemFeedback
local _SystemSet = Utils.SystemSet
local _SystemUpdateLog = Utils.SystemUpdateLog
local SystemInputBind = Utils.SystemInputBind

-- ========================================
-- 常量定义
-- ========================================
local URL_GEO_LOOKUP = "http://ip-api.com/json/"
local MAX_GEO_RETRY = 10
local GEO_RETRY_INTERVAL_SEC = 5
local GEO_FIELD_COUNTRY = "countryCode"
local GEO_FIELD_REGION = "regionName"

local SERVER_TIME_INST_NAME = "服务器存在时间"
local SERVER_COUNTRY_INST_NAME = "服务器countryCode"
local SERVER_REGION_INST_NAME = "服务器regionName"
local UI_SHUTDOWN_TIP = "关服提示"

local GLOBAL_STORE = SystemDataStore.STORE.Global

local GLOBAL_SAVE_OPTIONS = {
	maxTries = 3,
	retryIntervalSec = 1,
}

local ROBLOX_SERVER_TYPE = {
	VIP = "VIPServer",
	RESERVED = "ReservedServer",
	STANDARD = "StandardServer",
}

-- 与 WorldUtil.GetServerType 返回值一致
local SERVER_TYPE_OFFICIAL = "Official"

-- ========================================
-- 私有变量
-- ========================================
local _serverTime: NumberValue = InsMgr.GetIns(SERVER_TIME_INST_NAME, "NumberValue", workspace)
_serverTime.Value = 0

-- ========================================
-- 私有函数
-- ========================================

--[[
	判断当前 Roblox 服务器类型（标准 / 预留 / VIP 私人服）

	@return string - ROBLOX_SERVER_TYPE.VIP / RESERVED / STANDARD
]]
local function _getRobloxServerType(): string
	if game.PrivateServerId ~= "" then
		if game.PrivateServerOwnerId ~= 0 then
			return ROBLOX_SERVER_TYPE.VIP
		end
		return ROBLOX_SERVER_TYPE.RESERVED
	end
	return ROBLOX_SERVER_TYPE.STANDARD
end

--[[
	关服时提示玩家并传送回当前 Place，使本服务器实例被腾空
	@param plr Player - 关服时已在场或窗口内新加入的玩家
	@return nil - 无效玩家直接返回；传送由 SystemTeleport 内部重试
]]
local function _notifyAndTeleportOnShutdown(plr: Player)
	if not plr or not plr:IsA("Player") then
		return
	end
	NetWork.FireClient(plr, NetMsg.SHOW_LOCAL_UI, UI_SHUTDOWN_TIP, nil, true)
	SystemTeleport.TeleportWithRetry(game.PlaceId, { plr })
end

--[[
	Official 预留服关服时清除 Global 上的私服占用记录，避免房间列表残留幽灵房
	键格式：{sceneId}{VIPServer}{ownerUserId}，与创房写入约定一致
	owner 镜像不存在时跳过（不在此创建 NumberValue）
	@return nil - 非目标环境或缺镜像时跳过；失败只 Log
]]
local function _clearReservedServerRecord()
	if WorldUtil.GetServerType() ~= SERVER_TYPE_OFFICIAL then
		return
	end
	if _getRobloxServerType() ~= ROBLOX_SERVER_TYPE.RESERVED then
		return
	end

	local ownerValue = workspace:FindFirstChild(NetMsg.PRIVATE_SERVER_OWNER_ID)
	if not ownerValue or not ownerValue:IsA("NumberValue") then
		return
	end

	local recordName = tostring(WorldUtil.GetSceneId()) .. ROBLOX_SERVER_TYPE.VIP .. (ownerValue :: NumberValue).Value
	local clearOk, clearErr = SystemDataStore.Set(GLOBAL_STORE, recordName, "", GLOBAL_SAVE_OPTIONS)
	if clearOk then
		Log.print("清除记录的私服数据:", recordName)
	else
		Log.warn("清除私服数据失败:", recordName, clearErr)
	end
end

--[[
	关服流程：存档、清理私服 Global 记录、SDK 上报、提示并传送在线玩家
	PlayerAdded 在 BindToClose 窗口内保持连接，覆盖关服瞬间新加入的玩家；服务器即将销毁，不 Disconnect

	@return nil - BindToClose 回调内调用；失败步骤由 Log 记录
]]
local function _handleServerShutdown()
	local ok, err = pcall(SystemSave.AutoSave)
	if not ok then
		Log.warn("关服自动存档失败:", err)
	end

	_clearReservedServerRecord()

	local flushOk, flushErr = pcall(SystemSDK.Flush)
	if not flushOk then
		Log.warn("关服 SDK flush 失败:", flushErr)
	end

	Players.PlayerAdded:Connect(_notifyAndTeleportOnShutdown)

	for _, plr: Player in Players:GetPlayers() do
		task.spawn(_notifyAndTeleportOnShutdown, plr)
	end
end

--[[
	轮询 ip-api 获取服务器国家/地区，写入 workspace StringValue；失败重试后放弃
	JSON 非法时计入重试，避免 GetAsync 成功但正文非 JSON 时协程直接中断
	有界 for，避免 while true；每次尝试前等待，给启动期让路

	@return nil - 成功写入后返回；达 MAX_GEO_RETRY 次仍失败则 Log 后结束
]]
local function _fetchServerLocation()
	for _ = 1, MAX_GEO_RETRY do
		task.wait(GEO_RETRY_INTERVAL_SEC)

		local success, response = pcall(HttpService.GetAsync, HttpService, URL_GEO_LOOKUP)
		if success and typeof(response) == "string" then
			local decodeOk, data = pcall(HttpService.JSONDecode, HttpService, response)
			if decodeOk and typeof(data) == "table" then
				local countryCode = data[GEO_FIELD_COUNTRY]
				local regionName = data[GEO_FIELD_REGION]
				if typeof(countryCode) == "string"
					and countryCode ~= ""
					and typeof(regionName) == "string"
					and regionName ~= ""
				then
					local countryInst: StringValue = InsMgr.GetIns(SERVER_COUNTRY_INST_NAME, "StringValue", workspace)
					local regionInst: StringValue = InsMgr.GetIns(SERVER_REGION_INST_NAME, "StringValue", workspace)
					countryInst.Value = countryCode
					regionInst.Value = regionName
					Log.print("服务器地理位置:", countryCode, regionName)
					return
				end
			end
		end
	end

	Log.warn("获取服务器地理位置失败，已达到最大重试次数")
end

--[[
	秒级时钟回调：累加 workspace「服务器存在时间」
	@param elapsed number - 本区间实际经过秒数，由 UpdateModule 传入
	@return nil - 只写 NumberValue
]]
local function _onServerTimeTick(elapsed: number)
	_serverTime.Value += elapsed
end

--[[
	BindToClose：Studio 只 AutoSave；生产走完整关服编排
	@return nil - Studio 存档失败只 Log；生产失败步骤由 _handleServerShutdown 记录
]]
local function _onBindToClose()
	if RunService:IsStudio() then
		local saveOk, saveErr = pcall(SystemSave.AutoSave)
		if not saveOk then
			Log.warn("Studio 关服自动存档失败:", saveErr)
		end
		return
	end
	_handleServerShutdown()
end

--[[
	启动编排：秒级时钟 Register → 各 System.Init → UpdateModule.Start → BindToClose → 地理信息
	Studio 在 SystemRank.Init 之后立即拉一次榜缓存，便于本地看镜像
	@return nil - 由脚本加载末尾调用一次；不对外导出
]]
local function _init()
	UpdateModule.Register(UpdateModule.INTERVAL.SEC, _onServerTimeTick)

	SystemSave.Init()
	SystemGlobalData.Init()
	SystemServerBuff.Init()
	SystemRank.Init()
	if RunService:IsStudio() then
		SystemRank.UpdateRank()
	end
	DataCache.Init({
		cacheRoot = ServerStorage,
		clearNameOnSweep = true,
		registerSweep = true,
	})
	SystemInputBind.Init()

	CombatWorld.Init()
	SystemCharacterMotion.Init()
	if SystemEnemy.IsEnabled() then
		EnemyLogicalSync.Init()
		SystemEnemy.Init()
		EnemySim.Init()
	end
	SkillBuffUtil.Init()

	UpdateModule.Start()

	game:BindToClose(_onBindToClose)
	task.spawn(_fetchServerLocation)
end

-- ========================================
-- 启动
-- ========================================
_init()
