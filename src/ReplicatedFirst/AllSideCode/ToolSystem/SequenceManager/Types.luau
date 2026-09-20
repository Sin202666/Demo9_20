--[[
	Module: Types
	Description: SequenceManager 共享常量、枚举与导出类型
	Author: 林奥宇
	Created: 2026-07-31
	Last Modified: 2026-09-01

	供 Catalog / Playback / PlaybackPresent / Preload 等子模块共用；不对外单独挂 Utils。

	PresentMode（表现层，与 playMode 正交）：
	- Swap：单控件硬切 Image / ImageRect（默认）
	- Crossfade：双缓冲叠化（bufferA=目标，bufferB=同级轻量 ImageLabel）
	- CloneAll：每帧预创建同级控件，切 Visible（多图闪帧敏感场景；图集不可用）

	PlaybackHandle：PlaySequence 成功时第三返回值；StopHandle / 带 handle 的控制 API 用于防旧回调误操作新播。
	PlaybackState：唯一运行时状态表（Playback / Present / Step / Query / Lifecycle 共用，禁止各文件再复制字段）。
	SeekPhase：SeekTime / FrameFromTime 解析结果（含 PingPong 往返方向）。

	rp18 映射（合库时对照）：
	- mode → presentMode（含 CloneAll）
	- speedScale → speed；pingPong → playMode=PingPong
	- PlaySequenceEx → PlaySequence(options)；SetPlaybackSpeed → SetSpeed
]]

export type StopPolicyValue = "HideClear" | "Restore" | "Keep"
export type PlayModeValue = "Forward" | "PingPong" | "Reverse"
export type PresentModeValue = "Swap" | "Crossfade" | "CloneAll"
export type SequenceKind = "Images" | "Sheet"
export type CallbackModeValue = "Sync" | "Deferred"

export type SheetLayout = {
	imageId: string,
	cellWidth: number,
	cellHeight: number,
	columns: number,
	-- 图集左侧/顶侧边距（像素）；默认 0
	padding: number?,
	-- 格与格之间间距（像素）；默认 0
	spacing: number?,
	-- 可选行数；若配置则须 >= ceil(frameCount/columns)
	rows: number?,
}

export type SequenceFrameData = {
	kind: SequenceKind,
	frames: { string },
	count: number,
	sheet: SheetLayout?,
	-- count=0 时的拒绝原因（FRAME_GAP / INVALID_SHEET / EMPTY_SEQUENCE）；可播放时为 nil
	rejectCode: string?,
}

export type SheetPlayOptions = {
	imageId: string,
	cellWidth: number,
	cellHeight: number,
	columns: number,
	frameCount: number?,
	padding: number?,
	spacing: number?,
	rows: number?,
}

export type PlayOptions = {
	-- 已移除：请用 fps / secondsPerFrame（传入将返回 INVALID_TIMING）
	frameDuration: number?,
	fps: number?,
	secondsPerFrame: number?,
	loop: boolean?,
	loopInterval: number?,
	speed: number?,
	stopPolicy: StopPolicyValue?,
	startFrame: number?,
	-- 播放区间末帧（含）；默认总帧数；须 >= startFrame
	endFrame: number?,
	playMode: PlayModeValue?,
	-- 表现层：Swap | Crossfade | CloneAll；与 playMode 正交
	presentMode: PresentModeValue?,
	-- Crossfade 叠化时长（秒）；默认 Types.DEFAULT_CROSSFADE_SEC
	crossfadeSec: number?,
	-- 层 ImageTransparency（0 不透明～1 全透明）；播放中可 SetLayerTransparency
	layerTransparency: number?,
	direction: number?,
	forceVisible: boolean?,
	-- Sync（默认）：同帧同步回调；Deferred：task.spawn，避免回调内重活卡死时钟
	callbackMode: CallbackModeValue?,
	sheet: SheetPlayOptions?,
	onComplete: (() -> ())?,
	onLoop: (() -> ())?,
	onFrame: ((frame: number) -> ())?,
	markers: { [number]: () -> () }?,
}

export type PreloadOptions = {
	warmup: boolean?,
	fps: number?,
	onReady: (() -> ())?,
	onComplete: ((ok: boolean, err: string?) -> ())?,
	onProgress: ((done: number, total: number, sequenceName: string) -> ())?,
	strictWarmup: boolean?,
}

export type StopOpts = {
	policy: StopPolicyValue?,
	skipVisual: boolean?,
}

-- PlaySequence 成功时返回；target 用于 StopHandle，id 用于世代校验
export type PlaybackHandle = {
	id: number,
	target: GuiObject,
}

-- SeekTime / ResolveSeekPhase 的帧 + 方向（PingPong 往返前半 direction=1，后半或落在末帧为 -1）
export type SeekPhase = {
	frame: number,
	direction: number,
}

-- Catalog.ValidateSequence 单条问题
export type CatalogIssue = {
	code: string,
	message: string,
}

-- GetDebugSnapshot 单条活跃播放摘要
export type DebugPlaybackEntry = {
	id: number,
	targetName: string,
	sequenceName: string,
	currentFrame: number,
	rangeStart: number,
	rangeEnd: number,
	presentMode: PresentModeValue,
	playMode: PlayModeValue,
	kind: SequenceKind,
	paused: boolean,
	speed: number,
	direction: number,
}

