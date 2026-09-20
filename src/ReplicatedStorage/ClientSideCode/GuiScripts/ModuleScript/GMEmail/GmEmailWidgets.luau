--[[
	Module: GmEmailWidgets
	Description: GM 发邮件面板的通用控件工厂（圆角、描边、标签、按钮、输入框、滚动）
	Author: 林奥宇
	Created: 2026-08-18
	Last Modified: 2026-08-18

	功能：
	- 程序化创建 GM 面板常用 GuiObject
	- 无 RewardUITemp 资源时提供奖励格兜底模板
	- 绑定 ScrollingFrame 画布高度

	加载方式：同目录 require(script.Parent.GmEmailWidgets) 或 require(script.GmEmailWidgets)
]]

-- ========================================
-- 模块定义
-- ========================================
local GmEmailWidgets = {}

-- ========================================
-- 公共函数
-- ========================================

--[[
	给 GuiObject 加圆角

	@param uiObject GuiObject - 目标控件
	@param radius number? - 圆角像素，默认 6
	@return UICorner - 已挂载的圆角实例
]]
function GmEmailWidgets.createCorner(uiObject: GuiObject, radius: number?): UICorner
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius or 6)
	corner.Parent = uiObject
	return corner
end

--[[
	给 GuiObject 加描边

	@param uiObject GuiObject - 目标控件
	@param color Color3? - 描边颜色，默认深灰
	@return UIStroke - 已挂载的描边实例
]]
function GmEmailWidgets.createStroke(uiObject: GuiObject, color: Color3?): UIStroke
	local stroke = Instance.new("UIStroke")
	stroke.Color = color or Color3.fromRGB(72, 72, 78)
	stroke.Thickness = 1
	stroke.Parent = uiObject
	return stroke
end

--[[
	创建左对齐文本标签

	@param parent Instance - 父节点
	@param text string - 显示文本
	@param position UDim2 - 位置
	@param size UDim2 - 尺寸
	@param textSize number? - 字号，默认 20
	@param isBold boolean? - 是否加粗
	@return TextLabel - 标签
]]
function GmEmailWidgets.createLabel(
	parent: Instance,
	text: string,
	position: UDim2,
	size: UDim2,
	textSize: number?,
	isBold: boolean?
): TextLabel
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Position = position
	label.Size = size
	label.Text = text
	label.TextColor3 = Color3.fromRGB(235, 235, 235)
	label.TextSize = textSize or 20
	label.Font = if isBold then Enum.Font.GothamBold else Enum.Font.Gotham
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.Parent = parent
	return label
end

--[[
	创建文本按钮

	@param parent Instance - 父节点
	@param text string - 按钮文案
	@param position UDim2 - 位置
	@param size UDim2 - 尺寸
	@param bgColor Color3 - 背景色
	@param textSize number? - 字号，默认 20
	@return TextButton - 按钮
]]
function GmEmailWidgets.createButton(
	parent: Instance,
	text: string,
	position: UDim2,
	size: UDim2,
	bgColor: Color3,
	textSize: number?
): TextButton
	local button = Instance.new("TextButton")
	button.Position = position
	button.Size = size
	button.BackgroundColor3 = bgColor
	button.BorderSizePixel = 0
	button.Text = text
	button.TextColor3 = Color3.fromRGB(255, 255, 255)
	button.TextSize = textSize or 20
	button.Font = Enum.Font.GothamBold
	button.AutoButtonColor = true
	button.Parent = parent
	GmEmailWidgets.createCorner(button, 6)
	return button
end

--[[
	创建文本输入框

	@param parent Instance - 父节点
	@param placeholder string - 占位符
	@param position UDim2 - 位置
	@param size UDim2 - 尺寸
	@param textSize number? - 字号，默认 20
	@param isMultiLine boolean? - 是否多行
	@return TextBox - 输入框
]]
function GmEmailWidgets.createTextBox(
	parent: Instance,
	placeholder: string,
	position: UDim2,
	size: UDim2,
	textSize: number?,
	isMultiLine: boolean?
): TextBox
	local box = Instance.new("TextBox")
	box.Position = position
	box.Size = size
	box.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
	box.BorderSizePixel = 0
	box.Text = ""
	box.PlaceholderText = placeholder
	box.TextColor3 = Color3.fromRGB(255, 255, 255)
	box.PlaceholderColor3 = Color3.fromRGB(160, 160, 160)
	box.TextSize = textSize or 20
	box.Font = Enum.Font.Gotham
	box.ClearTextOnFocus = false
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.TextYAlignment = if isMultiLine then Enum.TextYAlignment.Top else Enum.TextYAlignment.Center
	box.MultiLine = isMultiLine == true
	box.TextWrapped = isMultiLine == true
	box.Parent = parent
	GmEmailWidgets.createCorner(box, 6)
	return box
