--[[
	Module: TypeData
	Description: Part-Icles 三维/工作区类型的属性描述表（Part / Beam / PointLight / Attachment / Model / Trail）；屏幕类型见 TypeDataScreen
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-09-01

	纯数据表，无函数。属性条目：{ type, default, attrName?, enumType?, nonNegative?, attribute? }
	  attrName    Configuration 属性名覆盖（避免与原生属性撞名）
	  enumType    Roblox Enum 分类名（type="enum" 时必填）
	  nonNegative 写入时将 NumberSequence 关键点钳到 >= 0
	  attribute   仅 directAccess：存实例 Attribute 而非属性
]]

local TypeData = {}
local ScreenData = require(script.Parent.TypeDataScreen)

TypeData.PartProperties = {
	-- Graph properties (NumberSequence)
	Brightness    = { type = "NumberSequence", default = NumberSequence.new(1) },
	Color         = { type = "ColorSequence", default = ColorSequence.new(Color3.new(1,1,1)) },
	SizeX         = { type = "NumberSequence", default = NumberSequence.new(1), nonNegative = true },
	SizeY         = { type = "NumberSequence", default = NumberSequence.new(1), nonNegative = true },
	SizeZ         = { type = "NumberSequence", default = NumberSequence.new(1), nonNegative = true },
	Transparency  = { type = "NumberSequence", default = NumberSequence.new(0) },
	Speed         = { type = "NumberSequence", default = NumberSequence.new(0) },
	-- Per-axis position offset graphs over normalized life (studs, spawn-local frame).
	-- Trajectory shape, distinct from emit-time PosX/Y/Z NumberRange spreads below.
	-- Composed ADDITIVELY with Speed × Direction via per-frame delta accumulation.
	PosOffsetX    = { type = "NumberSequence", default = NumberSequence.new(0) },
	PosOffsetY    = { type = "NumberSequence", default = NumberSequence.new(0) },
	PosOffsetZ    = { type = "NumberSequence", default = NumberSequence.new(0) },
	RotSpeedX     = { type = "NumberSequence", default = NumberSequence.new(0) },
	RotSpeedY     = { type = "NumberSequence", default = NumberSequence.new(0) },
	RotSpeedZ     = { type = "NumberSequence", default = NumberSequence.new(0) },
	-- Timescale graph: scales per-frame elapsed-time advancement. Default constant 1
	-- means real-time playback. <1 slows, 0 freezes, >1 speeds up, NEGATIVE rewinds (v2).
	-- Sampled at REAL normalized time `(now - StartTime) / LifeTime` so the graph
	-- progresses monotonically through its keypoints regardless of which direction
	-- the particle's effective time is moving. Initial `_effectiveElapsed` depends on
	-- the graph's value at i=0: ts(0) >= 0 → particle starts at 0 and plays forward;
	-- ts(0) < 0 → particle starts at LifeTime (end-state visual) and rewinds to 0.
	-- This is what makes a STATIC `Timescale = -1` produce end-to-start playback.
	-- Runtime: `dt *= ts(real_i)`, `_effectiveElapsed += dt` clamped to [0, LifeTime].
	-- Death rule: ONLY after the graph has finished playing (real_i >= 1) does a
	-- boundary cross (effective hit 0 or LifeTime) trigger death. During graph
	-- playback the particle bounces freely between bounds  -  users can author graphs
	-- that overshoot either bound without prematurely killing the particle. Sticky-
	-- zero post-graph (last-keypoint ts == 0 + effective stuck mid-life) is
	-- documented user error: no real-time cap, particle leaks the slot.
	Timescale     = { type = "NumberSequence", default = NumberSequence.new(1) },

	-- Non-graph properties
	Lifetime          = { type = "NumberRange",  default = NumberRange.new(1) },
	Rate              = { type = "number",       default = 10 },
	Drag              = { type = "number",       default = 0 },
	Acceleration      = { type = "Vector3",      default = Vector3.new(0, 0, 0) },
	SpreadAngle       = { type = "Vector2",      default = Vector2.new(0, 0) },
	RotX              = { type = "NumberRange",   default = NumberRange.new(0) },
	RotY              = { type = "NumberRange",   default = NumberRange.new(0) },
	RotZ              = { type = "NumberRange",   default = NumberRange.new(0) },
	PosX              = { type = "NumberRange",   default = NumberRange.new(0) },
	PosY              = { type = "NumberRange",   default = NumberRange.new(0) },
	PosZ              = { type = "NumberRange",   default = NumberRange.new(0) },
	PosMode           = { type = "string",       default = "Local" },
	RotMode           = { type = "string",       default = "OverLife" },
	RotOrder          = { type = "string",       default = "Global" },
	TotalKeyFrames    = { type = "number",       default = 100 },
	PartLife          = { type = "number",       default = 0, nonNegative = true },
	ShapePartial      = { type = "number",       default = 0 },
	VelocityVectored  = { type = "boolean",      default = false },
	DirMode           = { type = "string",       default = "RigidLocal" },
	-- Frame for PosOffsetX/Y/Z over-life graphs. Mirrors DirMode's role for
	-- Speed but applied to displacement-through-life instead of velocity.
	-- Global = world axes; Local = particle's spawn frame (post-RotXYZ);
	-- RigidLocal = emitter's frame at spawn (pre-RotXYZ).
	DisplacementMode  = { type = "string",       default = "Global" },
	InvertMotion      = { type = "boolean",      default = false },
	Enabled           = { type = "boolean",      default = false },

	-- Target acceleration. AccelerationTowardsInstance gates the AccelStrength + AccelTarget pair.
	-- AccelStrength is a non-negative scalar magnitude over normalized particle lifetime.
	-- AccelTarget is the picked instance (stored as ObjectValue child, not attribute -- see Transform).
	AccelerationTowardsInstance = { type = "boolean",        default = false },
	AccelStrength               = { type = "NumberSequence", default = NumberSequence.new(0), nonNegative = true },

	-- Axis links: per-axis "LinkedTo" attribute names the primary axis whose graph + seed (or
	-- per-emit sampled range value) the follower axis should adopt. Stored as full property
	-- keys (e.g. SizeYLinkedTo = "SizeX"). Registered here so QOL snapshot/Migrate see them.
	-- Default "" means unlinked; GetData sanitizes empty/invalid values to nil. Clipboard
	-- companion-copy (auto-include LinkedTo when its primary axis is copied) is a separate
	-- piece of work  -  registration alone does not make per-prop clipboard preserve them.
	SizeXLinkedTo        = { type = "string", default = "" },
	SizeYLinkedTo        = { type = "string", default = "" },
	SizeZLinkedTo        = { type = "string", default = "" },
	RotSpeedXLinkedTo    = { type = "string", default = "" },
	RotSpeedYLinkedTo    = { type = "string", default = "" },
	RotSpeedZLinkedTo    = { type = "string", default = "" },
	PosOffsetXLinkedTo   = { type = "string", default = "" },
	PosOffsetYLinkedTo   = { type = "string", default = "" },
	PosOffsetZLinkedTo   = { type = "string", default = "" },
	RotXLinkedTo         = { type = "string", default = "" },
	RotYLinkedTo         = { type = "string", default = "" },
	RotZLinkedTo         = { type = "string", default = "" },
	PosXLinkedTo         = { type = "string", default = "" },
	PosYLinkedTo         = { type = "string", default = "" },
	PosZLinkedTo         = { type = "string", default = "" },
	-- EvenDistribution: per-axis toggle. When true + EmitIndex/EmitCount in emitCtx,
	-- the axis samples a deterministic spread across [Min, Max] instead of random.
	-- EnableEmit batches use the natural EmitCount; rate-mode emits use a per-property
	-- rolling cycle (PositionEvenCycle / RotationEvenCycle) per Lifecycle.luau loopBody.
	-- Linked followers inherit the primary's spread scalar via AxisLinks.sampleRangeAxes.
	RotXEven             = { type = "boolean", default = false },
	RotYEven             = { type = "boolean", default = false },
	RotZEven             = { type = "boolean", default = false },
	PosXEven             = { type = "boolean", default = false },
	PosYEven             = { type = "boolean", default = false },
	PosZEven             = { type = "boolean", default = false },
	-- Per-property rolling-cycle length for rate-mode EvenDistribution. NumberRange
	-- sampled at every cycle wrap. Sign = direction (+ forward, - reverse). 0 or
	-- default zero-range → fall back to current cfg.Rate (forward).
	PositionEvenCycle    = { type = "NumberRange", default = NumberRange.new(0) },
	RotationEvenCycle    = { type = "NumberRange", default = NumberRange.new(0) },

	-- Master gate: when true, the shape function runs at emit time and contributes
	-- offset / rotation / direction. When false, particles emit at the item's origin
	-- with no shape distribution.
	UseShape           = { type = "boolean", default = false },
	-- When true, the shape function's natural lookAt rotation (CFrame.lookAt(0, -dirVec))
	-- is applied to each spawned particle so they face the radial outward of the shape.
	-- When false, particles inherit only the emitter's rotation. ShapePartial (Hollow)
	-- separately controls volume vs shell distribution; this is purely an orientation knob.
	LookAtInitially    = { type = "boolean", default = false },
	-- Enum properties (stored as string Name)
	Shape              = { type = "enum", enumType = "ParticleEmitterShape",        default = Enum.ParticleEmitterShape.Box },
	ShapeInOut         = { type = "enum", enumType = "ParticleEmitterShapeInOut",    default = Enum.ParticleEmitterShapeInOut.Outward },
	EmissionDirection  = { type = "enum", enumType = "NormalId",                     default = Enum.NormalId.Top },
	Orientation        = { type = "string", default = "None" },
	ZOffset            = { type = "number", default = 0 },

	-- Flipbook
	FlipbookMode         = { type = "enum", enumType = "ParticleFlipbookMode", default = Enum.ParticleFlipbookMode.OneShot },
	FlipbookFramerate    = { type = "NumberRange", default = NumberRange.new(30) },
	FlipbookStartRandom  = { type = "boolean",     default = false },
	FlipbookReverse      = { type = "boolean",     default = false },

	Pool                 = { type = "boolean",     default = false },
}

