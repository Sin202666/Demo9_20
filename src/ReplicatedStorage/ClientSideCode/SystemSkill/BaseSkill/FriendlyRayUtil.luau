--[[
	FriendlyRayUtil - 穿透友方/己方实体的分段射线
	与 HitQueryContext / EntityUtil.isFriendly 语义一致：同阵营（含主人召唤物）不视为遮挡。
]]

local EntityUtil = require(script.Parent.EntityUtil)

local FriendlyRayUtil = {}

export type FriendlyRayContext = {
	id: any,
	type: string,
}

export type FriendlyRayOpts = {
	extraIgnore: { Instance }?,
	maxPenetrations: number?,
	ignoreWater: boolean?,
}

local DEFAULT_MAX_PENETRATIONS = 8
local PENETRATE_SURFACE_EPSILON = 0.01

function FriendlyRayUtil.getModelFromHit(hitPart: Instance): Model?
	if not hitPart or not hitPart:IsA("BasePart") then
		return nil
	end
	local model = hitPart:FindFirstAncestorOfClass("Model")
	if model then
		return model
	end
	if hitPart.Parent and hitPart.Parent:IsA("Model") then
		return hitPart.Parent
	end
	return nil
end

local function isIgnoredInstance(inst: Instance, ignore: { Instance }): boolean
	for _, entry in ignore do
		if inst == entry or inst:IsDescendantOf(entry) then
			return true
		end
	end
	return false
end

--[[
	命中部件是否应穿透（友方/己方，含主人召唤物）
]]
function FriendlyRayUtil.shouldPenetrateHit(hitPart: BasePart, ctx: FriendlyRayContext): boolean
	if not hitPart or not ctx or ctx.id == nil or not ctx.type then
		return false
	end
	local model = FriendlyRayUtil.getModelFromHit(hitPart)
	if not model then
		return false
	end
	return EntityUtil.isNonHostileTarget(ctx.id, ctx.type, model)
end

--[[
	弹道障碍射线：穿透友方/己方后，忽略敌方角色，仅返回墙体等真实遮挡
]]
function FriendlyRayUtil.raycastProjectileObstacle(
	origin: Vector3,
	direction: Vector3,
	ctx: FriendlyRayContext,
	opts: FriendlyRayOpts?
): RaycastResult?
	local result = FriendlyRayUtil.raycast(origin, direction, ctx, opts)
	if not result then
		return nil
	end
	local model = FriendlyRayUtil.getModelFromHit(result.Instance)
	if model and model:FindFirstChildOfClass("Humanoid") then
		return nil
	end
	return result
end

--[[
	分段射线：穿透友方后返回第一个真实遮挡命中；全程无阻挡则 nil。
]]
function FriendlyRayUtil.raycast(
	origin: Vector3,
	direction: Vector3,
	ctx: FriendlyRayContext,
	opts: FriendlyRayOpts?
): RaycastResult?
	local totalLength = direction.Magnitude
	if totalLength < 1e-4 then
		return nil
	end

	local maxPenetrations = (opts and opts.maxPenetrations) or DEFAULT_MAX_PENETRATIONS
	local ignoreWater = if opts and opts.ignoreWater ~= nil then opts.ignoreWater else true
	local dirUnit = direction.Unit
	local endPos = origin + direction

	local ignore: { Instance } = {}
	if opts and opts.extraIgnore then
		for _, inst in opts.extraIgnore do
			table.insert(ignore, inst)
		end
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Blacklist
	params.IgnoreWater = ignoreWater

	local currentOrigin = origin
	for _ = 1, maxPenetrations + 1 do
		local remaining = endPos - currentOrigin
		if remaining.Magnitude < 1e-4 then
			return nil
		end

		params.FilterDescendantsInstances = ignore
		local res = workspace:Raycast(currentOrigin, remaining, params) :: RaycastResult?
		if not res then
			return nil
		end

		if not FriendlyRayUtil.shouldPenetrateHit(res.Instance, ctx) then
			return res
		end

		local penetratedModel = FriendlyRayUtil.getModelFromHit(res.Instance)
		if penetratedModel and not isIgnoredInstance(penetratedModel, ignore) then
			table.insert(ignore, penetratedModel)
		elseif not isIgnoredInstance(res.Instance, ignore) then
			table.insert(ignore, res.Instance)
		end

		local traveled = (res.Position - currentOrigin).Magnitude
		currentOrigin = currentOrigin + dirUnit * (math.max(traveled, 1e-3) + PENETRATE_SURFACE_EPSILON)
		if (currentOrigin - origin).Magnitude >= totalLength - 1e-4 then
			return nil
		end
	end

	return nil
end

--[[
	origin → intentPos：穿透友方后返回最终落点；无真实遮挡则 intentPos。
]]
function FriendlyRayUtil.resolvePositionThroughFriendly(
	origin: Vector3,
	intentPos: Vector3,
	ctx: FriendlyRayContext,
	opts: FriendlyRayOpts?
): Vector3
	local delta = intentPos - origin
	if delta.Magnitude < 1e-4 then
		return intentPos
	end
	local res = FriendlyRayUtil.raycast(origin, delta, ctx, opts)
	if not res then
		return intentPos
	end
	return res.Position
end

return FriendlyRayUtil
