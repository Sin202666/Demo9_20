--!strict
--[[
	Module: WorldUtil
	Description: 世界/服务器环境查询——按 PlaceId 推断 Dev/Official 与世界 ID；服务端镜像私人服务器 owner
	Author: 林奥宇
	Created: 2026-07-02
	Last Modified: 2026-09-01

	功能：
	- GetServerType()     当前服务器类型（"Dev" / "Official"）
	- GetCurWorld()       当前世界 ID（PLACE_ID_INFO 命中结果；未命中默认 1）
	- GetSceneId()        当前场景 ID（Dev=1，Official=2）
	- RegisterNetWork()   仅服务端：注册私人服务器 owner Remote；可重复调用（仅首次生效）

	------------------------------------------------------------------------
	何时使用本模块
	------------------------------------------------------------------------
	只问「当前是 Dev 还是 Official / 世界 ID / 场景 ID」→ Utils.WorldUtil。
	关服清理预留服 Global 记录 → UpdateManager 读 workspace 上的 owner NumberValue。
	不要在本模块结算奖励、伤害或改存档。

	------------------------------------------------------------------------
	与相关模块的关系
	------------------------------------------------------------------------
	- Log / DebugManager / SystemSDK：用 GetServerType() 判断是否开发环境
	- UpdateManager：关服时用 GetSceneId() + workspace[NetMsg.PRIVATE_SERVER_OWNER_ID] 拼 DataStore 键
	- RequestRateLimit：已为 PRIVATE_SERVER_OWNER_ID 配限频；本模块不重复 SetRateLimitConfig
	- 权威 owner：优先 game.PrivateServerOwnerId（VIP 服）；客上报只允许报自己的 UserId，且只写一次

	------------------------------------------------------------------------
	PLACE_ID_INFO
	------------------------------------------------------------------------
	格式：[世界ID] = { Dev = PlaceId, Official = PlaceId }
	同一世界 Dev 与 Official 必须配置不同 PlaceId；若相同则无法区分，按 Official 计并延迟 warn。
	未命中任何条目时：类型 Official、世界 ID 为 DEFAULT_WORLD_ID（1）。

	------------------------------------------------------------------------
	端侧 / 调用约束
	------------------------------------------------------------------------
	查询 API 双端可用（PlaceId 两端一致）。
	RegisterNetWork 仅服务端生效；客户端调用直接返回。
	模块加载时自动调用 RegisterNetWork（与 PlayerData / SystemCode 相同）。
	IS_SERVER 只作注册门控，不是两套业务 System。

	加载方式：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local WorldUtil = Utils.WorldUtil

	示例：
		local serverType = WorldUtil.GetServerType()
		local sceneId = WorldUtil.GetSceneId()
		if serverType == "Dev" then
			-- 仅开发环境逻辑
		end
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local NetWork = Utils.NetWork
local NetMsg = Utils.NetMsg
local InsMgr = Utils.InsMgr
local RunService = Utils.RunService

-- ========================================
-- 模块定义
-- ========================================
local WorldUtil = {}

-- ========================================
-- 常量定义
-- ========================================
local SERVER_TYPE_DEV: string = "Dev"
local SERVER_TYPE_OFFICIAL: string = "Official"

local SCENE_ID_DEV: number = 1
local SCENE_ID_OFFICIAL: number = 2
local DEFAULT_WORLD_ID: number = 1

local IS_SERVER = RunService:IsServer()

-- PlaceID 信息配置表；格式: [世界ID] = { Dev = PlaceID, Official = PlaceID }
local PLACE_ID_INFO: { [number]: { Dev: number, Official: number } } = {
	[1] = {
		Dev = 95737228031014,
		Official = 95737228031014,
	},
}

-- ========================================
-- 私有变量
-- ========================================
local _placeId: number = game.PlaceId
local _nowServer: string = SERVER_TYPE_OFFICIAL
local _curWorldId: number = DEFAULT_WORLD_ID
local _placeIdCollision: boolean = false
local _netRegistered: boolean = false

-- ========================================
-- 私有函数
-- ========================================

--[[
	延迟加载 Log.warn，避免 WorldUtil → Log → WorldUtil 循环依赖
	@param ... any - 原样传给 Log.warn 的参数列表
	@return nil - 无返回值
]]
local function _logWarn(...: any)
	local log = Utils.Log
	if log then
		log.warn(...)
	end
end

--[[
	根据当前 PlaceId 写入 _nowServer / _curWorldId
	Official 命中优先于 Dev，避免同 PlaceId 时 pairs 顺序把正式服判成 Dev
	未命中则保持默认 Official + DEFAULT_WORLD_ID
	@return nil - 无返回值
]]
local function _resolveWorldContext()
	local matchedWorldId: number? = nil
	local matchedType: string = SERVER_TYPE_OFFICIAL
	local matchedOfficial = false

	for worldId: number, serverInfo: { Dev: number, Official: number } in pairs(PLACE_ID_INFO) do
		local officialPlaceId = serverInfo[SERVER_TYPE_OFFICIAL]
		local devPlaceId = serverInfo[SERVER_TYPE_DEV]
		if officialPlaceId == devPlaceId then
			_placeIdCollision = true
		end
		if officialPlaceId == _placeId then
			matchedWorldId = worldId
			matchedType = SERVER_TYPE_OFFICIAL
			matchedOfficial = true
		elseif (not matchedOfficial) and devPlaceId == _placeId then
			matchedWorldId = worldId
			matchedType = SERVER_TYPE_DEV
		end
	end

	if matchedWorldId then
		_curWorldId = matchedWorldId
		_nowServer = matchedType
	end
end

--[[
	获取或创建 workspace 上的私人服务器 owner NumberValue
	@return NumberValue - 名为 NetMsg.PRIVATE_SERVER_OWNER_ID 的镜像；Value==0 表示尚未写入
]]
local function _getOwnerValue(): NumberValue
	return InsMgr.GetIns(NetMsg.PRIVATE_SERVER_OWNER_ID, "NumberValue", workspace) :: NumberValue
end

--[[
	服务端只写一次 owner UserId 到 workspace 镜像
	已写入且与本次相同视为成功；已写入且不同则拒绝，防止后到包抢写
	@param ownerId number - 正整数 UserId
	@return boolean - 写入成功或已是同一值时 true；已被其它 UserId 占用时 false
]]
local function _writePrivateServerOwnerId(ownerId: number): boolean
	local ownerValue = _getOwnerValue()
	local existingId = ownerValue.Value
	if existingId ~= 0 then
		return existingId == ownerId
	end
	ownerValue.Value = ownerId
	return true
end

--[[
	VIP 服用 Roblox 权威 PrivateServerOwnerId 预填 workspace 镜像
	预留服 OwnerId==0，无法在此判定归属，留给 handler 按「自称且只写一次」收口
	@return nil - 无返回值
]]
local function _seedOwnerFromRoblox()
	local robloxOwnerId = game.PrivateServerOwnerId
	if typeof(robloxOwnerId) == "number" and robloxOwnerId ~= 0 then
		_writePrivateServerOwnerId(robloxOwnerId)
	end
end

--[[
	PRIVATE_SERVER_OWNER_ID 入站：玩家合法 → 数据合法 → 业务（自称 / VIP 对齐 / 只写一次）
	VIP：忽略客 payload，以 game.PrivateServerOwnerId 为准
	预留服：只接受 player.UserId，且只写一次（任意玩家仍可能抢先自称，完整归属须 TeleportData）
	@param player Player - Remote 调用方；须在线
	@param data any - 客上报的 owner；仅当等于 player.UserId 的正整数时才考虑
	@return nil - 失败静默 return + Log，不向客户端回传内部原因
]]
local function _onPrivateServerOwnerReported(player: Player, data: any)
	if not player or not player:IsA("Player") then
		_logWarn("[WorldUtil] PRIVATE_SERVER_OWNER_ID invalid player")
		return
	end
	if not player.Parent then
		return
	end

	local robloxOwnerId = game.PrivateServerOwnerId
	if typeof(robloxOwnerId) == "number" and robloxOwnerId ~= 0 then
		_writePrivateServerOwnerId(robloxOwnerId)
		return
	end

	local ownerId = tonumber(data)
	if not ownerId or ownerId ~= math.floor(ownerId) or ownerId < 1 then
		_logWarn("[WorldUtil] PRIVATE_SERVER_OWNER_ID invalid data:", data)
		return
	end
	if ownerId ~= player.UserId then
		_logWarn("[WorldUtil] PRIVATE_SERVER_OWNER_ID spoofed owner:", player.UserId, ownerId)
		return
	end

	if not _writePrivateServerOwnerId(ownerId) then
		_logWarn("[WorldUtil] PRIVATE_SERVER_OWNER_ID already set, ignore:", ownerId)
	end
end

-- ========================================
-- 公共函数
-- ========================================

--[[
	获取当前服务器类型（Dev 或 Official）
	@return string - "Dev" 或 "Official"；未匹配 PlaceId 时为 "Official"
]]
function WorldUtil.GetServerType(): string
	return _nowServer
end

--[[
	获取当前世界 ID
	@return number - PLACE_ID_INFO 命中的世界 ID；未匹配时为 DEFAULT_WORLD_ID（1）
]]
function WorldUtil.GetCurWorld(): number
	return _curWorldId
end

--[[
	获取当前场景 ID（由服务器类型映射，不是独立配置）
	Dev → 1，Official → 2
	@return number - 场景 ID（SCENE_ID_DEV 或 SCENE_ID_OFFICIAL）
]]
function WorldUtil.GetSceneId(): number
	if _nowServer == SERVER_TYPE_DEV then
		return SCENE_ID_DEV
	end
	return SCENE_ID_OFFICIAL
end

--[[
	注册私人服务器 owner 通信（仅服务端；可重复调用，仅首次生效）
	副作用：VIP 服用 PrivateServerOwnerId 预填 workspace NumberValue
	@return nil - 非服务端或已注册时直接返回
]]
function WorldUtil.RegisterNetWork()
	if not IS_SERVER then
		return
	end
	if _netRegistered then
		return
	end
	_netRegistered = true

	_seedOwnerFromRoblox()
	NetWork.RegisterServerRemoteEvent(NetMsg.PRIVATE_SERVER_OWNER_ID, _onPrivateServerOwnerReported)
end

-- ========================================
-- 初始化
-- ========================================
_resolveWorldContext()
if _placeIdCollision then
	task.defer(function()
		_logWarn("[WorldUtil] PLACE_ID_INFO Dev 与 Official 使用同一 PlaceId，无法区分；已按 Official 计")
	end)
end
WorldUtil.RegisterNetWork()

return WorldUtil
