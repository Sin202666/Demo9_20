--[[
	Module: SystemDailyAward
	Description: 每日签到领取、冷却检测与红点逻辑（服务端权威结算）
	Author: 林奥宇
	Created: 2026-04-21
	Last Modified: 2026-09-04

	功能：
	- IsEnabled：GameConfig「每日签到.启用」（缺键视为开）
	- CheckDailyAward：冷却已结束且当日配置可领时添加签到红点
	- GetDailyAward：校验 → 写领取标志 → 入包；失败回滚标志。Remote 只回传 boolean
	- Init：玩家入服时立即执行一次签到冷却检测
	- RegisterNetWork：注册 CLAIM_DAILY_AWARD RemoteFunction，并配置 RequestRateLimit

	配置（SystemGameConfig「每日签到」）：
	- 启用：false 时不检测、不领取、不写红点、不注册 30 秒定时；Remote 仍注册但拒绝
	- 每日奖励领取间隔（小时）
	- 每日签到最大天数
	- 每日签到最大多少轮次（超过后 CfgFind 与存档轮次均钳制为上限）

	结算约束：
	- 先查配置与物品 ID/数量，再写 LastDailyTime / NextDailyID / DailyWeekID，再 SystemBag.AddItems
	- 入包失败回滚上述三字段；Remote 不回传 DailyAwardErr（避免泄露内部错误码）
	- LastDailyTime 缺省 0 表示从未领取，0 为合法时间戳，不可当空值拒绝
	- 下一天配置缺失时进入下一轮第 1 天，禁止把 NextDailyID 减回当天（会重复发奖）
	- 修改类成功 true，失败 false + EnumMgr.DailyAwardErr

	调用关系：
	- PlayerManager 入服时调用 Init(plr)；UpdateManager 预加载本模块以注册 30 秒定时检测
	- 客户端 DailyReward UI 通过 NetWork.InvokeServer(CLAIM_DAILY_AWARD) 领取（只认第一返回值 == true）

	加载方式（仅服务端）：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local SystemDailyAward = Utils.SystemDailyAward

	示例：
		if SystemDailyAward.IsEnabled() then
			SystemDailyAward.Init(player)
		end
		local ok, err = SystemDailyAward.GetDailyAward(player)
		if not ok then
			-- err 为 EnumMgr.DailyAwardErr.*
		end
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local Players = Utils.Players
local SystemGameConfig = Utils.SystemGameConfig
local PlayerData = Utils.PlayerData
local TipsModule = Utils.TipsModule
local SystemBag = Utils.SystemBag
local Log = Utils.Log
local CfgFind = Utils.CfgFind
local SystemRedPoint = Utils.SystemRedPoint
local NetMsg = Utils.NetMsg
local NetWork = Utils.NetWork
local UpdateModule = Utils.UpdateModule
local RequestRateLimit = Utils.RequestRateLimit
local EnumMgr = Utils.EnumMgr

-- ========================================
-- 模块定义
-- ========================================
local SystemDailyAward = {}

-- ========================================
-- 常量定义
-- ========================================
local ENABLED_PATH = { "每日签到", "启用" }
local DAILY_INTERVAL_HOURS_PATH = { "每日签到", "每日奖励领取间隔" }
local MAX_DAILY_DAYS_PATH = { "每日签到", "每日签到最大天数" }
local MAX_DAILY_WEEK_PATH = { "每日签到", "每日签到最大多少轮次" }

local STAT_LAST_DAILY_TIME = "LastDailyTime"
local STAT_NEXT_DAILY_ID = "NextDailyID"
local STAT_DAILY_WEEK_ID = "DailyWeekID"
local RED_POINT_SIGN = "签到红点"
local UI_REWARD_POPUP = "AwardPop"

local DAILY_COOLDOWN_SEC: number = SystemGameConfig.GetValue(DAILY_INTERVAL_HOURS_PATH) * 3600
local MAX_DAILY_REWARD_DAY: number = SystemGameConfig.GetValue(MAX_DAILY_DAYS_PATH)
local MAX_DAILY_REWARD_WEEK: number = SystemGameConfig.GetValue(MAX_DAILY_WEEK_PATH)
local MAX_AWARD_COUNT = 9999
local RATE_LIMIT_MAX_REQUESTS = 3
local RATE_LIMIT_WINDOW_SEC = 5

local DailyAwardErr = EnumMgr.DailyAwardErr

-- ========================================
-- 私有变量
-- ========================================
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
	将轮次 ID 钳制到配置的合法区间
	@param weekId number - 当前轮次
	@return number - 钳制后的轮次（1 ~ MAX_DAILY_REWARD_WEEK）
]]
local function _clampWeekId(weekId: number): number
	if weekId < 1 then
		return 1
	end
	if weekId > MAX_DAILY_REWARD_WEEK then
		return MAX_DAILY_REWARD_WEEK
	end
	return weekId
