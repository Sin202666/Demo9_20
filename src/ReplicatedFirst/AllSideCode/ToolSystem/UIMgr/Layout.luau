--[[
	Module: UIMgr/Layout
	Description: UIMgr 子模块 — UIList / UIGrid 容器尺寸计算（由 init 合并导出至 Utils.UIMgr）
	Author: 林奥宇
	Created: 2026-08-18
	Last Modified: 2026-09-01

	功能：
	- SetUIlistSize：按可见子项 Offset 累加 CanvasSize / Size
	- SetUIGridLayoutSize：按网格单元格估算行列
	- SetUIlistSize_New：支持换行、Title 分离、UIScale 逻辑坐标

	与 init：业务只调 Utils.UIMgr，不要直接 require 本文件。

	加载方式：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local UIMgr = Utils.UIMgr

	示例：
		UIMgr.SetUIlistSize(listFrame)
		UIMgr.SetUIGridLayoutSize(gridFrame)
		UIMgr.SetUIlistSize_New(shopList)
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Players = Utils.Players

local Layout = {}

local SCREEN_GUI_NAME = "ScreenGui"
local TITLE_CHILD_NAME = "Title"

--[[
	读取 ScreenGui 与所属 UI 上 UIScale 的组合倍率
	@param frame Frame | ScrollingFrame - 目标容器
	@return number - 逻辑坐标换算用倍率；找不到 UIScale 时为 1
]]
local function _getCombinedUiScale(frame: Frame | ScrollingFrame): number
	local localPlayer = Players.LocalPlayer
	local playerGui = if localPlayer then localPlayer:FindFirstChild("PlayerGui") else nil
	if not playerGui or not playerGui:IsA("PlayerGui") then
		return 1
	end

	local screenGui = playerGui:FindFirstChild(SCREEN_GUI_NAME)
	if not screenGui or not screenGui:IsA("ScreenGui") then
		return 1
	end

	local screenUIScale = screenGui:FindFirstChild("UIScale")
	local uiFrame: Instance? = frame
	while uiFrame and uiFrame.Parent ~= screenGui do
		uiFrame = uiFrame.Parent
	end
	local uiScale = uiFrame and uiFrame:FindFirstChild("UIScale")

	if screenUIScale and screenUIScale:IsA("UIScale") and uiScale and uiScale:IsA("UIScale") then
		return screenUIScale.Scale * uiScale.Scale
	elseif screenUIScale and screenUIScale:IsA("UIScale") then
		return screenUIScale.Scale
	elseif uiScale and uiScale:IsA("UIScale") then
		return uiScale.Scale
	end
	return 1
end

--[[
	将 Frame.Size 转为逻辑宽高（Offset 优先；否则 AbsoluteSize / uiScale）
	@param frame Frame - 要读取的框架
	@param uiScaleValue number - 组合 UIScale，须 >0
	@return number - 逻辑宽度
	@return number - 逻辑高度
]]
local function _getLogicalSize(frame: Frame, uiScaleValue: number): (number, number)
	local sizeX = frame.Size.X
	local sizeY = frame.Size.Y
	local scale = if uiScaleValue > 0 then uiScaleValue else 1

	local logicalX = 0
	local logicalY = 0
	if sizeX.Offset ~= 0 then
		logicalX = sizeX.Offset
	elseif sizeX.Scale ~= 0 then
		logicalX = frame.AbsoluteSize.X / scale
	end
	if sizeY.Offset ~= 0 then
		logicalY = sizeY.Offset
	elseif sizeY.Scale ~= 0 then
		logicalY = frame.AbsoluteSize.Y / scale
	end
	return logicalX, logicalY
end

--[[
	分离可见 Title Frame 与其余商品 Frame
	@param frame Frame | ScrollingFrame - 列表容器
	@return Frame? - Name 为 Title 的可见 Frame
	@return {Frame} - 其余可见商品 Frame（插入序）
]]
local function _collectVisibleListItems(frame: Frame | ScrollingFrame): (Frame?, { Frame })
	local titleFrame: Frame? = nil
	local itemFrames: { Frame } = {}
	for _, child in frame:GetChildren() do
		if child:IsA("Frame") and child.Visible == true then
			if child.Name == TITLE_CHILD_NAME then
				titleFrame = child
			else
				table.insert(itemFrames, child)
			end
		end
	end
	return titleFrame, itemFrames
end

--[[
	横向 + Wraps：按每行容量估算总高度并写 Size / CanvasSize
	@param frame Frame | ScrollingFrame - 列表容器
	@param titleFrame Frame? - Title 行
	@param itemFrames {Frame} - 商品行
	@param padding number - UIListLayout.Padding.Offset
	@param frameSize UDim2 - 已扣除 UIPadding 后的可用 Size
	@param xPaddingAdd number - 左右 Padding Offset 之和
	@param yPaddingAdd number - 上下 Padding Offset 之和
	@param uiScaleValue number - 组合 UIScale
	@return () - 无返回值
]]
local function _applyHorizontalWrapSize(
	frame: Frame | ScrollingFrame,
	titleFrame: Frame?,
	itemFrames: { Frame },
	padding: number,
	frameSize: UDim2,
	xPaddingAdd: number,
	yPaddingAdd: number,
	uiScaleValue: number
)
	local scale = if uiScaleValue > 0 then uiScaleValue else 1
	local availableWidth = frameSize.X.Offset
	if availableWidth <= 0 then
		availableWidth = (frame.AbsoluteSize.X / scale) - xPaddingAdd
	end

	local titleHeight = 0
	if titleFrame then
		local _, titleHeightLogical = _getLogicalSize(titleFrame, scale)
		titleHeight = titleHeightLogical
	end

	local itemCount = #itemFrames
	local itemRowsHeight = 0
	if itemCount > 0 then
		local itemWidth, itemHeight = _getLogicalSize(itemFrames[1], scale)
		local cellWidth = itemWidth + padding
		local itemsPerRow = 1
		if cellWidth > 0 then
			itemsPerRow = math.max(1, math.floor((availableWidth + padding) / cellWidth))
		end
		local rowCount = math.max(1, math.ceil(itemCount / itemsPerRow))
		itemRowsHeight = (rowCount * itemHeight) + ((rowCount - 1) * padding)
	end

	local totalHeight = yPaddingAdd
	if titleFrame then
		totalHeight += titleHeight
		if itemCount > 0 then
			totalHeight += padding
		end
	end
	totalHeight += itemRowsHeight

	if frame:IsA("ScrollingFrame") then
		totalHeight = math.max(totalHeight, frame.AbsoluteSize.Y / scale)
		frame.CanvasSize = UDim2.new(1, 0, 0, totalHeight)
	else
		frame.Size = UDim2.new(frameSize.X.Scale, frameSize.X.Offset + xPaddingAdd, 0, totalHeight)
	end
end

--[[
	纵向或不换行：按子项逻辑尺寸累加后写 Size / CanvasSize
	@param frame Frame | ScrollingFrame - 列表容器
	@param titleFrame Frame? - Title 行
	@param itemFrames {Frame} - 商品行
	@param dir Enum.FillDirection - 填充方向
	@param padding number - UIListLayout.Padding.Offset
	@param frameSize UDim2 - 已扣除 UIPadding 后的可用 Size
	@param xPaddingAdd number - 左右 Padding Offset 之和
	@param yPaddingAdd number - 上下 Padding Offset 之和
	@param uiScaleValue number - 组合 UIScale
	@return () - 无返回值
]]
local function _applyLinearListSize(
	frame: Frame | ScrollingFrame,
	titleFrame: Frame?,
	itemFrames: { Frame },
	dir: Enum.FillDirection,
	padding: number,
	frameSize: UDim2,
	xPaddingAdd: number,
	yPaddingAdd: number,
	uiScaleValue: number
)
	local totalSizeY = 0
	local totalSizeX = 0
	local itemCount = #itemFrames

	if titleFrame then
		local _, titleHeightLogical = _getLogicalSize(titleFrame, uiScaleValue)
		totalSizeY += titleHeightLogical
		if itemCount > 0 then
			totalSizeY += padding
		end
	end

	for _, itemFrame in itemFrames do
		local itemWidthLogical, itemHeightLogical = _getLogicalSize(itemFrame, uiScaleValue)
		totalSizeY += itemHeightLogical
		totalSizeX += itemWidthLogical
	end

	local itemPadding = 0
	if itemCount > 0 then
		itemPadding = padding * (itemCount - 1)
	end

	if frame:IsA("ScrollingFrame") then
		if dir == Enum.FillDirection.Vertical then
			frame.CanvasSize = UDim2.new(0, 0, 0, yPaddingAdd + totalSizeY + itemPadding)
		else
			frame.CanvasSize = UDim2.new(0, xPaddingAdd + totalSizeX + itemPadding, 0, 0)
		end
	elseif frame:IsA("Frame") then
		if dir == Enum.FillDirection.Vertical then
			frame.Size = UDim2.new(
				frameSize.X.Scale,
				frameSize.X.Offset + xPaddingAdd,
				0,
				yPaddingAdd + totalSizeY + itemPadding
			)
		else
			frame.Size = UDim2.new(
				0,
				xPaddingAdd + totalSizeX + itemPadding,
				frameSize.Y.Scale,
				yPaddingAdd + frameSize.Y.Offset
			)
		end
	end
end

--[[
	动态设置 UI 列表大小
	@param _frame Frame - UI 框架（支持 Frame 和 ScrollingFrame）
	@return () - 无返回值
]]
function Layout.SetUIlistSize(_frame: Frame): ()
	local UIListLayout: UIListLayout? = _frame:FindFirstChildOfClass("UIListLayout") :: UIListLayout?
	if not UIListLayout then
		return
	end

	local dir = UIListLayout.FillDirection
	local totalSizeX = 0
	local totalSizeY = 0
	local showNum = 0

	-- 计算 UIPadding
	local UIPadding: UIPadding? = _frame:FindFirstChildOfClass("UIPadding") :: UIPadding?
	if UIPadding then
		totalSizeX += UIPadding.PaddingLeft.Offset
		totalSizeX += UIPadding.PaddingRight.Offset
		totalSizeY += UIPadding.PaddingTop.Offset
		totalSizeY += UIPadding.PaddingBottom.Offset
	end

	-- 计算可见子元素的总大小
	for _, v in pairs(_frame:GetChildren()) do
		if not v:IsA("UIListLayout") and not v:IsA("LocalScript") and not v:IsA("UIPadding") and v.Visible == true then
			showNum = showNum + 1
			totalSizeY = totalSizeY + v.Size.Height.Offset
			totalSizeX = totalSizeX + v.Size.Width.Offset
		end
	end

	local padding = UIListLayout.Padding.Offset

	-- 根据框架类型和方向设置大小
	if _frame:IsA("ScrollingFrame") then
		if dir == Enum.FillDirection.Vertical then
			-- 垂直方向
			_frame.CanvasSize = UDim2.new(0, 0, 0, totalSizeY + (padding * (showNum - 1)))
		else
			-- 水平方向
			_frame.CanvasSize = UDim2.new(0, totalSizeX + (padding * (showNum - 1)), 0, 0)
		end
	elseif _frame:IsA("Frame") then
		local Size: UDim2 = _frame.Size
		if dir == Enum.FillDirection.Vertical then
			-- 垂直方向
			_frame.Size = UDim2.new(Size.X.Scale, Size.X.Offset, 0, totalSizeY + (padding * (showNum - 1)))
		else
			-- 水平方向
			_frame.Size = UDim2.new(0, totalSizeX + (padding * (showNum - 1)), Size.Y.Scale, Size.Y.Offset)
		end
	end
end

--[[
	动态设置 UI 网格布局大小
	@param _frame Frame - UI 框架（支持 Frame 和 ScrollingFrame）
	@return () - 无返回值
]]
function Layout.SetUIGridLayoutSize(_frame: Frame): ()
	local UIGridLayout: UIGridLayout? = _frame:FindFirstChildOfClass("UIGridLayout") :: UIGridLayout?
	if not UIGridLayout then
		return
	end

	local totalSizeX = 0
	local totalSizeY = 0
	local showNum = 0

	-- 计算可见元素数量
	for _, v in pairs(_frame:GetChildren()) do
		if (v:IsA("ImageButton") or v:IsA("Frame")) and v.Visible == true then
			showNum = showNum + 1
		end
	end

	-- 计算 UIPadding
	local UIPadding: UIPadding? = _frame:FindFirstChildOfClass("UIPadding") :: UIPadding?
	if UIPadding then
		totalSizeX += UIPadding.PaddingLeft.Offset
		totalSizeX += UIPadding.PaddingRight.Offset
		totalSizeY += UIPadding.PaddingTop.Offset
		totalSizeY += UIPadding.PaddingBottom.Offset
	end

	local CellPadding = UIGridLayout.CellPadding
	local CellSize = UIGridLayout.CellSize

	-- 根据框架类型和滚动方向设置大小
	if _frame:IsA("ScrollingFrame") then
		if _frame.ScrollingDirection == Enum.ScrollingDirection.Y then
			-- 垂直滚动：计算每行几个
			local xNum = math.floor((_frame.Size.X.Offset + CellPadding.X.Offset) / (CellPadding.X.Offset + CellSize.X.Offset))
			local yNum = math.ceil(showNum / xNum)
			local yWidth = CellPadding.Y.Offset + CellSize.Y.Offset
			_frame.CanvasSize = UDim2.new(0, 0, 0, (yNum * yWidth) - CellPadding.Y.Offset + totalSizeY)
		elseif _frame.ScrollingDirection == Enum.ScrollingDirection.X then
			-- 水平滚动：计算每列几个
			local yNum = math.floor((_frame.Size.Y.Offset + CellPadding.Y.Offset) / (CellPadding.Y.Offset + CellSize.Y.Offset))
			local xNum = math.ceil(showNum / yNum)
			local xWidth = CellPadding.X.Offset + CellSize.X.Offset
			_frame.CanvasSize = UDim2.new(0, (xNum * xWidth) - CellPadding.X.Offset + totalSizeX, 0, 0)
		end
	elseif _frame:IsA("Frame") then
		local Size: UDim2 = _frame.Size

		if UIGridLayout.FillDirection == Enum.FillDirection.Horizontal then
			-- 水平填充：计算每列几个
			local xNum = math.floor((_frame.Size.X.Offset + CellSize.X.Offset) / (CellPadding.X.Offset + CellSize.X.Offset))
			local yNum = math.ceil(showNum / xNum)
			local yWidth = CellPadding.Y.Offset + CellSize.Y.Offset
			_frame.Size = UDim2.new(Size.X.Scale, Size.X.Offset, 0, (yNum * yWidth) - CellPadding.Y.Offset + totalSizeY)
		elseif UIGridLayout.FillDirection == Enum.FillDirection.Vertical then
			-- 垂直填充：计算每行几个
			local yNum = math.floor((_frame.Size.Y.Offset + CellSize.X.Offset) / (CellPadding.Y.Offset + CellSize.Y.Offset))
			local xNum = math.ceil(showNum / yNum)
			local xWidth = CellPadding.X.Offset + CellSize.X.Offset
			_frame.Size = UDim2.new(0, (xNum * xWidth) - CellPadding.X.Offset + totalSizeX, Size.Y.Scale, Size.Y.Offset)
		end
	end
end

--[[
	动态设置 UIListLayout 的大小（支持换行，正确处理 Title 和商品元素）

	功能：
	- 根据子元素自动计算并设置 Frame 或 ScrollingFrame 的大小
	- 支持横向和纵向布局
	- 支持换行（Wraps）功能
	- 正确处理 Title Frame 和商品元素的分离
	- 考虑 UIScale 的影响，使用逻辑坐标进行计算
	- 支持 UIPadding 的内边距计算

	@param _frame Frame | ScrollingFrame - 要设置大小的容器框架
	@return () - 无返回值
]]
function Layout.SetUIlistSize_New(_frame: Frame | ScrollingFrame)
	local uiListLayout = _frame:FindFirstChildOfClass("UIListLayout")
	if not uiListLayout then
		return
	end

	local uiScaleValue = _getCombinedUiScale(_frame)
	local dir = uiListLayout.FillDirection
	local wraps = uiListLayout.Wraps or false
	local uiPadding = _frame:FindFirstChildOfClass("UIPadding")
	local frameSize = _frame.Size
	local xPaddingAdd = 0
	local yPaddingAdd = 0
	if uiPadding then
		xPaddingAdd = uiPadding.PaddingLeft.Offset + uiPadding.PaddingRight.Offset
		yPaddingAdd = uiPadding.PaddingTop.Offset + uiPadding.PaddingBottom.Offset
		frameSize = frameSize - UDim2.new(0, xPaddingAdd, 0, yPaddingAdd)
	end

	local titleFrame, itemFrames = _collectVisibleListItems(_frame)
	local padding = uiListLayout.Padding.Offset

	if dir == Enum.FillDirection.Horizontal and wraps then
		_applyHorizontalWrapSize(_frame, titleFrame, itemFrames, padding, frameSize, xPaddingAdd, yPaddingAdd, uiScaleValue)
		return
	end

	_applyLinearListSize(_frame, titleFrame, itemFrames, dir, padding, frameSize, xPaddingAdd, yPaddingAdd, uiScaleValue)
end

return Layout
