--[[
	Module: Meteor
	Description: 陨石术组技能（含 Hitbox 的主动技样板）。单段派生 Meteor1；中档打断；可选表现预测。
	Author: Dev-Framework
	Created: 2026-07-30
	Last Modified: 2026-07-30

	对照：
	- SkillDemoCast：无 Hitbox 主动样例
	- 本模块：服务端落地短窗球形 Hitbox + DamageRate 权威结算
]]
local module = {}

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local EnumMgr = Utils.EnumMgr

module.InterruptionPriority = 50

module.Data = {
	skillName = "Meteor",
	skillElementType = EnumMgr.ElementTp.Fire,
	skillCooldown = 1,
	syncRadius = 150,
	predictPresentation = true,
	-- 单段样例无派生条件，首段恒真；豁免 SkillLiteralTrueAlways
	suppressions = {
		SkillLiteralTrueAlways = "原因：单段含 Hitbox 样例无派生，首段 literal=true",
	},
}

module.Skill = {
	[1] = {
		baseSkillName = "Meteor1",
		breakLastSkill = false,
		condition = { type = "literal", value = true },
	},
}

return module