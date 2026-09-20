--[[
	Module: SystemInput
	Description: 客户端统一输入路由器（Action / Binding / Context / Scheme / 重绑存档）
	Author: 林奥宇
	Created: 2026-08-27
	Last Modified: 2026-09-02

	功能：
	- Button Action + Context 栈 + 活跃 Scheme
	- 重绑捕获 BeginRebindCapture / 冲突检测 / Reset / Save
	- 存档经 LocalBindingSave → SystemInputBind（服 Init 注册 Remote）
	- Studio DebugOverlay（默认关闭；SetDebugOverlay(true) 打开）

	子模块：BindingStore / ContextStack / ActionRegistry / InputPump / SchemeUtil / LocalBindingSave / DefaultConfig / Constants
	与 CharacterControl：本模块不采样 WASD；移动 Intent 仍走 CharacterControl
	启动：PlayerInputClientManager 调 Init、Push Gameplay，再 defer LoadSavedBindings

	加载：
		local SystemInput = Utils.SystemInput

	示例：
		SystemInput.Init()
		SystemInput.PushContext(SystemInput.ContextIds.Gameplay)
		SystemInput.OnAction(SystemInput.ActionIds.MountToggle, function(phase)
			if phase == SystemInput.Phase.Started then
				-- 业务
			end
		end)

]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local UserInputService = Utils.UserInputService
local Log = Utils.Log

local Constants = require(script.Constants)
local BindingStore = require(script.BindingStore)
local ContextStackMod = require(script.ContextStack)
local ActionRegistry = require(script.ActionRegistry)
local InputPump = require(script.InputPump)
local SchemeUtil = require(script.SchemeUtil)
local LocalBindingSave = require(script.LocalBindingSave)
local DebugOverlay = require(script.DebugOverlay)
local DefaultConfig = require(script.DefaultConfig)

local SystemInput = {}

local _inited = false
local _enabled = true
local _bindings: any = nil
local _stack: any = nil
local _registry: any = nil
local _pump: any = nil
local _activeScheme: string = Constants.Scheme.KeyboardMouse
local _schemeManualLock = false
local _schemeConnections: { RBXScriptConnection } = {}
local _defaultProviders: { (scheme: string?) -> () } = {}
local _capture: {
	actionId: string,
	scheme: string,
	modalToken: string?,
	onDone: (ok: boolean, keyCode: Enum.KeyCode?, err: string?) -> (),
}? = nil

local MODIFIER_KEYS: { [number]: boolean } = {
	[Enum.KeyCode.LeftShift.Value] = true,
	[Enum.KeyCode.RightShift.Value] = true,
	[Enum.KeyCode.LeftControl.Value] = true,
	[Enum.KeyCode.RightControl.Value] = true,
	[Enum.KeyCode.LeftAlt.Value] = true,
	[Enum.KeyCode.RightAlt.Value] = true,
	[Enum.KeyCode.LeftMeta.Value] = true,
	[Enum.KeyCode.RightMeta.Value] = true,
}

-- ========================================
-- 私有函数
-- ========================================

--[[
	应用活跃 Scheme
	@param scheme string - 目标
	@param reason string? - 日志
]]
local function _applyActiveScheme(scheme: string, reason: string?)
	if not SchemeUtil.IsValid(scheme) then
		return
	end
	if _activeScheme == scheme then
		return
	end
	if _registry then
		_registry:ReleaseAllActive({ reason = "SchemeChanged", scheme = scheme })
	end
	_activeScheme = scheme
	if reason then
		Log.print("[SystemInput] ActiveScheme →", scheme, reason)
	end
end

--[[
	按 PreferredInput 同步活跃 Scheme（手动锁时跳过）
]]
local function _syncFromPreferred()
	if _schemeManualLock then
		return
	end
	_applyActiveScheme(SchemeUtil.FromPreferredInput(UserInputService.PreferredInput), "PreferredInput")
end

--[[
	按本次 InputObject 同步 Scheme，并返回当前活跃 Scheme
	@param input InputObject - 原始输入
	@return string - 当前活跃 Scheme
]]
local function _syncSchemeFromInput(input: InputObject): string
	if not _schemeManualLock then
		_applyActiveScheme(SchemeUtil.FromInputObject(input), "InputObject")
	end
	return _activeScheme
end

--[[
	懒初始化：公共 API 入口确保已 Init
]]
local function _ensureInit()
	if not _inited then
		SystemInput.Init()
	end
end

--[[
	重绑捕获消费；Started 时生效
	@param input InputObject - 原始输入
	@param phase string - Phase.Started / Ended
	@param gameProcessed boolean - UIS 是否已标记被游戏处理
	@return boolean - 已消费为 true（捕获期吞键）
]]
local function _tryCapture(input: InputObject, phase: string, gameProcessed: boolean): boolean
	local cap = _capture
	if not cap then
		return false
	end
	if phase ~= Constants.Phase.Started then
		return true
	end
	-- 捕获期吞掉全部 Began，避免漏到玩法
	if input.KeyCode == Constants.CancelRebindKeyCode then
		local onDone = cap.onDone
		SystemInput.CancelRebindCapture()
		onDone(false, nil, "CANCELLED")
		return true
	end
	if input.KeyCode == Enum.KeyCode.Unknown or MODIFIER_KEYS[input.KeyCode.Value] then
		return true
	end
	local inputScheme = SchemeUtil.FromInputObject(input)
	if inputScheme ~= cap.scheme then
		return true
	end

	local conflict = _bindings:FindConflict(cap.scheme, input.KeyCode, cap.actionId)
	if conflict then
		local onDone = cap.onDone
		SystemInput.CancelRebindCapture()
		onDone(false, input.KeyCode, "CONFLICT:" .. conflict)
		return true
	end

	_bindings:SetBinding(cap.actionId, input.KeyCode, cap.scheme)
	local onDone = cap.onDone
	SystemInput.CancelRebindCapture()
	onDone(true, input.KeyCode, nil)
	return true
end

--[[
	组装 DebugOverlay 文本
	@return string - 多行快照
]]
local function _debugSnapshot(): string
	local lines = { "[SystemInput Debug]" }
	table.insert(lines, "Scheme: " .. tostring(_activeScheme) .. (if _schemeManualLock then " (locked)" else ""))
	table.insert(lines, "Enabled: " .. tostring(_enabled))
	if _stack then
		local ctx = _stack:GetSnapshot()
		if #ctx == 0 then
			table.insert(lines, "Context: (empty)")
		else
			local parts = {}
			for _, c in ipairs(ctx) do
				table.insert(parts, string.format("%s@%d", c.id, c.priority))
			end
			table.insert(lines, "Context: " .. table.concat(parts, " > "))
		end
	end
	if _registry then
		local last = _registry:GetLastDispatch()
		if last then
			table.insert(lines, string.format("Last: %s %s", last.actionId, last.phase))
		else
			table.insert(lines, "Last: (none)")
		end
	end
	if _capture then
		table.insert(lines, "Capture: " .. _capture.actionId .. " / " .. _capture.scheme)
	end
	return table.concat(lines, "\n")
end

-- ========================================
-- 公共 API
-- ========================================

--[[
	初始化（幂等；仅 PlayerInputClientManager 调用）
]]
function SystemInput.Init()
	if _inited then
		return
	end

	_bindings = BindingStore.new()
	_bindings:LoadDefaults()
	_stack = ContextStackMod.new()
	_registry = ActionRegistry.new()
	_enabled = true
	_schemeManualLock = false
	_activeScheme = SchemeUtil.FromPreferredInput(UserInputService.PreferredInput)

	_pump = InputPump.new({
		userInputService = UserInputService,
		bindingStore = _bindings,
		contextStack = _stack,
		actionRegistry = _registry,
		isEnabled = function(): boolean
			return _enabled
		end,
		syncSchemeFromInput = _syncSchemeFromInput,
		tryCapture = _tryCapture,
	})
	_pump:Start()

	table.insert(
		_schemeConnections,
		UserInputService:GetPropertyChangedSignal("PreferredInput"):Connect(_syncFromPreferred)
	)
	table.insert(_schemeConnections, UserInputService.GamepadConnected:Connect(_syncFromPreferred))
	table.insert(_schemeConnections, UserInputService.GamepadDisconnected:Connect(_syncFromPreferred))

	_inited = true
	Log.print("[SystemInput] Init scheme=", _activeScheme)
end

--[[
	销毁连接与运行时态（测试/热重载）
]]
function SystemInput.destroy()
	if not _inited then
		return
	end
	SystemInput.CancelRebindCapture()
	DebugOverlay.Stop()
	for _, conn in ipairs(_schemeConnections) do
		conn:Disconnect()
	end
	table.clear(_schemeConnections)
	if _pump then
		_pump:Stop()
		_pump = nil
	end
	if _stack then
		_stack:Clear()
		_stack = nil
	end
	if _registry then
		_registry:Clear()
		_registry = nil
	end
	if _bindings then
		_bindings:Clear()
		_bindings = nil
	end
	table.clear(_defaultProviders)
	_inited = false
	_enabled = true
	_schemeManualLock = false
	_activeScheme = Constants.Scheme.KeyboardMouse
	Log.print("[SystemInput] destroy")
end

-- 兼容旧名
SystemInput.Destroy = SystemInput.destroy

--[[
	总开关（false 时泵不再分发玩法 Action；捕获期仍可消费）
	@param enabled boolean - 是否启用分发
]]
function SystemInput.SetEnabled(enabled: boolean)
	_ensureInit()
	_enabled = enabled == true
end

--[[
	是否启用分发
	@return boolean - 启用为 true
]]
function SystemInput.IsEnabled(): boolean
	return _enabled
end

--[[
	当前活跃 Scheme
	@return string - KeyboardMouse / Gamepad / Touch
]]
function SystemInput.GetActiveScheme(): string
	_ensureInit()
	return _activeScheme
end

--[[
	设置活跃 Scheme
	@param scheme string - 目标 Scheme
	@param lock boolean? - true 锁定（忽略 PreferredInput）；false 解锁；nil 不改锁
	@return boolean - 成功
	@return string? - 错误码 INVALID_SCHEME
]]
function SystemInput.SetActiveScheme(scheme: string, lock: boolean?): (boolean, string?)
	_ensureInit()
	if not SchemeUtil.IsValid(scheme) then
		return false, "INVALID_SCHEME"
	end
	if lock == true then
		_schemeManualLock = true
	elseif lock == false then
		_schemeManualLock = false
	end
	_applyActiveScheme(scheme, "SetActiveScheme")
	return true, nil
end

--[[
	Scheme 是否被手动锁定
	@return boolean - 已锁为 true
]]
function SystemInput.IsSchemeLocked(): boolean
	_ensureInit()
	return _schemeManualLock
end

--[[
	压入 Context
	@param contextId string - 模板 ID 或任意业务 ID
	@param opts ContextStackMod.PushOpts? - 覆盖模板：priority / consume / suppressLower / actions
	@return string - Pop 用 token
]]
function SystemInput.PushContext(contextId: string, opts: ContextStackMod.PushOpts?): string
	_ensureInit()
	return _stack:Push(contextId, opts)
end

--[[
	弹出 Context
	@param token string - Push 返回的 token
	@return boolean - 找到并弹出为 true
]]
function SystemInput.PopContext(token: string): boolean
	_ensureInit()
	return _stack:Pop(token)
end

--[[
	栈上是否存在该 ContextId
	@param contextId string - Context 模板或业务 ID
	@return boolean - 存在为 true
]]
function SystemInput.HasContext(contextId: string): boolean
	_ensureInit()
	return _stack:Has(contextId)
end

--[[
	当前 Context 快照（可序列化字段拷贝）
	@return { { id: string, priority: number, token: string } } - 高优在前
]]
function SystemInput.GetActiveContexts(): { { id: string, priority: number, token: string } }
	_ensureInit()
	return _stack:GetSnapshot()
end

--[[
	订阅 Action 相位
	@param actionId string - 语义动作
	@param callback ActionRegistry.ActionCallback - Started/Ended
	@return ActionRegistry.ActionHandle - 含 Disconnect
]]
function SystemInput.OnAction(actionId: string, callback: ActionRegistry.ActionCallback): ActionRegistry.ActionHandle
	_ensureInit()
	return _registry:OnAction(actionId, callback)
end

--[[
	Action 是否处于按下态
	@param actionId string - 语义动作
	@return boolean - 按下为 true
]]
function SystemInput.IsActionActive(actionId: string): boolean
	_ensureInit()
	return _registry:IsActionActive(actionId)
end

--[[
	Action 轴值（按钮按下=1、松开=0）
	@param actionId string - 语义动作
	@return number - [0, 1]
]]
function SystemInput.GetActionValue(actionId: string): number
	_ensureInit()
	return _registry:GetActionValue(actionId)
end

--[[
	设置绑定
	@param actionId string - 语义动作
	@param keyCode Enum.KeyCode - 物理键
	@param scheme string? - 默认当前活跃 Scheme
	@return boolean - 成功
	@return string? - 错误码
]]
function SystemInput.SetBinding(actionId: string, keyCode: Enum.KeyCode, scheme: string?): (boolean, string?)
	_ensureInit()
	return _bindings:SetBinding(actionId, keyCode, scheme)
end

--[[
	导出绑定深拷贝
	@param scheme string? - 过滤 Scheme；nil 为全部
	@return { BindingStore.BindingRecord } - 拷贝列表
]]
function SystemInput.GetBindings(scheme: string?): { BindingStore.BindingRecord }
	_ensureInit()
	return _bindings:GetBindings(scheme)
end

--[[
	查冲突
	@param scheme string - Scheme
	@param keyCode Enum.KeyCode - 物理键
	@param exceptActionId string? - 排除 Action
	@return string? - 占用方 ActionId
]]
function SystemInput.FindConflict(scheme: string, keyCode: Enum.KeyCode, exceptActionId: string?): string?
	_ensureInit()
	return _bindings:FindConflict(scheme, keyCode, exceptActionId)
end

--[[
	注册默认绑定补充器（如 Skill Manager 写入槽位默认键）
	@param provider (scheme: string?) -> () - 无参或按 Scheme 重放默认
]]
function SystemInput.RegisterDefaultProvider(provider: (scheme: string?) -> ())
	table.insert(_defaultProviders, provider)
end

--[[
	恢复默认绑定并可选写回存档
	@param scheme string? - 仅该 Scheme；nil 为全部
	@param save boolean? - 默认 true 上送存档
	@return boolean - 保存成功或未要求保存
]]
function SystemInput.ResetBindingsToDefault(scheme: string?, save: boolean?): boolean
	_ensureInit()
	if scheme then
		_bindings:ClearScheme(scheme)
		for _, entry in ipairs(DefaultConfig.GetDefaultBindings()) do
			if entry.scheme == scheme then
				_bindings:SetBinding(entry.actionId, entry.keyCode, entry.scheme)
			end
		end
	else
		_bindings:LoadDefaults()
	end
	for _, provider in ipairs(_defaultProviders) do
		provider(scheme)
	end
	if save == false then
		return true
	end
	return LocalBindingSave.SaveFromStore(_bindings)
end

--[[
	从服务端加载存档并覆盖绑定（应在各 Manager SetBinding 默认之后 defer 调用）
	@return boolean - 成功
]]
function SystemInput.LoadSavedBindings(): boolean
	_ensureInit()
	return LocalBindingSave.LoadAndApply(_bindings)
end

--[[
	将当前绑定保存到存档
	@return boolean - 成功
]]
function SystemInput.SaveBindings(): boolean
	_ensureInit()
	return LocalBindingSave.SaveFromStore(_bindings)
end

--[[
	开始重绑捕获
	@param actionId string - 目标 Action
	@param scheme string - 目标 Scheme
	@param onDone (ok: boolean, keyCode: Enum.KeyCode?, err: string?) -> () - 完成回调
	@return boolean - 已进入捕获
	@return string? - 错误码
]]
function SystemInput.BeginRebindCapture(
	actionId: string,
	scheme: string,
	onDone: (boolean, Enum.KeyCode?, string?) -> ()
): (boolean, string?)
	_ensureInit()
	if _capture then
		return false, "BUSY"
	end
	if type(actionId) ~= "string" or actionId == "" then
		return false, "INVALID_ACTION"
	end
	if not SchemeUtil.IsValid(scheme) then
		return false, "INVALID_SCHEME"
	end
	local token = _stack:Push(Constants.ContextIds.UIModal)
	_capture = {
		actionId = actionId,
		scheme = scheme,
		modalToken = token,
		onDone = onDone,
	}
	return true, nil
end

--[[
	取消重绑捕获
]]
function SystemInput.CancelRebindCapture()
	if not _capture then
		return
	end
	local token = _capture.modalToken
	_capture = nil
	if token and _stack then
		_stack:Pop(token)
	end
end

--[[
	是否正在捕获重绑
	@return boolean - 正在捕获为 true
]]
function SystemInput.IsRebindCapturing(): boolean
	return _capture ~= nil
end

--[[
	Studio Debug Overlay 开关
	@param enabled boolean - 是否显示
]]
function SystemInput.SetDebugOverlay(enabled: boolean)
	_ensureInit()
	if enabled then
		DebugOverlay.Start(_debugSnapshot)
	end
	DebugOverlay.SetEnabled(enabled)
end

-- Constants 内已 freeze；再 freeze 会报 already frozen，导致本模块 require 失败、OnAction 为 nil
SystemInput.ActionIds = Constants.ActionIds
SystemInput.Phase = Constants.Phase
SystemInput.ContextIds = Constants.ContextIds
SystemInput.Scheme = Constants.Scheme
SystemInput.SkillSlotActionId = Constants.SkillSlotActionId
SystemInput.ToolbarSlotActionId = Constants.ToolbarSlotActionId

return SystemInput
