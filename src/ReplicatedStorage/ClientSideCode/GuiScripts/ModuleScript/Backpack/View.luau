--[[
	Module: BackpackView
	Description: 背包 UI 只读查询与乐观 overlay（不写 PlayerData）
	Author: 林奥宇
	Created: 2026-09-04
	Last Modified: 2026-09-04

	功能：
	- overlay：onlyID→equip / lock；权威同步后由 Core 清除
	- 服拒绝或超时未同步则回滚 overlay
	- 仓库/栏查询叠 overlay 后交给 Core 渲染
	- queryWarehouseDisplay：按 BagCapacity.Tab（All / Potion / Material）筛选

	加载：
		local View = require(script.Parent.View)
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local EnumMgr = Utils.EnumMgr
local GetData = Utils.GetData
local LocalPlayer = Utils.LocalPlayer

local BagView = GetData.BagView
local BagCapacity = GetData.BagCapacity

local BackpackView = {}

-- ========================================
-- 常量定义
-- ========================================
local OVERLAY_ROLLBACK_SEC = 2
local EQUIP_WAREHOUSE = 0

-- ========================================
-- 私有变量
-- ========================================
local overlayEquip: { [number]: number } = {}
local overlayLock: { [number]: number } = {}
local overlayGeneration = 0
local onRollback: (() -> ())? = nil

-- ========================================
-- 私有函数
-- ========================================

--[[
	overlay 是否仍有未对齐权威的字段

	@return boolean - 非空为 true
]]
local function _hasOverlay(): boolean
	return next(overlayEquip) ~= nil or next(overlayLock) ~= nil
end

--[[
	按 onlyID 在 Window 有效列表中取条目

	@param onlyID number - onlyID
	@param list { table } - 已叠 overlay 的 Window 列表
	@return table?
]]
local function _findByOnlyId(onlyID: number, list: { any }): any?
	for _, entry in ipairs(list) do
		if tonumber(entry.onlyID) == onlyID then
			return entry
		end
	end
	return nil
end

--[[
	把 overlay 叠到条目拷贝上（不写 PlayerData）

	@param entry table - BagView 深拷贝
	@return table - 同一张表（已改拷贝字段）
]]
local function _applyOverlay(entry: any): any
	local onlyID = tonumber(entry.onlyID) or 0
	if onlyID <= 0 then
		return entry
	end
	local eq = overlayEquip[onlyID]
	if eq ~= nil then
		entry.equip = eq
	end
	local lockVal = overlayLock[onlyID]
	if lockVal ~= nil then
		entry.lock = lockVal
	end
	return entry
end

-- ========================================
-- 公共函数
-- ========================================

--[[
	权威到达或超时回滚时清空 overlay

	@return nil
]]
function BackpackView.clearOverlay(): ()
	table.clear(overlayEquip)
	table.clear(overlayLock)
end

--[[
	设置 overlay 超时回滚回调（刷新 UI）

	@param callback (() -> ())? - 回滚后刷新
	@return nil
]]
function BackpackView.setOnRollback(callback: (() -> ())?): ()
	onRollback = callback
end

--[[
	单条锁定 overlay

	@param onlyID number - onlyID
	@param lockVal number - EnumMgr.BagLock
	@return nil
]]
function BackpackView.setLockOverlay(onlyID: number, lockVal: number): ()
	if onlyID > 0 then
		overlayLock[onlyID] = lockVal
	end
end

--[[
	全窗锁定 overlay

	@param wantLock boolean - true 锁 / false 解锁
	@return nil
]]
function BackpackView.setLockAllOverlay(wantLock: boolean): ()
	local lockVal = if wantLock then EnumMgr.BagLock.Locked else EnumMgr.BagLock.Unlocked
	for _, entry in ipairs(BackpackView.queryWindowEffective()) do
		local oid = tonumber(entry.onlyID) or 0
		if oid > 0 then
			overlayLock[oid] = lockVal
		end
	end
end

--[[
	Window 条目 + overlay

	@return { table } - 深拷贝列表
]]
function BackpackView.queryWindowEffective(): { any }
	local list = BagView.Query(LocalPlayer, BagView.Filter.Window)
	for _, entry in ipairs(list) do
		_applyOverlay(entry)
	end
	return list
end

--[[
	仓库展示列表（页签 + 译名搜索）

	@param tabId string? - BagCapacity.Tab 键；nil 为 All
	@param searchText string? - 搜索原文
	@return { table }
]]
function BackpackView.queryWarehouseDisplay(tabId: string?, searchText: string?): { any }
	local resolvedTab = tabId or BagCapacity.Tab.All
	local result = {}
	for _, entry in ipairs(BackpackView.queryWindowEffective()) do
		if not BagCapacity.IsToolbarEquipSlot(entry.equip) then
			if BagCapacity.IsTabType(resolvedTab, entry.tp) then
				if BagView.MatchesSearch(entry, searchText) then
					table.insert(result, entry)
				end
			end
		end
	end
	return result
end

--[[
	快捷栏某槽当前展示物品（含 overlay）

	@param slotIndex number - 槽 1~N
	@return table? - 条目
]]
function BackpackView.getToolbarItemAtSlot(slotIndex: number): any?
	local slot = tonumber(slotIndex) or 0
	for _, entry in ipairs(BackpackView.queryWindowEffective()) do
		if BagCapacity.IsFilterType(BagCapacity.Filter.Toolbar, entry.tp) and tonumber(entry.equip) == slot then
			return entry
		end
	end
	return nil
end

--[[
	仓库 onlyID 是否允许上栏（Filter.Toolbar）

	@param onlyID number - onlyID
	@return boolean - 可上栏为 true
]]
function BackpackView.canDropOnToolbar(onlyID: number): boolean
	local numOnly = tonumber(onlyID) or 0
	if numOnly <= 0 then
		return false
	end
	local entry = _findByOnlyId(numOnly, BackpackView.queryWindowEffective())
	if type(entry) ~= "table" then
		return false
	end
	return BagCapacity.IsFilterType(BagCapacity.Filter.Toolbar, entry.tp)
end

--[[
	乐观拖拽 overlay；非 Toolbar 类型拒绝上栏。超时仍有 overlay 则回滚。

	@param from table - 起点
	@param to table - 落点
	@return boolean - 已应用为 true；非法拖拽 false
]]
function BackpackView.applyOptimisticDrag(
	from: { zone: string, equipSlot: number?, onlyID: number? },
	to: { zone: string, equipSlot: number?, onlyID: number? }
): boolean
	if type(from) ~= "table" or type(to) ~= "table" then
		return false
	end

	local zoneToolbar = EnumMgr.BagDragZone.Toolbar
	local zoneWarehouse = EnumMgr.BagDragZone.Warehouse
	local effective = BackpackView.queryWindowEffective()

	local function findOnlyIdByEquip(slot: number): number
		for _, entry in ipairs(effective) do
			if BagCapacity.IsFilterType(BagCapacity.Filter.Toolbar, entry.tp) and tonumber(entry.equip) == slot then
				return tonumber(entry.onlyID) or 0
			end
		end
		return 0
	end

	if from.zone == zoneWarehouse and to.zone == zoneToolbar then
		local onlyID = tonumber(from.onlyID) or 0
		if not BackpackView.canDropOnToolbar(onlyID) then
			return false
		end
	end

	overlayGeneration += 1
	local gen = overlayGeneration

	if from.zone == zoneToolbar and to.zone == zoneToolbar then
		local slotA = tonumber(from.equipSlot) or 0
		local slotB = tonumber(to.equipSlot) or 0
		local idA = findOnlyIdByEquip(slotA)
		local idB = findOnlyIdByEquip(slotB)
		if idA > 0 then
			overlayEquip[idA] = slotB
		end
		if idB > 0 then
			overlayEquip[idB] = slotA
		end
	elseif from.zone == zoneToolbar and to.zone == zoneWarehouse then
		local idA = findOnlyIdByEquip(tonumber(from.equipSlot) or 0)
		if idA > 0 then
			overlayEquip[idA] = EQUIP_WAREHOUSE
		end
	elseif from.zone == zoneWarehouse and to.zone == zoneToolbar then
		local onlyID = tonumber(from.onlyID) or 0
		local slot = tonumber(to.equipSlot) or 0
		if onlyID > 0 and BagCapacity.IsToolbarEquipSlot(slot) then
			local kicked = findOnlyIdByEquip(slot)
			if kicked > 0 then
				overlayEquip[kicked] = EQUIP_WAREHOUSE
			end
			overlayEquip[onlyID] = slot
		end
	else
		overlayGeneration -= 1
		return false
	end

	task.delay(OVERLAY_ROLLBACK_SEC, function()
		if gen ~= overlayGeneration then
			return
		end
		if not _hasOverlay() then
			return
		end
		overlayGeneration += 1
		BackpackView.clearOverlay()
		if onRollback then
			onRollback()
		end
	end)

	return true
end

return BackpackView
