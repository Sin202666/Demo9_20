--[[
	Module: HitResolver
	Description: 命中结算客户端 stub（权威写口在 ServerSideCode.System.HitResolver）
	Author: 林奥宇
	Created: 2026-07-29
	Last Modified: 2026-08-31

	功能：
	- applyHit / applyLogicalEnemyHit：客机 no-op（不结算伤害、不写击退）
	- 查询类 API 不在本 stub 提供；检测层仍走 Hitbox / HitQueryContext

	Utils.HitResolver 服务端优先加载真模块；本文件仅非服回落。
	勿在客户端当伤害 / 掉落 / 击退权威。击退仍只经 SystemCharacterMotion → CharacterMotion。

	加载方式：
		local HitResolver = Utils.HitResolver
		HitResolver.applyHit(baseSkill, hitbox, hitpart, partParent)
]]

local HitResolver = {}

--[[
	客户端 stub：不结算 Model / 逻辑怪命中
	@param _baseSkill any - 技能实例；客机忽略
	@param _hitbox any - 命中盒；客机忽略
	@param _hitpart any? - 命中部件或 Position；客机忽略
	@param _partParent any - Model 或逻辑怪 id；客机忽略
	@param _damageContext any? - 伤害上下文；客机忽略
]]
function HitResolver.applyHit(_baseSkill: any, _hitbox: any, _hitpart: any?, _partParent: any, _damageContext: any?)
end

--[[
	客户端 stub：不结算逻辑怪命中
	@param _baseSkill any - 技能实例；客机忽略
	@param _hitbox any - 命中盒；客机忽略
	@param _enemyId number - 逻辑怪运行时 id；客机忽略
	@param _hitpart any? - 相交参考点；客机忽略
	@param _damageContext any? - 伤害上下文；客机忽略
]]
function HitResolver.applyLogicalEnemyHit(_baseSkill: any, _hitbox: any, _enemyId: number, _hitpart: any?, _damageContext: any?)
end

return HitResolver
