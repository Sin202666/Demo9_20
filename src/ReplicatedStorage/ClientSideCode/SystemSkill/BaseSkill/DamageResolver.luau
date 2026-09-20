--[[
	伤害计算器（数值层）
	职责：技能倍率、元素倍率、暴击、随机偏移、纯度倍率（与 GetSkillPurityDamageRateMul / HitResolver 一致）、最终伤害加减成；**伤害数值不额外乘魔法强度 skillPower**（skillPower 仍可由上下文传入，供体量/VFX 等）。
	唯一结算口：resolveDamage，所有伤害计算均经此路

	调用方：HitResolver.applyHit（damageContext+DamageProfile 或 fallback skillConf.DamageRate）
]]

local GetSkillData = require(script.Parent.GetSkillData)
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local ElementTp = Utils.EnumMgr.ElementTp
local GetData = Utils.GetData

local DamageResolver = {}

--[[
	构建确定性随机种子
	@param seed number combatSeed
	@param hitIndex number
	@param hitboxIndex number
	@return number combinedSeed
]]
function DamageResolver.buildCombinedSeed(seed, hitIndex, hitboxIndex)
	hitIndex = hitIndex or 0
	hitboxIndex = hitboxIndex or 0
	return (seed or 0) + hitIndex * 10000 + hitboxIndex * 100
end

--[[
	暴击判定
	@param attackerData table
	@param rng Random?
	@param canCritical boolean
	@return isCritical boolean, critMult number
]]
function DamageResolver.rollCritical(attackerData, rng, canCritical)
	if not canCritical then
		return false, 1
	end
	local critRate = attackerData.criticalRate or 0
	local critDamage = attackerData.criticalDamage or 0.5
	local roll = rng and rng:NextNumber() or math.random()
	local isCritical = roll < critRate
	local critMult = isCritical and (1 + critDamage) or 1
	return isCritical, critMult
end

--[[
	统一伤害结算口
	@param ctx table {
		attackerData = table,
		defenderData = table,
		damageRate = number?,
		mpTp = string?,
		powerMult = number?,
		canCritical = boolean?,
		hitIndex = number?,
		hitboxIndex = number?,
		combatSeed = number?,
		elementType = number?,
		randomOffset = number?,
	}
	@return result table { finalDamage, isCritical, elementMultiplier, powerMultiplier, reductionMultiplier, randomInfo }
]]
function DamageResolver.resolveDamage(ctx)
	local attackerData = ctx.attackerData
	local defenderData = ctx.defenderData
	if not attackerData or not defenderData then
		warn("[DamageResolver] 攻击者或被攻击者数据为空")
		return { finalDamage = 0, isCritical = false }
	end

	local damageRateCfg = ctx.damageRate or 1
	local tierDamageMul = 1
	if not ctx.summonDirectDamage then
		local tierEffects = GetData.GetSkillMpTierEffects(ctx.mpTp)
		tierDamageMul = tierEffects.damageRateMul
	end
	local powerMult = ctx.powerMult or 1
	local canCritical = ctx.canCritical ~= false
	local randomOffset = ctx.randomOffset or 0.05
	local elementType = ctx.elementType or ElementTp.None

	-- 元素克制
	local defenderElementType = defenderData.elementType or ElementTp.None
	local elementMult = GetSkillData.ElementCounterDamage[elementType] and GetSkillData.ElementCounterDamage[elementType][defenderElementType] or 1

	-- 确定性随机
	local combatSeed = ctx.combatSeed or attackerData.combatSeed
	local hitIndex = ctx.hitIndex or attackerData.hitIndex or 0
	local hitboxIndex = ctx.hitboxIndex or attackerData.hitboxIndex or 0
	local combinedSeed = DamageResolver.buildCombinedSeed(combatSeed, hitIndex, hitboxIndex)
	local rng = (type(combatSeed) == "number") and Random.new(combinedSeed) or nil

	-- 暴击
	local isCritical, criticalMult = DamageResolver.rollCritical(attackerData, rng, canCritical)

	-- 最终伤害加成/减免
	local finalDamageBonus = 1 + (attackerData.finalDamageBonus or 0)
	local reductionMult = 1 - (defenderData.finalDamageReduction or 0)

	-- 基础伤害：baseDamageOverride 优先，否则 attackPower * damageRate（挡位倍率只乘配置倍率，不乘固定 baseDamage）
	local baseRaw = ctx.baseDamageOverride
	if baseRaw == nil then
		baseRaw = (attackerData.attackPower or 1) * damageRateCfg * tierDamageMul
	end
	local raw = baseRaw
		* powerMult
		* elementMult
		* criticalMult
		* finalDamageBonus
		* reductionMult

	-- 随机偏移
	local offset = 0
	if rng then
		offset = (1 - 2 * rng:NextNumber()) * randomOffset
	else
		offset = (1 - 2 * math.random()) * randomOffset
	end
	-- 允许 0 伤害（纯击退、debuff 型 profile）
	local finalDamage = math.max(0, math.floor(raw * (1 + offset) + 0.5))

	return {
		finalDamage = finalDamage,
		isCritical = isCritical,
		elementMultiplier = elementMult,
		powerMultiplier = powerMult,
		reductionMultiplier = reductionMult,
		randomInfo = {
			combatSeed = combatSeed,
			combinedSeed = combinedSeed,
			hitIndex = hitIndex,
			hitboxIndex = hitboxIndex,
		},
	}
