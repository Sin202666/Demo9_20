--[[
	Module: NewRoll
	Description: 长冲翻滚组技能。predictPresentation=true；InterruptionPriority=70；单段派生 NewRoll。
	Author: 林奥宇
	Created: 2026-07-30
	Last Modified: 2026-09-01

	功能：
	- 按键即本地预测至 ControlOpenState(Recovery) hold，确认后 soft-merge
	- 位移经 CharacterMotion（DashStyleRoll Gate）；服包络 SystemCharacterMotion
	- 打断档 70：高于默认中档(50)，可跨槽打断主动技

	模块关系：
	- 基础段：SkillModule/NewRoll（状态机 / 无敌 / 包络 / Fx）
	- 对照：SkillDemoCast（无预测、中档 50）；Meteor（含 Hitbox）

	加载方式：
	-- 由技能框架按 GroupSkillModule 名「NewRoll」require，业务勿直接调用
	local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

	示例：
	module.InterruptionPriority = 70
	module.Data.predictPresentation = true
	module.Skill[1].baseSkillName = "NewRoll"

	验收清单（模拟 100–150ms 延迟）：
	1. 按键 → 首帧内进入 Rolling 并产生 CharacterMotion 位移
	2. 服务端确认后动画/速度无重置感（handoff）
	3. 拒释（CD/死亡）→ 物理与 ActionLock 清干净；可有短 rubberband
	4. 旁观者仅在 BaseSkillStarted 后可见（不预测）
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local EnumMgr = Utils.EnumMgr
local ElementTp = EnumMgr.ElementTp

local module = {}

-- 冲刺高于默认中档主动技，可打断之；同档仍须严格大于才打断
module.InterruptionPriority = 70

module.Data = {
	skillName = "NewRoll",
	skillElementType = ElementTp.None,
	skillCooldown = 0.8,
	syncRadius = 80,
	-- 单段无派生条件，首段恒真；豁免 SkillLiteralTrueAlways
	suppressions = { SkillLiteralTrueAlways = "原因：首段无条件派生，单段 literal=true" },
	predictPresentation = true,
}

module.Skill = {
	[1] = {
		baseSkillName = "NewRoll",
		breakLastSkill = false,
		condition = { type = "literal", value = true },
	},
}

return module
