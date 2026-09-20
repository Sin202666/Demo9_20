--[[
	Module: SystemBag-Type
	Description: SystemBag 类型声明（实现见 ServerSideCode/System/SystemBag）
	Author: 林奥宇
	Created: 2026-06-30
	Last Modified: 2026-09-04
]]

local SystemBag = {}

function SystemBag.SetupPlayerBag(plr: Player)
end

--[[
	按唯一 ID 获取背包条目深拷贝（禁止返回存档活引用）
	@param plr Player - 玩家对象
	@param onlyID number - 唯一 ID
	@return table? - 条目深拷贝 { id, tp, count, onlyID, lock?, equip? }；不存在为 nil
]]
function SystemBag.GetItemByOnlyID(plr: Player, onlyID: number)
end

function SystemBag.GetItemCountByID(plr: Player, itemID: number)
end

function SystemBag.AddData(plr: Player, itemData): (boolean, string?)
end

--[[
	批量添加物品（可选容量策略；默认不检满仓，三参调用保持兼容）
	@param plr Player - 玩家对象
	@param itemIDVt {number} - 物品 ID 列表
	@param itemCountVt {number} - 对应数量列表
	@param opts { capacity: string? }? - 可选；capacity 为 GetData.BagCapacity.Capacity 键，默认 None
	@return boolean - 成功 true
	@return number|string? - 成功为最后写入的 onlyID；失败为 INVALID_PLAYER / INVALID_PARAM / INVALID_ITEM / NO_BAG_DATA / BAG_FULL
]]
function SystemBag.AddItems(plr: Player, itemIDVt: { number }, itemCountVt: { number }, opts: { capacity: string? }?): (boolean, number | string?)
end

function SystemBag.CanRemove(plr: Player, onlyIDVt: { number })
end

function SystemBag.RemoveAllItem(plr: Player, itemID: number): (boolean, string?)
end

function SystemBag.RemoveItemByOnlyID(plr: Player, onlyID: number, isIgnoreLock: boolean?): (boolean, string?)
end

function SystemBag.RemoveTradeItem(plr: Player, onlyID: number, itemCount: number): (boolean, any?)
end

function SystemBag.RemoveItem(plr: Player, itemIDVt: { number }, itemCountVt: { number }): (boolean, string?)
end

function SystemBag.LockItem(plr: Player, onlyIDVt: { number }, lockState: boolean): (boolean, string?)
end

function SystemBag.UseItem(plr: Player, onlyID: number, num: number?)
end

--[[
	将 onlyID 装备到快捷栏或卸回仓库（唯一写 Bag.equip）
	@param plr Player - 玩家对象
	@param onlyID number - 背包 onlyID
	@param slot number - 0=仓库，1~N=快捷栏；非 Toolbar 类型上栏失败
	@return boolean - 成功 true
	@return string? - 失败为 INVALID_PLAYER / INVALID_PARAM / NO_BAG_DATA / NOT_FOUND
]]
function SystemBag.SetEquip(plr: Player, onlyID: number, slot: number): (boolean, string?)
end

--[[
	快捷栏两槽互换
	@param plr Player - 玩家对象
	@param slotA number - 槽 A（1~N）
	@param slotB number - 槽 B（1~N）
	@return boolean - 成功 true
	@return string? - 失败 errorCode
]]
function SystemBag.SwapToolbarSlots(plr: Player, slotA: number, slotB: number): (boolean, string?)
end

function SystemBag.InitNewPlayerItemsIfNeeded(plr: Player, isNewFromSave: boolean): boolean
end

function SystemBag.RegisterNetWork()
end

return SystemBag