end

--[[
	DamageProfile 行为标签（数值 + 行为）
	- baseDamage: number? 基础伤害值，与 damageRate 二选一；有 baseDamage 时以它为底
	- damageRate: number? 伤害倍率（兼容旧配置），无 baseDamage 时用 attackPower * damageRate
	- knockback: number? 击退力度，0/nil 不击退
	- canCrit: boolean?
	- hitReactionType: string? "LightHit"|"HeavyHit"|"None" 等，供硬直/受击表现
	- damageTags: table? {"Magic","Projectile","Debuff"} 等，供 debuff/分支
	- showDamageText: boolean? 是否飘字
	- elementType, randomOffset: 兼容
]]

--[[
	统一协议：从 DamageContext + damageProfile 创建伤害结算结果
	@param damageCtx table 由 DamageContext.create 构建
	@param damageProfile table? DamageProfile 配置
	@return result table { finalDamage, isCritical, knockback, showDamageText, hitReactionType, damageTags } 或 nil
]]
function DamageResolver.createDamageResult(damageCtx, damageProfile)
	if not damageCtx or not damageProfile then return nil end

	local attackerData = damageCtx.attackerData
	local defenderData = damageCtx.defenderData
	if not attackerData or not defenderData then return nil end

	local elementType = damageProfile.elementType or damageCtx.elementType or ElementTp.None
	local canCritical = damageProfile.canCritical ~= false
	local randomOffset = damageProfile.randomOffset or 0.05

	-- 召唤物：攻击×技能倍率；纯度/挡位已体现在面板或不应重复乘
	local powerMult = if damageCtx.summonDirectDamage
		then 1
		else GetData.GetSkillPurityDamageRateMul(damageCtx.skillPurity)

	local damageRate = damageProfile.damageRate
	local baseDamage = damageProfile.baseDamage
	if baseDamage == nil and damageRate == nil then
		damageRate = 1
	end

	local resolveCtx = {
		attackerData = attackerData,
		defenderData = defenderData,
		skillPower = damageCtx.skillPower,
		skillPurity = damageCtx.skillPurity,
		summonDirectDamage = damageCtx.summonDirectDamage,
		powerMult = powerMult,
		mpTp = damageCtx.mpTp,
		canCritical = canCritical,
		hitIndex = damageCtx.hitIndex,
		hitboxIndex = damageCtx.hitboxIndex,
		combatSeed = damageCtx.combatSeed,
		elementType = elementType,
		randomOffset = randomOffset,
	}
	if baseDamage ~= nil then
		resolveCtx.damageRate = 1
		resolveCtx.baseDamageOverride = baseDamage
	else
		resolveCtx.damageRate = damageRate or 1
	end

	local result = DamageResolver.resolveDamage(resolveCtx)
	local finalDamage = result.finalDamage
	local isCritical = result.isCritical

	return {
		finalDamage = finalDamage,
		isCritical = isCritical,
		knockback = damageProfile.knockback,
		showDamageText = damageProfile.showDamageText ~= false,
		hitReactionType = damageProfile.hitReactionType or "LightHit",
		damageTags = damageProfile.damageTags or {},
	}
end

--[[
	兼容旧 API：从 attackerData + defenderData + damageContext + damageProfile 计算
]]
function DamageResolver.calculate(attackerData, defenderData, damageContext, damageProfile)
	if not damageProfile then return nil end

	local DamageContext = require(script.Parent.DamageContext)
	local damageCtx = DamageContext.create(attackerData, defenderData, damageContext, nil)
	if damageCtx and damageContext then
		damageCtx.hitIndex = damageContext.hitIndex or damageCtx.hitIndex
		damageCtx.hitboxIndex = damageContext.hitboxIndex or damageCtx.hitboxIndex
		damageCtx.combatSeed = damageContext.combatSeed or damageCtx.combatSeed
	end
	return DamageResolver.createDamageResult(damageCtx, damageProfile)
end

return DamageResolver
