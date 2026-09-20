--[[
	Module: SystemBuyRoblox
	Description: 服务端 Roblox 付费购买（收据处理、GamePass、赠送发货）
	Author: 林奥宇
	Created: 2026-07-02
	Last Modified: 2026-09-04

	功能：
	- BuyItemEnd — Marketplace 收据 / GamePass 回调 / 邮件礼品共用的统一发货入口；OnlineAwardClaimAll 走 SystemOnlineAward.UnlockAllClaimable
	- ProcessReceipt — Developer Product 收据幂等：先占位 PurchaseHistory 再发货
	- OnGamePassPurchased — GamePass 购买完成后的发货与统计
	- Init — 注册 SET_GIFT / CANCEL_GIFT Remote 并配置限频

	与客户端 SystemBuyRoblox（SystemModule）的关系：
	- 客户端仅负责 Prompt 购买弹窗、赠送确认 UI，以及 Invoke SET_GIFT
	- 权威发货、收据去重、赠送目标写入仅在本模块执行
	- PurchaseManager 仅绑定 MarketplaceService 并转发至本模块

	约束：
	- 修改类成功 true，失败 false + EnumMgr.BuyRobloxErr
	- 任一件 AddItems 失败则不提示成功；已入包件不回滚
	- PurchaseHistory 先 Update 占位 true 再发货；发货失败则 Remove 占位
	- SET_GIFT 只收 targetUserId，服校验在线且不能是自己

	加载方式（仅服务端）：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local SystemBuyRoblox = Utils.SystemBuyRoblox
		SystemBuyRoblox.Init()

	示例：
		local ok, err = SystemBuyRoblox.BuyItemEnd(player, cfg.OnlyTag)
		if not ok then
			-- err 为 EnumMgr.BuyRobloxErr.*
		end
		local decision = SystemBuyRoblox.ProcessReceipt(receiptInfo)
]]

-- ============================================================================
-- 服务引用
-- ============================================================================

local Players = game:GetService("Players")

-- ============================================================================
-- 模块引用
-- ============================================================================

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local CfgFind = Utils.CfgFind
local EnumMgr = Utils.EnumMgr
local GameAnalytics = Utils.GameAnalytics
local Log = Utils.Log
local NetMsg = Utils.NetMsg
local NetWork = Utils.NetWork
local RankConfig = Utils.RankConfig
local RequestRateLimit = Utils.RequestRateLimit
local SystemBag = Utils.SystemBag
local SystemDataStore = Utils.SystemDataStore
local SystemRecord = Utils.SystemRecord
local SystemRank = Utils.SystemRank
local SystemSDK = Utils.SystemSDK
local SystemShop = Utils.SystemShop
local SystemOnlineAward = Utils.SystemOnlineAward
local TipsModule = Utils.TipsModule

-- ============================================================================
-- 模块定义
-- ============================================================================

local SystemBuyRoblox = {}

-- ============================================================================
-- 常量
-- ============================================================================

-- 购买成功时不弹出奖励 UI 的物品 id 集合；值为 1 表示跳过
local NOT_POP_UI_VT: { [number]: number } = {}

-- 需要显示奖励弹窗的 GamePass OnlyTag 集合；值为 1 表示展示
local SHOW_REWARD_GAMEPASS: { [string]: number } = {
	["GiftPack1"] = 1,
	["GiftPack2"] = 1,
}

local RECORD_ROBUX_SPEND_KEY = RankConfig.GetRecordField(RankConfig.RANK_ROBUX_NAME) :: string

local PURCHASE_HISTORY_STORE = SystemDataStore.STORE.PurchaseHistory

local PURCHASE_LOAD_OPTIONS = {
	maxTries = 1,
	retryIntervalSec = 0,
}

local PURCHASE_SAVE_OPTIONS = {
	maxTries = 3,
	retryIntervalSec = 1,
}

local RATE_LIMIT_MAX_REQUESTS = 3
local RATE_LIMIT_WINDOW_SEC = 5

local GIFT_PLAYER_INST_NAME = EnumMgr.PlayerInst.GiftPlayer
local BuyRobloxErr = EnumMgr.BuyRobloxErr
local USE_SCRIPT_ADD_BUFF = "AddBUFF"

