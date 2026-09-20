--[[
	Module: TypeDataScreen
	Description: Part-Icles 屏幕空间五类（Blur / Bloom / ColorCorrection / Atmosphere / ImageLabel）的属性表与 Types 条目
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-09-01

	纯数据表，无函数。条目形状与 TypeData 一致，见 TypeData 文件头。
]]

local Screen = {}

Screen.BlurProperties = {
	-- Graph properties
	Size           = { type = "NumberSequence", default = NumberSequence.new(10), attrName = "BlurSize", nonNegative = true },

	-- Timescale graph: see TypeData.PartProperties for full semantics.
	Timescale      = { type = "NumberSequence", default = NumberSequence.new(1) },

	-- Non-graph properties
	Lifetime       = { type = "NumberRange", default = NumberRange.new(1) },
	Rate           = { type = "number",      default = 10 },
	TotalKeyFrames = { type = "number",      default = 100 },
	PartLife       = { type = "number",      default = 0 },
	Enabled        = { type = "boolean",     default = false },
}

Screen.BloomProperties = {
	-- Graph properties (per BloomEffect spec: Intensity 0..1, Size 0..56, Threshold 0..10)
	Intensity      = { type = "NumberSequence", default = NumberSequence.new(0.4),  attrName = "BloomIntensity", nonNegative = true },
	Size           = { type = "NumberSequence", default = NumberSequence.new(24),   attrName = "BloomSize",      nonNegative = true },
	Threshold      = { type = "NumberSequence", default = NumberSequence.new(0.95), attrName = "BloomThreshold", nonNegative = true },

	-- Timescale graph: see TypeData.PartProperties for full semantics.
	Timescale      = { type = "NumberSequence", default = NumberSequence.new(1) },

	-- Non-graph properties
	Lifetime       = { type = "NumberRange", default = NumberRange.new(1) },
	Rate           = { type = "number",      default = 10 },
	TotalKeyFrames = { type = "number",      default = 100 },
	PartLife       = { type = "number",      default = 0 },
	Enabled        = { type = "boolean",     default = false },
}

Screen.ColorCorrectionProperties = {
	-- Graph properties (all signed: -1..1 range, so no nonNegative)
	Brightness     = { type = "NumberSequence", default = NumberSequence.new(0), attrName = "CCBrightness" },
	Contrast       = { type = "NumberSequence", default = NumberSequence.new(0), attrName = "CCContrast" },
	Saturation     = { type = "NumberSequence", default = NumberSequence.new(0), attrName = "CCSaturation" },
	TintColor      = { type = "ColorSequence",  default = ColorSequence.new(Color3.new(1,1,1)), attrName = "CCTintColor" },

	-- Timescale graph: see TypeData.PartProperties for full semantics.
	Timescale      = { type = "NumberSequence", default = NumberSequence.new(1) },

	-- Non-graph properties
	Lifetime       = { type = "NumberRange", default = NumberRange.new(1) },
	Rate           = { type = "number",      default = 10 },
	TotalKeyFrames = { type = "number",      default = 100 },
	PartLife       = { type = "number",      default = 0 },
	Enabled        = { type = "boolean",     default = false },
}

Screen.AtmosphereProperties = {
	-- Graph properties (Density/Offset 0..1, Glare 0..24, Haze 0..10 per Atmosphere spec)
	Density        = { type = "NumberSequence", default = NumberSequence.new(0.3),  attrName = "AtmDensity", nonNegative = true },
	Offset         = { type = "NumberSequence", default = NumberSequence.new(0.25), attrName = "AtmOffset",  nonNegative = true },
	Glare          = { type = "NumberSequence", default = NumberSequence.new(0),    attrName = "AtmGlare",   nonNegative = true },
	Haze           = { type = "NumberSequence", default = NumberSequence.new(0),    attrName = "AtmHaze",    nonNegative = true },
	Color          = { type = "ColorSequence",  default = ColorSequence.new(Color3.new(0.78, 0.78, 0.78)), attrName = "AtmColor" },
	Decay          = { type = "ColorSequence",  default = ColorSequence.new(Color3.new(0.416, 0.471, 0.541)), attrName = "AtmDecay" },
	-- Timescale graph: see TypeData.PartProperties for full semantics.
	Timescale      = { type = "NumberSequence", default = NumberSequence.new(1), attrName = "AtmTimescale" },

	-- Non-graph properties (Atmosphere has no native Enabled; we track it for emission timing only)
	Lifetime       = { type = "NumberRange", default = NumberRange.new(1) },
	Rate           = { type = "number",      default = 10 },
	TotalKeyFrames = { type = "number",      default = 100 },
	PartLife       = { type = "number",      default = 0 },
	Enabled        = { type = "boolean",     default = false },
}