end

--[[
	读取签到存档字段；LastDailyTime=0 表示从未领取，视为合法
	@param plr Player - 目标玩家
	@return table? - { lastDailyTime, weekId（已钳制）, storedWeekId（存档原值）, nextDailyId }；无效时为 nil
	@return string? - 失败时为 EnumMgr.DailyAwardErr
]]
local function _readClaimSnapshot(plr: Player): ({
	lastDailyTime: number,
	weekId: number,
	storedWeekId: number,
	nextDailyId: number,
}?, string?)
	local plrData = PlayerData.GetPlrData(plr)
	if not plrData then
		return nil, DailyAwardErr.NoData
	end

	local lastDailyTime = plrData[STAT_LAST_DAILY_TIME]
	local weekId = plrData[STAT_DAILY_WEEK_ID]
	local nextDailyId = plrData[STAT_NEXT_DAILY_ID]
	if type(lastDailyTime) ~= "number" or type(weekId) ~= "number" or type(nextDailyId) ~= "number" then
		return nil, DailyAwardErr.NoData
	end
	if nextDailyId < 0 then
		return nil, DailyAwardErr.Finished
	end

	return {
		lastDailyTime = lastDailyTime,
		weekId = _clampWeekId(weekId),
		storedWeekId = weekId,
		nextDailyId = nextDailyId,
	}, nil
end

--[[
	判断距离上次领取是否已超过冷却时间
	@param lastDailyTime number - 上次领取时间戳（秒）；0 表示从未领取
	@param nowTime number - 当前时间戳（秒）
	@return boolean - 已过冷却为 true
]]
local function _isCooldownElapsed(lastDailyTime: number, nowTime: number): boolean
	return (nowTime - lastDailyTime) > DAILY_COOLDOWN_SEC
end

--[[
	解析当日可发奖励；配置缺失或数量非法时不结算
	@param weekId number - 当前轮次（已钳制）
	@param nextDailyId number - 当日天数索引
	@return number? - 物品配置 ID
	@return number? - 发放数量（正整数）
	@return string? - 失败时为 EnumMgr.DailyAwardErr
]]
local function _resolveTodayAward(weekId: number, nextDailyId: number): (number?, number?, string?)
	local cfg = CfgFind.GetDailyAward(weekId, nextDailyId)
	if not cfg then
		return nil, nil, DailyAwardErr.ConfigNotFound
	end

	local awardId = tonumber(cfg.AwardID)
	local countId = tonumber(cfg.CountID)
	if not awardId or awardId ~= math.floor(awardId) or awardId <= 0 then
		return nil, nil, DailyAwardErr.InvalidReward
	end
	if not countId or countId ~= math.floor(countId) or countId <= 0 or countId > MAX_AWARD_COUNT then
		return nil, nil, DailyAwardErr.InvalidReward
	end
	if not CfgFind.FindCfgByID(awardId) then
		return nil, nil, DailyAwardErr.ConfigNotFound
	end

	return awardId, countId, nil
end

