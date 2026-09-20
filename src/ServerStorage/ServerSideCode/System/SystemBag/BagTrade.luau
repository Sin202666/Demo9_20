--[[
	Module: BagTrade
	Description: 背包物品锁定与交易扣除
	Author: 林奥宇
	Created: 2026-06-30
	Last Modified: 2026-08-31
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local PlayerData = Utils.PlayerData
local CfgFind = Utils.CfgFind
local Log = Utils.Log
local Copy = Utils.Copy
local EnumMgr = Utils.EnumMgr

local BagShared = require(script.Parent.BagShared)
local BagValueSync = require(script.Parent.BagValueSync)
local BagInventory = require(script.Parent.BagInventory)

-- ========================================
-- 模块定义
-- ========================================
local BagTrade = {}

-- ========================================
-- 公共函数
-- ========================================

--[[
	检查 onlyID 列表中的物品是否均可删除（未锁定且存在）

	@param plr Player - 玩家对象
	@param onlyIDVt {number} - 唯一 ID 列表
	@return boolean - 全部可删除时返回 true
]]
function BagTrade.CanRemove(plr: Player, onlyIDVt: { number }): boolean
	for _, onlyID in onlyIDVt do
		local data = BagInventory.GetItemByOnlyID(plr, onlyID)
		if data == nil then
			return false
		end
		if BagShared.isItemLocked(data) then
			return false
		end
	end

	return true
end

--[[
	交易扣除：按 onlyID 扣除数量并返回拷贝条目

	@param plr Player - 玩家对象
	@param onlyID number - 唯一 ID
	@param itemCount number - 扣除数量，须 > 0 且不超过持有
	@return boolean, table|string? - 成功 true 与条目拷贝 { id, tp, count, onlyID, lock? }；失败 false 与 errorCode
]]
function BagTrade.RemoveTradeItem(plr: Player, onlyID: number, itemCount: number): (boolean, any?)
	local numOnlyID = tonumber(onlyID) :: number?
	local numItemCount = tonumber(itemCount) :: number?

	if not numOnlyID or not numItemCount then
		return false, BagShared.ERROR_INVALID_PARAM
	end

	onlyID = numOnlyID
	itemCount = numItemCount

	if not BagShared.validatePlayer(plr) or onlyID == 0 then
		return false, BagShared.ERROR_INVALID_PLAYER
	end

	if itemCount < 1 then
		return false, BagShared.ERROR_INVALID_PARAM
	end

	local bagData = BagShared.getBagData(plr)
	if not bagData then
		return false, BagShared.ERROR_NO_BAG_DATA
	end

	local itemData = bagData[tostring(onlyID)]
	if not itemData then
		return false, BagShared.ERROR_NOT_FOUND
	end

	if BagShared.isItemLocked(itemData) then
		return false, BagShared.ERROR_ITEM_LOCKED
	end

	local cfg = CfgFind.FindCfgByID(itemData.id)
	if not cfg then
		Log.warn("没有这个物品的配置表:", itemData.id)
		return false, BagShared.ERROR_INVALID_ITEM
	end

	if not cfg.isTrade or cfg.isTrade == EnumMgr.BagTrade.NotTradeable then
		return false, BagShared.ERROR_NOT_TRADEABLE
	end

	if itemData.count < itemCount then
		return false, BagShared.ERROR_INSUFFICIENT
	end

	local nowCount = itemData.count - itemCount
	local newCopy = Copy.deepCopy(itemData)
	newCopy.count = itemCount

	local slotKey = tostring(onlyID)
	if nowCount <= 0 then
		PlayerData.ChangePlrData(plr, { "Bag", slotKey }, nil)
	else
		PlayerData.ChangePlrData(plr, { "Bag", slotKey, "count" }, nowCount)
	end

	BagValueSync.update(plr)
	return true, newCopy
end

--[[
	批量设置物品锁定状态

	@param plr Player - 玩家对象
	@param onlyIDVt {number} - 唯一 ID 列表
	@param lockState boolean - 是否锁定
	@return boolean, string? - 成功 true；失败 false 与 INVALID_PLAYER / NO_BAG_DATA
]]
function BagTrade.LockItem(plr: Player, onlyIDVt: { number }, lockState: boolean): (boolean, string?)
	if not BagShared.validatePlayer(plr) then
		return false, BagShared.ERROR_INVALID_PLAYER
	end

	local bagData = BagShared.getBagData(plr)
	if not bagData then
		return false, BagShared.ERROR_NO_BAG_DATA
	end

	local lockValue = BagShared.toLockValue(lockState)
	for _, onlyID in onlyIDVt do
		local onlyKey = tostring(onlyID)
		if bagData[onlyKey] then
			PlayerData.ChangePlrData(plr, { "Bag", onlyKey, "lock" }, lockValue)
		end
	end

	BagValueSync.update(plr)
	return true
end

return BagTrade