TypeData.BeamProperties = {
	-- Graph properties (NumberSequence)
	Brightness    = { type = "NumberSequence", default = NumberSequence.new(1),    attrName = "BeamBrightness", nonNegative = true },
	Width0        = { type = "NumberSequence", default = NumberSequence.new(1),    nonNegative = true },
	Width1        = { type = "NumberSequence", default = NumberSequence.new(1),    nonNegative = true },
	CurveSize0    = { type = "NumberSequence", default = NumberSequence.new(0) },
	CurveSize1    = { type = "NumberSequence", default = NumberSequence.new(0) },
	LightEmission  = { type = "NumberSequence", default = NumberSequence.new(0) },
	-- Plugin expects unlit beams. Roblox's native Beam default is 1 (lit) but the
	-- Transform / RenderTemplate path forces 0; mirror that here so EmitBeam's
	-- config readback agrees.
	LightInfluence = { type = "NumberSequence", default = NumberSequence.new(0), attrName = "BeamLightInfluence" },
	Segments      = { type = "NumberSequence", default = NumberSequence.new(10) },
	TextureLength = { type = "NumberSequence", default = NumberSequence.new(1) },
	TextureSpeed  = { type = "NumberSequence", default = NumberSequence.new(1) },
	-- Timescale: see PartProperties for full semantics. Beam is continuous-time so
	-- the effective elapsed accumulator drives both GraphBlender state lerp and the
	-- per-frame property samples uniformly.
	Timescale     = { type = "NumberSequence", default = NumberSequence.new(1), attrName = "BeamTimescale" },

	-- Non-graph properties
	Lifetime          = { type = "NumberRange",  default = NumberRange.new(1),  attrName = "BeamLifetime" },
	Rate              = { type = "number",       default = 10 },
	TotalKeyFrames    = { type = "number",       default = 100 },
	Enabled           = { type = "boolean",      default = false },
	FaceCamera        = { type = "boolean",      default = false },
	ZOffset           = { type = "number",       default = 0 },
	TextureMode       = { type = "enum",         enumType = "TextureMode", default = Enum.TextureMode.Stretch, attrName = "BeamTextureMode" },

	-- Flipbook
	FlipbookMode         = { type = "enum",        enumType = "ParticleFlipbookMode", default = Enum.ParticleFlipbookMode.OneShot, attrName = "BeamFlipbookMode" },
	FlipbookFramerate    = { type = "NumberRange",  default = NumberRange.new(30), attrName = "BeamFlipbookFramerate" },
	FlipbookStartRandom  = { type = "boolean",      default = false,               attrName = "BeamFlipbookStartRandom" },
	FlipbookReverse      = { type = "boolean",      default = false,               attrName = "BeamFlipbookReverse" },

	Pool                 = { type = "boolean",      default = false },
}

