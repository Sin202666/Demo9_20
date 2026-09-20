--[[
	HitQueryContext - 命中查询上下文
	用于「是否可命中」判断，避免参数散落

	字段：attacker identity、target identity、hitbox index、hit policy、
	     nowTime、sameEntity、friendly、owner info、isForeignPlayerSummon
]]

local EntityUtil = require(script.Parent.EntityUtil)
local HitPolicy = require(script.Parent.HitPolicy)

local HitQueryContext = {}

--[[
	从 hitbox + targetModel 构建 HitQueryContext
	@param hitbox table { hitboxOwnerId, hitboxOwnerType, hitboxIndex, hitPolicy, _activationHitCount, hitHistory }
	@param targetModel Model 命中的目标 Model
	@param nowTime number?
	@return table hitQueryCtx
]]
function HitQueryContext.create(hitbox, targetModel, nowTime)
	if not hitbox or not targetModel then return nil end

	local policy = hitbox.hitPolicy or HitPolicy.default()
	local targetId, targetType = EntityUtil.getEntityIdentity(targetModel)
	local isOwner = EntityUtil.isOwnedBy(hitbox.hitboxOwnerId, hitbox.hitboxOwnerType, targetModel)
	local isFriendly = EntityUtil.isFriendly(
		{ id = hitbox.hitboxOwnerId, type = hitbox.hitboxOwnerType },
		targetModel
	)
	local isForeignPlayerSummon = EntityUtil.isForeignPlayerOwnedSummon(
		hitbox.hitboxOwnerId,
		hitbox.hitboxOwnerType,
		targetModel
	)

	return {
		attackerId = hitbox.hitboxOwnerId,
		attackerType = hitbox.hitboxOwnerType,
		targetId = targetId,
		targetType = targetType,
		targetModel = targetModel,
		hitboxIndex = hitbox.hitboxIndex,
		hitPolicy = policy,
		nowTime = nowTime or 0,
		sameEntity = (targetId ~= nil and EntityUtil.idsEqual(hitbox.hitboxOwnerId, targetId) and hitbox.hitboxOwnerType == targetType),
		isOwner = isOwner,
		isFriendly = isFriendly,
		isForeignPlayerSummon = isForeignPlayerSummon,
		_activationHitCount = hitbox._activationHitCount or 0,
		_hitHistory = hitbox.hitHistory or {},
	}
end

--[[
	是否应纳入 Hitbox 候选（穿透友方/己方，不写入 checkedParts）
	与 HitResolver.canApplyHitFromContext 的归属/友伤规则一致，不含 hitOnce 类规则
]]
function HitQueryContext.isDetectableTarget(hitQueryCtx)
	if not hitQueryCtx then return false end
	local policy = hitQueryCtx.hitPolicy or HitPolicy.default()
	if not policy.allowSelfHit and hitQueryCtx.isOwner then
		return false
	end
	if not policy.allowFriendlyFire and hitQueryCtx.isFriendly then
		return false
	end
	if hitQueryCtx.isForeignPlayerSummon then
		return false
	end
	return true
end

return HitQueryContext
