--[[
	Module: GetData.BagView
	Description: 背包只读视图（Query / Occupancy / IsFull / ToSlotVM / 仓库与快捷栏查询）
	Author: 林奥宇
	Created: 2026-09-04
	Last Modified: 2026-09-04

	功能：
	- Query：从玩家或 Bag 表切出条目深拷贝列表；Filter.ByType / AllShowInBag / Window / Toolbar / WarehouseGrid
	- Occupancy / IsFull：只读闭集表 BagCapacity；不信客户端满仓结论
	- QueryWarehouse：Window 且 equip 不在 1~N；可选类型页签与译名搜索
	- QueryToolbarSlot / GetFirstFreeToolbarSlot：栏位查询
	- ShouldRefreshToolbarOnPlayerDataSync / ShouldRefreshWarehouseOnPlayerDataSync：差量刷新判定
	- ToSlotVM：格子展示字段 id/tp/count/onlyID/lock/equip，深拷贝
	- MatchesSearch：译名子串；失败不回退中文键

	与 GetData.Bag / Entry 的关系：
	- Bag 按物品 id 读数量；Entry 按 onlyID 查单条+配置；本模块按视图切列表与占用
	- Filter.AllShowInBag 可留作查询，不要当任何背包窗的默认数据源（会铺开堆叠货币）
	- 窗默认数据源用 Filter.WarehouseGrid；栏用 QueryToolbarSlot
	- 禁止返回 PlayerData.Bag 活引用；入包拒绝只以服 Pipeline 为准
	- 搜索走 TranslateByKey(ZhName)；失败不回退中文键

	加载方式（由 GetData/init 聚合）：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local GetData = Utils.GetData
		local BagView = GetData.BagView

	使用示例：
		local list = BagView.Query(plr, BagView.Filter.WarehouseGrid)
		local occ = BagView.Occupancy(plr, GetData.BagCapacity.Capacity.Backpack)
		local vm = BagView.ToSlotVM(list[1])
		local slotItem = BagView.QueryToolbarSlot(plr, 1)
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local PlayerData = Utils.PlayerData
local CfgFind = Utils.CfgFind
local Copy = Utils.Copy
local EnumMgr = Utils.EnumMgr
local TranslationHelper = Utils.TranslationHelper

local BagCapacity = require(script.Parent.BagCapacity)

local BagView = {}

-- ========================================
-- 常量定义
-- ========================================
local SAVE_KEY_BAG = "Bag"
local UNLOCALIZED_PREFIX = "未本地化-"

-- ========================================
-- 私有函数
-- ========================================

--[[
	按物品类型过滤（返回谓词，交给 Query）

	@param tp number - 物品类型，对齐 EnumMgr.ItemType / 条目 tp
	@return (any) -> boolean - 匹配该 tp 的条目谓词
]]
local function _filterByType(tp: number): (any) -> boolean
	return function(entry: any): boolean
		return type(entry) == "table" and entry.tp == tp
	end
end

--[[
	配置 isShow == InBag 的条目（不是任何窗的默认数据源）

	@param entry table - 背包条目，字段含 id / tp
	@return boolean - 是否在背包中展示
]]
local function _filterAllShowInBag(entry: any): boolean
	if type(entry) ~= "table" or entry.id == nil then
		return false
	end
	local cfg = CfgFind.FindCfgByID(entry.id, entry.tp)
	return cfg ~= nil and cfg.isShow == EnumMgr.BagShow.InBag
end

--[[
	窗白名单类型

	@param entry table - 背包条目
	@return boolean - Filter.Window 为 true
]]
local function _filterWindow(entry: any): boolean
	return type(entry) == "table" and BagCapacity.IsFilterType(BagCapacity.Filter.Window, entry.tp)
end

--[[
	栏白名单类型

	@param entry table - 背包条目
	@return boolean - Filter.Toolbar 为 true
]]
local function _filterToolbar(entry: any): boolean
	return type(entry) == "table" and BagCapacity.IsFilterType(BagCapacity.Filter.Toolbar, entry.tp)
end

--[[
	仓库网格：Window 且未上栏

	@param entry table - 背包条目
	@return boolean - 进仓库网格为 true
]]
local function _filterWarehouseGrid(entry: any): boolean
	if not _filterWindow(entry) then
		return false
	end
	return not BagCapacity.IsToolbarEquipSlot(entry.equip)
end

--[[
	闭集 Filter（加表项扩展，禁止运行时 Register）
	- ByType(tp)：返回按条目 tp 匹配的谓词
	- AllShowInBag：isShow == InBag；不要当任何背包窗的默认数据源
	- Window / Toolbar：BagCapacity.Filter 白名单
	- WarehouseGrid：Window 且 equip 不在 1~N
]]
BagView.Filter = table.freeze({
	ByType = _filterByType,
	AllShowInBag = _filterAllShowInBag,
	Window = _filterWindow,
	Toolbar = _filterToolbar,
	WarehouseGrid = _filterWarehouseGrid,
})

--[[
	把 Player 或 Bag 表收成字典引用（只读遍历，调用方不得写回）

	@param bagCopyOrPlr Player | table - 玩家对象或 Bag 字典/拷贝
	@return table? - Bag 字典；无效为 nil
]]
local function _resolveBag(bagCopyOrPlr: any): any?
	if typeof(bagCopyOrPlr) == "Instance" and bagCopyOrPlr:IsA("Player") then
		local bagData = PlayerData.GetPlrDataByKey(bagCopyOrPlr, SAVE_KEY_BAG)
		if type(bagData) ~= "table" then
			return nil
		end
		return bagData
	end
	if type(bagCopyOrPlr) == "table" then
		return bagCopyOrPlr
	end
	return nil
end

--[[
	解析 PLAYER_DATA_SYNC 路径是否落在 Bag

	@param key string | { string }? - 同步路径
	@return string?, string? - onlyKey、subKey
]]
local function _parseBagSyncKey(key: string | { string }?): (string?, string?)
	if key == nil or key == SAVE_KEY_BAG then
		return nil, nil
	end
	if type(key) ~= "table" or key[1] ~= SAVE_KEY_BAG then
		return nil, nil
	end
	local onlyKey = key[2]
	if type(onlyKey) ~= "string" then
		return nil, nil
	end
	local subKey = key[3]
	if type(subKey) == "string" then
		return onlyKey, subKey
	end
	return onlyKey, nil
end

-- ========================================
-- 公共函数
-- ========================================

--[[
	译名搜索：TranslateByKey(ZhName) 子串；失败（未本地化/空）不回退中文键

	@param entry table - 背包条目
	@param searchText string? - 搜索原文；nil/空串视为全匹配
	@return boolean - 命中为 true
]]
function BagView.MatchesSearch(entry: any, searchText: string?): boolean
	local needle = string.lower(searchText or "")
	if needle == "" then
		return true
	end
	if type(entry) ~= "table" or entry.id == nil then
		return false
	end
	local cfg = CfgFind.FindCfgByID(entry.id, entry.tp)
	if not cfg or type(cfg.ZhName) ~= "string" or cfg.ZhName == "" then
		return false
	end
	local name = TranslationHelper.TranslateByKey(cfg.ZhName)
	if type(name) ~= "string" or name == "" then
		return false
	end
	if string.sub(name, 1, #UNLOCALIZED_PREFIX) == UNLOCALIZED_PREFIX then
		return false
	end
	return string.find(string.lower(name), needle, 1, true) ~= nil
end

--[[
	from 玩家或 Bag 表查出条目深拷贝列表（按 onlyID 升序）

	@param bagCopyOrPlr Player | table - 玩家对象，或已有 Bag 字典（不会写回）
	@param filter ((any) -> boolean)? - 谓词；nil 表示不过滤
	@return { table } - 条目深拷贝数组；无效输入为空表
]]
function BagView.Query(bagCopyOrPlr: any, filter: ((any) -> boolean)?): { any }
	local bagData = _resolveBag(bagCopyOrPlr)
	if not bagData then
		return {}
	end

	local filterFn = if type(filter) == "function" then filter else nil
	local list = {}
	for _, entry in pairs(bagData) do
		if type(entry) == "table" then
			if not filterFn or filterFn(entry) then
				table.insert(list, Copy.deepCopy(entry))
			end
		end
	end

	table.sort(list, function(a, b)
		return (tonumber(a.onlyID) or 0) < (tonumber(b.onlyID) or 0)
	end)
	return list
end

--[[
	仓库网格查询：Window 且未上栏；可选类型页签与译名搜索

	@param bagCopyOrPlr Player | table - 玩家或 Bag 字典
	@param tabTp number? - 页签类型；nil 表示 All
	@param searchText string? - 译名子串；空为不过滤
	@return { table } - 条目深拷贝数组
]]
function BagView.QueryWarehouse(bagCopyOrPlr: any, tabTp: number?, searchText: string?): { any }
	local wantTp = tonumber(tabTp)
	return BagView.Query(bagCopyOrPlr, function(entry: any): boolean
		if not _filterWarehouseGrid(entry) then
			return false
		end
		if wantTp and entry.tp ~= wantTp then
			return false
		end
		return BagView.MatchesSearch(entry, searchText)
	end)
end

--[[
	读取快捷栏某槽物品（须 Toolbar 类型且 equip==slot）

	@param bagCopyOrPlr Player | table - 玩家或 Bag 字典
	@param slotIndex number - 槽 1~N
	@return table? - 条目深拷贝；空槽或非法为 nil
]]
function BagView.QueryToolbarSlot(bagCopyOrPlr: any, slotIndex: number): any?
	local slot = tonumber(slotIndex) or 0
	if not BagCapacity.IsToolbarEquipSlot(slot) then
		return nil
	end
	local bagData = _resolveBag(bagCopyOrPlr)
	if not bagData then
		return nil
	end
	for _, entry in pairs(bagData) do
		if type(entry) == "table" and _filterToolbar(entry) and tonumber(entry.equip) == slot then
			return Copy.deepCopy(entry)
		end
	end
	return nil
end

--[[
	第一个空快捷槽；无空位为 0

	@param bagCopyOrPlr Player | table - 玩家或 Bag 字典
	@return number - 空槽 1~N；无空位 0
]]
function BagView.GetFirstFreeToolbarSlot(bagCopyOrPlr: any): number
	local bagData = _resolveBag(bagCopyOrPlr)
	local used: { [number]: boolean } = {}
	if type(bagData) == "table" then
		for _, entry in pairs(bagData) do
			if type(entry) == "table" and _filterToolbar(entry) then
				local eq = tonumber(entry.equip) or 0
				if BagCapacity.IsToolbarEquipSlot(eq) then
					used[eq] = true
				end
			end
		end
	end
	local n = BagCapacity.GetToolbarSlotCount()
	for i = 1, n do
		if not used[i] then
			return i
		end
	end
	return 0
end

--[[
	只读占用：当前格数与策略上限（上限 nil 表示不检满仓）

	@param plr Player - 玩家对象
	@param policyName string? - BagCapacity.Capacity 键；nil 视为 None
	@return table - 深拷贝 { used: number, max: number? }
]]
function BagView.Occupancy(plr: Player, policyName: string?): { [string]: any }
	local bagData = nil
	if typeof(plr) == "Instance" and plr:IsA("Player") then
		bagData = PlayerData.GetPlrDataByKey(plr, SAVE_KEY_BAG)
	end
	return Copy.deepCopy({
		used = BagCapacity.CountOccupancy(bagData, policyName, function(itemId: number): any
			return CfgFind.FindCfgByID(itemId)
		end),
		max = BagCapacity.GetMaxSlots(policyName),
	})
end

--[[
	只读：加入 1 个该物品是否会满（策略无上限则为 false）

	@param plr Player - 玩家对象
	@param itemId number - 物品 id
	@param policyName string? - BagCapacity.Capacity 键；nil 视为 None
	@return boolean - 视为满仓为 true；玩家/配置无效为 false（不是满仓）
]]
function BagView.IsFull(plr: Player, itemId: number, policyName: string?): boolean
	if typeof(plr) ~= "Instance" or not plr:IsA("Player") then
		return false
	end
	local numItemId = tonumber(itemId)
	if not numItemId then
		return false
	end
	local cfg = CfgFind.FindCfgByID(numItemId)
	if not cfg then
		return false
	end
	local bagData = PlayerData.GetPlrDataByKey(plr, SAVE_KEY_BAG)
	return BagCapacity.WouldExceed(bagData, numItemId, 1, cfg, policyName)
end

--[[
	条目 → 格子 VM（id/tp/count/onlyID/lock/equip），深拷贝

	@param entry table - 背包条目或已有拷贝
	@return table? - VM 深拷贝；entry 无效为 nil
]]
function BagView.ToSlotVM(entry: any): { [string]: any }?
	if type(entry) ~= "table" then
		return nil
	end
	return Copy.deepCopy({
		id = entry.id,
		tp = entry.tp,
		count = entry.count,
		onlyID = entry.onlyID,
		lock = entry.lock,
		equip = entry.equip,
	})
end

--[[
	PLAYER_DATA_SYNC 是否应刷新快捷栏

	@param key string | { string }? - 同步路径
	@param value any - 同步值
	@param plr Player? - 玩家；可省略
	@param toolbarCachedOnlyIds { [number]: number }? - 槽 → onlyID 缓存
	@return boolean - 需要刷新为 true
]]
function BagView.ShouldRefreshToolbarOnPlayerDataSync(
	key: string | { string }?,
	value: any,
	plr: Player?,
	toolbarCachedOnlyIds: { [number]: number }?
): boolean
	if key == nil or key == SAVE_KEY_BAG then
		return true
	end
	local onlyKey, subKey = _parseBagSyncKey(key)
	if not onlyKey then
		return false
	end
	if subKey == "equip" then
		return true
	end
	local onlyID = tonumber(onlyKey) or 0
	if type(toolbarCachedOnlyIds) == "table" then
		for _, cached in toolbarCachedOnlyIds do
			if cached == onlyID then
				return true
			end
		end
	end
	if value == nil and subKey == nil then
		return onlyID > 0
	end
	local row = if type(value) == "table" then value else nil
	if not row and typeof(plr) == "Instance" then
		local bag = PlayerData.GetPlrDataByKey(plr, SAVE_KEY_BAG)
		row = type(bag) == "table" and bag[onlyKey]
	end
	if type(row) ~= "table" then
		return false
	end
	return _filterToolbar(row) or BagCapacity.IsToolbarEquipSlot(row.equip)
end

--[[
	PLAYER_DATA_SYNC 是否应刷新仓库网格

	@param key string | { string }? - 同步路径
	@param value any - 同步值
	@param plr Player? - 玩家；可省略
	@param _toolbarCachedOnlyIds { [number]: number }? - 预留
	@param warehouseCachedOnlyIds { [number]: boolean }? - 仓库 onlyID 缓存
	@return boolean - 需要刷新为 true
]]
function BagView.ShouldRefreshWarehouseOnPlayerDataSync(
	key: string | { string }?,
	value: any,
	plr: Player?,
	_toolbarCachedOnlyIds: { [number]: number }?,
	warehouseCachedOnlyIds: { [number]: boolean }?
): boolean
	if key == nil or key == SAVE_KEY_BAG then
		return true
	end
	local onlyKey, subKey = _parseBagSyncKey(key)
	if not onlyKey then
		return false
	end
	if subKey == "equip" or subKey == "lock" or subKey == "count" then
		return true
	end
	local onlyID = tonumber(onlyKey) or 0
	if type(warehouseCachedOnlyIds) == "table" and warehouseCachedOnlyIds[onlyID] then
		return true
	end
	if value == nil and subKey == nil then
		return onlyID > 0
	end
	local row = if type(value) == "table" then value else nil
	if not row and typeof(plr) == "Instance" then
		local bag = PlayerData.GetPlrDataByKey(plr, SAVE_KEY_BAG)
		row = type(bag) == "table" and bag[onlyKey]
	end
	if type(row) ~= "table" then
		return false
	end
	return _filterWindow(row)
end

return BagView
