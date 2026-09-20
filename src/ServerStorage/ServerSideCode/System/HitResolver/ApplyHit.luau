--[[
	Module: HitResolver.ApplyHit
	Description: Model 命中结算（伤害、Buff、可破坏物、击退）
	Author: 林奥宇
	Created: 2026-09-01
	Last Modified: 2026-09-01

	角色击退只经 Knockback → SystemCharacterMotion。逻辑怪 id 转交 LogicalEnemy。
	业务只经 Utils.HitResolver.applyHit，不要直接 require 本文件。
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local CollectionService = Utils.CollectionService
local SystemPlrAttr = Utils.SystemPlrAttr
local SystemEnemy = Utils.SystemEnemy
local SystemSummon = Utils.SystemSummon
local Players = Utils.Players
local GetData = Utils.GetData
local RemoteEventModule = Utils.RemoteEvent
local RemoteEvent = RemoteEventModule and RemoteEventModule.RemoteEvent
local SkillBuffUtil = Utils.SkillBuffUtil
local Log = Utils.Log

local BaseSkillFolder = game.ReplicatedStorage.ClientSideCode.SystemSkill.BaseSkill
local GetSkillData = require(BaseSkillFolder.GetSkillData)
local SkillDamageRateFromCfg = require(BaseSkillFolder.SkillDamageRateFromCfg)
local DamageResolver = require(BaseSkillFolder.DamageResolver)
local DamageContext = require(BaseSkillFolder.DamageContext)
local HitQueryContext = require(BaseSkillFolder.HitQueryContext)

local Query = require(script.Parent.Query)
local LogicalEnemy = require(script.Parent.LogicalEnemy)
local Destructible = require(script.Parent.Destructible)
local Knockback = require(script.Parent.Knockback)

local ApplyHit = {}

--[[
	写入本次命中的攻击者元数据（hitboxIndex / combatSeed / hitIndex）。

	@param attackerData table - GetSkillData.getAttackerData 结果
	@param baseSkill any - 技能实例
	@param hitbox any - 命中盒
	@return nil
]]
local function _fillAttackerMeta(attackerData, baseSkill, hitbox)
	attackerData.hitboxIndex = hitbox.hitboxIndex
	attackerData.skillName = hitbox.skillName or baseSkill.skillName
	attackerData.skillID = baseSkill.skillID
	attackerData.mpTp = baseSkill.mpTp
	attackerData.combatSeed = hitbox.combatSeed or baseSkill.combatSeed
	hitbox._hitCounter = (hitbox._hitCounter or 0) + 1
	attackerData.hitIndex = hitbox._hitCounter
end

--[[
	解析 Model 命中的伤害与 hitData。

	@param baseSkill any - 技能实例
	@param hitbox any - 命中盒
	@param hitpart BasePart? - 命中部件
	@param attackerData table - 攻击者数据
	@param defenderData table - 防御者数据
	@param damageContext table? - 可选伤害上下文
	@return table, number, Vector3? - hitData、knockback、命中盒世界坐标
]]
local function _resolveModelHit(baseSkill, hitbox, hitpart, attackerData, defenderData, damageContext)
	local isSummonAttacker = hitbox.hitboxOwnerType == "Summon"
	local skillCtx = damageContext or {}
	skillCtx.hitIndex = skillCtx.hitIndex or hitbox._hitCounter
	skillCtx.hitboxIndex = skillCtx.hitboxIndex or hitbox.hitboxIndex
	skillCtx.combatSeed = skillCtx.combatSeed or baseSkill.combatSeed
	skillCtx.skillPower = skillCtx.skillPower or baseSkill.skillPower
	skillCtx.skillPurity = skillCtx.skillPurity or baseSkill.skillPurity
	if isSummonAttacker then
		skillCtx.summonDirectDamage = true
	end
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
			knockback = 10,
			showDamageText = true,
			hitReactionType = "LightHit",
			damageTags = {},
		}
	end

	local skillDamage = resolveResult.finalDamage
	local isCrit = resolveResult.isCritical
	local knockback = resolveResult.knockback or 0
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
	if not isSummonAttacker and (not damageProfileUsed or damageProfileUsed.baseDamage == nil) then
		local tierDamageMul = GetData.GetSkillMpTierDamageRateMul(baseSkill.mpTp)
		local purityDamageMul = GetData.GetSkillPurityDamageRateMul(baseSkill.skillPurity)
		hitDataDamageRate = hitDataDamageRate * tierDamageMul * purityDamageMul
	end

	if hitbox.hitboxOwnerType == "Mirror" then
		local mirrorModel = GetSkillData.getCharacter("Mirror", hitbox.hitboxOwnerId)
		local mirrorMul = mirrorModel and tonumber(mirrorModel:GetAttribute("MirrorDamageMul"))
		if mirrorMul and mirrorMul > 0 then
			hitDataDamageRate = hitDataDamageRate * mirrorMul
			skillDamage = math.max(0, math.floor(skillDamage * mirrorMul + 0.5))
		end
	end

	local hitboxWorldPosition = nil
	local hbPart = hitbox.hitbox
	if hbPart and hbPart:IsA("BasePart") then
		hitboxWorldPosition = hbPart.Position
	elseif hitpart and hitpart:IsA("BasePart") then
		hitboxWorldPosition = hitpart.Position
	end

	local hitData = {
		attackerPlayerId = hitbox.hitboxOwnerId,
		damageRate = hitDataDamageRate,
		eleTp = skillModule.skillElementType,
		isCrit = isCrit,
		hitboxWorldPosition = hitboxWorldPosition,
		skillid = attackerData.skillID,
		finalDamage = skillDamage or 0,
		skillPurity = baseSkill.skillPurity,
	}
	return hitData, knockback, hitboxWorldPosition
end

--[[
	造成有效伤害后对受击 Model 叠技能 Buff。

	@param baseSkill any - 技能实例
	@param hitbox any - 命中盒
	@param partParent Model - 受击 Model
	@param skillDamage number? - 本次最终伤害
	@return nil
]]
local function _tryApplyEnemySkillBuffs(baseSkill, hitbox, partParent, skillDamage)
	if (skillDamage or 0) <= 0 then
		return
	end
	local sid = tonumber(baseSkill.skillID)
	if not sid or sid <= 0 then
		return
	end
	local atkInst: Model | Player? = nil
	if hitbox.hitboxOwnerType == "Player" then
		atkInst = Players:GetPlayerByUserId(hitbox.hitboxOwnerId)
	elseif hitbox.hitboxOwnerType == "Mirror" then
		local mirrorModel = GetSkillData.getCharacter("Mirror", hitbox.hitboxOwnerId)
		local ownerUserId = mirrorModel and mirrorModel:GetAttribute("OwnerUserId")
		if typeof(ownerUserId) == "number" then
			atkInst = Players:GetPlayerByUserId(ownerUserId)
		end
	else
		atkInst = GetSkillData.getCharacter(hitbox.hitboxOwnerType, hitbox.hitboxOwnerId)
	end
	SkillBuffUtil.ApplySkillBuffsToDefender(partParent, sid, {
		skillPower = baseSkill.skillPower,
		skillPurity = baseSkill.skillPurity,
		mpTp = baseSkill.mpTp,
		attacker = atkInst,
	})
end

--[[
	按 hitboxOwnerType 分流：可破坏物 / 怪 / 召唤物 / 打玩家。
	可破坏物路径已含 Buff 并应提前结束（不下发角色击退、不 recordHit）。

	@param baseSkill any - 技能实例
	@param hitbox any - 命中盒
	@param partParent Model - 受击 Model
	@param hitData table - 伤害包
	@param knockback number - 击退速度
	@return boolean - true 表示已完整处理，调用方应直接 return
]]
local function _applyOwnerHit(baseSkill, hitbox, partParent, hitData, knockback)
	local skillDamage = hitData.finalDamage

	if hitbox.hitboxOwnerType == "Player" then
		if CollectionService:HasTag(partParent, "CanBroke") then
			local hitPlr = game.Players:GetPlayerByUserId(hitbox.hitboxOwnerId)
			Destructible.applyBroken(hitPlr, partParent, hitData, hitbox, knockback)
			_tryApplyEnemySkillBuffs(baseSkill, hitbox, partParent, skillDamage)
			return true
		end

		local summonFolder = workspace:FindFirstChild("Summons")
		if summonFolder and partParent:IsDescendantOf(summonFolder) then
			if SystemSummon and SystemSummon.Hit then
				SystemSummon.Hit(hitbox.hitboxOwnerId, partParent.Name, hitData)
			end
		else
			if SystemEnemy and SystemEnemy.Hit then
				SystemEnemy.Hit(hitbox.hitboxOwnerId, partParent.Name, hitData)
			end
		end

	elseif hitbox.hitboxOwnerType == "Mirror" then
		local mirrorModel = GetSkillData.getCharacter("Mirror", hitbox.hitboxOwnerId)
		local ownerUserId = mirrorModel and mirrorModel:GetAttribute("OwnerUserId")
		if typeof(ownerUserId) == "number" then
			hitData.attackerPlayerId = ownerUserId

			if CollectionService:HasTag(partParent, "CanBroke") then
				local hitPlr = Players:GetPlayerByUserId(ownerUserId)
				if hitPlr then
					Destructible.applyBroken(hitPlr, partParent, hitData, hitbox, knockback)
				end
				_tryApplyEnemySkillBuffs(baseSkill, hitbox, partParent, skillDamage)
				return true
			end

			local summonFolder = workspace:FindFirstChild("Summons")
			if summonFolder and partParent:IsDescendantOf(summonFolder) then
				if SystemSummon and SystemSummon.Hit then
					SystemSummon.Hit(ownerUserId, partParent.Name, hitData)
				end
			else
				if SystemEnemy and SystemEnemy.Hit then
					SystemEnemy.Hit(ownerUserId, partParent.Name, hitData)
				end
			end
		end

	elseif hitbox.hitboxOwnerType == "NPC" then
		local enemyModel: Model = GetSkillData.getCharacter(hitbox.hitboxOwnerType, hitbox.hitboxOwnerId)

		if CollectionService:HasTag(partParent, "CanBroke") and enemyModel then
			Destructible.applyBroken(enemyModel, partParent, hitData, hitbox, knockback)
			_tryApplyEnemySkillBuffs(baseSkill, hitbox, partParent, skillDamage)
			return true
		end

		local beHitPlr: Player = Players:GetPlayerFromCharacter(partParent)
		if enemyModel and beHitPlr then
			local dmg = SystemPlrAttr.HitPlr(enemyModel, beHitPlr, hitData)
			if dmg > 0 then
				local hitPos = partParent:GetPivot().Position
				for _, player in pairs(game.Players:GetPlayers()) do
					local character = player.Character
					if character and (character:GetPivot().Position - hitPos).Magnitude < 150 then
						if RemoteEvent then
							RemoteEvent:FireClient(player, "玩家受击表现", beHitPlr.UserId)
						end
					end
				end
			end
		else
			local summonFolder = workspace:FindFirstChild("Summons")
			if enemyModel and summonFolder and partParent:IsDescendantOf(summonFolder) then
				hitData.attackerModel = enemyModel
				SystemSummon.HitFromNpc(partParent.Name, hitData)
			end
		end

	elseif hitbox.hitboxOwnerType == "Summon" then
		local summonModel: Model? = GetSkillData.getCharacter("Summon", hitbox.hitboxOwnerId)
		local ownerId = summonModel and summonModel:GetAttribute("OwnerId")
		if typeof(ownerId) == "number" then
			hitData.attackerPlayerId = ownerId
		end

		if CollectionService:HasTag(partParent, "CanBroke") and summonModel then
			Destructible.applyBroken(summonModel, partParent, hitData, hitbox, knockback)
			_tryApplyEnemySkillBuffs(baseSkill, hitbox, partParent, skillDamage)
			return true
		end

		local monsterFolder = workspace:FindFirstChild("Monster")
		if monsterFolder and partParent:IsDescendantOf(monsterFolder) then
			if typeof(ownerId) == "number" and summonModel then
				hitData.attackerModel = summonModel
				SystemEnemy.Hit(ownerId, partParent.Name, hitData)
			end
			return true
		end

		local beHitPlrSummon: Player? = Players:GetPlayerFromCharacter(partParent)
		if summonModel and beHitPlrSummon then
			local dmg = SystemPlrAttr.HitPlr(summonModel, beHitPlrSummon, hitData)
			if dmg > 0 then
				local hitPos = partParent:GetPivot().Position
				for _, player in pairs(game.Players:GetPlayers()) do
					local character = player.Character
					if character and (character:GetPivot().Position - hitPos).Magnitude < 150 then
						if RemoteEvent then
							RemoteEvent:FireClient(player, "玩家受击表现", beHitPlrSummon.UserId)
						end
					end
				end
			end
		end
	end

	return false
end

--[[
	应用一次命中结算（伤害 + 飘字 + 击退）。
	先经 canApplyHit 判断，通过后才结算并 recordHit。

	@param baseSkill any - 技能实例
	@param hitbox any - 命中盒
	@param hitpart BasePart | Vector3? - 命中部件；逻辑怪可为中心 Position
	@param partParent Model | number - 命中 Model，或逻辑怪运行时 id
	@param damageContext table? - 伤害上下文
	@return nil
]]
function ApplyHit.applyHit(baseSkill, hitbox, hitpart, partParent: Model | number, damageContext)
	if not baseSkill or not hitbox or partParent == nil then
		return
	end

	if typeof(partParent) == "number" then
		LogicalEnemy.applyLogicalEnemyHit(baseSkill, hitbox, partParent, hitpart, damageContext)
		return
	end

	local hitQueryCtx = HitQueryContext.create(hitbox, partParent, baseSkill.nowTime)
	if not hitQueryCtx or not Query.canApplyHitFromContext(hitQueryCtx) then
		return
	end

	local attackerData = GetSkillData.getAttackerData(hitbox.hitboxOwnerId, hitbox.hitboxOwnerType)
	local defenderData = GetSkillData.getDefenderData(partParent)
	if not attackerData or not defenderData then
		Log.warn("[HitResolver] 攻击者或被攻击者数据为空，跳过结算")
		return
	end

	_fillAttackerMeta(attackerData, baseSkill, hitbox)
	local hitData, knockback, hitboxWorldPosition = _resolveModelHit(
		baseSkill,
		hitbox,
		hitpart,
		attackerData,
		defenderData,
		damageContext
	)

	if _applyOwnerHit(baseSkill, hitbox, partParent, hitData, knockback) then
		return
	end

	_tryApplyEnemySkillBuffs(baseSkill, hitbox, partParent, hitData.finalDamage)
	Knockback.dispatchPlayerKnockback(baseSkill, hitbox, partParent, knockback, hitboxWorldPosition)

	if hitbox.recordHit then
		hitbox:recordHit(partParent, baseSkill.nowTime)
	end
end

return ApplyHit