-- 运行时播放状态（唯一权威定义；子模块勿再声明平行字段表）
export type PlaybackState = {
	id: number,
	presentId: string,
	sequenceName: string,
	destroyConnection: any,
	kind: SequenceKind,
	frames: { string },
	sheet: SheetLayout?,
	frameCount: number,
	rangeStart: number,
	rangeEnd: number,
	currentFrame: number,
	elapsed: number,
	stopTime: number,
	frameStep: number,
	speed: number,
	paused: boolean,
	loop: boolean,
	loopInterval: number,
	stopPolicy: StopPolicyValue,
	playMode: PlayModeValue,
	presentMode: PresentModeValue,
	crossfadeSec: number,
	layerTransparency: number,
	crossfading: boolean,
	crossfadeElapsed: number,
	activeIsA: boolean,
	bufferA: GuiObject?,
	bufferB: ImageLabel?,
	clones: { ImageLabel }?,
	nowShow: ImageLabel?,
	direction: number,
	forceVisible: boolean,
	callbackMode: CallbackModeValue,
	playedTime: number,
	savedImage: string,
	savedVisible: boolean,
	savedRectOffset: Vector2,
	savedRectSize: Vector2,
	savedTransparency: number,
	savedImageColor: Color3,
	onComplete: (() -> ())?,
	onLoop: (() -> ())?,
	onFrame: ((frame: number) -> ())?,
	markers: { [number]: () -> () }?,
}

local Types = {}

-- 历史换算常量（旧 frameDuration 倍率基准约 1/60s）；仅作迁移文档参考，运行时不再使用
Types.LEGACY_FRAME_TIME_SEC = 0.016
Types.DEFAULT_SPEED = 1
Types.DEFAULT_WARMUP_FPS = 12
Types.DEFAULT_CROSSFADE_SEC = 0.04
-- Crossfade 叠化除零保护（秒）；实际时长仍用 crossfadeSec
Types.MIN_CROSSFADE_SEC = 0.0001
Types.DEFAULT_LAYER_TRANSPARENCY = 0
-- 同 tick 逻辑/回调追帧上限；超出部分保留到后续 tick
Types.MAX_CATCHUP_CALLBACKS = 32
-- Crossfade 期间每 tick 最多推进 1 逻辑帧，避免叠化被追帧跳过
Types.MAX_STEPS_WHILE_CROSSFADE = 1
-- CloneAll 帧数上限；超出返回 PRESENT_FAILED（请改用 Swap/Crossfade）
Types.MAX_CLONE_ALL_FRAMES = 64
-- Crossfade/CloneAll peer 闲置池上限；超出则 Destroy
Types.MAX_PEER_POOL = 48
Types.PLAYER_GUI_NAME = "PlayerGui"
Types.SEQUENCE_ROOT_NAME = "Sequence"
Types.PRELOAD_GUI_NAME = "SequencePreloadGui"
Types.WARMUP_IMAGE_NAME = "SequenceWarmup"
Types.CROSSFADE_BUFFER_B_PREFIX = "SEQ_CF_B"
Types.CLONE_NAME_PREFIX = "SEQ_CL"

-- Folder Attribute / 子实例约定（图集）
Types.ATTR_SHEET_IMAGE = "SheetImage"
Types.ATTR_CELL_WIDTH = "CellWidth"
Types.ATTR_CELL_HEIGHT = "CellHeight"
Types.ATTR_COLUMNS = "Columns"
Types.ATTR_FRAME_COUNT = "FrameCount"
Types.ATTR_ROWS = "Rows"
Types.ATTR_PADDING = "Padding"
Types.ATTR_SPACING = "Spacing"
Types.SHEET_IMAGE_VALUE_NAME = "SheetImage"

Types.StopPolicy = table.freeze({
	HideClear = "HideClear" :: StopPolicyValue,
	Restore = "Restore" :: StopPolicyValue,
	Keep = "Keep" :: StopPolicyValue,
})

Types.PlayMode = table.freeze({
	Forward = "Forward" :: PlayModeValue,
	PingPong = "PingPong" :: PlayModeValue,
	Reverse = "Reverse" :: PlayModeValue,
})

Types.PresentMode = table.freeze({
	Swap = "Swap" :: PresentModeValue,
	Crossfade = "Crossfade" :: PresentModeValue,
	CloneAll = "CloneAll" :: PresentModeValue,
})

Types.SequenceKind = table.freeze({
	Images = "Images" :: SequenceKind,
	Sheet = "Sheet" :: SequenceKind,
})

Types.CallbackMode = table.freeze({
	Sync = "Sync" :: CallbackModeValue,
	Deferred = "Deferred" :: CallbackModeValue,
})

Types.ErrorCode = table.freeze({
	NOT_CLIENT = "NOT_CLIENT",
	INVALID_ARG = "INVALID_ARG",
	INVALID_TIMING = "INVALID_TIMING",
	NOT_FOUND = "NOT_FOUND",
	NOT_PLAYING = "NOT_PLAYING",
	PRELOAD_FAILED = "PRELOAD_FAILED",
	NO_PLAYER_GUI = "NO_PLAYER_GUI",
	INVALID_SHEET = "INVALID_SHEET",
	-- Crossfade / CloneAll 无法创建缓冲（目标无 Parent、图集用 CloneAll、超 CloneAll 上限等）
	PRESENT_FAILED = "PRESENT_FAILED",
	-- handle.id 与当前在播世代不一致（旧回调误操作）
	STALE_HANDLE = "STALE_HANDLE",
	-- 多图帧目录序号不连续（须从最小序号起连续，无空洞）
	FRAME_GAP = "FRAME_GAP",
	-- 序列存在但无任何有效帧（非空洞、非图集配置错误）
	EMPTY_SEQUENCE = "EMPTY_SEQUENCE",
	-- Play 已装配但 Sync 回调内停播且无后继在播（成功路径必须带 handle）
	ABORTED = "ABORTED",
})

return Types
