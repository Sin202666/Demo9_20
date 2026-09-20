--[[
	Module: PartConstants
	Description: Emit / Update / Transform 共用的查找表与位姿辅助（方向、形状、link、位移、接触加速度）
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-09-01

	功能：
	- resolveLinkCFrame / getParentScaleFactor / composeRotation
	- applyPositionOffset / resolveDisplacement / applyContactAccel
	- DirectionVectors[NormalId] → (axis, multiplier)
	- shapeFunctions[ParticleEmitterShape] → (offset, rotation, direction)

	模块关系：
	- Emit / EmitAnimate / EmitModel / Update / UpdateModel / UpdateBeam / Transform /
	  Engine / LinkTrack / LinkService / EventsCollision 只读调用
	- getParentScaleFactor 由调用方传入 GraphMod，本文件保持无 Graph require
	- 不写权威伤害/掉落；仅算 CFrame / 加速度向量

	加载方式：
		local Constants = require(script.Parent.PartConstants)

	使用示例：
		local cf = Constants.resolveLinkCFrame(link)
		simCF = Constants.applyPositionOffset(simCF, data, link, item, RangeMod, AxisLinksMod, emitCtx)
]]

local PartConstants = {}

--[[
	按类型取世界 CFrame：Attachment→WorldCFrame，Model→GetPivot，Bone→TransformedWorldCFrame，否则 .CFrame。

	@param link Instance - Attachment / Model / Bone / 其它有 CFrame 的实例
	@return CFrame - 世界空间 CFrame
]]
function PartConstants.resolveLinkCFrame(link)
	if link:IsA("Attachment") then return link.WorldCFrame end
	if link:IsA("Model") then return link:GetPivot() end
	if link:IsA("Bone") then return link.TransformedWorldCFrame end
	return link.CFrame
end

--[[
	嵌套粒子父 Model 链的合成缩放。parentScale 是经 .Parent 链接的链表
	（Model→Model→…；Part 原样下传同一节点）。每层乘 graph 采样或 StaticValue（钳 >0）。
	nil 链 → 1。GraphMod 由调用方传入，避免本模块 require Graph。
	gate：nil=各层都计（Size/视觉）；"motion"=仅 ScaleMotion；"rotation"=仅 ScaleRotation。

	@param parentScale table? - 链节点；字段 Parent / Graph / Seed / StartTime / LifeTime / StaticValue / ScaleMotion / ScaleRotation
	@param currentTime number - 当前墙钟（与节点 StartTime 配对算归一化寿命）
	@param GraphMod table - Graph 模块，须有 QueryPointsWithTime
	@param gate string? - nil | "motion" | "rotation"
	@return number - 合成缩放因子，至少乘过的每层 ≥0.001
]]
function PartConstants.getParentScaleFactor(parentScale, currentTime, GraphMod, gate)
	local factor = 1
	local ps = parentScale
	while ps do
		local include = true
		if gate == "motion" then include = ps.ScaleMotion ~= false
		elseif gate == "rotation" then include = ps.ScaleRotation == true end
		if include then
			local levelF
			if ps.StaticValue then
				levelF = math.max(0.001, ps.StaticValue)
			else
				local pI = math.clamp((currentTime - ps.StartTime) / ps.LifeTime, 0, 1)
				levelF = math.max(0.001, GraphMod.QueryPointsWithTime(pI, ps.Graph, ps.Seed))
			end
			factor = factor * levelF
		end
		ps = ps.Parent
	end
	return factor
end

--[[
	合成三轴旋转。LocalABC 为体轴 Tait-Bryan（左到右）。默认 Global 为遗留 Y*X*Z 固定轴，
	保证旧存档视觉不漂。发射轴与某旋转轴重合时固有序可能让该轴对发射方向 no-op，Global 更像锥形铺开。

	@param order string? - LocalXYZ / LocalXZY / LocalYXZ / LocalYZX / LocalZXY / LocalZYX；其它或 nil 为 Global
	@param rotXdeg number - X 轴角度（度）
	@param rotYdeg number - Y 轴角度（度）
	@param rotZdeg number - Z 轴角度（度）
	@return CFrame - 纯旋转 CFrame
]]
function PartConstants.composeRotation(order, rotXdeg, rotYdeg, rotZdeg)
	local rxCF = CFrame.Angles(math.rad(rotXdeg), 0, 0)
	local ryCF = CFrame.Angles(0, math.rad(rotYdeg), 0)
	local rzCF = CFrame.Angles(0, 0, math.rad(rotZdeg))
	if order == "LocalXYZ" then return rxCF * ryCF * rzCF end
	if order == "LocalXZY" then return rxCF * rzCF * ryCF end
	if order == "LocalYXZ" then return ryCF * rxCF * rzCF end
	if order == "LocalYZX" then return ryCF * rzCF * rxCF end
	if order == "LocalZXY" then return rzCF * rxCF * ryCF end
	if order == "LocalZYX" then return rzCF * ryCF * rxCF end
	return ryCF * rxCF * rzCF -- Global default
