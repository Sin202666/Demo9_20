--[[
	Module: HitResolver
	Description: 命中结算器（服权威写口：HitPolicy、伤害、TakeDamage、飘字、击退）
	Author: 林奥宇
	Created: 2026-07-29
	Last Modified: 2026-09-01

	功能：
	- applyHit / applyLogicalEnemyHit：按 HitPolicy 结算伤害、Buff、逻辑怪 Hit、角色击退
	- canApplyHit / canApplyHitFromContext：是否可结算（自伤/友伤/hitOnce）
	- getEntityIdentity / isOwner / isFriendly：归属与阵营查询（委托 EntityUtil）

	子模块（业务只经本 façade，不要直接 require 子文件）：
	- Query.luau         身份 / 阵营 / canApplyHit
	- ApplyHit.luau      Model 命中分流
	- LogicalEnemy.luau  逻辑怪命中
	- Destructible.luau  可破坏物
	- Knockback.luau     角色击退（SystemCharacterMotion）

	与同类：
	- Hitbox 只检测候选；本模块决定是否结算。客机 Utils.HitResolver 回落 ToolSystem stub（apply* 为 no-op）
	- 角色击退只经 SystemCharacterMotion.FireKnockback → CharacterMotion.ApplyKnockback
	- 瞄准点不得作为命中或发奖证据；不绑 Remote、不写 DataStore

	加载方式：
		local HitResolver = Utils.HitResolver
		HitResolver.applyHit(baseSkill, hitbox, hitpart, partParent)
]]

local Query = require(script.Query)
local ApplyHit = require(script.ApplyHit)
local LogicalEnemy = require(script.LogicalEnemy)

local HitResolver = {}

HitResolver.getEntityIdentity = Query.getEntityIdentity
HitResolver.getEntityCamp = Query.getEntityCamp
HitResolver.getEntityOwnerId = Query.getEntityOwnerId
HitResolver.isSameEntity = Query.isSameEntity
HitResolver.isOwner = Query.isOwner
HitResolver.isFriendly = Query.isFriendly
HitResolver.canApplyHitFromContext = Query.canApplyHitFromContext
HitResolver.canApplyHit = Query.canApplyHit
HitResolver.applyHit = ApplyHit.applyHit
HitResolver.applyLogicalEnemyHit = LogicalEnemy.applyLogicalEnemyHit

return HitResolver
