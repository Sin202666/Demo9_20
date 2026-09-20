--[[
	Module: SystemInput.ActionRegistry
	Description: Action 订阅、按下态与 Started/Ended 分发
	Author: 林奥宇
	Created: 2026-08-27
	Last Modified: 2026-08-28
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Log = Utils.Log

local Constants = require(script.Parent.Constants)

export type ActionCallback = (phase: string, value: number?, meta: { [string]: any }?) -> ()

export type ActionHandle = {
	Disconnect: (self: ActionHandle) -> (),
}

type Listener = {
	id: number,
	callback: ActionCallback,
}

local ActionRegistry = {}
ActionRegistry.__index = ActionRegistry

--[[
	创建注册表
	@return ActionRegistry - 空注册表
]]
function ActionRegistry.new()
	local self = setmetatable({
		_listeners = {} :: { [string]: { Listener } },
		_active = {} :: { [string]: boolean },
		_nextId = 1,
		_lastDispatch = nil :: { actionId: string, phase: string, at: number }?,
	}, ActionRegistry)
	return self
end

--[[
	订阅 Action
	@param actionId string - 语义动作
	@param callback ActionCallback - 相位回调
	@return ActionHandle - 可 Disconnect
]]
function ActionRegistry:OnAction(actionId: string, callback: ActionCallback): ActionHandle
	local list = self._listeners[actionId]
	if not list then
		list = {}
		self._listeners[actionId] = list
	end
	local id = self._nextId
	self._nextId += 1
	local listener: Listener = { id = id, callback = callback }
	table.insert(list, listener)

	local registry = self
	local handle: ActionHandle = {
		Disconnect = function(_self: ActionHandle)
			local cur = registry._listeners[actionId]
			if not cur then
				return
			end
			for i, item in ipairs(cur) do
				if item.id == id then
					table.remove(cur, i)
					break
				end
			end
		end,
	}
	return handle
end

--[[
	分发相位（更新 active 并通知订户）
	@param actionId string - 语义动作
	@param phase string - Started / Ended
	@param meta { [string]: any }? - 附加信息（如 keyCode）
]]
function ActionRegistry:Dispatch(actionId: string, phase: string, meta: { [string]: any }?)
	if phase == Constants.Phase.Started then
		self._active[actionId] = true
	elseif phase == Constants.Phase.Ended then
		self._active[actionId] = false
	end

	self._lastDispatch = {
		actionId = actionId,
		phase = phase,
		at = os.clock(),
	}

	local value = if self._active[actionId] then 1 else 0
	local list = self._listeners[actionId]
	if not list then
		return
	end
	local snapshot = table.clone(list)
	for _, listener in ipairs(snapshot) do
		local ok, err = pcall(listener.callback, phase, value, meta)
		if not ok then
			Log.warn("[SystemInput.ActionRegistry] callback error:", actionId, err)
		end
	end
end

--[[
	最近一次分发快照（Debug）
	@return { actionId: string, phase: string, at: number }? - 最近一次分发；无则 nil
]]
function ActionRegistry:GetLastDispatch(): { actionId: string, phase: string, at: number }?
	local last = self._lastDispatch
	if not last then
		return nil
	end
	return {
		actionId = last.actionId,
		phase = last.phase,
		at = last.at,
	}
end

--[[
	强制结束所有处于按下态的 Action（Scheme 切换时避免粘键）
	@param meta { [string]: any }? - 附加信息
]]
function ActionRegistry:ReleaseAllActive(meta: { [string]: any }?)
	local toRelease: { string } = {}
	for actionId, isActive in pairs(self._active) do
		if isActive then
			table.insert(toRelease, actionId)
		end
	end
	for _, actionId in ipairs(toRelease) do
		self:Dispatch(actionId, Constants.Phase.Ended, meta)
	end
end

--[[
	Action 是否处于按下态
	@param actionId string - 语义动作
	@return boolean - 按下为 true
]]
function ActionRegistry:IsActionActive(actionId: string): boolean
	return self._active[actionId] == true
end

--[[
	Button 当前值
	@param actionId string - 语义动作
	@return number - 1 按下 / 0 未按下
]]
function ActionRegistry:GetActionValue(actionId: string): number
	return if self._active[actionId] then 1 else 0
end

--[[
	清空订阅与按下态
]]
function ActionRegistry:Clear()
	table.clear(self._listeners)
	table.clear(self._active)
end

return ActionRegistry
