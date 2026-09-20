--[[
	Module: AnimationLayer.Slots
	Description: Slot 默认 Priority / BlendPolicy / fade 约定（R6 经典多轨）。
	Author: Dev-Framework
	Created: 2026-07-31
	Last Modified: 2026-07-31
]]

local Slots = {}

Slots.Name = {
	Upper = "Upper",
	FullBody = "FullBody",
	React = "React",
}

--[[
	各 Slot 默认：Priority、BlendPolicy、淡入淡出
	Upper 叠层依赖资源未键腿；非运行时 Mask。
]]
Slots.Defaults = {
	Upper = {
		priority = Enum.AnimationPriority.Action2,
		blendPolicy = "Overlay",
		fadeIn = 0.12,
		fadeOut = 0.15,
		arbiterPriority = 60, -- Skill
	},
	FullBody = {
		priority = Enum.AnimationPriority.Action,
		blendPolicy = "Override",
		fadeIn = 0.1,
		fadeOut = 0.15,
		arbiterPriority = 60,
	},
	React = {
		priority = Enum.AnimationPriority.Action4,
		blendPolicy = "React",
		fadeIn = 0.05,
		fadeOut = 0.1,
		arbiterPriority = 90, -- Knockback 档，便于压住技能 overlay
	},
}

return Slots