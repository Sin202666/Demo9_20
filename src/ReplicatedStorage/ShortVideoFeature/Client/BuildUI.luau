--[[
	Module: BuildUI
	Description: U1 深色风 SurfaceGui 控件树（视频底板内：顶栏/视频/动作栏/进度条/评论抽屉/Loading）
	Author: 林奥宇
	Created: 2026-08-13
	Last Modified: 2026-09-01

	2D Screen 模式优先使用 Assets.ScreenGui.ShortVideoScreen；本模块作 3D / 预制体缺失时的回退构建。
	切集 Prev/Next 不在本树内，由 SceneBoard 在底板外两侧独立 SurfaceGui 创建；键位字见 AttachNavKeyLabel。
	键位设备适配（优先手柄）：移动隐藏；手柄 L1/R1 或 LB/RB（可区分则单种，否则两种都显示）；PC 为 Q/E。
	移动判定会话内锁存，避免 Studio 手机模拟器下 PreferredInput 在 Touch 与键鼠间抖动导致 KeyLabel 闪烁。
	动作栏图标、进度条与 Loading 图见 Shared/Constants.UI；评论行含 TimeLabel / AvatarBg / LikeIcon；
	评论行对齐 List.RowTemplate（无行 AspectRatio；正文扩高见 UiPrefabUtil.ApplyCommentBodyFit）；
	评论抽屉 Header 含 SortHotBtn / SortNewestBtn（文案在子 TextLabel；Top / Newest）。
]]

local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local TranslationHelper = Utils.TranslationHelper

local Constants = require(script.Parent.Parent.Shared.Constants)
local UiAssets = require(script.Parent.UiAssets)

local BuildUI = {}

local COLORS = Constants.COLORS

-- 会话内一旦判定移动端则锁住，防止切集点击触发 PreferredInput 抖动导致 Q/E 显隐闪烁
local _mobileInputLatched = false
local _deviceMobileResolved = false
local _deviceMobileCached: boolean? = nil

--[[
	软读 DeviceType.IsMobile（与工程设备判定对齐；无 Utils 时跳过；结果缓存一次）
	@return boolean? - 已知移动端为 true；非移动为 false；不可用为 nil
]]
local function _tryDeviceTypeIsMobile(): boolean?
	if _deviceMobileResolved then
		return _deviceMobileCached
	end
	_deviceMobileResolved = true
	local ok, utils = pcall(function()
		return require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
	end)
	if not ok or not utils or not utils.DeviceType then
		_deviceMobileCached = nil
		return nil
	end
	local dt = utils.DeviceType
	if type(dt.IsMobile) ~= "function" then
		_deviceMobileCached = nil
		return nil
	end
	_deviceMobileCached = dt.IsMobile() == true
	return _deviceMobileCached
end

--[[
	是否为移动端（触控为主；对齐 DeviceType；Studio 模拟器 TouchEnabled 兜底）
	@return boolean - 移动端为 true
]]
local function _isMobileInput(): boolean
	if _mobileInputLatched then
		return true
	end

	local isMobile = false
	local deviceMobile = _tryDeviceTypeIsMobile()
	if deviceMobile == true then
		isMobile = true
	elseif UserInputService.PreferredInput == Enum.PreferredInput.Touch then
		isMobile = true
	elseif UserInputService.TouchEnabled
		and not UserInputService.MouseEnabled
		and not UserInputService.KeyboardEnabled
		and not UserInputService.GamepadEnabled
	then
		isMobile = true
	elseif RunService:IsStudio() and UserInputService.TouchEnabled then
		-- Studio 设备模拟器选手机后 TouchEnabled 为 true，但 Mouse/Keyboard 常仍为 true
		isMobile = true
	end

	if isMobile then
		_mobileInputLatched = true
	end
	return isMobile
end

--[[
	当前是否应显示手柄键位（有手柄时优先于 PC 键鼠字）
	@return boolean - 应显示手柄键位为 true
]]
local function _preferGamepadKeyHint(): boolean
	return UserInputService.GamepadEnabled == true
		or UserInputService.PreferredInput == Enum.PreferredInput.Gamepad
end

--[[
	解析手柄肩键文案；能区分 PS/Xbox 则单种，否则两种都显示
	@param isPrev boolean - 左切集为 true
	@param nav any - Nav 配置
	@return string - 键位字
]]
local function _resolveGamepadKeyText(isPrev: boolean, nav: any): string
	local ok, mapped = pcall(function()
		return UserInputService:GetStringForKeyCode(Enum.KeyCode.ButtonA)
	end)
	if ok and type(mapped) == "string" then
		if mapped == "ButtonCross" then
			return if isPrev then (nav.KeyPrevGamepadPS or "L1") else (nav.KeyNextGamepadPS or "R1")
		end
		-- 可解析且非 PS → 按 Xbox 系肩键
		return if isPrev then (nav.KeyPrevGamepadXbox or "LB") else (nav.KeyNextGamepadXbox or "RB")
	end
	-- 无法区分手柄类型时两种都显示
	return if isPrev then (nav.KeyPrevGamepadBoth or "L1/LB") else (nav.KeyNextGamepadBoth or "R1/RB")
end

