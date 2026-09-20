--[[
	Module: SkillHitPresentation
	Description: 玩家技能命中逻辑怪时的受击特效与音效客户端播轨（服写口在 ServerSideCode.System.SkillHitPresentation）
	Author: 林奥宇
	Created: 2026-08-17
	Last Modified: 2026-09-01

	能力：
	- resolveProfile / resolveHitboxEntry：hitbox EffectName / HitPresentationProfile → Config 预设副本
	- handleIncoming：客侧播 FX + 3D 音效（含 enemyConf.InjuredSound）
	- beginBatch / accumulateFromLogical / flushBatch：客机 no-op（防误调）
	- skipPresentation / suppressPresentation 时不播（含怪物受击音）

	与同类：
	- 只做 FX/音效，不写位姿/速度/WalkSpeed；受击轨走 NPCCosmeticHit
	- Utils.SkillHitPresentation 服务端优先加载真模块；本文件仅非服回落
	- 客侧由 EnemyManager 注册 SKILL_HIT_PRESENTATION 后转发至此
	- 无 Init、不进 CombatWorld、不写存档、不绑 Remote

	加载：
		local SkillHitPresentation = Utils.SkillHitPresentation
		SkillHitPresentation.handleIncoming(payload)
]]

local SkillHitPresentationClient = require(script.SkillHitPresentationClient)
local SkillHitPresentationProfile = require(script.SkillHitPresentationProfile)

local SkillHitPresentation = {}

-- ============================================================================
-- 公共函数
-- ============================================================================

--[[
	解析命中表现预设（只读副本）
	@param profileName string - SkillHitPresentationConfig 键名
	@return ResolvedProfile? - { effectName: string, soundKey: string, skipPresentation: boolean? }；无效为 nil
]]
function SkillHitPresentation.resolveProfile(profileName: string)
	return SkillHitPresentationProfile.resolve(profileName)
end

--[[
	从 hitbox 条目解析命中表现（HitPresentationProfile 优先，否则 EffectName 当预设键，再回退通用受击）
	@param hitboxEntry table? - { HitPresentationProfile: string?, EffectName: string? }；nil 时回退通用受击
	@return ResolvedProfile - { effectName: string, soundKey: string, skipPresentation: boolean? }
]]
function SkillHitPresentation.resolveHitboxEntry(hitboxEntry: any)
	return SkillHitPresentationProfile.resolveHitboxEntry(hitboxEntry)
end

--[[
	客机 stub：不开始服侧批
	@param _attackerUserId number? - 攻击者 UserId；客机忽略
]]
function SkillHitPresentation.beginBatch(_attackerUserId: number?)
end

--[[
	客机 stub：不下发 Nearby 包
]]
function SkillHitPresentation.flushBatch()
end

--[[
	客机 stub：不累积服侧条目
	@param _logicalId number - 运行时 id；客机忽略
	@param _cfgId number - enemyConf id；客机忽略
	@param _realDmg number - 实际伤害；客机忽略
	@param _hitData table - 含 hitPresentation；客机忽略
]]
function SkillHitPresentation.accumulateFromLogical(_logicalId: number, _cfgId: number, _realDmg: number, _hitData: any)
end

--[[
	处理 NetMsg.SKILL_HIT_PRESENTATION 下行（AOE 合并包）
	@param payload { table } - { effectName: string, soundNames: { string }, hitPos: Vector3, targetScale: number? }[]
]]
function SkillHitPresentation.handleIncoming(payload: { any })
	SkillHitPresentationClient.handleIncoming(payload)
end

return SkillHitPresentation
