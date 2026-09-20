--[[
	Module: Emit
	Description: PartIcles Mixin：Part / Attachment / Beam 一次性发射（克隆 RT、写入 _activeEmits）
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-09-01

	功能：
	- EmitPart / EmitAttachment / EmitBeam：按类型一次性发射
	- 初始位姿与 Motion Preview 共用 PreSimulateForward / PreSimulateAttachmentForward
	- 不驱动 Heartbeat；生命周期由 Engine / Lifecycle 接管

	由 PartIcles/init 作为 mixin 注入 Particle 实例，业务侧勿单独 require。
]]

local GraphMod = require(script.Parent.Graph)
local RangeMod = require(script.Parent.Range)
local AxisLinksMod = require(script.Parent.AxisLinks)
local ParticlesMod = require(script.Parent.Particles)
local MeshFlipMod = require(script.Parent.Flipbook)
local EventsMod = require(script.Parent.Events)
local Constants = require(script.Parent.PartConstants)
local Pool = require(script.Parent.Pool)
local NestedEmit = require(script.Parent.NestedEmit)
local StaticPass = require(script.Parent.StaticPass)
local DirectionVectors = Constants.DirectionVectors
local shapeFunctions = Constants.shapeFunctions

--[[
	沿父级链向上查找最近的 BasePart，作为 Attachment 视觉锚点。
	嵌套 Attachment 必须合成祖先变换；锚定到第一个 BasePart 后，父级局部 CFrame 才与同级发射类型一致。

	@param inst Instance - 起始实例（通常为 Attachment）
	@return BasePart? - 最近的 BasePart 祖先；无则 nil
]]
local function _findBasePartAncestor(inst)
	local p = inst.Parent
	while p do
		if p:IsA("BasePart") then return p end
		p = p.Parent
	end
	return nil
end

return function(Particle)