--[[
	按设备解析切集键位字；移动端返回 nil 表示隐藏
	@param isPrev boolean - 左切集为 true
	@param nav any - Nav 配置
	@return string? - 键位字；nil 表示隐藏
]]
local function _resolveNavKeyText(isPrev: boolean, nav: any): string?
	-- PC+手柄同时存在时优先主机适配
	if _preferGamepadKeyHint() then
		return _resolveGamepadKeyText(isPrev, nav)
	end
	if _isMobileInput() then
		return nil
	end
	return if isPrev then (nav.KeyPrev or "Q") else (nav.KeyNext or "E")
end

--[[
	写入或更新 KeyLabel 显隐与文案
	@param btn ImageButton - Prev/Next
	@param side "prev" | "next" - 左/右
	@param uiCfg any? - UI 配置
]]
local function _applyNavKeyLabel(btn: ImageButton, side: string, uiCfg: any?)
	local nav = (uiCfg or Constants.UI).Nav
	local isPrev = side == "prev"
	local keyText = _resolveNavKeyText(isPrev, nav)

	local label = btn:FindFirstChild("KeyLabel")
	if not label or not label:IsA("TextLabel") then
		label = Instance.new("TextLabel")
		label.Name = "KeyLabel"
		label.BackgroundTransparency = 1
		label.Size = UDim2.fromScale(1, 1)
		label.Font = Enum.Font.GothamBold
		label.Parent = btn
		local stroke = Instance.new("UIStroke")
		stroke.Name = "KeyStroke"
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
		stroke.Parent = label
	end

	local stroke = label:FindFirstChild("KeyStroke")
	if stroke and stroke:IsA("UIStroke") then
		stroke.Thickness = tonumber(nav.KeyStrokeThickness) or 2
		stroke.Color = nav.KeyStrokeColor or Color3.fromRGB(255, 255, 255)
	end

	label.TextSize = tonumber(nav.KeyTextSize) or 42
	label.TextColor3 = nav.KeyTextColor or Color3.fromRGB(20, 20, 20)
	label.Font = Enum.Font.GothamBold
	label.ZIndex = btn.ZIndex + 2

	if keyText == nil then
		label.Text = ""
		label.Visible = false
	else
		label.Text = keyText
		label.Visible = true
	end
end

--[[
	创建 TextLabel
	@param parent Instance - 父级
	@param name string - 名
	@param props table - 属性
	@return TextLabel
]]
local function textLabel(parent: Instance, name: string, props: { [string]: any }): TextLabel
	local t = Instance.new("TextLabel")
	t.Name = name
	t.BackgroundTransparency = 1
	t.Font = Enum.Font.GothamMedium
	t.TextColor3 = COLORS.Text
	t.TextScaled = false
	t.TextSize = 18
	t.TextXAlignment = Enum.TextXAlignment.Left
	for k, v in pairs(props) do
		(t :: any)[k] = v
	end
	t.Parent = parent
	return t
end

--[[
	创建 TextButton（抽屉等文字按钮）
	@param parent Instance - 父级
	@param name string - 名
	@param props table - 属性
	@return TextButton
]]
local function textButton(parent: Instance, name: string, props: { [string]: any }): TextButton
	local b = Instance.new("TextButton")
	b.Name = name
	b.AutoButtonColor = false
	b.Active = true
	b.Selectable = true
	b.Font = Enum.Font.GothamBold
	b.TextColor3 = COLORS.Text
	b.TextSize = 22
	b.BackgroundColor3 = COLORS.Line
	b.BorderSizePixel = 0
	b.ZIndex = 5
	for k, v in pairs(props) do
		(b :: any)[k] = v
	end
	b.Parent = parent
	return b
end

--[[
	创建动作栏 ImageButton（透明底 + 可配图）
	@param parent Instance - 父级
	@param name string - 名
	@param y number - 顶部 Y 偏移
	@param image any - 图资源
	@param fallback string - 无图文字
	@return ImageButton
]]
local function actionImageButton(
	parent: Instance,
	name: string,
	y: number,
	btnSize: Vector2,
	image: any,
	fallback: string
): ImageButton
	local size = btnSize
	local b = Instance.new("ImageButton")
	b.Name = name
	b.AutoButtonColor = false
	b.Active = true
	b.Selectable = true
	b.Size = UDim2.fromOffset(size.X, size.Y)
	b.Position = UDim2.new(0.5, -size.X / 2, 0, y)
	b.BackgroundTransparency = 1
	b.BorderSizePixel = 0
	b.Image = ""
	b.ScaleType = Enum.ScaleType.Fit
	b.ZIndex = 6
	b.Parent = parent
	UiAssets.ApplyButtonImage(b, image, fallback)
	return b
end