-- Screen-type property tables (Blur/Bloom/CC/Atmosphere/ImageLabel) live in the TypeDataScreen
-- sub-module. Merged into TypeData.Types at the bottom.
TypeData.BlurProperties = ScreenData.BlurProperties
TypeData.BloomProperties = ScreenData.BloomProperties
TypeData.ColorCorrectionProperties = ScreenData.ColorCorrectionProperties
TypeData.AtmosphereProperties = ScreenData.AtmosphereProperties
TypeData.ImageLabelProperties = ScreenData.ImageLabelProperties

TypeData.PointLightProperties = {
	-- Graph properties
	Range      = { type = "NumberSequence", default = NumberSequence.new(8),  attrName = "PLRange",      nonNegative = true },
	Brightness = { type = "NumberSequence", default = NumberSequence.new(1),  attrName = "PLBrightness", nonNegative = true },
	Color      = { type = "ColorSequence", default = ColorSequence.new(Color3.new(1,1,1)), attrName = "PLColor" },
	-- Timescale: see PartProperties.
	Timescale  = { type = "NumberSequence", default = NumberSequence.new(1),  attrName = "PLTimescale" },

	-- Non-graph properties
	Lifetime       = { type = "NumberRange",  default = NumberRange.new(1) },
	Rate           = { type = "number",       default = 10 },
	TotalKeyFrames = { type = "number",       default = 100 },
	PartLife       = { type = "number",       default = 0, nonNegative = true },
	Enabled        = { type = "boolean",      default = false },
	Shadows        = { type = "boolean",      default = false },

	Pool           = { type = "boolean",      default = false },
}

-- Non-spatial emitter type (no Link / LinkSource / EmissionDirection / Orientation / ZOffset).
-- Cloned Highlight is parented to source; Adornee resolved per-emit via Adornee ObjectValue child
-- (falls back to source.Parent if unset). Graphs drive the 4 colour/transparency properties over Lifetime.
TypeData.HighlightProperties = {
	FillColor            = { type = "ColorSequence",  default = ColorSequence.new(Color3.new(1,1,1)), attrName = "HLFillColor" },
	FillTransparency     = { type = "NumberSequence", default = NumberSequence.new(0), attrName = "HLFillTransparency" },
	OutlineColor         = { type = "ColorSequence",  default = ColorSequence.new(Color3.new(1,1,1)), attrName = "HLOutlineColor" },
	OutlineTransparency  = { type = "NumberSequence", default = NumberSequence.new(0), attrName = "HLOutlineTransparency" },
	-- Timescale: see PartProperties.
	Timescale            = { type = "NumberSequence", default = NumberSequence.new(1), attrName = "HLTimescale" },

	Lifetime             = { type = "NumberRange",    default = NumberRange.new(1) },
	Rate                 = { type = "number",         default = 10 },
	TotalKeyFrames       = { type = "number",         default = 100 },
	PartLife             = { type = "number",         default = 0, nonNegative = true },
	DepthMode            = { type = "enum",           enumType = "HighlightDepthMode", default = Enum.HighlightDepthMode.AlwaysOnTop, attrName = "HLDepthMode" },
	Enabled              = { type = "boolean",        default = false },

	Pool                 = { type = "boolean",        default = false },
}

