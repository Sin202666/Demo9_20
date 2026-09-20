--[[
	Module: SystemCode
	Description: 兑换码 Remote 编排：type 3 CDK 经 SystemCDK CAS 兑换后 SystemBag 发奖，入包失败回滚
	Author: 林奥宇
	Created: 2026-07-03
	Last Modified: 2026-09-01

	功能：
	- RedeemCode：校验玩家与码字符串；非 type 3 普通码仍为 TODO（false + CodeErr.OrdinaryNotImplemented）；type 3 走 CDK
	- RegisterNetWork：注册 REDEEM_CODE RemoteFunction，并配置 RequestRateLimit（幂等）

	调用关系：
	- UpdateManager 预加载以在入服前完成 Remote 注册（模块加载时 RegisterNetWork，避免客户端 Invoke 早于 Init）
	- 客户端 Setting UI 通过 NetWork.InvokeServer(REDEEM_CODE, codeStr) 兑换
	- 发奖只在本模块：SystemCDK.Redeem → SystemBag.AddItems；失败 SystemCDK.RollbackRedeem
	- 不把 rewardId 回传客户端

	示例：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local ok, err = Utils.SystemCode.RedeemCode(player, "XXXX-XXXX-XXXX")
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local Log = Utils.Log
local CfgFind = Utils.CfgFind
local EnumMgr = Utils.EnumMgr
local NetMsg = Utils.NetMsg
local NetWork = Utils.NetWork
local SystemBag = Utils.SystemBag
local SystemCDK = Utils.SystemCDK
local RequestRateLimit = Utils.RequestRateLimit

local SystemCode = {}

local CodeErr = EnumMgr.CodeErr
local CDK_TYPE = 3
local REDEEM_CODE_MAX_LEN = 50
local RATE_LIMIT_MAX_REQUESTS = 3
local RATE_LIMIT_WINDOW_SEC = 5

local _registered = false

-- ============================================================================
-- 私有函数
-- ============================================================================

--[[
	校验玩家对象是否在线且有效
	@param plr Player - 待校验玩家
	@return boolean - 有效为 true
]]
local function _validatePlayer(plr: Player): boolean
	return plr ~= nil and plr:IsA("Player") and plr.Parent ~= nil
end

--[[
	规范化兑换码：去首尾空白并大写
	@param codeStr string - 原始输入
	@return string - 规范化后的码
]]
local function _normalizeCode(codeStr: string): string
	local trimmed = string.gsub(codeStr, "^%s+", "")
	trimmed = string.gsub(trimmed, "%s+$", "")
	return string.upper(trimmed)
end

--[[
	是否为 codeConf 中非 type 3 的普通兑换码（精确匹配规范化后的 code）
	@param codeStr string - 已规范化的码
	@return boolean - 命中普通码配置为 true
]]
local function _isNonCdkConfiguredCode(codeStr: string): boolean
	local codes = CfgFind.GetCfgByName("codeConf")
	if not codes then
		return false
	end
	for _, config in pairs(codes) do
		if tonumber(config.codeType) ~= CDK_TYPE and type(config.code) == "string" then
			if _normalizeCode(config.code) == codeStr then
				return true
			end
		end
	end
	return false
end

--[[
	奖励列表是否至少有一条可入包的配置物品
	@param rewardId {number}? - 物品 ID 列表
	@param rewardNum {number}? - 对应数量
	@return boolean - 存在可发条目为 true
]]
local function _hasGrantableReward(rewardId: { number }?, rewardNum: { number }?): boolean
	if type(rewardId) ~= "table" or type(rewardNum) ~= "table" then
		return false
	end
	for i, itemId in ipairs(rewardId) do
		local count = tonumber(rewardNum[i])
		if CfgFind.FindCfgByID(itemId) and count and count > 0 then
			return true
		end
	end
	return false
end

--[[
	将 CDK 奖励写入背包
	@param plr Player - 玩家
	@param rewardId {number}? - 物品 ID 列表
	@param rewardNum {number}? - 对应数量
	@return boolean - 至少入包一件为 true
]]
local function _grantCdkRewards(plr: Player, rewardId: { number }?, rewardNum: { number }?): boolean
	if not _hasGrantableReward(rewardId, rewardNum) then
		return false
	end
	local ok = SystemBag.AddItems(plr, rewardId :: { number }, rewardNum :: { number })
	return ok == true
end

-- ============================================================================
-- 公共 API
-- ============================================================================

--[[
	兑换兑换码（服务端权威：校验 → CDK CAS → 入包；失败回滚）
	@param plr Player - 发起兑换的玩家
	@param codeStr string - 用户输入的兑换码
	@return boolean - 兑换并入包成功为 true
	@return string? - 失败时为 EnumMgr.CodeErr；成功为 nil
]]
function SystemCode.RedeemCode(plr: Player, codeStr: string): (boolean, string?)
	if not _validatePlayer(plr) then
		return false, CodeErr.InvalidPlayer
	end
	if type(codeStr) ~= "string" or codeStr == "" then
		return false, CodeErr.InvalidCode
	end

	local normalized = _normalizeCode(codeStr)
	if normalized == "" or string.len(normalized) >= REDEEM_CODE_MAX_LEN then
		return false, CodeErr.InvalidCode
	end

	if _isNonCdkConfiguredCode(normalized) then
		-- TODO(林奥宇, 2026-08-31): 接入普通兑换码（codeType ≠ 3）校验与发奖
		return false, CodeErr.OrdinaryNotImplemented
	end

	local ok, rewardId, rewardNum, poolId = SystemCDK.Redeem(plr, normalized)
	if not ok or type(poolId) ~= "string" then
		return false, CodeErr.RedeemFailed
	end

	if _grantCdkRewards(plr, rewardId, rewardNum) then
		return true, nil
	end

	local rolled = SystemCDK.RollbackRedeem(plr, poolId, normalized)
	if not rolled then
		Log.warn("SystemCode: CDK 入包失败且回滚失败", plr.UserId, poolId)
	end
	return false, CodeErr.GrantFailed
end

--[[
	注册兑换码 RemoteFunction，并配置限频（幂等；须在模块加载时调用，避免客户端 Invoke 早于 Init）
]]
function SystemCode.RegisterNetWork()
	if _registered then
		return
	end
	_registered = true

	if RequestRateLimit and RequestRateLimit.SetRateLimitConfig then
		RequestRateLimit.SetRateLimitConfig(NetMsg.REDEEM_CODE, {
			maxRequests = RATE_LIMIT_MAX_REQUESTS,
			timeWindow = RATE_LIMIT_WINDOW_SEC,
		})
	end

	NetWork.RegisterServerRemoteFunction(NetMsg.REDEEM_CODE, function(player: Player, rawCode: string)
		if not _validatePlayer(player) then
			Log.warn("SystemCode: Remote 无效玩家")
			return false, CodeErr.InvalidPlayer
		end
		return SystemCode.RedeemCode(player, rawCode)
	end)
end

SystemCode.RegisterNetWork()

return SystemCode
