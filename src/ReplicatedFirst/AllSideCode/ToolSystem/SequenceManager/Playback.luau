--[[
	Module: Playback
	Description: 序列播放装配与共享时钟推进（控制 API 见 PlaybackControl，查询见 PlaybackQuery）
	Author: 林奥宇
	Created: 2026-07-31
	Last Modified: 2026-09-01

	可靠性约定：
	- 每步推进后校验 Registry.IsActive，防止 Sync 回调 Stop/Play 重入写已清理状态
	- PlaySequence 先校验再停旧播；Setup 失败按 Restore 回滚播前快照
	- 出树停播以非 game 后代为准（换父瞬时 Parent=nil 不误停）
	- Play 成功必须返回 PlaybackHandle；Sync 回调内停播且无后继在播时返回 false, ABORTED
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local Log = Utils.Log

local Types = require(script.Parent.Types)
local Catalog = require(script.Parent.Catalog)
local PlayOptionsUtil = require(script.Parent.PlayOptionsUtil)
local PlaybackVisual = require(script.Parent.PlaybackVisual)
local PlaybackPresent = require(script.Parent.PlaybackPresent)
local PlaybackStep = require(script.Parent.PlaybackStep)
local PlaybackRegistry = require(script.Parent.PlaybackRegistry)
local PlaybackLifecycle = require(script.Parent.PlaybackLifecycle)
local PlaybackControl = require(script.Parent.PlaybackControl)

type ImageTarget = GuiObject
type PlayOptions = Types.PlayOptions
type SheetLayout = Types.SheetLayout
type PlaybackHandle = Types.PlaybackHandle
type PlaybackState = Types.PlaybackState
type SequenceFrameData = Types.SequenceFrameData

local Playback = {}

-- ============================================================================
-- 私有函数
-- ============================================================================

--[[
	读取播前外观快照（重播时继承首次快照）
	@param imageTarget GuiObject - 目标
	@param existing PlaybackState? - 已有状态
	@return string - savedImage
	@return boolean - savedVisible
	@return Vector2 - savedRectOffset
	@return Vector2 - savedRectSize
	@return number - savedTransparency
	@return Color3 - savedImageColor
]]
local function _captureRestoreSnapshot(
	imageTarget: ImageTarget,
	existing: PlaybackState?
): (string, boolean, Vector2, Vector2, number, Color3)
	if existing then
		return existing.savedImage,
			existing.savedVisible,
			existing.savedRectOffset,
			existing.savedRectSize,
			existing.savedTransparency,
			existing.savedImageColor
	end
	local img = imageTarget :: any
	return img.Image,
		imageTarget.Visible,
		img.ImageRectOffset,
		img.ImageRectSize,
		img.ImageTransparency,
		img.ImageColor3
end

--[[
	解析播放区间端点
	@param options PlayOptions - 选项
	@param frameCount number - 总帧数
	@return number - rangeStart
	@return number - rangeEnd
]]
local function _resolveRange(options: PlayOptions, frameCount: number): (number, number)
	local rangeStart = 1
	if options.startFrame then
		rangeStart = PlayOptionsUtil.ClampFrame(options.startFrame, frameCount)
	end
	local rangeEnd = frameCount
	if options.endFrame then
		rangeEnd = PlayOptionsUtil.ClampFrame(options.endFrame, frameCount)
	end
	if rangeEnd < rangeStart then
		rangeStart, rangeEnd = rangeEnd, rangeStart
	end
	return rangeStart, rangeEnd
end

--[[
	组装 PlaybackState（不含 Registry 登记 / Present 装配）
	@param imageTarget GuiObject - 目标
	@param sequenceName string - 序列名
	@param options PlayOptions - 已归一化选项
	@param sequenceData SequenceFrameData - 可播放数据
	@param frameStep number - 每帧秒数
	@param existing PlaybackState? - 已有状态（继承 Restore 快照）
	@return PlaybackState - 新状态
]]
local function _buildPlaybackState(
	imageTarget: ImageTarget,
	sequenceName: string,
	options: PlayOptions,
	sequenceData: SequenceFrameData,
	frameStep: number,
	existing: PlaybackState?
): PlaybackState
	local savedImage, savedVisible, savedRectOffset, savedRectSize, savedTransparency, savedImageColor =
		_captureRestoreSnapshot(imageTarget, existing)

	local rangeStart, rangeEnd = _resolveRange(options, sequenceData.count)

	local frameCopy: { string } = table.clone(sequenceData.frames)
	local sheetCopy: SheetLayout? = nil
	if sequenceData.sheet then
		sheetCopy = {
			imageId = sequenceData.sheet.imageId,
			cellWidth = sequenceData.sheet.cellWidth,
			cellHeight = sequenceData.sheet.cellHeight,
			columns = sequenceData.sheet.columns,
			padding = sequenceData.sheet.padding or 0,
			spacing = sequenceData.sheet.spacing or 0,
			rows = sequenceData.sheet.rows,
		}
	end

	local playId = PlaybackRegistry.AllocId()
	local presentMode = PlayOptionsUtil.NormalizePresentMode(options.presentMode)
	local playMode = PlayOptionsUtil.NormalizePlayMode(options.playMode)
	local startDirection = if playMode == Types.PlayMode.Reverse
		then -1
		elseif options.direction and options.direction < 0 then -1
		else 1
	local startFrame = if playMode == Types.PlayMode.Reverse then rangeEnd else rangeStart
	return {
		id = playId,
		presentId = tostring(playId),
		sequenceName = sequenceName,
		destroyConnection = nil,
		kind = sequenceData.kind,
		frames = frameCopy,
		sheet = sheetCopy,
		frameCount = sequenceData.count,
		rangeStart = rangeStart,
		rangeEnd = rangeEnd,
		currentFrame = startFrame,
		elapsed = 0,
		stopTime = 0,
		frameStep = frameStep,
		speed = options.speed or Types.DEFAULT_SPEED,
		paused = false,
		loop = options.loop == true,
		loopInterval = options.loopInterval or 0,
		stopPolicy = PlayOptionsUtil.NormalizeStopPolicy(options.stopPolicy),
		playMode = playMode,
		presentMode = presentMode,
		crossfadeSec = PlayOptionsUtil.NormalizeCrossfadeSec(options.crossfadeSec),
		layerTransparency = PlayOptionsUtil.NormalizeLayerTransparency(options.layerTransparency),
		crossfading = false,
		crossfadeElapsed = 0,
		activeIsA = true,
		bufferA = nil,
		bufferB = nil,
		clones = nil,
		nowShow = nil,
		direction = startDirection,
		forceVisible = if options.forceVisible == nil then true else options.forceVisible,
		callbackMode = PlayOptionsUtil.NormalizeCallbackMode(options.callbackMode),
		playedTime = 0,
		savedImage = savedImage,
		savedVisible = savedVisible,
		savedRectOffset = savedRectOffset,
		savedRectSize = savedRectSize,
		savedTransparency = savedTransparency,
		savedImageColor = savedImageColor,
		onComplete = options.onComplete,
		onLoop = options.onLoop,
		onFrame = options.onFrame,
		markers = if options.markers then table.clone(options.markers) else nil,
	}
end

--[[
	开播后解析返回：本世代仍活跃、或已被新 Play 替换则成功带 handle；否则 ABORTED
	@param imageTarget GuiObject - 目标
	@param state PlaybackState - 刚装配的世代
	@return boolean - true 成功
	@return string? - 失败时的 ErrorCode（仅 ABORTED）
	@return PlaybackHandle? - 成功时句柄
]]
local function _resolvePlayResult(imageTarget: ImageTarget, state: PlaybackState): (boolean, string?, PlaybackHandle?)
	if PlaybackRegistry.IsActive(imageTarget, state) then
		return true, nil, PlaybackLifecycle.MakeHandle(imageTarget, state)
	end
	local current = PlaybackRegistry.Get(imageTarget) :: PlaybackState?
	if current then
		return true, nil, PlaybackLifecycle.MakeHandle(imageTarget, current)
	end
	return false, Types.ErrorCode.ABORTED, nil
end

--[[
	共享时钟单实例推进
	@param imageTarget GuiObject - 目标
	@param state PlaybackState - 状态
	@param deltaTime number - Heartbeat dt
]]
local function _tickPlayback(imageTarget: ImageTarget, state: PlaybackState, deltaTime: number): ()
	if not PlaybackRegistry.IsActive(imageTarget, state) then
		return
	end

	-- Crossfade/CloneAll：暂停时也同步 peer，避免 UI 缩放后叠层错位
	if state.presentMode ~= Types.PresentMode.Swap then
		PlaybackPresent.SyncPeersFromPrimary(imageTarget, state)
	end

	if state.paused then
		return
	end

	if PlaybackPresent.Tick(state, deltaTime) then
		return
	end
	if not PlaybackRegistry.IsActive(imageTarget, state) then
		return
	end

	local scaledDt = deltaTime * state.speed

	if state.stopTime > 0 then
		state.stopTime -= scaledDt
		if state.stopTime < 0 then
			state.stopTime = 0
		end
		return
	end

	state.playedTime += scaledDt
	state.elapsed += scaledDt
	if state.elapsed < state.frameStep then
		return
	end

	local intervalIndex: number = math.floor(state.elapsed / state.frameStep)
	state.elapsed -= intervalIndex * state.frameStep

	-- Crossfade：每 tick 最多 1 逻辑帧；其它模式同 tick 可追到 MAX_CATCHUP_CALLBACKS（画面仍只刷最终帧）
	local maxSteps = if state.presentMode == Types.PresentMode.Crossfade
		then Types.MAX_STEPS_WHILE_CROSSFADE
		else Types.MAX_CATCHUP_CALLBACKS
	local steps = math.min(intervalIndex, maxSteps)
	if intervalIndex > steps then
		state.elapsed += (intervalIndex - steps) * state.frameStep
	end

	local frameBefore = state.currentFrame
	for _ = 1, steps do
		if not PlaybackRegistry.IsActive(imageTarget, state) then
			return
		end
		if PlaybackStep.StepOneFrame(imageTarget, state, PlaybackLifecycle.StopPlayback) then
			return
		end
	end

	if not PlaybackRegistry.IsActive(imageTarget, state) then
		return
	end

	if state.currentFrame ~= frameBefore or steps > 0 then
		PlaybackPresent.ShowCurrentFrame(imageTarget, state, false)
	end
end

PlaybackLifecycle.SetTickHandler(_tickPlayback)

-- ============================================================================
-- 公共函数（控制 API 转发，保持历史 require(script.Playback) 调用方兼容）
-- ============================================================================
Playback.StopSequence = PlaybackControl.StopSequence
Playback.StopHandle = PlaybackControl.StopHandle
Playback.StopAll = PlaybackControl.StopAll
Playback.PauseSequence = PlaybackControl.PauseSequence
Playback.ResumeSequence = PlaybackControl.ResumeSequence
Playback.PauseAll = PlaybackControl.PauseAll
Playback.ResumeAll = PlaybackControl.ResumeAll
Playback.Seek = PlaybackControl.Seek
Playback.SeekTime = PlaybackControl.SeekTime
Playback.SetSpeed = PlaybackControl.SetSpeed
Playback.SetLayerTransparency = PlaybackControl.SetLayerTransparency

--[[
	在 ImageLabel / ImageButton 上播放图片序列
	@param imageTarget GuiObject - 播放目标（Crossfade 时兼作 bufferA）
	@param sequenceName string - 序列名称
	@param options PlayOptions - 须含 fps 或 secondsPerFrame；含 loop / playMode / presentMode 等
	@return boolean - true 开始播放（必含 handle）；false 参数/资源/环境无效或 Sync 回调内已中止
	@return string? - 失败时的 ErrorCode
	@return PlaybackHandle? - 成功时的句柄（成功路径非 nil）
]]
function Playback.PlaySequence(
	imageTarget: ImageTarget,
	sequenceName: string,
	optionsInput: PlayOptions
): (boolean, string?, PlaybackHandle?)
	if not PlaybackLifecycle.IsClient() then
		Log.warn("[SequenceManager] 仅客户端可用")
		return false, Types.ErrorCode.NOT_CLIENT, nil
	end

	if typeof(imageTarget) ~= "Instance" or not PlaybackLifecycle.IsImageTarget(imageTarget) then
		Log.warn("[SequenceManager] PlaySequence 需要 ImageLabel 或 ImageButton")
		return false, Types.ErrorCode.INVALID_ARG, nil
	end

	if typeof(sequenceName) ~= "string" or sequenceName == "" then
		Log.warn("[SequenceManager] PlaySequence 参数无效")
		return false, Types.ErrorCode.INVALID_ARG, nil
	end

	local options, optionsErr = PlayOptionsUtil.ResolvePlayOptions(optionsInput)
	if not options then
		return false, optionsErr, nil
	end

	local frameStep, timingErr = PlayOptionsUtil.ResolveFrameStep(options)
	if not frameStep then
		Log.warn("[SequenceManager] PlaySequence 时间参数无效（须 options.fps 或 options.secondsPerFrame）")
		return false, timingErr or Types.ErrorCode.INVALID_TIMING, nil
	end

	local sequenceData, dataErr = PlayOptionsUtil.ResolvePlayData(
		options,
		Catalog.GetSequenceData(sequenceName)
	)
	if not sequenceData then
		Log.warn("[SequenceManager] 序列不可用:", sequenceName, dataErr)
		return false, dataErr, nil
	end

	local existing = PlaybackRegistry.Get(imageTarget) :: PlaybackState?
	local state = _buildPlaybackState(imageTarget, sequenceName, options, sequenceData, frameStep, existing)

	PlaybackLifecycle.StopPlayback(imageTarget, { skipVisual = true })

	local setupOk, setupErr = PlaybackPresent.Setup(imageTarget, state)
	if not setupOk then
		Log.warn("[SequenceManager] 表现层初始化失败:", sequenceName, setupErr)
		PlaybackVisual.ApplyStopVisual(imageTarget, state, Types.StopPolicy.Restore)
		return false, setupErr, nil
	end

	PlaybackRegistry.Set(imageTarget, state)
	PlaybackLifecycle.EnsureSharedClock()
	PlaybackLifecycle.BindDestroyCleanup(imageTarget, state)
	PlaybackPresent.ShowCurrentFrame(imageTarget, state, true)

	if not PlaybackRegistry.IsActive(imageTarget, state) then
		return _resolvePlayResult(imageTarget, state)
	end

	PlaybackVisual.FireFrameCallbacks(imageTarget, state, state.currentFrame)

	return _resolvePlayResult(imageTarget, state)
end

return Playback
