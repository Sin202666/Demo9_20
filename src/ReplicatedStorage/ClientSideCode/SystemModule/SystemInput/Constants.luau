--[[
	Module: SystemInput.Constants
	Description: SystemInput 动作 ID、相位与 Context 默认优先级常量
	Author: 林奥宇
	Created: 2026-08-27
	Last Modified: 2026-09-04
]]

local Constants = {}

-- 语义动作 ID（业务只认这些字符串，不认 KeyCode）
Constants.ActionIds = table.freeze({
	MountToggle = "Mount.Toggle",
	SkillDash = "Skill.Dash",
	BagToggle = "Bag.Toggle",
})

-- 相位
Constants.Phase = table.freeze({
	Started = "Started",
	Ended = "Ended",
})

-- 设备 Scheme（Phase 2a：解析只认活跃 Scheme）
Constants.Scheme = table.freeze({
	KeyboardMouse = "KeyboardMouse",
	Gamepad = "Gamepad",
	Touch = "Touch",
})

-- Context 模板 ID
Constants.ContextIds = table.freeze({
	Gameplay = "Gameplay",
	UIModal = "UI.Modal",
})

-- 默认优先级（越大越优先）
Constants.DefaultPriority = table.freeze({
	[Constants.ContextIds.UIModal] = 100,
	[Constants.ContextIds.Gameplay] = 10,
})

-- 重绑捕获取消键
Constants.CancelRebindKeyCode = Enum.KeyCode.Escape

--[[
	生成技能槽 ActionId
	@param slotIndex number - 技能槽下标（1..N）
	@return string - 如 Skill.Slot1
]]
function Constants.SkillSlotActionId(slotIndex: number): string
	return "Skill.Slot" .. tostring(slotIndex)
end

--[[
	生成快捷栏槽 ActionId
	@param slotIndex number - 快捷栏槽 1~N
	@return string - 如 Bag.Toolbar1
]]
function Constants.ToolbarSlotActionId(slotIndex: number): string
	return "Bag.Toolbar" .. tostring(slotIndex)
end

return Constants
