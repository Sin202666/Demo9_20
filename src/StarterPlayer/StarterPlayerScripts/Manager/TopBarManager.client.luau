--[[
	Module: TopBarManager
	Description: 客户端 TopbarPlus 顶栏图标管理器，注册设置菜单、反馈、公告、好友邀请、每日签到、在线奖励、背包与金币显示等入口
	Author: 林奥宇
	Created: 2026-07-03
	Last Modified: 2026-09-04

	功能：
	- 右侧「SettingMenu」下拉：设置、反馈（大屏反馈在菜单内）、公告邮件、好友邀请（移动端）
	- 独立图标：设置、公告邮件、更新日志、每日签到、在线奖励、背包（切换 Main.Backpack 仓库层）
	- 每日签到 / 在线奖励 / 背包图标受 GameConfig「每日签到.启用」「在线奖励.启用」「背包UI.启用」门控；关闭不建入口、不绑热键
	- 左上角 TopbarPlus 金币显示（非 Small 屏）或 CoinGui Money（Small 屏）
	- ShowUI（默认禁用）：经 SETTING_CHANGE 切换 HideUI

	依赖：
	- TopbarPlus Icon：第三方包，未纳入 UtilsSystem，顶部直接 require
	- Utils.NetWork.FireBindable(NetMsg.SHOW_LOCAL_UI, ...)：经 UIManager 开关界面
	- Utils.NetWork.InvokeServer(NetMsg.SETTING_CHANGE, ...)：HideUI 设置变更
	- Utils.TranslationHelper：顶栏玩家可见标签 / 邀请 Prompt 文案

	约定：
	- 本文件为 StarterPlayerScripts LocalScript，启动即绑定图标，无 Init() / 模块表
	- ScreenGui 下须存在 Setting / Feedback / NewsMail_Full / UpdateLog / DailyReward / OnlineAward 等 Frame
	- 背包：顶栏图标与 Bag.Toggle 热键（默认 Backquote）Fire BindableEvent ToggleBackpackWarehouse（挂 LocalPlayer），由 BackpackCore 切仓库详细层；不打开独立 Bag 弹窗、不藏 Main
	- Place 须有 ScreenGui.Main.Backpack（工具栏常态 + 仓库子级）
	- updatelogConf 无有效行时不创建 UpdateLog 图标
	- CoinGui 下须存在 Money Frame（Small 屏）
	- 金币 NumberValue 连接随玩家会话释放；重绑前会 Disconnect 旧连接

	本地化（Key 须为调用处字面量）：
	- 好友邀请 Prompt：TranslateByKey("邀请好友")
	- 菜单内反馈标签：SetText(..., "标题-反馈")
	- 移动端公告标签：SetText(..., "公告标题")
	- 移动端邀请标签：SetText(..., "邀请")
	- 更新日志标签：SetText(..., "更新版本", { visionName })

	示例：
	NetWork.FireBindable(NetMsg.SHOW_LOCAL_UI, "Setting")
	InsMgr.GetIns("ToggleBackpackWarehouse", "BindableEvent", LocalPlayer):Fire()
	NetWork.InvokeServer(NetMsg.SETTING_CHANGE, "HideUI", 1)
]]

-- ========================================
-- 服务引用
-- ========================================
local GuiService = game:GetService("GuiService")
local SocialService = game:GetService("SocialService")

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

-- TopbarPlus 第三方包，未纳入 UtilsSystem
local Icon = require(game.ReplicatedStorage.ClientSideCode.Tool.TopbarPlus.Icon)

local CfgFind = Utils.CfgFind
local DeviceType = Utils.DeviceType
local EnumMgr = Utils.EnumMgr
local GetData = Utils.GetData
local InsMgr = Utils.InsMgr
local LocalPlayer = Utils.LocalPlayer
local Log = Utils.Log
local MathMgr = Utils.MathMgr
local NetMsg = Utils.NetMsg
local NetWork = Utils.NetWork
local SystemGameConfig = Utils.SystemGameConfig
local SystemInput = Utils.SystemInput
local TranslationHelper = Utils.TranslationHelper
local UIanima = Utils.UIanima

