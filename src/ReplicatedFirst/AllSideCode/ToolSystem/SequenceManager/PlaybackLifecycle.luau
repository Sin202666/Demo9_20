--[[
	Module: PlaybackLifecycle
	Description: 播放停播、共享时钟、世代解析与生命周期绑定（供 Playback / PlaybackControl 共用）
	Author: 林奥宇
	Created: 2026-07-31
	Last Modified: 2026-09-01

	Seek 相位：
	- ResolveSeekPhase(time) 同时给出 frame + direction（PingPong 往返）
	- DirectionForSeekFrame(frame) 用于 Seek(帧)：端点定方向，中间帧保留当前方向
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local Log = Utils.Log
local RunService = Utils.RunService

local Types = require(script.Parent.Types)
local PlayOptionsUtil = require(script.Parent.PlayOptionsUtil)
local PlaybackVisual = require(script.Parent.PlaybackVisual)
local PlaybackPresent = require(script.Parent.PlaybackPresent)
local PlaybackRegistry = require(script.Parent.PlaybackRegistry)

type ImageTarget = GuiObject
type Connection = typeof(RunService.Heartbeat:Connect(function() end))
type StopOpts = Types.StopOpts
type PlaybackHandle = Types.PlaybackHandle
type PlaybackState = Types.PlaybackState
type SeekPhase = Types.SeekPhase

local PlaybackLifecycle = {}

-- ============================================================================
-- 私有变量
-- ============================================================================
local sharedClock: Connection? = nil
local _tickPlayback: ((ImageTarget, PlaybackState, number) -> ())? = nil
local _tickLabels: { GuiObject } = {}

-- ============================================================================
-- 公共函数
-- ============================================================================

--[[
	是否为可播放的 Image 控件
	@param inst Instance - 候选
	@return boolean - ImageLabel 或 ImageButton
]]
function PlaybackLifecycle.IsImageTarget(inst: Instance): boolean
	return inst:IsA("ImageLabel") or inst:IsA("ImageButton")
end

--[[
	是否为客户端运行环境
	@return boolean - true 表示客户端
]]
function PlaybackLifecycle.IsClient(): boolean
	return RunService:IsClient()
end

--[[
	区间内帧数（含端点）
	@param state Types.PlaybackState - 播放状态
	@return number - 帧数
]]
function PlaybackLifecycle.RangeFrameCount(state: PlaybackState): number
	return math.max(1, state.rangeEnd - state.rangeStart + 1)
end

--[[
	解析目标状态；可选 handle 世代校验
	@param imageTarget GuiObject - 目标
	@param handle PlaybackHandle? - 可选句柄
	@return Types.PlaybackState? - 有效状态
	@return string? - 失败 ErrorCode
]]
function PlaybackLifecycle.ResolveState(imageTarget: ImageTarget, handle: PlaybackHandle?): (PlaybackState?, string?)
	local state = PlaybackRegistry.Get(imageTarget)
	if not state then
		return nil, Types.ErrorCode.NOT_PLAYING
	end
	if handle ~= nil then
		if typeof(handle) ~= "table" or handle.id ~= state.id then
			return nil, Types.ErrorCode.STALE_HANDLE
		end
	end
	return state, nil
end

--[[
	构造对外 PlaybackHandle
	@param imageTarget GuiObject - 目标
	@param state Types.PlaybackState - 播放状态
	@return PlaybackHandle - 句柄
]]
function PlaybackLifecycle.MakeHandle(imageTarget: ImageTarget, state: PlaybackState): PlaybackHandle
	return {
		id = state.id,
		target = imageTarget,
	}
end

--[[
	按目标帧推断 PingPong/Forward 方向（Seek 用）
	端点：首帧 → +1，末帧 → -1；中间帧保留 state.direction（往返歧义）
	@param state Types.PlaybackState - 播放状态
	@param frame number - 目标绝对帧（调用方宜先钳制）
	@return number - 1 或 -1
]]
function PlaybackLifecycle.DirectionForSeekFrame(state: PlaybackState, frame: number): number
	if state.playMode == Types.PlayMode.Reverse then
		return -1
	end
	local dir = if state.direction < 0 then -1 else 1
	if state.playMode ~= Types.PlayMode.PingPong then
		return dir
	end
	if frame >= state.rangeEnd then
		return -1
	end
	if frame <= state.rangeStart then
		return 1
	end
	return dir
end

--[[
	将墙钟秒映射为区间内帧 + 方向（PingPong 含往返相位）
	@param state Types.PlaybackState - 播放状态
	@param timeSec number - 相位时间（秒，>=0）
	@return Types.SeekPhase - frame（1-based）与 direction（1|-1）
]]
function PlaybackLifecycle.ResolveSeekPhase(state: PlaybackState, timeSec: number): SeekPhase
	local n = PlaybackLifecycle.RangeFrameCount(state)
	if n <= 1 or state.frameStep <= 0 then
		return {
			frame = state.rangeStart,
			direction = 1,
		}
	end

	local steps = math.max(0, math.floor(timeSec / state.frameStep))
	if state.playMode == Types.PlayMode.PingPong then
		local cycle = math.max(1, (n - 1) * 2)
		local idx = steps % cycle
		if idx < n then
			return {
				frame = state.rangeStart + idx,
				direction = if idx >= (n - 1) then -1 else 1,
			}
		end
		return {
			frame = state.rangeEnd - (idx - (n - 1)),
			direction = -1,
		}
	end

	if state.playMode == Types.PlayMode.Reverse then
		local frame: number
		if state.loop then
			frame = state.rangeEnd - (steps % n)
		else
			frame = math.clamp(state.rangeEnd - steps, state.rangeStart, state.rangeEnd)
		end
		return {
			frame = frame,
			direction = -1,
		}
	end

	local frame: number
	if state.loop then
		frame = state.rangeStart + (steps % n)
	else
		frame = math.clamp(state.rangeStart + steps, state.rangeStart, state.rangeEnd)
	end
	return {
		frame = frame,
		direction = if state.direction < 0 then -1 else 1,
	}
end

--[[
	将墙钟秒映射到区间内帧（1-based）；等价 ResolveSeekPhase(...).frame
	@param state Types.PlaybackState - 播放状态
	@param timeSec number - 相位时间（秒）
	@return number - 帧下标
]]
function PlaybackLifecycle.FrameFromTime(state: PlaybackState, timeSec: number): number
	return PlaybackLifecycle.ResolveSeekPhase(state, timeSec).frame
end

--[[
	无活跃播放时断开共享 Heartbeat
]]
local function _releaseSharedClockIfIdle(): ()
	if not PlaybackRegistry.IsEmpty() then
		return
	end
	if sharedClock then
		sharedClock:Disconnect()
		sharedClock = nil
	end
end

--[[
	强制断开共享时钟（Shutdown；通常 StopAll 后已空闲断开）
]]
function PlaybackLifecycle.DisconnectSharedClock(): ()
	if sharedClock then
		sharedClock:Disconnect()
		sharedClock = nil
	end
end

--[[
	注册 tick 实现（由 Playback 注入，打破与 Step 的环）
	@param tickFn (GuiObject, Types.PlaybackState, number) -> () - 单实例推进
]]
function PlaybackLifecycle.SetTickHandler(tickFn: (ImageTarget, PlaybackState, number) -> ()): ()
	_tickPlayback = tickFn
end

--[[
	确保共享 Heartbeat 已连接（全局仅一条）
]]
function PlaybackLifecycle.EnsureSharedClock(): ()
	if sharedClock then
		return
	end

	sharedClock = RunService.Heartbeat:Connect(function(deltaTime: number)
		local labels = PlaybackRegistry.CollectTargetsInto(_tickLabels)
		local tickFn = _tickPlayback
		if not tickFn then
			return
		end

		for i = 1, #labels do
			local label = labels[i]
			local state = PlaybackRegistry.Get(label)
			if state then
				local ok, err = pcall(tickFn, label, state, deltaTime)
				if not ok then
					Log.warn("[SequenceManager] 播放推进异常:", label.Name, err)
				end
			end
		end
	end)
end

--[[
	停止播放并移除状态（可选跳过外观处理）
	@param imageTarget GuiObject - 目标
	@param opts StopOpts? - policy / skipVisual
	@return boolean - 是否存在过播放状态
]]
function PlaybackLifecycle.StopPlayback(imageTarget: ImageTarget, opts: StopOpts?): boolean
	local state = PlaybackRegistry.Get(imageTarget)
	if not state then
		return false
	end

	if state.destroyConnection then
		state.destroyConnection:Disconnect()
		state.destroyConnection = nil
	end
	PlaybackRegistry.Remove(imageTarget)
	_releaseSharedClockIfIdle()

	PlaybackPresent.Cleanup(imageTarget, state)

	local skipVisual = opts and opts.skipVisual
	if not skipVisual then
		local policy = PlayOptionsUtil.NormalizeStopPolicy(if opts and opts.policy then opts.policy else state.stopPolicy)
		PlaybackVisual.ApplyStopVisual(imageTarget, state, policy)
	end

	return true
end

--[[
	注册 Destroying + AncestryChanged：Destroy 或脱离 DataModel 均停播
	@param imageTarget GuiObject - 播放目标
	@param state Types.PlaybackState - 写入 destroyConnection
]]
function PlaybackLifecycle.BindDestroyCleanup(imageTarget: ImageTarget, state: PlaybackState): ()
	--[[
		Destroy 或脱离 DataModel 时停播（换父瞬时 Parent=nil 不走这条）
	]]
	local function _onGone()
		if PlaybackRegistry.IsActive(imageTarget, state) then
			PlaybackLifecycle.StopPlayback(imageTarget, { skipVisual = true })
		end
	end

	local destroyingConn = imageTarget.Destroying:Connect(_onGone)
	local ancestryConn = imageTarget.AncestryChanged:Connect(function()
		if not imageTarget:IsDescendantOf(game) then
			_onGone()
		end
	end)

	state.destroyConnection = {
		Disconnect = function()
			destroyingConn:Disconnect()
			ancestryConn:Disconnect()
		end,
	} :: any
end

return PlaybackLifecycle
