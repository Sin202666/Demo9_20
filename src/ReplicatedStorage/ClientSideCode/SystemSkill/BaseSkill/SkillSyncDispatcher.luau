--[[
	技能同步统一派发层
	职责：按 SyncPolicy 事件策略表统一派发，半径、track、audience 策略集中管理

	调用方：BaseSkillServer、GroupSkillInstanceRuntime、HitResolver 等
	所有广播走 dispatch 入口，避免各写一套半径/track 逻辑
]]

local Players = game:GetService("Players")
local SkillSyncRouter = require(script.Parent.SkillSyncRouter)
local GetSkillData = require(script.Parent.GetSkillData)

local SkillSyncDispatcher = {}

--[[
	事件策略表：半径来源、是否 track、是否 deliverTrackedAudience
	defaultRadius: Data 字段名，用于 getRadius；fallback 为字段名或数字
]]
SkillSyncDispatcher.SyncPolicy = {
	BaseSkillStarted = { track = true, defaultRadius = "syncRadius" },
	Derived = { track = true, defaultRadius = "syncRadius" },
	BaseSkillStateTransition = { track = true, defaultRadius = "syncRadius" },
	ProjectileHitConfirmed = { track = true, defaultRadius = "hitConfirmRadius", fallback = "syncRadius" },
	ProximityStrikeWave = { track = true, defaultRadius = "syncRadius" },
	SolarFlareMeteorShot = { track = true, defaultRadius = "syncRadius" },
	ProjectilePathConfirmed = { track = true, defaultRadius = "syncRadius" },
	StopSkill = { track = true, deliverTrackedAudience = true, defaultRadius = "stopSyncRadius", fallback = "syncRadius" },
	DamageTip = { track = false, defaultRadius = "damageTipRadius", fallback = 60 },
}

local DEFAULT_RADIUS = 120

local function getCasterPlayer(context)
	local owner = context.owner or context
	local charType = owner.characterType
	local charId = owner.characterId
	if charType == "Player" and charId then
		return Players:GetPlayerByUserId(charId)
	end
	if charType == "Mirror" and charId then
		local mirrorModel = GetSkillData.getCharacter("Mirror", charId)
		local ownerUserId = mirrorModel and mirrorModel:GetAttribute("OwnerUserId")
		if typeof(ownerUserId) == "number" then
			return Players:GetPlayerByUserId(ownerUserId)
		end
	end
	return nil
end

--[[
	从 context 解析半径
	- context 有 getSyncRadius(phase)：BaseSkillServer，phase 即 eventType
	- context 有 groupSkillModule：GroupSkillInstanceRuntime，读 Data.syncRadius
	- 否则用 DEFAULT_RADIUS
]]
local function resolveRadius(context, policy, eventType)
	if context.getSyncRadius then
		return context:getSyncRadius(eventType)
	end
	if context.groupSkillModule and context.groupSkillModule.Data then
		local data = context.groupSkillModule.Data
		local field = policy.defaultRadius
		if type(data[field]) == "number" then
			return data[field]
		end
		if type(policy.fallback) == "string" and type(data[policy.fallback]) == "number" then
			return data[policy.fallback]
		end
		if type(policy.fallback) == "number" then
			return policy.fallback
		end
	end
	return policy.fallback == 60 and 60 or DEFAULT_RADIUS
end

--[[
	统一派发入口
	@param context table 上下文（BaseSkillServer 或 GroupSkillInstanceRuntime），需 skillCastId、getSyncRadius 或 groupSkillModule、characterId/characterType 或 owner
	@param eventType string SyncPolicy 中的事件类型
	@param payload any 载荷（DamageTip 时为 { hitPos, damageText, isCrit, dmgType }）
	@param originPos Vector3? 中心位置（半径筛选用），nil 时 StopSkill 用 fallbackOriginPos
]]
function SkillSyncDispatcher.dispatch(context, eventType, payload, originPos)
	local policy = SkillSyncDispatcher.SyncPolicy[eventType]
	if not policy then
		warn("[SkillSyncDispatcher] 未知事件类型:", eventType)
		return
	end

	local radius = resolveRadius(context, policy, eventType)
	local casterPlayer = getCasterPlayer(context)
	local skillCastId = context.skillCastId

	if eventType == "DamageTip" then
		local hitPos = payload.hitPos or originPos
		local damageText = payload.damageText or "0"
		local isCrit = payload.isCrit or false
		local dmgType = payload.dmgType
		SkillSyncRouter.broadcastDamageTipRelevant(hitPos, radius, hitPos, damageText, isCrit, dmgType, casterPlayer)
		return
	end

	if policy.deliverTrackedAudience then
		SkillSyncRouter.broadcastStopTrackedAndClear(skillCastId, payload, originPos, radius, casterPlayer)
		return
	end

	if policy.track then
		SkillSyncRouter.broadcastRelevantAndTrack(skillCastId, originPos, radius, payload, casterPlayer)
	else
		SkillSyncRouter.broadcastRelevant(originPos, radius, payload, casterPlayer)
	end
end

return SkillSyncDispatcher
