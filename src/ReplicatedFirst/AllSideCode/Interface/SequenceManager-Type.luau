--[[
	Module: SequenceManager-Type
	Description: SequenceManager / UISequence 对外类型桩（与 ToolSystem/SequenceManager 实现同步）
	Author: 林奥宇
	Created: 2026-07-02
	Last Modified: 2026-09-01

	调用方强制约定（与 SequenceManager init 文件头一致）：
	接收 ok/err/handle → 失败勿假装在播 → 主动/回调内停播用 StopHandle → 长循环业务关闭须显式停。
]]

local SequenceManager = {}

type ImageLabel = typeof(workspace:FindFirstChildOfClass("ImageLabel"))

type StopPolicyValue = "HideClear" | "Restore" | "Keep"
type PlayModeValue = "Forward" | "PingPong" | "Reverse"
type PresentModeValue = "Swap" | "Crossfade" | "CloneAll"
type SequenceKind = "Images" | "Sheet"
type CallbackModeValue = "Sync" | "Deferred"

type SheetPlayOptions = {
	imageId: string,
	cellWidth: number,
	cellHeight: number,
	columns: number,
	frameCount: number?,
	padding: number?,
	spacing: number?,
	rows: number?,
}

type CatalogIssue = {
	code: string,
	message: string,
}

