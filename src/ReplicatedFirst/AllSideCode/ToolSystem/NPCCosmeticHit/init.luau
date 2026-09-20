--[[
	Module: NPCCosmeticHit
	Description: 逻辑怪「仅表现」受击动画客户端播轨（服写口在 ServerSideCode.System.NPCCosmeticHit）
	Author: 林奥宇
	Created: 2026-08-17
	Last Modified: 2026-08-31

	能力：
	- handleIncoming：按 payload 在 LocalMonster 上播受击轨（NPCCosmeticHitPlay）
	- tryPlayLogical：客机 no-op（防误调）
	- 不进 CombatWorld；不做完整 Hurt 硬直；不写逻辑怪权威位姿

	Utils.NPCCosmeticHit 服务端优先加载真模块；本文件仅非服回落。
	客侧由 EnemyManager 注册 NPC_COSMETIC_HIT 后转发至此。

	加载：
		local NPCCosmeticHit = Utils.NPCCosmeticHit
		NPCCosmeticHit.handleIncoming(payload)
]]

local NPCCosmeticHitPlay = require(script.NPCCosmeticHitPlay)

local NPCCosmeticHit = {}

--[[
	客机 stub：不下发 Nearby 包
	@param _rec table - LogicalRecord；客机忽略
	@param _realDmg number - 实际伤害；客机忽略
	@param _skillId number? - 技能 ID；客机忽略
]]
function NPCCosmeticHit.tryPlayLogical(_rec: any, _realDmg: number, _skillId: number?)
end

--[[
	处理 NetMsg.NPC_COSMETIC_HIT 下行
	@param payload table - { monsterId: string, animName: string, fadeTime: number?, speed: number?, skillid: number? }
]]
function NPCCosmeticHit.handleIncoming(payload: any)
	NPCCosmeticHitPlay.playFromPayload(payload)
end

return NPCCosmeticHit