end

--[[
	创建纵向滚动框

	@param parent Instance - 父节点
	@param position UDim2 - 位置
	@param size UDim2 - 尺寸
	@return ScrollingFrame - 滚动框
]]
function GmEmailWidgets.createScrollFrame(parent: Instance, position: UDim2, size: UDim2): ScrollingFrame
	local scroll = Instance.new("ScrollingFrame")
	scroll.Position = position
	scroll.Size = size
	scroll.BackgroundColor3 = Color3.fromRGB(34, 34, 38)
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 8
	scroll.CanvasSize = UDim2.new()
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.None
	scroll.ScrollingDirection = Enum.ScrollingDirection.Y
	scroll.ClipsDescendants = true
	scroll.Parent = parent
	GmEmailWidgets.createCorner(scroll, 8)
	GmEmailWidgets.createStroke(scroll)
	return scroll
end

--[[
	按布局内容高度更新滚动画布（会话期内保持连接）

	@param scroll ScrollingFrame - 滚动框
	@param layout UIListLayout | UIGridLayout - 子项布局
	@param extraY number? - 额外底部留白
	@return nil
]]
function GmEmailWidgets.bindCanvasSize(scroll: ScrollingFrame, layout: UIListLayout | UIGridLayout, extraY: number?)
	local function updateCanvas()
		local w = math.max(scroll.AbsoluteSize.X, 1)
		local contentY = if layout:IsA("UIListLayout")
			then layout.AbsoluteContentSize.Y
			else (layout :: UIGridLayout).AbsoluteContentSize.Y
		scroll.CanvasSize = UDim2.new(0, w, 0, contentY + (extraY or 0))
	end
	layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(updateCanvas)
	scroll:GetPropertyChangedSignal("AbsoluteSize"):Connect(updateCanvas)
	updateCanvas()
end

--[[
	程序化奖励格模板（无 Assets.UI.RewardUITemp 时兜底）

	@return Frame - 含 Icon / ViewportFrame / Count / ZhName 的格子
]]
function GmEmailWidgets.createRewardSlotTemplate(): Frame
	local frame = Instance.new("Frame")
	frame.Name = "RewardUITemp"
	frame.BackgroundColor3 = Color3.fromRGB(45, 45, 50)
	frame.BorderSizePixel = 0
	frame.Size = UDim2.fromOffset(150, 150)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = frame

	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.BackgroundTransparency = 1
	icon.Size = UDim2.new(0.7, 0, 0.7, 0)
	icon.Position = UDim2.new(0.15, 0, 0.05, 0)
	icon.ScaleType = Enum.ScaleType.Fit
	icon.Parent = frame

	local viewport = Instance.new("ViewportFrame")
	viewport.Name = "ViewportFrame"
	viewport.BackgroundTransparency = 1
	viewport.Size = UDim2.new(0.7, 0, 0.7, 0)
	viewport.Position = UDim2.new(0.15, 0, 0.05, 0)
	viewport.Visible = false
	viewport.Parent = frame

	local count = Instance.new("TextLabel")
	count.Name = "Count"
	count.BackgroundTransparency = 1
	count.Size = UDim2.new(1, -8, 0, 22)
	count.Position = UDim2.new(0, 4, 1, -48)
	count.TextColor3 = Color3.fromRGB(255, 255, 255)
	count.TextSize = 16
	count.Font = Enum.Font.GothamBold
	count.TextXAlignment = Enum.TextXAlignment.Right
	count.Parent = frame

	local zhName = Instance.new("TextLabel")
	zhName.Name = "ZhName"
	zhName.BackgroundTransparency = 1
	zhName.Size = UDim2.new(1, -8, 0, 22)
	zhName.Position = UDim2.new(0, 4, 1, -26)
	zhName.TextColor3 = Color3.fromRGB(235, 235, 235)
	zhName.TextSize = 14
	zhName.Font = Enum.Font.Gotham
	zhName.TextTruncate = Enum.TextTruncate.AtEnd
	zhName.Parent = frame

	return frame
end

return GmEmailWidgets