-- ============================================================================
-- 私有变量
-- ============================================================================

local _initialized = false

-- ============================================================================
-- 私有函数
-- ============================================================================

--[[
	累计玩家 Robux 消费记录

	@param player Player - 消费玩家
	@param price number - 消费罗宝数量
]]
local function _recordRobuxSpend(player: Player, price: number)
	if not player or not price then
		return
	end
	SystemRecord.RecordAdd(player, RECORD_ROBUX_SPEND_KEY, price)
	SystemRank.UploadPlayer(player)
end

--[[
	向客户端推送 GamePass 奖励弹窗

	@param player Player - 目标玩家
	@param cfg table - CfgFind 商品配置；须含 itemID、itemCount
]]
local function _showGamePassRewardPop(player: Player, cfg: any)
	local uiData = {
		AwardID = cfg.itemID,
		Count = cfg.itemCount,
	}
	NetWork.FireClient(player, NetMsg.SHOW_LOCAL_UI, "AwardPop", uiData, true)
end

--[[
	取玩家下服创建的赠送目标 ObjectValue

	@param player Player - 赠送发起者
	@return ObjectValue? - GiftPlayer 实例；缺失或类型不符为 nil
]]
local function _getGiftPlayerObject(player: Player): ObjectValue?
	local inst = player:FindFirstChild(GIFT_PLAYER_INST_NAME)
	if inst and inst:IsA("ObjectValue") then
		return inst :: ObjectValue
	end
	return nil
end

--[[
	处理赠送类 Developer Product 购买

	@param buyer Player - 付款玩家
	@param giftCfg table - CfgFind 赠送商品配置；须含 passID、OnlyTag、cost、price、ZhName
	@return boolean, string? - 成功 true；失败 false 与 GiftTargetInvalid / TargetOffline / GrantFailed
]]
local function _handleGiftPurchase(buyer: Player, giftCfg: any): (boolean, string?)
	local giftPlayerObj = _getGiftPlayerObject(buyer)
	if not giftPlayerObj or giftPlayerObj.Value == nil then
		return false, BuyRobloxErr.GiftTargetInvalid
	end

	local giftPlrValue = giftPlayerObj.Value
	if not giftPlrValue or not giftPlrValue:IsA("Player") then
		return false, BuyRobloxErr.GiftTargetInvalid
	end

	local giftPlr: Player = giftPlrValue :: Player
	if not giftPlr.Parent then
		return false, BuyRobloxErr.TargetOffline
	end

	if giftCfg.cost == EnumMgr.RobuxType.GamePass then
		local ok, err = SystemShop.BuyGamePassSuc(giftPlr, giftCfg.passID)
		if not ok then
			Log.warn("[SystemBuyRoblox] 赠送 GamePass 发货失败:", giftPlr.UserId, giftCfg.passID, err)
			return false, BuyRobloxErr.GrantFailed
		end
	else
		local buyOk, buyErr = SystemBuyRoblox.BuyItemEnd(giftPlr, giftCfg.OnlyTag)
		if not buyOk then
			Log.warn("[SystemBuyRoblox] 赠送商品发货失败:", giftPlr.UserId, giftCfg.OnlyTag, buyErr)
			return false, buyErr or BuyRobloxErr.GrantFailed
		end
	end

	local buyerTipData = {
		Title = "赠送",
		Key = "赠送成功",
		args = nil,
	}
	NetWork.FireClient(buyer, NetMsg.SHOW_LOCAL_UI, "弹窗提示", buyerTipData, true)
	_recordRobuxSpend(buyer, giftCfg.price)

	local receiverTipData = {
		Title = "赠送",
		Key = "收到礼物",
		args = { buyer.DisplayName, { giftCfg.ZhName } },
	}
	NetWork.FireClient(giftPlr, NetMsg.SHOW_LOCAL_UI, "弹窗提示", receiverTipData, true)

	return true
end

