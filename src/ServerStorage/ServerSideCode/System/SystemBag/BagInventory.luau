--[[
	Module: BagInventory
	Description: 背包物品增删查核心逻辑（AddItems 走 BagPipeline；成功后 Toolbar 空槽自动上栏）
	Author: 林奥宇
	Created: 2026-06-30
	Last Modified: 2026-09-04
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local PlayerData = Utils.PlayerData
local CfgFind = Utils.CfgFind
local Log = Utils.Log
local Copy = Utils.Copy
local NetMsg = Utils.NetMsg
local NetWork = Utils.NetWork

local BagShared = require(script.Parent.BagShared)
local BagValueSync = require(script.Parent.BagValueSync)
local BagPipeline = require(script.Parent.BagPipeline)
local BagEquip = require(script.Parent.BagEquip)

-- ========================================
-- 模块定义
-- ========================================
local BagInventory = {}

-- ========================================
-- 私有函数
-- ========================================

--[[
	按物品 ID 扣除指定数量（内部实现）

	@param plr Player - 玩家对象
	@param itemID number - 物品 ID
	@param itemCount number? - 数量，默认 1
	@return boolean, string? - 成功 true；失败 false 与 errorCode
]]
local function _removeItemByIDCount(plr: Player, itemID: number, itemCount: number?): (boolean, string?)
	if tostring(itemCount) == "nan" then
		return false, BagShared.ERROR_INVALID_PARAM
	end

	local numItemID = tonumber(itemID) :: number?
	local numItemCount = tonumber(itemCount) :: number?

	if not numItemID or not numItemCount then
		return false, BagShared.ERROR_INVALID_PARAM
	end

	itemID = numItemID
	itemCount = numItemCount

	if not BagShared.validatePlayer(plr) or itemID == 0 then
		return false, BagShared.ERROR_INVALID_PLAYER
	end

	if itemCount < 0 then
		return false, BagShared.ERROR_INVALID_PARAM
	end

	local bagData = BagShared.getBagData(plr)
	if not bagData then
		return false, BagShared.ERROR_NO_BAG_DATA
	end

	local cfg = CfgFind.FindCfgByID(itemID)
	if not cfg then
		Log.warn("没有这个物品的配置表:", itemID)
		return false, BagShared.ERROR_INVALID_ITEM
	end

	if BagShared.isStackable(cfg) then
		for slotKey, slotData in bagData do
			if slotData.id == itemID then
				local nowCount = bagData[slotKey].count - itemCount
				if nowCount <= 0 then
					PlayerData.ChangePlrData(plr, { "Bag", slotKey }, nil)
				else
					PlayerData.ChangePlrData(plr, { "Bag", slotKey, "count" }, nowCount)
				end
				break
			end
		end
	else
		local delNum = itemCount
		for slotKey, slotData in bagData do
			if delNum <= 0 then
				break
			end
			if slotData.id == itemID then
				delNum -= 1
				PlayerData.ChangePlrData(plr, { "Bag", slotKey }, nil)
			end
		end
	end

	NetWork.FireBindable(NetMsg.RECORD_ITEM_REMOVE, { plr, itemID, itemCount })
	BagValueSync.update(plr)
	return true
end

-- ========================================
-- 公共函数
-- ========================================

--[[
	按唯一 ID 获取背包条目深拷贝（禁止返回存档活引用）

	@param plr Player - 玩家对象
	@param onlyID number - 唯一 ID
	@return table? - 条目深拷贝 { id, tp, count, onlyID, lock?, equip? }；不存在为 nil
]]
function BagInventory.GetItemByOnlyID(plr: Player, onlyID: number)
	if not BagShared.validatePlayer(plr) or not onlyID or onlyID == 0 then
		return nil
	end

	local bagData = BagShared.getBagData(plr)
	if not bagData then
		return nil
	end

	local row = bagData[tostring(onlyID)]
	if type(row) ~= "table" then
		return nil
	end
	return Copy.deepCopy(row)
end

--[[
	获取玩家拥有某物品的数量

	@param plr Player - 玩家对象
	@param itemID number - 物品 ID
	@return number - 数量
]]
function BagInventory.GetItemCountByID(plr: Player, itemID: number): number
	local numItemID = tonumber(itemID)
	if not numItemID or not BagShared.validatePlayer(plr) or numItemID == 0 then
		return 0
	end

	itemID = numItemID

	local bagData = BagShared.getBagData(plr)
	if not bagData then
		return 0
	end

	local cfg = CfgFind.FindCfgByID(itemID)
	if not cfg then
		Log.warn("没有这个物品的配置表:", itemID)
		return 0
	end

	if BagShared.isStackable(cfg) then
		for _, slotData in bagData do
			if slotData.id == itemID then
				return slotData.count
			end
		end
		return 0
	end

	local hasNum = 0
	for _, slotData in bagData do
		if slotData.id == itemID then
			hasNum += 1
		end
	end
	return hasNum
end

--[[
	直接写入完整背包条目数据（绕过 BagPipeline：不检满仓、不自动上栏）

	@param plr Player - 玩家对象
	@param itemData table - 条目数据 { id, tp?, count?, lock? }；onlyID 由本函数重新分配
	@return boolean, string? - 成功 true；失败 false 与 INVALID_PLAYER / INVALID_PARAM / NO_BAG_DATA
]]
function BagInventory.AddData(plr: Player, itemData): (boolean, string?)
	if not BagShared.validatePlayer(plr) then
		return false, BagShared.ERROR_INVALID_PLAYER
	end
	if type(itemData) ~= "table" then
		return false, BagShared.ERROR_INVALID_PARAM
	end

	local plrData = PlayerData.GetPlrData(plr)
	if not plrData then
		return false, BagShared.ERROR_NO_BAG_DATA
	end

	local bagData = plrData.Bag
	if not bagData then
		return false, BagShared.ERROR_NO_BAG_DATA
	end

	local newOnlyID = BagShared.getOnlyID(plr)
	local itemCopy = Copy.deepCopy(itemData)
	itemCopy.onlyID = newOnlyID
	PlayerData.ChangePlrData(plr, { "Bag", tostring(newOnlyID) }, itemCopy)
	Log.print("直接存数据进背包:" .. plr.DisplayName, itemCopy.id)
	BagValueSync.update(plr)
	return true
end

--[[
	批量添加物品（可选容量策略；默认不检满仓，三参调用保持兼容）

	@param plr Player - 玩家对象
	@param itemIDVt {number} - 物品 ID 列表
	@param itemCountVt {number} - 对应数量列表
	@param opts { capacity: string? }? - 可选；capacity 为 GetData.BagCapacity.Capacity 键，默认 None
	@return boolean, number|string? - 成功 true 与最后写入的 onlyID；失败 false 与 INVALID_PLAYER / INVALID_PARAM / INVALID_ITEM / NO_BAG_DATA / BAG_FULL
]]
function BagInventory.AddItems(
	plr: Player,
	itemIDVt: { number },
	itemCountVt: { number },
	opts: { capacity: string? }?
): (boolean, number | string?)
	local ok, lastOrErr, newOnlyIds = BagPipeline.AddItems(plr, itemIDVt, itemCountVt, opts)
	if ok then
		BagEquip.TryAutoEquipNewItems(plr, newOnlyIds)
	end
	return ok, lastOrErr
end

--[[
	清空玩家背包中某物品 ID 的全部数量

	@param plr Player - 玩家对象
	@param itemID number - 物品 ID
	@return boolean, string? - 成功 true；失败 false 与 INVALID_PLAYER / NO_BAG_DATA / INVALID_ITEM
]]
function BagInventory.RemoveAllItem(plr: Player, itemID: number): (boolean, string?)
	if not BagShared.validatePlayer(plr) or not itemID or itemID == 0 then
		return false, BagShared.ERROR_INVALID_PLAYER
	end

	local bagData = BagShared.getBagData(plr)
	if not bagData then
		return false, BagShared.ERROR_NO_BAG_DATA
	end

	local cfg = CfgFind.FindCfgByID(itemID)
	if not cfg then
		Log.warn("没有这个物品的配置表:", itemID)
		return false, BagShared.ERROR_INVALID_ITEM
	end

	if BagShared.isStackable(cfg) then
		for slotKey, slotData in bagData do
			if slotData.id == itemID then
				PlayerData.ChangePlrData(plr, { "Bag", slotKey }, nil)
				break
			end
		end
	else
		for slotKey, slotData in bagData do
			if slotData.id == itemID then
				PlayerData.ChangePlrData(plr, { "Bag", slotKey }, nil)
			end
		end
	end

	BagValueSync.update(plr)
	return true
end

--[[
	按唯一 ID 删除背包条目

	@param plr Player - 玩家对象
	@param onlyID number - 唯一 ID
	@param isIgnoreLock boolean? - 是否忽略锁定
	@return boolean, string? - 成功 true；失败 false 与 INVALID_PLAYER / NO_BAG_DATA / NOT_FOUND / ITEM_LOCKED
]]
function BagInventory.RemoveItemByOnlyID(plr: Player, onlyID: number, isIgnoreLock: boolean?): (boolean, string?)
	if not BagShared.validatePlayer(plr) then
		return false, BagShared.ERROR_INVALID_PLAYER
	end

	local bagData = BagShared.getBagData(plr)
	if not bagData then
		return false, BagShared.ERROR_NO_BAG_DATA
	end

	local slotKey = tostring(onlyID)
	local itemData = bagData[slotKey]
	if not itemData then
		return false, BagShared.ERROR_NOT_FOUND
	end

	if not isIgnoreLock and BagShared.isItemLocked(itemData) then
		return false, BagShared.ERROR_ITEM_LOCKED
	end

	PlayerData.ChangePlrData(plr, { "Bag", slotKey }, nil)
	BagValueSync.update(plr)
	return true
end

--[[
	批量扣除多种物品（先校验数量再扣除）

	@param plr Player - 玩家对象
	@param itemIDVt {number} - 物品 ID 列表
	@param itemCountVt {number} - 对应数量列表
	@return boolean, string? - 成功 true；失败 false 与 INVALID_PARAM / INSUFFICIENT_COUNT / INVALID_ITEM
]]
function BagInventory.RemoveItem(plr: Player, itemIDVt: { number }, itemCountVt: { number }): (boolean, string?)
	if type(itemIDVt) ~= "table" or type(itemCountVt) ~= "table" then
		return false, BagShared.ERROR_INVALID_PARAM
	end

	for index, itemID in itemIDVt do
		if tostring(itemCountVt[index]) == "nan" then
			return false, BagShared.ERROR_INVALID_PARAM
		end

		local itemCount = tonumber(itemCountVt[index])
		itemID = tonumber(itemID)
		if not itemID or not itemCount then
			return false, BagShared.ERROR_INVALID_PARAM
		end
		local itemHasNum: number = BagInventory.GetItemCountByID(plr, itemID)
		if itemHasNum < itemCount then
			return false, BagShared.ERROR_INSUFFICIENT
		end
	end

	for index, itemID in itemIDVt do
		local itemCount = tonumber(itemCountVt[index])
		itemID = tonumber(itemID)
		local ok, err = _removeItemByIDCount(plr, itemID, itemCount)
		if not ok then
			return false, err
		end
	end

	return true
end

return BagInventory