-- Trail emitter mode (post-"Transform as Emitter"): full particle pipeline. Differentiated from
-- directAccess Trail by presence of a PartIcleProperties Configuration child. Width / Transparency
-- / Color via TrailGraphBlender; other Trail props are NumberSequence graphs over Lifetime.
TypeData.TrailEmitterProperties = {
	-- Standard timing. Lifetime drives how long the emitter spawns particles for; TrailLife
	-- drives the cloned Trail's native .Lifetime (segment fade-out). Two values needed because
	-- a Trail particle is "alive" longer than its trail tail  -  emit a Trail that exists for
	-- Lifetime seconds, with each clone fading its own tail over TrailLife seconds.
	Lifetime       = { type = "NumberRange",    default = NumberRange.new(2) },
	TrailLife      = { type = "NumberRange",    default = NumberRange.new(2), attrName = "TEmitTrailLife" },
	Rate           = { type = "number",         default = 10 },
	TotalKeyFrames = { type = "number",         default = 100 },
	PartLife       = { type = "number",         default = 0, nonNegative = true },
	-- Timescale: see PartProperties.
	Timescale      = { type = "NumberSequence", default = NumberSequence.new(1), attrName = "TEmitTimescale" },

	-- Per-particle graphs (mutate the cloned Trail every frame).
	Brightness     = { type = "NumberSequence", default = NumberSequence.new(1),   attrName = "TEmitBrightness",     nonNegative = true },
	LightEmission  = { type = "NumberSequence", default = NumberSequence.new(0),   attrName = "TEmitLightEmission",  nonNegative = true },
	LightInfluence = { type = "NumberSequence", default = NumberSequence.new(1),   attrName = "TEmitLightInfluence", nonNegative = true },
	TextureLength  = { type = "NumberSequence", default = NumberSequence.new(1),   attrName = "TEmitTextureLength",  nonNegative = true },
	MinLength      = { type = "NumberSequence", default = NumberSequence.new(0.1), attrName = "TEmitMinLength",      nonNegative = true },
	MaxLength      = { type = "NumberSequence", default = NumberSequence.new(0),   attrName = "TEmitMaxLength",      nonNegative = true },

	-- Texture / TextureMode / FaceCamera live as native properties on the RenderTemplate child;
	-- UI writes go directly to RT instead of through a duplicate Configuration attribute.
	Enabled        = { type = "boolean", default = false },

	-- Flipbook (cycles `visual.Texture` through TrailFlipbooks/Decals over particle lifetime).
	TrailFlipbookMode        = { type = "enum",        enumType = "ParticleFlipbookMode", default = Enum.ParticleFlipbookMode.OneShot, attrName = "TEmitFlipbookMode" },
	TrailFlipbookFramerate   = { type = "NumberRange", default = NumberRange.new(30), attrName = "TEmitFlipbookFramerate" },
	TrailFlipbookStartRandom = { type = "boolean",     default = false, attrName = "TEmitFlipbookStartRandom" },
	TrailFlipbookReverse     = { type = "boolean",     default = false, attrName = "TEmitFlipbookReverse" },

	Pool           = { type = "boolean", default = false },
}

-- Native Beam (directAccess): edits the raw Beam instance, no PartIcleProperties / emit pipeline.
-- Differentiated from emitter Beam by absence of a PartIcleProperties Configuration child.
-- All properties map 1:1 to native Beam instance properties (read/write direct).
TypeData.BeamNativeProperties = {
	Transparency   = { type = "NumberSequence", default = NumberSequence.new(0) },
	Color          = { type = "ColorSequence",  default = ColorSequence.new(Color3.new(1,1,1)) },

	Brightness     = { type = "number", default = 1 },
	Width0         = { type = "number", default = 1, nonNegative = true },
	Width1         = { type = "number", default = 1, nonNegative = true },
	CurveSize0     = { type = "number", default = 0 },
	CurveSize1     = { type = "number", default = 0 },
	LightEmission  = { type = "number", default = 0 },
	LightInfluence = { type = "number", default = 0 },
	Segments       = { type = "number", default = 10, nonNegative = true },
	TextureLength  = { type = "number", default = 1 },
	TextureSpeed   = { type = "number", default = 1 },
	ZOffset        = { type = "number", default = 0 },

	Texture        = { type = "string",  default = "" },
	TextureMode    = { type = "enum",    enumType = "TextureMode", default = Enum.TextureMode.Stretch },
	FaceCamera     = { type = "boolean", default = false },
	Enabled        = { type = "boolean", default = true },
}

TypeData.TrailProperties = {
	-- Graph properties (native NumberSequence / ColorSequence on Trail instance)
	Transparency   = { type = "NumberSequence", default = NumberSequence.new(0.5) },
	WidthScale     = { type = "NumberSequence", default = NumberSequence.new(1), nonNegative = true },
	Color          = { type = "ColorSequence", default = ColorSequence.new(Color3.new(1,1,1)) },

	-- Number properties (native on Trail instance)
	Brightness     = { type = "number", default = 1 },
	LightEmission  = { type = "number", default = 0 },
	LightInfluence = { type = "number", default = 1 },
	TextureLength  = { type = "number", default = 1 },
	Lifetime       = { type = "number", default = 2 },
	MinLength      = { type = "number", default = 0.1 },
	MaxLength      = { type = "number", default = 0 },

	-- Emission timing (stored as attribute, supports "5,2" range string)
	Duration       = { type = "string", default = "2", attribute = true, attrName = "EmitDuration" },

	-- Boolean properties
	Enabled        = { type = "boolean", default = true },
	FaceCamera     = { type = "boolean", default = false },

	-- Enum
	TextureMode    = { type = "enum", enumType = "TextureMode", default = Enum.TextureMode.Stretch },
}

