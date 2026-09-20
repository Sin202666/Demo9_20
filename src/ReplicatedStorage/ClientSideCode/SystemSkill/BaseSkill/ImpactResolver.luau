--[[
	ImpactResolver - 命中后果解析器（统一协议）
	职责：根据 ImpactContext 驱动状态转换、回调、后续逻辑
	即使当前实现较薄，也预留接口，便于后续扩展护盾、元素反应、DOT、穿透等
]]

local SkillEventConst = require(script.Parent.SkillEventConst)
local EVT = SkillEventConst

local IMPACT_TYPE_TO_EVENT = {
	Enemy = EVT.EnemyHit,
	Obstacle = EVT.ObstacleHit,
	Timeout = EVT.Timeout,
	Ground = EVT.ObstacleHit,
	Shield = EVT.ObstacleHit,
}

local ImpactResolver = {}

--[[
	统一协议：解析 ImpactContext 并驱动技能状态转换
	@param impactCtx table 由 ImpactContext.fromImpact 或直接构建
	@param skillInstance BaseSkillServer 技能实例
	@return boolean 是否成功结算（已结算过则返回 false）
]]
function ImpactResolver.resolveImpact(impactCtx, skillInstance)
	if not impactCtx or not skillInstance then return false end

	local runData = skillInstance.skillRunData
	if not runData or not runData.Logic then return false end
	if runData.Logic.hasExploded then return false end
	if runData.State.current ~= "ProjectileFlying" then return false end

	runData.Logic.hasExploded = true
	runData.Logic.impactPosition = impactCtx.hitPosition
	runData.Logic.impactType = impactCtx.impactType
	runData.Logic.impactTargetId = impactCtx.targetId

	local eventName = IMPACT_TYPE_TO_EVENT[impactCtx.impactType] or EVT.Timeout
	local payload = {
		hitPosition = impactCtx.hitPosition,
		hitType = impactCtx.impactType,
		targetId = impactCtx.targetId,
	}

	local module = skillInstance.skillModule
	if module and type(module.onProjectileImpact) == "function" then
		module.onProjectileImpact(skillInstance, impactCtx)
	end

	skillInstance:TryTransition(eventName, payload)
	return true
end

return ImpactResolver
