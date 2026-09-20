--[[
	Module: PurchaseManager
	Description: 购买管理器（服务端），绑定 MarketplaceService 并路由至 SystemBuyRoblox
	Author: 林奥宇
	Created: 2026-07-03
	Last Modified: 2026-09-01

	功能：
	- 绑定 PromptGamePassPurchaseFinished → SystemBuyRoblox.OnGamePassPurchased
	- 设置 ProcessReceipt（全局唯一）→ SystemBuyRoblox.ProcessReceipt
	- 启动时调用 SystemBuyRoblox.Init 注册 SET_GIFT / CANCEL_GIFT

	与 SystemBuyRoblox / SystemShop / SystemSDK 的关系：
	- 本模块仅做 Marketplace 回调编排，不含发货、收据去重等业务逻辑
	- 发货与 PurchaseHistory 幂等由 SystemBuyRoblox 负责
	- GameAnalytics / SDK 统计由 SystemBuyRoblox 在发货成功后异步调用

	约束：
	- 本文件为服务端 Script，由引擎自动运行，禁止被其他模块 require
	- MarketplaceService.ProcessReceipt 全服只能赋值一次，勿在其他脚本重复设置
	- 须先 Init 再绑 Marketplace，确保赠送 Remote 先于收据回调可用
	- ProcessReceipt 仅回传 PurchaseGranted / NotProcessedYet；其它值一律改回 NotProcessedYet 以便 Roblox 重试

	加载方式：
		本脚本位于 ServerScriptService/InitGame/Manager，服务器启动时自动运行。
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local SystemBuyRoblox = Utils.SystemBuyRoblox

	示例（引擎执行本脚本时的顺序，勿从其它模块再绑一次）：
		SystemBuyRoblox.Init()
		MarketplaceService.PromptGamePassPurchaseFinished:Connect(_onGamePassPurchaseFinished)
		MarketplaceService.ProcessReceipt = _onProcessReceipt
]]

-- ============================================================================
-- 服务引用
-- ============================================================================

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local MarketplaceService = Utils.MarketplaceService

-- ============================================================================
-- 模块引用
-- ============================================================================

local Log = Utils.Log
local SystemBuyRoblox = Utils.SystemBuyRoblox

-- ============================================================================
-- 常量定义
-- ============================================================================

local DECISION_NOT_PROCESSED = Enum.ProductPurchaseDecision.NotProcessedYet
local DECISION_GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted

-- ============================================================================
-- 私有函数
-- ============================================================================

--[[
	GamePass 购买完成回调：校验玩家与资产 ID 后转发至 SystemBuyRoblox；异常仅记日志

	@param player Player - Roblox 回调给出的购买玩家
	@param passID number - GamePass 资产 ID，须为正数
	@param purchaseSuccess boolean - 本次 Prompt 是否购买成功
	@return nil
]]
local function _onGamePassPurchaseFinished(player: Player, passID: number, purchaseSuccess: boolean)
	if not player or not player:IsA("Player") then
		return
	end
	if typeof(passID) ~= "number" or passID <= 0 then
		Log.warn("[PurchaseManager] OnGamePassPurchased passID 无效:", passID)
		return
	end
	if purchaseSuccess ~= true then
		return
	end

	local ok, err = pcall(SystemBuyRoblox.OnGamePassPurchased, player, passID, purchaseSuccess)
	if not ok then
		Log.warn("[PurchaseManager] OnGamePassPurchased 异常:", err)
	end
end

--[[
	Developer Product 收据回调：转发至 SystemBuyRoblox；异常或非法返回值一律 NotProcessedYet 以便 Roblox 重试

	@param receiptInfo table - Marketplace 收据；须含 PlayerId number、ProductId number、PurchaseId string
	@return Enum.ProductPurchaseDecision - PurchaseGranted 已处理；NotProcessedYet 待重试
]]
local function _onProcessReceipt(receiptInfo: any): Enum.ProductPurchaseDecision
	if typeof(receiptInfo) ~= "table" then
		Log.warn("[PurchaseManager] ProcessReceipt 收据无效")
		return DECISION_NOT_PROCESSED
	end

	local ok, result = pcall(SystemBuyRoblox.ProcessReceipt, receiptInfo)
	if not ok then
		Log.warn("[PurchaseManager] ProcessReceipt 异常:", result)
		return DECISION_NOT_PROCESSED
	end

	if result ~= DECISION_GRANTED and result ~= DECISION_NOT_PROCESSED then
		Log.warn("[PurchaseManager] ProcessReceipt 返回值非法:", result)
		return DECISION_NOT_PROCESSED
	end

	return result
end

--[[
	绑定 Marketplace 回调。ProcessReceipt 全服只能由一个脚本赋值。

	@return nil
]]
local function _bindMarketplaceCallbacks()
	if not MarketplaceService then
		Log.warn("[PurchaseManager] MarketplaceService 未就绪，跳过回调绑定")
		return
	end
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(_onGamePassPurchaseFinished)

	-- ProcessReceipt 只能赋值、不能读取；无法检测是否已被其他脚本占用
	MarketplaceService.ProcessReceipt = _onProcessReceipt
end

-- ============================================================================
-- 启动
-- ============================================================================

local initOk, initErr = pcall(SystemBuyRoblox.Init)
if not initOk then
	Log.warn("[PurchaseManager] SystemBuyRoblox.Init 异常:", initErr)
end

_bindMarketplaceCallbacks()