TypeData.AttachmentProperties = {
	-- Graph properties (NumberSequence)
	Speed         = { type = "NumberSequence", default = NumberSequence.new(0) },
	-- Over-life per-axis position offset graphs (see PartProperties for semantics).
	PosOffsetX    = { type = "NumberSequence", default = NumberSequence.new(0) },
	PosOffsetY    = { type = "NumberSequence", default = NumberSequence.new(0) },
	PosOffsetZ    = { type = "NumberSequence", default = NumberSequence.new(0) },
	RotSpeedX     = { type = "NumberSequence", default = NumberSequence.new(0) },
	RotSpeedY     = { type = "NumberSequence", default = NumberSequence.new(0) },
	RotSpeedZ     = { type = "NumberSequence", default = NumberSequence.new(0) },
	-- Timescale graph: scales per-frame elapsed-time advancement. Default constant 1
	-- means real-time playback. <1 slows, 0 freezes, >1 speeds up, NEGATIVE rewinds (v2).
	-- Sampled at REAL normalized time `(now - StartTime) / LifeTime` so the graph
	-- progresses monotonically through its keypoints regardless of which direction
	-- the particle's effective time is moving. Initial `_effectiveElapsed` depends on
	-- the graph's value at i=0: ts(0) >= 0 → particle starts at 0 and plays forward;
	-- ts(0) < 0 → particle starts at LifeTime (end-state visual) and rewinds to 0.
	-- This is what makes a STATIC `Timescale = -1` produce end-to-start playback.
	-- Runtime: `dt *= ts(real_i)`, `_effectiveElapsed += dt` clamped to [0, LifeTime].
	-- Death rule: ONLY after the graph has finished playing (real_i >= 1) does a
	-- boundary cross (effective hit 0 or LifeTime) trigger death. During graph
	-- playback the particle bounces freely between bounds  -  users can author graphs
	-- that overshoot either bound without prematurely killing the particle. Sticky-
	-- zero post-graph (last-keypoint ts == 0 + effective stuck mid-life) is
	-- documented user error: no real-time cap, particle leaks the slot.
	Timescale     = { type = "NumberSequence", default = NumberSequence.new(1) },

	-- Non-graph properties
	Lifetime          = { type = "NumberRange",  default = NumberRange.new(1) },
	Rate              = { type = "number",       default = 10 },
	Drag              = { type = "number",       default = 0 },
	Acceleration      = { type = "Vector3",      default = Vector3.new(0, 0, 0) },
	SpreadAngle       = { type = "Vector2",      default = Vector2.new(0, 0) },
	RotX              = { type = "NumberRange",   default = NumberRange.new(0) },
	RotY              = { type = "NumberRange",   default = NumberRange.new(0) },
	RotZ              = { type = "NumberRange",   default = NumberRange.new(0) },
	PosX              = { type = "NumberRange",   default = NumberRange.new(0) },
	PosY              = { type = "NumberRange",   default = NumberRange.new(0) },
	PosZ              = { type = "NumberRange",   default = NumberRange.new(0) },
	PosMode           = { type = "string",       default = "Local" },
	RotMode           = { type = "string",       default = "OverLife" },
	RotOrder          = { type = "string",       default = "Global" },
	TotalKeyFrames    = { type = "number",       default = 100 },
	PartLife          = { type = "number",       default = 0, nonNegative = true },
	VelocityVectored  = { type = "boolean",      default = false },
	DirMode           = { type = "string",       default = "RigidLocal" },
	DisplacementMode  = { type = "string",       default = "Global" },
	InvertMotion      = { type = "boolean",      default = false },
	Enabled           = { type = "boolean",      default = false },

	-- Enum properties (stored as string Name)
	EmissionDirection  = { type = "enum", enumType = "NormalId", default = Enum.NormalId.Top },
	Orientation        = { type = "string", default = "None" },
	ZOffset            = { type = "number", default = 0 },

	-- Axis links: default "" means unlinked; GetData sanitizes empty/invalid values to nil.
	-- Attachment has Rot/Pos/RotSpeed config rows but not Size, so Size*LinkedTo entries are
	-- omitted to keep the attribute count tight.
	RotSpeedXLinkedTo    = { type = "string", default = "" },
	RotSpeedYLinkedTo    = { type = "string", default = "" },
	RotSpeedZLinkedTo    = { type = "string", default = "" },
	PosOffsetXLinkedTo   = { type = "string", default = "" },
	PosOffsetYLinkedTo   = { type = "string", default = "" },
	PosOffsetZLinkedTo   = { type = "string", default = "" },
	RotXLinkedTo         = { type = "string", default = "" },
	RotYLinkedTo         = { type = "string", default = "" },
	RotZLinkedTo         = { type = "string", default = "" },
	PosXLinkedTo         = { type = "string", default = "" },
	PosYLinkedTo         = { type = "string", default = "" },
	PosZLinkedTo         = { type = "string", default = "" },
	-- EvenDistribution: per-axis toggle. When true + EmitIndex/EmitCount in emitCtx,
	-- the axis samples a deterministic spread across [Min, Max] instead of random.
	-- EnableEmit batches use the natural EmitCount; rate-mode emits use a per-property
	-- rolling cycle (PositionEvenCycle / RotationEvenCycle) per Lifecycle.luau loopBody.
	-- Linked followers inherit the primary's spread scalar via AxisLinks.sampleRangeAxes.
	RotXEven             = { type = "boolean", default = false },
	RotYEven             = { type = "boolean", default = false },
	RotZEven             = { type = "boolean", default = false },
	PosXEven             = { type = "boolean", default = false },
	PosYEven             = { type = "boolean", default = false },
	PosZEven             = { type = "boolean", default = false },
	-- Per-property rolling-cycle length for rate-mode EvenDistribution. NumberRange
	-- sampled at every cycle wrap. Sign = direction (+ forward, - reverse). 0 or
	-- default zero-range → fall back to current cfg.Rate (forward).
	PositionEvenCycle    = { type = "NumberRange", default = NumberRange.new(0) },
	RotationEvenCycle    = { type = "NumberRange", default = NumberRange.new(0) },

	Pool                 = { type = "boolean", default = false },
}