Screen.ImageLabelProperties = {
	-- Graph properties (animate per-life)
	ImageTransparency       = { type = "NumberSequence", default = NumberSequence.new(0) },
	BackgroundTransparency  = { type = "NumberSequence", default = NumberSequence.new(1) }, -- default invisible
	Speed                   = { type = "NumberSequence", default = NumberSequence.new(0), attrName = "ImgSpeed", nonNegative = true },

	-- Per-axis Size scale graphs (multiply base Size components per frame). Keys match the
	-- axis_graph_select widget's expected naming (baseKey "SizeScale" + axis "X"/"Y").
	SizeScaleX              = { type = "NumberSequence", default = NumberSequence.new(1), nonNegative = true },
	SizeScaleY              = { type = "NumberSequence", default = NumberSequence.new(1), nonNegative = true },

	-- Rotation system (RotRange for random initial; RotSpeed graph for continuous/over-life spin; RotMode switches semantics)
	RotRange                = { type = "NumberRange",    default = NumberRange.new(0),   attrName = "ImgRotRange" },
	RotSpeed                = { type = "NumberSequence", default = NumberSequence.new(0), attrName = "ImgRotSpeed" },
	RotMode                 = { type = "string",         default = "OverLife",            attrName = "ImgRotMode" },

	-- ColorSequences
	ImageColor3             = { type = "ColorSequence",  default = ColorSequence.new(Color3.new(1,1,1)) },
	BackgroundColor3        = { type = "ColorSequence",  default = ColorSequence.new(Color3.new(1,1,1)) },

	-- Static at emit
	Image             = { type = "string",    default = "" },
	Position          = { type = "UDim2",     default = UDim2.fromScale(0.5, 0.5) },
	Size              = { type = "UDim2",     default = UDim2.fromOffset(100, 100), attrName = "ImgSize" },
	AnchorPoint       = { type = "Vector2",   default = Vector2.new(0.5, 0.5) },
	ZIndex            = { type = "number",    default = 1 },
	ScaleType         = { type = "enum",      enumType = "ScaleType",       default = Enum.ScaleType.Stretch },
	ResampleMode      = { type = "enum",      enumType = "ResamplerMode",   default = Enum.ResamplerMode.Default },

	-- 2D motion
	EmissionAngle     = { type = "number",    default = 90 }, -- 90 = up, 0 = right, 180 = left, 270 = down
	SpreadAngle       = { type = "number",    default = 0, attrName = "ImgSpreadAngle" },
	Acceleration      = { type = "Vector2",   default = Vector2.new(0, 0), attrName = "ImgAcceleration" },
	Drag              = { type = "number",    default = 0, attrName = "ImgDrag" },
	InvertMotion      = { type = "boolean",   default = false, attrName = "ImgInvertMotion" },

	-- Flipbook source type (asset layout)  -  "Decals" = numbered-Decals folder, "Spritesheet" = grid on single Image.
	FlipbookSource     = { type = "string",      default = "Decals", attrName = "ImgFlipbookSource" },
	-- Flipbook playback mode  -  matches Roblox's Enum.ParticleFlipbookMode convention (Loop/OneShot/PingPong/Random).
	FlipbookMode       = { type = "enum",        enumType = "ParticleFlipbookMode", default = Enum.ParticleFlipbookMode.Loop, attrName = "ImgFlipbookMode" },
	FlipbookStartRandom = { type = "boolean",    default = false, attrName = "ImgFlipbookStartRandom" },
	GridCols           = { type = "number",      default = 8 },
	GridRows           = { type = "number",      default = 1 },
	FlipbookFramerate  = { type = "NumberRange", default = NumberRange.new(10), attrName = "ImgFlipbookFramerate" },
	FlipbookReverse    = { type = "boolean",     default = false, attrName = "ImgFlipbookReverse" },

	-- Timescale graph: see TypeData.PartProperties for full semantics.
	Timescale      = { type = "NumberSequence", default = NumberSequence.new(1), attrName = "ImgTimescale" },

	-- Standard
	Lifetime       = { type = "NumberRange", default = NumberRange.new(1) },
	Rate           = { type = "number",      default = 10 },
	TotalKeyFrames = { type = "number",      default = 100 },
	PartLife       = { type = "number",      default = 0 },
	Enabled        = { type = "boolean",     default = false },
}

