--[[
	ImpactContext - 命中后果上下文
	用于「命中后产生什么结果」，避免参数散落

	字段：hitPosition、impactType、targetId、shouldExplode、penetrate、
	     ricochet、stopProjectile、spawnedEffects
]]

local Players = game:GetService("Players")

local ImpactContext = {}

--[[
	从 ProjectileImpact 原始结构构建 ImpactContext
	@param impact table { type, position, normal, target, hitResult, source }
	@return table impactCtx
]]
function ImpactContext.fromImpact(impact)
	if not impact then return nil end

	local targetId = nil
	if impact.target then
		local plr = Players:GetPlayerFromCharacter(impact.target)
		targetId = plr and plr.UserId or nil
	end

	return {
		hitPosition = impact.position,
		impactType = impact.type or "Timeout",
		targetId = targetId,
		shouldExplode = true, -- 默认爆炸/终止
		penetrate = false,
		ricochet = false,
		stopProjectile = true,
		spawnedEffects = {},
		-- 保留原始字段供扩展
		_normal = impact.normal,
		_target = impact.target,
		_hitResult = impact.hitResult,
		_source = impact.source,
	}
end

return ImpactContext
