local module = {}

--[[
	按 onlyTag 发起 Roblox 购买 Prompt（仅客户端 SystemBuyRoblox 提供）

	@param plr Player - 发起购买的玩家
	@param onlyTag string - CfgFind 商品唯一标签
	@return boolean - 已发起购买流程为 true
]]
function module.BuyRobloxByOnlyTag(plr: Player, onlyTag: string): boolean
end

--[[
	请求服务端写入赠送目标（仅客户端 SystemBuyRoblox 提供）

	@param targetPlr Player - 收礼玩家
	@return boolean - 服写入成功为 true
]]
function module.SetGiftTarget(targetPlr: Player): boolean
end

--[[
	购买完成后的服务端发货（仅服务端 SystemBuyRoblox 提供）

	@param plr Player - 接收物品的玩家
	@param onlyTag string - CfgFind 商品唯一标签
	@return boolean, string? - 成功 true；失败 false 与 EnumMgr.BuyRobloxErr
]]
function module.BuyItemEnd(plr: Player, onlyTag: string): (boolean, string?)
end

--[[
	处理 GamePass 购买完成（仅服务端 SystemBuyRoblox 提供）

	@param player Player - 购买玩家
	@param passID number - GamePass 资产 ID
	@param purchaseSuccess boolean - Roblox 回调是否成功
]]
function module.OnGamePassPurchased(player: Player, passID: number, purchaseSuccess: boolean)
end

--[[
	处理 Developer Product 购买收据（仅服务端 SystemBuyRoblox 提供）

	@param receiptInfo table - Marketplace 收据；字段 PlayerId number、ProductId number、PurchaseId string
	@return Enum.ProductPurchaseDecision - PurchaseGranted 已发货；NotProcessedYet 待重试
]]
function module.ProcessReceipt(receiptInfo: any): Enum.ProductPurchaseDecision
end

--[[
	注册购买相关 Remote（仅服务端 SystemBuyRoblox 提供；由 PurchaseManager 启动时调用）
]]
function module.Init()
end

return module