--[[
	计算领取成功后的下一指针；下一天缺配置则进入下一轮第 1 天，绝不回退当天
	@param weekId number - 当前轮次
	@param nextDailyId number - 刚领取的天数
	@return number - 下一轮次
	@return number - 下一天数
]]
local function _computeNextPointer(weekId: number, nextDailyId: number): (number, number)
	local upcomingId = nextDailyId + 1
	if upcomingId <= MAX_DAILY_REWARD_DAY and CfgFind.GetDailyAward(weekId, upcomingId) then
		return weekId, upcomingId
	end
	return _clampWeekId(weekId + 1), 1
end

--[[
	写入签到三字段（领取标志 + 进度）
	@param plr Player - 目标玩家
	@param lastDailyTime number - LastDailyTime
	@param weekId number - DailyWeekID
	@param nextDailyId number - NextDailyID
	@return boolean - 三字段均写入成功为 true
]]
local function _writeClaimFields(plr: Player, lastDailyTime: number, weekId: number, nextDailyId: number): boolean
	local okTime = PlayerData.ChangePlrData(plr, STAT_LAST_DAILY_TIME, lastDailyTime)
	local okWeek = PlayerData.ChangePlrData(plr, STAT_DAILY_WEEK_ID, weekId)
	local okNext = PlayerData.ChangePlrData(plr, STAT_NEXT_DAILY_ID, nextDailyId)
	return okTime == true and okWeek == true and okNext == true
end

--[[
	玩家离场时清领取互斥，避免 UserId 槽位残留
	@param plr Player - 正在离开的玩家
]]
local function _onPlayerRemoving(plr: Player)
	_claiming[plr.UserId] = nil
end

-- ========================================
-- 公共函数
-- ========================================

--[[
	每日签到总开关（GameConfig「每日签到.启用」；缺键视为开）
	@return boolean - true 表示启用
]]
function SystemDailyAward.IsEnabled(): boolean
	return SystemGameConfig.GetValue(ENABLED_PATH) ~= false
end

--[[
	检测玩家是否满足每日签到领取条件；满足则添加签到红点
	@param plr Player - 目标玩家
	@return boolean - 是否应显示可领取红点
]]
function SystemDailyAward.CheckDailyAward(plr: Player): boolean
	if not SystemDailyAward.IsEnabled() then
		return false
	end
	if not _validatePlayer(plr) then
		return false
	end

	local snapshot = _readClaimSnapshot(plr)
	if not snapshot then
		return false
	end

	local awardId = _resolveTodayAward(snapshot.weekId, snapshot.nextDailyId)
	if not awardId then
		return false
	end

	if not _isCooldownElapsed(snapshot.lastDailyTime, os.time()) then
		return false
	end

	SystemRedPoint.AddRedValue(plr, RED_POINT_SIGN)
	return true
end