--[[
	为赞/评计数应用视觉稿字号、描边与透明度
	@param label TextLabel - 计数 Label
	@param action any - Constants.UI.Action
]]
local function styleCountLabel(label: TextLabel, action: any)
	label.TextSize = tonumber(action.CountTextSize) or 28
	label.TextColor3 = action.CountTextColor or Color3.fromRGB(255, 255, 255)
	label.TextTransparency = if typeof(action.CountTextTransparency) == "number" then action.CountTextTransparency else 0.5
	label.Font = Enum.Font.GothamBold
	local existing = label:FindFirstChild("CountStroke")
	if existing and not existing:IsA("UIStroke") then
		existing:Destroy()
		existing = nil
	end
	local stroke: UIStroke
	if existing and existing:IsA("UIStroke") then
		stroke = existing
	else
		stroke = Instance.new("UIStroke")
		stroke.Name = "CountStroke"
		stroke.Parent = label
	end
	stroke.Thickness = tonumber(action.CountStrokeThickness) or 2
	stroke.Color = action.CountStrokeColor or Color3.fromRGB(0, 0, 0)
	stroke.Transparency = 0
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
end

--[[
	在切集按钮上叠加键位字（按设备适配；有图时也显示）
	@param btn ImageButton - Prev/Next
	@param side "prev" | "next" - 左/右
	@param uiCfg any? - UI 配置
]]
function BuildUI.AttachNavKeyLabel(btn: ImageButton, side: string, uiCfg: any?)
	_applyNavKeyLabel(btn, side, uiCfg)
end

--[[
	按当前输入设备刷新左右切集键位字（手柄插拔 / PreferredInput 变化时调用）
	@param prevBtn ImageButton? - 上一集按钮
	@param nextBtn ImageButton? - 下一集按钮
	@param uiCfg any? - UI 配置
]]
function BuildUI.RefreshNavKeyLabels(prevBtn: ImageButton?, nextBtn: ImageButton?, uiCfg: any?)
	if prevBtn then
		_applyNavKeyLabel(prevBtn, "prev", uiCfg)
	end
	if nextBtn then
		_applyNavKeyLabel(nextBtn, "next", uiCfg)
	end
end

