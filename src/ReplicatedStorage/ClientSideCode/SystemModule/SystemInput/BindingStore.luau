--[[
	Module: SystemInput.BindingStore
	Description: 物理 KeyCode → ActionId（按 Scheme；每 Scheme 每 Action 仅保留一键）
	Author: 林奥宇
	Created: 2026-08-27
	Last Modified: 2026-08-28
]]

local Constants = require(script.Parent.Constants)
local DefaultConfig = require(script.Parent.DefaultConfig)

export type BindingRecord = {
	actionId: string,
	keyCode: Enum.KeyCode,
	scheme: string,
}

local BindingStore = {}
BindingStore.__index = BindingStore

--[[
	创建绑定仓库
	@return BindingStore - 空仓库
]]
function BindingStore.new()
	local self = setmetatable({
		_byScheme = {} :: { [string]: { BindingRecord } },
		_indexByScheme = {} :: { [string]: { [number]: string } },
	}, BindingStore)
	return self
end

--[[
	重建索引
]]
function BindingStore:_rebuildIndex()
	table.clear(self._indexByScheme)
	for schemeName, list in pairs(self._byScheme) do
		local index: { [number]: string } = {}
		for _, rec in ipairs(list) do
			index[rec.keyCode.Value] = rec.actionId
		end
		self._indexByScheme[schemeName] = index
	end
end

--[[
	加载默认绑定
]]
function BindingStore:LoadDefaults()
	table.clear(self._byScheme)
	table.clear(self._indexByScheme)
	for _, entry in ipairs(DefaultConfig.GetDefaultBindings()) do
		self:SetBinding(entry.actionId, entry.keyCode, entry.scheme)
	end
end

--[[
	设置绑定（同 Scheme 下同 Action 只保留一键；同 key 替换）
	@param actionId string - 语义动作
	@param keyCode Enum.KeyCode - 物理键
	@param scheme string? - Scheme
	@return boolean - 成功
	@return string? - 错误码
]]
function BindingStore:SetBinding(actionId: string, keyCode: Enum.KeyCode, scheme: string?): (boolean, string?)
	if type(actionId) ~= "string" or actionId == "" then
		return false, "INVALID_ACTION"
	end
	if typeof(keyCode) ~= "EnumItem" or keyCode.EnumType ~= Enum.KeyCode then
		return false, "INVALID_KEY"
	end
	local schemeName = scheme or Constants.Scheme.KeyboardMouse
	local list = self._byScheme[schemeName]
	if not list then
		list = {}
		self._byScheme[schemeName] = list
	end

	for i = #list, 1, -1 do
		local rec = list[i]
		if rec.keyCode == keyCode or rec.actionId == actionId then
			table.remove(list, i)
		end
	end
	table.insert(list, {
		actionId = actionId,
		keyCode = keyCode,
		scheme = schemeName,
	})
	self:_rebuildIndex()
	return true, nil
end

--[[
	查冲突 Action
	@param scheme string - Scheme
	@param keyCode Enum.KeyCode - 物理键
	@param exceptActionId string? - 排除的 Action（自身重绑）
	@return string? - 占用方 ActionId
]]
function BindingStore:FindConflict(scheme: string, keyCode: Enum.KeyCode, exceptActionId: string?): string?
	local owner = self:GetActionForKey(keyCode, scheme)
	if not owner then
		return nil
	end
	if exceptActionId and owner == exceptActionId then
		return nil
	end
	return owner
end

--[[
	按 Scheme 查 KeyCode
	@param keyCode Enum.KeyCode - 物理键
	@param scheme string - Scheme
	@return string? - ActionId
]]
function BindingStore:GetActionForKey(keyCode: Enum.KeyCode, scheme: string): string?
	local index = self._indexByScheme[scheme]
	if not index then
		return nil
	end
	return index[keyCode.Value]
end

--[[
	导出绑定深拷贝
	@param scheme string? - 过滤
	@return { BindingRecord } - 绑定记录深拷贝
]]
function BindingStore:GetBindings(scheme: string?): { BindingRecord }
	local result: { BindingRecord } = {}
	if scheme then
		local list = self._byScheme[scheme]
		if list then
			for _, rec in ipairs(list) do
				table.insert(result, {
					actionId = rec.actionId,
					keyCode = rec.keyCode,
					scheme = rec.scheme,
				})
			end
		end
		return result
	end
	for _, list in pairs(self._byScheme) do
		for _, rec in ipairs(list) do
			table.insert(result, {
				actionId = rec.actionId,
				keyCode = rec.keyCode,
				scheme = rec.scheme,
			})
		end
	end
	return result
end

--[[
	序列化为存档形状
	@return { [string]: { [string]: string } } - scheme → actionId → KeyCode.Name
]]
function BindingStore:Serialize(): { [string]: { [string]: string } }
	local out: { [string]: { [string]: string } } = {}
	for schemeName, list in pairs(self._byScheme) do
		local map: { [string]: string } = {}
		for _, rec in ipairs(list) do
			map[rec.actionId] = rec.keyCode.Name
		end
		out[schemeName] = map
	end
	return out
end

--[[
	应用存档形状（覆盖对应 Action 绑定）
	@param serialized { [string]: { [string]: string } } - 存档表
]]
function BindingStore:ApplySerialized(serialized: { [string]: { [string]: string } })
	for schemeName, actions in pairs(serialized) do
		if type(schemeName) == "string" and type(actions) == "table" then
			for actionId, keyName in pairs(actions) do
				if type(actionId) == "string" and type(keyName) == "string" then
					local keyCode = (Enum.KeyCode :: any)[keyName]
					if typeof(keyCode) == "EnumItem" and keyCode.EnumType == Enum.KeyCode then
						self:SetBinding(actionId, keyCode, schemeName)
					end
				end
			end
		end
	end
end

--[[
	清空指定 Scheme 或全部
	@param scheme string? - nil 清空全部
]]
function BindingStore:ClearScheme(scheme: string?)
	if scheme then
		self._byScheme[scheme] = nil
		self._indexByScheme[scheme] = nil
		self:_rebuildIndex()
		return
	end
	table.clear(self._byScheme)
	table.clear(self._indexByScheme)
end

--[[
	清空全部
]]
function BindingStore:Clear()
	table.clear(self._byScheme)
	table.clear(self._indexByScheme)
end

return BindingStore