-- ========================================
-- 常量
-- ========================================
local UI_NAME_SETTING = "Setting"
local UI_NAME_FEEDBACK = "Feedback"
local UI_NAME_NEWS_MAIL = "NewsMail_Full"
local UI_NAME_UPDATE_LOG = "UpdateLog"
local UI_NAME_DAILY_REWARD = "DailyReward"
local UI_NAME_ONLINE_AWARD = "OnlineAward"
local TOGGLE_BACKPACK_WAREHOUSE = "ToggleBackpackWarehouse"

local SETTING_KEY_HIDE_UI = "HideUI"

local ICON_NAME_FRIEND = "FriendTopbar"
local ICON_NAME_SETTING = "Setting"
local ICON_NAME_FEEDBACK_MENU = "feedback"
local ICON_NAME_SETTING_MENU = "SettingMenu"
local ICON_NAME_SHOW_UI = "ShowUI"
local ICON_NAME_NEWS_MAIL = "NewsMail"
local ICON_NAME_UPDATE_LOG = "update"
local ICON_NAME_DAILY_REWARD = "dailyreward"
local ICON_NAME_ONLINE_AWARD = "OnlineAward"
local ICON_NAME_BAG = "BackpackWarehouse"
local ICON_NAME_MONEY = "Money"

local RED_POINT_ONLINE = "在线奖励红点"
local ICON_ORDER_MENU = 3
local ICON_ORDER_SECONDARY = 2
local ICON_ORDER_NEWS_MAIL = 1
local ICON_ORDER_FEEDBACK_MENU = 0
local ICON_ORDER_UPDATE_LOG = 3
local ICON_ORDER_DAILY_REWARD = 2
local ICON_ORDER_ONLINE_AWARD = 1
local ICON_ORDER_BAG = 0

local IMAGE_FRIEND = "rbxassetid://73815092203036"
local IMAGE_SETTING = "rbxassetid://121912900687510"
local IMAGE_FEEDBACK_MENU = "rbxassetid://71141863602929"
local IMAGE_SETTING_MENU = "rbxassetid://80613834867873"
local IMAGE_SHOW_UI = "rbxassetid://108026101285797"
local IMAGE_NEWS_MAIL = "rbxassetid://140443240603234"
local DAILY_REWARD_IMAGE = "rbxassetid://15282926127"
local IMAGE_ONLINE_AWARD = "rbxassetid://75856038792641"
local IMAGE_BAG = "rbxassetid://118736042007083"
local COIN_IMAGE_ID = 86980976562325

local SCALE_ICON_DEFAULT = 0.65
local SCALE_FEEDBACK_MENU = 0.7
local SCALE_SETTING_MENU = 0.85
local SCALE_NEWS_MAIL = 0.6
local SCALE_UPDATE_LOG = 3
local SCALE_DAILY_REWARD = 1
local SCALE_ONLINE_AWARD = 0.85
local SCALE_BAG = 0.65
local SCALE_MOBILE = 0.6

local CORNER_RADIUS_CIRCLE = UDim.new(1, 0)
local CORNER_RADIUS_COIN = UDim.new(0, 22)
local DROPDOWN_POSITION = UDim2.new(1, 0, 1, 10)

local NOTICE_BG_COLOR = Color3.new(1, 0, 0.0156863)
local NOTICE_LABEL_COLOR = Color3.new(1, 1, 1)

local COIN_LABEL_COLOR = Color3.fromHex("FFD865")
local COIN_STROKE_COLOR = Color3.fromHex("000000")
local COIN_ANIM_DURATION = 0.25
local COIN_TEXT_SIZE = 24
local COIN_IMAGE_SCALE = 33 / 34
local COIN_STROKE_THICKNESS = 1
local COIN_STROKE_TRANSPARENCY = 0.5

-- ========================================
-- 私有变量
-- ========================================
local _coinValueConn: RBXScriptConnection? = nil

-- ========================================
-- 私有函数
-- ========================================

--[[
	取 TopbarPlus 图标的 IconLabel，供 SetText 绑定
	@param icon any - TopbarPlus Icon 实例（链式调用返回自身）
	@return TextLabel? - 存在且为 TextLabel 时返回，否则 nil
]]
local function _getIconLabel(icon: any): TextLabel?
	local label = icon:getInstance("IconLabel")
	if label and label:IsA("TextLabel") then
		return label
	end
	return nil
end

--[[
	为 TopbarPlus 图标应用统一红点通知主题
	@param icon any - TopbarPlus Icon 实例（链式调用返回自身）
	@return any - 配置后的 Icon 实例
]]
local function _applyNoticeTheme(icon: any): any
	return icon
		:modifyTheme({ "Notice", "BackgroundColor3", NOTICE_BG_COLOR })
		:modifyTheme({ "NoticeLabel", "TextColor3", NOTICE_LABEL_COLOR })