--[[
	在 SurfaceGui / ScreenGui 面板下构建完整 UI（不含左右切集）
	@param parent Instance - SurfaceGui 或承载 Frame
	@param uiCfg any? - UI 配置
	@return Frame - 业务 Root（Content，已内缩；外圈透明露霓虹边）
]]
function BuildUI.Build(parent: Instance, uiCfg: any?): Frame
	local UI = uiCfg or Constants.UI
	local board = UI.Board or {}
	local pad = tonumber(board.PaddingPx) or 6
	parent:ClearAllChildren()

	-- 外壳透明：四周留白露出底层 Neon 底板，形成白边框
	local shell = Instance.new("Frame")
	shell.Name = "Root"
	shell.Size = UDim2.fromScale(1, 1)
	shell.BackgroundTransparency = 1
	shell.BorderSizePixel = 0
	shell.Parent = parent

	local root = Instance.new("Frame")
	root.Name = "Content"
	root.Size = UDim2.new(1, -pad * 2, 1, -pad * 2)
	root.Position = UDim2.fromOffset(pad, pad)
	root.BackgroundColor3 = COLORS.Bg
	root.BorderSizePixel = 0
	root.ClipsDescendants = true
	root.Parent = shell

	local strokeThickness = tonumber(board.StrokeThickness) or 0
	if strokeThickness > 0 then
		local stroke = Instance.new("UIStroke")
		stroke.Name = "ContentStroke"
		stroke.Thickness = strokeThickness
		stroke.Color = board.StrokeColor or Color3.fromRGB(255, 255, 255)
		stroke.Transparency = if typeof(board.StrokeTransparency) == "number" then board.StrokeTransparency else 0
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.Parent = root
	end

	local topBar = Instance.new("Frame")
	topBar.Name = "TopBar"
	topBar.Size = UDim2.new(1, 0, 0, 48)
	topBar.BackgroundTransparency = 1
	topBar.ZIndex = 5
	topBar.Parent = root

	textLabel(topBar, "TitleLabel", {
		Size = UDim2.new(1, -64, 1, 0),
		Position = UDim2.fromOffset(12, 0),
		Text = "",
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = 5,
	})

	local topCfg = UI.TopBar or {}
	local closeBtn = Instance.new("ImageButton")
	closeBtn.Name = "CloseBtn"
	closeBtn.AutoButtonColor = false
	closeBtn.Active = true
	closeBtn.Selectable = true
	closeBtn.Size = UDim2.fromOffset(40, 40)
	closeBtn.Position = UDim2.new(1, -48, 0.5, -20)
	closeBtn.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
	closeBtn.BackgroundTransparency = 0.2
	closeBtn.BorderSizePixel = 0
	closeBtn.ScaleType = Enum.ScaleType.Fit
	closeBtn.ZIndex = 6
	closeBtn.Parent = topBar
	local closeCorner = Instance.new("UICorner")
	closeCorner.CornerRadius = UDim.new(0, 8)
	closeCorner.Parent = closeBtn
	UiAssets.ApplyButtonImage(closeBtn, topCfg.ImageClose, topCfg.FallbackCloseText or "X")

	-- 视频区：底座比例内留白；片源按宽度铺满、高度可不足
	local videoContainer = Instance.new("Frame")
	videoContainer.Name = "VideoContainer"
	videoContainer.Size = UDim2.fromScale(1, 1)
	videoContainer.BackgroundColor3 = COLORS.Bg
	videoContainer.BorderSizePixel = 0
	videoContainer.ClipsDescendants = true
	videoContainer.ZIndex = 1
	videoContainer.Parent = root

	local mainVideo = Instance.new("VideoFrame")
	mainVideo.Name = "MainVideo"
	mainVideo.AnchorPoint = Vector2.new(0.5, 0.5)
	mainVideo.Position = UDim2.fromScale(0.5, 0.5)
	mainVideo.Size = UDim2.fromScale(1, 1)
	mainVideo.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	mainVideo.BorderSizePixel = 0
	mainVideo.Looped = true
	mainVideo.Active = false
	mainVideo.ZIndex = 1
	mainVideo.Parent = videoContainer

	-- 点击层：切换暂停（低于 ActionRail / TopBar，不挡按钮）
	local tapLayer = Instance.new("TextButton")
	tapLayer.Name = "VideoTapLayer"
	tapLayer.Size = UDim2.fromScale(1, 1)
	tapLayer.BackgroundTransparency = 1
	tapLayer.BorderSizePixel = 0
	tapLayer.Text = ""
	tapLayer.AutoButtonColor = false
	tapLayer.ZIndex = 2
	tapLayer.Parent = videoContainer

	local pauseCfg = UI.Pause or {}
	local pauseSize = pauseCfg.Size or Vector2.new(130, 130)
	local pauseIcon = Instance.new("ImageLabel")
	pauseIcon.Name = "PauseIcon"
	pauseIcon.AnchorPoint = Vector2.new(0.5, 0.5)
	pauseIcon.Position = UDim2.fromScale(0.5, 0.5)
	pauseIcon.Size = UDim2.fromOffset(pauseSize.X, pauseSize.Y)
	pauseIcon.BackgroundTransparency = 1
	pauseIcon.BorderSizePixel = 0
	pauseIcon.Image = UiAssets.ToImage(pauseCfg.Image)
	pauseIcon.ScaleType = Enum.ScaleType.Fit
	pauseIcon.Visible = false
	pauseIcon.ZIndex = 3
	pauseIcon.Parent = videoContainer

	local preload1 = Instance.new("VideoFrame")
	preload1.Name = "PreloadVideo1"
	preload1.Size = UDim2.fromOffset(1, 1)
	preload1.Position = UDim2.fromOffset(-100, -100)
	preload1.Visible = false
	preload1.Looped = true
	preload1.Volume = 0
	preload1.Parent = root

	local preload2 = Instance.new("VideoFrame")
	preload2.Name = "PreloadVideo2"
	preload2.Size = UDim2.fromOffset(1, 1)
	preload2.Position = UDim2.fromOffset(-100, -100)
	preload2.Visible = false
	preload2.Looped = true
	preload2.Volume = 0
	preload2.Parent = root

	local preload3 = Instance.new("VideoFrame")
	preload3.Name = "PreloadVideo3"
	preload3.Size = UDim2.fromOffset(1, 1)
	preload3.Position = UDim2.fromOffset(-100, -100)
	preload3.Visible = false
	preload3.Looped = true
	preload3.Volume = 0
	preload3.Parent = root

	-- 右侧动作栏：赞 / 评 / 分享（计数挂在按钮内，槽高不含 CountHeight）
	local action = UI.Action
	local slotH = action.BtnSize.Y + action.Spacing
	local railH = slotH * 3 - action.Spacing
	local rail = Instance.new("Frame")
	rail.Name = "ActionRail"
	rail.Size = UDim2.fromOffset(action.RailWidth, railH)
	rail.AnchorPoint = Vector2.new(1, 0.5)
	rail.Position = UDim2.new(1, -action.MarginRight, action.AnchorY, 0)
	rail.BackgroundTransparency = 1
	rail.ZIndex = 5
	rail.Parent = root

	local y0 = 0
	local likeBtn = actionImageButton(rail, "LikeBtn", y0, action.BtnSize, action.ImageLike, action.FallbackLike)
	local likeCount = textLabel(likeBtn, "LikeCount", {
		Size = UDim2.new(1, 0, 0, action.CountHeight),
		Position = UDim2.fromScale(0, 0.9),
		Text = "0",
		TextXAlignment = Enum.TextXAlignment.Center,
		TextScaled = true,
		ZIndex = 6,
	})
	styleCountLabel(likeCount, action)

	local y1 = slotH
	local commentBtn = actionImageButton(rail, "CommentBtn", y1, action.BtnSize, action.ImageComment, action.FallbackComment)
	local cmtCount = textLabel(commentBtn, "CommentCount", {
		Size = UDim2.new(1, 0, 0, action.CountHeight),
		Position = UDim2.fromScale(0, 0.9),
		Text = "0",
		TextXAlignment = Enum.TextXAlignment.Center,
		TextScaled = true,
		ZIndex = 6,
	})
	styleCountLabel(cmtCount, action)

	local y2 = slotH * 2
	local shareBtn = actionImageButton(rail, "ShareBtn", y2, action.BtnSize, action.ImageShare, action.FallbackShare)
	-- 分享无计数，占位对齐高度
	textLabel(shareBtn, "ShareSpacer", {
		Size = UDim2.new(1, 0, 0, action.CountHeight),
		Position = UDim2.fromScale(0, 0.9),
		Text = "",
		ZIndex = 6,
	})

	-- 底部播放进度条（视觉稿：白底轨 + #26d956 填充，高 12，底边 -3）
	local progressCfg = UI.Progress or {}
	local progressH = tonumber(progressCfg.Height) or 12
	local progressOffsetY = if typeof(progressCfg.OffsetY) == "number" then progressCfg.OffsetY else -3
	local progressBar = Instance.new("Frame")
	progressBar.Name = "ProgressBar"
	progressBar.AnchorPoint = Vector2.new(0, 1)
	progressBar.Position = UDim2.new(0, 0, 1, progressOffsetY)
	progressBar.Size = UDim2.new(1, 0, 0, progressH)
	progressBar.BackgroundColor3 = progressCfg.TrackColor or Color3.fromRGB(255, 255, 255)
	progressBar.BackgroundTransparency = if typeof(progressCfg.TrackTransparency) == "number"
		then progressCfg.TrackTransparency
		else 0.15
	progressBar.BorderSizePixel = 0
	progressBar.ZIndex = tonumber(progressCfg.ZIndex) or 7
	progressBar.ClipsDescendants = true
	progressBar.Parent = root

	local progressFill = Instance.new("Frame")
	progressFill.Name = "Fill"
	progressFill.Size = UDim2.new(0, 0, 1, 0)
	progressFill.BackgroundColor3 = progressCfg.FillColor or COLORS.Progress or Color3.fromRGB(38, 217, 86)
	progressFill.BackgroundTransparency = 0
	progressFill.BorderSizePixel = 0
	progressFill.ZIndex = progressBar.ZIndex + 1
	progressFill.Parent = progressBar

	local drawer = Instance.new("Frame")
	drawer.Name = "CommentDrawer"
	drawer.Size = UDim2.new(1, 0, 0.45, 0)
	drawer.Position = UDim2.new(0, 0, 0.55, 0)
	drawer.BackgroundColor3 = COLORS.Drawer
	drawer.BorderSizePixel = 0
	drawer.Visible = false
	drawer.ZIndex = 10
	drawer.Parent = root

	local dimmer = textButton(drawer, "Dimmer", {
		Size = UDim2.new(1, 0, 0, 0),
		Position = UDim2.fromScale(0, 0),
		Text = "",
		BackgroundTransparency = 1,
		ZIndex = 10,
	})
	dimmer.Size = UDim2.new(1, 0, 0, 1)

	local header = Instance.new("Frame")
	header.Name = "Header"
	header.Size = UDim2.new(1, 0, 0, 40)
	header.BackgroundTransparency = 1
	header.ZIndex = 11
	header.Parent = drawer

	-- 排序切换：Top（赞序）/ Newest（时间序），挂在 Header 下；文案在子 TextLabel
	local sortHot = textButton(header, "SortHotBtn", {
		Size = UDim2.fromOffset(72, 26),
		Position = UDim2.fromOffset(12, 7),
		Text = "",
		ZIndex = 12,
	})
	sortHot.BackgroundColor3 = COLORS.SortSelectedBg
	sortHot.BackgroundTransparency = 0
	local sortHotCorner = Instance.new("UICorner")
	sortHotCorner.CornerRadius = UDim.new(0, 6)
	sortHotCorner.Parent = sortHot
	textLabel(sortHot, "TextLabel", {
		Size = UDim2.fromScale(1, 1),
		Text = "Top",
		TextSize = 14,
		TextColor3 = COLORS.SortSelectedText,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextYAlignment = Enum.TextYAlignment.Center,
		ZIndex = 13,
	})

	local sortNewest = textButton(header, "SortNewestBtn", {
		Size = UDim2.fromOffset(72, 26),
		Position = UDim2.fromOffset(92, 7),
		Text = "",
		ZIndex = 12,
	})
	sortNewest.BackgroundColor3 = COLORS.SortUnselectedBg
	sortNewest.BackgroundTransparency = 0
	local sortNewestCorner = Instance.new("UICorner")
	sortNewestCorner.CornerRadius = UDim.new(0, 6)
	sortNewestCorner.Parent = sortNewest
	textLabel(sortNewest, "TextLabel", {
		Size = UDim2.fromScale(1, 1),
		Text = "Newest",
		TextSize = 14,
		TextColor3 = COLORS.SortUnselectedText,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextYAlignment = Enum.TextYAlignment.Center,
		ZIndex = 13,
	})

	local titleLabel = textLabel(header, "Title", {
		Size = UDim2.new(1, -220, 1, 0),
		Position = UDim2.fromOffset(172, 0),
		Text = "",
		ZIndex = 11,
	})
	TranslationHelper.SetText(titleLabel, "短视频评论")
	textButton(header, "CloseDrawerBtn", {
		Size = UDim2.fromOffset(40, 32),
		Position = UDim2.new(1, -48, 0.5, -16),
		Text = "X",
		TextSize = 16,
		ZIndex = 11,
	})

	local list = Instance.new("ScrollingFrame")
	list.Name = "List"
	list.Size = UDim2.new(1, -16, 1, -92) -- Header40 + Input44 + pad
	list.Position = UDim2.fromOffset(8, 40)
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.ScrollBarThickness = 6
	list.ScrollingDirection = Enum.ScrollingDirection.Y
	list.ElasticBehavior = Enum.ElasticBehavior.Always
	list.CanvasSize = UDim2.fromOffset(0, 0)
	list.ZIndex = 11
	list.Parent = drawer

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 6)
	layout.Parent = list

	local template = Instance.new("Frame")
	template.Name = "RowTemplate"
	-- 对齐 List.RowTemplate：单行稿高 = List 高 * COMMENT_ROW_HEIGHT_SCALE；无行级 AspectRatio
	template.Size = UDim2.new(1, 0, Constants.COMMENT_ROW_HEIGHT_SCALE or 0.2, 0)
	template.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	template.BorderSizePixel = 0
	template.Visible = false
	template.ZIndex = 11
	template.Parent = drawer

	local rowLayout = Constants.COMMENT_ROW_LAYOUT
		or {
			Name = { X = 0.18, Y = 0.12, W = 0.8, H = 0.28061226 },
			Body = { X = 0.185, Y = 0.45, W = 0.65, H = 0.263605446 },
			Time = { X = 0.185, Y = 0.72, W = 0.65, H = 0.255102038 },
		}

	local avatarBg = Instance.new("Frame")
	avatarBg.Name = "AvatarBg"
	avatarBg.Size = UDim2.fromScale(0.7, 0.7)
	avatarBg.Position = UDim2.fromScale(0.02, 0.1)
	avatarBg.BackgroundColor3 = Color3.fromRGB(167, 167, 167)
	avatarBg.BorderSizePixel = 0
	avatarBg.ZIndex = 11
	avatarBg.Parent = template
	local avatarBgCorner = Instance.new("UICorner")
	avatarBgCorner.CornerRadius = UDim.new(1, 0)
	avatarBgCorner.Parent = avatarBg
	local avatarBgAspect = Instance.new("UIAspectRatioConstraint")
	avatarBgAspect.AspectRatio = 1
	avatarBgAspect.Parent = avatarBg

	local avatar = Instance.new("ImageLabel")
	avatar.Name = "Avatar"
	avatar.Size = UDim2.fromScale(1, 1)
	avatar.AnchorPoint = Vector2.new(0.5, 0.5)
	avatar.Position = UDim2.fromScale(0.5, 0.5)
	avatar.BackgroundTransparency = 1
	avatar.BorderSizePixel = 0
	avatar.ZIndex = 12
	avatar.Parent = avatarBg
	local avatarCorner = Instance.new("UICorner")
	avatarCorner.CornerRadius = UDim.new(1, 0)
	avatarCorner.Parent = avatar

	textLabel(template, "NameLabel", {
		Size = UDim2.fromScale(rowLayout.Name.W, rowLayout.Name.H),
		Position = UDim2.fromScale(rowLayout.Name.X, rowLayout.Name.Y),
		Text = "",
		TextSize = 14,
		TextScaled = true,
		TextWrapped = true,
		ZIndex = 12,
	})
	textLabel(template, "BodyLabel", {
		Size = UDim2.fromScale(rowLayout.Body.W, rowLayout.Body.H),
		Position = UDim2.fromScale(rowLayout.Body.X, rowLayout.Body.Y),
		Text = "",
		TextColor3 = COLORS.Text,
		TextSize = 14,
		TextScaled = true,
		TextWrapped = true,
		RichText = true,
		ZIndex = 12,
	})
	textLabel(template, "TimeLabel", {
		Size = UDim2.fromScale(rowLayout.Time.W, rowLayout.Time.H),
		Position = UDim2.fromScale(rowLayout.Time.X, rowLayout.Time.Y),
		Text = "",
		TextColor3 = Color3.fromRGB(86, 86, 86),
		TextSize = 14,
		TextScaled = true,
		TextWrapped = true,
		ZIndex = 12,
	})

	-- 评论点赞：对齐 List 正确版（Scale 尺寸；LikeIcon 子层；LikeCount 挂行上）
	local cmtLikeBtn = Instance.new("ImageButton")
	cmtLikeBtn.Name = "LikeBtn"
	cmtLikeBtn.AutoButtonColor = false
	cmtLikeBtn.Active = true
	cmtLikeBtn.Selectable = true
	cmtLikeBtn.Size = UDim2.fromScale(0.136, 0.68)
	cmtLikeBtn.AnchorPoint = Vector2.new(0.5, 0.5)
	cmtLikeBtn.Position = UDim2.fromScale(0.87, 0.5)
	cmtLikeBtn.BackgroundTransparency = 1
	cmtLikeBtn.BorderSizePixel = 0
	cmtLikeBtn.Image = ""
	cmtLikeBtn.ZIndex = 12
	cmtLikeBtn.Parent = template
	local likeIcon = Instance.new("ImageLabel")
	likeIcon.Name = "LikeIcon"
	likeIcon.BackgroundTransparency = 1
	likeIcon.AnchorPoint = Vector2.new(0.5, 0.5)
	likeIcon.Position = UDim2.fromScale(0.5, 0.5)
	likeIcon.Size = UDim2.fromScale(0.4, 0.4)
	likeIcon.ScaleType = Enum.ScaleType.Fit
	likeIcon.ZIndex = 13
	likeIcon.Parent = cmtLikeBtn
	local cmtLikeCfg = UI.CommentLike or action
	UiAssets.ApplyButtonImage(cmtLikeBtn, cmtLikeCfg.ImageLike, cmtLikeCfg.FallbackLike)

	textLabel(template, "LikeCount", {
		Size = UDim2.fromScale(0.1, 0.25),
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		Text = "0",
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = COLORS.Text,
		TextSize = 12,
		TextScaled = true,
		ZIndex = 12,
	})

	local inputFrame = Instance.new("Frame")
	inputFrame.Name = "InputFrame"
	inputFrame.Size = UDim2.new(1, 0, 0, 44)
	inputFrame.Position = UDim2.new(0, 0, 1, -44)
	inputFrame.BackgroundTransparency = 1
	inputFrame.BorderSizePixel = 0
	inputFrame.ZIndex = 11
	inputFrame.Parent = drawer

	local inputBg = Instance.new("Frame")
	inputBg.Name = "InputBG"
	inputBg.Size = UDim2.new(0.835, 0, 0, 44)
	inputBg.Position = UDim2.new(0.01, 0, 1, -44)
	inputBg.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	inputBg.BorderSizePixel = 0
	inputBg.ZIndex = 11
	inputBg.Parent = inputFrame
	local inputBgCorner = Instance.new("UICorner")
	inputBgCorner.CornerRadius = UDim.new(0, 8)
	inputBgCorner.Parent = inputBg

	local input = Instance.new("TextBox")
	input.Name = "Input"
	input.Size = UDim2.fromScale(0.8, 0.9)
	input.Position = UDim2.fromScale(0.03, 0.5)
	input.AnchorPoint = Vector2.new(0, 0.5)
	input.BackgroundTransparency = 1
	input.BorderSizePixel = 0
	input.Font = Enum.Font.Gotham
	input.TextColor3 = COLORS.Text
	input.PlaceholderColor3 = COLORS.Muted
	input.Text = ""
	input.TextSize = 16
	input.TextScaled = true
	input.ClearTextOnFocus = false
	input.ZIndex = 11
	input.Parent = inputBg
	TranslationHelper.SetText(input, "短视频评论占位")

	local sendCfg = UI.Send or {}
	local sendBtn = Instance.new("TextButton")
	sendBtn.Name = "SendBtn"
	sendBtn.AutoButtonColor = false
	sendBtn.Active = true
	sendBtn.Selectable = true
	sendBtn.Size = UDim2.fromOffset(76, 44)
	sendBtn.AnchorPoint = Vector2.new(1, 0.5)
	sendBtn.Position = UDim2.new(0.99, 0, 0.5, 0)
	sendBtn.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	sendBtn.BorderSizePixel = 0
	sendBtn.Text = ""
	sendBtn.ZIndex = 11
	sendBtn.Parent = inputFrame
	local sendCorner = Instance.new("UICorner")
	sendCorner.CornerRadius = UDim.new(0, 8)
	sendCorner.Parent = sendBtn
	local sendIcon = Instance.new("ImageLabel")
	sendIcon.Name = "SendIcon"
	sendIcon.AnchorPoint = Vector2.new(0.5, 0.5)
	sendIcon.Position = UDim2.fromScale(0.5, 0.5)
	sendIcon.Size = UDim2.fromOffset(36, 36)
	sendIcon.BackgroundTransparency = 1
	sendIcon.BorderSizePixel = 0
	sendIcon.Image = UiAssets.ToImage(sendCfg.Image)
	sendIcon.ScaleType = Enum.ScaleType.Fit
	sendIcon.ZIndex = 12
	sendIcon.Parent = sendBtn

	-- Loading 遮罩 + 转圈（图可配置）
	local loadingOverlay = Instance.new("Frame")
	loadingOverlay.Name = "LoadingOverlay"
	loadingOverlay.Size = UDim2.fromScale(1, 1)
	loadingOverlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	loadingOverlay.BackgroundTransparency = 0.45
	loadingOverlay.BorderSizePixel = 0
	loadingOverlay.Visible = false
	loadingOverlay.ZIndex = 8
	loadingOverlay.Parent = root

	local spinSize = UI.Loading.Size
	local spinner = Instance.new("ImageLabel")
	spinner.Name = "Spinner"
	spinner.AnchorPoint = Vector2.new(0.5, 0.5)
	spinner.Position = UDim2.fromScale(0.5, 0.5)
	spinner.Size = UDim2.fromOffset(spinSize.X, spinSize.Y)
	spinner.BackgroundTransparency = 1
	spinner.BorderSizePixel = 0
	spinner.Image = UiAssets.ToImage(UI.Loading.Image)
	spinner.ScaleType = Enum.ScaleType.Fit
	spinner.ZIndex = 9
	spinner.Parent = loadingOverlay

	-- 无配置图时：圆环 + 高亮弧作为经典转圈
	if spinner.Image == "" then
		spinner.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		spinner.BackgroundTransparency = 1
		local ring = Instance.new("Frame")
		ring.Name = "Ring"
		ring.Size = UDim2.fromScale(1, 1)
		ring.BackgroundTransparency = 1
		ring.BorderSizePixel = 0
		ring.ZIndex = 9
		ring.Parent = spinner
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = ring
		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 4
		stroke.Color = Color3.fromRGB(220, 220, 220)
		stroke.Transparency = 0.35
		stroke.Parent = ring
		local arc = Instance.new("Frame")
		arc.Name = "Arc"
		arc.AnchorPoint = Vector2.new(0.5, 0)
		arc.Position = UDim2.new(0.5, 0, 0, 2)
		arc.Size = UDim2.new(0, 8, 0, math.floor(spinSize.Y * 0.28))
		arc.BackgroundColor3 = COLORS.Accent
		arc.BorderSizePixel = 0
		arc.ZIndex = 10
		arc.Parent = spinner
		local arcCorner = Instance.new("UICorner")
		arcCorner.CornerRadius = UDim.new(1, 0)
		arcCorner.Parent = arc
	end

	textLabel(loadingOverlay, "LoadingLabel", {
		Size = UDim2.new(1, -24, 0, 24),
		Position = UDim2.new(0, 12, 0.5, spinSize.Y / 2 + 12),
		Text = UI.Loading.FallbackText or "",
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = COLORS.Muted,
		TextSize = 16,
		ZIndex = 9,
	})

	return root