end

PartConstants.DirectionVectors = {
	[Enum.NormalId.Top]    = {vector = "UpVector",    multiplier = 1},
	[Enum.NormalId.Bottom] = {vector = "UpVector",    multiplier = -1},
	[Enum.NormalId.Front]  = {vector = "LookVector",  multiplier = 1},
	[Enum.NormalId.Back]   = {vector = "LookVector",  multiplier = -1},
	[Enum.NormalId.Left]   = {vector = "RightVector", multiplier = -1},
	[Enum.NormalId.Right]  = {vector = "RightVector", multiplier = 1},
}

-- Each shape returns (offset, lookAtRotation, outwardDirection).
-- rotation applied only when LookAtInitially is true; direction sign-modulated by ShapeInOut.
PartConstants.shapeFunctions = {
	[Enum.ParticleEmitterShape.Box] = function(p, emitter)
		local Px = (math.random() * 2 - 1) * p.Size.X / 2
		local Py = (math.random() * 2 - 1) * p.Size.Y / 2
		local Pz = (math.random() * 2 - 1) * p.Size.Z / 2
		-- Box has no radial; use offset.Unit (origin-aligned falls back to world up).
		local offset = Vector3.new(Px, Py, Pz)
		local dir = offset.Magnitude > 1e-4 and offset.Unit or Vector3.yAxis
		local sRot = offset.Magnitude > 1e-4 and CFrame.lookAt(Vector3.new(), -dir) or CFrame.new()
		return offset, sRot, dir
	end,
	[Enum.ParticleEmitterShape.Sphere] = function(p, emitter)
		local outerRadius = p.Size.X / 2
		local innerRadius = outerRadius * emitter.ShapePartial
		local randomRadius = (math.random() * (outerRadius^3 - innerRadius^3) + innerRadius^3)^(1/3)
		local theta = math.random() * 2 * math.pi
		local phi = math.acos((math.random() * 2) - 1)
		local direction = Vector3.new(
			math.sin(phi) * math.cos(theta),
			math.sin(phi) * math.sin(theta),
			math.cos(phi)
		)
		return direction * randomRadius, CFrame.lookAt(Vector3.new(), -direction), direction
	end,
	[Enum.ParticleEmitterShape.Cylinder] = function(p, emitter)
		local radius = p.Size.X / 2
		local height = p.Size.Y
		-- Area-uniform annulus radius: F^-1(u) = sqrt(u*(1-h^2) + h^2).
		local h = math.clamp(emitter.ShapePartial, 0, 1)
		local randomRadius = math.sqrt(math.random() * (1 - h * h) + h * h)
		local angle = math.random() * 2 * math.pi
		local x = randomRadius * radius * math.cos(angle)
		local y = (math.random() * 2 - 1) * (height / 2)
		local z = randomRadius * radius * math.sin(angle)
		local localOffset = Vector3.new(x, y, z)
		local direction
		if math.abs(y) > (height / 2) - 0.01 then
			direction = Vector3.new(0, math.sign(y), 0)
		else
			local lateral = Vector3.new(x, 0, z)
			if lateral.Magnitude < 0.0001 then
				direction = Vector3.new(0, 1, 0)
			else
				direction = lateral.Unit
			end
		end
		return localOffset, CFrame.lookAt(Vector3.new(), -direction), direction
	end,
	[Enum.ParticleEmitterShape.Disc] = function(p, emitter)
		local radius = p.Size.X / 2
		-- Area-uniform annulus; matches Cylinder.
		local h = math.clamp(emitter.ShapePartial, 0, 1)
		local randomRadiusRatio = math.sqrt(math.random() * (1 - h * h) + h * h)
		local angle = math.random() * 2 * math.pi
		local x = randomRadiusRatio * radius * math.cos(angle)
		local z = randomRadiusRatio * radius * math.sin(angle)
		local localOffset = Vector3.new(x, 0, z)
		if localOffset.Magnitude < 0.0001 then
			return localOffset, CFrame.new(), Vector3.yAxis
		end
		local direction = localOffset.Unit
		return localOffset, CFrame.lookAt(Vector3.new(), -direction), direction
	end,
}

