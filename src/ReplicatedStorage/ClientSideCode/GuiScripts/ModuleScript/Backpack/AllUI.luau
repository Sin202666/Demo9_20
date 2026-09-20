--[[
	Module: BackpackAllUI
	Description: Main.Backpack 节点收集（工具栏常态 + 仓库详细层同树；页签名对齐 Filter 类型键）
	Author: 林奥宇
	Created: 2026-09-04
	Last Modified: 2026-09-04

	功能：
	- collect(main)：从 ScreenGui.Main.Backpack 取 工具栏 / 仓库 / 页签 / 锁定
	- findSlotButton：根 GuiButton 或子级 Button
	- 页签：All + Filter.Window 类型名（UseItem / Pet / PetEgg / Mount）；缺节点不自建

	Place 节点约定（缺则 collect 失败或对应功能跳过，禁止 Instance.new 整窗）：
	- Main.Backpack
	- Backpack.工具栏 / Temp
	- Backpack.仓库 / ScrollingFrame / Temp
	- 仓库.容量.Size、仓库.搜索（可选 TextBox）、仓库.页签.{All,UseItem,Pet,PetEgg,Mount}
	- 仓库.锁定 / 锁定状态 / 锁定全部 / 解锁全部 / 回退（可选）
	- 仓库.拖动替换区（可选）

	加载：
		local AllUI = require(script.Parent.AllUI)
		local refs = AllUI.collect(main)
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local GetData = Utils.GetData
local EnumMgr = Utils.EnumMgr
local Log = Utils.Log

local BagCapacity = GetData.BagCapacity

local BackpackAllUI = {}

export type LockUiRefs = {
	root: Frame,
	listLayout: UIListLayout?,
	statusFrame: Frame,
	lockAllFrame: Frame,
	unlockAllFrame: Frame,
	backFrame: Frame,
}

export type BackpackUiRefs = {
	root: Frame,
	warehouse: Frame,
	warehouseScroll: ScrollingFrame,
	warehouseTemp: GuiObject,
	capacitySize: TextLabel?,
	searchBox: TextBox?,
	tabContainer: Frame?,
	tabFrames: { [string]: Frame },
	dragReplaceZone: Frame?,
	toolbar: Frame,
	toolbarTemp: GuiObject,
	lockUi: LockUiRefs?,
}

--[[
	按名取指定 Class 子级

	@param parent Instance - 父级
	@param name string - 子级 Name
	@param className string - 期望 Class
	@return Instance? - 命中；否则 nil
]]
local function _childOfClass(parent: Instance, name: string, className: string): Instance?
	local child = parent:FindFirstChild(name)
	if child and child:IsA(className) then
		return child
	end
	return nil
end

--[[
	ItemType 枚举值 → 键名（与页签 Frame.Name 对齐）

	@param tp number - ItemType
	@return string? - 键名
]]
function BackpackAllUI.itemTypeName(tp: number): string?
	for name, value in EnumMgr.ItemType do
		if value == tp then
			return name
		end
	end
	return nil
end

--[[
	解析槽位点击/拖拽热区（根 GuiButton 或子级 Button）

	@param slot GuiObject - 槽 UI 或页签根
	@param context string? - 日志上下文
	@return GuiButton? - 可绑定按钮；不符合约定 nil
]]
function BackpackAllUI.findSlotButton(slot: GuiObject, context: string?): GuiButton?
	if slot:IsA("GuiButton") then
		return slot
	end
	local named = slot:FindFirstChild("Button")
	if named and named:IsA("GuiButton") then
		return named
	end
	Log.warn("[BackpackAllUI] slot button missing (need GuiButton root or child Button)", context or slot.Name, slot:GetFullName())
	return nil
end

--[[
	收集仓库锁定区（缺节点不阻断其它功能）

	@param warehouse Frame - 仓库根
	@return LockUiRefs? - 锁定区引用
]]
local function _collectLockUi(warehouse: Frame): LockUiRefs?
	local lockRoot = _childOfClass(warehouse, "锁定", "Frame") :: Frame?
	if not lockRoot then
		return nil
	end
	local statusFrame = _childOfClass(lockRoot, "锁定状态", "Frame") :: Frame?
	local lockAllFrame = _childOfClass(lockRoot, "锁定全部", "Frame") :: Frame?
	local unlockAllFrame = _childOfClass(lockRoot, "解锁全部", "Frame") :: Frame?
	local backFrame = _childOfClass(lockRoot, "回退", "Frame") :: Frame?
	if not statusFrame or not lockAllFrame or not unlockAllFrame or not backFrame then
		Log.warn("[BackpackAllUI] 锁定子节点不完整", lockRoot:GetFullName())
		return nil
	end
	local listLayout = lockRoot:FindFirstChildOfClass("UIListLayout")
	return {
		root = lockRoot,
		listLayout = listLayout,
		statusFrame = statusFrame,
		lockAllFrame = lockAllFrame,
		unlockAllFrame = unlockAllFrame,
		backFrame = backFrame,
	}
end

--[[
	从 Main.Backpack 收集引用

	@param main Frame - ScreenGui.Main
	@return BackpackUiRefs? - 缺必要节点为 nil
]]
function BackpackAllUI.collect(main: Frame): BackpackUiRefs?
	local backpackRoot = _childOfClass(main, "Backpack", "Frame") :: Frame?
	if not backpackRoot then
		Log.warn("[BackpackAllUI] Main.Backpack 缺失 — Place 需含工具栏+仓库 Temp")
		return nil
	end

	local warehouse = _childOfClass(backpackRoot, "仓库", "Frame") :: Frame?
	local toolbar = _childOfClass(backpackRoot, "工具栏", "Frame") :: Frame?
	if not warehouse or not toolbar then
		Log.warn("[BackpackAllUI] 仓库或工具栏缺失", backpackRoot:GetFullName())
		return nil
	end

	local warehouseScroll = _childOfClass(warehouse, "ScrollingFrame", "ScrollingFrame") :: ScrollingFrame?
	local warehouseTemp = if warehouseScroll then warehouseScroll:FindFirstChild("Temp") :: GuiObject? else nil
	if warehouseTemp and not warehouseTemp:IsA("GuiObject") then
		warehouseTemp = nil
	end
	local toolbarTemp = toolbar:FindFirstChild("Temp") :: GuiObject?
	if toolbarTemp and not toolbarTemp:IsA("GuiObject") then
		toolbarTemp = nil
	end
	if not warehouseScroll or not warehouseTemp or not toolbarTemp then
		Log.warn("[BackpackAllUI] Temp / ScrollingFrame 缺失", backpackRoot:GetFullName())
		return nil
	end

	local capacityFrame = _childOfClass(warehouse, "容量", "Frame") :: Frame?
	local capacitySize = if capacityFrame then _childOfClass(capacityFrame, "Size", "TextLabel") :: TextLabel? else nil
	local searchFrame = _childOfClass(warehouse, "搜索", "Frame") :: Frame?
	local searchBox = if searchFrame then searchFrame:FindFirstChildWhichIsA("TextBox", true) :: TextBox? else nil
	local tabContainer = _childOfClass(warehouse, "页签", "Frame") :: Frame?
	local dragReplaceZone = _childOfClass(warehouse, "拖动替换区", "Frame") :: Frame?

	local tabFrames: { [string]: Frame } = {}
	if tabContainer then
		local tabAll = _childOfClass(tabContainer, "All", "Frame") :: Frame?
		if tabAll then
			tabFrames.All = tabAll
		end
		for _, tp in ipairs(BagCapacity.GetFilterTypes(BagCapacity.Filter.Window)) do
			local typeName = BackpackAllUI.itemTypeName(tp)
			if typeName then
				local tabFrame = _childOfClass(tabContainer, typeName, "Frame") :: Frame?
				if tabFrame then
					tabFrames[typeName] = tabFrame
				end
			end
		end
	end

	return {
		root = backpackRoot,
		warehouse = warehouse,
		warehouseScroll = warehouseScroll,
		warehouseTemp = warehouseTemp,
		capacitySize = capacitySize,
		searchBox = searchBox,
		tabContainer = tabContainer,
		tabFrames = tabFrames,
		dragReplaceZone = dragReplaceZone,
		toolbar = toolbar,
		toolbarTemp = toolbarTemp,
		lockUi = _collectLockUi(warehouse),
	}
end

return BackpackAllUI