end

--[[
	构建底板外单侧切集 SurfaceGui 内容
	@param surfaceGui SurfaceGui - 侧板 Gui
	@param side "prev" | "next" - 左/右
	@return ImageButton - 切集按钮
]]
function BuildUI.BuildNavButton(surfaceGui: SurfaceGui, side: string, uiCfg: any?): ImageButton
	surfaceGui:ClearAllChildren()
	local nav = (uiCfg or Constants.UI).Nav
	local isPrev = side == "prev"
	local root = Instance.new("Frame")
	root.Name = "NavRoot"
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundTransparency = 1
	root.Parent = surfaceGui

	local btn = Instance.new("ImageButton")
	btn.Name = if isPrev then "PrevBtn" else "NextBtn"
	btn.AutoButtonColor = false
	btn.Active = true
	btn.Selectable = true
	btn.AnchorPoint = Vector2.new(0.5, 0.5)
	btn.Position = UDim2.fromScale(0.5, 0.5)
	btn.Size = UDim2.fromScale(1, 1)
	btn.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	btn.BackgroundTransparency = 0.25
	btn.BorderSizePixel = 0
	btn.ScaleType = Enum.ScaleType.Fit
	btn.ZIndex = 2
	btn.Parent = root

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = btn

	UiAssets.ApplyButtonImage(
		btn,
		if isPrev then nav.ImagePrev else nav.ImageNext,
		if isPrev then nav.FallbackPrevText else nav.FallbackNextText
	)
	local fallback = btn:FindFirstChild("FallbackLabel")
	if fallback and fallback:IsA("TextLabel") then
		fallback.TextSize = 28
	end
	BuildUI.AttachNavKeyLabel(btn, side, uiCfg)

	return btn
