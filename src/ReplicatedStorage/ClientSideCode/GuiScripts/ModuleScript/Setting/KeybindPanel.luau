--[[
	Module: Setting.KeybindPanel
	Description: 设置页键位重绑面板（KeyboardMouse / Gamepad；经 SystemInput 捕获与存档）
	Author: 林奥宇
	Created: 2026-08-27
	Last Modified: 2026-09-04

	功能：
	- Open / Close / IsOpen：全屏遮罩 + 动作行 + 方案页签
	- 捕获走 SystemInput.BeginRebindCapture；成功后 SaveBindings
	- Open 时 PushContext(UIModal)，Close 时 Pop 并 CancelRebindCapture

	与 Setting/init：
	- 控制分类「键位设置」入口调用 Open；设置页 closeUi 时 Close
	- 不写 player.Setting，不经 SETTING_CHANGE

	加载：
	local KeybindPanel = require(script.KeybindPanel)
	KeybindPanel.Open()
	KeybindPanel.Close()
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local SystemInput = Utils.SystemInput
local TipsModule = Utils.TipsModule
local LocalPlayer = Utils.LocalPlayer
local TranslationHelper = Utils.TranslationHelper
local AddListen = Utils.AddListen
local Log = Utils.Log

local KeybindPanel = {}

-- ========================================
-- 常量
-- ========================================
local ACTION_MOUNT_TOGGLE = "Mount.Toggle"
local ACTION_SKILL_SLOT1 = "Skill.Slot1"
local ACTION_SKILL_SLOT2 = "Skill.Slot2"
local ACTION_SKILL_DASH = "Skill.Dash"
local ACTION_BAG_TOGGLE = "Bag.Toggle"

local PANEL_WIDTH = 480
local PANEL_HEIGHT = 420
local PANEL_DISPLAY_ORDER = 60
local DIM_TRANSPARENCY = 0.45

-- ========================================
-- 私有变量
-- ========================================
local _gui: ScreenGui? = nil
local _modalToken: string? = nil
local _scheme = SystemInput.Scheme.KeyboardMouse
local _statusLabel: TextLabel? = nil
local _listFrame: Frame? = nil

-- ========================================
-- 私有函数
-- ========================================

--[[
	写动作行标题（Key 必须是调用处字面量）
	@param label TextLabel - 行标题
	@param actionId string - SystemInput ActionId
	@return nil - 未知 actionId 时不改文案
]]
local function _applyActionTitle(label: TextLabel, actionId: string)
	if actionId == ACTION_MOUNT_TOGGLE then
		TranslationHelper.SetText(label, "坐骑切换")
	elseif actionId == ACTION_SKILL_SLOT1 then
		TranslationHelper.SetText(label, "技能槽 1")
	elseif actionId == ACTION_SKILL_SLOT2 then
		TranslationHelper.SetText(label, "技能槽 2")
	elseif actionId == ACTION_SKILL_DASH then
		TranslationHelper.SetText(label, "冲刺")
	elseif actionId == ACTION_BAG_TOGGLE then
		TranslationHelper.SetText(label, "背包")
	end
end

--[[
	按当前 Scheme 与捕获态刷新状态栏
	@return nil - 无 status 时跳过
]]
local function _applySchemeStatus()
	if not _statusLabel then
		return
	end
	if SystemInput.IsRebindCapturing() then
		TranslationHelper.SetText(_statusLabel, "请按下新按键")
		return
	end
	if _scheme == SystemInput.Scheme.KeyboardMouse then
		TranslationHelper.SetText(_statusLabel, "当前设备键鼠")
		return
	end
	if _scheme == SystemInput.Scheme.Gamepad then
		TranslationHelper.SetText(_statusLabel, "当前设备手柄")
		return
	end
	TranslationHelper.SetRawText(_statusLabel, "")
end

--[[
	把某 Action 当前键名写到标签（键名不翻译；未绑定走「未绑定」）
	@param keyLbl TextLabel - 键名标签
	@param actionId string - SystemInput ActionId
	@return nil - 无返回值
]]
local function _applyKeyLabel(keyLbl: TextLabel, actionId: string)
	for _, rec in ipairs(SystemInput.GetBindings(_scheme)) do
		if rec.actionId == actionId then
			TranslationHelper.SetRawText(keyLbl, rec.keyCode.Name)
			return
		end
	end
	TranslationHelper.SetText(keyLbl, "未绑定")
end

--[[
	刷新列表行键名与状态栏
	@return nil - 列表未构建时跳过
]]
local function _refreshRows()
	local list = _listFrame
	if not list then
		return
	end
	for _, child in ipairs(list:GetChildren()) do
		if child:IsA("Frame") and child.Name:sub(1, 4) == "Row_" then
			local actionId = child.Name:sub(5)
			local keyLbl = child:FindFirstChild("Key") :: TextLabel?
			if keyLbl then
				_applyKeyLabel(keyLbl, actionId)
			end
		end
	end
	_applySchemeStatus()
end

--[[
	开始捕获某 Action；结束回调里提示并刷新
	@param actionId string - SystemInput ActionId
	@return nil - Begin 失败时打日志并 Tips，不向玩家展示内部 err
]]
local function _startCapture(actionId: string)
	local ok, err = SystemInput.BeginRebindCapture(actionId, _scheme, function(success, _keyCode, captureErr)
		if success then
			if SystemInput.SaveBindings() then
				TipsModule.NormalTips(LocalPlayer, "键位已保存", nil)
			else
				TipsModule.ErrorTips(LocalPlayer, "键位已改但存档失败", nil)
			end
		elseif captureErr == "CANCELLED" then
			-- Esc 取消：静默
		elseif type(captureErr) == "string" and string.sub(captureErr, 1, 9) == "CONFLICT:" then
			TipsModule.ErrorTips(LocalPlayer, "按键冲突", { string.sub(captureErr, 10) })
		else
			TipsModule.ErrorTips(LocalPlayer, "重绑失败", nil)
		end
		_refreshRows()
	end)
	if not ok then
		Log.warn("[Setting.KeybindPanel] BeginRebindCapture failed:", err)
		TipsModule.ErrorTips(LocalPlayer, "无法开始重绑", nil)
		return
	end
	_refreshRows()
end

--[[
	创建一条动作行
	@param list Frame - 列表容器
	@param actionId string - SystemInput ActionId（同时作 Row_ 后缀）
	@param layoutOrder number - UIListLayout 顺序
	@return nil - 无返回值
]]
local function _createActionRow(list: Frame, actionId: string, layoutOrder: number)
	local row = Instance.new("Frame")
	row.Name = "Row_" .. actionId
	row.Size = UDim2.new(1, 0, 0, 36)
	row.BackgroundColor3 = Color3.fromRGB(45, 48, 56)
	row.BorderSizePixel = 0
	row.LayoutOrder = layoutOrder
	row.Parent = list

	local nameLbl = Instance.new("TextLabel")
	nameLbl.Name = "Title"
	nameLbl.Size = UDim2.new(0.4, 0, 1, 0)
	nameLbl.Position = UDim2.fromOffset(8, 0)
	nameLbl.BackgroundTransparency = 1
	nameLbl.Font = Enum.Font.Gotham
	nameLbl.TextSize = 14
	nameLbl.TextColor3 = Color3.fromRGB(230, 230, 230)
	nameLbl.TextXAlignment = Enum.TextXAlignment.Left
	nameLbl.Text = ""
	nameLbl.Parent = row
	_applyActionTitle(nameLbl, actionId)

	local keyLbl = Instance.new("TextLabel")
	keyLbl.Name = "Key"
	keyLbl.Size = UDim2.new(0.3, 0, 1, 0)
	keyLbl.Position = UDim2.fromScale(0.4, 0)
	keyLbl.BackgroundTransparency = 1
	keyLbl.Font = Enum.Font.Code
	keyLbl.TextSize = 14
	keyLbl.TextColor3 = Color3.fromRGB(160, 220, 255)
	keyLbl.TextXAlignment = Enum.TextXAlignment.Left
	keyLbl.Text = ""
	keyLbl.Parent = row

	local changeBtn = Instance.new("TextButton")
	changeBtn.Name = "Change"
	changeBtn.Size = UDim2.fromOffset(72, 28)
	changeBtn.Position = UDim2.new(1, -80, 0.5, -14)
	changeBtn.Font = Enum.Font.Gotham
	changeBtn.TextSize = 14
	changeBtn.Text = TranslationHelper.TranslateByKey("更改")
	changeBtn.Parent = row
	AddListen.AddMouseCLick(changeBtn, function()
		_startCapture(actionId)
	end, row)
end

--[[
	创建遮罩、面板壳、标题与状态栏
	@param parent PlayerGui - 挂载点
	@return ScreenGui - 新建的面板 Gui
	@return Frame - 内容面板
	@return TextLabel - 状态栏
]]
local function _createChrome(parent: PlayerGui): (ScreenGui, Frame, TextLabel)
	local gui = Instance.new("ScreenGui")
	gui.Name = "SystemInputKeybindPanel"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = PANEL_DISPLAY_ORDER
	gui.IgnoreGuiInset = true
	gui.Parent = parent

	local dim = Instance.new("TextButton")
	dim.Name = "Dim"
	dim.Size = UDim2.fromScale(1, 1)
	dim.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	dim.BackgroundTransparency = DIM_TRANSPARENCY
	dim.Text = ""
	dim.AutoButtonColor = false
	dim.Parent = gui
	AddListen.AddMouseCLick(dim, function()
		KeybindPanel.Close()
	end, dim)

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(PANEL_WIDTH, PANEL_HEIGHT)
	panel.BackgroundColor3 = Color3.fromRGB(30, 32, 38)
	panel.BorderSizePixel = 0
	panel.Parent = gui

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(1, -20, 0, 36)
	title.Position = UDim2.fromOffset(10, 8)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 20
	title.TextColor3 = Color3.fromRGB(240, 240, 240)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Parent = panel
	TranslationHelper.SetText(title, "键位设置")

	local status = Instance.new("TextLabel")
	status.Name = "Status"
	status.Size = UDim2.new(1, -20, 0, 24)
	status.Position = UDim2.fromOffset(10, 44)
	status.BackgroundTransparency = 1
	status.Font = Enum.Font.Gotham
	status.TextSize = 14
	status.TextColor3 = Color3.fromRGB(180, 200, 180)
	status.TextXAlignment = Enum.TextXAlignment.Left
	status.Text = ""
	status.Parent = panel

	return gui, panel, status
end

--[[
	创建键鼠 / 手柄页签
	@param panel Frame - 内容面板
	@return nil - 无返回值
]]
local function _createSchemeTabs(panel: Frame)
	local tabKbm = Instance.new("TextButton")
	tabKbm.Name = "TabKbm"
	tabKbm.Size = UDim2.fromOffset(120, 28)
	tabKbm.Position = UDim2.fromOffset(10, 72)
	tabKbm.Font = Enum.Font.Gotham
	tabKbm.TextSize = 14
	tabKbm.Text = TranslationHelper.TranslateByKey("键鼠")
	tabKbm.Parent = panel

	local tabPad = Instance.new("TextButton")
	tabPad.Name = "TabPad"
	tabPad.Size = UDim2.fromOffset(120, 28)
	tabPad.Position = UDim2.fromOffset(140, 72)
	tabPad.Font = Enum.Font.Gotham
	tabPad.TextSize = 14
	tabPad.Text = TranslationHelper.TranslateByKey("手柄")
	tabPad.Parent = panel

	AddListen.AddMouseCLick(tabKbm, function()
		_scheme = SystemInput.Scheme.KeyboardMouse
		_refreshRows()
	end, tabKbm)
	AddListen.AddMouseCLick(tabPad, function()
		_scheme = SystemInput.Scheme.Gamepad
		_refreshRows()
	end, tabPad)
end

--[[
	创建底栏恢复默认 / 关闭
	@param panel Frame - 内容面板
	@return nil - 无返回值
]]
local function _createFooter(panel: Frame)
	local resetBtn = Instance.new("TextButton")
	resetBtn.Name = "Reset"
	resetBtn.Size = UDim2.fromOffset(120, 32)
	resetBtn.Position = UDim2.new(0, 10, 1, -44)
	resetBtn.Font = Enum.Font.Gotham
	resetBtn.TextSize = 14
	resetBtn.Text = TranslationHelper.TranslateByKey("恢复默认")
	resetBtn.Parent = panel
	AddListen.AddMouseCLick(resetBtn, function()
		SystemInput.CancelRebindCapture()
		if SystemInput.ResetBindingsToDefault(_scheme, true) then
			TipsModule.NormalTips(LocalPlayer, "已恢复默认并保存", nil)
		else
			TipsModule.ErrorTips(LocalPlayer, "恢复默认失败", nil)
		end
		_refreshRows()
	end, resetBtn)

	local closeBtn = Instance.new("TextButton")
	closeBtn.Name = "Close"
	closeBtn.Size = UDim2.fromOffset(80, 32)
	closeBtn.Position = UDim2.new(1, -90, 1, -44)
	closeBtn.Font = Enum.Font.Gotham
	closeBtn.TextSize = 14
	closeBtn.Text = TranslationHelper.TranslateByKey("关闭面板")
	closeBtn.Parent = panel
	AddListen.AddMouseCLick(closeBtn, function()
		KeybindPanel.Close()
	end, closeBtn)
end

--[[
	构建完整面板并刷新一次
	@param parent PlayerGui - 挂载点
	@return nil - 无返回值
]]
local function _build(parent: PlayerGui)
	local gui, panel, status = _createChrome(parent)
	_statusLabel = status
	_createSchemeTabs(panel)

	local list = Instance.new("Frame")
	list.Name = "List"
	list.Position = UDim2.fromOffset(10, 110)
	list.Size = UDim2.new(1, -20, 1, -170)
	list.BackgroundTransparency = 1
	list.Parent = panel
	_listFrame = list

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list

	_createActionRow(list, ACTION_MOUNT_TOGGLE, 1)
	_createActionRow(list, ACTION_BAG_TOGGLE, 2)
	_createActionRow(list, ACTION_SKILL_SLOT1, 3)
	_createActionRow(list, ACTION_SKILL_SLOT2, 4)
	_createActionRow(list, ACTION_SKILL_DASH, 5)

	_createFooter(panel)
	_gui = gui
	_refreshRows()
end

-- ========================================
-- 公共函数
-- ========================================

--[[
	打开键位面板；已存在则仅重新启用并刷新
	@return nil - LocalPlayer 无 PlayerGui 时静默 return
]]
function KeybindPanel.Open()
	if _gui then
		_gui.Enabled = true
		_refreshRows()
		return
	end
	if not LocalPlayer then
		return
	end
	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui") or LocalPlayer:WaitForChild("PlayerGui")
	_modalToken = SystemInput.PushContext(SystemInput.ContextIds.UIModal)
	_build(playerGui :: PlayerGui)
end

--[[
	关闭键位面板：取消捕获、弹出 UIModal、销毁 Gui
	@return nil - 无返回值；可重复调用
]]
function KeybindPanel.Close()
	SystemInput.CancelRebindCapture()
	if _modalToken then
		SystemInput.PopContext(_modalToken)
		_modalToken = nil
	end
	if _gui then
		_gui:Destroy()
		_gui = nil
	end
	_statusLabel = nil
	_listFrame = nil
end

--[[
	面板是否仍挂在 PlayerGui
	@return boolean - ScreenGui 存在且有 Parent
]]
function KeybindPanel.IsOpen(): boolean
	return _gui ~= nil and _gui.Parent ~= nil
end

return KeybindPanel
