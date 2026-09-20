--[[
	Module: SystemBuyRoblox
	Description: 客户端 Roblox 付费购买入口（Prompt 弹窗、赠送确认 UI、赠送目标请求）
	Author: 林奥宇
	Created: 2026-07-02
	Last Modified: 2026-09-04

	功能：
	- BuyRobloxByOnlyTag — 按商品 onlyTag 拉起 GamePass / Developer Product 购买 Prompt
	- SetGiftTarget — 请求服务端写入赠送目标（只传 UserId，收货人由服裁定）

	与服务端 SystemBuyRoblox 的关系：
	- 本模块仅触发 MarketplaceService Prompt、本地 WarnPop 确认弹窗、Invoke SET_GIFT / CANCEL_GIFT
	- 发货、收据处理、GiftPlayer.Value 写入由 ServerSideCode/System/SystemBuyRoblox 负责
	- PurchaseManager 仅绑定 Marketplace 回调

	加载方式（客户端）：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local SystemBuyRoblox = Utils.SystemBuyRoblox

	示例：
		SystemBuyRoblox.SetGiftTarget(targetPlayer)
		SystemBuyRoblox.BuyRobloxByOnlyTag(localPlayer, "GiftPack1")
]]

-- ============================================================================
-- 服务引用
-- ============================================================================

local MarketplaceService = game:GetService("MarketplaceService")

-- ============================================================================
-- 模块引用
-- ============================================================================

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local CfgFind = Utils.CfgFind
local EnumMgr = Utils.EnumMgr
local NetMsg = Utils.NetMsg
local NetWork = Utils.NetWork
local TranslationHelper = Utils.TranslationHelper

-- ============================================================================
-- 模块定义
-- ============================================================================

local SystemBuyRoblox = {}

-- ============================================================================
-- 私有函数
-- ============================================================================

--[[
	拉起 Developer Product 购买 Prompt

	@param plr Player - 发起购买的本地玩家
	@param productID number - Marketplace ProductId
	@return nil
]]
local function _promptRobloxItem(plr: Player, productID: number)
	MarketplaceService:PromptProductPurchase(plr, productID)
end

--[[
	拉起 GamePass 购买 Prompt

	@param plr Player - 发起购买的本地玩家
	@param gamePassID number - GamePass 资产 id
	@return nil
]]
local function _promptGamePass(plr: Player, gamePassID: number)
	MarketplaceService:PromptGamePassPurchase(plr, gamePassID)
end

-- ============================================================================
-- 公共函数
-- ============================================================================

--[[
	请求服务端把赠送目标写成指定在线玩家（只传 UserId）

	@param targetPlr Player - 收礼玩家；须在线且不能是自己（服侧再校验）
	@return boolean - 服写入成功为 true；参数无效或 Invoke 失败为 false
]]
function SystemBuyRoblox.SetGiftTarget(targetPlr: Player): boolean
	if not targetPlr or not targetPlr:IsA("Player") then
		return false
	end
	local result = NetWork.InvokeServer(NetMsg.SET_GIFT, targetPlr.UserId)
	return result == true
end

--[[
	按商品 onlyTag 发起 Roblox 付费购买（含赠送确认流程）

	@param plr Player - 发起购买的玩家；客户端通常为 LocalPlayer
	@param onlyTag string - CfgFind 商品唯一标签
	@return boolean - 已发起 Prompt 或弹出赠送确认为 true；参数或配置无效为 false
]]
function SystemBuyRoblox.BuyRobloxByOnlyTag(plr: Player, onlyTag: string): boolean
	if not plr or not onlyTag then
		return false
	end

	local cfg = CfgFind.FindCfgByOnlyTag(onlyTag)
	if not cfg then
		return false
	end

	local giftPlayer: ObjectValue? = plr:FindFirstChild(EnumMgr.PlayerInst.GiftPlayer) :: ObjectValue?
	local giftTarget = giftPlayer and giftPlayer.Value
	if giftTarget and giftTarget:IsA("Player") then
		local giftProductId = cfg.GiftID and tonumber(cfg.GiftID)
		if giftProductId then
			local checkData = {
				titleText = TranslationHelper.TranslateByKey("确认"),
				tipsText = TranslationHelper.TranslateByKey("赠送确认", {
					{ cfg.ZhName },
					giftTarget.DisplayName,
				}),
				func = function()
					_promptRobloxItem(plr, giftProductId :: number)
				end,
			}
			NetWork.FireBindable(NetMsg.SHOW_LOCAL_UI, "WarnPop", checkData, true)
		end
		return giftProductId ~= nil
	end

	if cfg.passID and cfg.price then
		if cfg.cost == EnumMgr.RobuxType.GamePass then
			_promptGamePass(plr, cfg.passID)
			return true
		elseif cfg.cost == EnumMgr.RobuxType.RobuxItem then
			_promptRobloxItem(plr, cfg.passID)
			return true
		end
	end

	return false
end

return SystemBuyRoblox
