--[[
	Module: SystemInput.DefaultConfig
	Description: 硬编码默认绑定与 Context 模板（Skill 槽仍由 Skill Manager SetBinding）
	Author: 林奥宇
	Created: 2026-08-27
	Last Modified: 2026-09-04
]]

local Constants = require(script.Parent.Constants)

local DefaultConfig = {}

export type BindingEntry = {
	actionId: string,
	keyCode: Enum.KeyCode,
	scheme: string,
}

export type ContextTemplate = {
	contextId: string,
	priority: number,
	consume: boolean,
	suppressLower: boolean,
	actions: { string }?,
}

--[[
	默认物理绑定（Mount：键鼠 M + 手柄 Y；Bag：Backquote；快捷栏数字 1~9；Skill 由业务写入）
	@return { BindingEntry } - 绑定列表
]]
function DefaultConfig.GetDefaultBindings(): { BindingEntry }
	local list: { BindingEntry } = {
		{
			actionId = Constants.ActionIds.MountToggle,
			keyCode = Enum.KeyCode.M,
			scheme = Constants.Scheme.KeyboardMouse,
		},
		{
			actionId = Constants.ActionIds.MountToggle,
			keyCode = Enum.KeyCode.ButtonY,
			scheme = Constants.Scheme.Gamepad,
		},
		{
			actionId = Constants.ActionIds.BagToggle,
			keyCode = Enum.KeyCode.Backquote,
			scheme = Constants.Scheme.KeyboardMouse,
		},
	}
	local numberKeys = {
		Enum.KeyCode.One,
		Enum.KeyCode.Two,
		Enum.KeyCode.Three,
		Enum.KeyCode.Four,
		Enum.KeyCode.Five,
		Enum.KeyCode.Six,
		Enum.KeyCode.Seven,
		Enum.KeyCode.Eight,
		Enum.KeyCode.Nine,
	}
	for index, keyCode in ipairs(numberKeys) do
		table.insert(list, {
			actionId = Constants.ToolbarSlotActionId(index),
			keyCode = keyCode,
			scheme = Constants.Scheme.KeyboardMouse,
		})
	end
	return list
end

--[[
	Context 模板表
	@return { [string]: ContextTemplate } - contextId → 模板（新建表）
]]
function DefaultConfig.GetContextTemplates(): { [string]: ContextTemplate }
	return {
		[Constants.ContextIds.Gameplay] = {
			contextId = Constants.ContextIds.Gameplay,
			priority = Constants.DefaultPriority[Constants.ContextIds.Gameplay],
			consume = false,
			suppressLower = false,
			actions = nil,
		},
		[Constants.ContextIds.UIModal] = {
			contextId = Constants.ContextIds.UIModal,
			priority = Constants.DefaultPriority[Constants.ContextIds.UIModal],
			consume = true,
			suppressLower = true,
			actions = {},
		},
	}
end

return DefaultConfig
