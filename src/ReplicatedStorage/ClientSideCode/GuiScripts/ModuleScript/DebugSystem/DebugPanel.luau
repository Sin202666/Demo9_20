--[[
	Module: DebugPanel
	Description: DebugSystem 的 UI 构建子模块——创建面板实例、悬停与动态按钮，不持有业务回调之外的状态
	Author: 林奥宇
	Created: 2026-09-01
	Last Modified: 2026-09-01

	功能：
	- build：创建 ScreenGui / 主面板 / 背包区 / 动态按钮区
	- createDynamicButton / createAllDynamicButtons：按 Host.dynamicButtons 生成按钮
	- applyButtonText / applyInputGroupTexts：转调 DebugI18n（已知键字面量 SetText）

	与 DebugSystem：
	- 本文件只建 Instance；输入缓存、按钮注册表由 init 的 Host 传入
	- DebugI18n：已知翻译键字面量 SetText；按钮文案写在 Caption 子 Label 上
	- 动态按钮 Name / Param 名必须是已入 LocalizationTable 的键；未知键由 DebugI18n warn

	加载：
	local DebugPanel = require(script.Parent.DebugPanel)  -- 仅 DebugSystem/init 引用
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local TweenService = Utils.TweenService
local TranslationHelper = Utils.TranslationHelper

local DebugI18n = require(script.Parent.DebugI18n)

local DebugPanel = {}

-- ========================================
-- 常量
-- ========================================

local HOVER_TIME = 0.2
local HOVER_LERP = 0.2
local INPUT_ROW_HEIGHT = 50
local LABEL_WIDTH = 90
local ACTION_BUTTON_WIDTH = 95
local PARAM_CONTAINER_PAD = 48
local PARAM_BUTTON_HEIGHT = 42
local DYNAMIC_SCROLL_HEIGHT = 400
local CANVAS_PAD = 20
local PANEL_WIDTH = 420
local PANEL_HEIGHT = 700
local PANEL_RIGHT_INSET = 430
local PANEL_HALF_HEIGHT = 350
local TITLE_HEIGHT = 45
local DISPLAY_ORDER = 999
local CONTENT_LEFT = 20
local CONTENT_RIGHT_PAD = 50
local CONTENT_PAD_TOP = 16
local TOGGLE_WIDTH = 120
local TOGGLE_HEIGHT = 45
local TOGGLE_RIGHT_INSET = 130
local TOGGLE_BOTTOM_INSET = 55

local COLOR = table.freeze({
	PanelBg = Color3.fromRGB(30, 30, 30),
	TitleBg = Color3.fromRGB(20, 20, 20),
	InputBg = Color3.fromRGB(50, 50, 50),
	Label = Color3.fromRGB(220, 220, 220),
	White = Color3.fromRGB(255, 255, 255),
	Placeholder = Color3.fromRGB(140, 140, 140),
	Container = Color3.fromRGB(45, 45, 50),
	DefaultBtn = Color3.fromRGB(70, 130, 180),
	Add = Color3.fromRGB(50, 150, 50),
	Reduce = Color3.fromRGB(150, 100, 50),
	Clear = Color3.fromRGB(150, 50, 50),
	Toggle = Color3.fromRGB(50, 100, 150),
	Close = Color3.fromRGB(200, 50, 50),
	Divider = Color3.fromRGB(100, 100, 100),
	Scroll = Color3.fromRGB(100, 100, 100),
})

-- ========================================
-- 类型
-- ========================================

export type ButtonConfig = {
	Name: string,
	Param1Name: string?,
	Param2Name: string?,
	Callback: (() -> ())?,
	Color: Color3?,
	_Param1Input: TextBox?,
	_Param2Input: TextBox?,
}

export type UiRefs = {
	ScreenGui: ScreenGui?,
	MainFrame: Frame?,
	ToggleButton: TextButton?,
	IDInput: TextBox?,
	AmountInput: TextBox?,
	AddButton: TextButton?,
	ReduceButton: TextButton?,
	ClearButton: TextButton?,
	ButtonWindowScrollFrame: ScrollingFrame?,
}

export type Host = {
	uiRefs: UiRefs,
	inputValues: { ID: string, Amount: string },
	buttonParams: { [string]: { Param1: string?, Param2: string? } },
	eventCallbacks: {
		OnAddClick: (() -> ())?,
		OnReduceClick: (() -> ())?,
		OnClearClick: (() -> ())?,
	},
	dynamicButtons: { ButtonConfig },
	buttonCache: { [string]: Instance },
}

-- ========================================
-- 私有：几何与交互
-- ========================================

--[[
	给实例加圆角
	@param parent Instance - 父实例
	@param radius number - 圆角像素
	@return nil
]]
local function _corner(parent: Instance, radius: number)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = parent
end

--[[
	绑定按钮悬停明暗（不改 Text）
	@param button GuiObject - 目标按钮
	@param baseColor Color3 - 静止背景色
	@return nil
]]
local function _bindHover(button: GuiObject, baseColor: Color3)
	local tweenInfo = TweenInfo.new(HOVER_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	button.MouseEnter:Connect(function()
		TweenService:Create(button, tweenInfo, {
			BackgroundColor3 = baseColor:Lerp(COLOR.White, HOVER_LERP),
		}):Play()
	end)
	button.MouseLeave:Connect(function()
		TweenService:Create(button, tweenInfo, { BackgroundColor3 = baseColor }):Play()
	end)
end

--[[
	AbsoluteContentSize 变化时防抖执行 apply
	@param layout UIListLayout - 被监听的布局
	@param apply () -> () - 更新 CanvasSize / 容器高度
	@return nil
]]
local function _bindDebouncedLayout(layout: UIListLayout, apply: () -> ())
	local pending = false
	layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
		if pending then
			return
		end
		pending = true
		task.defer(function()
			apply()
			pending = false
		end)
	end)
end

-- ========================================
-- 私有：控件工厂
-- ========================================

--[[
	创建带标签的输入行
	@param parent Instance - 父容器
	@param labelKey string - 标签翻译键（须为已入表字面量键名）
	@param yPosition number - 无 ListLayout 时的 Y 偏移
	@param host Host - 共享状态（仅 ID / 物品数量写入 inputValues）
	@param layoutOrder number? - 父级有 UIListLayout 时的排序
	@return TextBox - 输入框
]]
local function _createInputGroup(parent: Instance, labelKey: string, yPosition: number, host: Host, layoutOrder: number?): TextBox
	local inputGroup = Instance.new("Frame")
	inputGroup.Name = labelKey .. "Group"
	inputGroup.Size = UDim2.new(1, 0, 0, INPUT_ROW_HEIGHT)
	inputGroup.Position = UDim2.new(0, 0, 0, yPosition)
	inputGroup.BackgroundTransparency = 1
	if layoutOrder then
		inputGroup.LayoutOrder = layoutOrder
	end
	inputGroup.Parent = parent

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.Size = UDim2.new(0, LABEL_WIDTH, 0, 30)
	label.Position = UDim2.new(0, 0, 0, 10)
	label.BackgroundTransparency = 1
	label.TextColor3 = COLOR.Label
	label.TextSize = 20
	label.Font = Enum.Font.Gotham
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = inputGroup

	local inputFrame = Instance.new("Frame")
	inputFrame.Name = "InputFrame"
	inputFrame.Size = UDim2.new(1, -LABEL_WIDTH, 0, 36)
	inputFrame.Position = UDim2.new(0, LABEL_WIDTH, 0, 7)
	inputFrame.BackgroundColor3 = COLOR.InputBg
	inputFrame.BorderSizePixel = 0
	inputFrame.Parent = inputGroup
	_corner(inputFrame, 5)

	local textBox = Instance.new("TextBox")
	textBox.Name = "TextBox"
	textBox.Size = UDim2.new(1, -8, 1, -8)
	textBox.Position = UDim2.new(0, 4, 0, 4)
	textBox.BackgroundTransparency = 1
	textBox.Text = ""
	textBox.TextColor3 = COLOR.White
	textBox.PlaceholderColor3 = COLOR.Placeholder
	textBox.TextSize = 20
	textBox.Font = Enum.Font.Gotham
	textBox.TextXAlignment = Enum.TextXAlignment.Left
	textBox.ClearTextOnFocus = false
	textBox.Parent = inputFrame

	DebugI18n.applyInputGroupTexts(label, textBox, labelKey)

	textBox:GetPropertyChangedSignal("Text"):Connect(function()
		if labelKey == "ID" then
			host.inputValues.ID = textBox.Text
		elseif labelKey == "物品数量" then
			host.inputValues.Amount = textBox.Text
		end
	end)

	return textBox
end

--[[
	把动态按钮参数输入同步进 host.buttonParams
	@param textBox TextBox - 参数输入框
	@param buttonName string - 按钮 Name（兼查找键）
	@param field string - "Param1" 或 "Param2"
	@param host Host - 共享状态
	@return nil
]]
local function _wireParamInput(textBox: TextBox, buttonName: string, field: string, host: Host)
	textBox:GetPropertyChangedSignal("Text"):Connect(function()
		if not host.buttonParams[buttonName] then
			host.buttonParams[buttonName] = {}
		end
		host.buttonParams[buttonName][field] = textBox.Text
	end)
end

--[[
	创建单个动态按钮容器
	@param buttonConfig ButtonConfig - Name / Param* / Callback / Color
	@param layoutOrder number - UIListLayout 排序
	@param parent Instance - 动态区 ScrollingFrame
	@param host Host - 共享状态
	@return Frame - 按钮容器
]]
function DebugPanel.createDynamicButton(buttonConfig: ButtonConfig, layoutOrder: number, parent: Instance, host: Host): Frame
	local hasParam1 = buttonConfig.Param1Name ~= nil and buttonConfig.Param1Name ~= ""
	local hasParam2 = buttonConfig.Param2Name ~= nil and buttonConfig.Param2Name ~= ""
	local paramCount = (hasParam1 and 1 or 0) + (hasParam2 and 1 or 0)
	local containerHeight = PARAM_CONTAINER_PAD + (paramCount * INPUT_ROW_HEIGHT) + PARAM_BUTTON_HEIGHT

	local buttonContainer = Instance.new("Frame")
	buttonContainer.Name = buttonConfig.Name .. "Container"
	buttonContainer.Size = UDim2.new(1, 0, 0, containerHeight)
	buttonContainer.BackgroundColor3 = COLOR.Container
	buttonContainer.BorderSizePixel = 0
	buttonContainer.LayoutOrder = layoutOrder
	buttonContainer.Parent = parent
	_corner(buttonContainer, 8)

	local contentFrame = Instance.new("Frame")
	contentFrame.Name = "ContentFrame"
	contentFrame.Size = UDim2.new(1, -16, 1, -24)
	contentFrame.Position = UDim2.new(0, 8, 0, 12)
	contentFrame.BackgroundTransparency = 1
	contentFrame.Parent = buttonContainer

	local param1Input: TextBox? = nil
	if hasParam1 then
		param1Input = _createInputGroup(contentFrame, buttonConfig.Param1Name :: string, 0, host)
		_wireParamInput(param1Input, buttonConfig.Name, "Param1", host)
	end

	local param2Input: TextBox? = nil
	if hasParam2 then
		local param2Y = hasParam1 and INPUT_ROW_HEIGHT or 0
		param2Input = _createInputGroup(contentFrame, buttonConfig.Param2Name :: string, param2Y, host)
		_wireParamInput(param2Input, buttonConfig.Name, "Param2", host)
	end

	local buttonColor = buttonConfig.Color or COLOR.DefaultBtn
	local button = Instance.new("TextButton")
	button.Name = buttonConfig.Name .. "Button"
	button.Size = UDim2.new(1, 0, 0, PARAM_BUTTON_HEIGHT)
	button.Position = UDim2.new(0, 0, 0, paramCount * INPUT_ROW_HEIGHT)
	button.BorderSizePixel = 0
	button.AutoButtonColor = false
	button.TextColor3 = COLOR.White
	button.TextSize = 22
	button.Font = Enum.Font.GothamBold
	button.BackgroundColor3 = buttonColor
	button.Parent = contentFrame
	_corner(button, 6)
	DebugI18n.applyButtonText(button, buttonConfig.Name)
	_bindHover(button, buttonColor)

	if buttonConfig.Callback then
		button.MouseButton1Click:Connect(function()
			buttonConfig.Callback()
		end)
	end

	if not host.buttonParams[buttonConfig.Name] then
		host.buttonParams[buttonConfig.Name] = {}
		if hasParam1 then
			host.buttonParams[buttonConfig.Name].Param1 = ""
		end
		if hasParam2 then
			host.buttonParams[buttonConfig.Name].Param2 = ""
		end
	end

	buttonConfig._Param1Input = param1Input
	buttonConfig._Param2Input = param2Input
	return buttonContainer
end

--[[
	按 Host.dynamicButtons 补齐尚未创建的动态按钮
	@param host Host - 共享状态
	@return nil
]]
function DebugPanel.createAllDynamicButtons(host: Host)
	local scrollFrame = host.uiRefs.ButtonWindowScrollFrame
	if not scrollFrame then
		return
	end
	for i, buttonConfig in ipairs(host.dynamicButtons) do
		if not host.buttonCache[buttonConfig.Name] then
			host.buttonCache[buttonConfig.Name] = DebugPanel.createDynamicButton(buttonConfig, i, scrollFrame, host)
		end
	end
end

--[[
	创建标题栏与关闭按钮
	@param mainFrame Frame - 主面板
	@param onClose () -> () - 关闭回调
	@return nil
]]
local function _createTitleBar(mainFrame: Frame, onClose: () -> ())
	local titleBar = Instance.new("Frame")
	titleBar.Name = "TitleBar"
	titleBar.Size = UDim2.new(1, 0, 0, TITLE_HEIGHT)
	titleBar.BackgroundColor3 = COLOR.TitleBg
	titleBar.BorderSizePixel = 0
	titleBar.LayoutOrder = 1
	titleBar.ZIndex = 11
	titleBar.Parent = mainFrame
	_corner(titleBar, 8)

	local titleLabel = Instance.new("TextLabel")
	titleLabel.Name = "TitleLabel"
	titleLabel.Size = UDim2.new(1, -50, 1, 0)
	titleLabel.Position = UDim2.new(0, 15, 0, 0)
	titleLabel.BackgroundTransparency = 1
	titleLabel.ZIndex = 12
	titleLabel.TextColor3 = COLOR.White
	titleLabel.TextSize = 26
	titleLabel.Font = Enum.Font.GothamBold
	titleLabel.TextXAlignment = Enum.TextXAlignment.Left
	titleLabel.Parent = titleBar
	TranslationHelper.SetText(titleLabel, "调试系统")

	local closeButton = Instance.new("TextButton")
	closeButton.Name = "CloseButton"
	closeButton.Size = UDim2.new(0, 30, 0, 30)
	closeButton.Position = UDim2.new(1, -35, 0.5, -15)
	closeButton.BackgroundColor3 = COLOR.Close
	closeButton.BorderSizePixel = 0
	closeButton.ZIndex = 12
	closeButton.Text = "×"
	closeButton.TextColor3 = COLOR.White
	closeButton.TextSize = 28
	closeButton.Font = Enum.Font.GothamBold
	closeButton.Parent = titleBar
	_corner(closeButton, 4)
	closeButton.MouseButton1Click:Connect(onClose)
end

--[[
	创建背包区固定三按钮之一
	@param parent Instance - 按钮行
	@param instanceName string - Instance.Name
	@param key string - 翻译键
	@param color Color3 - 背景色
	@param layoutOrder number - 横向排序
	@param onClick () -> () - 点击
	@return TextButton - 按钮
]]
local function _createActionButton(
	parent: Instance,
	instanceName: string,
	key: string,
	color: Color3,
	layoutOrder: number,
	onClick: () -> ()
): TextButton
	local button = Instance.new("TextButton")
	button.Name = instanceName
	button.Size = UDim2.new(0, ACTION_BUTTON_WIDTH, 0, 40)
	button.BackgroundColor3 = color
	button.BorderSizePixel = 0
	button.AutoButtonColor = false
	button.TextColor3 = COLOR.White
	button.TextSize = 22
	button.Font = Enum.Font.GothamBold
	button.LayoutOrder = layoutOrder
	button.Parent = parent
	_corner(button, 6)
	DebugI18n.applyButtonText(button, key)
	_bindHover(button, color)
	button.MouseButton1Click:Connect(onClick)
	return button
end

--[[
	创建 ID / 数量输入与添加减少清空
	@param contentFrame Frame - 内容列
	@param host Host - 共享状态
	@return nil
]]
local function _createBagSection(contentFrame: Frame, host: Host)
	host.uiRefs.IDInput = _createInputGroup(contentFrame, "ID", 0, host, 1)
	host.uiRefs.AmountInput = _createInputGroup(contentFrame, "物品数量", 0, host, 2)

	local buttonFrame = Instance.new("Frame")
	buttonFrame.Name = "ButtonFrame"
	buttonFrame.Size = UDim2.new(1, 0, 0, 50)
	buttonFrame.BackgroundTransparency = 1
	buttonFrame.LayoutOrder = 3
	buttonFrame.Parent = contentFrame

	local listLayout = Instance.new("UIListLayout")
	listLayout.FillDirection = Enum.FillDirection.Horizontal
	listLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	listLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Padding = UDim.new(0, 8)
	listLayout.Parent = buttonFrame

	host.uiRefs.AddButton = _createActionButton(buttonFrame, "添加Button", "添加", COLOR.Add, 1, function()
		if host.eventCallbacks.OnAddClick then
			host.eventCallbacks.OnAddClick()
		end
	end)
	host.uiRefs.ReduceButton = _createActionButton(buttonFrame, "减少Button", "减少", COLOR.Reduce, 2, function()
		if host.eventCallbacks.OnReduceClick then
			host.eventCallbacks.OnReduceClick()
		end
	end)
	host.uiRefs.ClearButton = _createActionButton(buttonFrame, "清空Button", "清空", COLOR.Clear, 3, function()
		if host.eventCallbacks.OnClearClick then
			host.eventCallbacks.OnClearClick()
		end
	end)
end

--[[
	创建右下角切换按钮
	@param screenGui ScreenGui - 根 Gui
	@param mainFrame Frame - 主面板
	@param host Host - 写入 ToggleButton 引用
	@return nil
]]
local function _createToggleButton(screenGui: ScreenGui, mainFrame: Frame, host: Host)
	local toggleButton = Instance.new("TextButton")
	toggleButton.Name = "ToggleButton"
	toggleButton.Size = UDim2.new(0, TOGGLE_WIDTH, 0, TOGGLE_HEIGHT)
	toggleButton.Position = UDim2.new(1, -TOGGLE_RIGHT_INSET, 1, -TOGGLE_BOTTOM_INSET)
	toggleButton.BackgroundColor3 = COLOR.Toggle
	toggleButton.BorderSizePixel = 0
	toggleButton.AutoButtonColor = false
	toggleButton.ZIndex = 10
	toggleButton.TextColor3 = COLOR.White
	toggleButton.TextSize = 22
	toggleButton.Font = Enum.Font.GothamBold
	toggleButton.Parent = screenGui
	_corner(toggleButton, 8)
	DebugI18n.applyButtonText(toggleButton, "调试窗口")
	_bindHover(toggleButton, COLOR.Toggle)

	toggleButton.MouseButton1Click:Connect(function()
		if mainFrame.Visible then
			mainFrame.Visible = false
			DebugI18n.applyButtonText(toggleButton, "调试窗口")
		else
			mainFrame.Visible = true
			DebugI18n.applyButtonText(toggleButton, "关闭调试")
		end
	end)

	host.uiRefs.ToggleButton = toggleButton
end

--[[
	创建动态按钮分区（分隔线、标题、滚动列表）
	@param contentFrame Frame - 内容列
	@param host Host - 共享状态
	@return nil
]]
local function _createDynamicSection(contentFrame: Frame, host: Host)
	local divider = Instance.new("Frame")
	divider.Name = "Divider"
	divider.Size = UDim2.new(1, 0, 0, 2)
	divider.BackgroundColor3 = COLOR.Divider
	divider.BorderSizePixel = 0
	divider.LayoutOrder = 4
	divider.Parent = contentFrame
	_corner(divider, 1)

	local buttonSectionTitle = Instance.new("TextLabel")
	buttonSectionTitle.Name = "ButtonSectionTitle"
	buttonSectionTitle.Size = UDim2.new(1, 0, 0, 30)
	buttonSectionTitle.BackgroundTransparency = 1
	buttonSectionTitle.TextColor3 = COLOR.White
	buttonSectionTitle.TextSize = 24
	buttonSectionTitle.Font = Enum.Font.GothamBold
	buttonSectionTitle.TextXAlignment = Enum.TextXAlignment.Left
	buttonSectionTitle.LayoutOrder = 5
	buttonSectionTitle.Parent = contentFrame
	TranslationHelper.SetText(buttonSectionTitle, "动态按钮")

	local buttonScrollFrame = Instance.new("ScrollingFrame")
	buttonScrollFrame.Name = "ButtonScrollFrame"
	buttonScrollFrame.Size = UDim2.new(1, -10, 0, DYNAMIC_SCROLL_HEIGHT)
	buttonScrollFrame.BackgroundTransparency = 1
	buttonScrollFrame.BorderSizePixel = 0
	buttonScrollFrame.ScrollBarThickness = 6
	buttonScrollFrame.ScrollBarImageColor3 = COLOR.Scroll
	buttonScrollFrame.LayoutOrder = 6
	buttonScrollFrame.Parent = contentFrame
	host.uiRefs.ButtonWindowScrollFrame = buttonScrollFrame

	local buttonListLayout = Instance.new("UIListLayout")
	buttonListLayout.FillDirection = Enum.FillDirection.Vertical
	buttonListLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	buttonListLayout.VerticalAlignment = Enum.VerticalAlignment.Top
	buttonListLayout.SortOrder = Enum.SortOrder.LayoutOrder
	buttonListLayout.Padding = UDim.new(0, 12)
	buttonListLayout.Parent = buttonScrollFrame

	_bindDebouncedLayout(buttonListLayout, function()
		buttonScrollFrame.CanvasSize = UDim2.new(0, 0, 0, buttonListLayout.AbsoluteContentSize.Y + CANVAS_PAD)
	end)
end

-- ========================================
-- 公共：整页构建
-- ========================================

--[[
	创建调试 ScreenGui（调用方保证尚未存在有效 UI）
	@param playerGui PlayerGui - 挂载点
	@param host Host - 共享状态与回调
	@param onClose () -> () - 标题栏关闭
	@return ScreenGui - 根 Gui
]]
function DebugPanel.build(playerGui: PlayerGui, host: Host, onClose: () -> ()): ScreenGui
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "DebugSystemUI"
	screenGui.ResetOnSpawn = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.DisplayOrder = DISPLAY_ORDER
	screenGui.IgnoreGuiInset = true
	screenGui.Parent = playerGui
	host.uiRefs.ScreenGui = screenGui

	local mainFrame = Instance.new("Frame")
	mainFrame.Name = "MainFrame"
	mainFrame.Size = UDim2.new(0, PANEL_WIDTH, 0, PANEL_HEIGHT)
	mainFrame.Position = UDim2.new(1, -PANEL_RIGHT_INSET, 0.5, -PANEL_HALF_HEIGHT)
	mainFrame.BackgroundColor3 = COLOR.PanelBg
	mainFrame.BorderSizePixel = 0
	mainFrame.ZIndex = 10
	mainFrame.Visible = false
	mainFrame.Parent = screenGui
	host.uiRefs.MainFrame = mainFrame
	_corner(mainFrame, 8)

	_createTitleBar(mainFrame, onClose)

	local scrollFrame = Instance.new("ScrollingFrame")
	scrollFrame.Name = "ContentScrollFrame"
	scrollFrame.Size = UDim2.new(1, 0, 1, -TITLE_HEIGHT)
	scrollFrame.Position = UDim2.new(0, 0, 0, TITLE_HEIGHT)
	scrollFrame.BackgroundTransparency = 1
	scrollFrame.BorderSizePixel = 0
	scrollFrame.ScrollBarThickness = 6
	scrollFrame.ScrollBarImageColor3 = COLOR.Scroll
	scrollFrame.Parent = mainFrame

	local contentFrame = Instance.new("Frame")
	contentFrame.Name = "ContentFrame"
	contentFrame.Size = UDim2.new(1, -CONTENT_RIGHT_PAD, 0, 0)
	contentFrame.Position = UDim2.new(0, CONTENT_LEFT, 0, 0)
	contentFrame.BackgroundTransparency = 1
	contentFrame.Parent = scrollFrame

	local contentListLayout = Instance.new("UIListLayout")
	contentListLayout.FillDirection = Enum.FillDirection.Vertical
	contentListLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	contentListLayout.VerticalAlignment = Enum.VerticalAlignment.Top
	contentListLayout.SortOrder = Enum.SortOrder.LayoutOrder
	contentListLayout.Padding = UDim.new(0, 8)
	contentListLayout.Parent = contentFrame

	local contentPad = Instance.new("UIPadding")
	contentPad.PaddingTop = UDim.new(0, CONTENT_PAD_TOP)
	contentPad.Parent = contentFrame

	_createBagSection(contentFrame, host)
	_createDynamicSection(contentFrame, host)
	_createToggleButton(screenGui, mainFrame, host)

	_bindDebouncedLayout(contentListLayout, function()
		contentFrame.Size = UDim2.new(1, -CONTENT_RIGHT_PAD, 0, contentListLayout.AbsoluteContentSize.Y + CANVAS_PAD)
		scrollFrame.CanvasSize = UDim2.new(0, 0, 0, contentFrame.Size.Y.Offset)
	end)

	DebugPanel.createAllDynamicButtons(host)
	return screenGui
end

DebugPanel.applyButtonText = DebugI18n.applyButtonText
DebugPanel.applyInputGroupTexts = DebugI18n.applyInputGroupTexts

return DebugPanel