end

--[[
	经 UIManager 打开本地 UI
	@param uiName string - ScreenGui 下 Frame 名称
	@param uiData any? - 透传给目标 UI updateUi 的数据；无则传 nil
	@param isShow boolean? - 显式显隐；nil 时切换
	@param isAnim boolean? - 是否播放动画
	@param ... any - 透传给 updateUi
	@return nil - 无返回值
]]
local function _fireShowLocalUI(uiName: string, uiData: any?, isShow: boolean?, isAnim: boolean?, ...)
	NetWork.FireBindable(NetMsg.SHOW_LOCAL_UI, uiName, uiData, isShow, isAnim, ...)
end

--[[
	子图标在 joinDropdown 后点击完成时收起父级下拉
	@param childIcon any - 已 joinDropdown 的子 TopbarPlus Icon
	@return nil - 无返回值
]]
local function _closeDropdownParentIfJoined(childIcon: any)
	local uid = childIcon.parentIconUID
	if not uid then
		return
	end
	local parentIcon = Icon.getIconByUID(uid)
	if parentIcon then
		parentIcon:deselect()
	end
end

--[[
	绑定顶栏图标点击：打开本地 UI 并清除通知/选中态
	@param icon any - TopbarPlus Icon 实例
	@param uiName string - ScreenGui 下 Frame 名称
	@param isShow boolean? - 显式显隐；nil 时切换
	@param isAnim boolean? - 是否播放动画；默认 true
	@return nil - 无返回值
]]
local function _bindOpenUiClick(icon: any, uiName: string, isShow: boolean?, isAnim: boolean?)
	icon:bindEvent("selected", function()
		_fireShowLocalUI(uiName, nil, isShow, isAnim)
		icon:clearNotices()
		icon:deselect()
	end)
end

--[[
	延迟刷新 SettingMenu 下拉位置，补偿 TopbarInset 首帧未稳定
	@param settingMenuIcon any - SettingMenu TopbarPlus Icon
	@return nil - 无返回值
]]
local function _deferRefreshSettingMenuDropdown(settingMenuIcon: any)
	task.defer(function()
		local dropdown = settingMenuIcon:getInstance("Dropdown")
		if dropdown then
			settingMenuIcon:refreshAppearance(dropdown)
		end
	end)
end

--[[
	播放金币数量滚动动效并同步 TopbarPlus theme
	@param label TextLabel - 数量文本
	@param topbarMoneyIcon any? - TopbarPlus Money 图标；nil 时仅更新 label
	@param lastValue number - 变化前数量
	@param newValue number - 变化后数量
	@return nil - 无返回值
]]
local function _animateCoinLabel(label: TextLabel, topbarMoneyIcon: any?, lastValue: number, newValue: number)
	local direction = newValue > lastValue and "up" or "down"
	local formatted = MathMgr.getNumStr(newValue)

	if topbarMoneyIcon then
		topbarMoneyIcon:setLabel(formatted, "Viewing")
		topbarMoneyIcon:setLabel(formatted, "Selected")
	end

	UIanima.AnimateNumberChange(label, direction, {
		mode = "roll",
		fromValue = lastValue,
		toValue = newValue,
		duration = COIN_ANIM_DURATION,
		formatFn = function(n: number): string
			return MathMgr.getNumStr(math.floor(n))
		end,
		onComplete = function()
			if topbarMoneyIcon then
				topbarMoneyIcon:setLabel(formatted)
				if topbarMoneyIcon.updateSize and topbarMoneyIcon.updateSize.Fire then
					topbarMoneyIcon.updateSize:Fire()
				end
			end
		end,
	})
end

