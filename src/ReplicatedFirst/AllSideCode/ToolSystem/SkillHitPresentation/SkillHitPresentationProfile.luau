--[[
	Module: SkillHitPresentation/SkillHitPresentationProfile
	Description: 命中表现预设解析（特效 + 音效键名组合）
	Author: 林奥宇
	Created: 2026-08-17
	Last Modified: 2026-09-01

	能力：
	- resolve：按 Config 键名返回副本；skipPresentation 时 effectName/soundKey 为空串
	- resolveHitboxEntry：HitPresentationProfile 优先；否则把 EffectName 当预设键；再回退「通用受击」
	- 不播 FX/音效、不写位姿；只给 HitResolver / 门面提供只读预设

	加载：由 SkillHitPresentation 门面转发；也可同目录 require。
		local profile = SkillHitPresentationProfile.resolve("通用受击")
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Log = Utils.Log

local SkillHitPresentationConfig = require(script.Parent.SkillHitPresentationConfig)

local SkillHitPresentationProfile = {}

-- ============================================================================
-- 常量
-- ============================================================================

local DEFAULT_PROFILE_NAME = "通用受击"
local FALLBACK_EFFECT_NAME = "受击效果"
local FALLBACK_SOUND_KEY = "通用受击"

export type ResolvedProfile = {
	effectName: string,
	soundKey: string,
	skipPresentation: boolean?,
}

-- ============================================================================
-- 公共函数
-- ============================================================================

--[[
	读取并校验预设表条目
	@param profileName string - SkillHitPresentationConfig 键名
	@return ResolvedProfile? - 解析成功返回副本；无效返回 nil
]]
function SkillHitPresentationProfile.resolve(profileName: string): ResolvedProfile?
	if type(profileName) ~= "string" or profileName == "" then
		return nil
	end

	local raw = SkillHitPresentationConfig[profileName]
	if type(raw) ~= "table" then
		return nil
	end

	if raw.skipPresentation == true then
		return {
			effectName = "",
			soundKey = "",
			skipPresentation = true,
		}
	end

	local effectName = raw.effectName
	local soundKey = raw.soundKey
	if type(effectName) ~= "string" or effectName == "" then
		Log.warn("[SkillHitPresentationProfile] 无效预设 effectName:", profileName)
		return nil
	end
	if type(soundKey) ~= "string" or soundKey == "" then
		Log.warn("[SkillHitPresentationProfile] 无效预设 soundKey:", profileName)
		return nil
	end

	return {
		effectName = effectName,
		soundKey = soundKey,
		skipPresentation = false,
	}
end

--[[
	从 hitbox 字段解析命中表现（HitPresentationProfile 优先；否则把 EffectName 当预设键再回退）
	@param hitboxEntry table? - { HitPresentationProfile: string?, EffectName: string? }；nil 或未知键回退通用受击
	@return ResolvedProfile - 含 skipPresentation==true 时调用方不应再播表现
]]
function SkillHitPresentationProfile.resolveHitboxEntry(hitboxEntry: any): ResolvedProfile
	local profileName = hitboxEntry and hitboxEntry.HitPresentationProfile
	if type(profileName) == "string" and profileName ~= "" then
		local resolved = SkillHitPresentationProfile.resolve(profileName)
		if resolved then
			return resolved
		end
		Log.warn("[SkillHitPresentationProfile] 未知预设，回退通用受击:", profileName)
	end

	local effectOrProfile = hitboxEntry and hitboxEntry.EffectName
	if type(effectOrProfile) == "string" and effectOrProfile ~= "" then
		local asProfile = SkillHitPresentationProfile.resolve(effectOrProfile)
		if asProfile then
			return asProfile
		end
	end

	local defaultResolved = SkillHitPresentationProfile.resolve(DEFAULT_PROFILE_NAME)
	if defaultResolved then
		return defaultResolved
	end

	return {
		effectName = FALLBACK_EFFECT_NAME,
		soundKey = FALLBACK_SOUND_KEY,
		skipPresentation = false,
	}
end

return SkillHitPresentationProfile
