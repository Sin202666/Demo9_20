--[[
	Module: DebugSystem
	Description: 调试 UI——物品 ID/数量输入、背包操作按钮与可扩展动态按钮区；由 DebugManager 绑定 Remote 回调
	Author: 林奥宇
	Created: 2026-01-29
	Last Modified: 2026-09-01

	功能：
	- CreateUI / Show / Hide / Toggle：调试面板生命周期（默认主面板隐藏，右下角切换按钮可见）
	- GetID / GetAmount、SetID / SetAmount：背包输入
	- OnAddClick / OnReduceClick / OnClearClick：绑定固定操作按钮
	- AddButton / RemoveButton / ClearButtons：注册带参动态按钮
	- GetButtonParam* / SetButtonParam*：读写动态按钮参数

	与相关模块：
	- DebugPanel：建 Instance；DebugI18n：已知键字面量 SetText
	- DebugManager：Dev / Studio 下 require 本模块、绑回调、发 Remote；Official 非 Studio 不加载
	- 本模块不发 Remote、不改存档、不结算奖励

	端侧约束：
	- 须由 DebugManager 在绑回调与 AddButton 之后调用 CreateUI（模块加载不再自行 spawn）
	- 动态按钮 Name / Param1Name / Param2Name 必须是 LocalizationTable 已有键；DebugI18n 用分支字面量查表
	- TextButton 文案写在子 TextLabel Caption 上（SetText 不支持 TextButton），以便切语言刷新

	加载（Manager 侧）：
	local guiScripts = game.ReplicatedStorage.ClientSideCode.GuiScripts.ModuleScript
	local DebugSystem = require(guiScripts.DebugSystem)
	DebugSystem.OnAddClick(function() end)
	DebugSystem.AddButton({ Name = "初始化角色数据" }, function() end)
	DebugSystem.CreateUI()
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Players = Utils.Players
local Log = Utils.Log

local DebugPanel = require(script.DebugPanel)

local PLAYER_GUI_WAIT_SEC = 10

local localPlayer = Players.LocalPlayer

local DebugSystem = {}

-- ========================================
-- 私有状态
-- ========================================

local _uiRefs: DebugPanel.UiRefs = {
	ScreenGui = nil,
	MainFrame = nil,
	ToggleButton = nil,
	IDInput = nil,
	AmountInput = nil,
	AddButton = nil,
	ReduceButton = nil,
	ClearButton = nil,
	ButtonWindowScrollFrame = nil,
}

local _inputValues = { ID = "", Amount = "" }
local _buttonParams: { [string]: { Param1: string?, Param2: string? } } = {}
local _eventCallbacks = {
	OnAddClick = nil :: (() -> ())?,
	OnReduceClick = nil :: (() -> ())?,
	OnClearClick = nil :: (() -> ())?,
}
local _dynamicButtons: { DebugPanel.ButtonConfig } = {}
local _buttonCache: { [string]: Instance } = {}
local _isUICreated = false

local _host: DebugPanel.Host = {
	uiRefs = _uiRefs,
	inputValues = _inputValues,
	buttonParams = _buttonParams,
	eventCallbacks = _eventCallbacks,
	dynamicButtons = _dynamicButtons,
	buttonCache = _buttonCache,
}

-- ========================================
-- 私有
-- ========================================

--[[
	清空 UI 引用表字段（不替换表，保持 Host 指向）
	@return nil
]]
local function _clearUiRefs()
	_uiRefs.ScreenGui = nil
	_uiRefs.MainFrame = nil
	_uiRefs.ToggleButton = nil
	_uiRefs.IDInput = nil
	_uiRefs.AmountInput = nil
	_uiRefs.AddButton = nil
	_uiRefs.ReduceButton = nil
	_uiRefs.ClearButton = nil
	_uiRefs.ButtonWindowScrollFrame = nil
end

--[[
	同步 Host 中可能被 table.clear 后仍共用的表引用
	@return nil
]]
local function _refreshHost()
	_host.uiRefs = _uiRefs
	_host.inputValues = _inputValues
	_host.buttonParams = _buttonParams
	_host.eventCallbacks = _eventCallbacks
	_host.dynamicButtons = _dynamicButtons
	_host.buttonCache = _buttonCache
end

-- ========================================
-- 公共：生命周期
-- ========================================

--[[
	创建调试 UI（幂等；已存在且仍挂在 PlayerGui 时直接返回）
	@return ScreenGui? - 主 ScreenGui；LocalPlayer / PlayerGui 不可用时为 nil
]]
function DebugSystem.CreateUI(): ScreenGui?
	if _isUICreated and _uiRefs.ScreenGui and _uiRefs.ScreenGui.Parent then
		return _uiRefs.ScreenGui
	end

	if _uiRefs.ScreenGui and not _uiRefs.ScreenGui.Parent then
		_uiRefs.ScreenGui = nil
		_isUICreated = false
		table.clear(_buttonCache)
	end

	if not localPlayer then
		Log.warn("[DebugSystem] LocalPlayer missing")
		return nil
	end

	local playerGui = localPlayer:FindFirstChild("PlayerGui")
	if not playerGui or not playerGui:IsA("PlayerGui") then
		playerGui = localPlayer:WaitForChild("PlayerGui", PLAYER_GUI_WAIT_SEC)
	end
	if not playerGui or not playerGui:IsA("PlayerGui") then
		Log.warn("[DebugSystem] PlayerGui missing")
		return nil
	end

	_refreshHost()
	local screenGui = DebugPanel.build(playerGui :: PlayerGui, _host, function()
		DebugSystem.Hide()
	end)
	_isUICreated = true
	return screenGui
end

--[[
	显示调试主面板（切换按钮文案改为「关闭调试」）
	@return nil
]]
function DebugSystem.Show()
	if not _isUICreated or not _uiRefs.ScreenGui or not _uiRefs.ScreenGui.Parent then
		DebugSystem.CreateUI()
	end
	if _uiRefs.MainFrame then
		_uiRefs.MainFrame.Visible = true
	end
	if _uiRefs.ToggleButton then
		DebugPanel.applyButtonText(_uiRefs.ToggleButton, "关闭调试")
	end
end

--[[
	隐藏调试主面板（保留右下角切换按钮）
	@return nil
]]
function DebugSystem.Hide()
	if _uiRefs.MainFrame then
		_uiRefs.MainFrame.Visible = false
	end
	if _uiRefs.ToggleButton then
		DebugPanel.applyButtonText(_uiRefs.ToggleButton, "调试窗口")
	end
end

--[[
	切换调试主面板显示状态
	@return nil
]]
function DebugSystem.Toggle()
	if not _isUICreated or not _uiRefs.ScreenGui or not _uiRefs.ScreenGui.Parent then
		DebugSystem.CreateUI()
	end
	if not _uiRefs.MainFrame then
		return
	end
	local willBeVisible = not _uiRefs.MainFrame.Visible
	_uiRefs.MainFrame.Visible = willBeVisible
	if _uiRefs.ToggleButton then
		if willBeVisible then
			DebugPanel.applyButtonText(_uiRefs.ToggleButton, "关闭调试")
		else
			DebugPanel.applyButtonText(_uiRefs.ToggleButton, "调试窗口")
		end
	end
end

-- ========================================
-- 公共：背包输入
-- ========================================

--[[
	获取 ID 输入框当前文本
	@return string - 物品 ID 字符串，未输入时为空串
]]
function DebugSystem.GetID(): string
	return _inputValues.ID
end

--[[
	获取物品数量输入框当前文本
	@return string - 数量字符串，未输入时为空串
]]
function DebugSystem.GetAmount(): string
	return _inputValues.Amount
end

--[[
	设置 ID 输入框文本并同步内部缓存
	@param value string - 物品 ID 字符串
	@return nil
]]
function DebugSystem.SetID(value: string)
	_inputValues.ID = value
	if _uiRefs.IDInput then
		_uiRefs.IDInput.Text = value
	end
end

--[[
	设置物品数量输入框文本并同步内部缓存
	@param value string - 数量字符串
	@return nil
]]
function DebugSystem.SetAmount(value: string)
	_inputValues.Amount = value
	if _uiRefs.AmountInput then
		_uiRefs.AmountInput.Text = value
	end
end

--[[
	绑定「添加」按钮点击回调
	@param callback () -> () - 点击时执行的函数
	@return nil
]]
function DebugSystem.OnAddClick(callback: () -> ())
	_eventCallbacks.OnAddClick = callback
end

--[[
	绑定「减少」按钮点击回调
	@param callback () -> () - 点击时执行的函数
	@return nil
]]
function DebugSystem.OnReduceClick(callback: () -> ())
	_eventCallbacks.OnReduceClick = callback
end

--[[
	绑定「清空」按钮点击回调
	@param callback () -> () - 点击时执行的函数
	@return nil
]]
function DebugSystem.OnClearClick(callback: () -> ())
	_eventCallbacks.OnClearClick = callback
end

-- ========================================
-- 公共：动态按钮参数
-- ========================================

--[[
	获取按钮的参数1值
	@param buttonName string - 按钮 Name（与 AddButton 时一致）
	@return string - 参数1文本；无该按钮时为空串
]]
function DebugSystem.GetButtonParam1(buttonName: string): string
	if _buttonParams[buttonName] then
		return _buttonParams[buttonName].Param1 or ""
	end
	return ""
end

--[[
	获取按钮的参数2值
	@param buttonName string - 按钮 Name（与 AddButton 时一致）
	@return string - 参数2文本；无该按钮时为空串
]]
function DebugSystem.GetButtonParam2(buttonName: string): string
	if _buttonParams[buttonName] then
		return _buttonParams[buttonName].Param2 or ""
	end
	return ""
end

--[[
	获取按钮的两个参数值（拷贝，不是内部表）
	@param buttonName string - 按钮 Name（与 AddButton 时一致）
	@return {Param1: string, Param2: string} - 两参数文本；无该按钮时均为空串
]]
function DebugSystem.GetButtonParams(buttonName: string): { Param1: string, Param2: string }
	if _buttonParams[buttonName] then
		return {
			Param1 = _buttonParams[buttonName].Param1 or "",
			Param2 = _buttonParams[buttonName].Param2 or "",
		}
	end
	return { Param1 = "", Param2 = "" }
end

--[[
	设置按钮的参数1值
	@param buttonName string - 按钮 Name
	@param value string - 参数1文本
	@return nil
]]
function DebugSystem.SetButtonParam1(buttonName: string, value: string)
	if not _buttonParams[buttonName] then
		_buttonParams[buttonName] = { Param1 = "", Param2 = "" }
	end
	_buttonParams[buttonName].Param1 = value

	for _, buttonConfig in ipairs(_dynamicButtons) do
		if buttonConfig.Name == buttonName and buttonConfig._Param1Input then
			buttonConfig._Param1Input.Text = value
			break
		end
	end
end

--[[
	设置按钮的参数2值
	@param buttonName string - 按钮 Name
	@param value string - 参数2文本
	@return nil
]]
function DebugSystem.SetButtonParam2(buttonName: string, value: string)
	if not _buttonParams[buttonName] then
		_buttonParams[buttonName] = { Param1 = "", Param2 = "" }
	end
	_buttonParams[buttonName].Param2 = value

	for _, buttonConfig in ipairs(_dynamicButtons) do
		if buttonConfig.Name == buttonName and buttonConfig._Param2Input then
			buttonConfig._Param2Input.Text = value
			break
		end
	end
end

--[[
	注册动态调试按钮（可含最多两个参数输入框）
	@param buttonInfo {Name: string, Param1Name: string?, Param2Name: string?} - Name 为查找键兼翻译键；Param* 为输入组翻译键
	@param callback () -> () - 按钮点击回调
	@param buttonColor Color3? - 按钮背景色，默认蓝色
	@return nil
]]
function DebugSystem.AddButton(
	buttonInfo: { Name: string, Param1Name: string?, Param2Name: string? },
	callback: () -> (),
	buttonColor: Color3?
)
	local buttonName = buttonInfo.Name
	for _, btnConfig in ipairs(_dynamicButtons) do
		if btnConfig.Name == buttonName then
			return
		end
	end

	local buttonConfig: DebugPanel.ButtonConfig = {
		Name = buttonName,
		Param1Name = buttonInfo.Param1Name,
		Param2Name = buttonInfo.Param2Name,
		Callback = callback,
		Color = buttonColor,
	}
	table.insert(_dynamicButtons, buttonConfig)

	_buttonParams[buttonName] = {}
	if buttonInfo.Param1Name and buttonInfo.Param1Name ~= "" then
		_buttonParams[buttonName].Param1 = ""
	end
	if buttonInfo.Param2Name and buttonInfo.Param2Name ~= "" then
		_buttonParams[buttonName].Param2 = ""
	end

	if _uiRefs.ButtonWindowScrollFrame then
		_refreshHost()
		local newButtonContainer = DebugPanel.createDynamicButton(
			buttonConfig,
			#_dynamicButtons,
			_uiRefs.ButtonWindowScrollFrame,
			_host
		)
		_buttonCache[buttonName] = newButtonContainer
	end
end

--[[
	移除动态按钮
	@param buttonName string - 要移除的按钮 Name
	@return nil
]]
function DebugSystem.RemoveButton(buttonName: string)
	for i, buttonConfig in ipairs(_dynamicButtons) do
		if buttonConfig.Name == buttonName then
			table.remove(_dynamicButtons, i)
			break
		end
	end

	_buttonParams[buttonName] = nil

	if _buttonCache[buttonName] then
		local buttonContainer = _buttonCache[buttonName]
		if buttonContainer.Parent then
			buttonContainer:Destroy()
		end
		_buttonCache[buttonName] = nil

		local scrollFrame = _uiRefs.ButtonWindowScrollFrame
		if scrollFrame then
			for i, buttonConfig in ipairs(_dynamicButtons) do
				local btnContainer = _buttonCache[buttonConfig.Name]
				if btnContainer and btnContainer.Parent then
					btnContainer.LayoutOrder = i
				end
			end
		end
	end
end

--[[
	清空所有动态按钮（含 UI 与参数缓存）
	@return nil
]]
function DebugSystem.ClearButtons()
	for _, buttonContainer in pairs(_buttonCache) do
		if buttonContainer.Parent then
			buttonContainer:Destroy()
		end
	end
	table.clear(_buttonCache)
	table.clear(_dynamicButtons)
	table.clear(_buttonParams)
end

--[[
	销毁调试 UI 并清理内部状态
	@return nil
]]
function DebugSystem.destroy()
	if _uiRefs.ScreenGui then
		_uiRefs.ScreenGui:Destroy()
	end
	_clearUiRefs()
	_inputValues.ID = ""
	_inputValues.Amount = ""
	table.clear(_buttonParams)
	_eventCallbacks.OnAddClick = nil
	_eventCallbacks.OnReduceClick = nil
	_eventCallbacks.OnClearClick = nil
	table.clear(_dynamicButtons)
	table.clear(_buttonCache)
	_isUICreated = false
	_refreshHost()
end

return DebugSystem