end

--[[
	确保 VideoContainer 上有点击层与暂停图标（预制体缺失时补齐）
	@param root Frame - Content
	@param uiCfg any? - UI 配置
	@return TextButton? - VideoTapLayer
	@return ImageLabel? - PauseIcon
]]
function BuildUI.EnsurePauseControls(root: Frame, uiCfg: any?): (TextButton?, ImageLabel?)
	local container = root:FindFirstChild("VideoContainer")
	if not container or not container:IsA("GuiObject") then
		return nil, nil
	end
	local UI = uiCfg or Constants.UI
	local pauseCfg = UI.Pause or {}
	local pauseSize = pauseCfg.Size or Vector2.new(130, 130)

	local tap = container:FindFirstChild("VideoTapLayer")
	if not (tap and tap:IsA("TextButton")) then
		if tap then
			tap:Destroy()
		end
		local btn = Instance.new("TextButton")
		btn.Name = "VideoTapLayer"
		btn.Size = UDim2.fromScale(1, 1)
		btn.BackgroundTransparency = 1
		btn.BorderSizePixel = 0
		btn.Text = ""
		btn.AutoButtonColor = false
		btn.ZIndex = 2
		btn.Parent = container
		tap = btn
	end

	local icon = container:FindFirstChild("PauseIcon")
	if not (icon and icon:IsA("ImageLabel")) then
		if icon then
			icon:Destroy()
		end
		local label = Instance.new("ImageLabel")
		label.Name = "PauseIcon"
		label.AnchorPoint = Vector2.new(0.5, 0.5)
		label.Position = UDim2.fromScale(0.5, 0.5)
		label.Size = UDim2.fromOffset(pauseSize.X, pauseSize.Y)
		label.BackgroundTransparency = 1
		label.BorderSizePixel = 0
		label.Image = UiAssets.ToImage(pauseCfg.Image)
		label.ScaleType = Enum.ScaleType.Fit
		label.Visible = false
		label.ZIndex = 3
		label.Parent = container
		icon = label
	else
		-- 预制体已有 Size，勿用代码覆盖
		local uri = UiAssets.ToImage(pauseCfg.Image)
		if uri ~= "" then
			icon.Image = uri
		end
		icon.Visible = false
	end

	return tap :: TextButton, icon :: ImageLabel
end

return BuildUI