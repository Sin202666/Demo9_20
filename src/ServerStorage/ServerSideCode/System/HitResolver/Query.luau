--[[
	Module: HitResolver.Query
	Description: 命中查询（身份、阵营、是否可结算）；由 HitResolver/init 再导出
	Author: 林奥宇
	Created: 2026-09-01
	Last Modified: 2026-09-01

	不结算伤害、不写击退。业务只经 Utils.HitResolver，不要直接 require 本文件。
]]

local BaseSkillFolder = game.ReplicatedStorage.ClientSideCode.SystemSkill.BaseSkill
local EntityUtil = require(BaseSkillFolder.EntityUtil)
local HitPolicy = require(BaseSkillFolder.HitPolicy)
local HitQueryContext = require(BaseSkillFolder.HitQueryContext)

local Query = {}

--[[
	获取目标 Model 的实体身份（委托 EntityUtil）。

	@param model Model? - 目标模型；非 Model 时返回 nil, nil
	@return any?, string? - 实体 id 与类型（"Player" / 自定义 EntityType）；无法识别则为 nil, nil
]]
function Query.getEntityIdentity(model)
	return EntityUtil.getEntityIdentity(model)
end

--[[
	获取 Model 的阵营（委托 EntityUtil）。

	@param model Model? - 目标模型
	@return string? - 阵营名（Attribute / 主人继承 / Team.Name）；无法识别则为 nil
]]
function Query.getEntityCamp(model)
	return EntityUtil.getEntityCamp(model)
end

--[[
	获取 Model 的归属主人（召唤物/宠物/分身，委托 EntityUtil）。

	@param model Model? - 目标模型
	@return any?, string? - 主人 id 与类型；无主人则为 nil, nil
]]
function Query.getEntityOwnerId(model)
	return EntityUtil.getEntityOwnerId(model)
end

--[[
	判断两个 Model 是否为同一实体（委托 EntityUtil）。

	@param a Model? - 实体 A
	@param b Model? - 实体 B
	@return boolean - id+type 相同，或双方无身份时实例相等，则为 true
]]
function Query.isSameEntity(a, b)
	return EntityUtil.isSameEntity(a, b)
end

--[[
	是否为目标所有者（技能释放者）或需规避的归属关系。

	@param hitbox any - 命中盒，须含 hitboxOwnerId / hitboxOwnerType
	@param targetModel Model? - 受击模型
	@return boolean - 属自身/主人/下属则 true；参数缺失则 false
]]
function Query.isOwner(hitbox, targetModel)
	if not hitbox or not targetModel then return false end
	return EntityUtil.isOwnedBy(hitbox.hitboxOwnerId, hitbox.hitboxOwnerType, targetModel)
end

--[[
	是否友方（同阵营，委托 EntityUtil）。

	@param hitbox any - 命中盒，须含 hitboxOwnerId / hitboxOwnerType
	@param targetModel Model? - 受击模型
	@return boolean - 同阵营则为 true；参数缺失则 false
]]
function Query.isFriendly(hitbox, targetModel)
	if not hitbox or not targetModel then return false end
	return EntityUtil.isFriendly(
		{ id = hitbox.hitboxOwnerId, type = hitbox.hitboxOwnerType },
		targetModel
	)
end

--[[
	根据 HitQueryContext 判断是否可结算此次命中（统一协议）。

	@param hitQueryCtx table - 由 HitQueryContext.create 构建
	@return boolean - 允许结算则为 true；ctx 缺失或策略拒绝则为 false
]]
function Query.canApplyHitFromContext(hitQueryCtx)
	if not hitQueryCtx then return false end
	local policy = hitQueryCtx.hitPolicy or HitPolicy.default()
	local nowTime = hitQueryCtx.nowTime or 0

	if not policy.allowSelfHit and hitQueryCtx.isOwner then
		return false
	end
	if not policy.allowFriendlyFire and hitQueryCtx.isFriendly then
		return false
	end
	if hitQueryCtx.isForeignPlayerSummon then
		return false
	end
	if policy.hitOncePerActivation and (hitQueryCtx._activationHitCount or 0) >= 1 then
		return false
	end
	if policy.hitOncePerTarget then
		local lastHitTime = (hitQueryCtx._hitHistory or {})[hitQueryCtx.targetModel]
		if lastHitTime then
			if (policy.repeatHitCooldown or 0) <= 0 then
				return false
			end
			if nowTime - lastHitTime < policy.repeatHitCooldown then
				return false
			end
		end
	end
	return true
end

--[[
	兼容旧 API：从 hitbox + targetModel 构建 HitQueryContext 后判断。

	@param hitbox any - 命中盒
	@param targetModel Model - 受击模型
	@param policy table? - HitPolicy；nil 时用 ctx 内默认
	@param nowTime number? - 当前技能时间（秒）；nil 时由 ctx 默认 0
	@return boolean - 允许结算则为 true；无法建 ctx 则为 false
]]
function Query.canApplyHit(hitbox, targetModel, policy, nowTime)
	local ctx = HitQueryContext.create(hitbox, targetModel, nowTime)
	if not ctx then return false end
	if policy then ctx.hitPolicy = policy end
	return Query.canApplyHitFromContext(ctx)
end

return Query
