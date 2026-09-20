--[[
	Module: ActionArbiter-Type
	Description: ActionArbiter IDE 类型桩（实现以 ToolSystem/ActionArbiter 为准）
	Author: 林奥宇
	Created: 2026-07-28
	Last Modified: 2026-09-01
]]

local module = {}

--[[
	动作仲裁优先级常量（与 ActionArbiter.Priority 一致）
]]
module.Priority = {
	Loco = 0,
	Flight = 40,
	FacingBridge = 55,
	Skill = 60,
	Roll = 70,
	Knockback = 90,
	Cinematic = 100,
}

module.BlendPolicy = {
	Override = "Override",
	Overlay = "Overlay",
	FacingOnly = "FacingOnly",
	React = "React",
}

module.FacingOwner = {
	Animate = "Animate",
	External = "External",
	None = "None",
}

module.CameraOwner = {
	Default = "Default",
	External = "External",
	None = "None",
}

module.BridgeOwnerId = {
	JetPacking = "Bridge:JetPacking",
	FacingOverride = "Bridge:FacingOverride",
	SkillActionLock = "Bridge:SkillActionLock",
}

--[[
	展开 BlendPolicy 为默认闸字段
	@param policyName string? - Override/Overlay/FacingOnly/React
	@return table - { suppressLoco: boolean, pauseBaseTracks: boolean, facingOwner: string? }
]]
function module.ExpandBlendPolicy(policyName: string?): {
	suppressLoco: boolean,
	pauseBaseTracks: boolean,
	facingOwner: string?,
}
end

--[[
	为角色创建仲裁实例（仅 Animate 入口应调用）
	@param character Model - 角色模型
	@param options table? - { localPlayer: Player?, enableAttributeBridge: boolean?, enableJetPacking: boolean?, enableFacingOverride: boolean?, enableSkillActionLock: boolean? }
	@return table - ActionArbiterInstance
]]
function module.Create(character: Model, options: {
	localPlayer: Player?,
	enableAttributeBridge: boolean?,
	enableJetPacking: boolean?,
	enableFacingOverride: boolean?,
	enableSkillActionLock: boolean?,
}?): any
end

--[[
	查询已 Create 的实例；未创建返回 nil
	@param character Model - 角色
	@return any? - ActionArbiterInstance
]]
function module.GetForCharacter(character: Model): any?
end

return module