type DebugPlaybackEntry = {
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

type PlayOptions = {
	-- 已移除：传入将 INVALID_TIMING；请用 fps / secondsPerFrame
	frameDuration: number?,
	fps: number?,
	secondsPerFrame: number?,
	loop: boolean?,
	loopInterval: number?,
	speed: number?,
	stopPolicy: StopPolicyValue?,
	startFrame: number?,
	endFrame: number?,
	playMode: PlayModeValue?,
	presentMode: PresentModeValue?,
	crossfadeSec: number?,
	layerTransparency: number?,
	direction: number?,
	forceVisible: boolean?,
	callbackMode: CallbackModeValue?,
	sheet: SheetPlayOptions?,
	onComplete: (() -> ())?,
	onLoop: (() -> ())?,
	onFrame: ((frame: number) -> ())?,
	markers: { [number]: () -> () }?,
}

type PreloadOptions = {
	warmup: boolean?,
	fps: number?,
	onReady: (() -> ())?,
	onComplete: ((ok: boolean, err: string?) -> ())?,
	onProgress: ((done: number, total: number, sequenceName: string) -> ())?,
	strictWarmup: boolean?,
}

type PlaybackHandle = {
	id: number,
	target: GuiObject,
}

SequenceManager.StopPolicy = table.freeze({
	HideClear = "HideClear" :: StopPolicyValue,
	Restore = "Restore" :: StopPolicyValue,
	Keep = "Keep" :: StopPolicyValue,
})

SequenceManager.PlayMode = table.freeze({
	Forward = "Forward" :: PlayModeValue,
	PingPong = "PingPong" :: PlayModeValue,
	Reverse = "Reverse" :: PlayModeValue,
})

SequenceManager.PresentMode = table.freeze({
	Swap = "Swap" :: PresentModeValue,
	Crossfade = "Crossfade" :: PresentModeValue,
	CloneAll = "CloneAll" :: PresentModeValue,
})

SequenceManager.SequenceKind = table.freeze({
	Images = "Images" :: SequenceKind,
	Sheet = "Sheet" :: SequenceKind,
})

SequenceManager.CallbackMode = table.freeze({
	Sync = "Sync" :: CallbackModeValue,
	Deferred = "Deferred" :: CallbackModeValue,
})

SequenceManager.ErrorCode = table.freeze({
	NOT_CLIENT = "NOT_CLIENT",
	INVALID_ARG = "INVALID_ARG",
	INVALID_TIMING = "INVALID_TIMING",
	NOT_FOUND = "NOT_FOUND",
	NOT_PLAYING = "NOT_PLAYING",
	PRELOAD_FAILED = "PRELOAD_FAILED",
	NO_PLAYER_GUI = "NO_PLAYER_GUI",
	INVALID_SHEET = "INVALID_SHEET",
	PRESENT_FAILED = "PRESENT_FAILED",
	STALE_HANDLE = "STALE_HANDLE",
	FRAME_GAP = "FRAME_GAP",
	EMPTY_SEQUENCE = "EMPTY_SEQUENCE",
	ABORTED = "ABORTED",
})

--[[
	停止指定 ImageLabel 上的序列播放
	@param imageLabel ImageLabel? - 要停止的目标，nil 时无操作
	@param policy StopPolicyValue? - 覆盖停止策略；未在播时不改外观
	@param handle PlaybackHandle? - 可选世代校验
	@return boolean - true 成功；false 参数/环境无效
	@return string? - 失败时的 ErrorCode
]]
function SequenceManager:StopSequence(
	imageLabel: ImageLabel?,
	policy: StopPolicyValue?,
	handle: PlaybackHandle?
): (boolean, string?)
	return false, nil
end

--[[
	按 PlaybackHandle 停止
	@param handle PlaybackHandle - PlaySequence 成功时的第三返回值
	@param policy StopPolicyValue? - 覆盖停止策略
	@return boolean - true 成功或已无对应播放
	@return string? - 失败时的 ErrorCode
]]
function SequenceManager:StopHandle(handle: PlaybackHandle, policy: StopPolicyValue?): (boolean, string?)
	return false, nil
end

--[[
	停止全部在播序列
	@param policy StopPolicyValue? - 统一覆盖停止策略；默认各自 stopPolicy
	@return number - 实际停止的数量
]]
function SequenceManager:StopAll(policy: StopPolicyValue?): number
	return 0
end

--[[
	暂停播放（保持当前帧）
	@param imageLabel ImageLabel - 目标
	@param handle PlaybackHandle? - 可选世代校验
	@return boolean - true 成功；false 未在播放
	@return string? - 失败时的 ErrorCode
]]
function SequenceManager:PauseSequence(imageLabel: ImageLabel, handle: PlaybackHandle?): (boolean, string?)
	return false, nil
end

--[[
	恢复已暂停的播放
	@param imageLabel ImageLabel - 目标
	@param handle PlaybackHandle? - 可选世代校验
	@return boolean - true 成功；false 未在播放
	@return string? - 失败时的 ErrorCode
]]
function SequenceManager:ResumeSequence(imageLabel: ImageLabel, handle: PlaybackHandle?): (boolean, string?)
	return false, nil
end

--[[
	暂停全部在播实例
	@return number - 新置为暂停的数量
]]
function SequenceManager:PauseAll(): number
	return 0
end

--[[
	恢复全部已暂停实例
	@return number - 新恢复的数量
]]
function SequenceManager:ResumeAll(): number
	return 0
end

--[[
	跳转到指定帧（1-based）
	@param imageLabel ImageLabel|ImageButton - 目标
	@param frame number - 目标帧（越界钳制到 startFrame..endFrame）
	@param handle PlaybackHandle? - 可选世代校验
	@return boolean - true 成功
	@return string? - 失败时的 ErrorCode
]]
function SequenceManager:Seek(imageLabel: ImageLabel, frame: number, handle: PlaybackHandle?): (boolean, string?)
	return false, nil
end

--[[
	按时间跳转（秒，相对区间起点相位）
	@param imageLabel ImageLabel|ImageButton - 目标
	@param timeSec number - 秒，须 >= 0
	@param handle PlaybackHandle? - 可选世代校验
	@return boolean - true 成功
	@return string? - 失败时的 ErrorCode
]]
function SequenceManager:SeekTime(imageLabel: ImageLabel, timeSec: number, handle: PlaybackHandle?): (boolean, string?)
	return false, nil
end

--[[
	当前在播实例在 speed=1 下的区间总时长（秒）
	@param imageLabel ImageLabel|ImageButton - 目标
	@return number? - 秒；未在播放时 nil
]]
function SequenceManager:GetDuration(imageLabel: ImageLabel): number?
	return nil
end

--[[
	设置播放速率（1 为原速）
	@param imageLabel ImageLabel - 目标
	@param speed number - 速率，须 > 0
	@param handle PlaybackHandle? - 可选世代校验
	@return boolean - true 成功
	@return string? - 失败时的 ErrorCode
]]
function SequenceManager:SetSpeed(imageLabel: ImageLabel, speed: number, handle: PlaybackHandle?): (boolean, string?)
	return false, nil
end

--[[
	设置层 ImageTransparency（0 不透明～1 全透明）
	@param imageLabel ImageLabel - 目标
	@param transparency number - 透明度
	@param handle PlaybackHandle? - 可选世代校验
	@return boolean - true 成功
	@return string? - 失败时的 ErrorCode
]]
function SequenceManager:SetLayerTransparency(
	imageLabel: ImageLabel,
	transparency: number,
	handle: PlaybackHandle?
): (boolean, string?)
	return false, nil
end

--[[
	当前层透明度；未在播放时 nil
	@param imageLabel ImageLabel - 目标
	@return number? - [0, 1]
]]
function SequenceManager:GetLayerTransparency(imageLabel: ImageLabel): number?
	return nil
end

--[[
	是否正在播放（存在状态且未暂停；含循环间隔等待中）
	@param imageLabel ImageLabel - 目标
	@return boolean - true 正在播
]]
function SequenceManager:IsPlaying(imageLabel: ImageLabel): boolean
	return false
end

--[[
	是否已暂停（存在播放状态且 paused）
	@param imageLabel ImageLabel - 目标
	@return boolean - true 已暂停
]]
function SequenceManager:IsPaused(imageLabel: ImageLabel): boolean
	return false
end

--[[
	handle 是否仍指向当前在播世代
	@param handle PlaybackHandle - PlaySequence 返回的句柄
	@return boolean - true 仍有效
]]
function SequenceManager:IsHandleActive(handle: PlaybackHandle): boolean
	return false
end

--[[
	当前帧下标（1-based）；未在播放时 nil
	@param imageLabel ImageLabel - 目标
	@return number? - 当前帧
]]
function SequenceManager:GetCurrentFrame(imageLabel: ImageLabel): number?
	return nil
end

--[[
	播放进度 [0, 1]（按当前帧/总帧，兼容旧名）
	@param imageLabel ImageLabel - 目标
	@return number? - 帧进度
]]
function SequenceManager:GetProgress(imageLabel: ImageLabel): number?
	return nil
end

--[[
	按当前帧/总帧的进度 [0, 1]
	@param imageLabel ImageLabel - 目标
	@return number? - 帧进度
]]
function SequenceManager:GetFrameProgress(imageLabel: ImageLabel): number?
	return nil
end

--[[
	按已播放时间估算动画相位进度 [0, 1]（不含 loopInterval；等待期间不累加 playedTime）
	@param imageLabel ImageLabel - 目标
	@return number? - 时间进度
]]
function SequenceManager:GetTimeProgress(imageLabel: ImageLabel): number?
	return nil
end

--[[
	查询目录中序列的总帧数
	@param sequenceName string - 序列名称
	@return number? - 帧数
]]
function SequenceManager:GetFrameCount(sequenceName: string): number?
	return nil
end

--[[
	按目录帧数与时间选项估算序列时长（speed=1；不启动播放）
	@param sequenceName string - 序列名称
	@param options PlayOptions? - fps/secondsPerFrame/playMode/startFrame/endFrame
	@return number? - 秒
]]
function SequenceManager:GetSequenceDuration(sequenceName: string, options: PlayOptions?): number?
	return nil
end

--[[
	序列是否存在且可播放
	@param sequenceName string - 序列名称
	@return boolean - true 表示存在且帧数 > 0
]]
function SequenceManager:HasSequence(sequenceName: string): boolean
	return false
end

--[[
	校验序列是否可安全播放
	@param sequenceName string - 序列名称
	@return boolean - true 无问题且可播放
	@return { CatalogIssue } - 问题列表；code 可为 NOT_FOUND / FRAME_GAP / INVALID_SHEET / EMPTY_SEQUENCE / INVALID_ARG 等
]]
function SequenceManager:ValidateSequence(sequenceName: string): (boolean, { CatalogIssue })
	return false, {}
end

--[[
	目录中全部可播放序列名（浅拷贝）
	@return { string } - 名称列表
]]
function SequenceManager:GetSequenceNames(): { string }
	return {}
end

--[[
	当前活跃播放实例数（含暂停）
	@return number - 数量
]]
function SequenceManager:GetActiveCount(): number
	return 0
end

--[[
	活跃播放诊断快照
	@return { DebugPlaybackEntry } - 摘要列表
]]
function SequenceManager:GetDebugSnapshot(): { DebugPlaybackEntry }
	return {}
end

--[[
	重新扫描 Sequence 目录（成功时清空预载 ImageId 标记）
	@param stopActive boolean? - 是否先停在播（默认 true，Keep）；false 则在播继续持旧帧
	@return boolean - true 目录存在并已重载
	@return string? - 失败时的 ErrorCode
	@return number - 因 stopActive 停止的实例数
]]
function SequenceManager:ReloadCatalog(stopActive: boolean?): (boolean, string?, number)
	return false, nil, 0
end

--[[
	客户端会话清理（StopAll + 断时钟 + 清 PeerPool/预载/临时 Gui）
	@return number - 停止的在播实例数
]]
function SequenceManager:Shutdown(): number
	return 0
end

--[[
	预加载序列资源（同步等待 ContentProvider）；可选暖场
	@param sequenceName string - 序列名称（Assets/Sequence 下 Folder 名）
	@param options PreloadOptions? - warmup / fps / onReady / strictWarmup
	@return boolean - true 预载成功；false 失败
	@return string? - 失败时的 ErrorCode
]]
function SequenceManager:Preload(sequenceName: string, options: PreloadOptions?): (boolean, string?)
	return false, nil
end

--[[
	异步预载（立即返回；完成后回调 onComplete）
	@param sequenceName string - 序列名称
	@param options PreloadOptions? - 同 Preload，另支持 onComplete(ok, err)；失败不调 onReady
	@return boolean - true 已调度
	@return string? - 失败时的 ErrorCode
	@return (() -> ())? - 取消：抑制回调并 Stop 暖场（ContentProvider 无法中断）
]]
function SequenceManager:PreloadAsync(sequenceName: string, options: PreloadOptions?): (boolean, string?, (() -> ())?)
	return false, nil, nil
end

--[[
	批量同步预载多个序列的图片（不含暖场）
	@param sequenceNames { string } - 序列名列表
	@param options PreloadOptions? - onProgress(done, total, name)
	@return boolean - true 全部成功
	@return string? - 失败时的 ErrorCode
]]
function SequenceManager:PreloadMany(sequenceNames: { string }, options: PreloadOptions?): (boolean, string?)
	return false, nil
end

-- 兼容旧 API 命名（弃用：请改用 Preload）
--[[
	兼容旧名：等价 Preload（请改用 Preload）
	@param self any - 冒号或点号调用时的接收者（内容忽略）
	@param ... any - 原样转发给 Preload 的 sequenceName 与 options
	@return boolean - true 预载成功
	@return string? - 失败时的 ErrorCode
]]
SequenceManager.PreLoad = SequenceManager.Preload

--[[
	通过 ContentProvider 预加载序列内图片资源（同步等待）
	@param sequenceName string - 序列名称（Assets/Sequence 下 Folder 名）
	@return boolean - true 成功或无需预载；false 失败
	@return string? - 失败时的 ErrorCode
]]
function SequenceManager:PreloadImages(sequenceName: string): (boolean, string?)
	return false, nil
end

--[[
	在 ImageLabel / ImageButton 上播放图片序列（Swap / Crossfade / CloneAll；多图/图集）

	PlaySequence(label, name, { fps = 12, loop = true, presentMode = "CloneAll", ... })
	迁移：旧 frameDuration=N → secondsPerFrame = 0.016 * N

	@param imageLabel ImageLabel|ImageButton - 播放目标（Crossfade 时兼作 bufferA）
	@param sequenceName string - 序列名称（Assets/Sequence 下 Folder 名）
	@param options PlayOptions - 须含 fps 或 secondsPerFrame
	@return boolean - true 开始播放（必含 handle）；false 失败或 Sync 回调内 ABORTED
	@return string? - 失败时的 ErrorCode
	@return PlaybackHandle? - 成功时非 nil
]]
function SequenceManager:PlaySequence(
	imageLabel: ImageLabel,
	sequenceName: string,
	options: PlayOptions
): (boolean, string?, PlaybackHandle?)
	return false, nil, nil
end

--[[
	运行行为契约自检（Seek 相位 / 帧连续性；客户端含 Stop nil 与 Sync-Stop ABORTED）
	@return boolean - true 全部通过
	@return { string } - 失败说明列表
]]
function SequenceManager:RunContractSelfTest(): (boolean, { string })
	return false, {}
end

return SequenceManager