--[[
	处理 Developer Product 购买成功后的发货逻辑

	@param receipt table - Marketplace 收据；字段 ProductId number、PlayerId number、PurchaseId string
	@param player Player - 在线购买玩家
	@return boolean, string? - 发货成功为 true；失败 false 与 BuyRobloxErr
]]
local function _handleProductPurchaseSuccess(receipt: any, player: Player): (boolean, string?)
	if not receipt or not player then
		return false, BuyRobloxErr.InvalidParam
	end

	local robuxItemId: number = receipt.ProductId
	if not robuxItemId then
		return false, BuyRobloxErr.InvalidParam
	end

	local cfg = CfgFind.FindCfgByPassID(robuxItemId)
	if not cfg then
		local giftCfg = CfgFind.FindCfgByPassID_Gift(robuxItemId)
		if giftCfg and giftCfg.passID then
			return _handleGiftPurchase(player, giftCfg)
		end

		Log.warn("[SystemBuyRoblox] 商品 ID 无配置:", robuxItemId)
		return false, BuyRobloxErr.ConfigNotFound
	end

	local buyOk, buyErr = SystemBuyRoblox.BuyItemEnd(player, cfg.OnlyTag)
	if not buyOk then
		return false, buyErr or BuyRobloxErr.GrantFailed
	end
	_recordRobuxSpend(player, cfg.price)
	return true
end

--[[
	构建 PurchaseHistory Store 键名

	@param receiptInfo table - Marketplace 收据；字段 PlayerId number、PurchaseId string
	@return string - 格式 "{playerId}_{purchaseId}"
]]
local function _buildPurchaseHistoryKey(receiptInfo: any): string
	return tostring(receiptInfo.PlayerId) .. "_" .. tostring(receiptInfo.PurchaseId)
end

--[[
	抢占 PurchaseHistory：把空值写成 true。已有记录视为已处理，不再发货。
	transform 每次调用都改写 claimedByUs，避免 UpdateAsync 重试把「他人已占位」当成自己抢到。

	@param purchaseKey string - "{playerId}_{purchaseId}"
	@return boolean, boolean - DataStore 操作成功；本调用是否抢占成功（可以发货）
]]
local function _claimPurchaseHistory(purchaseKey: string): (boolean, boolean)
	local claimedByUs = false
	local updateOk, _, updateErr = SystemDataStore.Update(
		PURCHASE_HISTORY_STORE,
		purchaseKey,
		function(old)
			if old then
				claimedByUs = false
				return old
			end
			claimedByUs = true
			return true
		end,
		PURCHASE_SAVE_OPTIONS
	)
	if not updateOk then
		Log.warn("[SystemBuyRoblox] PurchaseHistory 占位失败:", updateErr)
		return false, false
	end
	return true, claimedByUs
end

--[[
	发货失败时清除占位，允许收据重试再次发货。Remove 失败时占位仍在，重试不再发货（少发不重发）。

	@param purchaseKey string - "{playerId}_{purchaseId}"
]]
local function _clearPurchaseClaim(purchaseKey: string)
	local remOk, remErr = SystemDataStore.Remove(
		PURCHASE_HISTORY_STORE,
		purchaseKey,
		PURCHASE_SAVE_OPTIONS
	)
	if not remOk then
		Log.warn("[SystemBuyRoblox] 发货失败且清除占位失败:", remErr)
	end
end

--[[
	异步上报 GameAnalytics 收据（失败仅记日志，不影响购买决策）

	@param receiptInfo table - Marketplace 收据；字段同 ProcessReceipt 入参
]]
local function _notifyGameAnalytics(receiptInfo: any)
	task.defer(function()
		local analytics = GameAnalytics
		if not analytics then
			Log.warn("[SystemBuyRoblox] GameAnalytics 不可用，跳过收据上报")
			return
		end

		local gaOk, gaErr = pcall(function()
			analytics:ProcessReceiptCallback(receiptInfo)
		end)
		if not gaOk then
			Log.warn("[SystemBuyRoblox] GameAnalytics ProcessReceipt 失败:", gaErr)
		end
	end)
end

