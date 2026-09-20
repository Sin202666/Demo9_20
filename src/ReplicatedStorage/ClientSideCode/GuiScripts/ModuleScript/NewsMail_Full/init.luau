--[[
	Module: NewsMail_Full
	Description: 公告全屏弹窗（UIManager 驱动 openUi/closeUi/updateUi）
	Author: 林奥宇
	Created: 2026-07-03
	Last Modified: 2026-09-02

	功能：
	- 公告（UpdatePanel）；邮件收件箱已停用（入服自动发奖，不再走领取 UI）
	- openUi/closeUi：显隐、SafeArea 适配、UIScale/滚动条/小屏 PhoneScale 文本监听
	- UIStroke.Thickness 由 UISetMgr 按分辨率等比适配，本模块不写 Thickness
	- updateUi({ SwitchTag = 1 })：外部指定 Tab（邮件 Tab 已隐藏，非公告值回落到公告）

	子模块：
	- AllUI：UI 节点索引
	- News：公告列表与已读（页签标题走 updatelogConf.ZhTagTitle）
	- Mail：旧收件箱逻辑保留文件，当前不挂载

	加载（UIManager 动态 require）：
	local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
	Utils.NetWork.FireBindable(Utils.NetMsg.SHOW_LOCAL_UI, "NewsMail_Full")
]]

local GuiService = game:GetService("GuiService")

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local AddListen = Utils.AddListen
local UIMgr = Utils.UIMgr
local PlayerData = Utils.PlayerData
local LocalPlayer = Utils.LocalPlayer

local AllUI = require(script.AllUI)
local NewsModule = require(script.News)

-- ========================================
-- 模块定义
-- ========================================
local NewsMail_Full = {}

-- ========================================
-- 常量定义
-- ========================================
local TAG_NEWS = 1
local PHONE_TEXT_SCALE = 0.6
-- updateUi 延迟：等待 Tab 切换动画/布局稳定后再触发子面板 OnSwitch
local SWITCH_TAG_DELAY_SEC = 1
local SAVE_KEY_UPDATE_LOG = "UpdateLog"

-- ========================================
-- 私有变量
-- ========================================
local PlayerGui: PlayerGui = LocalPlayer:WaitForChild("PlayerGui", math.huge)
local ScreenGui: ScreenGui = PlayerGui:WaitForChild("ScreenGui", math.huge)
local ScreenGui_Full: ScreenGui = PlayerGui:WaitForChild("ScreenGui_Full", math.huge)
local UIScale: UIScale = ScreenGui:WaitForChild("UIScale", math.huge)

local UI: Frame = AllUI.UIRoot
local CurTag: NumberValue = UI.CurTag

type tagData = {
	TagBtn: Frame,
	Panel: Frame,
	Title: Frame,
}

local TagList: { [number]: tagData } = {
	[TAG_NEWS] = {
		TagBtn = AllUI.UpdateTag,
		Panel = AllUI.UpdatePanel,
		Title = AllUI.UpdateTitle,
	},
}

local _openConnections: { RBXScriptConnection } = {}
local _phoneScaleLabels: { TextLabel } = {}

-- 收件箱已改为入服自动发奖，隐藏邮件 Tab / 面板与左右切换栏
AllUI.MailTag.Visible = false
AllUI.MailPanel.Visible = false
AllUI.MailTitle.Visible = false
local tagList = AllUI.MailTag.Parent
if tagList and tagList:IsA("GuiObject") then
	tagList.Visible = false
end
AllUI.UpdatePanel.Visible = true
AllUI.UpdateTitle.Visible = true
CurTag.Value = TAG_NEWS

for _, inst in ipairs(AllUI.UIRoot:GetDescendants()) do
	if inst:IsA("TextLabel") and inst:GetAttribute("PhoneScale") then
		inst:SetAttribute("OriTextSize", inst.TextSize)
		table.insert(_phoneScaleLabels, inst)
	end
end

-- ========================================
-- 私有函数
-- ========================================

--[[
	适配全屏弹窗 SafeArea（刘海/状态栏）
	@return nil - 无返回值
]]
local function _updateTopUI()
	local noneRect: Rect = GuiService:GetInsetArea(Enum.ScreenInsets.None)
	local Main: Frame = UI.Main
	Main.Position = UDim2.new(0.5, 0, 0, -noneRect.Min.Y)
	Main.Size = UDim2.new(1, noneRect.Min.X, 1, noneRect.Min.Y)
end