--[[
	把 PosX/Y/Z Range 偏移叠到 simCF。
	simFrameCF：调用方 simCF 所在坐标系的世界 CFrame。nil = 世界空间 sim（Part/Model 兄弟）。
	Attachment Emit：上溯 BasePart 的 CFrame；Attachment Animate：源 Attachment 的 WorldCFrame。
	有 AxisLinks 时相关 Pos 跟随轴保持相关；emitCtx 驱动 Pos*Even。嵌套 Model scaleFactor 放大铺开。

	@param simCF CFrame - 当前仿真 CFrame（已在调用方坐标系）
	@param data table - GetData 结果；字段 PosX/Y/Z / PosMode / AxisLinks
	@param link Instance? - 可选 link，RigidLocal 用其世界框旋转偏移
	@param item Instance - 源发射器（无 link 时取自身世界框）
	@param RangeMod table - Range 模块，须有 RandomValueFromRange
	@param AxisLinksMod table? - AxisLinks 模块；与 data.AxisLinks 同时存在才走相关采样
	@param emitCtx table? - 可选 Even 上下文（EmitIndex / EmitCount / EvenOffset*）
	@param simFrameCF CFrame? - sim 坐标系世界框；nil 表示 sim 已是世界空间
	@param scaleFactor number? - 嵌套 Model 缩放；nil 或 1 不放大
	@return CFrame - 叠偏移后的 simCF
]]
function PartConstants.applyPositionOffset(simCF, data, link, item, RangeMod, AxisLinksMod, emitCtx, simFrameCF, scaleFactor)
	-- AxisLinks-aware sampling so linked Pos followers stay correlated; emitCtx drives
	-- PosXEven/PosYEven/PosZEven even spread. Independent sampling is the fallback.
	local pxS, pyS, pzS
	if AxisLinksMod and data.AxisLinks then
		local s = AxisLinksMod.sampleRangeAxes(data, data.AxisLinks, {"PosX","PosY","PosZ"}, RangeMod, emitCtx)
		pxS, pyS, pzS = s.PosX, s.PosY, s.PosZ
	else
		pxS = RangeMod.RandomValueFromRange(data.PosX or NumberRange.new(0))
		pyS = RangeMod.RandomValueFromRange(data.PosY or NumberRange.new(0))
		pzS = RangeMod.RandomValueFromRange(data.PosZ or NumberRange.new(0))
	end
	local px, py, pz = pxS, pyS, pzS
	-- Nested-Model scale: a 2x model spawns its particles' Pos spread 2x wider.
	if scaleFactor and scaleFactor ~= 1 then
		px, py, pz = px * scaleFactor, py * scaleFactor, pz * scaleFactor
	end
	if px == 0 and py == 0 and pz == 0 then return simCF end
	local posMode = data.PosMode or "Local"

	if posMode == "Local" then
		return simCF * CFrame.new(px, py, pz)
	end

	local offset = Vector3.new(px, py, pz)
	local worldOffset
	if posMode == "Global" then
		worldOffset = offset
	else -- RigidLocal: rotate by source's WORLD frame; composes through full nest chain.
		local rotCF
		if link then
			rotCF = PartConstants.resolveLinkCFrame(link)
		elseif item:IsA("Attachment") then
			rotCF = item.WorldCFrame
		elseif item:IsA("Model") then
			rotCF = item:GetPivot()
		else
			rotCF = item.CFrame
		end
		worldOffset = rotCF:VectorToWorldSpace(offset)
	end

	-- Convert world offset → caller's sim frame. nil = sim is world-space.
	local applyOffset = simFrameCF and simFrameCF:VectorToObjectSpace(worldOffset) or worldOffset
	return CFrame.new(simCF.Position + applyOffset) * simCF.Rotation
end