--[[
	服务端写入赠送目标（只收 userId）

	@param player Player - 发起赠送的玩家
	@param targetUserId any - 目标玩家 UserId
	@return boolean - 写入成功为 true；校验失败为 false
]]
local function _onSetGift(player: Player, targetUserId: any): boolean
	if not player or not player.Parent then
		Log.warn("[SystemBuyRoblox] SET_GIFT 无效玩家")
		return false
	end

	local uid = tonumber(targetUserId)
	if not uid then
		Log.warn("[SystemBuyRoblox] SET_GIFT 无效目标:", targetUserId)
		return false
	end
	if uid == player.UserId then
		return false
	end

	local target = Players:GetPlayerByUserId(uid)
	if not target or not target.Parent then
		return false
	end

	local giftObj = _getGiftPlayerObject(player)
	if not giftObj then
		Log.warn("[SystemBuyRoblox] GiftPlayer 实例缺失:", player.UserId)
		return false
	end

	giftObj.Value = target
	return true
end

--[[
	清除赠送目标

	@param player Player - 发起取消的玩家
	@return boolean - 玩家有效为 true
]]
local function _onCancelGift(player: Player): boolean
	if not player or not player.Parent then
		return false
	end

	local giftPlayer = _getGiftPlayerObject(player)
	if giftPlayer then
		giftPlayer.Value = nil
	end
	return true
end

-- ============================================================================
-- 公共函数
-- ============================================================================

--[[
	购买完成后的服务端发货处理（Marketplace 收据、赠送、邮件礼品共用）

	@param plr Player - 接收物品的目标玩家
	@param onlyTag string - CfgFind 商品唯一标签
	@return boolean, string? - 成功 true；失败 false 与 InvalidParam / ConfigNotFound / GrantFailed
]]
function SystemBuyRoblox.BuyItemEnd(plr: Player, onlyTag: string): (boolean, string?)
	if not plr or not onlyTag then
		return false, BuyRobloxErr.InvalidParam
	end

	local cfg = CfgFind.FindCfgByOnlyTag(onlyTag)
	if not cfg then
		Log.warn("[SystemBuyRoblox] 配置表不存在:", onlyTag)
		return false, BuyRobloxErr.ConfigNotFound
	end

	if onlyTag == "OnlineAwardClaimAll" then
		if SystemOnlineAward and SystemOnlineAward.UnlockAllClaimable then
			local unlockOk = SystemOnlineAward.UnlockAllClaimable(plr)
			if unlockOk == true then
				return true
			end
			return false, BuyRobloxErr.GrantFailed
		end
		Log.warn("[SystemBuyRoblox] SystemOnlineAward 不可用，无法处理 OnlineAwardClaimAll")
		return false, BuyRobloxErr.GrantFailed
	end

	if cfg.cost == EnumMgr.RobuxType.GamePass then
		local ok, err = SystemShop.BuyGamePassSuc(plr, cfg.passID)
		if not ok then
			Log.warn("[SystemBuyRoblox] GamePass 发货失败:", plr.UserId, cfg.passID, err)
			return false, BuyRobloxErr.GrantFailed
		end
		TipsModule.NormalTips(plr, "获得GamePass", { { cfg.ZhName } })
		return true
	end

	if type(cfg.itemID) ~= "table" then
		Log.warn("[SystemBuyRoblox] 商品 itemID 无效:", onlyTag)
		return false, BuyRobloxErr.ConfigNotFound
	end

	local showItemIDVt: { number } = {}
	local showItemNumVt: { number } = {}

	for k, v in pairs(cfg.itemID) do
		if v ~= 0 then
			local ok, addOnlyID = SystemBag.AddItems(plr, { v }, { cfg.itemCount[k] })
			if not ok then
				Log.warn("[SystemBuyRoblox] AddItems 失败:", plr.UserId, onlyTag, v, addOnlyID)
				return false, BuyRobloxErr.GrantFailed
			end

			local cfgBoost = CfgFind.FindCfgByID(v, EnumMgr.ItemType.UseItem)
			if type(addOnlyID) == "number" and cfgBoost and cfgBoost["UseScript"] == USE_SCRIPT_ADD_BUFF then
				task.spawn(function()
					SystemBag.UseItem(plr, addOnlyID)
				end)
			end

			local cfgInbagCfg = CfgFind.FindCfgByID(v)
			if cfgInbagCfg and cfg.itemCount[k] and NOT_POP_UI_VT[v] ~= 1 then
				table.insert(showItemIDVt, v)
				table.insert(showItemNumVt, cfg.itemCount[k])
			end
		end
	end

	TipsModule.NormalTips(plr, "成功购买")
	if #showItemIDVt > 0 then
		TipsModule.ShowAwardPop(plr, showItemIDVt, showItemNumVt)
	end

	return true
