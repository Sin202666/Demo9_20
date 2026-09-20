--[[
	Module: PlaybackStep
	Description: 序列逻辑帧推进与边界解析（Forward / Reverse / PingPong；支持 rangeStart/rangeEnd）
	Author: 林奥宇
	Created: 2026-07-31
	Last Modified: 2026-09-01

	Reverse 与 Forward 共用越界处理（依赖 direction=-1 与起始末帧）；PingPong 单独掉头。
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local Log = Utils.Log

local Types = require(script.Parent.Types)
local PlaybackVisual = require(script.Parent.PlaybackVisual)

type ImageTarget = GuiObject
type StopOpts = Types.StopOpts
type StepState = Types.PlaybackState
type StopPlaybackFn = (ImageTarget, StopOpts?) -> boolean

local PlaybackStep = {}

--[[
	进入循环间隔等待，并触发 onLoop
	@param state StepState - 可变状态
]]
local function _enterLoopGap(state: StepState): ()
	state.stopTime = state.loopInterval
	state.elapsed = 0
	if state.onLoop then
		task.spawn(function()
			local ok, err = pcall(state.onLoop)
			if not ok then
				Log.warn("[SequenceManager] onLoop 异常:", err)
			end
		end)
	end
end

--[[
	自然结束：停播并触发 onComplete
	@param imageTarget GuiObject - 目标
	@param state StepState - 状态（停播前读取回调）
	@param stopPlayback StopPlaybackFn - 主模块停播实现
	@return boolean - 恒为 true（表示已停止）
]]
local function _finishPlayback(imageTarget: ImageTarget, state: StepState, stopPlayback: StopPlaybackFn): boolean
	local onComplete = state.onComplete
	stopPlayback(imageTarget, { policy = state.stopPolicy })
	if onComplete then
		task.spawn(function()
			local ok, err = pcall(onComplete)
			if not ok then
				Log.warn("[SequenceManager] onComplete 异常:", err)
			end
		end)
	end
	return true
end

--[[
	Forward/Reverse 越界：循环则回到端点并进入间隔；否则结束
	@param imageTarget GuiObject - 目标
	@param state StepState - 状态
	@param pastEnd boolean - true 表示越过末帧，false 表示越过首帧
	@param stopPlayback StopPlaybackFn - 主模块停播实现
	@return boolean - true 表示已停止
]]
local function _resolveLinearOverflow(
	imageTarget: ImageTarget,
	state: StepState,
	pastEnd: boolean,
	stopPlayback: StopPlaybackFn
): boolean
	if not state.loop then
		return _finishPlayback(imageTarget, state, stopPlayback)
	end

	-- Reverse 越过首帧回到末帧；Forward 越过末帧回到首帧
	if state.playMode == Types.PlayMode.Reverse then
		state.currentFrame = if pastEnd then state.rangeStart else state.rangeEnd
		state.direction = -1
	else
		state.currentFrame = if pastEnd then state.rangeStart else state.rangeEnd
	end
	_enterLoopGap(state)
	PlaybackVisual.FireFrameCallbacks(imageTarget, state, state.currentFrame)
	return false
end

--[[
	PingPong 越过末帧：掉头；单帧或循环间隔；不可循环则结束
	@param imageTarget GuiObject - 目标
	@param state StepState - 状态
	@param stopPlayback StopPlaybackFn - 主模块停播实现
	@return number? - 新的 nextFrame；已停止时 nil
	@return boolean - true 表示已停止
]]
local function _resolvePingPongPastEnd(
	imageTarget: ImageTarget,
	state: StepState,
	stopPlayback: StopPlaybackFn
): (number?, boolean)
	state.direction = -1
	local nextFrame = state.rangeEnd - 1
	if nextFrame < state.rangeStart then
		nextFrame = state.rangeStart
	end

	if state.rangeEnd <= state.rangeStart then
		if state.loop then
			_enterLoopGap(state)
			PlaybackVisual.FireFrameCallbacks(imageTarget, state, state.currentFrame)
			return nil, false
		end
		return nil, _finishPlayback(imageTarget, state, stopPlayback)
	end

	return nextFrame, false
end

--[[
	PingPong 越过首帧：循环则掉头进入间隔；否则结束
	@param imageTarget GuiObject - 目标
	@param state StepState - 状态
	@param stopPlayback StopPlaybackFn - 主模块停播实现
	@return number? - 新的 nextFrame；已停止时 nil
	@return boolean - true 表示已停止
]]
local function _resolvePingPongPastStart(
	imageTarget: ImageTarget,
	state: StepState,
	stopPlayback: StopPlaybackFn
): (number?, boolean)
	if not state.loop then
		return nil, _finishPlayback(imageTarget, state, stopPlayback)
	end

	state.direction = 1
	local nextFrame = state.rangeStart + 1
	if nextFrame > state.rangeEnd then
		nextFrame = state.rangeStart
	end
	state.currentFrame = nextFrame
	_enterLoopGap(state)
	PlaybackVisual.FireFrameCallbacks(imageTarget, state, state.currentFrame)
	return nil, false
end

--[[
	推进一帧；若已自然结束并清理状态则返回 true
	@param imageTarget GuiObject - 目标
	@param state StepState - 可变状态
	@param stopPlayback StopPlaybackFn - 主模块停播实现
	@return boolean - true 表示已停止（调用方勿再写帧）
]]
function PlaybackStep.StepOneFrame(
	imageTarget: ImageTarget,
	state: StepState,
	stopPlayback: StopPlaybackFn
): boolean
	local nextFrame = state.currentFrame + state.direction

	if nextFrame > state.rangeEnd then
		if state.playMode == Types.PlayMode.PingPong then
			local resolved, stopped = _resolvePingPongPastEnd(imageTarget, state, stopPlayback)
			if stopped then
				return true
			end
			if not resolved then
				return false
			end
			nextFrame = resolved
		else
			return _resolveLinearOverflow(imageTarget, state, true, stopPlayback)
		end
	elseif nextFrame < state.rangeStart then
		if state.playMode == Types.PlayMode.PingPong then
			local _, stopped = _resolvePingPongPastStart(imageTarget, state, stopPlayback)
			return stopped
		end
		return _resolveLinearOverflow(imageTarget, state, false, stopPlayback)
	end

	state.currentFrame = nextFrame
	PlaybackVisual.FireFrameCallbacks(imageTarget, state, state.currentFrame)
	return false
end

return PlaybackStep
