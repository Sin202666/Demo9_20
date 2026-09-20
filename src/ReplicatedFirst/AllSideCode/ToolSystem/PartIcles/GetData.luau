--[[
	Module: GetData
	Description: Part-Icles mixin：把已 Transform 实例的配置 Attribute 读成扁平 data 表，供 Emit / Update 使用
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-09-01

	未 Transform（无 PartIcleProperties）返回 nil。按 Instance 类型分支填字段（Model / 屏幕特效 / ImageLabel / Light / Highlight / Trail / Attachment / Beam / Part）。
	本文件不写权威状态、不拆文件。挂载：return function(Particle) 后 Particle:GetData(item)。
]]

local MeshFlipMod = require(script.Parent.Flipbook)
local TypeRegistry = require(script.Parent.TypeRegistry)
local AxisLinksMod = require(script.Parent.AxisLinks)
local EventsSchema = require(script.Parent.EventsSchema)

--[[
	按名称安全取 Enum 项；未知名或空名回退 default，避免坏迁移打断发射
	@param enumType Enum - Roblox Enum 分类（如 Enum.NormalId）
	@param name string? - Attribute 里存的枚举 Name
	@param default any - 查找失败时的回退值（通常为 EnumItem）
	@return any - 解析到的 EnumItem，或 default
]]
local function _safeEnum(enumType, name, default)
	if not name then return default end
	local ok, val = pcall(function() return enumType[name] end)
	return (ok and val) or default
end

--[[
	读取各轴 LinkedTo Attribute，交给 AxisLinks.sanitize 过滤非法链接
	@param config Configuration - PartIcleProperties 配置实例
	@return table - { [axisName]=primaryName|nil }，空/非法链接为 nil
]]
local function _readAxisLinks(config)
	local raw = {
		SizeX = config:GetAttribute("SizeXLinkedTo"), SizeY = config:GetAttribute("SizeYLinkedTo"), SizeZ = config:GetAttribute("SizeZLinkedTo"),
		RotSpeedX = config:GetAttribute("RotSpeedXLinkedTo"), RotSpeedY = config:GetAttribute("RotSpeedYLinkedTo"), RotSpeedZ = config:GetAttribute("RotSpeedZLinkedTo"),
		PosOffsetX = config:GetAttribute("PosOffsetXLinkedTo"), PosOffsetY = config:GetAttribute("PosOffsetYLinkedTo"), PosOffsetZ = config:GetAttribute("PosOffsetZLinkedTo"),
		RotX = config:GetAttribute("RotXLinkedTo"), RotY = config:GetAttribute("RotYLinkedTo"), RotZ = config:GetAttribute("RotZLinkedTo"),
		PosX = config:GetAttribute("PosXLinkedTo"), PosY = config:GetAttribute("PosYLinkedTo"), PosZ = config:GetAttribute("PosZLinkedTo"),
	}
	return AxisLinksMod.sanitize(raw)
end

--[[
	将 GetData mixin 挂到 Particle 主表
	@param Particle table - PartIcles 运行时主表（将获得 :GetData）
]]
return function(Particle)