end

--[[
	处理 GamePass 购买完成回调

	@param player Player - 购买玩家
	@param passID number - GamePass 资产 ID
	@param purchaseSuccess boolean - Roblox 回调是否成功
]]
function SystemBuyRoblox.OnGamePassPurchased(player: Player, passID: number, purchaseSuccess: boolean)
	if not purchaseSuccess or not player or not passID then
		return
	end

	local ok, err = SystemShop.BuyGamePassSuc(player, passID)
	if not ok then
		Log.warn("[SystemBuyRoblox] OnGamePassPurchased 发货失败:", player.UserId, passID, err)
		return
	end

	TipsModule.NormalTips(player, "成功购买")

	local cfg = CfgFind.FindCfgByPassID(passID)
	if cfg then
		_recordRobuxSpend(player, cfg.price)
		if SHOW_REWARD_GAMEPASS[cfg.OnlyTag] == 1 then
			_showGamePassRewardPop(player, cfg)
		end
	end

	task.spawn(function()
		SystemSDK.PayGamePass(player, passID)
	end)
end

--[[
	处理 Developer Product 购买收据（幂等）

	@param receiptInfo table - Marketplace 收据；字段 PlayerId number、ProductId number、PurchaseId string
	@return Enum.ProductPurchaseDecision - PurchaseGranted 已发货或已占位；NotProcessedYet 待重试
]]
function SystemBuyRoblox.ProcessReceipt(receiptInfo: any): Enum.ProductPurchaseDecision
	if not receiptInfo then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local playerProductKey = _buildPurchaseHistoryKey(receiptInfo)
	local getOk, purchased, getErr = SystemDataStore.Get(
		PURCHASE_HISTORY_STORE,
		playerProductKey,
		PURCHASE_LOAD_OPTIONS
	)

	if not getOk then
		Log.warn("[SystemBuyRoblox] PurchaseHistory 读取失败:", getErr)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	if purchased then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	local player: Player? = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not player then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local claimOk, claimedByUs = _claimPurchaseHistory(playerProductKey)
	if not claimOk then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if not claimedByUs then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	local isBuySuc = _handleProductPurchaseSuccess(receiptInfo, player)
	if not isBuySuc then
		_clearPurchaseClaim(playerProductKey)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	_notifyGameAnalytics(receiptInfo)

	task.spawn(function()
		SystemSDK.PayProductItem(player, receiptInfo)
	end)

	return Enum.ProductPurchaseDecision.PurchaseGranted
end

-- ============================================================================
-- 初始化
-- ============================================================================

--[[
	注册购买相关 Remote 与限频（由 PurchaseManager 在 Marketplace 绑定前调用）
]]
function SystemBuyRoblox.Init()
	if _initialized then
		return
	end
	_initialized = true

	if RequestRateLimit and RequestRateLimit.SetRateLimitConfig then
		RequestRateLimit.SetRateLimitConfig(NetMsg.SET_GIFT, {
			maxRequests = RATE_LIMIT_MAX_REQUESTS,
			timeWindow = RATE_LIMIT_WINDOW_SEC,
		})
		RequestRateLimit.SetRateLimitConfig(NetMsg.CANCEL_GIFT, {
			maxRequests = RATE_LIMIT_MAX_REQUESTS,
			timeWindow = RATE_LIMIT_WINDOW_SEC,
		})
	end

	NetWork.RegisterServerRemoteFunction(NetMsg.SET_GIFT, _onSetGift)
	NetWork.RegisterServerRemoteFunction(NetMsg.CANCEL_GIFT, _onCancelGift)
end

return SystemBuyRoblox
