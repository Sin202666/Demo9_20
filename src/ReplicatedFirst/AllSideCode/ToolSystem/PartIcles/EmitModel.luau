--[[
	Module: EmitModel
	Description: PartIcles Mixin：Model 一次性发射与 Animate（整模克隆、PivotTo / ScaleTo）
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-09-01

	功能：
	- EmitModel：克隆 RT，PivotTo 定位、ScaleTo 缩放到子节点
	- EmitModelAnimate：直接驱动 LIVE RenderTemplate，AnimateLoop 用新数据重跑

	由 PartIcles/init 作为 mixin 注入 Particle 实例，业务侧勿单独 require。
]]

local GraphMod = require(script.Parent.Graph)
local RangeMod = require(script.Parent.Range)
local AxisLinksMod = require(script.Parent.AxisLinks)
local ParticlesMod = require(script.Parent.Particles)
local TypeRegistry = require(script.Parent.TypeRegistry)
local EventsMod = require(script.Parent.Events)
local Constants = require(script.Parent.PartConstants)
local Pool = require(script.Parent.Pool)
local NestedEmit = require(script.Parent.NestedEmit)
local StaticPass = require(script.Parent.StaticPass)
local DirectionVectors = Constants.DirectionVectors

return function(Particle)

--[[
	一次性发射 Model：以 model:GetPivot 为枢轴，对齐 EmitPart 但无 Shape 几何。

	@param model Model - 源 Model（须有 GetData / RenderTemplate）
	@param link Instance? - 链接目标；nil 时用 data.Link；emitCtx.IgnoreLink 时强制 nil
	@param emitCtx table? - 可选发射上下文，字段同 EmitPart（ChainCtx / EventOriginCF / EventOriginResolver / IgnoreLink / UseFullOrigin）
]]
function Particle:EmitModel(model, link, emitCtx)
	if not model or not model.Parent then return end
	local data = self:GetData(model)
	if not data or not data.RenderTemplate then return end
	if emitCtx and emitCtx.IgnoreLink then
		link = nil
	else
		link = link or data.Link
	end

	local Time = RangeMod.RandomValueFromRange(data.Lifetime)
	if Time <= 0 then Time = 0.001 end

	-- Event-origin override replaces pivot position; preserves authored rotation.
	local pivotCF = model:GetPivot()
	local originOverrideCF
	if emitCtx then
		if emitCtx.EventOriginResolver then originOverrideCF = emitCtx.EventOriginResolver() end
		if not originOverrideCF then originOverrideCF = emitCtx.EventOriginCF end
	end
	local unrotatedCF
	if originOverrideCF then
		if emitCtx and emitCtx.UseFullOrigin then
			unrotatedCF = originOverrideCF -- AtCFrame: full source CFrame
		else
			unrotatedCF = CFrame.new(originOverrideCF.Position) * pivotCF.Rotation
		end
	else
		unrotatedCF = pivotCF
	end
	local dirInfo = DirectionVectors[data.EmissionDirection] or DirectionVectors[Enum.NormalId.Top]
	local rawWorldDirection = unrotatedCF[dirInfo.vector] * dirInfo.multiplier

	local initialCF = unrotatedCF

	local dirMode = data.DirMode or "RigidLocal"
	local rotS = AxisLinksMod.sampleRangeAxes(data, data.AxisLinks, {"RotX","RotY","RotZ"}, RangeMod, emitCtx)
	local RX, RY, RZ = rotS.RotX, rotS.RotY, rotS.RotZ
	local rotXYZ = Constants.composeRotation(data.RotOrder or "Global", RX, RY, RZ)
	initialCF = initialCF * rotXYZ

	initialCF = Constants.applyPositionOffset(initialCF, data, link, model, RangeMod, AxisLinksMod, emitCtx)

	if dirMode == "Global" then
		initialCF = CFrame.new(initialCF.Position) * rotXYZ
	end

	local baseDirection
	if dirMode == "Local" then
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
		RotSpeedX = GraphMod.GenerateSeed(data.RotSpeedX),
		RotSpeedY = GraphMod.GenerateSeed(data.RotSpeedY),
		RotSpeedZ = GraphMod.GenerateSeed(data.RotSpeedZ),
		PosOffsetX = GraphMod.GenerateSeed(data.PosOffsetX),
		PosOffsetY = GraphMod.GenerateSeed(data.PosOffsetY),
		PosOffsetZ = GraphMod.GenerateSeed(data.PosOffsetZ),
		Speed = GraphMod.GenerateSeed(data.Speed),
		Scale = GraphMod.GenerateSeed(data.Scale),
		Timescale = GraphMod.GenerateSeed(data.Timescale),
	}
	AxisLinksMod.applyGraphAxisAliases(data, seeds, data.AxisLinks)

	local invertMotion = data.InvertMotion
	local simLocalCFrames = nil
	local simEffectiveTKF = nil

	if invertMotion then
		simLocalCFrames, simEffectiveTKF = self:PreSimulateForward(data, seeds, initialCF, baseDirection, spreadRotation, link, Time, nil, initialCF.Rotation * rotXYZ:Inverse())
	end

	local visualModel = Pool.acquireOrCopyBare(data.RenderTemplate, "Model", data.Pool)
	visualModel.Archivable = false
	-- Pool reuse can carry over the prior cycle's final ScaleTo value. Snapshot the
	-- authored RT scale once + restore before the graph-driven ScaleTo writes its t=0
	-- value below so the visible state never reflects a stale scale, even for one frame.
	do
		local rt = data.RenderTemplate
		if rt and visualModel:GetAttribute("_pooledModelScale") == nil then
			local ok, s = pcall(function() return rt:GetScale() end)
			if ok and s then visualModel:SetAttribute("_pooledModelScale", s) end
		end
		local priorScale = visualModel:GetAttribute("_pooledModelScale")
		if priorScale then pcall(function() visualModel:ScaleTo(priorScale) end) end
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
		visualModel:PivotTo(parentCF_now * localCF)
	else
		localCF = link and parentCF_now:ToObjectSpace(initialCF) or initialCF
		visualModel:PivotTo(parentCF_now * localCF)
	end

	local pData = {
		Type = "Model",
		VisualPart = visualModel,
		Link = link,
		LinkMode = data.LinkMode,
		_rigidLocalParentCF = (data.LinkMode == "RigidLocal" and link) and parentCF_now or nil,
		Events = data.Events,

		StartTime = os.clock(),
		TotalKeyFrames = invertMotion and simEffectiveTKF or math.max(1, data.TotalKeyFrames),
		CurrentStep = 0,
		AccumulatedDT = 0,
		LifeTime = Time,
		PartLife = data.PartLife,
		CurrentPosition = visualModel:GetPivot().Position,
		LocalCF = localCF,

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
		_localWorldCF = localCF,

		-- PosOffsetX/Y/Z trajectory graph state (see Emit.luau Part path for semantics).
		SpawnRotation = localCF.Rotation,
		SpawnEmitterRotation = localCF.Rotation * rotXYZ:Inverse(),
		DisplacementMode = data.DisplacementMode,
		-- Model has no .Size; 1.0 fallback for sleep point-velocity check.
		_sleepRadius = 1.0,
		_prevWorldOff = Vector3.zero,
		HasPosOffsetGraphs = data.PosOffsetX ~= nil or data.PosOffsetY ~= nil or data.PosOffsetZ ~= nil,

		NeedsFullIteration = data.VelocityVectored,
		NeedsRotAccum = (data.RotMode == "Speed") and not data.VelocityVectored,
		HasDrag = data.ParticleData.Drag ~= 0,
		HasAccel = data.ParticleData.Acceleration.Magnitude > 0,

		Graphs = {
			RotSpeedX = data.RotSpeedX, RotSpeedY = data.RotSpeedY, RotSpeedZ = data.RotSpeedZ,
			PosOffsetX = data.PosOffsetX, PosOffsetY = data.PosOffsetY, PosOffsetZ = data.PosOffsetZ,
			Speed = data.Speed, Scale = data.Scale,
			Timescale = data.Timescale,
		},
		Seeds = seeds,
		_effectiveElapsed = GraphMod.InitialEffectiveElapsed(data.Timescale, seeds.Timescale, Time),
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
			pData.VisualPart:PivotTo(pData.VisualPart:GetPivot() + worldOff)
		end
	end

	-- Cache descendant Beams for Segments clamp after ScaleTo.
	local vBeams = {}
	for _, desc in visualModel:GetDescendants() do
		if desc:IsA("Beam") and not desc:GetAttribute("Transformed") then table.insert(vBeams, desc) end
	end
	if #vBeams > 0 then pData._visualBeams = vBeams end

	-- Inherit the parent-Model scale chain (nil for a top-level Model) so this Model's own
	-- visual AND its nested children compound with every ancestor Model's scale.
	if self._parentScaleMap and self._parentScaleMap[model] then
		pData.ParentScale = self._parentScaleMap[model]
	end

	-- 1-frame pop prevention. Compound the frame-0 scale with the inherited chain.
	local startScale = math.max(0.001, GraphMod.QueryPointsWithTime(0, pData.Graphs.Scale, pData.Seeds.Scale))
	startScale = startScale * Constants.getParentScaleFactor(pData.ParentScale, pData.StartTime, GraphMod)
	visualModel:ScaleTo(startScale)
	for _, beam in ipairs(vBeams) do if beam.Segments < 20 then beam.Segments = 20 end end

	visualModel.Parent = data.EmitParent or self:GetFolder()

	-- Restore pooled Trails AFTER PivotTo + Parent so trails track from spawn, not pool pose.
	Pool.restoreTrails(visualModel, "Model")

	for _, desc in visualModel:GetDescendants() do
		if desc:IsA("ParticleEmitter") then desc.Enabled = false end
	end
	local alive = self:_makeAliveCheck()
	for _, desc in visualModel:GetDescendants() do
		ParticlesMod.EnableEmitSingle(desc, alive)
	end

	pData._sourceItem = model
	Particle._seedTsOverride(pData, model)
	if data.Pool ~= false then pData._sourceRT, pData._poolKind = data.RenderTemplate, "Model" end
	StaticPass.apply(pData)
	self:_applyEmitVisualPasses(pData)
	self:_registerEmit(pData, emitCtx)

	-- Nested Part-Icles: source-walk with per-node origin override. See NestedEmit.luau.
	-- _parentScaleMap is keyed by SOURCE node (not cloned desc) so live-beam scale
	-- lookups still resolve when nested emit runs against the original instance.
	pData._nestedAlive = { true }
	self._parentScaleMap = self._parentScaleMap or {}
	local parentScaleInfo = {
		Graph = pData.Graphs.Scale, Seed = pData.Seeds.Scale,
		-- StaticPass nils constant graphs from pData.Graphs and stamps the value on pData._staticScale.
		-- Fallback to 1.0 when neither is set (legacy Models pre-Fix that lack Scale attribute) so
		-- Update / UpdateBeam ParentScale blocks don't fall through to QueryPointsWithTime(nil) crash.
		StaticValue = pData._staticScale or (pData.Graphs.Scale == nil and 1 or nil),
		TotalKeyFrames = pData.TotalKeyFrames, StartTime = pData.StartTime, LifeTime = pData.LifeTime,
		-- nil/true → scale Beam.TextureLength with model scale (preserves tile count).
		-- false → leave authored TextureLength alone (tiles repeat more as beam grows).
		ScaleTextureLength = data.ScaleTextureLength ~= false,
		-- Nested-particle motion scaling (Speed/Accel/PosOffset/Pos) + rotation (opt-in).
		ScaleMotion = data.ScaleMotion ~= false,
		ScaleRotation = data.ScaleRotation == true,
		-- Chain to this Model's own inherited scale so nested children compound up the tree.
		Parent = pData.ParentScale,
	}
	local scaleKeys = {}
	NestedEmit.walk(self, data.RenderTemplate, visualModel, pData._nestedAlive, emitCtx, function(node)
		self._parentScaleMap[node] = parentScaleInfo
		scaleKeys[#scaleKeys+1] = node
	end)
	pData._scaleMapKeys = scaleKeys
end

--[[
	Animate 模式发射 Model：直接驱动 LIVE RenderTemplate（不克隆）；AnimateLoop 用新数据重跑。

	@param model Model - 源 Model（须有 GetData / RenderTemplate）
	@param link Instance? - 链接目标；nil 时用 data.Link
	@param emitCtx table? - 可选发射上下文，字段同 EmitPart
]]
function Particle:EmitModelAnimate(model, link, emitCtx)
	if not model or not model.Parent then return end
	local data = self:GetData(model)
	if not data or not data.RenderTemplate then return end
	link = link or data.Link

	local Time = RangeMod.RandomValueFromRange(data.Lifetime)
	if Time <= 0 then Time = 0.001 end

	local visualModel = data.RenderTemplate -- LIVE source, not a clone
	local initialAnchorCF = visualModel:GetPivot()

	local unrotatedCF = model:GetPivot()
	local dirInfo = DirectionVectors[data.EmissionDirection] or DirectionVectors[Enum.NormalId.Top]
	local rawWorldDirection = unrotatedCF[dirInfo.vector] * dirInfo.multiplier

	local initialCF = unrotatedCF

	local dirMode = data.DirMode or "RigidLocal"
	local rotS = AxisLinksMod.sampleRangeAxes(data, data.AxisLinks, {"RotX","RotY","RotZ"}, RangeMod, emitCtx)
	local RX, RY, RZ = rotS.RotX, rotS.RotY, rotS.RotZ
	local rotXYZ = Constants.composeRotation(data.RotOrder or "Global", RX, RY, RZ)
	initialCF = initialCF * rotXYZ

	initialCF = Constants.applyPositionOffset(initialCF, data, link, model, RangeMod, AxisLinksMod, emitCtx)

	if dirMode == "Global" then
		initialCF = CFrame.new(initialCF.Position) * rotXYZ
	end

	local baseDirection
	if dirMode == "Local" then
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
		RotSpeedX = GraphMod.GenerateSeed(data.RotSpeedX),
		RotSpeedY = GraphMod.GenerateSeed(data.RotSpeedY),
		RotSpeedZ = GraphMod.GenerateSeed(data.RotSpeedZ),
		PosOffsetX = GraphMod.GenerateSeed(data.PosOffsetX),
		PosOffsetY = GraphMod.GenerateSeed(data.PosOffsetY),
		PosOffsetZ = GraphMod.GenerateSeed(data.PosOffsetZ),
		Speed = GraphMod.GenerateSeed(data.Speed),
		Scale = GraphMod.GenerateSeed(data.Scale),
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
	visualModel:PivotTo(parentCF_now * localCF)

	local pData = {
		Type = "Model",
		VisualPart = visualModel,
		Link = link,
		LinkMode = data.LinkMode,
		_rigidLocalParentCF = (data.LinkMode == "RigidLocal" and link) and parentCF_now or nil,
		Events = data.Events,

		StartTime = os.clock(),
		TotalKeyFrames = invertMotion and simEffectiveTKF or math.max(1, data.TotalKeyFrames),
		CurrentStep = 0, AccumulatedDT = 0,
		LifeTime = Time, PartLife = data.PartLife or 0,
		CurrentPosition = visualModel:GetPivot().Position,
		LocalCF = localCF,

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
		_localWorldCF = localCF,

		-- PosOffsetX/Y/Z trajectory graph state (see Emit.luau Part path for semantics).
		SpawnRotation = localCF.Rotation,
		SpawnEmitterRotation = localCF.Rotation * rotXYZ:Inverse(),
		DisplacementMode = data.DisplacementMode,
		-- Model has no .Size; 1.0 fallback for sleep point-velocity check.
		_sleepRadius = 1.0,
		_prevWorldOff = Vector3.zero,
		HasPosOffsetGraphs = data.PosOffsetX ~= nil or data.PosOffsetY ~= nil or data.PosOffsetZ ~= nil,

		NeedsFullIteration = data.VelocityVectored,
		NeedsRotAccum = (data.RotMode == "Speed") and not data.VelocityVectored,
		HasDrag = data.ParticleData.Drag ~= 0,
		HasAccel = data.ParticleData.Acceleration.Magnitude > 0,

		Graphs = {
			RotSpeedX = data.RotSpeedX, RotSpeedY = data.RotSpeedY, RotSpeedZ = data.RotSpeedZ,
			PosOffsetX = data.PosOffsetX, PosOffsetY = data.PosOffsetY, PosOffsetZ = data.PosOffsetZ,
			Speed = data.Speed, Scale = data.Scale,
			Timescale = data.Timescale,
		},
		Seeds = seeds,
		_effectiveElapsed = GraphMod.InitialEffectiveElapsed(data.Timescale, seeds.Timescale, Time),

		IsAnimate = true, AnimateItem = model,
		InitialAnchorCF = initialAnchorCF, InitialLocalCF = localCF,
		-- Snapshot scale so finishAnimate / cancelAnimation restore authored value.
		InitialScale = (function() local ok, s = pcall(function() return model:GetScale() end); return ok and s or 1 end)(),
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
			pData.VisualPart:PivotTo(pData.VisualPart:GetPivot() + worldOff)
		end
	end

	local vBeams = {}
	for _, desc in visualModel:GetDescendants() do
		if desc:IsA("Beam") and not desc:GetAttribute("Transformed") then table.insert(vBeams, desc) end
	end
	if #vBeams > 0 then pData._visualBeams = vBeams end

	-- Inherit + compound the parent-Model scale chain (see EmitModel normal path).
	if self._parentScaleMap and self._parentScaleMap[model] then
		pData.ParentScale = self._parentScaleMap[model]
	end
	local startScale = math.max(0.001, GraphMod.QueryPointsWithTime(0, pData.Graphs.Scale, pData.Seeds.Scale))
	startScale = startScale * Constants.getParentScaleFactor(pData.ParentScale, pData.StartTime, GraphMod)
	visualModel:ScaleTo(startScale)
	for _, beam in ipairs(vBeams) do if beam.Segments < 20 then beam.Segments = 20 end end

	-- LIVE source, no pre-disable; EnableEmitSingle handles each descendant.
	local aliveAnim = self:_makeAliveCheck()
	for _, desc in visualModel:GetDescendants() do
		ParticlesMod.EnableEmitSingle(desc, aliveAnim)
	end

	pData._sourceItem = model
	Particle._seedTsOverride(pData, model)
	StaticPass.apply(pData)
	self._activeAnimates[model] = pData
	self:_applyEmitVisualPasses(pData)
	self:_registerEmit(pData, emitCtx)

	-- Nested Part-Icles: fire each transformed descendant; record parent scale info.
	self._parentScaleMap = self._parentScaleMap or {}
	local parentScaleInfo = {
		Graph = pData.Graphs.Scale, Seed = pData.Seeds.Scale,
		-- StaticPass nils constant graphs from pData.Graphs and stamps the value on pData._staticScale.
		-- Fallback to 1.0 when neither is set (legacy Models pre-Fix that lack Scale attribute) so
		-- Update / UpdateBeam ParentScale blocks don't fall through to QueryPointsWithTime(nil) crash.
		StaticValue = pData._staticScale or (pData.Graphs.Scale == nil and 1 or nil),
		TotalKeyFrames = pData.TotalKeyFrames, StartTime = pData.StartTime, LifeTime = pData.LifeTime,
		-- nil/true → scale Beam.TextureLength with model scale (preserves tile count).
		-- false → leave authored TextureLength alone (tiles repeat more as beam grows).
		ScaleTextureLength = data.ScaleTextureLength ~= false,
		-- Nested-particle motion scaling (Speed/Accel/PosOffset/Pos) + rotation (opt-in).
		ScaleMotion = data.ScaleMotion ~= false,
		ScaleRotation = data.ScaleRotation == true,
		-- Chain to this Model's own inherited scale so nested children compound up the tree.
		Parent = pData.ParentScale,
	}
	local scaleKeys = {}
	for _, desc in visualModel:GetDescendants() do
		if desc:GetAttribute("Transformed") then
			self._parentScaleMap[desc] = parentScaleInfo
			scaleKeys[#scaleKeys+1] = desc
			self:EnableEmit(desc, desc.Parent, EventsMod.descendCtx(emitCtx))
		end
	end
	pData._scaleMapKeys = scaleKeys
end

end