--[[
	一次性发射 Part：计算初始 CFrame 与方向，克隆 RT，压入 _activeEmits。
	初始 CFrame 顺序：link/LinkMode → Shape 偏移 → RotXYZ → Position 偏移；DirMode=Global 时去掉旋转。
	InvertMotion 时预模拟到终点再放置。EventOriginResolver 优先于 EventOriginCF（实时 vs 快照）。

	@param part BasePart - 源 Part（须有 GetData / RenderTemplate）
	@param link Instance? - 链接目标；nil 时用 data.Link；emitCtx.IgnoreLink 时强制 nil
	@param emitCtx table? - 可选发射上下文，字段：
		ChainCtx table? - 事件链 {ChainId, Depth}
		EmitIndex number? - burst 内 1-based 序号
		EventOriginCF CFrame? - 原点快照
		EventOriginResolver (() -> CFrame?)? - 实时原点，优先于 EventOriginCF
		IgnoreLink boolean? - true 时忽略 Link
		UseFullOrigin boolean? - true（AtCFrame）用完整朝向，否则只替换位置
]]
function Particle:EmitPart(part, link, emitCtx)
	if not part or not part.Parent then return end
	local data = self:GetData(part)
	if not data or not data.RenderTemplate then return end
	if emitCtx and emitCtx.IgnoreLink then
		link = nil
	else
		link = link or data.Link
	end

	local Time = RangeMod.RandomValueFromRange(data.Lifetime)
	if Time <= 0 then Time = 0.001 end

	-- Follow drops link rotation; Weld/Pivot compose it.
	local unrotatedCF
	local originOverrideCF
	if emitCtx then
		if emitCtx.EventOriginResolver then originOverrideCF = emitCtx.EventOriginResolver() end
		if not originOverrideCF then originOverrideCF = emitCtx.EventOriginCF end
	end
	if originOverrideCF then
		if emitCtx and emitCtx.UseFullOrigin then
			unrotatedCF = originOverrideCF -- AtCFrame: full source orientation
		else
			-- AtPosition / AtSource: replace position only, keep target rotation.
			unrotatedCF = CFrame.new(originOverrideCF.Position) * part.CFrame.Rotation
		end
	elseif link then
		local lCF = Constants.resolveLinkCFrame(link)
		local lPos = lCF.Position
		if data.LinkMode == "Follow" then unrotatedCF = CFrame.new(lPos) * part.CFrame.Rotation
		else unrotatedCF = CFrame.new(lPos) * lCF.Rotation * part.CFrame.Rotation end
	else unrotatedCF = part.CFrame end
	local dirInfo = DirectionVectors[data.EmissionDirection] or DirectionVectors[Enum.NormalId.Top]
	local rawWorldDirection = unrotatedCF[dirInfo.vector] * dirInfo.multiplier

	-- Shape branch. UseShape gates; shape function returns offset / rotation / outward direction.
	-- ShapePart override: when set, sample volume + spawn position in ShapePart's frame.
	-- nil falls back to existing source-frame behavior (unrotatedCF).
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

	-- Nested-Model scale: scatter the spawn Pos spread by the parent Model's scale at THIS
	-- emit moment (Pos spread is a one-time spawn offset; per-frame motion scales separately).
	local posScale = 1
	local psInfo = self._parentScaleMap and self._parentScaleMap[part]
	if psInfo and psInfo.ScaleMotion ~= false then
		posScale = Constants.getParentScaleFactor(psInfo, os.clock(), GraphMod)
	end
	initialCF = Constants.applyPositionOffset(initialCF, data, link, part, RangeMod, AxisLinksMod, emitCtx, nil, posScale)

	-- Global DirMode: drop emitter+link rotation; keep RotXYZ.
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

	-- Axis-link alias: followers adopt primary's seed + graph; mutates data + seeds in-place.
	AxisLinksMod.applyGraphAxisAliases(data, seeds, data.AxisLinks)

	local invertMotion = data.InvertMotion
	local simLocalCFrames = nil
	local simEffectiveTKF = nil

	if invertMotion then
		simLocalCFrames, simEffectiveTKF = self:PreSimulateForward(data, seeds, initialCF, baseDirection, spreadRotation, link, Time, nil, initialCF.Rotation * rotXYZ:Inverse())
	end

	local visualPart = Pool.acquireOrCopyBare(data.RenderTemplate, "Part", data.Pool)
	visualPart.Archivable = false
	local parentCF_now
	if link then
		local lC = Constants.resolveLinkCFrame(link)
		-- Only Weld uses full link CFrame; Follow/Pivot keep motion world-space.
		parentCF_now = (data.LinkMode == "Follow" or data.LinkMode == "Pivot") and CFrame.new(lC.Position) or lC
	else parentCF_now = CFrame.new() end
	local localCF

	if invertMotion and simLocalCFrames then
		-- Place at endpoint of forward sim. Index by effective TKF since presim caps at 500.
		local endLocalCF = simLocalCFrames[simEffectiveTKF or data.TotalKeyFrames] or simLocalCFrames[0]
		localCF = endLocalCF
		visualPart.CFrame = parentCF_now * localCF
	else
		localCF = link and parentCF_now:ToObjectSpace(initialCF) or initialCF
		visualPart.CFrame = parentCF_now * localCF
	end

	local pData = {
		Type = "Part",
		VisualPart = visualPart,
		Link = link,
		LinkMode = data.LinkMode,
		-- RigidLocal: snapshot the link's at-emit parent CFrame. Per-frame Link
		-- consumers (LinkTrack / getLinkCF / Bounce) read this instead of the live
		-- link CFrame. nil for non-RigidLocal modes.
		_rigidLocalParentCF = (data.LinkMode == "RigidLocal" and link) and parentCF_now or nil,
		Events = data.Events,
		SpecialMesh = visualPart:FindFirstChildOfClass('SpecialMesh'),
		Decal = visualPart:FindFirstChildOfClass('Decal'),
		-- SurfaceAppearance: flipbook routes to ColorMap, Transparency/Color graphs drive MeshPart
		-- because SurfaceAppearance has no per-instance Transparency / Color3 surface.
		SurfaceAppearance = visualPart:FindFirstChildOfClass('SurfaceAppearance'),

		StartTime = os.clock(),
		TotalKeyFrames = invertMotion and simEffectiveTKF or math.max(1, data.TotalKeyFrames),
		CurrentStep = 0,
		AccumulatedDT = 0,
		LifeTime = Time,
		PartLife = data.PartLife,
		CurrentPosition = visualPart.Position,
		LocalCF = localCF,

		BaseDirection = baseDirection,
		-- Accumulated velocity contribution from Acceleration. Tracked explicitly so OnHit
		-- Bounce can reflect it along the hit normal (a closed-form `accel * elapsedSec`
		-- would keep integrating from t=0 across a bounce, diverging from physics).
		_accelVel = Vector3.zero,
		-- Speed multiplier: scales the speed graph's output. Compounds across bounces
		-- when Bounciness < 1  -  each bounce loses energy along the normal, so the
		-- particle's effective speed decreases on impact.
		SpeedMultiplier = 1,
		-- Persistent angular velocity from collision impulses (deg/sec, world axes).
		-- Bounce's tangential drag converts to spin; this rate compounds with each
		-- glancing impact. _spinAccum tracks the integrated rotation contribution.
		_spinRate = Vector3.zero,
		_spinAccumX = 0,
		_spinAccumY = 0,
		_spinAccumZ = 0,
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
		_localWorldCF = localCF, -- seed for LinkTrack frame 0

		-- PosOffsetX/Y/Z trajectory state. DisplacementMode selects which rotation
		-- to apply: Local = SpawnRotation (post-RotXYZ particle frame); RigidLocal
		-- = SpawnEmitterRotation (same frame as SpawnRotation but with the per-
		-- particle RotXYZ contribution algebraically removed via rotXYZ:Inverse());
		-- Global = no rotation. HasPosOffsetGraphs gates per-frame work.
		SpawnRotation = localCF.Rotation,
		SpawnEmitterRotation = localCF.Rotation * rotXYZ:Inverse(),
		DisplacementMode = data.DisplacementMode,
		-- Body bbox half-diagonal for Jolt-style point-velocity sleep check.
		-- Captures rotation-induced edge speed when CoM is near-stationary.
		_sleepRadius = (visualPart and visualPart:IsA("BasePart") and visualPart.Size.Magnitude * 0.5) or 1.0,
		_prevWorldOff = Vector3.zero,
		HasPosOffsetGraphs = data.PosOffsetX ~= nil or data.PosOffsetY ~= nil or data.PosOffsetZ ~= nil,

		-- Target-accel: target.Position read live each frame, target ref fixed at emit.
		-- Disabled with InvertMotion (cached SimLocalCFrames can't track moving targets).
		HasTargetAccel = data.AccelerationTowardsInstance == true and data.AccelTarget ~= nil and data.AccelStrength ~= nil and not data.InvertMotion,
		AccelTarget = data.AccelTarget,
		TargetVel = Vector3.zero,
		NeedsFullIteration = data.VelocityVectored,
		NeedsRotAccum = (data.RotMode == "Speed") and not data.VelocityVectored,
		HasDrag = data.ParticleData.Drag ~= 0,
		HasAccel = data.ParticleData.Acceleration.Magnitude > 0,
		HasDecal = visualPart:FindFirstChildOfClass('Decal') ~= nil,

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
	}

	-- 1-frame pop prevention for PosOffset graphs: sample at t=0, apply to spawn
	-- pose so frame-0 visual already includes the initial offset. Initialize
	-- _prevWorldOff to worldOff(0) so the first Update step's delta is measured
	-- from this baseline (not from zero  -  which would cause a teleport at step 1
	-- for front-loaded curves where posOff ramps fast initially).
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
	local startSize = Vector3.new(GraphMod.QueryPointsWithTime(0, pData.Graphs.SizeX, pData.Seeds.SizeX), GraphMod.QueryPointsWithTime(0, pData.Graphs.SizeY, pData.Seeds.SizeY), GraphMod.QueryPointsWithTime(0, pData.Graphs.SizeZ, pData.Seeds.SizeZ))
	local startTrans = GraphMod.QueryPointsWithTime(0, pData.Graphs.Transparency, pData.Seeds.Transparency)
	local startColor = GraphMod.QueryColorPointWithTime(0, pData.Graphs.Color)
	local startBright = GraphMod.QueryPointsWithTime(0, pData.Graphs.Brightness, pData.Seeds.Brightness)

	if pData.SpecialMesh then
		pData.SpecialMesh.Scale = startSize
	else
		pData.VisualPart.Size = startSize
	end

	if pData.SurfaceAppearance then
		-- Color graph tints SA.Color raw; Brightness graph drives SA.EmissiveTint only.
		-- EmissiveTint write pcall-guarded for older Studio builds without the property.
		pData.VisualPart.Transparency = startTrans
		pData.VisualPart.Color = Color3.fromRGB(startColor.R * 255, startColor.G * 255, startColor.B * 255)
		pData.SurfaceAppearance.Color = Color3.fromRGB(startColor.R * 255, startColor.G * 255, startColor.B * 255)
		pcall(function() pData.SurfaceAppearance.EmissiveTint = Color3.new(startColor.R * startBright, startColor.G * startBright, startColor.B * startBright) end)
	elseif pData.Decal then
		pData.Decal.Transparency = startTrans
		pData.Decal.Color3 = Color3.fromRGB(startColor.R * 255 * startBright, startColor.G * 255 * startBright, startColor.B * 255 * startBright)
	else
		-- Plain MeshPart: Brightness multiplies SA/Decal only.
		pData.VisualPart.Transparency = startTrans
		pData.VisualPart.Color = Color3.fromRGB(startColor.R * 255, startColor.G * 255, startColor.B * 255)
	end

	-- Disable PEs BEFORE Parent so they don't auto-emit on workspace entry;
	-- EnableEmitSingle below controls their timing.
	for _, desc in visualPart:GetDescendants() do
		if desc:IsA("ParticleEmitter") then desc.Enabled = false end
	end

	visualPart.Parent = data.EmitParent or self:GetFolder()

	for _, desc in visualPart:GetDescendants() do
		if desc:IsA("Trail") then
			if desc:GetAttribute("Transformed") then continue end
			local underTransformed = false
			local cur = desc.Parent
			while cur and cur ~= visualPart do
				if cur:GetAttribute("Transformed") then underTransformed = true; break end
				cur = cur.Parent
			end
			if underTransformed then continue end
			local dur = desc:GetAttribute("EmitDuration")
			if dur ~= nil then
				if desc.Enabled ~= true then
					desc.Enabled = true
				end
				if desc:GetAttribute("_pooledTrailEnabled") ~= nil then
					desc:SetAttribute("_pooledTrailEnabled", true)
				end
			end
		end
	end

	-- Restore pooled Trails (deferred 1 Heartbeat). Snapshot was synced above
	-- so this is consistent with our pre-Parent enable for fresh emits.
	Pool.restoreTrails(visualPart, "Part")

	-- EnableEmitSingle schedules the EmitDuration-end Trail.Enabled=false and
	-- the PE Emit(count) burst. Trail.Enabled=true was already set above; this
	-- just registers the disable timer + PE emission.
	local alive = self:_makeAliveCheck()
	for _, child in visualPart:GetChildren() do
		if child:IsA("Attachment") then ParticlesMod.EnableEmitChildrenAndRepeatForAttachments(child, alive) end
		ParticlesMod.EnableEmitSingle(child, alive)
	end

	if self._parentScaleMap and self._parentScaleMap[part] then
		pData.ParentScale = self._parentScaleMap[part]
	end

	pData._sourceItem = part
	Particle._seedTsOverride(pData, part)
	if data.Pool ~= false then pData._sourceRT, pData._poolKind = data.RenderTemplate, "Part" end
	-- Static-graph short-circuit: constant-valued graphs nil out + stamp pData._static<Name>.
	StaticPass.apply(pData)
	-- _applyEmitVisualPasses MUST precede _registerEmit (OnEmit payload reads post-pass CFrame).
	self:_applyEmitVisualPasses(pData)
	self:_registerEmit(pData, emitCtx)

	-- Flipbook target: SA.ColorMap if present, else Decal.Texture, else MeshPart.TextureID
	-- when the visual is a plain MeshPart with no Decal/SA child to write to.
	if data.CachedMeshTextures and #data.CachedMeshTextures > 0 then
		local flipTarget = pData.SurfaceAppearance or pData.Decal
		if not flipTarget and visualPart:IsA("MeshPart") then flipTarget = visualPart end
		if flipTarget then
			MeshFlipMod.Flip(pData, data.ParticleData, data.CachedMeshTextures, flipTarget, Time)
		end
	end

	-- Nested Part-Icles: source-walk; link = visualPart drives position. See NestedEmit.luau.
	-- walkWithScale forwards this particle's inherited Model-scale chain to deeper nested
	-- particles, so Model→Part→Part keeps scaling (a Part adds no factor, just propagates).
	pData._nestedAlive = { true }
	NestedEmit.walkWithScale(self, data.RenderTemplate, visualPart, pData._nestedAlive, emitCtx, pData.ParentScale, pData)
end

--[[
	一次性发射 Attachment：在父 BasePart 局部空间模拟。
	DirMode 三分：Local=RotXYZ 后；Global=世界轴再投影；RigidLocal=RotXYZ 前。

	@param attachment Attachment - 源 Attachment（须有 GetData / RenderTemplate）
	@param link Instance? - 链接目标；nil 时用 data.Link；emitCtx.IgnoreLink 时强制 nil
	@param emitCtx table? - 可选发射上下文，字段同 EmitPart（ChainCtx / EmitIndex / EventOriginCF / EventOriginResolver / IgnoreLink / UseFullOrigin）
]]
function Particle:EmitAttachment(attachment, link, emitCtx)
	if not attachment or not attachment.Parent then return end
	local data = self:GetData(attachment)
	if not data or not data.RenderTemplate then return end
	if emitCtx and emitCtx.IgnoreLink then
		link = nil
	else
		link = link or data.Link
	end

	local Time = RangeMod.RandomValueFromRange(data.Lifetime)
	if Time <= 0 then Time = 0.001 end

	-- Source world pose composes the full chain (Attachment-in-Attachment-in-BasePart).
	-- WorldCFrame is the only correct read when parent is non-BasePart; .CFrame alone
	-- yields parent-local relative to a non-BasePart frame that breaks compose math.
	local sourceWorldCF = attachment.WorldCFrame
	local worldCF
	local originOverrideCF
	if emitCtx then
		if emitCtx.EventOriginResolver then originOverrideCF = emitCtx.EventOriginResolver() end
		if not originOverrideCF then originOverrideCF = emitCtx.EventOriginCF end
	end
	if originOverrideCF then
		if emitCtx and emitCtx.UseFullOrigin then
			worldCF = originOverrideCF -- AtCFrame: full source orientation
		else
			worldCF = CFrame.new(originOverrideCF.Position) * sourceWorldCF.Rotation
		end
	elseif link then
		local linkWorldCF = Constants.resolveLinkCFrame(link)
		if data.LinkMode == "Follow" then
			worldCF = CFrame.new(linkWorldCF.Position) * sourceWorldCF.Rotation
		else
			worldCF = CFrame.new(linkWorldCF.Position) * linkWorldCF.Rotation * sourceWorldCF.Rotation
		end
	else
		worldCF = sourceWorldCF
	end
	-- Walk up to find a BasePart anchor; nested-Attachment source compose through
	-- actualParent's CFrame. All downstream local-space math runs in actualParent-local.
	local actualParent = data.EmitParent or _findBasePartAncestor(attachment) or self:GetFolder()
	local actualParentCF = (actualParent and actualParent:IsA("BasePart")) and actualParent.CFrame or CFrame.new()
	local localCF = actualParentCF:ToObjectSpace(worldCF)
	local dirInfo = DirectionVectors[data.EmissionDirection] or DirectionVectors[Enum.NormalId.Top]

	-- Initial rotation (always applied)
	local dirMode = data.DirMode or "RigidLocal"
	local rotS = AxisLinksMod.sampleRangeAxes(data, data.AxisLinks, {"RotX","RotY","RotZ"}, RangeMod, emitCtx)
	local RX, RY, RZ = rotS.RotX, rotS.RotY, rotS.RotZ
	-- Initial RotX/Y/Z compose through RotOrder; see EmitPart for the rationale.
	local rotXYZ = Constants.composeRotation(data.RotOrder or "Global", RX, RY, RZ)
	local rotatedLocalCF = localCF * rotXYZ

	-- Base direction (3-way: Local / RigidLocal / Global). Sim frame is parent-local.
	local baseDirection
	if dirMode == "Local" then
		baseDirection = rotatedLocalCF[dirInfo.vector] * dirInfo.multiplier
	elseif dirMode == "Global" then
		-- World-space axis converted to actualParent-local (handles nested-Attachment via
		-- the BasePart anchor we walked up to). Folder-anchored fallback stays world-space.
		local worldAxis = CFrame.new()[dirInfo.vector] * dirInfo.multiplier
		if actualParent and actualParent:IsA("BasePart") then
			baseDirection = actualParent.CFrame:VectorToObjectSpace(worldAxis)
		else
			baseDirection = worldAxis
		end
	else -- RigidLocal: pre-RotXYZ pose in actualParent-local
		baseDirection = localCF[dirInfo.vector] * dirInfo.multiplier
	end

	localCF = rotatedLocalCF

	-- simFrameCF = actualParentCF so applyPositionOffset converts world offset into
	-- actualParent-local space (matches our sim frame after the BasePart walk-up).
	-- posScale: scale the spawn Pos spread by the parent Model's scale at this emit moment.
	local posScale = 1
	local psInfo = self._parentScaleMap and self._parentScaleMap[attachment]
	if psInfo and psInfo.ScaleMotion ~= false then
		posScale = Constants.getParentScaleFactor(psInfo, os.clock(), GraphMod)
	end
	localCF = Constants.applyPositionOffset(localCF, data, link, attachment, RangeMod, AxisLinksMod, emitCtx, actualParentCF, posScale)

	-- Global: apply inv(actualParent.Rotation) so parent cancels at engine-multiply,
	-- leaving rotXYZ alone. Uses actualParent (BasePart anchor) so nested-Attachment
	-- sources don't fall to identity here.
	if dirMode == "Global" then
		if actualParent and actualParent:IsA("BasePart") then
			localCF = CFrame.new(localCF.Position) * actualParent.CFrame.Rotation:Inverse() * rotXYZ
		else
			localCF = CFrame.new(localCF.Position) * rotXYZ
		end
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
	-- Aliases: RotSpeed only (no Size on Attachments).
	AxisLinksMod.applyGraphAxisAliases(data, seeds, data.AxisLinks)

	local invertMotion = data.InvertMotion
	local simLocalCFrames = nil
	local simEffectiveTKF = nil

	if invertMotion then
		simLocalCFrames, simEffectiveTKF = self:PreSimulateAttachmentForward(data, seeds, localCF, baseDirection, spreadRotation, Time, nil, localCF.Rotation * rotXYZ:Inverse())
	end

	local visualAttachment = Pool.acquireOrCopyBare(data.RenderTemplate, "Attachment", data.Pool)
	visualAttachment.Archivable = false

	if invertMotion and simLocalCFrames then
		local endLocalCF = simLocalCFrames[simEffectiveTKF or data.TotalKeyFrames] or simLocalCFrames[0]
		localCF = endLocalCF
	end

	-- actualParent + actualParentCF computed earlier (before sim) so PreSimulate
	-- and rotation/shape compose operate in the right frame.

	visualAttachment.CFrame = localCF
	visualAttachment.Parent = actualParent

	-- Restore nested-Trail Enabled snapshot after Parent so they track from spawn pose.
	-- Mirrors the Part path at line ~273.
	Pool.restoreTrails(visualAttachment, "Attachment")

	-- pData.LocalCF in parentCF_now-local space (link path) or actualParent-local (unlinked).
	local pDataLocalCF = localCF
	if link then
		local linkWorldCF = Constants.resolveLinkCFrame(link)
		local convCF = (actualParent and actualParent:IsA("BasePart")) and actualParent.CFrame or CFrame.new()
		local linkLocalCF = convCF:ToObjectSpace(linkWorldCF)
		local parentCF_now
		if data.LinkMode == "Follow" or data.LinkMode == "Pivot" then
			parentCF_now = CFrame.new(linkLocalCF.Position)
		else
			parentCF_now = linkLocalCF
		end
		pDataLocalCF = parentCF_now:ToObjectSpace(localCF)
	end

	-- RigidLocal: snapshot link's WORLD CFrame at emit. Per-frame Attachment Link
	-- consumers convert this to visualParent-local at sample time so a moving
	-- visualParent stays correct.
	local rigidLocalSnapshot = nil
	if data.LinkMode == "RigidLocal" and link then
		rigidLocalSnapshot = Constants.resolveLinkCFrame(link)
	end

	local pData = {
		Type = "Attachment",
		VisualPart = visualAttachment,
		Link = link,
		LinkMode = data.LinkMode,
		_rigidLocalParentCF = rigidLocalSnapshot,
		Events = data.Events,

		StartTime = os.clock(),
		TotalKeyFrames = invertMotion and simEffectiveTKF or math.max(1, data.TotalKeyFrames),
		CurrentStep = 0,
		AccumulatedDT = 0,
		LifeTime = Time,
		PartLife = data.PartLife,
		LocalCF = pDataLocalCF,
		_localWorldCF = pDataLocalCF, -- seed for LinkTrack frame 0
		BaseDirection = baseDirection,
		_accelVel = Vector3.zero,
		SpeedMultiplier = 1,
		_spinRate = Vector3.zero,
		_spinAccumX = 0, _spinAccumY = 0, _spinAccumZ = 0,
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

		-- PosOffsetX/Y/Z trajectory graph state (see Part emit above for semantics).
		SpawnRotation = pDataLocalCF.Rotation,
		SpawnEmitterRotation = pDataLocalCF.Rotation * rotXYZ:Inverse(),
		DisplacementMode = data.DisplacementMode,
		-- Attachment has no Size; 1.0 fallback for the sleep point-velocity check.
		_sleepRadius = 1.0,
		_prevWorldOff = Vector3.zero,
		HasPosOffsetGraphs = data.PosOffsetX ~= nil or data.PosOffsetY ~= nil or data.PosOffsetZ ~= nil,

		NeedsFullIteration = data.VelocityVectored,
		NeedsRotAccum = (data.RotMode == "Speed") and not data.VelocityVectored,
		HasDrag = data.ParticleData.Drag ~= 0,
		HasAccel = data.ParticleData.Acceleration.Magnitude > 0,

		Graphs = {
			Speed = data.Speed,
			RotSpeedX = data.RotSpeedX, RotSpeedY = data.RotSpeedY, RotSpeedZ = data.RotSpeedZ,
			PosOffsetX = data.PosOffsetX, PosOffsetY = data.PosOffsetY, PosOffsetZ = data.PosOffsetZ,
			Timescale = data.Timescale,
		},
		Seeds = seeds,
		_effectiveElapsed = GraphMod.InitialEffectiveElapsed(data.Timescale, seeds.Timescale, Time),
	}

	-- 1-frame pop prevention for PosOffset (see EmitPart for semantics).
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
	-- Nested-Model scale: attachment particles also read the parent's scale (motion/rotation).
	if self._parentScaleMap and self._parentScaleMap[attachment] then
		pData.ParentScale = self._parentScaleMap[attachment]
	end
	if data.Pool ~= false then pData._sourceRT, pData._poolKind = data.RenderTemplate, "Attachment" end
	-- Static-graph short-circuit: constant-valued graphs nil out + stamp pData._static<Name>.
	StaticPass.apply(pData)
	self:_applyEmitVisualPasses(pData)
	self:_registerEmit(pData, emitCtx)

	for _, desc in visualAttachment:GetDescendants() do
		if desc:IsA("ParticleEmitter") then desc.Enabled = false end
	end
	local aliveAtt = self:_makeAliveCheck()
	for _, child in visualAttachment:GetChildren() do
		if child:IsA("Attachment") then ParticlesMod.EnableEmitChildrenAndRepeatForAttachments(child, aliveAtt) end
		ParticlesMod.EnableEmitSingle(child, aliveAtt)
	end

	-- Nested Part-Icles: source-walk; link = visualAttachment drives position.
	-- walkWithScale forwards the inherited Model-scale chain to deeper nested particles.
	pData._nestedAlive = { true }
	NestedEmit.walkWithScale(self, data.RenderTemplate, visualAttachment, pData._nestedAlive, emitCtx, pData.ParentScale, pData)
end

--[[
	一次性发射 Beam：无空间运动（焊在 Attachment0/1），靠每属性曲线、GraphBlender、BeamFlipbook 动画。
	静态曲线只在发射时读一次。

	@param beam Beam - 源 Beam（须有 GetData / RenderTemplate）
	@param link Instance? - 链接目标（Beam 不走空间 Link，仅透传到 pData）
	@param emitCtx table? - 可选发射上下文；可用 `_parentCloneMap` {[Instance]=Instance} 重绑 Attachment0/1
]]
function Particle:EmitBeam(beam, link, emitCtx)
	if not beam or not beam.Parent then return end
	local data = self:GetData(beam)
	if not data or not data.RenderTemplate then return end

	-- PoolHide flipped Enabled=false on release; flip back here.
	local visualBeam = Pool.acquireOrClone(data.RenderTemplate, "Beam", data.Pool)
	visualBeam.Archivable = false
	visualBeam.Enabled = true
	if data.FaceCamera ~= nil then visualBeam.FaceCamera = data.FaceCamera end
	if data.ZOffset ~= nil then visualBeam.ZOffset = data.ZOffset end
	if data.TextureMode ~= nil then visualBeam.TextureMode = data.TextureMode end

	-- Rebind parent-scope Attachment0/1 refs via parent's clone map (nested-emit path).
	if emitCtx and emitCtx._parentCloneMap then
		local map = emitCtx._parentCloneMap
		if visualBeam.Attachment0 and map[visualBeam.Attachment0] then visualBeam.Attachment0 = map[visualBeam.Attachment0] end
		if visualBeam.Attachment1 and map[visualBeam.Attachment1] then visualBeam.Attachment1 = map[visualBeam.Attachment1] end
	end

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

	-- Cache merged keypoint times per adjacent pair.
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

	visualBeam.Parent = data.EmitParent or self:GetFolder()

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

		TransStates = transStates,
		ColorStates = colorStates,
		TransMergedTimes = transMergedTimes,
		ColorMergedTimes = colorMergedTimes,

		Graphs = { Timescale = data.BeamTimescale },
		Seeds = { Timescale = beamTimescaleSeed },
		_effectiveElapsed = GraphMod.InitialEffectiveElapsed(data.BeamTimescale, beamTimescaleSeed, safeLifeTime),
	}

	-- Inherit parent model scale; cache bases for static props.
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
	if data.Pool ~= false then pData._sourceRT, pData._poolKind = data.RenderTemplate, "Beam" end
	-- No _applyEmitVisualPasses for Beam (spatial-mesh only).
	self:_registerEmit(pData, emitCtx)

	if data.CachedBeamTextures and #data.CachedBeamTextures > 0 and data.FlipbookParticle then
		MeshFlipMod.FlipBeam(pData, data.FlipbookParticle, data.CachedBeamTextures, visualBeam, safeLifeTime)
	end
end

end
