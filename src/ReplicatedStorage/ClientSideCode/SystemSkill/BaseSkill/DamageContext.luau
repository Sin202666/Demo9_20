--[[
	DamageContext - 伤害计算上下文
	用于「算多少伤害」，避免参数散落

	字段：attackerData、defenderData、skillPower、skillPurity、mpTp、combatSeed、
	     elementType、hitIndex、hitboxIndex、damageProfileId、summonDirectDamage
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local ElementTp = Utils.EnumMgr.ElementTp

local DamageContext = {}

--[[
	从 applyHit 场景构建 DamageContext
	@param attackerData table
	@param defenderData table
	@param skillContext table? { skillPower, skillPurity, mpTp, combatSeed, hitIndex, hitboxIndex, damageProfileId }
	@param hitbox table? 提供 hitboxIndex、_hitCounter
	@return table damageCtx
]]
function DamageContext.create(attackerData, defenderData, skillContext, hitbox)
	if not attackerData or not defenderData then return nil end

	local ctx = skillContext or {}
	local hitIndex = ctx.hitIndex or (hitbox and (hitbox._hitCounter or 0) + 1) or 0
	local hitboxIndex = ctx.hitboxIndex or (hitbox and hitbox.hitboxIndex) or 0

	return {
		attackerData = attackerData,
		defenderData = defenderData,
		skillPower = ctx.skillPower or 1,
		skillPurity = ctx.skillPurity or 1,
		summonDirectDamage = ctx.summonDirectDamage == true,
		mpTp = ctx.mpTp,
		combatSeed = ctx.combatSeed or attackerData.combatSeed,
		elementType = ctx.elementType or ElementTp.None,
		hitIndex = hitIndex,
		hitboxIndex = hitboxIndex,
		damageProfileId = ctx.damageProfileId,
	}
end

return DamageContext
