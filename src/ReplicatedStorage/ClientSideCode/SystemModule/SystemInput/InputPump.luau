--[[
	Module: SystemInput.InputPump
	Description: 监听 UserInputService，按活跃 Scheme + Context 栈解析并分发 Action
	Author: 林奥宇
	Created: 2026-08-27
	Last Modified: 2026-09-01
]]

local Constants = require(script.Parent.Constants)
local ContextStack = require(script.Parent.ContextStack)

local InputPump = {}
InputPump.__index = InputPump

export type PumpDeps = {
	userInputService: UserInputService,
	-- BindingStore：GetActionForKey(keyCode, scheme)
	bindingStore: any,
	-- ContextStack：GetSortedDescending()
	contextStack: any,
	-- ActionRegistry：Dispatch(actionId, phase, meta)
	actionRegistry: any,
	isEnabled: () -> boolean,
	syncSchemeFromInput: (input: InputObject) -> string,
	-- 返回 true 表示已消费（重绑捕获）
	tryCapture: ((input: InputObject, phase: string, gameProcessed: boolean) -> boolean)?,
}

--[[
	创建输入泵
	@param deps PumpDeps - 依赖
	@return InputPump - 新泵实例
]]
function InputPump.new(deps: PumpDeps)
	local self = setmetatable({
		_uis = deps.userInputService,
		_bindings = deps.bindingStore,
		_stack = deps.contextStack,
		_registry = deps.actionRegistry,
		_isEnabled = deps.isEnabled,
		_syncSchemeFromInput = deps.syncSchemeFromInput,
		_tryCapture = deps.tryCapture,
		_connections = {} :: { RBXScriptConnection },
	}, InputPump)
	return self
end

--[[
	处理一次物理输入
	@param input InputObject - 原始输入
	@param phase string - Started / Ended
	@param gameProcessed boolean - 引擎是否已处理
]]
function InputPump:_resolve(input: InputObject, phase: string, gameProcessed: boolean)
	if self._tryCapture and self._tryCapture(input, phase, gameProcessed) then
		return
	end
	if gameProcessed then
		return
	end
	if not self._isEnabled() then
		return
	end

	local keyCode = input.KeyCode
	if keyCode == Enum.KeyCode.Unknown then
		return
	end

	local scheme = self._syncSchemeFromInput(input)
	local actionId = self._bindings:GetActionForKey(keyCode, scheme)
	if not actionId then
		return
	end

	local sorted = self._stack:GetSortedDescending()
	local meta = {
		keyCode = keyCode,
		scheme = scheme,
		userInputType = input.UserInputType,
	}

	for _, entry in ipairs(sorted) do
		if entry.suppressLower then
			if ContextStack.AllowsAction(entry, actionId) then
				self._registry:Dispatch(actionId, phase, meta)
				if entry.consume then
					return
				end
			end
			return
		end

		if ContextStack.AllowsAction(entry, actionId) then
			self._registry:Dispatch(actionId, phase, meta)
			if entry.consume then
				return
			end
		end
	end
end

--[[
	开始监听 UIS
]]
function InputPump:Start()
	self:Stop()
	local began = self._uis.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		self:_resolve(input, Constants.Phase.Started, gameProcessed)
	end)
	local ended = self._uis.InputEnded:Connect(function(input: InputObject, gameProcessed: boolean)
		self:_resolve(input, Constants.Phase.Ended, gameProcessed)
	end)
	table.insert(self._connections, began)
	table.insert(self._connections, ended)
end

--[[
	停止监听
]]
function InputPump:Stop()
	for _, conn in ipairs(self._connections) do
		conn:Disconnect()
	end
	table.clear(self._connections)
end

return InputPump