--[[
	把已 Transform 实例的配置读成扁平 data 表；Emit / Update 只读这份快照
	@param item Instance - 源发射器（需有 PartIcleProperties）
	@return table? - 扁平配置：EmitParent / Link / LinkMode / Events / 类型相关图与范围等；未 Transform 为 nil
]]
function Particle:GetData(item)
	local data = {}

	local config = TypeRegistry.getConfig(item)
	if not config then return nil end

	local ep = item:FindFirstChild("EmitParent")
	data.EmitParent = ep and ep:IsA("ObjectValue") and ep.Value or nil

	-- LinkSource (None / Camera / Object) picks what; LinkMode (Weld / Follow / Pivot) picks how.
	local lk = item:FindFirstChild("Link")
	local linkedInst = lk and lk:IsA("ObjectValue") and lk.Value or nil
	local linkSource = item:GetAttribute("LinkSource")
	if not linkSource then linkSource = linkedInst and "Object" or "None" end
	if linkSource == "Camera" then
		data.Link = workspace.CurrentCamera
	elseif linkSource == "Object" then
		data.Link = linkedInst
	else
		data.Link = nil
	end
	data.LinkMode = item:GetAttribute("LinkMode") or "Follow"

	data.RenderTemplate = item:FindFirstChild("RenderTemplate")

	-- Events snapshot frozen at emit; runtime fire reads only this, never live cfg.
	data.Events = EventsSchema.readEnabled(item)

	local tkf = config:GetAttribute("TotalKeyFrames") or 0
	data.TotalKeyFrames = tkf > 0 and tkf or 100

	data.CheckEnabled = function() return config.Parent ~= nil and config:GetAttribute("Enabled") == true end

	-- MODEL
	if item:IsA("Model") then
		data.PartLife = config:GetAttribute("PartLife") or 0
		data.DirMode = config:GetAttribute("DirMode") or ((config:GetAttribute("VelocityVectored") and "Local") or "RigidLocal")
		data.VelocityVectored = (data.DirMode == "Local")
		data.InvertMotion = config:GetAttribute("InvertMotion") or false
		data.RotMode = config:GetAttribute("RotMode") or "OverLife"
		data.RotOrder = config:GetAttribute("RotOrder") or "Global"
		data.Lifetime = config:GetAttribute("Lifetime") or NumberRange.new(1)
		data.Rate = config:GetAttribute("Rate") or 10

		data.EmissionDirection = _safeEnum(Enum.NormalId, config:GetAttribute("EmissionDirection"), Enum.NormalId.Top)

		data.ParticleData = {
			SpreadAngle = config:GetAttribute("SpreadAngle") or Vector2.new(0, 0),
			Acceleration = config:GetAttribute("Acceleration") or Vector3.new(0, 0, 0),
			Drag = config:GetAttribute("Drag") or 0,
		}

		data.Speed = config:GetAttribute("Speed")
		data.Scale = config:GetAttribute("Scale")
		data.Timescale = config:GetAttribute("Timescale")

		data.RotX = config:GetAttribute("RotX") or NumberRange.new(0)
		data.RotY = config:GetAttribute("RotY") or NumberRange.new(0)
		data.RotZ = config:GetAttribute("RotZ") or NumberRange.new(0)
		data.RotXEven = config:GetAttribute("RotXEven") == true
		data.RotYEven = config:GetAttribute("RotYEven") == true
		data.RotZEven = config:GetAttribute("RotZEven") == true

		data.PosX = config:GetAttribute("PosX") or NumberRange.new(0)
		data.PosY = config:GetAttribute("PosY") or NumberRange.new(0)
		data.PosZ = config:GetAttribute("PosZ") or NumberRange.new(0)
		data.PosXEven = config:GetAttribute("PosXEven") == true
		data.PosYEven = config:GetAttribute("PosYEven") == true
		data.PosZEven = config:GetAttribute("PosZEven") == true
		data.PosMode = config:GetAttribute("PosMode") or "Local"
		data.DisplacementMode = config:GetAttribute("DisplacementMode") or "Global"

		data.RotSpeedX = config:GetAttribute("RotSpeedX")
		data.RotSpeedY = config:GetAttribute("RotSpeedY")
		data.RotSpeedZ = config:GetAttribute("RotSpeedZ")

		data.PosOffsetX = config:GetAttribute("PosOffsetX")
		data.PosOffsetY = config:GetAttribute("PosOffsetY")
		data.PosOffsetZ = config:GetAttribute("PosOffsetZ")

		data.Orientation = config:GetAttribute("Orientation") or "None"
		data.ZOffset = config:GetAttribute("ZOffset") or 0

		data.AxisLinks = _readAxisLinks(config)
		data.Pool = config:GetAttribute("Pool")
		-- Gates descendant Beam's TextureLength * pFactor in UpdateBeam (parent-scale block).
		data.ScaleTextureLength = config:GetAttribute("ScaleTextureLength")
		-- Nested-particle motion scaling. ScaleMotion default true (~= false); ScaleRotation
		-- default false (== true). Carried into parentScaleInfo for nested particles to read.
		data.ScaleMotion = config:GetAttribute("ScaleMotion") ~= false
		data.ScaleRotation = config:GetAttribute("ScaleRotation") == true

		return data
	end

	-- BLUR
	if item:IsA("BlurEffect") then
		data.PartLife = config:GetAttribute("PartLife") or 0
		data.Lifetime = config:GetAttribute("Lifetime") or NumberRange.new(1)
		data.Rate = config:GetAttribute("Rate") or 10
		data.BlurSize = config:GetAttribute("BlurSize")
		data.Timescale = config:GetAttribute("Timescale")
		return data
	end

	-- BLOOM
	if item:IsA("BloomEffect") then
		data.PartLife = config:GetAttribute("PartLife") or 0
		data.Lifetime = config:GetAttribute("Lifetime") or NumberRange.new(1)
		data.Rate = config:GetAttribute("Rate") or 10
		data.BloomIntensity = config:GetAttribute("BloomIntensity")
		data.BloomSize = config:GetAttribute("BloomSize")
		data.BloomThreshold = config:GetAttribute("BloomThreshold")
		data.Timescale = config:GetAttribute("Timescale")
		return data
	end

	-- COLOR CORRECTION
	if item:IsA("ColorCorrectionEffect") then
		data.PartLife = config:GetAttribute("PartLife") or 0
		data.Lifetime = config:GetAttribute("Lifetime") or NumberRange.new(1)
		data.Rate = config:GetAttribute("Rate") or 10
		data.CCBrightness = config:GetAttribute("CCBrightness")
		data.CCContrast = config:GetAttribute("CCContrast")
		data.CCSaturation = config:GetAttribute("CCSaturation")
		data.CCTintColor = config:GetAttribute("CCTintColor")
		data.Timescale = config:GetAttribute("Timescale")
		return data
	end

	-- ATMOSPHERE
	if item:IsA("Atmosphere") then
		data.PartLife = config:GetAttribute("PartLife") or 0
		data.Lifetime = config:GetAttribute("Lifetime") or NumberRange.new(1)
		data.Rate = config:GetAttribute("Rate") or 10
		data.AtmDensity = config:GetAttribute("AtmDensity")
		data.AtmOffset = config:GetAttribute("AtmOffset")
		data.AtmGlare = config:GetAttribute("AtmGlare")
		data.AtmHaze = config:GetAttribute("AtmHaze")
		data.AtmColor = config:GetAttribute("AtmColor")
		data.AtmDecay = config:GetAttribute("AtmDecay")
		data.AtmTimescale = config:GetAttribute("AtmTimescale")
		return data
	end

	-- IMAGE LABEL
	if item:IsA("ImageLabel") then
		data.PartLife = config:GetAttribute("PartLife") or 0
		data.Lifetime = config:GetAttribute("Lifetime") or NumberRange.new(1)
		data.Rate = config:GetAttribute("Rate") or 10
		data.ImageTransparency      = config:GetAttribute("ImageTransparency")
		data.BackgroundTransparency = config:GetAttribute("BackgroundTransparency")
		data.ImgSpeed               = config:GetAttribute("ImgSpeed")
		data.SizeScaleX             = config:GetAttribute("SizeScaleX")
		data.SizeScaleY             = config:GetAttribute("SizeScaleY")
		data.ImgRotRange            = config:GetAttribute("ImgRotRange") or NumberRange.new(0)
		data.ImgRotSpeed            = config:GetAttribute("ImgRotSpeed")
		data.ImgRotMode             = config:GetAttribute("ImgRotMode") or "OverLife"
		data.ImageColor3       = config:GetAttribute("ImageColor3")
		data.BackgroundColor3  = config:GetAttribute("BackgroundColor3")
		data.Image             = config:GetAttribute("Image") or ""
		data.ImgPosition       = config:GetAttribute("Position") or UDim2.fromScale(0.5, 0.5)
		data.ImgSizeUDim       = config:GetAttribute("ImgSize") or UDim2.fromOffset(100, 100)
		data.ImgAnchorPoint    = config:GetAttribute("AnchorPoint") or Vector2.new(0.5, 0.5)
		data.ImgZIndex         = config:GetAttribute("ZIndex") or 1
		data.ImgScaleType      = _safeEnum(Enum.ScaleType, config:GetAttribute("ScaleType"), Enum.ScaleType.Stretch)
		data.ImgResampleMode   = _safeEnum(Enum.ResamplerMode, config:GetAttribute("ResampleMode"), Enum.ResamplerMode.Default)
		data.ImgEmissionAngle  = config:GetAttribute("EmissionAngle") or 90
		data.ImgSpreadAngle    = config:GetAttribute("ImgSpreadAngle") or 0
		data.ImgAcceleration   = config:GetAttribute("ImgAcceleration") or Vector2.new(0, 0)
		data.ImgDrag           = config:GetAttribute("ImgDrag") or 0
		data.ImgInvertMotion   = config:GetAttribute("ImgInvertMotion") or false
		-- FlipbookSource: Decals folder vs Spritesheet grid.
		data.ImgFlipbookSource      = config:GetAttribute("ImgFlipbookSource") or "Decals"
		data.ImgFlipbookMode = _safeEnum(Enum.ParticleFlipbookMode, config:GetAttribute("ImgFlipbookMode"), Enum.ParticleFlipbookMode.Loop)
		data.ImgFlipbookStartRandom = config:GetAttribute("ImgFlipbookStartRandom") or false
		-- Fallback values must match TypeDataScreen registry defaults.
		data.ImgGridCols            = config:GetAttribute("GridCols") or 8
		data.ImgGridRows            = config:GetAttribute("GridRows") or 1
		data.ImgFlipbookFramerate   = config:GetAttribute("ImgFlipbookFramerate") or NumberRange.new(10)
		data.ImgFlipbookReverse     = config:GetAttribute("ImgFlipbookReverse") or false
		-- Sheet dims stamped at edit time. Trust _SheetSize only when _SheetAsset matches current Image.
		local sSize = config:GetAttribute("_SheetSize")
		local sAsset = config:GetAttribute("_SheetAsset")
		local currentId = (type(data.Image) == "string") and (data.Image:match("rbxassetid://(%d+)") or data.Image:match("^(%d+)$")) or nil
		if typeof(sSize) == "Vector2" and sAsset and sAsset == currentId then data.SheetSize = sSize end
		data.ImageFlipbooks = item:FindFirstChild("ImageFlipbooks")
		data.ImgTimescale = config:GetAttribute("ImgTimescale")
		data.Pool = config:GetAttribute("Pool")
		return data
	end

	-- POINTLIGHT
	if item:IsA("PointLight") then
		data.PartLife = config:GetAttribute("PartLife") or 0
		data.Lifetime = config:GetAttribute("Lifetime") or NumberRange.new(1)
		data.Rate = config:GetAttribute("Rate") or 10
		data.PLRange = config:GetAttribute("PLRange")
		data.PLBrightness = config:GetAttribute("PLBrightness")
		data.PLColor = config:GetAttribute("PLColor")
		data.PLTimescale = config:GetAttribute("PLTimescale")
		data.Shadows = config:GetAttribute("Shadows")
		data.Pool = config:GetAttribute("Pool")
		return data
	end

	-- HIGHLIGHT  -  non-spatial, attached entity. Adornee resolved as ObjectValue child
	-- (falls back to source.Parent when unset). No Link / EmissionDirection / motion.
	if item:IsA("Highlight") then
		data.PartLife = config:GetAttribute("PartLife") or 0
		data.Lifetime = config:GetAttribute("Lifetime") or NumberRange.new(1)
		data.Rate = config:GetAttribute("Rate") or 10
		data.HLFillColor = config:GetAttribute("HLFillColor")
		data.HLFillTransparency = config:GetAttribute("HLFillTransparency")
		data.HLOutlineColor = config:GetAttribute("HLOutlineColor")
		data.HLOutlineTransparency = config:GetAttribute("HLOutlineTransparency")
		data.HLTimescale = config:GetAttribute("HLTimescale")
		data.HLDepthMode = _safeEnum(Enum.HighlightDepthMode, config:GetAttribute("HLDepthMode"), Enum.HighlightDepthMode.AlwaysOnTop)
		local adornee = item:FindFirstChild("Adornee")
		data.Adornee = adornee and adornee:IsA("ObjectValue") and adornee.Value or nil
		data.Pool = config:GetAttribute("Pool")
		return data
	end

	-- TRAILEMITTER  -  Trail with PartIcleProperties Configuration child (full particle pipeline).
	-- Discriminated from directAccess Trail by the config presence check above.
	if item:IsA("Trail") then
		data.PartLife = config:GetAttribute("PartLife") or 0
		data.Lifetime = config:GetAttribute("Lifetime") or NumberRange.new(2)
		data.Rate = config:GetAttribute("Rate") or 10
		data.TEmitTimescale = config:GetAttribute("TEmitTimescale")
		data.TEmitBrightness = config:GetAttribute("TEmitBrightness")
		data.TEmitLightEmission = config:GetAttribute("TEmitLightEmission")
		data.TEmitLightInfluence = config:GetAttribute("TEmitLightInfluence")
		data.TEmitTextureLength = config:GetAttribute("TEmitTextureLength")
		data.TEmitMinLength = config:GetAttribute("TEmitMinLength")
		data.TEmitMaxLength = config:GetAttribute("TEmitMaxLength")
		data.TrailLife = config:GetAttribute("TEmitTrailLife") or NumberRange.new(2)
		data.TrailFlipbookMode = _safeEnum(Enum.ParticleFlipbookMode, config:GetAttribute("TEmitFlipbookMode"), Enum.ParticleFlipbookMode.OneShot)
		data.TrailFlipbookFramerate = config:GetAttribute("TEmitFlipbookFramerate") or NumberRange.new(30)
		data.TrailFlipbookStartRandom = config:GetAttribute("TEmitFlipbookStartRandom")
		data.TrailFlipbookReverse = config:GetAttribute("TEmitFlipbookReverse")
		data.TrailFlipbooks = item:FindFirstChild("TrailFlipbooks")
		-- Texture / TextureMode / FaceCamera live on the cloned RT directly; no Configuration mirror.
		data.GraphBlender = item:FindFirstChild("GraphBlender")
		data.Pool = config:GetAttribute("Pool")
		return data
	end

	-- ATTACHMENT
	if item:IsA("Attachment") then
		data.PartLife = config:GetAttribute("PartLife") or 0
		data.DirMode = config:GetAttribute("DirMode") or ((config:GetAttribute("VelocityVectored") and "Local") or "RigidLocal")
		data.VelocityVectored = (data.DirMode == "Local")
		data.InvertMotion = config:GetAttribute("InvertMotion") or false
		data.RotMode = config:GetAttribute("RotMode") or "OverLife"
		data.RotOrder = config:GetAttribute("RotOrder") or "Global"
		data.Lifetime = config:GetAttribute("Lifetime") or NumberRange.new(1)
		data.Rate = config:GetAttribute("Rate") or 10

		data.EmissionDirection = _safeEnum(Enum.NormalId, config:GetAttribute("EmissionDirection"), Enum.NormalId.Top)

		data.ParticleData = {
			SpreadAngle = config:GetAttribute("SpreadAngle") or Vector2.new(0, 0),
			Acceleration = config:GetAttribute("Acceleration") or Vector3.new(0, 0, 0),
			Drag = config:GetAttribute("Drag") or 0,
		}

		data.Speed = config:GetAttribute("Speed")
		data.Timescale = config:GetAttribute("Timescale")

		data.RotX = config:GetAttribute("RotX") or NumberRange.new(0)
		data.RotY = config:GetAttribute("RotY") or NumberRange.new(0)
		data.RotZ = config:GetAttribute("RotZ") or NumberRange.new(0)
		data.RotXEven = config:GetAttribute("RotXEven") == true
		data.RotYEven = config:GetAttribute("RotYEven") == true
		data.RotZEven = config:GetAttribute("RotZEven") == true

		data.PosX = config:GetAttribute("PosX") or NumberRange.new(0)
		data.PosY = config:GetAttribute("PosY") or NumberRange.new(0)
		data.PosZ = config:GetAttribute("PosZ") or NumberRange.new(0)
		data.PosXEven = config:GetAttribute("PosXEven") == true
		data.PosYEven = config:GetAttribute("PosYEven") == true
		data.PosZEven = config:GetAttribute("PosZEven") == true
		data.PosMode = config:GetAttribute("PosMode") or "Local"
		data.DisplacementMode = config:GetAttribute("DisplacementMode") or "Global"

		data.RotSpeedX = config:GetAttribute("RotSpeedX")
		data.RotSpeedY = config:GetAttribute("RotSpeedY")
		data.RotSpeedZ = config:GetAttribute("RotSpeedZ")

		data.PosOffsetX = config:GetAttribute("PosOffsetX")
		data.PosOffsetY = config:GetAttribute("PosOffsetY")
		data.PosOffsetZ = config:GetAttribute("PosOffsetZ")

		data.Orientation = config:GetAttribute("Orientation") or "None"
		data.ZOffset = config:GetAttribute("ZOffset") or 0

		data.AxisLinks = _readAxisLinks(config)
		data.Pool = config:GetAttribute("Pool")

		return data
	end

	data.PartLife = config:GetAttribute("PartLife") or 0

	-- BEAM
	if item:IsA("Beam") then
		data.GraphBlender = item:FindFirstChild("GraphBlender")
		data.Lifetime = config:GetAttribute("BeamLifetime") or NumberRange.new(1)
		data.Rate = config:GetAttribute("Rate") or 10

		data.BeamFlipbooks = item:FindFirstChild("BeamFlipbooks")
		data.FlipbookParticle = {
			FlipbookMode = _safeEnum(Enum.ParticleFlipbookMode, config:GetAttribute("BeamFlipbookMode"), nil),
			FlipbookFramerate = config:GetAttribute("BeamFlipbookFramerate") or nil,
			FlipbookStartRandom = config:GetAttribute("BeamFlipbookStartRandom") or false,
			FlipbookReverse = config:GetAttribute("BeamFlipbookReverse") or false,
		}

		if data.BeamFlipbooks then
			data.CachedBeamTextures = MeshFlipMod.GetSortedBeamTextures(data.BeamFlipbooks)
		end

		data.FaceCamera = config:GetAttribute("FaceCamera")
		data.ZOffset = config:GetAttribute("ZOffset")
		data.TextureMode = _safeEnum(Enum.TextureMode, config:GetAttribute("BeamTextureMode"), nil)
		data.BeamProps = {
			Brightness = config:GetAttribute("BeamBrightness"),
			CurveSize0 = config:GetAttribute("CurveSize0"),
			CurveSize1 = config:GetAttribute("CurveSize1"),
			Width0 = config:GetAttribute("Width0"),
			Width1 = config:GetAttribute("Width1"),
			LightEmission = config:GetAttribute("LightEmission"),
			LightInfluence = config:GetAttribute("BeamLightInfluence"),
			Segments = config:GetAttribute("Segments"),
			TextureLength = config:GetAttribute("TextureLength"),
			TextureSpeed = config:GetAttribute("TextureSpeed"),
		}
		data.BeamTimescale = config:GetAttribute("BeamTimescale")
		data.Pool = config:GetAttribute("Pool")
		return data
	end

	-- PART (default)
	data.MeshFlipbooks = item:FindFirstChild("MeshFlipbooks")
	if data.MeshFlipbooks then
		data.CachedMeshTextures = MeshFlipMod.GetSortedTextures(data.MeshFlipbooks)
	end

	data.DirMode = config:GetAttribute("DirMode") or ((config:GetAttribute("VelocityVectored") and "Local") or "RigidLocal")
	data.VelocityVectored = (data.DirMode == "Local")
	data.InvertMotion = config:GetAttribute("InvertMotion") or false
	data.RotMode = config:GetAttribute("RotMode") or "OverLife"
	data.RotOrder = config:GetAttribute("RotOrder") or "Global"
	data.Lifetime = config:GetAttribute("Lifetime") or NumberRange.new(1)
	data.Rate = config:GetAttribute("Rate") or 10

	-- Target acceleration: AccelTarget readable types match getTargetPosition's dispatch
	-- (BasePart, Attachment, Camera, Model via GetPivot, Bone via TransformedWorldCFrame).
	data.AccelerationTowardsInstance = config:GetAttribute("AccelerationTowardsInstance") or false
	data.AccelStrength = config:GetAttribute("AccelStrength") or NumberSequence.new(0)
	do
		local at = item:FindFirstChild("AccelTarget")
		local picked = at and at:IsA("ObjectValue") and at.Value or nil
		if picked and (picked:IsA("BasePart") or picked:IsA("Attachment") or picked:IsA("Camera") or picked:IsA("Model") or picked:IsA("Bone")) then
			data.AccelTarget = picked
		else
			data.AccelTarget = nil
		end
	end
	-- ShapePart override (Part with UseShape=true): if set, particles sample shape volume
	-- + spawn at this BasePart's CFrame instead of the source's. nil = source fallback.
	do
		local sp = item:FindFirstChild("ShapePart")
		local picked = sp and sp:IsA("ObjectValue") and sp.Value or nil
		if picked and picked:IsA("BasePart") and picked.Parent then
			data.ShapePart = picked
		else
			data.ShapePart = nil
		end
	end

	data.Shape = _safeEnum(Enum.ParticleEmitterShape, config:GetAttribute("Shape"), Enum.ParticleEmitterShape.Box)
	data.ShapeInOut = _safeEnum(Enum.ParticleEmitterShapeInOut, config:GetAttribute("ShapeInOut"), Enum.ParticleEmitterShapeInOut.Outward)
	data.EmissionDirection = _safeEnum(Enum.NormalId, config:GetAttribute("EmissionDirection"), Enum.NormalId.Top)
	data.UseShape = config:GetAttribute("UseShape") == true
	data.LookAtInitially = config:GetAttribute("LookAtInitially") == true

	data.ParticleData = {
		Shape = data.Shape,
		ShapeInOut = data.ShapeInOut,
		ShapePartial = math.clamp(config:GetAttribute("ShapePartial") or 0, 0, 1),
		UseShape = data.UseShape,
		LookAtInitially = data.LookAtInitially,
		EmissionDirection = data.EmissionDirection,
		SpreadAngle = config:GetAttribute("SpreadAngle") or Vector2.new(0, 0),
		Acceleration = config:GetAttribute("Acceleration") or Vector3.new(0, 0, 0),
		Drag = config:GetAttribute("Drag") or 0,
		FlipbookMode = _safeEnum(Enum.ParticleFlipbookMode, config:GetAttribute("FlipbookMode"), nil),
		FlipbookFramerate = config:GetAttribute("FlipbookFramerate") or nil,
		FlipbookStartRandom = config:GetAttribute("FlipbookStartRandom") or false,
		FlipbookReverse = config:GetAttribute("FlipbookReverse") or false,
	}

	data.Transparency = config:GetAttribute("Transparency")
	data.Color = config:GetAttribute("Color")
	data.Speed = config:GetAttribute("Speed")
	data.Brightness = config:GetAttribute("Brightness")
	data.Timescale = config:GetAttribute("Timescale")

	data.AxisLinks = _readAxisLinks(config)

	data.SizeX = config:GetAttribute("SizeX")
	data.SizeY = config:GetAttribute("SizeY")
	data.SizeZ = config:GetAttribute("SizeZ")

	data.RotX = config:GetAttribute("RotX") or NumberRange.new(0)
	data.RotY = config:GetAttribute("RotY") or NumberRange.new(0)
	data.RotZ = config:GetAttribute("RotZ") or NumberRange.new(0)
	data.RotXEven = config:GetAttribute("RotXEven") == true
	data.RotYEven = config:GetAttribute("RotYEven") == true
	data.RotZEven = config:GetAttribute("RotZEven") == true

	data.PosX = config:GetAttribute("PosX") or NumberRange.new(0)
	data.PosY = config:GetAttribute("PosY") or NumberRange.new(0)
	data.PosZ = config:GetAttribute("PosZ") or NumberRange.new(0)
	data.PosXEven = config:GetAttribute("PosXEven") == true
	data.PosYEven = config:GetAttribute("PosYEven") == true
	data.PosZEven = config:GetAttribute("PosZEven") == true
	data.PosMode = config:GetAttribute("PosMode") or "Local"
	data.DisplacementMode = config:GetAttribute("DisplacementMode") or "Global"

	data.RotSpeedX = config:GetAttribute("RotSpeedX")
	data.RotSpeedY = config:GetAttribute("RotSpeedY")
	data.RotSpeedZ = config:GetAttribute("RotSpeedZ")

	data.PosOffsetX = config:GetAttribute("PosOffsetX")
	data.PosOffsetY = config:GetAttribute("PosOffsetY")
	data.PosOffsetZ = config:GetAttribute("PosOffsetZ")

	data.Orientation = config:GetAttribute("Orientation") or "None"
	data.ZOffset = config:GetAttribute("ZOffset") or 0

	data.Pool = config:GetAttribute("Pool")

	return data
end

end
