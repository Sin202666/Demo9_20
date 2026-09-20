--[[
	Module: SkillHitPresentation/SkillHitPresentationConfig
	Description: 技能命中表现预设表（受击 VFX + 技能侧受击音效键名）；hitboxConfig.HitPresentationProfile 引用本表键名
	Author: 林奥宇
	Created: 2026-08-17
	Last Modified: 2026-09-01

	字段说明：
	- effectName: FXUtil.PlayEffect 特效名（本仓默认「受击效果」，与 SkillSettle 对齐）
	- soundKey: SkillHitPresentationSoundMap 映射键名
	- skipPresentation: true 时不播放任何受击表现（含怪物 InjuredSound）

	表已 freeze，禁止运行时改条目。解析走 SkillHitPresentationProfile.resolve（返回副本）。
]]

local SkillHitPresentationConfig = table.freeze({
	["无受击表现"] = table.freeze({
		skipPresentation = true,
	}),
	["通用受击"] = table.freeze({
		effectName = "受击效果",
		soundKey = "通用受击",
	}),
})

return SkillHitPresentationConfig
