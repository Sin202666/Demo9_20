--[[
	SkillDemoCast 组技能（框架主动技样例）
	无表现预测；InterruptionPriority=50（中档，可被 NewRoll=70 打断）。
]]
local module = {}

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

module.InterruptionPriority = 50

module.Data = {
	skillName = "SkillDemoCast",
	skillElementType = Utils.EnumMgr.ElementTp.None,
	skillCooldown = 1,
	syncRadius = 80,
	predictPresentation = false,
	-- 单段样例无派生条件，首段恒真；豁免 SkillLiteralTrueAlways
	suppressions = { SkillLiteralTrueAlways = "原因：单段样例无派生，首段 literal=true" },
}

module.Skill = {
	[1] = {
		baseSkillName = "SkillDemoCast",
		breakLastSkill = false,
		condition = { type = "literal", value = true },
	},
}

return module