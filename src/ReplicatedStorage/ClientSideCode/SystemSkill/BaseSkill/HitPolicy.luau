--[[
	命中规则（HitPolicy）
	职责：定义命中语义，供 HitResolver 判断是否真正生效
	Hitbox 只负责检测候选，HitResolver 根据 policy 决定是否结算

	分层：Hitbox 检测 → HitPolicy 规则 → HitResolver 结算
]]

export type HitPolicy = {
	-- 每次激活只命中一次（整个 hitbox 生命周期内）
	hitOncePerActivation: boolean?,
	-- 每个目标只命中一次（或受 repeatHitCooldown 限制）
	hitOncePerTarget: boolean?,
	-- 重复命中冷却（秒），0 表示 hitOncePerTarget 时不再命中
	repeatHitCooldown: number?,
	-- 穿透敌人（命中后继续飞行/检测）
	canPierceEnemy: boolean?,
	-- 穿透障碍物（命中墙体等不停止）
	canPierceObstacle: boolean?,
	-- 命中第一个敌人后停止飞行（弹道用）
	stopOnFirstEnemy: boolean?,
	-- 命中障碍物后停止飞行（弹道用）
	stopOnObstacle: boolean?,
	-- 允许友伤
	allowFriendlyFire: boolean?,
	-- 允许命中自己
	allowSelfHit: boolean?,
}

local DEFAULT_POLICY: HitPolicy = {
	hitOncePerActivation = false,
	hitOncePerTarget = true,
	repeatHitCooldown = 0,
	canPierceEnemy = false,
	canPierceObstacle = false,
	stopOnFirstEnemy = true,
	stopOnObstacle = true,
	allowFriendlyFire = false,
	allowSelfHit = false,
}

local HitPolicyModule = {}

--[[
	获取默认命中规则
]]
function HitPolicyModule.default(): HitPolicy
	local out = {}
	for k, v in pairs(DEFAULT_POLICY) do
		out[k] = v
	end
	return out
end

--[[
	合并策略（覆盖式，nil 不覆盖）
	@param base HitPolicy 基础策略
	@param override HitPolicy? 覆盖项
	@return HitPolicy 合并后的策略
]]
function HitPolicyModule.merge(base: HitPolicy, override: HitPolicy?): HitPolicy
	if not override then return base end
	local out = {}
	for k, v in pairs(base) do
		out[k] = v
	end
	for k, v in pairs(override) do
		if v ~= nil then
			out[k] = v
		end
	end
	return out
end

--[[
	从 hitboxConfig 条目解析 HitPolicy
	@param hitboxEntry table? hitboxConfig 中单条（可含 HitPolicy 字段）
	@return HitPolicy
]]
function HitPolicyModule.fromHitboxEntry(hitboxEntry): HitPolicy
	local base = HitPolicyModule.default()
	local override = hitboxEntry and hitboxEntry.HitPolicy
	return HitPolicyModule.merge(base, override)
end

return HitPolicyModule
