--[[
	Module: SettingDropdown
	Description: 设置页下拉列表 ZIndex、展开互斥与 ScrollSort 布局
	Author: 林奥宇
	Created: 2026-07-03
	Last Modified: 2026-08-31

	功能：
	- 同时只允许一个下拉展开；展开时把所属 Cat_ 提到最高 ZIndex
	- 按 CanvasSize 与 DropMaxH 写 ScrollSort 视口高度
	- 重建称号下拉时清动态项、保留 SortTemp 与布局装饰

	与 SettingRowBind：
	- 行绑定持有共享 State，本模块只读写 ZIndex / Visible / Size
	- 不写 player.Setting，不调 Remote

	加载：
	local SettingDropdown = require(script.SettingDropdown)
	SettingDropdown.closeAny(state)

	示例：
	SettingDropdown.syncCatZIndex(state, catFrame)
	SettingDropdown.layoutScrollSort(UIMgr, sortFrame, scrollSort)
]]

local SettingDropdown = {}

-- ========================================
-- 常量
-- ========================================
local DROPDOWN_CAT_TOP_Z = 99
local DROPDOWN_CAT_BASE_Z = 1
local SETTING_DROPDOWN_SCROLL_MAX_H = 320

export type State = {
	categoryToSecondFrame: { [number]: Frame },
	openDropdownScroll: ScrollingFrame?,
}

-- ========================================
-- 公共函数
-- ========================================

--[[
	有下拉展开时：所属 Cat_ ZIndex 置顶，其余分类块还原
	@param state State - 下拉共享状态（categoryToSecondFrame / openDropdownScroll）
	@param openCat Frame? - 当前展开下拉所属分类块；nil 时全部还原为 DROPDOWN_CAT_BASE_Z
	@return nil - 无返回值
]]
function SettingDropdown.syncCatZIndex(state: State, openCat: Frame?)
	for _, secFrame in pairs(state.categoryToSecondFrame) do
		secFrame.ZIndex = DROPDOWN_CAT_BASE_Z
	end
	if openCat then
		openCat.ZIndex = DROPDOWN_CAT_TOP_Z
	end
end

--[[
	收起任意已展开的下拉，并还原 Cat_ ZIndex
	@param state State - 下拉共享状态
	@return nil - 无返回值
]]
function SettingDropdown.closeAny(state: State)
	local cur = state.openDropdownScroll
	state.openDropdownScroll = nil
	if cur and cur.Parent then
		cur.Visible = false
		local sz = cur.Size
		cur.Size = UDim2.new(sz.X.Scale, sz.X.Offset, 0, 0)
	end
	SettingDropdown.syncCatZIndex(state, nil)
end

--[[
	根据 ScrollSort CanvasSize 写视口高度（与 DropMaxH 上限取小）
	@param scrollSort ScrollingFrame - 下拉滚动区
	@return nil - 无返回值；CanvasSize.Y<=0 时视口高度按 1 像素
]]
function SettingDropdown.applyScrollSortViewport(scrollSort: ScrollingFrame)
	local cy = scrollSort.CanvasSize.Y.Offset
	if cy <= 0 then
		cy = 1
	end
	local attr = scrollSort:GetAttribute("DropMaxH")
	local maxH = (type(attr) == "number" and attr > 0) and attr or SETTING_DROPDOWN_SCROLL_MAX_H
	local windowH = math.min(cy, maxH)
	local sz = scrollSort.Size
	scrollSort.Size = UDim2.new(sz.X.Scale, sz.X.Offset, 0, windowH)
end

--[[
	更新 ScrollSort 画布并在展开时写视口高度
	@param UIMgr any - Utils.UIMgr（须有 SetUIlistSize_New）
	@param sortFrame Frame? - SortFrame 容器；无 UIListLayout 时跳过二次布局
	@param scrollSort ScrollingFrame - 下拉滚动区
	@return nil - 无返回值；defer 内若实例已销毁则跳过
]]
function SettingDropdown.layoutScrollSort(UIMgr: any, sortFrame: Frame?, scrollSort: ScrollingFrame)
	UIMgr.SetUIlistSize_New(scrollSort)
	if scrollSort.Visible then
		SettingDropdown.applyScrollSortViewport(scrollSort)
	else
		local sz0 = scrollSort.Size
		scrollSort.Size = UDim2.new(sz0.X.Scale, sz0.X.Offset, 0, 0)
	end
	task.defer(function()
		if scrollSort.Parent then
			UIMgr.SetUIlistSize_New(scrollSort)
			if scrollSort.Visible then
				SettingDropdown.applyScrollSortViewport(scrollSort)
			else
				local sz1 = scrollSort.Size
				scrollSort.Size = UDim2.new(sz1.X.Scale, sz1.X.Offset, 0, 0)
			end
		end
		if sortFrame and sortFrame.Parent and sortFrame:FindFirstChildOfClass("UIListLayout") then
			UIMgr.SetUIlistSize_New(sortFrame)
		end
	end)
end

--[[
	移除 ScrollSort 内动态克隆项，保留 SortTemp 与布局装饰
	@param scrollSort ScrollingFrame - 下拉滚动区
	@param sortTemp Frame? - 模板 Frame，不销毁
	@return nil - 无返回值
]]
function SettingDropdown.clearDynamicChildren(scrollSort: ScrollingFrame, sortTemp: Frame?)
	for _, ch in scrollSort:GetChildren() do
		if ch ~= sortTemp and not ch:IsA("UICorner") and not ch:IsA("UIListLayout") and not ch:IsA("UIStroke") then
			ch:Destroy()
		end
	end
end

return SettingDropdown
