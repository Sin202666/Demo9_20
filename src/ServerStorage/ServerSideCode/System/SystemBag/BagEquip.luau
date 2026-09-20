--[[
	Module: BagEquip
	Description: SystemBag 快捷栏 equip 唯一写口（SetEquip / 互换 / 新获得自动上栏）
	Author: 林奥宇
	Created: 2026-09-04
	Last Modified: 2026-09-04

	功能：
	- SetEquip(plr, onlyID, slot)：slot 0 卸回仓库，1~N 上栏；清冲突；仅 Filter.Toolbar 可上栏
	- SwapToolbarSlots：栏内互换，仍只写 Bag.equip
	- TryAutoEquipNewItems：入包新建行后，仅 Toolbar 类型填空槽
	- equip 不等于坐骑召唤 / 宠物出战，本模块不调 Mount / Pet

	与 BagPipeline / SystemBagToolbar 的关系：
	- Pipeline 只负责入包；自动上栏由 Inventory 在成功后调本模块
	- SystemBagToolbar 拖拽只调 SetEquip / SwapToolbarSlots
	- 禁止 Gui 与其它 System 直接 ChangePlrData(Bag.equip)

	加载方式（仅 SystemBag 内部）：
		local BagEquip = require(script.Parent.BagEquip)
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local PlayerData = Utils.PlayerData
local GetData = Utils.GetData
local Log = Utils.Log

local BagShared = require(script.Parent.BagShared)

local BagCapacity = GetData.BagCapacity
local BagView = GetData.BagView

local BagEquip = {}

-- ========================================
-- 常量定义
-- ========================================
local EQUIP_WAREHOUSE = 0

-- ========================================
-- 私有函数
-- ========================================

--[[
	按 onlyID 取背包键与行

	@param bagData table - Bag 字典
	@param onlyID number - 唯一 ID
	@return string?, table? - 键与行
]]
local function _findEntry(bagData: any, onlyID: number): (string?, any?)
	local key = tostring(onlyID)
	local row = bagData[key]
	if type(row) == "table" then
		return key, row
	end
	return nil, nil
end

--[[
	按 equip 槽找 Toolbar 行键

	@param bagData table - Bag 字典
	@param equipSlot number - 槽 1~N
	@return string? - 键
]]
local function _findKeyByEquip(bagData: any, equipSlot: number): string?
	for bagKey, row in pairs(bagData) do
		if type(row) == "table"
			and BagCapacity.IsFilterType(BagCapacity.Filter.Toolbar, row.tp)
			and tonumber(row.equip) == equipSlot
		then
			return tostring(bagKey)
		end
	end
	return nil
end

--[[
	写 equip 字段

	@param plr Player - 玩家
	@param bagKey string - Bag 键
	@param slot number - 0 或 1~N
	@return nil
]]
local function _writeEquip(plr: Player, bagKey: string, slot: number)
	PlayerData.ChangePlrData(plr, { "Bag", bagKey, "equip" }, slot)
end

-- ========================================
-- 公共函数
-- ========================================

--[[
	将 onlyID 装备到槽或卸回仓库（唯一写 Bag.equip）

	@param plr Player - 玩家对象
	@param onlyID number - 背包 onlyID
	@param slot number - 0=仓库，1~N=快捷栏
	@return boolean, string? - 成功 true；失败 false 与 INVALID_PLAYER / INVALID_PARAM / NO_BAG_DATA / NOT_FOUND
]]
function BagEquip.SetEquip(plr: Player, onlyID: number, slot: number): (boolean, string?)
	if not BagShared.validatePlayer(plr) then
		return false, BagShared.ERROR_INVALID_PLAYER
	end
	local numOnly = tonumber(onlyID)
	local numSlot = tonumber(slot)
	if not numOnly or not numSlot then
		return false, BagShared.ERROR_INVALID_PARAM
	end
	numOnly = math.floor(numOnly)
	numSlot = math.floor(numSlot)
	if numOnly <= 0 then
		return false, BagShared.ERROR_INVALID_PARAM
	end
	if numSlot ~= EQUIP_WAREHOUSE and not BagCapacity.IsToolbarEquipSlot(numSlot) then
		return false, BagShared.ERROR_INVALID_PARAM
	end

	local bagData = BagShared.getBagData(plr)
	if not bagData then
		return false, BagShared.ERROR_NO_BAG_DATA
	end

	local bagKey, row = _findEntry(bagData, numOnly)
	if not bagKey or type(row) ~= "table" then
		return false, BagShared.ERROR_NOT_FOUND
	end

	if numSlot ~= EQUIP_WAREHOUSE then
		if not BagCapacity.IsFilterType(BagCapacity.Filter.Toolbar, row.tp) then
			Log.warn("[BagEquip.SetEquip] refuse non-toolbar type", plr.UserId, row.tp, numOnly)
			return false, BagShared.ERROR_INVALID_PARAM
		end
		local occupantKey = _findKeyByEquip(bagData, numSlot)
		if occupantKey and occupantKey ~= bagKey then
			_writeEquip(plr, occupantKey, EQUIP_WAREHOUSE)
		end
	end

	_writeEquip(plr, bagKey, numSlot)
	return true
end

--[[
	快捷栏两槽互换（空槽视为把对方卸到该空位）

	@param plr Player - 玩家对象
	@param slotA number - 槽 A
	@param slotB number - 槽 B
	@return boolean, string? - 成功 true；失败 false 与 errorCode
]]
function BagEquip.SwapToolbarSlots(plr: Player, slotA: number, slotB: number): (boolean, string?)
	if not BagShared.validatePlayer(plr) then
		return false, BagShared.ERROR_INVALID_PLAYER
	end
	local a = math.floor(tonumber(slotA) or 0)
	local b = math.floor(tonumber(slotB) or 0)
	if a == b then
		return true
	end
	if not BagCapacity.IsToolbarEquipSlot(a) or not BagCapacity.IsToolbarEquipSlot(b) then
		return false, BagShared.ERROR_INVALID_PARAM
	end

	local bagData = BagShared.getBagData(plr)
	if not bagData then
		return false, BagShared.ERROR_NO_BAG_DATA
	end

	local keyA = _findKeyByEquip(bagData, a)
	local keyB = _findKeyByEquip(bagData, b)
	if keyA then
		_writeEquip(plr, keyA, b)
	end
	if keyB then
		_writeEquip(plr, keyB, a)
	end
	return true
end

--[[
	新获得行尝试自动上栏（仅 Toolbar 类型 + 空槽）

	@param plr Player - 玩家对象
	@param newOnlyIds { number }? - 本次新建 onlyID
	@return nil
]]
function BagEquip.TryAutoEquipNewItems(plr: Player, newOnlyIds: { number }?): ()
	if type(newOnlyIds) ~= "table" or not BagShared.validatePlayer(plr) then
		return
	end
	local bagData = BagShared.getBagData(plr)
	if not bagData then
		return
	end
	for _, onlyID in ipairs(newOnlyIds) do
		local numOnly = tonumber(onlyID)
		if numOnly and numOnly > 0 then
			local _, row = _findEntry(bagData, numOnly)
			if type(row) == "table"
				and BagCapacity.IsFilterType(BagCapacity.Filter.Toolbar, row.tp)
				and not BagCapacity.IsToolbarEquipSlot(row.equip)
			then
				local freeSlot = BagView.GetFirstFreeToolbarSlot(plr)
				if freeSlot > 0 then
					BagEquip.SetEquip(plr, numOnly, freeSlot)
					bagData = BagShared.getBagData(plr)
					if not bagData then
						return
					end
				else
					return
				end
			end
		end
	end
end

return BagEquip
