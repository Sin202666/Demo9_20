--[[
	Module: EnemyManager
	Description: 客户端逻辑怪表现启动与同步注册（薄 Manager）
	Author: 林奥宇
	Created: 2026-08-12
	Last Modified: 2026-08-18

	职责：
	- SystemLogicalEnemy.Init
	- 注册 ENEMY_LOGICAL_SPAWN / TRANSFORM / STATE / DEATH / DISPLACE
	- 注册 SKILL_HIT_PRESENTATION / NPC_COSMETIC_HIT（怪物受击表现）

	配置（GameConfig.怪物系统.启用）：
	- false 时本 Manager 不注册、不运行
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local SystemGameConfig = Utils.SystemGameConfig

if SystemGameConfig.GetValue({ "怪物系统", "启用" }) == false then
	return
end

local NetWork = Utils.NetWork
local NetMsg = Utils.NetMsg
local SystemLogicalEnemy = Utils.SystemLogicalEnemy
local SkillHitPresentation = Utils.SkillHitPresentation
local NPCCosmeticHit = Utils.NPCCosmeticHit

SystemLogicalEnemy.Init()

NetWork.RegisterClientRemoteEvent(NetMsg.ENEMY_LOGICAL_SPAWN, function(payload)
	SystemLogicalEnemy.OnSpawn(payload)
end)

NetWork.RegisterClientRemoteEvent(NetMsg.ENEMY_LOGICAL_TRANSFORM, function(payload)
	SystemLogicalEnemy.OnTransform(payload)
end)

NetWork.RegisterClientRemoteEvent(NetMsg.ENEMY_LOGICAL_STATE, function(payload)
	SystemLogicalEnemy.OnState(payload)
end)

NetWork.RegisterClientRemoteEvent(NetMsg.ENEMY_LOGICAL_DEATH, function(payload)
	SystemLogicalEnemy.OnDeath(payload)
end)

NetWork.RegisterClientRemoteEvent(NetMsg.ENEMY_LOGICAL_DISPLACE, function(payload)
	SystemLogicalEnemy.OnDisplace(payload)
end)

NetWork.RegisterClientRemoteEvent(NetMsg.SKILL_HIT_PRESENTATION, function(payload)
	if SkillHitPresentation and SkillHitPresentation.handleIncoming then
		SkillHitPresentation.handleIncoming(payload)
	end
end)

NetWork.RegisterClientRemoteEvent(NetMsg.NPC_COSMETIC_HIT, function(payload)
	if NPCCosmeticHit and NPCCosmeticHit.handleIncoming then
		NPCCosmeticHit.handleIncoming(payload)
	end
end)