--[[
	领取玩家当前可领的每日签到奖励（服务端权威：先写标志再入包，失败回滚）
	@param plr Player - 目标玩家
	@return boolean - 领取并入包成功为 true
	@return string? - 失败时为 EnumMgr.DailyAwardErr；成功为 nil
]]
function SystemDailyAward.GetDailyAward(plr: Player): (boolean, string?)
	if not SystemDailyAward.IsEnabled() then
		return false, nil
	end
	if not _validatePlayer(plr) then
		Log.warn("SystemDailyAward: 无效玩家领取每日奖励")
		return false, DailyAwardErr.InvalidPlayer
	end

	local userId = plr.UserId
	if _claiming[userId] then
		return false, DailyAwardErr.Busy
	end

	local snapshot, snapErr = _readClaimSnapshot(plr)
	if not snapshot then
		if snapErr == DailyAwardErr.NoData then
			Log.warn("SystemDailyAward: 玩家存档不存在", plr.Name)
		end
		return false, snapErr
	end

	local nowTime = os.time()
	if not _isCooldownElapsed(snapshot.lastDailyTime, nowTime) then
		return false, DailyAwardErr.OnCooldown
	end

	local awardId, countId, awardErr = _resolveTodayAward(snapshot.weekId, snapshot.nextDailyId)
	if not awardId or not countId then
		Log.warn("SystemDailyAward: 未找到签到奖励配置", snapshot.weekId, snapshot.nextDailyId)
		return false, awardErr
	end

	local upcomingWeek, upcomingId = _computeNextPointer(snapshot.weekId, snapshot.nextDailyId)

	_claiming[userId] = true
	local committed = false
	local ran, ok, err = pcall(function()
		if not _writeClaimFields(plr, nowTime, upcomingWeek, upcomingId) then
			return false, DailyAwardErr.SaveFailed
		end
		committed = true

		local grantOk = SystemBag.AddItems(plr, { awardId }, { countId })
		if grantOk ~= true then
			return false, DailyAwardErr.GrantFailed
		end

		SystemRedPoint.RemoveRedValue(plr, RED_POINT_SIGN)
		TipsModule.NormalTips(plr, "领取成功")
		Log.print(plr, "领取每日奖励", snapshot.nextDailyId)
		NetWork.FireClient(plr, NetMsg.SHOW_LOCAL_UI, UI_REWARD_POPUP, {
			AwardID = { awardId },
			Count = { countId },
		}, true)
		return true, nil
	end)
	_claiming[userId] = nil

	if not ran then
		Log.warn("SystemDailyAward: 领取过程异常", plr.Name, ok)
		if committed then
			if not _writeClaimFields(plr, snapshot.lastDailyTime, snapshot.storedWeekId, snapshot.nextDailyId) then
				Log.warn("SystemDailyAward: 领取异常且回滚失败", plr.UserId)
			end
		end
		return false, DailyAwardErr.GrantFailed
	end

	if ok ~= true then
		if committed then
			if not _writeClaimFields(plr, snapshot.lastDailyTime, snapshot.storedWeekId, snapshot.nextDailyId) then
				Log.warn("SystemDailyAward: 入包失败且回滚失败", plr.UserId)
			end
		end
		return false, err
	end

	return true, nil
end

--[[
	玩家入服时立即执行一次签到冷却检测
	@param plr Player - 刚完成数据加载的玩家
]]
function SystemDailyAward.Init(plr: Player)
	if not SystemDailyAward.IsEnabled() then
		return
	end
	SystemDailyAward.CheckDailyAward(plr)
end

--[[
	注册每日签到 RemoteFunction、限频与离场清理
]]
function SystemDailyAward.RegisterNetWork()
	if _netRegistered then
		return
	end
	_netRegistered = true

	if RequestRateLimit and RequestRateLimit.SetRateLimitConfig then
		RequestRateLimit.SetRateLimitConfig(NetMsg.CLAIM_DAILY_AWARD, {
			maxRequests = RATE_LIMIT_MAX_REQUESTS,
			timeWindow = RATE_LIMIT_WINDOW_SEC,
		})
	end

	NetWork.RegisterServerRemoteFunction(NetMsg.CLAIM_DAILY_AWARD, function(player: Player)
		if not _validatePlayer(player) then
			Log.warn("SystemDailyAward: Remote 无效玩家")
			return false
		end
		local ok = SystemDailyAward.GetDailyAward(player)
		return ok == true
	end)

	Players.PlayerRemoving:Connect(_onPlayerRemoving)
end

-- ========================================
-- 模块加载时注册通信（ServerStorage，无需 IsServer）
-- ========================================
SystemDailyAward.RegisterNetWork()

-- ========================================
-- 定时任务注册（UpdateManager 预加载时执行；不在 Init 中注册）
-- ========================================
if SystemDailyAward.IsEnabled() then
	UpdateModule.Register(UpdateModule.INTERVAL.SEC_30, function(_elapsed: number)
		for _, plr: Player in Players:GetPlayers() do
			SystemDailyAward.CheckDailyAward(plr)
		end
	end, { spawn = true })
end

return SystemDailyAward
