--[[
	Module: Transform
	Description: Part-Icles mixin：把实例打成发射器（Attribute + PartIcleProperties + RenderTemplate），以及预演运动轨迹
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-09-01

	:Transform 盖章属性、建配置与 RenderTemplate、隐藏源实例。
	:PreSimulateForward / :PreSimulateAttachmentForward 按步进返回局部 CFrame，不真正发射；Motion Preview 与 Emit 共用，保证预览与实发一致。
	本文件不写权威结算。挂载：return function(Particle)。
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local HttpService = Utils.HttpService

local GraphMod = require(script.Parent.Graph)
local TypeRegistry = require(script.Parent.TypeRegistry)
local Constants = require(script.Parent.PartConstants)
local DirectionVectors = Constants.DirectionVectors

--[[
	将 Transform mixin 挂到 Particle 主表
	@param Particle table - PartIcles 运行时主表（将获得 :Transform / :PreSimulate*）
]]
return function(Particle)

-- TransformCompleted fires after Transform/TransformModel/transformDirectAccess; lazy create.
if not Particle.TransformCompleted then
	Particle.TransformCompleted = Instance.new("BindableEvent")
end

--[[
	把实例打成发射器：盖章 Attribute、建 PartIcleProperties + RenderTemplate、隐藏源
	directAccess 的 Trail/Beam 会提升为 TrailEmitter/Beam（盖章后 classCheck 翻转）
	@param part Instance - 待 Transform 的源实例
	@return nil - 已 Transform 或无法识别类型时直接返回
]]
function Particle:Transform(part)
	if part:GetAttribute("Transformed") then return end
	local typeDef = TypeRegistry.getTypeFor(part)
	if not typeDef then return end

	-- Promoting a directAccess type: swap to the emitter typeDef before createConfig so the
	-- Configuration child carries TrailEmitter / Beam property defaults (not the directAccess shape).
	if typeDef.directAccess then
		if part:IsA("Trail") and TypeRegistry.Types.TrailEmitter then
			typeDef = TypeRegistry.Types.TrailEmitter
		elseif part:IsA("Beam") and TypeRegistry.Types.Beam then
			typeDef = TypeRegistry.Types.Beam
		else
			return
		end
	end

	if part:IsA("Model") then
		-- PrimaryPart not required. Model:GetPivot / PivotTo / ScaleTo work via the
		-- computed WorldPivot when PrimaryPart is unset.
		return self:TransformModel(part, typeDef)
	end

	local config = TypeRegistry.createConfig(part, typeDef)

	local renderTemplate = part:Clone()
	renderTemplate.Name = "RenderTemplate"

	for _, child in renderTemplate:GetChildren() do
		if child:GetAttribute("Transformed") or child:IsA("Attachment") then continue end
		if child.Name == TypeRegistry.CONFIG_NAME or child.Name == "EmitParent" or child.Name == "Link" or child.Name == "AccelTarget" or child.Name == "ImageFlipbooks" then
			child:Destroy()
		elseif part:IsA("PointLight") or part:IsA("Highlight") then
			child:Destroy()
		elseif part:IsA("Attachment") then
			-- Strip plugin internals; keep authored Trails/Beams/Decals.
			if child.Name == "MeshFlipbooks" or child.Name == "BeamFlipbooks" or child.Name == "GraphBlender" then
				child:Destroy()
			end
		elseif part:IsA("ImageLabel") then
			-- Keep UIComponent decorators (UIGradient/UICorner/UIStroke/UIPadding).
			if not child:IsA("UIComponent") then child:Destroy() end
		elseif not child:IsA("SpecialMesh") and not child:IsA("Decal") and not child:IsA("Texture") and not child:IsA("SurfaceAppearance") then
			-- SurfaceAppearance must survive; Emit reads it via FindFirstChildOfClass.
			child:Destroy()
		end
	end

	-- Strip plugin attributes; preserve user-authored ones.
	for _, attrName in ipairs({"Transformed", "Qwinkle", "IsEmitter", "EmitCount", "EmitDuration", "EmitDelay", "EmissionMode", "AnimateLoop", "PreloadTexture", "LinkMode", "LinkSource"}) do
		renderTemplate:SetAttribute(attrName, nil)
	end

	if renderTemplate:IsA("BasePart") then
		renderTemplate.Anchored = true; renderTemplate.CanCollide = false; renderTemplate.CanQuery = false
		renderTemplate.CanTouch = false; renderTemplate.CastShadow = false; renderTemplate.Massless = true; renderTemplate.Locked = true
		renderTemplate.Transparency = 1
		for _, c in ipairs(renderTemplate:GetChildren()) do
			if c:IsA("Decal") or c:IsA("Texture") then c.Transparency = 1 end
		end
	end

	if renderTemplate:IsA("Attachment") then
		renderTemplate.CFrame = CFrame.new()
	end

	-- Silence native PEs/Trails on the RT (they ignore parent hidden state). Skip Transformed
	-- ones  -  directAccess Trails own .Enabled, and nested transformed PEs have their own lifecycle.
	for _, desc in ipairs(renderTemplate:GetDescendants()) do
		if (desc:IsA("ParticleEmitter") or desc:IsA("Trail"))
			and not desc:GetAttribute("Transformed")
		then desc.Enabled = false end
	end

	renderTemplate.Parent = part

	-- Capture authored visuals so emitter defaults reflect the source's pre-transform state.
	-- Size: SpecialMesh.Scale wins. Color/Transparency: first Decal wins UNLESS a
	-- SurfaceAppearance is present (PBR covers the surface  -  Decal is irrelevant).
	-- Read BEFORE the source strip below destroys the SpecialMesh/Decal children.
	if part:IsA("BasePart") and not part:IsA("Terrain") then
		local sizeVec = part.Size
		local meshChild = part:FindFirstChildWhichIsA("SpecialMesh")
		if meshChild then sizeVec = meshChild.Scale end
		local colorVal = part.Color
		local transparencyVal = part.Transparency
		local hasSurfaceAppearance = part:FindFirstChildWhichIsA("SurfaceAppearance") ~= nil
		if not hasSurfaceAppearance then
			local decalChild = part:FindFirstChildWhichIsA("Decal")
			if decalChild then
				colorVal = decalChild.Color3
				transparencyVal = decalChild.Transparency
			end
		end
		config:SetAttribute("SizeX", NumberSequence.new(sizeVec.X))
		config:SetAttribute("SizeY", NumberSequence.new(sizeVec.Y))
		config:SetAttribute("SizeZ", NumberSequence.new(sizeVec.Z))
		config:SetAttribute("Color", ColorSequence.new(colorVal))
		config:SetAttribute("Transparency", NumberSequence.new(transparencyVal))
	end

	-- Hide source: visual children moved to RT.
	if part:IsA("BasePart") then
		for _, child in ipairs(part:GetChildren()) do
			if child ~= renderTemplate and (child:IsA("SpecialMesh") or child:IsA("Decal") or child:IsA("Texture")) then child:Destroy() end
		end
		part.Transparency = 1
	elseif part:IsA("PointLight") then
		part.Enabled = false
	elseif part:IsA("Highlight") then
		part.Enabled = false
	elseif part:IsA("PostProcessEffect") then
		part.Enabled = false
	elseif part:IsA("ImageLabel") then
		part.Visible = false
	end

	if part:IsA("PointLight") then
		config:SetAttribute("Shadows", part.Shadows)
	end

	-- Capture authored PostProcessEffect / Atmosphere into config as single-keypoint sequences.
	if part:IsA("BlurEffect") then
		config:SetAttribute("BlurSize", NumberSequence.new(part.Size))
	elseif part:IsA("BloomEffect") then
		config:SetAttribute("BloomIntensity", NumberSequence.new(part.Intensity))
		config:SetAttribute("BloomSize", NumberSequence.new(part.Size))
		config:SetAttribute("BloomThreshold", NumberSequence.new(part.Threshold))
	elseif part:IsA("ColorCorrectionEffect") then
		config:SetAttribute("CCBrightness", NumberSequence.new(part.Brightness))
		config:SetAttribute("CCContrast", NumberSequence.new(part.Contrast))
		config:SetAttribute("CCSaturation", NumberSequence.new(part.Saturation))
		config:SetAttribute("CCTintColor", ColorSequence.new(part.TintColor))
	elseif part:IsA("Atmosphere") then
		config:SetAttribute("AtmDensity", NumberSequence.new(part.Density))
		config:SetAttribute("AtmOffset", NumberSequence.new(part.Offset))
		config:SetAttribute("AtmGlare", NumberSequence.new(part.Glare))
		config:SetAttribute("AtmHaze", NumberSequence.new(part.Haze))
		config:SetAttribute("AtmColor", ColorSequence.new(part.Color))
		config:SetAttribute("AtmDecay", ColorSequence.new(part.Decay))
	elseif part:IsA("Highlight") then
		config:SetAttribute("HLFillColor", ColorSequence.new(part.FillColor))
		config:SetAttribute("HLFillTransparency", NumberSequence.new(part.FillTransparency))
		config:SetAttribute("HLOutlineColor", ColorSequence.new(part.OutlineColor))
		config:SetAttribute("HLOutlineTransparency", NumberSequence.new(part.OutlineTransparency))
		config:SetAttribute("HLDepthMode", part.DepthMode.Name)
		-- Adornee picker child: emit-time _resolveAdornee falls through to source.Adornee then
		-- source.Parent when this ObjectValue is unset. Picker UI binds to the ObjectValue's
		-- Value field  -  required for the user-facing Adornee picker.
		if not part:FindFirstChild("Adornee") then
			local ad = Instance.new("ObjectValue"); ad.Name = "Adornee"; ad.Value = nil; ad.Parent = part
		end
	end

	-- RT must never render live (both source + RT live in Lighting / GUI tree).
	if renderTemplate:IsA("PostProcessEffect") then renderTemplate.Enabled = false end

	if part:IsA("ImageLabel") then
		if renderTemplate:IsA("ImageLabel") then renderTemplate.Visible = false end
		-- Only force BG=1 from the default; preserve user-authored translucent backdrops.
		if part.BackgroundTransparency == 0 then
			part.BackgroundTransparency = 1
		end
		config:SetAttribute("Image", part.Image)
		config:SetAttribute("Position", part.Position)
		config:SetAttribute("ImgSize", part.Size)
		config:SetAttribute("AnchorPoint", part.AnchorPoint)
		config:SetAttribute("ZIndex", part.ZIndex)
		config:SetAttribute("ScaleType", part.ScaleType.Name)
		config:SetAttribute("ResampleMode", part.ResampleMode.Name)
		if not part:FindFirstChild("ImageFlipbooks") then
			local ff = Instance.new("Folder"); ff.Name = "ImageFlipbooks"; ff.Parent = part
		end
	end

	if part:IsA("BasePart") and not part:IsA("Terrain") then
		if not part:FindFirstChild("MeshFlipbooks") then
			local mf = Instance.new("Folder"); mf.Name = "MeshFlipbooks"; mf.Parent = part
		end
	end

	-- Trail promote-to-emitter: disable source + RT Trail (RT gets re-Enabled on each emit clone).
	-- TrailEmitter properties auto-fill from TypeData.TrailEmitterProperties defaults via Migrate;
	-- explicit per-prop capture isn't required since native Trail values already live on the RT clone.
	if part:IsA("Trail") then
		part.Enabled = false
		if renderTemplate:IsA("Trail") then renderTemplate.Enabled = false end
		-- Default GraphBlender: state 1 seeds from source Trail's current Width / Transparency / Color
		-- so the emit immediately matches the visual the user authored before promoting.
		if not part:FindFirstChild("GraphBlender") then
			local gb = Instance.new("Folder"); gb.Name = "GraphBlender"
			local s1 = Instance.new("Configuration"); s1.Name = "1"
			s1:SetAttribute("Time", 0)
			s1:SetAttribute("Width", part.WidthScale or NumberSequence.new(1))
			s1:SetAttribute("Transparency", part.Transparency or NumberSequence.new(0))
			s1:SetAttribute("Color", part.Color or ColorSequence.new(Color3.new(1,1,1)))
			s1:SetAttribute("_AutoTime", true)
			s1.Parent = gb; gb.Parent = part
		end
		if not part:FindFirstChild("TrailFlipbooks") then
			local tf = Instance.new("Folder"); tf.Name = "TrailFlipbooks"; tf.Parent = part
		end
	end

	if part:IsA("Beam") then
		part.Enabled = false
		part.LightInfluence = 0 -- Unlit default
		if renderTemplate:IsA("Beam") then renderTemplate.Enabled = false; renderTemplate.LightInfluence = 0 end

		if not part:FindFirstChild("BeamFlipbooks") then
			local bf = Instance.new("Folder"); bf.Name = "BeamFlipbooks"; bf.Parent = part
		end

		config:SetAttribute("BeamBrightness", NumberSequence.new(part.Brightness))
		config:SetAttribute("CurveSize0", NumberSequence.new(part.CurveSize0))
		config:SetAttribute("CurveSize1", NumberSequence.new(part.CurveSize1))
		config:SetAttribute("Width0", NumberSequence.new(part.Width0))
		config:SetAttribute("Width1", NumberSequence.new(part.Width1))
		config:SetAttribute("LightEmission", NumberSequence.new(part.LightEmission))
		config:SetAttribute("BeamLightInfluence", NumberSequence.new(0))
		config:SetAttribute("Segments", NumberSequence.new(part.Segments))
		config:SetAttribute("TextureLength", NumberSequence.new(part.TextureLength))
		config:SetAttribute("TextureSpeed", NumberSequence.new(part.TextureSpeed))
		config:SetAttribute("FaceCamera", part.FaceCamera)
		config:SetAttribute("ZOffset", part.ZOffset)
		config:SetAttribute("BeamTextureMode", part.TextureMode.Name)

		-- _AutoTime marks states whose Time was set by Add State (vs user-edited via TimeBox).
		local gb = Instance.new("Folder"); gb.Name = "GraphBlender"
		local s1 = Instance.new("Configuration"); s1.Name = "1"
		s1:SetAttribute("Time", 0); s1:SetAttribute("Transparency", part.Transparency); s1:SetAttribute("Color", part.Color)
		s1:SetAttribute("_AutoTime", true)
		s1.Parent = gb; gb.Parent = part
	end

	if not part:FindFirstChild("EmitParent") then
		local ep = Instance.new("ObjectValue")
		ep.Name = "EmitParent"
		ep.Value = nil
		ep.Parent = part
	end

	if (part:IsA("BasePart") or part:IsA("Attachment")) and not part:FindFirstChild("Link") then
		local lk = Instance.new("ObjectValue")
		lk.Name = "Link"
		lk.Parent = part
	end

	if part:IsA("BasePart") and not part:FindFirstChild("AccelTarget") then
		local at = Instance.new("ObjectValue")
		at.Name = "AccelTarget"
		at.Value = nil
		at.Parent = part
	end

	-- ShapePart override: when UseShape=true, particles spawn within this BasePart's volume
	-- (using its Size + CFrame). Default Value = source itself so the picker UI shows the
	-- source explicitly; runtime `data.ShapePart or part` fallback handles unset values.
	if part:IsA("BasePart") and not part:FindFirstChild("ShapePart") then
		local sp = Instance.new("ObjectValue")
		sp.Name = "ShapePart"
		sp.Value = part
		sp.Parent = part
	end

	part:SetAttribute("Transformed", true)
	part:SetAttribute("Qwinkle", true)
	-- Stable per-emitter id. Clones inherit it, so all clones of one authored emitter
	-- share one EvenDistribution rolling-cycle counter (keyed by this in _evenCycleStore).
	part:SetAttribute("_EvenCycleId", HttpService:GenerateGUID(false))
	-- Beam EmitCount=1 default (one beam = one instance); others default 0 (zero-as-zero contract).
	part:SetAttribute("EmitCount", part:IsA("Beam") and 1 or 0)
	part:SetAttribute("EmitDuration", 0)
	part:SetAttribute("EmitDelay", 0)
	part:SetAttribute("IsEmitter", true)
	if part:IsA("BasePart") or part:IsA("Beam") or part:IsA("Trail") or part:IsA("ImageLabel") then
		part:SetAttribute("PreloadTexture", false)
	end
	-- Atmosphere is singleton-per-Lighting; default to Animate to avoid flickering Emit stacks.
	part:SetAttribute("EmissionMode", part:IsA("Atmosphere") and "Animate" or "Emit")
	part:SetAttribute("AnimateLoop", false)
	-- Link-driven types only. Highlight (Adornee-driven) + Trail (Attachment0/1-driven) skip these.
	if part:IsA("BasePart") or part:IsA("Beam") or part:IsA("Attachment") or part:IsA("Model") then
		part:SetAttribute("LinkMode", "Follow")
		part:SetAttribute("LinkSource", "None")
	end
	pcall(function() Particle.TransformCompleted:Fire(part) end)
end

--[[
	按步进预演 Part/Beam/Model 运动，返回相对 parentCF 的局部 CFrame 序列（不发射）
	@param data table - GetData 快照（LinkMode / Speed / ParticleData / InvertMotion 等）
	@param seeds table - 各图通道随机种子 { [graphName]=seedTable }
	@param initialCF CFrame - 起始世界 CFrame
	@param baseDirection Vector3 - 初始发射方向
	@param spreadRotation CFrame - 散射旋转
	@param link Instance? - Link 目标；nil 则相对世界原点
	@param lifetime number - 粒子寿命（秒）
	@param previewMaxSteps number? - 预览步数上限；emit 路径由 InvertMotion 另限 500
	@param spawnEmitterRotation CFrame? - 发射器生成时旋转；nil 时退化为 spawnRotation
	@return { [number]: CFrame } - 步进局部 CFrame（含 [0]）
	@return number - 实际使用的关键帧数
]]
function Particle:PreSimulateForward(data, seeds, initialCF, baseDirection, spreadRotation, link, lifetime, previewMaxSteps, spawnEmitterRotation)
	local linkMode = data.LinkMode or "Follow"
	local parentCF
	if link then
		local worldCF = Constants.resolveLinkCFrame(link)
		if linkMode == "Follow" or linkMode == "Pivot" then
			parentCF = CFrame.new(worldCF.Position)
		else parentCF = worldCF end
	else parentCF = CFrame.new() end
	local useVOS = (linkMode == "Weld" or linkMode == "WeldWithoutRotation" or linkMode == "RigidLocal") and link ~= nil
	-- previewMaxSteps caps preview callers; InvertMotion caps emit (per-particle CFrame allocation).
	local INVERT_MAX_STEPS = 500
	local totalKeyFrames = math.max(1, data.TotalKeyFrames)
	if previewMaxSteps and totalKeyFrames > previewMaxSteps then
		totalKeyFrames = previewMaxSteps
	elseif data.InvertMotion and totalKeyFrames > INVERT_MAX_STEPS then
		totalKeyFrames = INVERT_MAX_STEPS
	end
	local stepDT = lifetime / totalKeyFrames

	local currentPosition = initialCF.Position
	local localCF = parentCF:ToObjectSpace(initialCF)
	local baseDir = baseDirection
	local emissionDirection = data.EmissionDirection
	local rotMode = data.RotMode or "OverLife"
	local accRotX, accRotY, accRotZ = 0, 0, 0

	-- Snapshot AccelTarget pos at start; InvertMotion's cached CFrames can't track moving targets.
	local hasTargetAccel = data.AccelerationTowardsInstance == true and data.AccelTarget ~= nil and data.AccelStrength ~= nil and not data.InvertMotion
	local targetWorldPos
	if hasTargetAccel then
		local t = data.AccelTarget
		-- Type dispatch matches Update.getTargetPosition (Bone live pose, Model pivot, etc.).
		if t:IsA("Bone") then targetWorldPos = t.TransformedWorldCFrame.Position
		elseif t:IsA("BasePart") then targetWorldPos = t.Position
		elseif t:IsA("Attachment") then targetWorldPos = t.WorldPosition
		elseif t:IsA("Model") then local ok, cf = pcall(t.GetPivot, t); if ok and cf then targetWorldPos = cf.Position end
		end
		if not targetWorldPos then hasTargetAccel = false end
	end
	local targetVel = Vector3.zero
	local accelStrengthSeed = seeds.AccelStrength or {}

	-- PosOffset trajectory state for the precomputation loop. DisplacementMode +
	-- spawnEmitterRotation flow through Constants.resolveDisplacement below so the
	-- cached SimLocalCFrames honour the same frame the live Update.luau path uses.
	-- When spawnEmitterRotation is nil (preview path) it falls back to spawnRotation,
	-- degrading RigidLocal to Local for preview (preview is single-particle, no rotXYZ).
	local hasPosOffset = data.PosOffsetX ~= nil or data.PosOffsetY ~= nil or data.PosOffsetZ ~= nil
	-- Under a useVOS link, capture spawnRotation link-local (matches the live Update path,
	-- Emit.luau:598) so a Local-mode PosOffset is link-local and the no-VOS branch below
	-- mirrors Update._composeLocalDelta (F30 parity — keep these two copies in sync).
	local spawnRotation = useVOS and (parentCF:ToObjectSpace(initialCF)).Rotation or initialCF.Rotation
	local prevWorldOff = Vector3.zero

	local localCFrames = {}
	localCFrames[0] = parentCF:ToObjectSpace(initialCF)

	for step = 1, totalKeyFrames do
		local steppedI = step / totalKeyFrames
		local elapsedSec = steppedI * lifetime

		local speed = GraphMod.QueryPointsWithTime(steppedI, data.Speed, seeds.Speed)
		local draggedSpeed = speed * math.exp(-data.ParticleData.Drag * elapsedSec)

		local accelVelocity = data.ParticleData.Acceleration * elapsedSec

		local displacement = (baseDir * draggedSpeed + accelVelocity) * stepDT

		if hasTargetAccel then
			local toTarget = targetWorldPos - currentPosition
			local dist = toTarget.Magnitude
			if dist > 1e-4 then
				local mag = GraphMod.QueryPointsWithTime(steppedI, data.AccelStrength, accelStrengthSeed)
				if mag and mag ~= 0 then
					targetVel = targetVel + toTarget * (mag * stepDT / dist)
					displacement = displacement + targetVel * stepDT
				end
			end
		end

		local posDelta = Vector3.zero
		if hasPosOffset then
			local oX = data.PosOffsetX and GraphMod.QueryPointsWithTime(steppedI, data.PosOffsetX, seeds.PosOffsetX) or 0
			local oY = data.PosOffsetY and GraphMod.QueryPointsWithTime(steppedI, data.PosOffsetY, seeds.PosOffsetY) or 0
			local oZ = data.PosOffsetZ and GraphMod.QueryPointsWithTime(steppedI, data.PosOffsetZ, seeds.PosOffsetZ) or 0
			local worldOff = Constants.resolveDisplacement(Vector3.new(oX, oY, oZ),
				data.DisplacementMode or "Global", spawnRotation,
				spawnEmitterRotation or spawnRotation)
			posDelta = worldOff - prevWorldOff
			prevWorldOff = worldOff
		end

		-- F30 parity with Update._composeLocalDelta: VOS only the world velocity into
		-- link-local; a Local-mode offset is already link-local (spawnRotation captured
		-- link-local) so add it as-is — else a spinning Weld precesses it.
		local posIsLinkLocal = useVOS and (data.DisplacementMode or "Global") == "Local"
		local velLocal = useVOS and parentCF:VectorToObjectSpace(displacement) or displacement
		local posLocal = (useVOS and not posIsLinkLocal) and parentCF:VectorToObjectSpace(posDelta) or posDelta
		localCF = CFrame.new(velLocal + posLocal) * localCF

		local rotSpeedX = GraphMod.QueryPointsWithTime(steppedI, data.RotSpeedX, seeds.RotSpeedX)
		local rotSpeedY = GraphMod.QueryPointsWithTime(steppedI, data.RotSpeedY, seeds.RotSpeedY)
		local rotSpeedZ = GraphMod.QueryPointsWithTime(steppedI, data.RotSpeedZ, seeds.RotSpeedZ)

		local rotCF
		local rotOrder = data.RotOrder or "Global"
		if rotMode == "Speed" then
			accRotX = accRotX + rotSpeedX * stepDT
			accRotY = accRotY + rotSpeedY * stepDT
			accRotZ = accRotZ + rotSpeedZ * stepDT
			rotCF = Constants.composeRotation(rotOrder, accRotX, accRotY, accRotZ)
		else
			rotCF = Constants.composeRotation(rotOrder, rotSpeedX, rotSpeedY, rotSpeedZ)
		end

		local worldCF = (parentCF * localCF) * rotCF
		currentPosition = worldCF.Position

		if data.VelocityVectored then
			local dirInfo = DirectionVectors[emissionDirection] or DirectionVectors[Enum.NormalId.Top]
			baseDir = (worldCF * spreadRotation)[dirInfo.vector] * dirInfo.multiplier
		end

		localCFrames[step] = parentCF:ToObjectSpace(worldCF)
	end

	return localCFrames, totalKeyFrames
end

--[[
	Attachment 预演：无 Link 参数，在 attachment 局部空间积分（initialCF 兼作 localCF）
	@param data table - GetData 快照（与 PreSimulateForward 同形）
	@param seeds table - 各图通道随机种子 { [graphName]=seedTable }
	@param initialCF CFrame - 起始局部 CFrame
	@param baseDirection Vector3 - 初始发射方向
	@param spreadRotation CFrame - 散射旋转
	@param lifetime number - 粒子寿命（秒）
	@param previewMaxSteps number? - 预览步数上限
	@param spawnEmitterRotation CFrame? - 发射器生成时旋转
	@return { [number]: CFrame } - 步进局部 CFrame（含 [0]）
	@return number - 实际使用的关键帧数
]]
function Particle:PreSimulateAttachmentForward(data, seeds, initialCF, baseDirection, spreadRotation, lifetime, previewMaxSteps, spawnEmitterRotation)
	local INVERT_MAX_STEPS = 500
	local totalKeyFrames = math.max(1, data.TotalKeyFrames)
	if previewMaxSteps and totalKeyFrames > previewMaxSteps then
		totalKeyFrames = previewMaxSteps
	elseif data.InvertMotion and totalKeyFrames > INVERT_MAX_STEPS then
		totalKeyFrames = INVERT_MAX_STEPS
	end
	local stepDT = lifetime / totalKeyFrames

	local localCF = initialCF
	local baseDir = baseDirection
	local emissionDirection = data.EmissionDirection
	local rotMode = data.RotMode or "OverLife"
	local accRotX, accRotY, accRotZ = 0, 0, 0
	-- AccelerationTowardsInstance not integrated here (local-space mismatch with world target).
	-- Preview Attachment trajectories diverge from live emit when target accel is enabled.

	-- PosOffset trajectory state. Routes through Constants.resolveDisplacement with
	-- DisplacementMode + spawnEmitterRotation so cached frames match live Update path.
	local hasPosOffset = data.PosOffsetX ~= nil or data.PosOffsetY ~= nil or data.PosOffsetZ ~= nil
	local spawnRotation = initialCF.Rotation
	local prevWorldOff = Vector3.zero

	local localCFrames = {}
	localCFrames[0] = initialCF

	for step = 1, totalKeyFrames do
		local steppedI = step / totalKeyFrames
		local elapsedSec = steppedI * lifetime

		local speed = GraphMod.QueryPointsWithTime(steppedI, data.Speed, seeds.Speed)
		local draggedSpeed = speed * math.exp(-data.ParticleData.Drag * elapsedSec)

		local accelVelocity = data.ParticleData.Acceleration * elapsedSec
		local displacement = (baseDir * draggedSpeed + accelVelocity) * stepDT

		if hasPosOffset then
			local oX = data.PosOffsetX and GraphMod.QueryPointsWithTime(steppedI, data.PosOffsetX, seeds.PosOffsetX) or 0
			local oY = data.PosOffsetY and GraphMod.QueryPointsWithTime(steppedI, data.PosOffsetY, seeds.PosOffsetY) or 0
			local oZ = data.PosOffsetZ and GraphMod.QueryPointsWithTime(steppedI, data.PosOffsetZ, seeds.PosOffsetZ) or 0
			local worldOff = Constants.resolveDisplacement(Vector3.new(oX, oY, oZ),
				data.DisplacementMode or "Global", spawnRotation,
				spawnEmitterRotation or spawnRotation)
			displacement = displacement + (worldOff - prevWorldOff)
			prevWorldOff = worldOff
		end

		localCF = CFrame.new(displacement) * localCF

		-- Rotation
		local rotSpeedX = GraphMod.QueryPointsWithTime(steppedI, data.RotSpeedX, seeds.RotSpeedX)
		local rotSpeedY = GraphMod.QueryPointsWithTime(steppedI, data.RotSpeedY, seeds.RotSpeedY)
		local rotSpeedZ = GraphMod.QueryPointsWithTime(steppedI, data.RotSpeedZ, seeds.RotSpeedZ)

		local rotCF
		local rotOrder = data.RotOrder or "Global"
		if rotMode == "Speed" then
			accRotX = accRotX + rotSpeedX * stepDT
			accRotY = accRotY + rotSpeedY * stepDT
			accRotZ = accRotZ + rotSpeedZ * stepDT
			rotCF = Constants.composeRotation(rotOrder, accRotX, accRotY, accRotZ)
		else
			rotCF = Constants.composeRotation(rotOrder, rotSpeedX, rotSpeedY, rotSpeedZ)
		end

		local worldCF = localCF * rotCF

		if data.VelocityVectored then
			local dirVecInfo = DirectionVectors[emissionDirection] or DirectionVectors[Enum.NormalId.Top]
			baseDir = (worldCF * spreadRotation)[dirVecInfo.vector] * dirVecInfo.multiplier
		end

		localCFrames[step] = worldCF
	end

	return localCFrames, totalKeyFrames
end

--[[
	Model 专用 Transform：RT 为整棵子树克隆；源后代只隐藏不 Destroy（保留 Motor6D / AnimationController）
	@param model Model - 待 Transform 的模型
	@param typeDef table - TypeRegistry 类型定义（properties / classCheck 等）
	@return nil - 已 Transform 时直接返回
]]
function Particle:TransformModel(model, typeDef)
	if model:GetAttribute("Transformed") then return end
	local config = TypeRegistry.createConfig(model, typeDef)

	-- Create RenderTemplate (clean clone of the Model)
	local renderTemplate = model:Clone()
	renderTemplate.Name = "RenderTemplate"

	for _, child in renderTemplate:GetChildren() do
		if child.Name == TypeRegistry.CONFIG_NAME or child.Name == "EmitParent" or child.Name == "Link" or child.Name == "AccelTarget" then
			child:Destroy()
		end
	end

	for _, attrName in ipairs({"Transformed", "Qwinkle", "IsEmitter", "EmitCount", "EmitDuration", "EmitDelay", "EmissionMode", "AnimateLoop"}) do
		renderTemplate:SetAttribute(attrName, nil)
	end

	-- Anchor + safe-clone every BasePart; silence native PEs/Trails (they ignore parent hidden state).
	for _, desc in renderTemplate:GetDescendants() do
		if desc:IsA("BasePart") then
			desc.Anchored = true; desc.CanCollide = false; desc.CanQuery = false
			desc.CanTouch = false; desc.CastShadow = false; desc.Massless = true; desc.Locked = true
		elseif (desc:IsA("ParticleEmitter") or desc:IsA("Trail"))
			and not desc:GetAttribute("Transformed")
		then
			desc.Enabled = false
		end
	end

	renderTemplate.Parent = model

	-- Hide originals; visuals moved to RT.
	for _, desc in ipairs(model:GetDescendants()) do
		if desc:IsDescendantOf(renderTemplate) then continue end
		if desc:IsA("BasePart") then desc.Transparency = 1
		elseif desc:IsA("SpecialMesh") or desc:IsA("Decal") or desc:IsA("Texture") then desc:Destroy() end
	end

	if not model:FindFirstChild("EmitParent") then
		local ep = Instance.new("ObjectValue")
		ep.Name = "EmitParent"
		ep.Value = nil
		ep.Parent = model
	end

	if not model:FindFirstChild("Link") then
		local lk = Instance.new("ObjectValue")
		lk.Name = "Link"
		lk.Parent = model
	end

	model:SetAttribute("Transformed", true)
	model:SetAttribute("Qwinkle", true)
	model:SetAttribute("EmitCount", 0)
	model:SetAttribute("EmitDuration", 0)
	model:SetAttribute("EmitDelay", 0)
	model:SetAttribute("IsEmitter", true)
	model:SetAttribute("PreloadTexture", false)
	model:SetAttribute("EmissionMode", "Emit")
	model:SetAttribute("AnimateLoop", false)
	model:SetAttribute("LinkMode", "Follow")
	model:SetAttribute("LinkSource", "None")
	pcall(function() Particle.TransformCompleted:Fire(model) end)
end

end
