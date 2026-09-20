--[[
	Module: SpaceSkill
	Description: 空间技能组技能（纯表现）。单段派生 SpaceSkill1；predictPresentation=false；无 Hitbox。
	Author: 中台组
	Created: 2026-08-03
	Last Modified: 2026-08-03

	对照：
	- SkillDemoCast / Meteor：独立 ModelRes 特效 + 基础段表现
	- 本模块：运镜仅施法者 + DualPath 双球 + 分资源 PartIcles Cue 时间轴

	资源（Studio）：Assets/ModelRes/Skill 下独立 Model（见 SpaceSkill1.ResNameList）
]]
local module = {}

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local EnumMgr = Utils.EnumMgr

module.InterruptionPriority = 50

module.Data = {
	skillName = "SpaceSkill",
	skillElementType = EnumMgr.ElementTp.None,
	skillCooldown = 12,
	syncRadius = 150,
	predictPresentation = false,
	suppressions = {
		SkillLiteralTrueAlways = "原因：单段纯表现样例无派生，首段 literal=true",
	},
}

module.Skill = {
	[1] = {
		baseSkillName = "SpaceSkill1",
		breakLastSkill = false,
		condition = { type = "literal", value = true },
	},
}

return module