TypeData.ModelProperties = {
	-- Graph properties (NumberSequence)
	Speed         = { type = "NumberSequence", default = NumberSequence.new(0) },
	-- Over-life per-axis position offset graphs (see PartProperties for semantics).
	PosOffsetX    = { type = "NumberSequence", default = NumberSequence.new(0) },
	PosOffsetY    = { type = "NumberSequence", default = NumberSequence.new(0) },
	PosOffsetZ    = { type = "NumberSequence", default = NumberSequence.new(0) },
	RotSpeedX     = { type = "NumberSequence", default = NumberSequence.new(0) },
	RotSpeedY     = { type = "NumberSequence", default = NumberSequence.new(0) },
	RotSpeedZ     = { type = "NumberSequence", default = NumberSequence.new(0) },
	Scale         = { type = "NumberSequence", default = NumberSequence.new(1), nonNegative = true },
	-- Timescale: see PartProperties.
	Timescale     = { type = "NumberSequence", default = NumberSequence.new(1) },

	-- Non-graph properties
	Lifetime          = { type = "NumberRange",  default = NumberRange.new(1) },
	Rate              = { type = "number",       default = 10 },
	Drag              = { type = "number",       default = 0 },
	Acceleration      = { type = "Vector3",      default = Vector3.new(0, 0, 0) },
	SpreadAngle       = { type = "Vector2",      default = Vector2.new(0, 0) },
	RotX              = { type = "NumberRange",   default = NumberRange.new(0) },
	RotY              = { type = "NumberRange",   default = NumberRange.new(0) },
	RotZ              = { type = "NumberRange",   default = NumberRange.new(0) },
	PosX              = { type = "NumberRange",   default = NumberRange.new(0) },
	PosY              = { type = "NumberRange",   default = NumberRange.new(0) },
	PosZ              = { type = "NumberRange",   default = NumberRange.new(0) },
	PosMode           = { type = "string",       default = "Local" },
	RotMode           = { type = "string",       default = "OverLife" },
	RotOrder          = { type = "string",       default = "Global" },
	TotalKeyFrames    = { type = "number",       default = 100 },
	PartLife          = { type = "number",       default = 0, nonNegative = true },
	VelocityVectored  = { type = "boolean",      default = false },
	DirMode           = { type = "string",       default = "RigidLocal" },
	DisplacementMode  = { type = "string",       default = "Global" },
	InvertMotion      = { type = "boolean",      default = false },
	Enabled           = { type = "boolean",      default = false },
	-- When true, descendant Beam's TextureLength scales with the Model's Scale graph
	-- (preserves tile count as Beam grows). When false, TextureLength stays at authored
	-- value (tiles repeat more as Beam scales up). Default true preserves prior behavior.
	ScaleTextureLength = { type = "boolean",     default = true },
	-- Scale graph also scales nested-particle motion (Speed/Accel/PosOffset/Pos spread).
	-- Default true so a scaled Model's nested particles travel proportionally.
	ScaleMotion        = { type = "boolean",     default = true },
	-- Scale graph also scales nested-particle RotSpeed (angular → non-physical). Opt-in.
	ScaleRotation      = { type = "boolean",     default = false },

	-- Enum properties
	EmissionDirection  = { type = "enum", enumType = "NormalId", default = Enum.NormalId.Top },
	Orientation        = { type = "string", default = "None" },
	ZOffset            = { type = "number", default = 0 },

	-- Axis links: default "" means unlinked; GetData sanitizes empty/invalid values to nil.
	-- Model has Rot/Pos/RotSpeed config rows; Scale isn't axis-keyed so no link metadata.
	RotSpeedXLinkedTo    = { type = "string", default = "" },
	RotSpeedYLinkedTo    = { type = "string", default = "" },
	RotSpeedZLinkedTo    = { type = "string", default = "" },
	PosOffsetXLinkedTo   = { type = "string", default = "" },
	PosOffsetYLinkedTo   = { type = "string", default = "" },
	PosOffsetZLinkedTo   = { type = "string", default = "" },
	RotXLinkedTo         = { type = "string", default = "" },
	RotYLinkedTo         = { type = "string", default = "" },
	RotZLinkedTo         = { type = "string", default = "" },
	PosXLinkedTo         = { type = "string", default = "" },
	PosYLinkedTo         = { type = "string", default = "" },
	PosZLinkedTo         = { type = "string", default = "" },
	-- EvenDistribution: per-axis toggle. When true + EmitIndex/EmitCount in emitCtx,
	-- the axis samples a deterministic spread across [Min, Max] instead of random.
	-- EnableEmit batches use the natural EmitCount; rate-mode emits use a per-property
	-- rolling cycle (PositionEvenCycle / RotationEvenCycle) per Lifecycle.luau loopBody.
	-- Linked followers inherit the primary's spread scalar via AxisLinks.sampleRangeAxes.
	RotXEven             = { type = "boolean", default = false },
	RotYEven             = { type = "boolean", default = false },
	RotZEven             = { type = "boolean", default = false },
	PosXEven             = { type = "boolean", default = false },
	PosYEven             = { type = "boolean", default = false },
	PosZEven             = { type = "boolean", default = false },
	-- Per-property rolling-cycle length for rate-mode EvenDistribution. NumberRange
	-- sampled at every cycle wrap. Sign = direction (+ forward, - reverse). 0 or
	-- default zero-range → fall back to current cfg.Rate (forward).
	PositionEvenCycle    = { type = "NumberRange", default = NumberRange.new(0) },
	RotationEvenCycle    = { type = "NumberRange", default = NumberRange.new(0) },

	Pool                 = { type = "boolean", default = false },
}

