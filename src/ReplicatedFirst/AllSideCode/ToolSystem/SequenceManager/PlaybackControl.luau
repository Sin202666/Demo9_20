--[[
	Module: PlaybackControl
	Description: 序列播放控制 API（Stop / Pause / Seek / Speed 等；从 Playback 拆出）
	Author: 林奥宇
	Created: 2026-07-31
	Last Modified: 2026-09-01
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local Log = Utils.Log

local Types = require(script.Parent.Types)
local PlayOptionsUtil = require(script.Parent.PlayOptionsUtil)
local PlaybackPresent = require(script.Parent.PlaybackPresent)
local PlaybackVisual = require(script.Parent.PlaybackVisual)
local PlaybackRegistry = require(script.Parent.PlaybackRegistry)
local PlaybackLifecycle = require(script.Parent.PlaybackLifecycle)

type ImageTarget = GuiObject
type StopPolicyValue = Types.StopPolicyValue
type PlaybackHandle = Types.PlaybackHandle

local PlaybackControl = {}

-- ============================================================================
-- 公共函数
-- ============================================================================

--[[
	停止指定控件上的序列播放
	@param imageTarget GuiObject? - 要停止的目标，nil 时无操作
	@param policy StopPolicyValue? - 覆盖该次停止策略（仅当确实在播时生效）
	@param handle PlaybackHandle? - 可选；与当前世代不一致时返回 STALE_HANDLE
	@return boolean - true 已停止或目标本无播放；false 参数/环境无效
	@return string? - 失败时的 ErrorCode
]]
function PlaybackControl.StopSequence(
	imageTarget: ImageTarget?,
	policy: StopPolicyValue?,
	handle: PlaybackHandle?
): (boolean, string?)
	if not PlaybackLifecycle.IsClient() then
		Log.warn("[SequenceManager] 仅客户端可用")
		return false, Types.ErrorCode.NOT_CLIENT
	end

	-- 与门面/Type 桩一致：nil 目标视为无操作成功
	if not imageTarget then
		return true, nil
	end

	if handle ~= nil then
		local _, err = PlaybackLifecycle.ResolveState(imageTarget, handle)
		if err == Types.ErrorCode.STALE_HANDLE then
			return false, err
		end
		if err == Types.ErrorCode.NOT_PLAYING then
			return true, nil
		end
	end

	PlaybackLifecycle.StopPlayback(imageTarget, {
		policy = if policy then PlayOptionsUtil.NormalizeStopPolicy(policy) else nil,
	})

	-- 无活跃播放时不改外观（避免防御性 Stop 误清空静态图）
	return true, nil
end

--[[
	按 PlaybackHandle 停止
	@param handle PlaybackHandle - PlaySequence 返回的句柄
	@param policy StopPolicyValue? - 覆盖停止策略
	@return boolean - true 成功或已无对应播放
	@return string? - 失败时的 ErrorCode
]]
function PlaybackControl.StopHandle(handle: PlaybackHandle, policy: StopPolicyValue?): (boolean, string?)
	if typeof(handle) ~= "table" or typeof(handle.id) ~= "number" then
		return false, Types.ErrorCode.INVALID_ARG
	end
	local target = handle.target
	if typeof(target) ~= "Instance" then
		return false, Types.ErrorCode.INVALID_ARG
	end
	return PlaybackControl.StopSequence(target :: ImageTarget, policy, handle)
end

--[[
	停止全部在播序列
	@param policy StopPolicyValue? - 统一覆盖停止策略
	@return number - 实际停止的数量
]]
function PlaybackControl.StopAll(policy: StopPolicyValue?): number
	if not PlaybackLifecycle.IsClient() then
		Log.warn("[SequenceManager] 仅客户端可用")
		return 0
	end

	local labels = PlaybackRegistry.CollectTargets()
	local count = 0
	for _, label in ipairs(labels) do
		if PlaybackLifecycle.StopPlayback(label, {
			policy = if policy then PlayOptionsUtil.NormalizeStopPolicy(policy) else nil,
		}) then
			count += 1
		end
	end
	return count
end

--[[
	暂停播放
	@param imageTarget GuiObject - 目标
	@param handle PlaybackHandle? - 可选世代校验
	@return boolean - true 成功
	@return string? - 失败时的 ErrorCode
]]
function PlaybackControl.PauseSequence(imageTarget: ImageTarget, handle: PlaybackHandle?): (boolean, string?)
	if not PlaybackLifecycle.IsClient() then
		Log.warn("[SequenceManager] 仅客户端可用")
		return false, Types.ErrorCode.NOT_CLIENT
	end

	local state, err = PlaybackLifecycle.ResolveState(imageTarget, handle)
	if not state then
		return false, err
	end

	state.paused = true
	return true, nil
end

--[[
	恢复已暂停的播放
	@param imageTarget GuiObject - 目标
	@param handle PlaybackHandle? - 可选世代校验
	@return boolean - true 成功
	@return string? - 失败时的 ErrorCode
]]
function PlaybackControl.ResumeSequence(imageTarget: ImageTarget, handle: PlaybackHandle?): (boolean, string?)
	if not PlaybackLifecycle.IsClient() then
		Log.warn("[SequenceManager] 仅客户端可用")
		return false, Types.ErrorCode.NOT_CLIENT
	end

	local state, err = PlaybackLifecycle.ResolveState(imageTarget, handle)
	if not state then
		return false, err
	end

	state.paused = false
	return true, nil
end

--[[
	暂停全部在播实例（已暂停的跳过）
	@return number - 新置为暂停的数量
]]
function PlaybackControl.PauseAll(): number
	if not PlaybackLifecycle.IsClient() then
		Log.warn("[SequenceManager] 仅客户端可用")
		return 0
	end

	local count = 0
	for _, label in ipairs(PlaybackRegistry.CollectTargets()) do
		local state = PlaybackRegistry.Get(label)
		if state and not state.paused then
			state.paused = true
			count += 1
		end
	end
	return count
end

--[[
	恢复全部已暂停实例（未暂停的跳过）
	@return number - 新恢复的数量
]]
function PlaybackControl.ResumeAll(): number
	if not PlaybackLifecycle.IsClient() then
		Log.warn("[SequenceManager] 仅客户端可用")
		return 0
	end

	local count = 0
	for _, label in ipairs(PlaybackRegistry.CollectTargets()) do
		local state = PlaybackRegistry.Get(label)
		if state and state.paused then
			state.paused = false
			count += 1
		end
	end
	return count
end

--[[
	跳转到指定帧（1-based）；PingPong 时同步 direction（端点定方向，中间保留）
	@param imageTarget GuiObject - 目标
	@param frame number - 目标帧
	@param handle PlaybackHandle? - 可选世代校验
	@return boolean - true 成功
	@return string? - 失败时的 ErrorCode
]]
function PlaybackControl.Seek(imageTarget: ImageTarget, frame: number, handle: PlaybackHandle?): (boolean, string?)
	if not PlaybackLifecycle.IsClient() then
		Log.warn("[SequenceManager] 仅客户端可用")
		return false, Types.ErrorCode.NOT_CLIENT
	end

	if typeof(frame) ~= "number" then
		return false, Types.ErrorCode.INVALID_ARG
	end

	local state, err = PlaybackLifecycle.ResolveState(imageTarget, handle)
	if not state then
		return false, err
	end

	state.currentFrame = math.clamp(math.floor(frame), state.rangeStart, state.rangeEnd)
	state.direction = PlaybackLifecycle.DirectionForSeekFrame(state, state.currentFrame)
	state.elapsed = 0
	state.stopTime = 0
	if state.playMode == Types.PlayMode.Reverse then
		state.playedTime = (state.rangeEnd - state.currentFrame) * state.frameStep
	else
		state.playedTime = (state.currentFrame - state.rangeStart) * state.frameStep
	end
	state.crossfading = false
	state.crossfadeElapsed = 0
	state.activeIsA = true
	PlaybackPresent.ShowCurrentFrame(imageTarget, state, true)
	if PlaybackRegistry.IsActive(imageTarget, state) then
		PlaybackVisual.FireFrameCallbacks(imageTarget, state, state.currentFrame)
	end
	return true, nil
end

--[[
	按时间跳转（秒；写入 ResolveSeekPhase 的 frame + direction，保留帧内 elapsed）
	@param imageTarget GuiObject - 目标
	@param timeSec number - 秒，须 >= 0
	@param handle PlaybackHandle? - 可选世代校验
	@return boolean - true 成功
	@return string? - 失败时的 ErrorCode
]]
function PlaybackControl.SeekTime(imageTarget: ImageTarget, timeSec: number, handle: PlaybackHandle?): (boolean, string?)
	if not PlaybackLifecycle.IsClient() then
		Log.warn("[SequenceManager] 仅客户端可用")
		return false, Types.ErrorCode.NOT_CLIENT
	end

	if typeof(timeSec) ~= "number" or timeSec < 0 then
		return false, Types.ErrorCode.INVALID_ARG
	end

	local state, err = PlaybackLifecycle.ResolveState(imageTarget, handle)
	if not state then
		return false, err
	end

	local phase = PlaybackLifecycle.ResolveSeekPhase(state, timeSec)
	state.currentFrame = phase.frame
	state.direction = phase.direction
	if state.frameStep > 0 then
		local steps = math.max(0, math.floor(timeSec / state.frameStep))
		state.elapsed = timeSec - steps * state.frameStep
	else
		state.elapsed = 0
	end
	state.stopTime = 0
	state.playedTime = timeSec
	state.crossfading = false
	state.crossfadeElapsed = 0
	state.activeIsA = true
	PlaybackPresent.ShowCurrentFrame(imageTarget, state, true)
	if PlaybackRegistry.IsActive(imageTarget, state) then
		PlaybackVisual.FireFrameCallbacks(imageTarget, state, state.currentFrame)
	end
	return true, nil
end

--[[
	设置播放速率
	@param imageTarget GuiObject - 目标
	@param speed number - 速率，须 > 0
	@param handle PlaybackHandle? - 可选世代校验
	@return boolean - true 成功
	@return string? - 失败时的 ErrorCode
]]
function PlaybackControl.SetSpeed(imageTarget: ImageTarget, speed: number, handle: PlaybackHandle?): (boolean, string?)
	if not PlaybackLifecycle.IsClient() then
		Log.warn("[SequenceManager] 仅客户端可用")
		return false, Types.ErrorCode.NOT_CLIENT
	end

	if not speed or speed <= 0 then
		Log.warn("[SequenceManager] SetSpeed 参数无效")
		return false, Types.ErrorCode.INVALID_ARG
	end

	local state, err = PlaybackLifecycle.ResolveState(imageTarget, handle)
	if not state then
		return false, err
	end

	state.speed = speed
	return true, nil
end

--[[
	设置层 ImageTransparency
	@param imageTarget GuiObject - 目标
	@param transparency number - 透明度
	@param handle PlaybackHandle? - 可选世代校验
	@return boolean - true 成功
	@return string? - 失败时的 ErrorCode
]]
function PlaybackControl.SetLayerTransparency(
	imageTarget: ImageTarget,
	transparency: number,
	handle: PlaybackHandle?
): (boolean, string?)
	if not PlaybackLifecycle.IsClient() then
		Log.warn("[SequenceManager] 仅客户端可用")
		return false, Types.ErrorCode.NOT_CLIENT
	end

	if typeof(transparency) ~= "number" then
		return false, Types.ErrorCode.INVALID_ARG
	end

	local state, err = PlaybackLifecycle.ResolveState(imageTarget, handle)
	if not state then
		return false, err
	end

	state.layerTransparency = PlayOptionsUtil.NormalizeLayerTransparency(transparency)
	PlaybackPresent.ApplyLayerTransparency(state)
	return true, nil
end

return PlaybackControl