--[[
	把 PosOffset 图采样（rawOff）按 DisplacementMode 收成世界位移。
	六条发射路径（Part/Attachment/Model × normal/animate）与 Update 的 _posOffsetFrameDelta 共用。
	  "Global"     → 不旋转（世界轴）
	  "RigidLocal" → 用 emitterRot（出生时发射器框，RotXYZ 前）
	  "Local"（或未知）→ 用 spawnRot（RotXYZ 后的粒子框）
	可选 mirrorX/Y/Z 在旋转后做正交变换（OnHit Bounce 绕法线反射）。
	多次 bounce 累成一组 3-vector 基（奇数次 det 可为 -1，对位移合法）。nil 镜轴跳过矩阵。

	@param rawOff Vector3 - 图采样出的局部偏移
	@param mode string? - "Global" / "RigidLocal" / "Local"；未知按 Local
	@param spawnRot CFrame - 出生后粒子旋转（世界）
	@param emitterRot CFrame - 发射器出生框（世界）
	@param mirrorX Vector3? - 反射基 X；与 Y/Z 同时有才应用
	@param mirrorY Vector3? - 反射基 Y
	@param mirrorZ Vector3? - 反射基 Z
	@return Vector3 - 世界空间位移
]]
function PartConstants.resolveDisplacement(rawOff, mode, spawnRot, emitterRot, mirrorX, mirrorY, mirrorZ)
	local frameOff
	if mode == "Global" then
		frameOff = rawOff
	elseif mode == "RigidLocal" then
		frameOff = emitterRot:VectorToWorldSpace(rawOff)
	else
		frameOff = spawnRot:VectorToWorldSpace(rawOff)
	end
	if mirrorX then
		return mirrorX * frameOff.X + mirrorY * frameOff.Y + mirrorZ * frameOff.Z
	end
	return frameOff
end

-- Skip Coulomb cancellation when |a · n| below this  -  body parallel to surface
-- (vertical-wall-grazing case) shouldn't have its full gravity stripped.
local FREEFALL_THRESHOLD = 10

--[[
	落地 settle 时的库仑接触约束：去掉法向分量（表面反力），并在切向速度上施加
	不超过 μ·|aN| 的摩擦力。得到斜面标准动力学：g·sinθ − μ·g·cosθ。
	|a · n| 低于 FREEFALL_THRESHOLD 时跳过（贴竖墙擦过不应剥光重力）。

	@param accel Vector3 - 本帧重力/加速度
	@param pData table - 粒子运行时；字段 _settleEngaged / _lastHitNormal / _accelVel / Events.OnHit.Friction
	@param dt number? - 本帧 delta；nil 视为 1/60，用于静摩擦锁步钳制
	@return Vector3 - 约束后的加速度；未 engage 或无法线时原样返回
]]
function PartConstants.applyContactAccel(accel, pData, dt)
	if not (pData._settleEngaged and pData._lastHitNormal) then return accel end
	local n = pData._lastHitNormal
	if n.Magnitude < 1e-4 then return accel end
	local aN_dot = accel:Dot(n)
	-- Surface only pushes (Newton's 3rd is one-directional). Gravity pointing
	-- AWAY from surface means no contact, no constraint.
	if aN_dot >= 0 then return accel end
	-- Vertical-wall escape: body parallel to surface normal has near-zero
	-- normal component. Skip constraint so gravity drags it along the wall.
	if math.abs(aN_dot) < FREEFALL_THRESHOLD then return accel end
	local aN = aN_dot * n
	local aT = accel - aN
	local mu = (pData.Events and pData.Events.OnHit and pData.Events.OnHit.Friction) or 0.2
	local vT = Vector3.zero
	if pData._accelVel then
		local av = pData._accelVel
		vT = av - av:Dot(n) * n
	end
	local vT_mag = vT.Magnitude
	local maxFrictionAccel = mu * math.abs(aN_dot)
	if vT_mag > 1e-4 then
		-- Kinetic regime: friction opposes tangent velocity, capped at Coulomb cone.
		-- Static-lock clamp prevents friction from reversing tangent vel in one step.
		local frictionAccel = (-vT.Unit) * maxFrictionAccel
		if maxFrictionAccel * (dt or 1/60) > vT_mag then
			frictionAccel = -vT / (dt or 1/60)
		end
		return aT + frictionAccel
	end
	-- Static regime: |aT| ≤ μ·|aN| means friction holds the body still
	-- (tan(θ) ≤ μ on a slope). |aT| > μ·|aN| means slope exceeds friction cone;
	-- body starts sliding at the residual tangent accel.
	local aT_mag = aT.Magnitude
	if aT_mag <= maxFrictionAccel then return Vector3.zero end
	return aT - aT.Unit * maxFrictionAccel
end

return PartConstants