TypeData.Types = {
	Part = {
		classCheck = function(item) return item:IsA("BasePart") end,
		pDataType = "Part",
		uiSection = "Meshes",
		properties = TypeData.PartProperties,

		resize = {
			scaleGraphs = { "SizeX", "SizeY", "SizeZ", "Speed", "AccelStrength", "PosOffsetX", "PosOffsetY", "PosOffsetZ" },
			scaleVectors = { "Acceleration" },
			scaleRanges = { "PosX", "PosY", "PosZ" },
		},
		retime = {
			multiplyNumbers = { "Rate", "Drag" },
			divideRanges = { "Lifetime" },
			multiplyRanges = { "FlipbookFramerate" },
			multiplyGraphs = { "Speed" },
			rotSpeedGraphs = { "RotSpeedX", "RotSpeedY", "RotSpeedZ" },
			squareVectors = { "Acceleration" },
			squareGraphs = { "AccelStrength" },
		},
		clipboard = {
			{name = "Spawning", props = {"Rate", "Lifetime", "SpreadAngle", "EmissionDirection", "PosX", "PosY", "PosZ", "PosXEven", "PosYEven", "PosZEven", "PositionEvenCycle", "PosMode", "Orientation", "ZOffset"}},
			{name = "Emission", props = {"EmitCount", "EmitDelay", "EmitDuration"}},
			{name = "Appearance", props = {"Brightness", "Color", "SizeX", "SizeY", "SizeZ", "Transparency", "Material"}},
			{name = "Movement", props = {"Speed", "PosOffsetX", "PosOffsetY", "PosOffsetZ", "RotMode", "RotOrder", "RotSpeedX", "RotSpeedY", "RotSpeedZ", "Acceleration", "Drag", "DirMode", "DisplacementMode", "InvertMotion", "AccelerationTowardsInstance", "AccelStrength", "Timescale"}},
			{name = "Shape", props = {"UseShape", "Shape", "ShapeInOut", "ShapePartial", "LookAtInitially"}},
			{name = "Flipbook", props = {"FlipbookMode", "FlipbookFramerate", "FlipbookStartRandom", "FlipbookReverse"}},
			{name = "Advanced", props = {"TotalKeyFrames", "PartLife", "RotX", "RotY", "RotZ", "RotXEven", "RotYEven", "RotZEven", "RotationEvenCycle", "Pool"}},
			-- One virtual prop per event so users pick which events to copy/paste. Each
			-- event prop's per-type validity is governed by EventsSchema.VALID_PER_TYPE,
			-- so filterTogglesBySelection auto-hides rows for events the selection's
			-- types don't support (e.g. OnHit hides for Beam-only selections).
			{name = "Events", props = {"OnEmit", "OnDeath", "OnDestruction", "OnHit"}},
		},
	},

	-- Beam emitter (post-"Transform as Emitter"): full particle pipeline. Differentiated from
	-- directAccess BeamNative by presence of a PartIcleProperties Configuration child.
	Beam = {
		classCheck = function(item) return item:IsA("Beam") and item:FindFirstChild("PartIcleProperties") ~= nil end,
		pDataType = "Beam",
		uiSection = "Beams",
		properties = TypeData.BeamProperties,

		resize = {
			scaleGraphs = { "Width0", "Width1", "CurveSize0", "CurveSize1", "Segments" },
		},
		retime = {
			multiplyNumbers = { "Rate" },
			divideRanges = { "Lifetime" },
			multiplyRanges = { "FlipbookFramerate" },
			multiplyGraphs = { "TextureSpeed" },
		},
		clipboard = {
			{name = "Spawning", props = {"Rate", "Lifetime"}},
			{name = "Emission", props = {"EmitCount", "EmitDelay", "EmitDuration"}},
			{name = "Appearance", props = {"Brightness", "Width0", "Width1", "LightEmission", "LightInfluence", "ZOffset"}},
			{name = "Geometry", props = {"CurveSize0", "CurveSize1", "Segments", "TextureLength", "TextureSpeed", "TextureMode", "FaceCamera"}},
			{name = "Flipbook", props = {"FlipbookMode", "FlipbookFramerate", "FlipbookStartRandom", "FlipbookReverse"}},
			{name = "Advanced", props = {"TotalKeyFrames", "Timescale", "Pool"}},
			{name = "Blender", props = {"Blender"}},
			{name = "Events", props = {"OnEmit", "OnDeath", "OnDestruction"}},
		},
	},

	PointLight = {
		classCheck = function(item) return item:IsA("PointLight") end,
		pDataType = "PointLight",
		uiSection = "PointLights",
		properties = TypeData.PointLightProperties,

		resize = {
			scaleGraphs = { "Range" },
		},
		retime = {
			multiplyNumbers = { "Rate" },
			divideRanges = { "Lifetime" },
		},
		clipboard = {
			{name = "Spawning", props = {"Rate", "Lifetime"}},
			{name = "Emission", props = {"EmitCount", "EmitDelay", "EmitDuration"}},
			{name = "Appearance", props = {"Range", "Brightness", "Color", "Shadows"}},
			{name = "Advanced", props = {"TotalKeyFrames", "PartLife", "Timescale", "Pool"}},
			{name = "Events", props = {"OnEmit", "OnDeath", "OnDestruction"}},
		},
	},

	Highlight = {
		classCheck = function(item) return item:IsA("Highlight") end,
		pDataType = "Highlight",
		uiSection = "Highlights",
		properties = TypeData.HighlightProperties,

		retime = {
			multiplyNumbers = { "Rate" },
			divideRanges = { "Lifetime" },
		},
		clipboard = {
			{name = "Spawning", props = {"Rate", "Lifetime"}},
			{name = "Emission", props = {"EmitCount", "EmitDelay", "EmitDuration"}},
			{name = "Appearance", props = {"FillColor", "FillTransparency", "OutlineColor", "OutlineTransparency", "DepthMode"}},
			{name = "Advanced", props = {"TotalKeyFrames", "PartLife", "Timescale", "Pool"}},
			{name = "Events", props = {"OnEmit", "OnDeath", "OnDestruction"}},
		},
	},

	-- TrailEmitter: Trail with a PartIcleProperties Configuration child (post-Transform-as-Emitter).
	-- Mutually exclusive with directAccess Trail via the FindFirstChild discriminator below.
	TrailEmitter = {
		classCheck = function(item) return item:IsA("Trail") and item:FindFirstChild("PartIcleProperties") ~= nil end,
		pDataType = "TrailEmitter",
		uiSection = "TrailEmitters",
		properties = TypeData.TrailEmitterProperties,

		resize = {
			scaleGraphs = { "MinLength", "MaxLength" },
		},
		retime = {
			multiplyNumbers = { "Rate" },
			divideRanges = { "Lifetime", "TrailLife" },
			multiplyRanges = { "TrailFlipbookFramerate" },
		},
		clipboard = {
			{name = "Spawning", props = {"Rate", "Lifetime"}},
			{name = "Emission", props = {"EmitCount", "EmitDelay", "EmitDuration"}},
			{name = "Appearance", props = {"Brightness", "LightEmission", "LightInfluence", "Texture", "TextureMode", "FaceCamera"}},
			{name = "Geometry", props = {"TextureLength", "MinLength", "MaxLength"}},
			{name = "Advanced", props = {"TotalKeyFrames", "PartLife", "Timescale", "Pool"}},
			{name = "Events", props = {"OnEmit", "OnDeath", "OnDestruction"}},
		},
	},

	-- Native Beam (directAccess): plain Beam without PartIcleProperties. Read/write directly
	-- on instance. Mutually exclusive with emitter Beam via FindFirstChild discriminator.
	BeamNative = {
		classCheck = function(item) return item:IsA("Beam") and item:FindFirstChild("PartIcleProperties") == nil end,
		pDataType = "BeamNative",
		uiSection = "BeamNatives",
		directAccess = true,
		properties = TypeData.BeamNativeProperties,

		resize = {
			scaleNumbers = { "Width0", "Width1", "CurveSize0", "CurveSize1" },
		},
		retime = {
			multiplyNumbers = { "TextureSpeed" },
		},

		clipboard = {
			{name = "Appearance", props = {"Brightness", "Color", "Transparency", "LightEmission", "LightInfluence", "ZOffset"}},
			{name = "Geometry", props = {"Width0", "Width1", "CurveSize0", "CurveSize1", "Segments", "TextureLength", "TextureSpeed", "TextureMode", "FaceCamera"}},
			{name = "Texture", props = {"Texture"}},
		},
	},

	Trail = {
		classCheck = function(item) return item:IsA("Trail") and item:FindFirstChild("PartIcleProperties") == nil end,
		pDataType = "Trail",
		uiSection = "Trails",
		directAccess = true,
		properties = TypeData.TrailProperties,

		resize = {
			scaleGraphs = { "WidthScale" },
		},
		retime = {
			divideNumbers = { "Lifetime" },
		},
		clipboard = {
			{name = "Spawning", props = {"Lifetime"}},
			-- Trail uses the logical key `Duration` (attrName=EmitDuration) instead of
			-- the virtual `EmitDuration` non-Trail items use. RandomizerRules has a
			-- special-case for Trail Duration; expose it in the catalog so the
			-- Randomizer panel actually surfaces a row.
			{name = "Emission", props = {"Duration"}},
			{name = "Appearance", props = {"Brightness", "Transparency", "Color", "WidthScale", "LightEmission", "LightInfluence"}},
			{name = "Geometry", props = {"MinLength", "MaxLength", "TextureLength", "TextureMode", "FaceCamera"}},
		},
	},

	Attachment = {
		classCheck = function(item) return item:IsA("Attachment") end,
		pDataType = "Attachment",
		uiSection = "Attachments",
		properties = TypeData.AttachmentProperties,

		resize = {
			scaleGraphs = { "Speed", "PosOffsetX", "PosOffsetY", "PosOffsetZ" },
			scaleVectors = { "Acceleration" },
			scaleRanges = { "PosX", "PosY", "PosZ" },
		},
		retime = {
			multiplyNumbers = { "Rate", "Drag" },
			divideRanges = { "Lifetime" },
			multiplyGraphs = { "Speed" },
			rotSpeedGraphs = { "RotSpeedX", "RotSpeedY", "RotSpeedZ" },
			squareVectors = { "Acceleration" },
		},
		clipboard = {
			{name = "Spawning", props = {"Rate", "Lifetime", "SpreadAngle", "EmissionDirection", "PosX", "PosY", "PosZ", "PosXEven", "PosYEven", "PosZEven", "PositionEvenCycle", "PosMode", "Orientation", "ZOffset"}},
			{name = "Emission", props = {"EmitCount", "EmitDelay", "EmitDuration"}},
			{name = "Movement", props = {"Speed", "PosOffsetX", "PosOffsetY", "PosOffsetZ", "RotMode", "RotOrder", "RotSpeedX", "RotSpeedY", "RotSpeedZ", "Acceleration", "Drag", "DirMode", "DisplacementMode", "InvertMotion", "Timescale"}},
			{name = "Advanced", props = {"TotalKeyFrames", "PartLife", "RotX", "RotY", "RotZ", "RotXEven", "RotYEven", "RotZEven", "RotationEvenCycle", "Pool"}},
			{name = "Events", props = {"OnEmit", "OnDeath", "OnDestruction", "OnHit"}},
		},
	},

	Model = {
		classCheck = function(item) return item:IsA("Model") end,
		pDataType = "Model",
		uiSection = "Models",
		properties = TypeData.ModelProperties,

		resize = {
			scaleGraphs = { "Speed", "Scale", "PosOffsetX", "PosOffsetY", "PosOffsetZ" },
			scaleVectors = { "Acceleration" },
			scaleRanges = { "PosX", "PosY", "PosZ" },
		},
		retime = {
			multiplyNumbers = { "Rate", "Drag" },
			divideRanges = { "Lifetime" },
			multiplyGraphs = { "Speed" },
			rotSpeedGraphs = { "RotSpeedX", "RotSpeedY", "RotSpeedZ" },
			squareVectors = { "Acceleration" },
		},
		clipboard = {
			{name = "Spawning", props = {"Rate", "Lifetime", "SpreadAngle", "EmissionDirection", "PosX", "PosY", "PosZ", "PosXEven", "PosYEven", "PosZEven", "PositionEvenCycle", "PosMode", "Orientation", "ZOffset"}},
			{name = "Emission", props = {"EmitCount", "EmitDelay", "EmitDuration"}},
			{name = "Scale", props = {"Scale", "ScaleTextureLength", "ScaleMotion", "ScaleRotation"}},
			{name = "Movement", props = {"Speed", "PosOffsetX", "PosOffsetY", "PosOffsetZ", "RotMode", "RotOrder", "RotSpeedX", "RotSpeedY", "RotSpeedZ", "Acceleration", "Drag", "DirMode", "DisplacementMode", "InvertMotion", "Timescale"}},
			{name = "Advanced", props = {"TotalKeyFrames", "PartLife", "RotX", "RotY", "RotZ", "RotXEven", "RotYEven", "RotZEven", "RotationEvenCycle", "Pool"}},
			{name = "Events", props = {"OnEmit", "OnDeath", "OnDestruction", "OnHit"}},
		},
	},
}

-- Merge in screen-type Types (Blur, Bloom, ColorCorrection, Atmosphere, ImageLabel).
for name, entry in pairs(ScreenData.Types) do TypeData.Types[name] = entry end

return TypeData
