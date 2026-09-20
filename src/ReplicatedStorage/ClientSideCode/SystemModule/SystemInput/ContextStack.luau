--[[
	Module: SystemInput.ContextStack
	Description: 输入 Context 栈（Push/Pop token、priority 排序、suppressLower）
	Author: 林奥宇
	Created: 2026-08-27
	Last Modified: 2026-09-01
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local HttpService = Utils.HttpService

local DefaultConfig = require(script.Parent.DefaultConfig)

export type ContextEntry = {
	token: string,
	contextId: string,
	priority: number,
	consume: boolean,
	suppressLower: boolean,
	-- nil = 允许全部；空表 = 不允许任何（配合 suppressLower 吞键）
	actions: { [string]: boolean }?,
}

export type PushOpts = {
	priority: number?,
	consume: boolean?,
	suppressLower: boolean?,
	actions: { string }?,
}

local ContextStack = {}
ContextStack.__index = ContextStack

--[[
	将 actions 列表转为查找集
	@param list { string }? - ActionId 列表；nil 表示不限制
	@return { [string]: boolean }? - 查找集；nil 表示不限制
]]
local function _toActionSet(list: { string }?): { [string]: boolean }?
	if list == nil then
		return nil
	end
	local set: { [string]: boolean } = {}
	for _, actionId in ipairs(list) do
		set[actionId] = true
	end
	return set
end

--[[
	创建空栈
	@return ContextStack - 空栈实例
]]
function ContextStack.new()
	local self = setmetatable({
		_entries = {} :: { ContextEntry },
	}, ContextStack)
	return self
end

--[[
	压入 Context
	@param contextId string - 上下文标识
	@param opts PushOpts? - 覆盖模板的 priority/consume/suppressLower/actions
	@return string - 用于 Pop 的 token
]]
function ContextStack:Push(contextId: string, opts: PushOpts?): string
	local templates = DefaultConfig.GetContextTemplates()
	local template = templates[contextId]
	local priority = (opts and opts.priority)
		or (template and template.priority)
		or 0
	local consume = if opts and opts.consume ~= nil
		then opts.consume
		elseif template then template.consume
		else false
	local suppressLower = if opts and opts.suppressLower ~= nil
		then opts.suppressLower
		elseif template then template.suppressLower
		else false

	local actionsList: { string }? = if opts and opts.actions ~= nil
		then opts.actions
		elseif template then template.actions
		else nil

	local token = HttpService:GenerateGUID(false)
	local entry: ContextEntry = {
		token = token,
		contextId = contextId,
		priority = priority,
		consume = consume,
		suppressLower = suppressLower,
		actions = _toActionSet(actionsList),
	}
	table.insert(self._entries, entry)
	return token
end

--[[
	按 token 弹出
	@param token string - Push 返回的 token
	@return boolean - 找到并移除为 true
]]
function ContextStack:Pop(token: string): boolean
	for i, entry in ipairs(self._entries) do
		if entry.token == token then
			table.remove(self._entries, i)
			return true
		end
	end
	return false
end

--[[
	是否存在指定 contextId（任意一层）
	@param contextId string - 上下文标识
	@return boolean - 存在为 true
]]
function ContextStack:Has(contextId: string): boolean
	for _, entry in ipairs(self._entries) do
		if entry.contextId == contextId then
			return true
		end
	end
	return false
end

--[[
	按 priority 降序返回条目拷贝（同 priority 时后 Push 者优先）
	@return { ContextEntry } - 排序后的条目拷贝（actions 查找集亦拷贝）
]]
function ContextStack:GetSortedDescending(): { ContextEntry }
	local indexed = {}
	for i, entry in ipairs(self._entries) do
		table.insert(indexed, { index = i, entry = entry })
	end
	table.sort(indexed, function(a, b): boolean
		if a.entry.priority ~= b.entry.priority then
			return a.entry.priority > b.entry.priority
		end
		return a.index > b.index
	end)
	local result = {}
	for _, item in ipairs(indexed) do
		local e = item.entry
		table.insert(result, {
			token = e.token,
			contextId = e.contextId,
			priority = e.priority,
			consume = e.consume,
			suppressLower = e.suppressLower,
			actions = if e.actions then table.clone(e.actions) else nil,
		})
	end
	return result
end

--[[
	当前栈快照（深拷贝可序列化字段，供外部只读）
	@return { { id: string, priority: number, token: string } } - 可序列化快照（非内部活引用）
]]
function ContextStack:GetSnapshot(): { { id: string, priority: number, token: string } }
	local snapshot = {}
	for _, entry in ipairs(self:GetSortedDescending()) do
		table.insert(snapshot, {
			id = entry.contextId,
			priority = entry.priority,
			token = entry.token,
		})
	end
	return snapshot
end

--[[
	Context 是否允许某 Action
	@param entry ContextEntry - 栈条目
	@param actionId string - 语义动作
	@return boolean - 允许为 true
]]
function ContextStack.AllowsAction(entry: ContextEntry, actionId: string): boolean
	if entry.actions == nil then
		return true
	end
	return entry.actions[actionId] == true
end

--[[
	清空栈
]]
function ContextStack:Clear()
	table.clear(self._entries)
end

return ContextStack
