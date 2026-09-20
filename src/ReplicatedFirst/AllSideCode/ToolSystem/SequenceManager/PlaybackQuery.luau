--[[
	Module: PlaybackQuery
	Description: 序列播放只读查询（从 Playback 拆出以降有效代码行）
	Author: 林奥宇
	Created: 2026-07-31
	Last Modified: 2026-09-01
]]

local Types = require(script.Parent.Types)
local PlaybackRegistry = require(script.Parent.PlaybackRegistry)

type ImageTarget = GuiObject
type PlaybackState = Types.PlaybackState

local PlaybackQuery = {}

--[[
	区间内帧数（含端点）
	@param state Types.PlaybackState - 播放状态
	@return number - 帧数
]]
local function _rangeFrameCount(state: PlaybackState): number
	return math.max(1, state.rangeEnd - state.rangeStart + 1)
end

--[[
	一轮动画步进数（PingPong 为往返）
	@param state Types.PlaybackState - 播放状态
	@return number - 步进数
]]
local function _animStepCount(state: PlaybackState): number
	local n = _rangeFrameCount(state)
	if state.playMode == Types.PlayMode.PingPong then
		return math.max(1, (n - 1) * 2)
	end
	return n
end

--[[
	当前活跃播放实例数（含暂停）
	@return number - 数量
]]
function PlaybackQuery.GetActiveCount(): number
	return PlaybackRegistry.Count()
end

--[[
	当前播放在 speed=1 下的区间总时长（秒；PingPong 按往返）
	@param imageTarget GuiObject - 目标
	@return number? - 秒；未在播放时 nil
]]
function PlaybackQuery.GetDuration(imageTarget: ImageTarget): number?
	local state = PlaybackRegistry.Get(imageTarget)
	if not state or state.frameStep <= 0 then
		return nil
	end
	return _animStepCount(state) * state.frameStep
end

--[[
	当前层透明度；未在播放时 nil
	@param imageTarget GuiObject - 目标
	@return number? - [0, 1]
]]
function PlaybackQuery.GetLayerTransparency(imageTarget: ImageTarget): number?
	local state = PlaybackRegistry.Get(imageTarget)
	if not state then
		return nil
	end
	return state.layerTransparency
end

--[[
	是否正在播放（存在状态且未暂停；含循环间隔等待中）
	@param imageTarget GuiObject - 目标
	@return boolean - true 正在播
]]
function PlaybackQuery.IsPlaying(imageTarget: ImageTarget): boolean
	local state = PlaybackRegistry.Get(imageTarget)
	return state ~= nil and not state.paused
end

--[[
	是否已暂停
	@param imageTarget GuiObject - 目标
	@return boolean - true 已暂停
]]
function PlaybackQuery.IsPaused(imageTarget: ImageTarget): boolean
	local state = PlaybackRegistry.Get(imageTarget)
	return state ~= nil and state.paused
end

--[[
	当前帧下标（1-based）；未在播放时 nil
	@param imageTarget GuiObject - 目标
	@return number? - 当前帧
]]
function PlaybackQuery.GetCurrentFrame(imageTarget: ImageTarget): number?
	local state = PlaybackRegistry.Get(imageTarget)
	if not state then
		return nil
	end
	return state.currentFrame
end

--[[
	按当前帧在区间内的进度 [0, 1]
	@param imageTarget GuiObject - 目标
	@return number? - 帧进度
]]
function PlaybackQuery.GetFrameProgress(imageTarget: ImageTarget): number?
	local state = PlaybackRegistry.Get(imageTarget)
	if not state then
		return nil
	end
	local n = _rangeFrameCount(state)
	return (state.currentFrame - state.rangeStart + 1) / n
end

--[[
	兼容旧名：等同 GetFrameProgress
	@param imageTarget GuiObject - 目标
	@return number? - 帧进度
]]
function PlaybackQuery.GetProgress(imageTarget: ImageTarget): number?
	return PlaybackQuery.GetFrameProgress(imageTarget)
end

--[[
	按已播放时间估算动画相位进度 [0, 1]
	@param imageTarget GuiObject - 目标
	@return number? - 时间进度
]]
function PlaybackQuery.GetTimeProgress(imageTarget: ImageTarget): number?
	local state = PlaybackRegistry.Get(imageTarget)
	if not state or state.frameStep <= 0 then
		return nil
	end

	local cycle = _animStepCount(state) * state.frameStep
	if cycle <= 0 then
		return nil
	end

	if state.loop then
		return (state.playedTime % cycle) / cycle
	end
	return math.clamp(state.playedTime / cycle, 0, 1)
end

--[[
	handle 是否仍指向当前在播世代
	@param handle Types.PlaybackHandle - PlaySequence 返回的句柄
	@return boolean - true 仍有效
]]
function PlaybackQuery.IsHandleActive(handle: Types.PlaybackHandle): boolean
	if typeof(handle) ~= "table" or typeof(handle.id) ~= "number" then
		return false
	end
	local target = handle.target
	if typeof(target) ~= "Instance" then
		return false
	end
	local state = PlaybackRegistry.Get(target :: GuiObject)
	return state ~= nil and state.id == handle.id
end

--[[
	活跃播放诊断快照（排障用；返回新建表，可安全持有）
	@return { Types.DebugPlaybackEntry } - 当前全部在播摘要
]]
function PlaybackQuery.GetDebugSnapshot(): { Types.DebugPlaybackEntry }
	local list: { Types.DebugPlaybackEntry } = {}
	PlaybackRegistry.ForEach(function(label: GuiObject, state: PlaybackState)
		table.insert(list, {
			id = state.id,
			targetName = label.Name,
			sequenceName = state.sequenceName,
			currentFrame = state.currentFrame,
			rangeStart = state.rangeStart,
			rangeEnd = state.rangeEnd,
			presentMode = state.presentMode,
			playMode = state.playMode,
			kind = state.kind,
			paused = state.paused,
			speed = state.speed,
			direction = state.direction,
		})
	end)
	table.sort(list, function(a, b)
		return a.id < b.id
	end)
	return list
end

return PlaybackQuery
