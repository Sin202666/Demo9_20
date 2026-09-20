--[[
	Module: GetData.BagCapacity
	Description: 背包堆叠与容量闭集表（服客同一份；加表项扩展，禁止运行时 Register）
	Author: 林奥宇
	Created: 2026-09-04
	Last Modified: 2026-09-04

	功能：
	- Stack.Default：hasCount == EnumMgr.BagStack.Stackable（与历史 BagShared.isStackable 一致）
	- Capacity.None：不检满仓（现网发奖默认）
	- Capacity.Warehouse / Capacity.Pet：预留键，V1 未填 max，不启用拦仓
	- Capacity.Backpack：只统计 Filter.Window 占用；上限读 GameConfig.背包配置.窗口上限
	- Filter.Window：UseItem / Item / Pet / PetEgg / Mount（仓库网格白名单；材料为 Item）
	- Filter.Toolbar：默认仅 UseItem（快捷栏 / 自动上栏；材料不可上栏）
	- Tab：Place 页签名闭集 All / Potion / Material；Potion=全部 UseItem，Material=Item
	- CountSlots / CountWindowOccupancy / GetAddSlotDelta / WouldExceed / WouldExceedBatch：只读计算，不写存档
	- GetToolbarSlotCount：GameConfig.背包配置.工具栏快捷槽数（默认 8）

	与 GetData.BagView / SystemBag.BagPipeline 的关系：
	- 客户端 IsFull / Occupancy 与服务端入包强制都查本表，禁止各写一份上限
	- 查询走 GetData.BagView；入包拒绝只以服 Pipeline 为准
	- GRANT_AWARD 仍 Capacity.None；UI 满不表示服会拦
	- 扩展方式是改本文件表项，不要加运行时 Register、不要在 UI 写死类型

	加载方式（一般由 GetData/init 聚合；服务端 Pipeline 经 Utils.GetData.BagCapacity）：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local GetData = Utils.GetData
		local BagCapacity = GetData.BagCapacity

	使用示例：
		local stackable = BagCapacity.IsStackable(cfg)
		local policy = BagCapacity.ResolvePolicy(nil) -- "None"
		local full = BagCapacity.WouldExceed(bagData, itemId, 1, cfg, BagCapacity.Capacity.None)
		local isWindow = BagCapacity.IsFilterType(BagCapacity.Filter.Window, cfg.tp)
		local isPotionTab = BagCapacity.IsTabType(BagCapacity.Tab.Potion, cfg.tp)
		local slots = BagCapacity.GetToolbarSlotCount()
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local EnumMgr = Utils.EnumMgr
local Copy = Utils.Copy
local CfgFind = Utils.CfgFind
local SystemGameConfig = Utils.SystemGameConfig

local BagCapacity = {}

-- ========================================
-- 常量定义
-- ========================================
local ItemType = EnumMgr.ItemType

local DEFAULT_WINDOW_MAX = 100
local DEFAULT_TOOLBAR_SLOTS = 8
local TOOLBAR_SLOT_MIN = 1
local TOOLBAR_SLOT_HARD_MAX = 9

local GAME_CONFIG_BAG = "背包配置"
local GAME_CONFIG_WINDOW_MAX = "窗口上限"
local GAME_CONFIG_TOOLBAR_SLOTS = "工具栏快捷槽数"

BagCapacity.Stack = table.freeze({
	Default = "Default",
})

BagCapacity.Capacity = table.freeze({
	None = "None",
	Warehouse = "Warehouse",
	Pet = "Pet",
	Backpack = "Backpack",
})

BagCapacity.Filter = table.freeze({
	Window = "Window",
	Toolbar = "Toolbar",
})

-- Place 页签 Frame.Name；禁止用 ItemType 键当页签名（Potion ≠ 新枚举）
BagCapacity.Tab = table.freeze({
	All = "All",
	Potion = "Potion",
	Material = "Material",
})

-- 闭集：有键即合法。max 为 nil 表示不拦（V1 的 None / 未启用预留键）
local CAPACITY_KEYS: { [string]: boolean } = {
	[BagCapacity.Capacity.None] = true,
	[BagCapacity.Capacity.Warehouse] = true,
	[BagCapacity.Capacity.Pet] = true,
	[BagCapacity.Capacity.Backpack] = true,
}

local CAPACITY_MAX: { [string]: number? } = {
	[BagCapacity.Capacity.None] = nil,
	[BagCapacity.Capacity.Warehouse] = nil,
	[BagCapacity.Capacity.Pet] = nil,
	[BagCapacity.Capacity.Backpack] = nil, -- 运行时读 GameConfig
}

-- 闭集类型表：加类型只改这里，禁止 UI 写死 Potion/Material
local FILTER_TYPES: { [string]: { [number]: boolean } } = {
	[BagCapacity.Filter.Window] = {
		[ItemType.UseItem] = true,
		[ItemType.Item] = true,
		[ItemType.Pet] = true,
		[ItemType.PetEgg] = true,
		[ItemType.Mount] = true,
	},
	[BagCapacity.Filter.Toolbar] = {
		[ItemType.UseItem] = true,
	},
}

local TAB_ORDER: { string } = {
	BagCapacity.Tab.All,
	BagCapacity.Tab.Potion,
	BagCapacity.Tab.Material,
}

local TAB_KEYS: { [string]: boolean } = {
	[BagCapacity.Tab.All] = true,
	[BagCapacity.Tab.Potion] = true,
	[BagCapacity.Tab.Material] = true,
}

-- All 不进本表：IsTabType(All) = Filter.Window。Potion=全部 UseItem，Material=Item
local TAB_TYPES: { [string]: { [number]: boolean } } = {
	[BagCapacity.Tab.Potion] = {
		[ItemType.UseItem] = true,
	},
	[BagCapacity.Tab.Material] = {
		[ItemType.Item] = true,
	},
}

-- ========================================
-- 私有函数
-- ========================================

--[[
	Stack.Default：hasCount 等于可叠加枚举

	@param cfg table? - 物品配置行
	@return boolean - 是否可叠加
]]
local function _stackRuleDefault(cfg: any): boolean
	if type(cfg) ~= "table" then
		return false
	end
	return (cfg.hasCount or 0) == EnumMgr.BagStack.Stackable
end

local STACK_RULES: { [string]: (any) -> boolean } = {
	[BagCapacity.Stack.Default] = _stackRuleDefault,
}

--[[
	读 GameConfig 正整数；非法回默认

	@param fieldName string - 背包配置字段名
	@param defaultValue number - 缺省
	@param maxValue number? - 可选上限钳制
	@return number - 钳制后的正整数
]]
local function _readBagConfigInt(fieldName: string, defaultValue: number, maxValue: number?): number
	local raw = SystemGameConfig.GetValue({ GAME_CONFIG_BAG, fieldName })
	local n = tonumber(raw)
	if not n or n <= 0 then
		n = defaultValue
	end
	n = math.floor(n)
	if maxValue and n > maxValue then
		n = maxValue
	end
	return n
end

--[[
	背包字典中是否已有该物品的堆叠格

	@param bagData table? - PlayerData.Bag 形 { [tostring(onlyID)]: { id, count, ... } }
	@param itemId number - 物品 id
	@return boolean - 已有同 id 格为 true
]]
local function _hasStack(bagData: any, itemId: number): boolean
	if type(bagData) ~= "table" then
		return false
	end
	for _, slotData in pairs(bagData) do
		if type(slotData) == "table" and slotData.id == itemId then
			return true
		end
	end
	return false
end

--[[
	单行 Window 占用：可叠用 count，其余 1

	@param entry table - 背包条目
	@param cfg table? - 配置行；缺省时按不可叠计 1
	@return number - 占用值 ≥ 0
]]
local function _windowRowOccupancy(entry: any, cfg: any?): number
	if BagCapacity.IsStackable(cfg) then
		local n = math.floor(tonumber(entry.count) or 0)
		if n < 0 then
			return 0
		end
		return n
	end
	return 1
end

--[[
	把类型集合收成排序后的深拷贝数组

	@param typeSet { [number]: boolean }? - tp → true
	@return { number } - 类型枚举数组
]]
local function _copyTypeList(typeSet: { [number]: boolean }?): { number }
	if not typeSet then
		return {}
	end
	local list = {}
	for tp, flag in pairs(typeSet) do
		if flag then
			table.insert(list, tp)
		end
	end
	table.sort(list)
	return Copy.deepCopy(list)
end

-- ========================================
-- 公共函数
-- ========================================

--[[
	判断配置是否按指定堆叠策略可叠加（省略策略时用 Stack.Default）

	@param cfg table? - 物品配置行，字段含 hasCount: number?
	@param stackName string? - BagCapacity.Stack 键；默认 Default
	@return boolean - 是否可叠加；未知策略或配置无效为 false
]]
function BagCapacity.IsStackable(cfg: any, stackName: string?): boolean
	local name = stackName or BagCapacity.Stack.Default
	local rule = STACK_RULES[name]
	if not rule then
		return false
	end
	return rule(cfg)
end

--[[
	策略名是否在闭集表中

	@param policyName any - 容量策略名
	@return boolean - 是否为已登记键（含未启用的 Warehouse / Pet）
]]
function BagCapacity.HasCapacityPolicy(policyName: any): boolean
	return type(policyName) == "string" and CAPACITY_KEYS[policyName] == true
end

--[[
	把调用方传入的策略名收成闭集键；nil / 空串视为 None

	@param policyName string? - opts.capacity 或查询用策略名
	@return string? - 合法键；未知名为 nil（写口应当 INVALID_PARAM）
]]
function BagCapacity.ResolvePolicy(policyName: string?): string?
	if policyName == nil or policyName == "" then
		return BagCapacity.Capacity.None
	end
	if not BagCapacity.HasCapacityPolicy(policyName) then
		return nil
	end
	return policyName
end

--[[
	读取策略格子上限；nil 表示不检满仓

	@param policyName string? - 容量策略名；非法或省略视为 None
	@return number? - 最大占用格数；不拦为 nil
]]
function BagCapacity.GetMaxSlots(policyName: string?): number?
	local resolved = BagCapacity.ResolvePolicy(policyName)
	if not resolved then
		return nil
	end
	if resolved == BagCapacity.Capacity.Backpack then
		return _readBagConfigInt(GAME_CONFIG_WINDOW_MAX, DEFAULT_WINDOW_MAX, nil)
	end
	return CAPACITY_MAX[resolved]
end

--[[
	快捷栏槽数（Bag.equip 1~N）

	@return number - 槽数，钳制在 1~9
]]
function BagCapacity.GetToolbarSlotCount(): number
	local n = _readBagConfigInt(GAME_CONFIG_TOOLBAR_SLOTS, DEFAULT_TOOLBAR_SLOTS, TOOLBAR_SLOT_HARD_MAX)
	if n < TOOLBAR_SLOT_MIN then
		return TOOLBAR_SLOT_MIN
	end
	return n
end

--[[
	equip 是否落在快捷栏 1~N

	@param equip any - Bag.equip
	@return boolean - 在栏为 true
]]
function BagCapacity.IsToolbarEquipSlot(equip: any): boolean
	local eq = tonumber(equip) or 0
	if eq < TOOLBAR_SLOT_MIN then
		return false
	end
	return eq <= BagCapacity.GetToolbarSlotCount()
end

--[[
	条目 tp 是否属于闭集 Filter

	@param filterName string - BagCapacity.Filter 键
	@param tp any - 物品类型
	@return boolean - 属于该 Filter 为 true
]]
function BagCapacity.IsFilterType(filterName: string, tp: any): boolean
	local set = FILTER_TYPES[filterName]
	if not set then
		return false
	end
	local numTp = tonumber(tp)
	if not numTp then
		return false
	end
	return set[numTp] == true
end

--[[
	闭集 Filter 的类型列表深拷贝（禁止返回活引用）

	@param filterName string - BagCapacity.Filter 键
	@return { number } - 类型枚举数组；未知 Filter 为空表
]]
function BagCapacity.GetFilterTypes(filterName: string): { number }
	return _copyTypeList(FILTER_TYPES[filterName])
end

--[[
	页签 id 是否在 Tabs 闭集中

	@param tabId any - Place 页签 Frame.Name
	@return boolean - 已登记为 true
]]
function BagCapacity.HasTab(tabId: any): boolean
	return type(tabId) == "string" and TAB_KEYS[tabId] == true
end

--[[
	页签 id 列表深拷贝（展示顺序：All / Potion / Material）

	@return { string } - 闭集页签 id
]]
function BagCapacity.GetTabIds(): { string }
	return Copy.deepCopy(TAB_ORDER)
end

--[[
	条目 tp 是否属于该页签（All = Filter.Window）

	@param tabId string - BagCapacity.Tab 键
	@param tp any - 物品类型
	@return boolean - 属于该页签为 true；未知 tab 为 false
]]
function BagCapacity.IsTabType(tabId: string, tp: any): boolean
	if not BagCapacity.HasTab(tabId) then
		return false
	end
	if tabId == BagCapacity.Tab.All then
		return BagCapacity.IsFilterType(BagCapacity.Filter.Window, tp)
	end
	local set = TAB_TYPES[tabId]
	if not set then
		return false
	end
	local numTp = tonumber(tp)
	if not numTp then
		return false
	end
	return set[numTp] == true
end

--[[
	页签类型列表深拷贝；All 返回 Window 类型

	@param tabId string - BagCapacity.Tab 键
	@return { number } - 类型枚举数组；未知 tab 为空表
]]
function BagCapacity.GetTabTypes(tabId: string): { number }
	if not BagCapacity.HasTab(tabId) then
		return {}
	end
	if tabId == BagCapacity.Tab.All then
		return BagCapacity.GetFilterTypes(BagCapacity.Filter.Window)
	end
	return _copyTypeList(TAB_TYPES[tabId])
end

--[[
	统计背包当前占用格数（字典条目数，含 count==0 的残留格）

	@param bagData table? - PlayerData.Bag 字典
	@return number - 占用格数；无效表为 0
]]
function BagCapacity.CountSlots(bagData: any): number
	if type(bagData) ~= "table" then
		return 0
	end
	local used = 0
	for _, slotData in pairs(bagData) do
		if type(slotData) == "table" then
			used += 1
		end
	end
	return used
end

--[[
	Window 白名单占用（可叠按 count，其余一行 1；含已上栏行）

	@param bagData table? - PlayerData.Bag 字典
	@param cfgById ((number) -> any)? - 可选；省略时不查配置，不可叠按 1
	@return number - 占用值
]]
function BagCapacity.CountWindowOccupancy(bagData: any, cfgById: ((number) -> any)?): number
	if type(bagData) ~= "table" then
		return 0
	end
	local used = 0
	for _, entry in pairs(bagData) do
		if type(entry) == "table" and BagCapacity.IsFilterType(BagCapacity.Filter.Window, entry.tp) then
			local cfg = nil
			local itemId = tonumber(entry.id)
			if itemId then
				if cfgById then
					cfg = cfgById(itemId)
				else
					cfg = CfgFind.FindCfgByID(itemId, entry.tp)
				end
			end
			used += _windowRowOccupancy(entry, cfg)
		end
	end
	return used
end

--[[
	策略占用：Backpack 走 Window 占用，其余走字典格数

	@param bagData table? - PlayerData.Bag 字典
	@param policyName string? - 容量策略名
	@param cfgById ((number) -> any)? - Backpack 占用查配置用；可省略
	@return number - 占用值
]]
function BagCapacity.CountOccupancy(bagData: any, policyName: string?, cfgById: ((number) -> any)?): number
	local resolved = BagCapacity.ResolvePolicy(policyName)
	if resolved == BagCapacity.Capacity.Backpack then
		return BagCapacity.CountWindowOccupancy(bagData, cfgById)
	end
	return BagCapacity.CountSlots(bagData)
end

--[[
	加入一批数量后相对当前占用会新增的格子数（堆叠进已有格为 0）

	@param bagData table? - 当前 Bag 字典
	@param itemId number - 物品 id
	@param addCount number - 计划加入数量
	@param cfg table? - 物品配置行
	@param pendingNewStacks { [number]: boolean }? - 同批次已记入的新建堆叠；可省略
	@return number - 新增格数（≥0）
]]
function BagCapacity.GetAddSlotDelta(
	bagData: any,
	itemId: number,
	addCount: number,
	cfg: any,
	pendingNewStacks: { [number]: boolean }?
): number
	if type(cfg) ~= "table" or type(itemId) ~= "number" then
		return 0
	end
	local count = tonumber(addCount) or 0
	if BagCapacity.IsStackable(cfg) then
		if (pendingNewStacks and pendingNewStacks[itemId]) or _hasStack(bagData, itemId) then
			return 0
		end
		return 1
	end
	if count < 0 then
		return 0
	end
	return math.floor(count)
end

--[[
	Backpack 策略：加入后 Window 占用增量（非 Window 类型为 0）

	@param bagData table? - 当前 Bag 字典
	@param itemId number - 物品 id
	@param addCount number - 计划加入数量
	@param cfg table? - 物品配置行
	@return number - 占用增量（≥0）
]]
function BagCapacity.GetAddWindowOccupancyDelta(bagData: any, itemId: number, addCount: number, cfg: any): number
	if type(cfg) ~= "table" then
		return 0
	end
	if not BagCapacity.IsFilterType(BagCapacity.Filter.Window, cfg.tp) then
		return 0
	end
	local count = math.floor(tonumber(addCount) or 0)
	if count <= 0 then
		return 0
	end
	if BagCapacity.IsStackable(cfg) then
		return count
	end
	return count
end

--[[
	单次加入是否会超过策略上限（max 为 nil 时永不超）

	@param bagData table? - 当前 Bag 字典
	@param itemId number - 物品 id
	@param addCount number - 计划加入数量
	@param cfg table? - 物品配置行
	@param policyName string? - 容量策略名
	@return boolean - 会超限为 true
]]
function BagCapacity.WouldExceed(
	bagData: any,
	itemId: number,
	addCount: number,
	cfg: any,
	policyName: string?
): boolean
	local maxSlots = BagCapacity.GetMaxSlots(policyName)
	if type(maxSlots) ~= "number" then
		return false
	end
	local resolved = BagCapacity.ResolvePolicy(policyName)
	if resolved == BagCapacity.Capacity.Backpack then
		local used = BagCapacity.CountWindowOccupancy(bagData)
		local delta = BagCapacity.GetAddWindowOccupancyDelta(bagData, itemId, addCount, cfg)
		return (used + delta) > maxSlots
	end
	local used = BagCapacity.CountSlots(bagData)
	local delta = BagCapacity.GetAddSlotDelta(bagData, itemId, addCount, cfg)
	return (used + delta) > maxSlots
end

--[[
	批量加入是否会超过策略上限（先模拟整批再判定，避免写一半）

	@param bagData table? - 当前 Bag 字典
	@param items { { id: number, count: number, cfg: any } } - 仅含已有配置的项
	@param policyName string? - 容量策略名
	@return boolean - 会超限为 true
]]
function BagCapacity.WouldExceedBatch(bagData: any, items: { any }, policyName: string?): boolean
	local maxSlots = BagCapacity.GetMaxSlots(policyName)
	if type(maxSlots) ~= "number" then
		return false
	end
	if type(items) ~= "table" then
		return false
	end

	local resolved = BagCapacity.ResolvePolicy(policyName)
	if resolved == BagCapacity.Capacity.Backpack then
		local extra = 0
		for _, item in ipairs(items) do
			if type(item) == "table" and type(item.cfg) == "table" then
				local itemId = tonumber(item.id)
				if itemId then
					extra += BagCapacity.GetAddWindowOccupancyDelta(bagData, itemId, item.count, item.cfg)
				end
			end
		end
		return (BagCapacity.CountWindowOccupancy(bagData) + extra) > maxSlots
	end

	local extra = 0
	local pendingNewStacks: { [number]: boolean } = {}
	for _, item in ipairs(items) do
		if type(item) == "table" and type(item.cfg) == "table" then
			local itemId = tonumber(item.id)
			local addCount = tonumber(item.count) or 0
			if itemId then
				local delta = BagCapacity.GetAddSlotDelta(bagData, itemId, addCount, item.cfg, pendingNewStacks)
				extra += delta
				if BagCapacity.IsStackable(item.cfg) and delta == 1 then
					pendingNewStacks[itemId] = true
				end
			end
		end
	end
	return (BagCapacity.CountSlots(bagData) + extra) > maxSlots
end

return BagCapacity
