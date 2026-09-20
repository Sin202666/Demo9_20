--[[
	Module: ActionArbiter.Constants
	Description: 动作仲裁优先级、BlendPolicy 预设与默认快照常量。
	Author: 林奥宇
	Created: 2026-07-28
	Last Modified: 2026-08-28
]]

local Constants = {}

-- 占用优先级档位（数值越大越高；同档后 Acquire 覆盖）
Constants.Priority = {
	Loco = 0,
	Flight = 40,
	FacingBridge = 55,
	Skill = 60,
	Roll = 70,
	Knockback = 90,
	Cinematic = 100,
}

-- 混合策略名（Acquire.blendPolicy；展开为 suppress/pause/facing）
Constants.BlendPolicy = {
	Override = "Override",
	Overlay = "Overlay",
	FacingOnly = "FacingOnly",
	React = "React",
}

--[[
	BlendPolicy 默认字段（显式 Acquire 字段可覆盖）
	React.facingOwner = nil 表示不声明朝向（快照回落 Animate）
]]
Constants.BlendPolicyDefaults = {
	Override = {
		suppressLoco = true,
		pauseBaseTracks = true,
		facingOwner = "External",
	},
	Overlay = {
		suppressLoco = false,
		pauseBaseTracks = false,
		facingOwner = "External",
	},
	FacingOnly = {
		suppressLoco = false,
		pauseBaseTracks = false,
		facingOwner = "External",
	},
	React = {
		suppressLoco = false,
		pauseBaseTracks = false,
		facingOwner = nil,
	},
}

Constants.FacingOwner = {
	Animate = "Animate",
	External = "External",
	None = "None",
}

Constants.CameraOwner = {
	Default = "Default",
	External = "External",
	None = "None",
}

Constants.BridgeOwnerId = table.freeze({
	JetPacking = "Bridge:JetPacking",
	FacingOverride = "Bridge:FacingOverride",
	SkillActionLock = "Bridge:SkillActionLock",
})

Constants.Priority = table.freeze(Constants.Priority)
Constants.BlendPolicy = table.freeze(Constants.BlendPolicy)
Constants.FacingOwner = table.freeze(Constants.FacingOwner)
Constants.CameraOwner = table.freeze(Constants.CameraOwner)
Constants.BlendPolicyDefaults = table.freeze(Constants.BlendPolicyDefaults)

return Constants