--[[
	绑定背包金币 NumberValue 到顶栏或 CoinGui 文本
	@param coinValue NumberValue - 背包金币实例
	@param getLabel () -> TextLabel? - 获取当前数量 TextLabel
	@param topbarMoneyIcon any? - TopbarPlus Money 图标；CoinGui 模式传 nil
	@return nil - 无返回值
]]
local function _bindCoinValueDisplay(
	coinValue: NumberValue,
	getLabel: () -> TextLabel?,
	topbarMoneyIcon: any?
)
	local lastCoinValue: number? = nil

	local function updateMoneyLabel()
		local newVal = math.floor(coinValue.Value)
		local label = getLabel()
		local canAnimate = lastCoinValue ~= nil and lastCoinValue ~= newVal and label ~= nil

		if canAnimate then
			if topbarMoneyIcon then
				_animateCoinLabel(label :: TextLabel, topbarMoneyIcon, lastCoinValue :: number, newVal)
			else
				TranslationHelper.SetText_UnTrans(label :: TextLabel, MathMgr.getNumStr(newVal), true)
				_animateCoinLabel(label :: TextLabel, nil, lastCoinValue :: number, newVal)
			end
		elseif label then
			if topbarMoneyIcon then
				topbarMoneyIcon:setLabel(MathMgr.getNumStr(newVal))
			else
				TranslationHelper.SetText_UnTrans(label, MathMgr.getNumStr(newVal), true)
			end
		end

		lastCoinValue = newVal
	end

	if _coinValueConn then
		_coinValueConn:Disconnect()
		_coinValueConn = nil
	end

	updateMoneyLabel()
	_coinValueConn = coinValue.Changed:Connect(updateMoneyLabel)
end

--[[
	非 Small 屏：TopbarPlus 左上角金币；Small 屏：使用 CoinGui.Money
	@return nil - 无返回值
]]
local function _initCoinTopbarDisplay()
	local playerGui: PlayerGui = LocalPlayer:WaitForChild("PlayerGui", math.huge) :: PlayerGui
	local coinGui: Instance? = playerGui:FindFirstChild("CoinGui")
	if not coinGui or not coinGui:IsA("ScreenGui") then
		Log.warn("[TopBarManager] CoinGui 不存在，跳过金币顶栏绑定")
		return
	end

	local coinGuiMoneyFrame: Instance? = coinGui:FindFirstChild("Money")
	if not coinGuiMoneyFrame or not coinGuiMoneyFrame:IsA("Frame") then
		Log.warn("[TopBarManager] CoinGui.Money 不存在，跳过金币顶栏绑定")
		return
	end

	local coinValue: NumberValue = GetData.WaitBagNumberValue(LocalPlayer, EnumMgr.ItemID.Coin) :: NumberValue

	if GuiService.ViewportDisplaySize ~= Enum.DisplaySize.Small then
		coinGuiMoneyFrame.Visible = false

		-- setTextFont 在 TopbarPlus 中走 Font.fromEnum 会丢失字重，故用 modifyTheme 直接设 FontFace
		local topbarMoneyIcon = Icon.new()
			:lock()
			:setName(ICON_NAME_MONEY)
			:setLeft()
			:setOrder(ICON_ORDER_SECONDARY)
			:setImage(COIN_IMAGE_ID)
			:setLabel("0")
			:setCornerRadius(CORNER_RADIUS_COIN)
			:setTextSize(COIN_TEXT_SIZE)
			:setImageScale(COIN_IMAGE_SCALE)
			:modifyTheme({ "IconLabel", "FontFace", Font.fromName("Montserrat", Enum.FontWeight.Bold, Enum.FontStyle.Normal) })
			:modifyTheme({ "IconLabel", "TextColor3", COIN_LABEL_COLOR })

		task.defer(function()
			local label = topbarMoneyIcon:getInstance("IconLabel")
			if label and label:IsA("GuiObject") then
				local stroke = Instance.new("UIStroke")
				stroke.Thickness = COIN_STROKE_THICKNESS
				stroke.Color = COIN_STROKE_COLOR
				stroke.Transparency = COIN_STROKE_TRANSPARENCY
				stroke.Parent = label
			end
		end)

		_bindCoinValueDisplay(coinValue, function(): TextLabel?
			local label = topbarMoneyIcon:getInstance("IconLabel")
			if label and label:IsA("TextLabel") then
				return label
			end
			return nil
		end, topbarMoneyIcon)
	else
		coinGuiMoneyFrame.Visible = true
		local coinLabel: TextLabel = coinGuiMoneyFrame:WaitForChild("IconLabel", math.huge) :: TextLabel
		_bindCoinValueDisplay(coinValue, function(): TextLabel?
			return coinLabel
		end, nil)
	end
end

