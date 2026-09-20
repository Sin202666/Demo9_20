--[[
	Module: SystemOnlineAward
	Description: 常驻在线奖励——累计在线秒分档领取；本轮全领完重置；付费逐档 Unlock 未达标项；离服清空本轮
	Author: 林奥宇
	Created: 2026-09-04
	Last Modified: 2026-09-04

	功能：
	- IsEnabled：GameConfig「在线奖励.启用」（缺键视为开）
	- AddOnlineTime：全员累加本轮在线秒（UpdateManager 每秒，含 AFK）；会话即时、客户端节流同步
	- AddOnlineSeconds：GM 给单人加秒
	- ClaimOnlineReward：时长达标或该档 Unlock 且未领则发奖；入包失败不标已领；本轮全领完后重置
	- UnlockAllClaimable：付费项 OnlineAwardClaimAll——对本轮「未达标且未领」档写 Unlock=1（已领不变）；无改动也成功；功能关闭时立即 false（不写档、不弹成功购买）
	- ResetOnlineAward：GM 清空本轮
	- HasClaimable：可领查询（红点）

	配置（SystemGameConfig「在线奖励」）：
	- 启用：false 时不计时、不领取、不 Unlock、不写红点、不注册每秒定时；Remote 仍注册但拒绝

	存档 OnlineBox（仅会话镜像，离服清空）：
	- OnlineSeconds
	- [tierId] = { State = 1已领 } 或 { Unlock = 1付费可领 }

	可领判定（CfgFind 共用）：
	- 未领 且（OnlineSeconds >= OnlinTime 或 Unlock == 1）

	发奖：
	- 按 onlineawardConf.AwardID / CountID 原样入包，不做重生倍率

	会话与离服：
	- 进度只在当次在线有效；进服从 0 开始；离服写空 OnlineBox（未领作废，已领物品仍在背包）
	- 每秒只改会话表；客户端推送默认每 CLIENT_SYNC_INTERVAL 秒一次
	- 跨可领档 / 领取 / Unlock / 轮次重置 立即同步

	调用关系：
	- PlayerManager 入服时调用 Init(plr)（须在 SystemRedPoint.Init 之后）
	- UpdateManager 预加载本模块以注册每秒计时与 CLAIM_ONLINE_AWARD
	- SystemBuyRoblox.BuyItemEnd 对 OnlyTag=OnlineAwardClaimAll 调用 UnlockAllClaimable
	- 客户端 OnlineAward UI 通过 NetWork.InvokeServer(CLAIM_ONLINE_AWARD, tierId) 领取（只认第一返回值 == true）

	加载方式（仅服务端）：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local SystemOnlineAward = Utils.SystemOnlineAward

	示例：
		if SystemOnlineAward.IsEnabled() then
			SystemOnlineAward.Init(player)
		end
		local ok = SystemOnlineAward.ClaimOnlineReward(player, 1)
		SystemOnlineAward.UnlockAllClaimable(player)
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local Players = Utils.Players
local SystemGameConfig = Utils.SystemGameConfig
local SystemSave = Utils.SystemSave
local Log = Utils.Log
local CfgFind = Utils.CfgFind
local SystemBag = Utils.SystemBag
local TipsModule = Utils.TipsModule
local EnumMgr = Utils.EnumMgr
local NetMsg = Utils.NetMsg
local NetWork = Utils.NetWork
local UpdateModule = Utils.UpdateModule
local SystemRedPoint = Utils.SystemRedPoint
local RequestRateLimit = Utils.RequestRateLimit

-- ========================================
-- 模块定义
-- ========================================
local SystemOnlineAward = {}

-- ========================================
-- 常量定义
-- ========================================
local ENABLED_PATH = { "在线奖励", "启用" }
local STAT_ONLINE = "OnlineBox"
local STATE_CLAIMED = 1
local RED_POINT_ONLINE = "在线奖励红点"
local CLIENT_SYNC_INTERVAL = 5
local RATE_LIMIT_MAX_REQUESTS = 3
local RATE_LIMIT_WINDOW_SEC = 5
local UI_REWARD_POPUP = "AwardPop"

-- ========================================
-- 私有变量
-- ========================================
local _runtimeByUserId: { [number]: { data: { [any]: any }, lastClientSync: number } } = {}
local _claiming: { [number]: boolean } = {}
local _netRegistered = false

-- ========================================
-- 私有函数
-- ========================================

--[[
	校验玩家对象是否在线且有效
	@param plr Player - 待校验玩家
	@return boolean - 有效为 true
]]
local function _validatePlayer(plr: Player): boolean
	return plr ~= nil and plr:IsA("Player") and plr.Parent ~= nil
end

--[[
	新建空 OnlineBox（不继承存档；进度仅本会话有效）
	@return table - OnlineBox 可变表
]]
local function _newOnlineBox(): { [any]: any }
	return {
		OnlineSeconds = 0,
	}
end

--[[
	获取/创建玩家运行时 OnlineBox（会话权威，入服即从 0）
	@param plr Player - 目标玩家
	@return { data: table, lastClientSync: number } - 运行时
]]
local function _getRuntime(plr: Player): { data: { [any]: any }, lastClientSync: number }
	local userId = plr.UserId
	local rt = _runtimeByUserId[userId]
	if rt then
		return rt
	end
	rt = {
		data = _newOnlineBox(),
		lastClientSync = 0,
	}
	_runtimeByUserId[userId] = rt
	return rt
end

--[[
	读取 OnlineBox（运行时表）
	@param plr Player - 目标玩家
	@return table - OnlineBox
]]
local function _getOnlineData(plr: Player): { [any]: any }
	return _getRuntime(plr).data
end

--[[
	写入会话并按需推客户端
	@param plr Player - 目标玩家
	@param forceClient boolean? - true 立即推客户端；默认按间隔
	@return nil
]]
local function _flushOnlineData(plr: Player, forceClient: boolean?)
	local rt = _getRuntime(plr)
	local now = os.clock()
	local shouldSync = forceClient == true or (now - rt.lastClientSync) >= CLIENT_SYNC_INTERVAL
	if not shouldSync then
		if rt.lastClientSync <= 0 then
			SystemSave.ChangeStat(plr, STAT_ONLINE, rt.data)
			rt.lastClientSync = now
		end
		return
	end
	SystemSave.ChangeStat(plr, STAT_ONLINE, rt.data)
	rt.lastClientSync = now
end

--[[
	替换 OnlineBox 并强制同步客户端
	@param plr Player - 目标玩家
	@param data table - 新 OnlineBox
	@return nil
]]
local function _replaceOnlineData(plr: Player, data: { [any]: any })
	local rt = _getRuntime(plr)
	rt.data = data
	SystemSave.ChangeStat(plr, STAT_ONLINE, rt.data)
	rt.lastClientSync = os.clock()
end

--[[
	本轮是否全部已领
	@param data table - OnlineBox
	@return boolean - 全领完为 true
]]
local function _isRoundFullyClaimed(data: { [any]: any }): boolean
	local list = CfgFind.GetOnlineAwardList()
	if #list == 0 then
		return false
	end
	for _, cfg in ipairs(list) do
		local tierId = tonumber(cfg.id)
		if tierId then
			local tierData = data[tostring(tierId)]
			if not (type(tierData) == "table" and tonumber(tierData.State) == STATE_CLAIMED) then
				return false
			end
		end
	end
	return true
end

--[[
	重置本轮进度（秒数与档位态）
	@param plr Player - 目标玩家
	@return nil
]]
local function _resetRound(plr: Player)
	_replaceOnlineData(plr, _newOnlineBox())
end

--[[
	秒数从 oldSec 增至 newSec 是否新跨过某未领档
	@param data table - OnlineBox
	@param oldSec number - 旧秒数
	@param newSec number - 新秒数
	@return boolean - 新产生可领为 true
]]
local function _crossedClaimableTier(data: { [any]: any }, oldSec: number, newSec: number): boolean
	if newSec <= oldSec then
		return false
	end
	local list = CfgFind.GetOnlineAwardList()
	for _, cfg in ipairs(list) do
		local need = tonumber(cfg.OnlinTime) or 0
		local tierId = tonumber(cfg.id)
		if tierId and oldSec < need and newSec >= need then
			local tierData = data[tostring(tierId)]
			if not (type(tierData) == "table" and tonumber(tierData.State) == STATE_CLAIMED) then
				return true
			end
		end
	end
	return false
end

--[[
	清理离服玩家运行时与领取互斥
	@param userId number - UserId
	@return nil
]]
local function _clearRuntime(userId: number)
	_runtimeByUserId[userId] = nil
	_claiming[userId] = nil
end

--[[
	按可领状态刷新「在线奖励红点」NumberValue（0/1，供客户端只读）
	@param plr Player - 目标玩家
	@return nil
]]
local function _syncRedPoint(plr: Player)
	local value = if CfgFind.HasClaimableOnlineAward(_getOnlineData(plr)) then 1 else 0
	SystemRedPoint.SetRedValue(plr, RED_POINT_ONLINE, value)
end

--[[
	玩家离场：清空本轮并释放运行时
	@param plr Player - 正在离开的玩家
	@return nil
]]
local function _onPlayerRemoving(plr: Player)
	if _runtimeByUserId[plr.UserId] then
		-- 离服清空本轮：未领取亏损；已发进包的物品保留，档位态不跨会话
		_resetRound(plr)
		_clearRuntime(plr.UserId)
	end
end

-- ========================================
-- 公共函数
-- ========================================

--[[
	在线奖励总开关（GameConfig「在线奖励.启用」；缺键视为开）
	@return boolean - true 表示启用
]]
function SystemOnlineAward.IsEnabled(): boolean
	return SystemGameConfig.GetValue(ENABLED_PATH) ~= false
end

--[[
	玩家入服：本轮从 0 开始（不继承离线前进度），刷新红点
	@param plr Player - 目标玩家
	@return nil
]]
function SystemOnlineAward.Init(plr: Player)
	if not SystemOnlineAward.IsEnabled() then
		return
	end
	if not _validatePlayer(plr) then
		return
	end
	-- 入服清空：上次离线未领的档位视为亏损，不延续 OnlineSeconds / State / Unlock
	_resetRound(plr)
	_syncRedPoint(plr)
end

--[[
	全员累加在线秒数（会话即时；客户端节流同步；跨可领档时刷新红点；含 AFK）
	@param dt number - 增量秒（通常为 1）
	@return nil
]]
function SystemOnlineAward.AddOnlineTime(dt: number)
	if not SystemOnlineAward.IsEnabled() then
		return
	end
	local add = tonumber(dt) or 0
	if add <= 0 then
		return
	end
	for _, plr in Players:GetPlayers() do
		if _validatePlayer(plr) and _runtimeByUserId[plr.UserId] then
			local data = _getOnlineData(plr)
			local oldSec = tonumber(data.OnlineSeconds) or 0
			local newSec = oldSec + add
			data.OnlineSeconds = newSec
			local force = _crossedClaimableTier(data, oldSec, newSec)
			_flushOnlineData(plr, force)
			if force then
				_syncRedPoint(plr)
			end
		end
	end
end

--[[
	给指定玩家增加在线秒（GM）
	@param plr Player - 目标玩家
	@param sec number - 增加秒数（可为负，结果钳制 ≥0）
	@return boolean - 成功为 true
]]
function SystemOnlineAward.AddOnlineSeconds(plr: Player, sec: number): boolean
	if not SystemOnlineAward.IsEnabled() then
		return false
	end
	if not _validatePlayer(plr) then
		return false
	end
	local add = tonumber(sec) or 0
	if add == 0 then
		return false
	end
	local data = _getOnlineData(plr)
	local oldSec = tonumber(data.OnlineSeconds) or 0
	local newSec = math.max(0, oldSec + add)
	data.OnlineSeconds = newSec
	_flushOnlineData(plr, true)
	_syncRedPoint(plr)
	Log.print(plr, "GM 增加在线时长", add, "当前", data.OnlineSeconds)
	return true
end

--[[
	领取指定档位在线奖励；入包失败不标已领；本轮全领完则重置
	@param plr Player - 目标玩家
	@param tierId any - 档位 confId
	@return boolean - 成功为 true
]]
function SystemOnlineAward.ClaimOnlineReward(plr: Player, tierId: any): boolean
	if not SystemOnlineAward.IsEnabled() then
		return false
	end
	if not _validatePlayer(plr) then
		Log.warn("SystemOnlineAward: 无效玩家领取")
		return false
	end

	local confId = tonumber(tierId)
	if not confId or confId <= 0 then
		return false
	end

	local userId = plr.UserId
	if _claiming[userId] then
		return false
	end

	local cfg = CfgFind.GetOnlineAward(confId)
	if not cfg then
		Log.warn("SystemOnlineAward: 无配置", confId)
		return false
	end
	cfg.id = confId

	local data = _getOnlineData(plr)
	if not CfgFind.IsOnlineTierClaimable(data, cfg) then
		return false
	end

	local awardId = tonumber(cfg.AwardID)
	local countId = tonumber(cfg.CountID) or 1
	if not awardId then
		Log.warn("SystemOnlineAward: 奖励 ID 非法", confId)
		return false
	end
	countId = math.max(0, math.floor(countId))
	if countId <= 0 then
		Log.warn("SystemOnlineAward: 奖励数量非法", confId)
		return false
	end

	_claiming[userId] = true
	local grantOk = SystemBag.AddItems(plr, { awardId }, { countId })
	_claiming[userId] = nil
	if grantOk ~= true then
		Log.warn("SystemOnlineAward: 入包失败", plr.UserId, confId, awardId, countId)
		return false
	end

	data[tostring(confId)] = { State = STATE_CLAIMED }

	if _isRoundFullyClaimed(data) then
		_resetRound(plr)
		Log.print(plr, "在线奖励本轮全领完，已重置")
	else
		_flushOnlineData(plr, true)
	end
	_syncRedPoint(plr)
	TipsModule.NormalTips(plr, "领取成功")
	NetWork.FireClient(plr, NetMsg.SHOW_LOCAL_UI, UI_REWARD_POPUP, {
		AwardID = { awardId },
		Count = { countId },
	}, true)
	Log.print(plr, "领取在线奖励", confId)
	return true
end

--[[
	是否有可领在线奖励
	@param plr Player - 目标玩家
	@return boolean - 有可领为 true
]]
function SystemOnlineAward.HasClaimable(plr: Player): boolean
	if not SystemOnlineAward.IsEnabled() then
		return false
	end
	if not _validatePlayer(plr) then
		return false
	end
	if not _runtimeByUserId[plr.UserId] then
		return false
	end
	return CfgFind.HasClaimableOnlineAward(_getOnlineData(plr))
end

--[[
	付费：将本轮未达标且未领的档位标记为可领（写 Unlock=1）；已领不变；幂等；无改动也返回 true；功能关闭时立即 false
	@param plr Player - 目标玩家
	@return boolean - 成功为 true
]]
function SystemOnlineAward.UnlockAllClaimable(plr: Player): boolean
	if not SystemOnlineAward.IsEnabled() then
		return false
	end
	if not _validatePlayer(plr) then
		Log.warn("SystemOnlineAward: UnlockAllClaimable 无效玩家")
		return false
	end

	local data = _getOnlineData(plr)
	local seconds = tonumber(data.OnlineSeconds) or 0
	local list = CfgFind.GetOnlineAwardList()
	local changed = false

	for _, cfg in ipairs(list) do
		local tierId = tonumber(cfg.id)
		if tierId then
			local tierStr = tostring(tierId)
			local tierData = data[tierStr]
			local claimed = type(tierData) == "table" and tonumber(tierData.State) == STATE_CLAIMED
			if not claimed then
				local need = tonumber(cfg.OnlinTime) or 0
				local alreadyUnlock = type(tierData) == "table" and tonumber(tierData.Unlock) == 1
				-- 仅处理「未达时长」的档；已达时长本身即可领，无需写 Unlock
				if seconds < need and not alreadyUnlock then
					data[tierStr] = { Unlock = 1 }
					changed = true
				end
			end
		end
	end

	if changed then
		_flushOnlineData(plr, true)
		_syncRedPoint(plr)
	end
	TipsModule.NormalTips(plr, "成功购买")
	Log.print(plr, "在线奖励付费解锁未达标档", changed)
	return true
end

--[[
	GM：重置在线奖励本轮进度
	@param plr Player - 目标玩家
	@return nil
]]
function SystemOnlineAward.ResetOnlineAward(plr: Player)
	if not SystemOnlineAward.IsEnabled() then
		return
	end
	if not _validatePlayer(plr) then
		return
	end
	_resetRound(plr)
	_syncRedPoint(plr)
	Log.print(plr, "GM 重置在线奖励")
end

--[[
	注册领取 RemoteFunction、限频与离场清理
	@return nil
]]
function SystemOnlineAward.RegisterNetWork()
	if _netRegistered then
		return
	end
	_netRegistered = true

	if RequestRateLimit and RequestRateLimit.SetRateLimitConfig then
		RequestRateLimit.SetRateLimitConfig(NetMsg.CLAIM_ONLINE_AWARD, {
			maxRequests = RATE_LIMIT_MAX_REQUESTS,
			timeWindow = RATE_LIMIT_WINDOW_SEC,
		})
	end

	NetWork.RegisterServerRemoteFunction(NetMsg.CLAIM_ONLINE_AWARD, function(player: Player, tierId: any)
		if not _validatePlayer(player) then
			Log.warn("SystemOnlineAward: Remote 无效玩家")
			return false
		end
		return SystemOnlineAward.ClaimOnlineReward(player, tierId)
	end)

	Players.PlayerRemoving:Connect(_onPlayerRemoving)
end

-- ========================================
-- 模块加载时注册通信（ServerStorage，无需 IsServer）
-- ========================================
SystemOnlineAward.RegisterNetWork()

-- ========================================
-- 定时任务注册（UpdateManager 预加载时执行；不在 Init 中注册）
-- ========================================
if SystemOnlineAward.IsEnabled() then
	UpdateModule.Register(UpdateModule.INTERVAL.SEC, function(_elapsed: number)
		SystemOnlineAward.AddOnlineTime(1)
	end, { spawn = true })
end

return SystemOnlineAward
