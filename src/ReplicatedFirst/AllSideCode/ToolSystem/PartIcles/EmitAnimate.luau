--[[
	Module: EmitAnimate
	Description: PartIcles Mixin：Part / Attachment / Beam 的 Animate 发射（直接驱动 RenderTemplate，不克隆）
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-09-01

	功能：
	- EmitPartAnimate / EmitAttachmentAnimate / EmitBeamAnimate：就地动画源 RT
	- Lifetime 到期后由 Engine Heartbeat 复位；AnimateLoop=true 时重放
	- Screen / ImageLabel 动画在 ScreenEmit / ImageEmit，不在本文件

	由 PartIcles/init 作为 mixin 注入 Particle 实例，业务侧勿单独 require。
]]

local GraphMod = require(script.Parent.Graph)
local RangeMod = require(script.Parent.Range)
local ParticlesMod = require(script.Parent.Particles)
local Constants = require(script.Parent.PartConstants)
local AxisLinksMod = require(script.Parent.AxisLinks)
local EventsMod = require(script.Parent.Events)
local StaticPass = require(script.Parent.StaticPass)
local DirectionVectors = Constants.DirectionVectors
local shapeFunctions = Constants.shapeFunctions

return function(Particle)

--[[
	Animate 模式发射 Part：逻辑对齐 EmitPart，但 visualPart 直接用 LIVE RenderTemplate（不克隆）。

	@param part BasePart - 源 Part（须有 GetData / RenderTemplate）
	@param link Instance? - 链接目标；nil 时用 data.Link
	@param emitCtx table? - 可选发射上下文，字段同 EmitPart（ChainCtx / EmitIndex / EventOriginCF 等）
]]
function Particle:EmitPartAnimate(part, link, emitCtx)
	if not part or not part.Parent then return end
	local data = self:GetData(part)
	if not data or not data.RenderTemplate then return end
	link = link or data.Link

	local Time = RangeMod.RandomValueFromRange(data.Lifetime)
	if Time <= 0 then Time = 0.001 end

	local visualPart = data.RenderTemplate -- LIVE source RT, not a clone
	local initialAnchorCF = visualPart.CFrame

	local unrotatedCF
	if link then
		local lCF = Constants.resolveLinkCFrame(link)
		local lPos = lCF.Position
		if data.LinkMode == "Follow" then unrotatedCF = CFrame.new(lPos) * part.CFrame.Rotation
		else unrotatedCF = CFrame.new(lPos) * lCF.Rotation * part.CFrame.Rotation end
	else unrotatedCF = part.CFrame end
	local dirInfo = DirectionVectors[data.EmissionDirection] or DirectionVectors[Enum.NormalId.Top]
	local rawWorldDirection = unrotatedCF[dirInfo.vector] * dirInfo.multiplier

	-- Shape branch (see Emit.luau for full rationale). ShapePart override mirrors Emit.luau.
	local localOffset = Vector3.new()
	local shapeDir = nil
	local initialCF = unrotatedCF
	if data.UseShape then
		local shapeFunc = shapeFunctions[data.ParticleData.Shape]
		if shapeFunc then
			local shapeSrc = data.ShapePart or part
			local shapeCF = data.ShapePart and data.ShapePart.CFrame or unrotatedCF
			local sOffset, sRotation, sDirVec = shapeFunc(shapeSrc, data.ParticleData)
			localOffset = sOffset
			local sio = data.ParticleData.ShapeInOut
			if sio == Enum.ParticleEmitterShapeInOut.Inward then
				sDirVec = -sDirVec
			elseif sio == Enum.ParticleEmitterShapeInOut.InAndOut then
				if math.random() < 0.5 then sDirVec = -sDirVec end
			end
			shapeDir = (shapeCF - shapeCF.Position):VectorToWorldSpace(sDirVec)
			if data.ParticleData.LookAtInitially then
				local rx, ry, rz = initialCF:ToEulerAnglesXYZ()
				initialCF = CFrame.new((shapeCF * CFrame.new(localOffset)).Position)
					* sRotation * CFrame.Angles(rx, ry, rz)
			else
				initialCF = CFrame.new((shapeCF * CFrame.new(localOffset)).Position) * initialCF.Rotation
			end
		else
			initialCF = CFrame.new((initialCF * CFrame.new(localOffset)).Position) * initialCF.Rotation
		end
	else
		initialCF = CFrame.new((initialCF * CFrame.new(localOffset)).Position) * initialCF.Rotation
	end

	local dirMode = data.DirMode or "RigidLocal"
	local rotS = AxisLinksMod.sampleRangeAxes(data, data.AxisLinks, {"RotX","RotY","RotZ"}, RangeMod, emitCtx)
	local RX, RY, RZ = rotS.RotX, rotS.RotY, rotS.RotZ
	local rotXYZ = Constants.composeRotation(data.RotOrder or "Global", RX, RY, RZ)
	initialCF = initialCF * rotXYZ

	initialCF = Constants.applyPositionOffset(initialCF, data, link, part, RangeMod, AxisLinksMod, emitCtx)

	if dirMode == "Global" then
		initialCF = CFrame.new(initialCF.Position) * rotXYZ
	end

	local baseDirection
	if shapeDir then
		baseDirection = shapeDir
	elseif dirMode == "Local" then
		baseDirection = initialCF[dirInfo.vector] * dirInfo.multiplier
	elseif dirMode == "Global" then
		baseDirection = CFrame.new()[dirInfo.vector] * dirInfo.multiplier
	else
		baseDirection = rawWorldDirection
	end

	local randomX, randomY = 0, 0
	if data.ParticleData.SpreadAngle.X > 0 or data.ParticleData.SpreadAngle.Y > 0 then
		randomX = (math.random() * 2 - 1) * data.ParticleData.SpreadAngle.X
		randomY = (math.random() * 2 - 1) * data.ParticleData.SpreadAngle.Y
	end
	local spreadRotation = CFrame.Angles(math.rad(randomX), math.rad(randomY), 0)
	local cf = CFrame.lookAt(Vector3.new(), baseDirection)
	cf = cf * spreadRotation
	baseDirection = cf.LookVector

	local seeds = {
		SizeX = GraphMod.GenerateSeed(data.SizeX), SizeY = GraphMod.GenerateSeed(data.SizeY), SizeZ = GraphMod.GenerateSeed(data.SizeZ),
		RotSpeedX = GraphMod.GenerateSeed(data.RotSpeedX), RotSpeedY = GraphMod.GenerateSeed(data.RotSpeedY), RotSpeedZ = GraphMod.GenerateSeed(data.RotSpeedZ),
		PosOffsetX = GraphMod.GenerateSeed(data.PosOffsetX), PosOffsetY = GraphMod.GenerateSeed(data.PosOffsetY), PosOffsetZ = GraphMod.GenerateSeed(data.PosOffsetZ),
		Speed = GraphMod.GenerateSeed(data.Speed), Brightness = GraphMod.GenerateSeed(data.Brightness),
		Transparency = GraphMod.GenerateSeed(data.Transparency),
		AccelStrength = GraphMod.GenerateSeed(data.AccelStrength),
		Timescale = GraphMod.GenerateSeed(data.Timescale),
	}
	AxisLinksMod.applyGraphAxisAliases(data, seeds, data.AxisLinks)

	local invertMotion = data.InvertMotion
	local simLocalCFrames = nil
	local simEffectiveTKF = nil
	if invertMotion then
		simLocalCFrames, simEffectiveTKF = self:PreSimulateForward(data, seeds, initialCF, baseDirection, spreadRotation, link, Time, nil, initialCF.Rotation * rotXYZ:Inverse())
	end

	local parentCF_now
	if link then
		local lC = Constants.resolveLinkCFrame(link)
		parentCF_now = (data.LinkMode == "Follow" or data.LinkMode == "Pivot") and CFrame.new(lC.Position) or lC
	else parentCF_now = CFrame.new() end
	local localCF
	if invertMotion and simLocalCFrames then
		local endLocalCF = simLocalCFrames[simEffectiveTKF or data.TotalKeyFrames] or simLocalCFrames[0]
		localCF = endLocalCF
	else
		localCF = link and parentCF_now:ToObjectSpace(initialCF) or initialCF
	end
	visualPart.CFrame = parentCF_now * localCF

	local pData = {
		Type = "Part",
		VisualPart = visualPart,
		Link = link,
		LinkMode = data.LinkMode,
		_rigidLocalParentCF = (data.LinkMode == "RigidLocal" and link) and parentCF_now or nil,
		Events = data.Events,
		SpecialMesh = visualPart:FindFirstChildOfClass('SpecialMesh'),
		Decal = visualPart:FindFirstChildOfClass('Decal'),
		-- SA has no per-instance Transparency/Color3; Color graph writes to SA.Color, MeshPart stays raw.
		SurfaceAppearance = visualPart:FindFirstChildOfClass('SurfaceAppearance'),
		-- Snapshot SA.Color + MeshPart.Color so finishAnimate restores authored tint.
		_initialSAColor = (function()
			local sa = visualPart:FindFirstChildOfClass('SurfaceAppearance')
			return sa and sa.Color or nil
		end)(),
		_initialPartColor = visualPart:IsA("BasePart") and visualPart.Color or nil,

		StartTime = os.clock(),
		TotalKeyFrames = invertMotion and simEffectiveTKF or math.max(1, data.TotalKeyFrames),
		CurrentStep = 0, AccumulatedDT = 0,
		LifeTime = Time, PartLife = data.PartLife or 0,
		CurrentPosition = visualPart.Position,
		LocalCF = localCF,

		BaseDirection = baseDirection,
		-- AnimateLoop replay restores from this so Bounce reflections don't leak into next cycle.
		_initialBaseDirection = baseDirection,
		EmissionDirection = data.EmissionDirection,
		SpreadRotation = spreadRotation,
		Acceleration = data.ParticleData.Acceleration,
		Drag = data.ParticleData.Drag,
		VelocityVectored = data.VelocityVectored,

		InvertMotion = invertMotion,
		SimLocalCFrames = simLocalCFrames,

		RotMode = data.RotMode or "OverLife",
		RotOrder = data.RotOrder or "Global",
		AccRotX = 0, AccRotY = 0, AccRotZ = 0,

		Orientation = data.Orientation,
		ZOffset = data.ZOffset,
		_localWorldCF = localCF,

		-- PosOffset trajectory state (see Emit.luau Part path for semantics).
		SpawnRotation = localCF.Rotation,
		SpawnEmitterRotation = localCF.Rotation * rotXYZ:Inverse(),
		DisplacementMode = data.DisplacementMode,
		_sleepRadius = (visualPart and visualPart:IsA("BasePart") and visualPart.Size.Magnitude * 0.5) or 1.0,
		_prevWorldOff = Vector3.zero,
		HasPosOffsetGraphs = data.PosOffsetX ~= nil or data.PosOffsetY ~= nil or data.PosOffsetZ ~= nil,

		NeedsFullIteration = data.VelocityVectored,
		NeedsRotAccum = (data.RotMode == "Speed") and not data.VelocityVectored,
		HasDrag = data.ParticleData.Drag ~= 0,
		HasAccel = data.ParticleData.Acceleration.Magnitude > 0,
		HasDecal = visualPart:FindFirstChildOfClass('Decal') ~= nil,
		-- InvertMotion + target-accel mutually exclusive (cached SimLocalCFrames can't track).
		HasTargetAccel = data.AccelerationTowardsInstance == true and data.AccelTarget ~= nil and data.AccelStrength ~= nil and not data.InvertMotion,
		AccelTarget = data.AccelTarget,
		TargetVel = Vector3.zero,

		Graphs = {
			SizeX = data.SizeX, SizeY = data.SizeY, SizeZ = data.SizeZ,
			RotSpeedX = data.RotSpeedX, RotSpeedY = data.RotSpeedY, RotSpeedZ = data.RotSpeedZ,
			PosOffsetX = data.PosOffsetX, PosOffsetY = data.PosOffsetY, PosOffsetZ = data.PosOffsetZ,
			Speed = data.Speed, Brightness = data.Brightness,
			Transparency = data.Transparency, Color = data.Color,
			AccelStrength = data.AccelStrength,
			Timescale = data.Timescale,
		},
		Seeds = seeds,
		_effectiveElapsed = GraphMod.InitialEffectiveElapsed(data.Timescale, seeds.Timescale, Time),

		IsAnimate = true, AnimateItem = part,
		InitialAnchorCF = initialAnchorCF, InitialLocalCF = localCF,
	}

	if pData.HasPosOffsetGraphs then
		local oX = pData.Graphs.PosOffsetX and GraphMod.QueryPointsWithTime(0, pData.Graphs.PosOffsetX, pData.Seeds.PosOffsetX) or 0
		local oY = pData.Graphs.PosOffsetY and GraphMod.QueryPointsWithTime(0, pData.Graphs.PosOffsetY, pData.Seeds.PosOffsetY) or 0
		local oZ = pData.Graphs.PosOffsetZ and GraphMod.QueryPointsWithTime(0, pData.Graphs.PosOffsetZ, pData.Seeds.PosOffsetZ) or 0
		local worldOff = Constants.resolveDisplacement(Vector3.new(oX, oY, oZ),
			data.DisplacementMode or "Global", pData.SpawnRotation, pData.SpawnEmitterRotation)
		pData._prevWorldOff = worldOff
		if oX ~= 0 or oY ~= 0 or oZ ~= 0 then
			pData.LocalCF = pData.LocalCF + worldOff
			pData.VisualPart.CFrame = pData.VisualPart.CFrame + worldOff
		end
	end

	-- 1-frame pop prevention.
	local startSize = Vector3.new(
		GraphMod.QueryPointsWithTime(0, pData.Graphs.SizeX, pData.Seeds.SizeX),
		GraphMod.QueryPointsWithTime(0, pData.Graphs.SizeY, pData.Seeds.SizeY),
		GraphMod.QueryPointsWithTime(0, pData.Graphs.SizeZ, pData.Seeds.SizeZ)
	)
	local startTrans = GraphMod.QueryPointsWithTime(0, pData.Graphs.Transparency, pData.Seeds.Transparency)
	local startColor = GraphMod.QueryColorPointWithTime(0, pData.Graphs.Color)
	local startBright = GraphMod.QueryPointsWithTime(0, pData.Graphs.Brightness, pData.Seeds.Brightness)

	if pData.SpecialMesh then pData.SpecialMesh.Scale = startSize
	else pData.VisualPart.Size = startSize end

	if pData.SurfaceAppearance then
		-- Color graph tints SA.Color raw; Brightness graph drives SA.EmissiveTint only.
		pData.VisualPart.Transparency = startTrans
		pData.VisualPart.Color = Color3.fromRGB(startColor.R * 255, startColor.G * 255, startColor.B * 255)
		pData.SurfaceAppearance.Color = Color3.fromRGB(startColor.R * 255, startColor.G * 255, startColor.B * 255)
		pcall(function() pData.SurfaceAppearance.EmissiveTint = Color3.new(startColor.R * startBright, startColor.G * startBright, startColor.B * startBright) end)
	elseif pData.Decal then
		pData.Decal.Transparency = startTrans
		pData.Decal.Color3 = Color3.fromRGB(startColor.R * 255 * startBright, startColor.G * 255 * startBright, startColor.B * 255 * startBright)
	else
		-- Plain MeshPart: Brightness multiplies SA/Decal only, not the mesh Color.
		pData.VisualPart.Transparency = startTrans
		pData.VisualPart.Color = Color3.fromRGB(startColor.R * 255, startColor.G * 255, startColor.B * 255)
	end

	-- LIVE source RT; EnableEmitSingle drives each child's per-cycle lifecycle.
	local alivePartAn = self:_makeAliveCheck()
	for _, child in visualPart:GetChildren() do
		if child:IsA("Attachment") then ParticlesMod.EnableEmitChildrenAndRepeatForAttachments(child, alivePartAn) end
		ParticlesMod.EnableEmitSingle(child, alivePartAn)
	end

	if self._parentScaleMap and self._parentScaleMap[part] then
		pData.ParentScale = self._parentScaleMap[part]
	end

	pData._sourceItem = part
	Particle._seedTsOverride(pData, part)
	StaticPass.apply(pData)
	self._activeAnimates[part] = pData
	self:_applyEmitVisualPasses(pData)
	self:_registerEmit(pData, emitCtx)

	for _, desc in visualPart:GetDescendants() do
		if desc:GetAttribute("Transformed") then
			self:EnableEmit(desc, desc.Parent, EventsMod.descendCtx(emitCtx))
		end
	end
end

--[[
	Animate 模式发射 Attachment：父级局部模拟对齐 EmitAttachment；视觉是 RT 子节点（不克隆）。

	@param attachment Attachment - 源 Attachment（须有 GetData / RenderTemplate）
	@param link Instance? - 链接目标；nil 时用 data.Link
	@param emitCtx table? - 可选发射上下文，字段同 EmitPart
]]
function Particle:EmitAttachmentAnimate(attachment, link, emitCtx)
	if not attachment or not attachment.Parent then return end
	local data = self:GetData(attachment)
	if not data or not data.RenderTemplate then return end
	link = link or data.Link

	local Time = RangeMod.RandomValueFromRange(data.Lifetime)
	if Time <= 0 then Time = 0.001 end

	local visualAttachment = data.RenderTemplate -- NOT a clone
	local initialAnchorCF = visualAttachment.CFrame

	-- Visual IS the RT child of the source Attachment; sim runs in source-local space so
	-- the visual's world pose composes via source.WorldCFrame * localCF. Starting at
	-- identity keeps Transform.luau:96's invariant (RT.CFrame = identity) consistent
	-- regardless of how the source itself is parented (BasePart, Attachment, deeper).
	local localCF = CFrame.new()
	local dirInfo = DirectionVectors[data.EmissionDirection] or DirectionVectors[Enum.NormalId.Top]

	local dirMode = data.DirMode or "RigidLocal"
	local rotS = AxisLinksMod.sampleRangeAxes(data, data.AxisLinks, {"RotX","RotY","RotZ"}, RangeMod, emitCtx)
	local RX, RY, RZ = rotS.RotX, rotS.RotY, rotS.RotZ
	local rotXYZ = Constants.composeRotation(data.RotOrder or "Global", RX, RY, RZ)
	local rotatedLocalCF = localCF * rotXYZ

	local baseDirection
	if dirMode == "Local" then
		baseDirection = rotatedLocalCF[dirInfo.vector] * dirInfo.multiplier
	elseif dirMode == "Global" then
		-- Convert world axis to source-local frame via source.WorldCFrame so the math
		-- works whether source is parented to BasePart, Attachment, or nested deeper.
		local worldAxis = CFrame.new()[dirInfo.vector] * dirInfo.multiplier
		baseDirection = attachment.WorldCFrame:VectorToObjectSpace(worldAxis)
	else
		baseDirection = localCF[dirInfo.vector] * dirInfo.multiplier
	end

	localCF = rotatedLocalCF

	-- simFrameCF = source.WorldCFrame; sim runs in source-local frame (visual IS RT
	-- child of source). WorldCFrame composes arbitrary nest depth automatically.
	localCF = Constants.applyPositionOffset(localCF, data, link, attachment, RangeMod, AxisLinksMod, emitCtx, attachment.WorldCFrame)

	-- Global DirMode: world-align visual; cancel source.WorldRotation so the engine-
	-- composed (source.WorldCFrame * RT.CFrame) lands at rotXYZ in world space.
	if dirMode == "Global" then
		localCF = CFrame.new(localCF.Position) * attachment.WorldCFrame.Rotation:Inverse() * rotXYZ
	end

	local randomX, randomY = 0, 0
	if data.ParticleData.SpreadAngle.X > 0 or data.ParticleData.SpreadAngle.Y > 0 then
		randomX = (math.random() * 2 - 1) * data.ParticleData.SpreadAngle.X
		randomY = (math.random() * 2 - 1) * data.ParticleData.SpreadAngle.Y
	end
	local spreadRotation = CFrame.Angles(math.rad(randomX), math.rad(randomY), 0)
	local cf = CFrame.lookAt(Vector3.new(), baseDirection)
	cf = cf * spreadRotation
	baseDirection = cf.LookVector

	local seeds = {
		Speed = GraphMod.GenerateSeed(data.Speed),
		RotSpeedX = GraphMod.GenerateSeed(data.RotSpeedX),
		RotSpeedY = GraphMod.GenerateSeed(data.RotSpeedY),
		RotSpeedZ = GraphMod.GenerateSeed(data.RotSpeedZ),
		PosOffsetX = GraphMod.GenerateSeed(data.PosOffsetX),
		PosOffsetY = GraphMod.GenerateSeed(data.PosOffsetY),
		PosOffsetZ = GraphMod.GenerateSeed(data.PosOffsetZ),
		Timescale = GraphMod.GenerateSeed(data.Timescale),
	}
	AxisLinksMod.applyGraphAxisAliases(data, seeds, data.AxisLinks)

	local invertMotion = data.InvertMotion
	local simLocalCFrames = nil
	local simEffectiveTKF = nil
	if invertMotion then
		simLocalCFrames, simEffectiveTKF = self:PreSimulateAttachmentForward(data, seeds, localCF, baseDirection, spreadRotation, Time, nil, localCF.Rotation * rotXYZ:Inverse())
	end

	if invertMotion and simLocalCFrames then
		localCF = simLocalCFrames[simEffectiveTKF or data.TotalKeyFrames] or simLocalCFrames[0]
	end

	visualAttachment.CFrame = localCF

	local pData = {
		Type = "Attachment",
		VisualPart = visualAttachment,
		Link = link,
		LinkMode = data.LinkMode,
		_rigidLocalParentCF = (data.LinkMode == "RigidLocal" and link) and Constants.resolveLinkCFrame(link) or nil,
		Events = data.Events,
		StartTime = os.clock(),
		TotalKeyFrames = invertMotion and simEffectiveTKF or math.max(1, data.TotalKeyFrames),
		CurrentStep = 0, AccumulatedDT = 0,
		LifeTime = Time, PartLife = data.PartLife or 0,
		LocalCF = localCF,
		_localWorldCF = localCF,
		BaseDirection = baseDirection,
		_initialBaseDirection = baseDirection,
		EmissionDirection = data.EmissionDirection,
		SpreadRotation = spreadRotation,
		Acceleration = data.ParticleData.Acceleration,
		Drag = data.ParticleData.Drag,
		VelocityVectored = data.VelocityVectored,
		InvertMotion = invertMotion,
		SimLocalCFrames = simLocalCFrames,
		RotMode = data.RotMode or "OverLife",
		RotOrder = data.RotOrder or "Global",
		AccRotX = 0, AccRotY = 0, AccRotZ = 0,
		Orientation = data.Orientation,
		ZOffset = data.ZOffset,
		NeedsFullIteration = data.VelocityVectored,
		NeedsRotAccum = (data.RotMode == "Speed") and not data.VelocityVectored,
		HasDrag = data.ParticleData.Drag ~= 0,
		HasAccel = data.ParticleData.Acceleration.Magnitude > 0,
		-- PosOffset trajectory state (see Emit.luau Part path for semantics).
		SpawnRotation = localCF.Rotation,
		SpawnEmitterRotation = localCF.Rotation * rotXYZ:Inverse(),
		DisplacementMode = data.DisplacementMode,
		_sleepRadius = (visualPart and visualPart:IsA("BasePart") and visualPart.Size.Magnitude * 0.5) or 1.0,
		_prevWorldOff = Vector3.zero,
		HasPosOffsetGraphs = data.PosOffsetX ~= nil or data.PosOffsetY ~= nil or data.PosOffsetZ ~= nil,
		Graphs = {
			Speed = data.Speed,
			RotSpeedX = data.RotSpeedX, RotSpeedY = data.RotSpeedY, RotSpeedZ = data.RotSpeedZ,
			PosOffsetX = data.PosOffsetX, PosOffsetY = data.PosOffsetY, PosOffsetZ = data.PosOffsetZ,
			Timescale = data.Timescale,
		},
		Seeds = seeds,
		_effectiveElapsed = GraphMod.InitialEffectiveElapsed(data.Timescale, seeds.Timescale, Time),
		IsAnimate = true, AnimateItem = attachment,
		InitialAnchorCF = initialAnchorCF, InitialLocalCF = localCF,
	}

	if pData.HasPosOffsetGraphs then
		local oX = pData.Graphs.PosOffsetX and GraphMod.QueryPointsWithTime(0, pData.Graphs.PosOffsetX, pData.Seeds.PosOffsetX) or 0
		local oY = pData.Graphs.PosOffsetY and GraphMod.QueryPointsWithTime(0, pData.Graphs.PosOffsetY, pData.Seeds.PosOffsetY) or 0
		local oZ = pData.Graphs.PosOffsetZ and GraphMod.QueryPointsWithTime(0, pData.Graphs.PosOffsetZ, pData.Seeds.PosOffsetZ) or 0
		local worldOff = Constants.resolveDisplacement(Vector3.new(oX, oY, oZ),
			data.DisplacementMode or "Global", pData.SpawnRotation, pData.SpawnEmitterRotation)
		pData._prevWorldOff = worldOff
		if oX ~= 0 or oY ~= 0 or oZ ~= 0 then
			pData.LocalCF = pData.LocalCF + worldOff
			pData.VisualPart.CFrame = pData.VisualPart.CFrame + worldOff
		end
	end

	pData._sourceItem = attachment
	Particle._seedTsOverride(pData, attachment)
	StaticPass.apply(pData)
	self._activeAnimates[attachment] = pData
	self:_applyEmitVisualPasses(pData)
	self:_registerEmit(pData, emitCtx)

	-- LIVE source RT; EnableEmitSingle drives each child's per-cycle lifecycle.
	local aliveAttAn = self:_makeAliveCheck()
	for _, child in visualAttachment:GetChildren() do
		if child:IsA("Attachment") then ParticlesMod.EnableEmitChildrenAndRepeatForAttachments(child, aliveAttAn) end
		ParticlesMod.EnableEmitSingle(child, aliveAttAn)
	end

	for _, desc in visualAttachment:GetDescendants() do
		if desc:GetAttribute("Transformed") then
			self:EnableEmit(desc, desc.Parent, EventsMod.descendCtx(emitCtx))
		end
	end
end

--[[
	Animate 模式发射 Beam：静态/动画属性拆分对齐 EmitBeam；视觉是 LIVE RenderTemplate。

	@param beam Beam - 源 Beam（须有 GetData / RenderTemplate）
	@param link Instance? - 链接目标（透传到 pData）
	@param emitCtx table? - 可选发射上下文，字段同 EmitPart
]]
function Particle:EmitBeamAnimate(beam, link, emitCtx)
	if not beam or not beam.Parent then return end
	local data = self:GetData(beam)
	if not data or not data.RenderTemplate then return end

	local visualBeam = data.RenderTemplate -- LIVE source, not a clone
	-- Snapshot mutated properties so finishAnimate restores authored visual.
	local beamSnapshot = {
		Brightness = visualBeam.Brightness,
		CurveSize0 = visualBeam.CurveSize0,
		CurveSize1 = visualBeam.CurveSize1,
		Width0 = visualBeam.Width0,
		Width1 = visualBeam.Width1,
		LightEmission = visualBeam.LightEmission,
		LightInfluence = visualBeam.LightInfluence,
		Segments = visualBeam.Segments,
		TextureLength = visualBeam.TextureLength,
		TextureSpeed = visualBeam.TextureSpeed,
		Transparency = visualBeam.Transparency,
		Color = visualBeam.Color,
		FaceCamera = visualBeam.FaceCamera,
		Enabled = visualBeam.Enabled,
	}
	if data.FaceCamera ~= nil then visualBeam.FaceCamera = data.FaceCamera end

	-- Static / animated beam property split.
	local animatedProps = {}
	for name, sequence in pairs(data.BeamProps) do
		if sequence then
			if GraphMod.IsStatic(sequence) then
				visualBeam[name] = GraphMod.GetStaticValue(sequence, visualBeam[name])
			else
				local seed = GraphMod.GenerateSeed(sequence)
				animatedProps[name] = { Sequence = sequence, Seed = seed }
				if name ~= "TextureSpeed" then
					local initVal = GraphMod.QueryPointsWithTime(0, sequence, seed)
					if name == "Segments" then initVal = math.max(20, math.round(initVal)) end
					visualBeam[name] = initVal
				end
			end
		end
	end

	-- Disable engine TextureSpeed accumulation; UpdateBeam computes offset.
	if animatedProps.TextureSpeed then
		visualBeam.TextureSpeed = 0
	end

	local transStates, colorStates = GraphMod.CollectGraphStates(data.GraphBlender)

	local transMergedTimes = {}
	for idx = 1, #transStates - 1 do
		transMergedTimes[idx] = GraphMod.PrecomputeMergedTimes(transStates[idx].Graph, transStates[idx + 1].Graph)
	end
	local colorMergedTimes = {}
	for idx = 1, #colorStates - 1 do
		colorMergedTimes[idx] = GraphMod.PrecomputeMergedColorTimes(colorStates[idx].Graph, colorStates[idx + 1].Graph)
	end

	-- Apply initial blender state (1-frame pop prevention).
	if #transStates > 0 then visualBeam.Transparency = transStates[1].Graph end
	if #colorStates > 0 then visualBeam.Color = colorStates[1].Graph end

	visualBeam.Enabled = true

	local safeLifeTime = RangeMod.RandomValueFromRange(data.Lifetime)
	if safeLifeTime <= 0 then safeLifeTime = 0.001 end
	local beamTimescaleSeed = GraphMod.GenerateSeed(data.BeamTimescale)

	local pData = {
		Type = "Beam",
		VisualPart = visualBeam,
		Link = link,
		Events = data.Events,
		StartTime = os.clock(),
		TotalKeyFrames = math.max(1, data.TotalKeyFrames),
		CurrentStep = 0,
		LifeTime = safeLifeTime,
		PartLife = data.PartLife or 0,
		AnimatedProps = animatedProps,
		TransStates = transStates, ColorStates = colorStates,
		TransMergedTimes = transMergedTimes, ColorMergedTimes = colorMergedTimes,
		BeamSnapshot = beamSnapshot,
		Graphs = { Timescale = data.BeamTimescale },
		Seeds = { Timescale = beamTimescaleSeed },
		_effectiveElapsed = GraphMod.InitialEffectiveElapsed(data.BeamTimescale, beamTimescaleSeed, safeLifeTime),
		IsAnimate = true, AnimateItem = beam,
	}

	-- Inherit parent model scale for live width scaling.
	if self._parentScaleMap and self._parentScaleMap[beam] then
		pData.ParentScale = self._parentScaleMap[beam]
		pData._baseWidth0 = visualBeam.Width0
		pData._baseWidth1 = visualBeam.Width1
		pData._baseCurveSize0 = visualBeam.CurveSize0
		pData._baseCurveSize1 = visualBeam.CurveSize1
		pData._baseTextureLength = visualBeam.TextureLength
		pData._baseSegments = visualBeam.Segments
	end

	pData._sourceItem = beam
	Particle._seedTsOverride(pData, beam)
	self._activeAnimates[beam] = pData
	self:_registerEmit(pData, emitCtx)
end

--[[
	AnimateLoop 刷新非空间字段（朝向、ZOffset、Timescale、SpreadAngle 等）。
	空间状态保留，完整重建由各类型自己做。

	@param pData table - 运行中粒子状态（Type / Graphs / Seeds / EmissionDirection 等）
	@param freshData table? - GetData 新读的配置；nil 则直接返回
]]
function Particle:_refreshAnimateNonSpatial(pData, freshData)
	if not freshData then return end
	if freshData.EmissionDirection then pData.EmissionDirection = freshData.EmissionDirection end
	if freshData.Orientation then pData.Orientation = freshData.Orientation end
	if freshData.ZOffset ~= nil then pData.ZOffset = freshData.ZOffset end
	if freshData.RotOrder then pData.RotOrder = freshData.RotOrder end
	if freshData.PartLife ~= nil then pData.PartLife = freshData.PartLife end
	-- Timescale attrName variants per type; exactly one is set.
	local tsG = freshData.Timescale or freshData.BeamTimescale or freshData.AtmTimescale or freshData.PLTimescale
	if tsG and pData.Graphs then pData.Graphs.Timescale = tsG; pData.Seeds.Timescale = GraphMod.GenerateSeed(tsG) end
	if freshData.ParticleData and freshData.ParticleData.SpreadAngle then
		local sa = freshData.ParticleData.SpreadAngle
		local rx, ry = 0, 0
		if sa.X > 0 or sa.Y > 0 then
			rx = (math.random() * 2 - 1) * sa.X
			ry = (math.random() * 2 - 1) * sa.Y
		end
		pData.SpreadRotation = CFrame.Angles(math.rad(rx), math.rad(ry), 0)
	end
end

end