--[[
	创建设置菜单下拉父图标
	@return any - SettingMenu TopbarPlus Icon
]]
local function _createSettingMenuIcon(): any
	return Icon.new()
		:setName(ICON_NAME_SETTING_MENU)
		:setRight()
		:setOrder(ICON_ORDER_MENU)
		:setLabel("")
		:setImage(IMAGE_SETTING_MENU)
		:setImageScale(SCALE_SETTING_MENU)
		:setCornerRadius(CORNER_RADIUS_CIRCLE)
		:autoDeselect(false)
		:modifyTheme({
			{ "Dropdown", "AnchorPoint", Vector2.new(1, 0) },
			{ "Dropdown", "Position", DROPDOWN_POSITION },
		})
end

--[[
	创建好友邀请顶栏图标
	@return any - FriendTopbar TopbarPlus Icon
]]
local function _createFriendIcon(): any
	local friendIcon = Icon.new()
		:setName(ICON_NAME_FRIEND)
		:setRight()
		:setOrder(ICON_ORDER_SECONDARY)
		:setLabel("")
		:setImage(IMAGE_FRIEND)
		:setImageScale(SCALE_ICON_DEFAULT)
		:setCornerRadius(CORNER_RADIUS_CIRCLE)
		:autoDeselect(false)

	friendIcon:bindEvent("selected", function()
		local experienceInviteOptions = Instance.new("ExperienceInviteOptions")
		experienceInviteOptions.PromptMessage = TranslationHelper.TranslateByKey("邀请好友")
		experienceInviteOptions.LaunchData = tostring(LocalPlayer.UserId)
		local ok, err = pcall(SocialService.PromptGameInvite, SocialService, LocalPlayer, experienceInviteOptions)
		if not ok then
			Log.warn("[TopBarManager] PromptGameInvite failed:", err)
		end
		friendIcon:deselect()
	end)

	return friendIcon
end

--[[
	创建设置顶栏图标
	@return any - Setting TopbarPlus Icon
]]
local function _createSettingIcon(): any
	local settingIcon = Icon.new()
		:setName(ICON_NAME_SETTING)
		:setRight()
		:setOrder(ICON_ORDER_SECONDARY)
		:setImage(IMAGE_SETTING)
		:setImageScale(SCALE_ICON_DEFAULT)
		:setCornerRadius(CORNER_RADIUS_CIRCLE)
		:autoDeselect(false)

	settingIcon:bindEvent("selected", function()
		_fireShowLocalUI(UI_NAME_SETTING, nil, true, true)
		settingIcon:deselect()
		_closeDropdownParentIfJoined(settingIcon)
	end)

	return settingIcon
end

--[[
	创建菜单内反馈顶栏图标（挂入 SettingMenu 下拉）
	@param settingMenuIcon any - SettingMenu 父图标
	@return any - feedback TopbarPlus Icon
]]
local function _createFeedbackMenuIcon(settingMenuIcon: any): any
	local feedbackIcon = Icon.new()
		:setName(ICON_NAME_FEEDBACK_MENU)
		:setRight()
		:setImageScale(SCALE_FEEDBACK_MENU)
		:setOrder(ICON_ORDER_FEEDBACK_MENU)
		:setLabel(TranslationHelper.TranslateByKey("标题-反馈"))
		:setImage(IMAGE_FEEDBACK_MENU)
		:setCornerRadius(CORNER_RADIUS_CIRCLE)
		:autoDeselect(false)

	_applyNoticeTheme(feedbackIcon)

	local feedbackLabel = _getIconLabel(feedbackIcon)
	if feedbackLabel then
		TranslationHelper.SetText(feedbackLabel, "标题-反馈")
	end

	feedbackIcon:bindEvent("selected", function()
		_fireShowLocalUI(UI_NAME_FEEDBACK, nil, true, true)
		feedbackIcon:clearNotices()
		feedbackIcon:deselect()
		settingMenuIcon:deselect()
	end)

	feedbackIcon:joinDropdown(settingMenuIcon)
	return feedbackIcon
end

--[[
	创建 HideUI 调试顶栏图标（默认禁用）
	@return any - ShowUI TopbarPlus Icon
]]
local function _createShowUIIcon(): any
	local showUiIcon = Icon.new()
		:setEnabled(false)
		:setName(ICON_NAME_SHOW_UI)
		:setRight()
		:setImageScale(SCALE_FEEDBACK_MENU)
		:setOrder(ICON_ORDER_FEEDBACK_MENU)
		:setLabel("")
		:setImage(IMAGE_SHOW_UI)
		:setCornerRadius(CORNER_RADIUS_CIRCLE)
		:autoDeselect(false)

	_applyNoticeTheme(showUiIcon)

	showUiIcon:bindEvent("selected", function()
		NetWork.InvokeServer(NetMsg.SETTING_CHANGE, SETTING_KEY_HIDE_UI, 1)
		showUiIcon:deselect()
	end)

	return showUiIcon
