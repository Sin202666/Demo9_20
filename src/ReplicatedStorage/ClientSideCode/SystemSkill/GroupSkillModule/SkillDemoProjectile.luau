--[[
	SkillDemoProjectile 组技能（框架直线弹道样例）
	无表现预测；InterruptionPriority=50。
	配套 Base：SkillModule/SkillDemoProjectile。
]]
local module = {}

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

module.InterruptionPriority = 50

module.Data = {
	skillName = "SkillDemoProjectile",
	skillElementType = Utils.EnumMgr.ElementTp.None,
	skillCooldown = 1.2,
	syncRadius = 100,
	hitConfirmRadius = 120,
	predictPresentation = false,
	suppressions = { SkillLiteralTrueAlways = "原因：单段弹道样例无派生，首段 literal=true" },
}

module.Skill = {
	[1] = {
		baseSkillName = "SkillDemoProjectile",
		breakLastSkill = false,
		condition = { type = "literal", value = true },
	},
}

return module