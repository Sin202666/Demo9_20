--[[
	Module: HitResolver.LogicalEnemy
	Description: 逻辑怪命中结算（SystemEnemy.Hit + 受击运动）
	Author: 林奥宇
	Created: 2026-09-01
	Last Modified: 2026-09-01

	无服端 Model；击退/位移走 LogicalAirborne / LogicalDisplace，不写角色 CFrame。
	业务只经 Utils.HitResolver.applyLogicalEnemyHit，不要直接 require 本文件。
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local SystemEnemy = Utils.SystemEnemy
local GetData = Utils.GetData
local SkillHitPresentation = Utils.SkillHitPresentation
local LogicalDisplace = Utils.LogicalDisplace
local LogicalAirborne = Utils.LogicalAirborne

local BaseSkillFolder = game.ReplicatedStorage.ClientSideCode.SystemSkill.BaseSkill
local GetSkillData = require(BaseSkillFolder.GetSkillData)
local SkillDamageRateFromCfg = require(BaseSkillFolder.SkillDamageRateFromCfg)
local DamageResolver = require(BaseSkillFolder.DamageResolver)
local DamageContext = require(BaseSkillFolder.DamageContext)
local HitPolicy = require(BaseSkillFolder.HitPolicy)

local LogicalEnemy = {}

--[[
	为逻辑怪命中写入 hitData.hitPresentation。

	@param hitbox any - Hitbox
	@param hitpart any? - Part 或 Position
	@param hitData table - 待写入的 hitData
	@return nil
]]
local function _attachLogicalHitPresentation(hitbox: any, hitpart: any?, hitData: any)
	if hitbox.hitboxOwnerType ~= "Player" and hitbox.hitboxOwnerType ~= "Mirror" then
		return
	end

	local hitPos: Vector3?
	if typeof(hitpart) == "Vector3" then
		hitPos = hitpart
	elseif hitpart and typeof(hitpart) == "Instance" and hitpart:IsA("BasePart") then
		hitPos = hitpart.Position
	elseif hitbox.hitbox and hitbox.hitbox:IsA("BasePart") then
		hitPos = hitbox.hitbox.Position
	end
	if not hitPos then
		return
	end

	if hitbox.hitSuppressPresentation == true then
		hitData.hitPresentation = {
			suppressPresentation = true,
			hitPos = hitPos,
		}
		return
	end

	local resolved = nil
	if SkillHitPresentation and SkillHitPresentation.resolveHitboxEntry then
		resolved = SkillHitPresentation.resolveHitboxEntry({
			HitPresentationProfile = hitbox.HitPresentationProfile,
			EffectName = hitbox.hitEffectName,
			SoundName = hitbox.hitSoundName,
		})
	end

	if resolved and resolved.skipPresentation == true then
		hitData.hitPresentation = {
			suppressPresentation = true,
			hitPos = hitPos,
		}
		return
	end

	local effectName = resolved and resolved.effectName
	local skillSoundKey = resolved and resolved.soundKey
	if typeof(effectName) ~= "string" or effectName == "" then
		effectName = hitbox.hitEffectName
	end
	if typeof(skillSoundKey) ~= "string" or skillSoundKey == "" then
		skillSoundKey = hitbox.hitSoundName
	end
	if typeof(effectName) ~= "string" or effectName == "" then
		effectName = "受击效果"
	end
	if typeof(skillSoundKey) ~= "string" or skillSoundKey == "" then
		skillSoundKey = "通用受击"
	end

	hitData.hitPresentation = {
		effectName = effectName,
		skillSoundKey = skillSoundKey,
		hitPos = hitPos,
	}
end

--[[
	逻辑怪命中结算（无服端 Model；经 SystemEnemy.Hit + LogicalHitValidate）。

	@param baseSkill any - 技能实例
	@param hitbox any - 命中盒
	@param enemyId number - 逻辑怪运行时 id
	@param hitpart BasePart | Vector3? - 相交参考点（Position 或 Part）
	@param damageContext table? - 伤害上下文
	@return nil
]]
function LogicalEnemy.applyLogicalEnemyHit(baseSkill, hitbox, enemyId: number, hitpart: any?, damageContext: any?)
	if not baseSkill or not hitbox or typeof(enemyId) ~= "number" then
		return
	end
	if hitbox.hitboxOwnerType ~= "Player" and hitbox.hitboxOwnerType ~= "Mirror" then
		return
	end

	local policy = hitbox.hitPolicy or HitPolicy.default()
	local nowTime = baseSkill.nowTime or 0
	if policy.hitOncePerActivation and (hitbox._activationHitCount or 0) >= 1 then
		return
	end
	if policy.hitOncePerTarget then
		local lastHitTime = (hitbox.hitHistory or {})[enemyId]
		if lastHitTime then
			if (policy.repeatHitCooldown or 0) <= 0 then
				return
			end
			if nowTime - lastHitTime < policy.repeatHitCooldown then
				return
			end
		end
	end

	local attackerData = GetSkillData.getAttackerData(hitbox.hitboxOwnerId, hitbox.hitboxOwnerType)
	local defenderData = GetSkillData.getDefenderData(nil)
	if not attackerData or not defenderData then
		return
	end

	attackerData.hitboxIndex = hitbox.hitboxIndex
	attackerData.skillName = hitbox.skillName or baseSkill.skillName
	attackerData.skillID = baseSkill.skillID
	attackerData.mpTp = baseSkill.mpTp
	attackerData.combatSeed = hitbox.combatSeed or baseSkill.combatSeed
	hitbox._hitCounter = (hitbox._hitCounter or 0) + 1
	attackerData.hitIndex = hitbox._hitCounter

	local skillCtx = damageContext or {}
	skillCtx.hitIndex = skillCtx.hitIndex or hitbox._hitCounter
	skillCtx.hitboxIndex = skillCtx.hitboxIndex or hitbox.hitboxIndex
	skillCtx.combatSeed = skillCtx.combatSeed or baseSkill.combatSeed
	skillCtx.skillPower = skillCtx.skillPower or baseSkill.skillPower
	skillCtx.skillPurity = skillCtx.skillPurity or baseSkill.skillPurity
	if skillCtx.mpTp == nil or skillCtx.mpTp == "" then
		skillCtx.mpTp = baseSkill.mpTp
	end

	local damageCtx = DamageContext.create(attackerData, defenderData, skillCtx, hitbox)
	local resolveResult
	local damageProfileUsed: any? = nil
	if damageCtx and damageCtx.damageProfileId and baseSkill.skillModule and baseSkill.skillModule.DamageProfiles then
		damageProfileUsed = baseSkill.skillModule.DamageProfiles[damageCtx.damageProfileId]
		resolveResult = DamageResolver.createDamageResult(damageCtx, damageProfileUsed)
	end
	if not resolveResult then
		local skillDamage, isCrit = GetSkillData.calculateSkillDamage(attackerData, defenderData)
		resolveResult = {
			finalDamage = skillDamage or 0,
			isCritical = isCrit or false,
		}
	end

	local skillDamage = resolveResult.finalDamage or 0
	local isCrit = resolveResult.isCritical == true
	local skillModule = baseSkill.skillModule
	local rateFromCfg = SkillDamageRateFromCfg.get(baseSkill.skillID, hitbox.hitboxIndex)
	local hitDataDamageRate = rateFromCfg
	if damageProfileUsed then
		if damageProfileUsed.baseDamage ~= nil then
			hitDataDamageRate = 0
		elseif damageProfileUsed.damageRate ~= nil then
			hitDataDamageRate = damageProfileUsed.damageRate
		end
	end
	if not damageProfileUsed or damageProfileUsed.baseDamage == nil then
		local tierDamageMul = GetData.GetSkillMpTierDamageRateMul(baseSkill.mpTp)
		local purityDamageMul = GetData.GetSkillPurityDamageRateMul(baseSkill.skillPurity)
		hitDataDamageRate = hitDataDamageRate * tierDamageMul * purityDamageMul
	end

	local ownerUserId = hitbox.hitboxOwnerId
	if hitbox.hitboxOwnerType == "Mirror" then
		local mirrorModel = GetSkillData.getCharacter("Mirror", hitbox.hitboxOwnerId)
		local mirrorOwner = mirrorModel and mirrorModel:GetAttribute("OwnerUserId")
		if typeof(mirrorOwner) == "number" then
			ownerUserId = mirrorOwner
		end
		local mirrorMul = mirrorModel and tonumber(mirrorModel:GetAttribute("MirrorDamageMul"))
		if mirrorMul and mirrorMul > 0 then
			hitDataDamageRate = hitDataDamageRate * mirrorMul
			skillDamage = math.max(0, math.floor(skillDamage * mirrorMul + 0.5))
		end
	end

	local hitboxWorldPosition: Vector3? = nil
	if typeof(hitpart) == "Vector3" then
		hitboxWorldPosition = hitpart
	elseif hitpart and typeof(hitpart) == "Instance" and hitpart:IsA("BasePart") then
		hitboxWorldPosition = hitpart.Position
	elseif hitbox.hitbox and hitbox.hitbox:IsA("BasePart") then
		hitboxWorldPosition = hitbox.hitbox.Position
	end

	local hitData = {
		attackerPlayerId = ownerUserId,
		damageRate = hitDataDamageRate,
		eleTp = skillModule and skillModule.skillElementType,
		isCrit = isCrit,
		hitboxWorldPosition = hitboxWorldPosition,
		skillid = attackerData.skillID,
		finalDamage = skillDamage,
		skillPurity = baseSkill.skillPurity,
	}

	_attachLogicalHitPresentation(hitbox, hitpart, hitData)

	if SystemEnemy and SystemEnemy.Hit then
		SystemEnemy.Hit(ownerUserId, tostring(enemyId), hitData)
	end

	local handledAir = false
	if LogicalAirborne and LogicalAirborne.tryApplyFromHitbox then
		handledAir = LogicalAirborne.tryApplyFromHitbox(enemyId, hitbox) == true
	end
	if not handledAir and LogicalDisplace and LogicalDisplace.tryApplyFromHitbox then
		LogicalDisplace.tryApplyFromHitbox(enemyId, hitbox)
	end

	if hitbox.recordHit then
		hitbox:recordHit(enemyId, nowTime)
	end
end

return LogicalEnemy