--[[
	同步九宫格 SliceScale 与主界面 UIScale
	@return nil - 无返回值
]]
local function _refreshAllTextScale()
	AllUI.UpdatePanelTagBG.SliceScale = UIScale.Scale
	AllUI.MailPanelTagBG.SliceScale = UIScale.Scale
end

--[[
	按 ViewportDisplaySize 缩放已缓存的 PhoneScale TextLabel
	@return nil - 无返回值
]]
local function _onViewportDisplaySizeChange()
	local isSmall = GuiService.ViewportDisplaySize == Enum.DisplaySize.Small
	for _, label in ipairs(_phoneScaleLabels) do
		local oriTextSize: number = label:GetAttribute("OriTextSize")
		if oriTextSize then
			label.TextSize = math.floor(if isSmall then oriTextSize * PHONE_TEXT_SCALE else oriTextSize)
		end
	end
end

--[[
	断开 openUi 期间注册的全部 RBXScriptConnection
	@return nil - 无返回值
]]
local function _disconnectOpenConnections()
	AddListen.DisconnectAll(_openConnections)
end

-- ========================================
-- 公共函数
-- ========================================

--[[
	UIManager 刷新入口：支持外部指定默认 Tab
	@param data { SwitchTag: number? }? - 可选 { SwitchTag = 1 }；邮件 Tab 已停用，非公告值回落到公告
	@return nil - 无返回值
]]
function NewsMail_Full:updateUi(data: { SwitchTag: number? }?)
	if data and data.SwitchTag then
		CurTag.Value = TAG_NEWS
		task.delay(SWITCH_TAG_DELAY_SEC, function()
			if not UI.Visible then
				return
			end
			if CurTag.Value == TAG_NEWS then
				NewsModule.OnSwitch()
			end
		end)
	end
end

--[[
	打开公告弹窗：隐藏主界面并绑定 SafeArea / Scale / 滚动条 / 小屏适配
	@return nil - 无返回值
]]
function NewsMail_Full:openUi()
	UIMgr.SetMainUIVisible(false)
	UI.Visible = true

	NewsModule.OpenUI()

	_disconnectOpenConnections()

	_updateTopUI()
	_openConnections[#_openConnections + 1] = ScreenGui_Full.Changed:Connect(_updateTopUI)

	_refreshAllTextScale()
	_openConnections[#_openConnections + 1] = UIScale:GetPropertyChangedSignal("Scale"):Connect(_refreshAllTextScale)

	AllUI.UpdatePanelTag.ScrollBarThickness = AllUI.UpdateScrollBar.AbsoluteSize.X - 1
	_openConnections[#_openConnections + 1] = AllUI.UpdateScrollBar:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		AllUI.UpdatePanelTag.ScrollBarThickness = AllUI.UpdateScrollBar.AbsoluteSize.X - 1
	end)

	AllUI.MailPanelTag.ScrollBarThickness = AllUI.MailScrollBar.AbsoluteSize.X - 1
	_openConnections[#_openConnections + 1] = AllUI.MailScrollBar:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		AllUI.MailPanelTag.ScrollBarThickness = AllUI.MailScrollBar.AbsoluteSize.X - 1
	end)

	_onViewportDisplaySizeChange()
	_openConnections[#_openConnections + 1] =
		GuiService:GetPropertyChangedSignal("ViewportDisplaySize"):Connect(_onViewportDisplaySizeChange)
end

--[[
	关闭公告弹窗并恢复主界面
	@return nil - 无返回值
]]
function NewsMail_Full:closeUi()
	UIMgr.SetMainUIVisible(true)
	UI.Visible = false

	_disconnectOpenConnections()
end

-- ========================================
-- 模块初始化（会话级绑定，随 UI 模块常驻）
-- ========================================

AddListen.NumValueAdd(CurTag, function()
	for k, v: tagData in pairs(TagList) do
		local isActive = k == CurTag.Value
		v.TagBtn.Frame.Close.Visible = not isActive
		v.TagBtn.Frame.Open.Visible = isActive
		v.Title.Visible = isActive
		v.Panel.Visible = isActive
	end

	if CurTag.Value == TAG_NEWS then
		NewsModule.OnSwitch()
	end
end)

for k, v in pairs(TagList) do
	AddListen.AddMouseClick(v.TagBtn.Button, function()
		CurTag.Value = k
	end, v.TagBtn.Frame)
end

PlayerData.ListenClientSync(function(key: string | { string }?, value: any)
	if key == SAVE_KEY_UPDATE_LOG then
		NewsModule.OnDataSync(value)
	end
end)

AddListen.AddMouseClick(AllUI.Exit.Button, function()
	NewsMail_Full:closeUi()
end, AllUI.Exit.Frame)

return NewsMail_Full