end

--[[
	创建公告邮件顶栏图标
	@return any - NewsMail TopbarPlus Icon
]]
local function _createNewsMailIcon(): any
	local newsMailIcon = Icon.new()
		:setName(ICON_NAME_NEWS_MAIL)
		:setRight()
		:setOrder(ICON_ORDER_NEWS_MAIL)
		:setLabel("")
		:setImage(IMAGE_NEWS_MAIL)
		:setImageScale(SCALE_NEWS_MAIL)
		:setCornerRadius(CORNER_RADIUS_CIRCLE)
		:autoDeselect(false)

	_applyNoticeTheme(newsMailIcon)

	newsMailIcon:bindEvent("selected", function()
		_fireShowLocalUI(UI_NAME_NEWS_MAIL, nil, true, true)
		newsMailIcon:clearNotices()
		newsMailIcon:deselect()
		_closeDropdownParentIfJoined(newsMailIcon)
	end)

	return newsMailIcon
end

--[[
	创建更新日志顶栏图标
	@param visionName string - updatelogConf.VisionName，作为「更新版本」占位 {1}
	@return nil - 无返回值
]]
local function _createUpdateLogIcon(visionName: string)
	local icon = Icon.new()
		:setName(ICON_NAME_UPDATE_LOG)
		:setRight()
		:setImageScale(SCALE_UPDATE_LOG)
		:setOrder(ICON_ORDER_UPDATE_LOG)
		:setLabel(TranslationHelper.TranslateByKey("更新版本", { visionName }))
		:setTextFont(Enum.Font.Montserrat, Enum.FontWeight.Medium, Enum.FontStyle.Normal)
		:setCornerRadius(CORNER_RADIUS_CIRCLE)
		:autoDeselect(false)

	_applyNoticeTheme(icon)
	_bindOpenUiClick(icon, UI_NAME_UPDATE_LOG)

	local label = _getIconLabel(icon)
	if label then
		TranslationHelper.SetText(label, "更新版本", { visionName })
	end
end

--[[
	创建每日签到顶栏图标
	@return nil - 无返回值
]]
local function _createDailyRewardIcon()
	local icon = Icon.new()
		:setName(ICON_NAME_DAILY_REWARD)
		:setRight()
		:setImageScale(SCALE_DAILY_REWARD)
		:setOrder(ICON_ORDER_DAILY_REWARD)
		:setImage(DAILY_REWARD_IMAGE)
		:setCornerRadius(CORNER_RADIUS_CIRCLE)
		:autoDeselect(false)

	_applyNoticeTheme(icon)
	_bindOpenUiClick(icon, UI_NAME_DAILY_REWARD)
end

--[[
	按服务端红点 NumberValue 刷新 TopbarPlus Notice（有可领显示单个红点）
	@param icon any - OnlineAward TopbarPlus Icon
	@param redValue NumberValue - 「在线奖励红点」
	@return nil
]]
local function _refreshOnlineAwardNotice(icon: any, redValue: NumberValue)
	if redValue.Value > 0 then
		if (icon.totalNotices or 0) < 1 then
			icon:notify()
		end
	else
		icon:clearNotices()
	end
end

--[[
	创建在线奖励顶栏入口（右侧，再点切换开关）；可领时 Notice 红点
	@return nil
]]
local function _createOnlineAwardIcon()
	local icon = Icon.new()
		:setName(ICON_NAME_ONLINE_AWARD)
		:setRight()
		:setOrder(ICON_ORDER_ONLINE_AWARD)
		:setLabel("")
		:setImage(IMAGE_ONLINE_AWARD)
		:setImageScale(SCALE_ONLINE_AWARD)
		:setCornerRadius(CORNER_RADIUS_CIRCLE)
		:autoDeselect(false)

	_applyNoticeTheme(icon)
	icon
		:modifyTheme({ "NoticeLabel", "TextTransparency", 1 })
		:modifyTheme({ "Notice", "AutomaticSize", Enum.AutomaticSize.None })
		:modifyTheme({ "Notice", "Size", UDim2.fromOffset(12, 12) })

	local redValue = GetData.WaitRedPointValue(LocalPlayer, RED_POINT_ONLINE)

	icon:bindEvent("selected", function()
		_fireShowLocalUI(UI_NAME_ONLINE_AWARD, nil, nil, true)
		icon:deselect()
		_refreshOnlineAwardNotice(icon, redValue)
	end)

	redValue.Changed:Connect(function()
		_refreshOnlineAwardNotice(icon, redValue)
	end)
	task.defer(function()
		_refreshOnlineAwardNotice(icon, redValue)
	end)