Screen.Types = {
	Blur = {
		classCheck = function(item) return item:IsA("BlurEffect") end,
		pDataType = "Blur",
		uiSection = "Blurs",
		properties = Screen.BlurProperties,
		resize = { scaleGraphs = { "Size" } },
		retime = { multiplyNumbers = { "Rate" }, divideRanges = { "Lifetime" } },
		clipboard = {
			{name = "Spawning",   props = {"Rate", "Lifetime"}},
			{name = "Emission",   props = {"EmitCount", "EmitDelay", "EmitDuration"}},
			{name = "Appearance", props = {"Size"}},
			{name = "Advanced",   props = {"TotalKeyFrames", "PartLife", "Timescale"}},
			{name = "Events",     props = {"OnEmit", "OnDeath", "OnDestruction"}},
		},
	},

	Bloom = {
		classCheck = function(item) return item:IsA("BloomEffect") end,
		pDataType = "Bloom",
		uiSection = "Blooms",
		properties = Screen.BloomProperties,
		resize = { scaleGraphs = { "Size" } },
		retime = { multiplyNumbers = { "Rate" }, divideRanges = { "Lifetime" } },
		clipboard = {
			{name = "Spawning",   props = {"Rate", "Lifetime"}},
			{name = "Emission",   props = {"EmitCount", "EmitDelay", "EmitDuration"}},
			{name = "Appearance", props = {"Intensity", "Size", "Threshold"}},
			{name = "Advanced",   props = {"TotalKeyFrames", "PartLife", "Timescale"}},
			{name = "Events",     props = {"OnEmit", "OnDeath", "OnDestruction"}},
		},
	},

	ColorCorrection = {
		classCheck = function(item) return item:IsA("ColorCorrectionEffect") end,
		pDataType = "ColorCorrection",
		uiSection = "ColorCorrections",
		properties = Screen.ColorCorrectionProperties,
		resize = {},
		retime = { multiplyNumbers = { "Rate" }, divideRanges = { "Lifetime" } },
		clipboard = {
			{name = "Spawning",   props = {"Rate", "Lifetime"}},
			{name = "Emission",   props = {"EmitCount", "EmitDelay", "EmitDuration"}},
			{name = "Appearance", props = {"Brightness", "Contrast", "Saturation", "TintColor"}},
			{name = "Advanced",   props = {"TotalKeyFrames", "PartLife", "Timescale"}},
			{name = "Events",     props = {"OnEmit", "OnDeath", "OnDestruction"}},
		},
	},

	Atmosphere = {
		classCheck = function(item) return item:IsA("Atmosphere") end,
		pDataType = "Atmosphere",
		uiSection = "Atmospheres",
		properties = Screen.AtmosphereProperties,
		resize = {},
		retime = { multiplyNumbers = { "Rate" }, divideRanges = { "Lifetime" } },
		clipboard = {
			{name = "Spawning",   props = {"Rate", "Lifetime"}},
			{name = "Emission",   props = {"EmitCount", "EmitDelay", "EmitDuration"}},
			{name = "Appearance", props = {"Density", "Offset", "Glare", "Haze", "Color", "Decay"}},
			{name = "Advanced",   props = {"TotalKeyFrames", "PartLife", "Timescale"}},
			{name = "Events",     props = {"OnEmit", "OnDeath", "OnDestruction"}},
		},
	},

	ImageLabel = {
		classCheck = function(item) return item:IsA("ImageLabel") end,
		pDataType = "ImageLabel",
		uiSection = "ImageLabels",
		properties = Screen.ImageLabelProperties,
		resize = {
			-- Pixel-sized bits scale: Speed graph (px/sec), per-axis size scale graphs, Acceleration (Vector2),
			-- and the UDim2 Position/Size rectangles (both Scale and Offset components scale together).
			scaleGraphs  = { "Speed", "SizeScaleX", "SizeScaleY" },
			scaleVectors = { "Acceleration" },
			scaleUDim2s  = { "Position", "Size" },
		},
		retime = {
			multiplyNumbers = { "Rate", "Drag" },
			divideRanges    = { "Lifetime" },
			multiplyRanges  = { "FlipbookFramerate" },
			multiplyGraphs  = { "Speed", "RotSpeed" },
			-- Acceleration is studs/sec² (or screen-pixels/sec² here); kinematic shape preserved
			-- under retime requires factor² scaling. Other types include this; ImageLabel was missing.
			squareVectors   = { "Acceleration" },
		},
		clipboard = {
			{name = "Spawning",   props = {"Rate", "Lifetime", "RotRange", "RotSpeed", "RotMode"}},
			{name = "Emission",   props = {"EmitCount", "EmitDelay", "EmitDuration"}},
			{name = "Appearance", props = {"Image", "ImageColor3", "ImageTransparency", "BackgroundColor3", "BackgroundTransparency", "ScaleType", "ResampleMode"}},
			-- (FlipbookMode stays in the Flipbook group  -  conceptually belongs there.)
			{name = "Layout",     props = {"Position", "Size", "SizeScaleX", "SizeScaleY", "AnchorPoint", "ZIndex"}},
			{name = "Motion",     props = {"Speed", "EmissionAngle", "SpreadAngle", "Acceleration", "Drag", "InvertMotion"}},
			{name = "Flipbook",   props = {"FlipbookSource", "FlipbookMode", "FlipbookStartRandom", "GridCols", "GridRows", "FlipbookFramerate", "FlipbookReverse"}},
			{name = "Advanced",   props = {"TotalKeyFrames", "PartLife", "Timescale"}},
			{name = "Events",     props = {"OnEmit", "OnDeath", "OnDestruction"}},
		},
	},
}

return Screen