end

--[[
	切换 Main.Backpack 仓库详细层

	@return nil
]]
local function _toggleBagWarehouse()
	local toggleEv = InsMgr.GetIns(TOGGLE_BACKPACK_WAREHOUSE, "BindableEvent", LocalPlayer) :: BindableEvent
	toggleEv:Fire()
end

--[[
	创建背包顶栏图标（右侧；图复用 RP18 IMAGE_BACKPACK；切仓库而非独立弹窗）

	@return nil
]]
local function _createBagIcon()
	local icon = Icon.new()
		:setName(ICON_NAME_BAG)
		:setRight()
		:setOrder(ICON_ORDER_BAG)
		:setLabel("")
		:setImage(IMAGE_BAG)
		:setImageScale(SCALE_BAG)
		:setCornerRadius(CORNER_RADIUS_CIRCLE)
		:autoDeselect(false)

	_applyNoticeTheme(icon)
	icon:bindEvent("selected", function()
		_toggleBagWarehouse()
		icon:deselect()
	end)
end

--[[
	绑定背包热键（默认 Backquote：Tab 上方、数字 1 左侧）

	@return nil
]]
local function _bindBagHotkey()
	SystemInput.OnAction(SystemInput.ActionIds.BagToggle, function(phase: string)
		if phase ~= SystemInput.Phase.Started then
			return
		end
		_toggleBagWarehouse()
	end)
end

--[[
	移动端将部分图标收入 SettingMenu 下拉
	@param settingMenuIcon any - SettingMenu 父图标
	@param newsMailIcon any - 公告邮件图标
	@param friendIcon any - 好友邀请图标
	@return nil - 无返回值
]]
local function _applyMobileDropdownLayout(settingMenuIcon: any, newsMailIcon: any, friendIcon: any)
	newsMailIcon:setLabel(TranslationHelper.TranslateByKey("公告标题"))
	local newsLabel = _getIconLabel(newsMailIcon)
	if newsLabel then
		TranslationHelper.SetText(newsLabel, "公告标题")
	end
	newsMailIcon:setImageScale(SCALE_MOBILE)
	newsMailIcon:joinDropdown(settingMenuIcon)

	friendIcon:setLabel(TranslationHelper.TranslateByKey("邀请"))
	local friendLabel = _getIconLabel(friendIcon)
	if friendLabel then
		TranslationHelper.SetText(friendLabel, "邀请")
	end
	friendIcon:setImageScale(SCALE_MOBILE)
	friendIcon:joinDropdown(settingMenuIcon)
end

-- ========================================
-- 初始化
-- ========================================
local settingMenuIcon = _createSettingMenuIcon()
local friendIcon = _createFriendIcon()
_createSettingIcon()
_createFeedbackMenuIcon(settingMenuIcon)
_deferRefreshSettingMenuDropdown(settingMenuIcon)
_createShowUIIcon()

local newsMailIcon = _createNewsMailIcon()
if DeviceType.IsMobile() then
	_applyMobileDropdownLayout(settingMenuIcon, newsMailIcon, friendIcon)
end

local visionCfg = CfgFind.GetNowVisionCfg()
if visionCfg and visionCfg.VisionName then
	_createUpdateLogIcon(visionCfg.VisionName)
end

if SystemGameConfig.GetValue({ "每日签到", "启用" }) ~= false then
	_createDailyRewardIcon()
end
if SystemGameConfig.GetValue({ "在线奖励", "启用" }) ~= false then
	_createOnlineAwardIcon()
end
if SystemGameConfig.GetValue({ "背包UI", "启用" }) ~= false then
	_createBagIcon()
	_bindBagHotkey()
end

task.spawn(_initCoinTopbarDisplay)
