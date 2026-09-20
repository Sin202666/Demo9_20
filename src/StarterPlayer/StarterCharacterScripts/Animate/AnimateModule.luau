--[[
	Module: AnimateModule
	Description: 角色动画播放类（基本 locomotion、StrafeBlend 方向混合、衔接轨 playTransition）。
	Author: 林奥宇
	Created: 2026-07-03
	Last Modified: 2026-09-03

	使用：
	local Animate = require(script.AnimateModule) -- 单例，绑定当前 Character
	Animate:bindBaseAction("Run", { ID = "...", Priority = Enum.AnimationPriority.Movement })
	Animate:setBasePos("Run")
	Animate:setStrafeBlend("Run", weights, speedScale, options) -- ShiftLock 方向混合
	角色销毁时 Animate:destroy()
	注：翻滚层已移除，取消类动作请经 ActionArbiter 接入；ShiftLock 方向用 StrafeBlend。
	稳态 Walk↔Run：GaitBlend 短 fade + 归一化脚相位对齐（见 AnimateSetting.GaitBlend）。
	Strafe 激活时 Walk↔Run 保留 cardinal 权重跨步态族 retarget，不清成前向单轨（避免侧移加速闪一下）。
	Gate：stopBaseAction 停基轨；resumeBaseAction 只使能；invalidateBasePose 后由调用方按当前态 setBasePos。
]]
local Class = require(game.ReplicatedFirst.AllSideCode.Class.Class)
local Setting = require(script.Parent.AnimateSetting)
type BaseAnimateEnum = typeof(Class.BaseAnimateEnum)
type AnimateType = typeof(Class.AnimateType)

-- fadeTime: 兼容旧配置；middleDuration 与 Stopped 取较晚后再 onComplete
type TransitionPlayOptions = {
	fadeTime: number | nil,
	fadeIn: number | nil,
	fadeOut: number | nil,
	middleDuration: number | nil,
	animationSpeed: number | nil,
}

-- 动画编辑器里 Marker 名称 -> 到达该标记时的回调（第二个参数为标记携带的参数字符串）
export type AnimationMarkerEvents = { [string]: (string) -> () }

local Animate = {}
Animate.__index = Animate

-- 方案D：Walk/Run 方向切换淡入淡出时间，延长至 0.18 秒减少抖动
local BASE_ACTION_FADE_TIME = 0.18

-- ========================================
-- 私有函数
-- ========================================

local TRANSITION_POSES: { [string]: boolean } = {
	StartRun = true,
	StopRun = true,
	StartWalk = true,
	StopWalk = true,
}

--[[
	是否为地面起停衔接姿态（Start*/Stop*）
	@param basePos string - BasePos 名
	@return boolean - true 表示衔接轨，Stop 淡出可读 _transitionExitFadeOut
]]
local function _isTransitionPose(basePos: string): boolean
	return TRANSITION_POSES[basePos] == true
end

--[[
	是否为稳态 locomotion 步态（可做 Walk↔Run 相位对齐）
	@param pos string - BasePos 名
	@return boolean - true 表示 Walk 或 Run
]]
local function _isLocomotionGait(pos: string): boolean
	return pos == "Walk" or pos == "Run"
end

--[[
	读取当前 locomotion 归一化脚相位 [0,1)
	优先 Strafe leader 轨，否则 CurrentBaseTrack
	@param self AnimateType - 动画实例
	@return number? - 归一化相位；轨未播或 Length 非法时 nil
]]
local function _readLocomotionPhase(self: AnimateType): number?
	local track: AnimationTrack? = nil
	if self._strafeActive and self._strafeLeaderPos then
		local slot = self.BaseActions[self._strafeLeaderPos]
		track = slot and slot.AnimationTrack
	end
	if not track then
		track = self.CurrentBaseTrack
	end
	if not track or not track.IsPlaying then
		return nil
	end
	local len = track.Length
	if type(len) ~= "number" or len ~= len or len <= 1e-3 then
		return nil
	end
	local t = track.TimePosition
	if type(t) ~= "number" or t ~= t then
		return nil
	end
	local phase = t / len
	-- 归一化到 [0,1)
	phase = phase % 1
	if phase < 0 then
		phase += 1
	end
	return phase
end

--[[
	将归一化相位写到轨的 TimePosition
	@param track AnimationTrack - 目标动画轨
	@param phase number - 归一化相位 [0,1)；会再 % 1
]]
local function _applyLocomotionPhase(track: AnimationTrack, phase: number)
	local len = track.Length
	if type(len) ~= "number" or len ~= len or len <= 1e-3 then
		return
	end
	local p = phase % 1
	if p < 0 then
		p += 1
	end
	pcall(function()
		track.TimePosition = p * len
	end)
end

--[[
	断开并清空动作槽上的 Marker 连接
	@param actionSlot { [string]: any } - BaseActions 条目；含 MarkerConnections 数组
]]
local function _disconnectMarkerConnections(actionSlot: { [string]: any })
	local list = actionSlot.MarkerConnections
	if not list then
		return
	end
	for _, conn in ipairs(list) do
		conn:Disconnect()
	end
	actionSlot.MarkerConnections = nil
end

--[[
	将 animationData.MarkerEvents 绑定到已创建的 AnimationTrack（Roblox 动画编辑器 Marker）
	@param animationTrack AnimationTrack - 已 LoadAnimation 的轨
	@param markerEvents AnimationMarkerEvents? - Marker 名 → 回调；nil 只断开旧连接
	@param actionSlot { [string]: any } - BaseActions 条目，用于存放 MarkerConnections 便于销毁时断开
]]
local function _syncMarkerConnections(
	animationTrack: AnimationTrack,
	markerEvents: AnimationMarkerEvents?,
	actionSlot: { [string]: any }
)

	_disconnectMarkerConnections(actionSlot)
	if markerEvents == nil then
		return
	end
	local conns: { RBXScriptConnection } = {}
	for markerName, callback in pairs(markerEvents) do
		if type(callback) == "function" then
			local ok, signal = pcall(function()
				return animationTrack:GetMarkerReachedSignal(markerName)
			end)
			if ok and signal then
				table.insert(conns, signal:Connect(callback))
			end
		end
	end
	if #conns > 0 then
		actionSlot.MarkerConnections = conns
	end
end

--[[
	停止播放当前基本动作轨
	@param self AnimateType - 动画实例
	@param fadeTime number - 淡出秒数；nil 时按 0.1
]]
local function _stopBaseAction(self:AnimateType, fadeTime:number)
	if self.CurrentBaseTrack then
		self.CurrentBaseTrack:Stop(fadeTime or 0.1)
	end
end

--[[
	播放当前基本行为轨（须 BaseActionEnabled）
	@param self AnimateType - 动画实例
	@param fadeTime number - 淡入秒数；nil 时按 0.1
]]
local function _playBaseAction(self:AnimateType, fadeTime:number)
	if self.BaseActionEnabled and self.CurrentBaseTrack then
		self.CurrentBaseTrack:Play(fadeTime or 0.1)
	end
end

-- ========================================
-- 公共函数
-- ========================================

--[[
	创建并绑定当前 Character 的动画实例（走路/跑步/待机/跳跃/掉落）。
	可暂停与恢复基本行为；随模块加载单例化，角色销毁时须 destroy。
	@return AnimateType - 绑定到 script.Parent.Parent 的实例
]]
function Animate.new()

	local character = script.Parent.Parent
	local humanoid:Humanoid = character:WaitForChild("Humanoid")
	local animator:Animator = humanoid:WaitForChild("Animator")

	local self = setmetatable({}, Animate)

	self.Animator = animator
	-------------------------------
	--常规动作(理论层级最低)
	--基本行动是否启用
	self.BaseActionEnabled = true
	--基本行为 当前正在播放的动作
	self.CurrentBaseTrack = nil
	--当前基本状态 默认为待机
	self.BasePos = "Idle"
	--绑定基本动作
	self.BaseActions = {}
	---------------------------------
	self.Animate = {}
	-- BasePos 改变时的回调列表
	self.BasePosChangedCallbacks = {}
	-- 衔接轨结束时用于 Stop(淡出) 的覆盖（由 playTransition 写入，switchBaseAction 消费一次）
	self._transitionExitFadeOut = nil
	self._locomotionTransitionCancel = nil
	-- StrafeBlend：ShiftLock 下四向权重
	self._strafeActive = false
	self._strafeGait = nil :: string?
	self._strafeWeights = { Forward = 0, Left = 0, Right = 0, Back = 0 }
	self._strafeLeaderPos = nil :: string?
	self._strafeLeaderWeight = 0
	self._strafeMarkerMinWeight = 0.55
	self._strafePhaseSync = true
	self._strafePlaying = {} :: { [string]: boolean }
	return self
end

--[[
	注册 BasePos 改变时的回调
	@param self AnimateType - 动画实例
	@param callback (BaseAnimateEnum, BaseAnimateEnum) -> () - 参数为 oldBasePos、newBasePos
	@return () -> () - 取消注册函数
]]
function Animate.BasePosChanged(self:AnimateType, callback:(BaseAnimateEnum, BaseAnimateEnum) -> ())
	table.insert(self.BasePosChangedCallbacks, callback)
	return function()
		for i, cb in ipairs(self.BasePosChangedCallbacks) do
			if cb == callback then
				table.remove(self.BasePosChangedCallbacks, i)
				break
			end
		end
	end
end

--[[
	通知所有 BasePosChanged 订阅者
	@param self AnimateType - 动画实例
	@param oldBasePos BaseAnimateEnum - 切换前姿态
	@param newBasePos BaseAnimateEnum - 切换后姿态
]]
local function _fireBasePosChanged(self:AnimateType, oldBasePos:BaseAnimateEnum, newBasePos:BaseAnimateEnum)
	for _, callback in ipairs(self.BasePosChangedCallbacks) do
		callback(oldBasePos, newBasePos)
	end
end

--[[
	绑定基本行为状态（创建 Animation + LoadAnimation；同 ID 仅刷新 Marker）
	@param self AnimateType - 动画实例
	@param basePos BaseAnimateEnum - 基本行为状态名（Idle/Walk/Run 等）
	@param animationData any - 动作数据；字段：
		ID: string - 动画 AssetId
		Priority: Enum.AnimationPriority - 轨优先级
		Speed: number? - AdjustSpeed，默认 1
		Looped: boolean? - false 时强制不循环
		MarkerEvents: AnimationMarkerEvents? - Marker 名 → function(markerParam: string)
]]
function Animate.bindBaseAction(self:AnimateType, basePos:BaseAnimateEnum, animationData:any)

	if not self.BaseActions[basePos] then
		self.BaseActions[basePos] = {}
	end
	if self.BaseActions[basePos]["Animation"] then
		--先判断是否已经存在
		if self.BaseActions[basePos]["Animation"].AnimationID == animationData.ID then
			--存在同样动作：可更新 Marker 绑定后返回
			local existingTrack = self.BaseActions[basePos]["AnimationTrack"]
			if existingTrack then
				_syncMarkerConnections(existingTrack, animationData.MarkerEvents, self.BaseActions[basePos])
			end
			return		
		else
			--存在不同的动作 删除掉
			_disconnectMarkerConnections(self.BaseActions[basePos])
			self.BaseActions[basePos]["Animation"]:Destroy()
			self.BaseActions[basePos]["Animation"] = nil
			if self.BaseActions[basePos]["AnimationTrack"] then
				self.BaseActions[basePos]["AnimationTrack"]:Stop()
				self.BaseActions[basePos]["AnimationTrack"]:Destroy()
				self.BaseActions[basePos]["AnimationTrack"] = nil
			end
		end

	end
	--创建动作
	local animation = Instance.new("Animation")
	animation.AnimationId = animationData.ID
	animation.Name = basePos
	animation.Parent = script
	local animationTrack = self.Animator:LoadAnimation(animation)
	animationTrack.Priority = animationData.Priority
	animationTrack:AdjustSpeed(animationData.Speed or 1)
	if animationData.Looped == false then
		animationTrack.Looped = false
	end
	_syncMarkerConnections(animationTrack, animationData.MarkerEvents, self.BaseActions[basePos])
	self.BaseActions[basePos]["AnimationTrack"] = animationTrack
	self.BaseActions[basePos]["Animation"] = animation
	if basePos == self.BasePos then
		-- bind 不会走 setBasePos；必须挂上 CurrentBaseTrack，否则 Idle 绑定后仍无腿
		self.CurrentBaseTrack = animationTrack
		_playBaseAction(self, 0.1)
	end

end

--[[
	设置基本动作播放倍率
	@param self AnimateType - 动画实例
	@param basePos BaseAnimateEnum - 基本行为状态名
	@param speed number - AdjustSpeed 倍率
]]
function Animate.setBaseSpeed(self:AnimateType, basePos:BaseAnimateEnum, speed:number)

	if self.BaseActions[basePos] and self.BaseActions[basePos]["AnimationTrack"] then
		self.BaseActions[basePos]["AnimationTrack"]:AdjustSpeed(speed)
	end

end

--[[
	切换基本 locomotion 状态并触发 BasePosChanged
	@param self AnimateType - 动画实例
	@param basePos BaseAnimateEnum - 目标基本姿态名（Idle/Walk/Run 等）
	@param fadeTime number? - 淡入淡出秒数；Walk↔Run 省略则用 GaitBlend.FADE，其它省略用 BASE_ACTION_FADE_TIME
	  Strafe 激活时的 Walk↔Run：保留方向权重跨族 retarget，不经前向单轨中间态
]]
function Animate.setBasePos(self:AnimateType, basePos:BaseAnimateEnum, fadeTime:number?)

	local oldBasePos = self.BasePos
	local isGaitSwitch = _isLocomotionGait(oldBasePos) and _isLocomotionGait(basePos) and oldBasePos ~= basePos

	if basePos ~= "Walk" and basePos ~= "Run" then
		-- 离开步态时清方向轨，且不要按旧 BasePos 把 Run/Walk 播回来；fade 与 setBasePos 一致
		Animate.clearStrafeBlend(self, fadeTime or BASE_ACTION_FADE_TIME, false)
	end

	if oldBasePos == basePos then
		-- 同姿态但轨已停（Gate pause 后未接腿）：补播，避免第二次技能后 BasePos 未变却无腿
		if self.BaseActionEnabled and self.CurrentBaseTrack and not self.CurrentBaseTrack.IsPlaying then
			_playBaseAction(self, fadeTime or BASE_ACTION_FADE_TIME)
		end
		return
	end

	-- 稳态 Walk↔Run：短 fade + 可选脚相位对齐（避免整族从 0 硬切）
	if isGaitSwitch then
		local gaitCfg = Setting.GaitBlend or {}
		local fade = fadeTime
		if type(fade) ~= "number" or fade ~= fade or fade < 0 then
			fade = gaitCfg.FADE
			if type(fade) ~= "number" or fade ~= fade or fade < 0 then
				fade = 0.12
			end
		end
		local phaseSync = gaitCfg.PHASE_SYNC ~= false

		-- Strafe 激活：保留 cardinal 权重跨步态族 retarget，禁止 clear→前向单轨中间态
		if self._strafeActive then
			local w = self._strafeWeights
			local weights = {
				Forward = w.Forward or 0,
				Left = w.Left or 0,
				Right = w.Right or 0,
				Back = w.Back or 0,
			}
			local speedScale = 1
			if self._strafeLeaderPos then
				local slot = self.BaseActions[self._strafeLeaderPos]
				local track = slot and slot.AnimationTrack
				if track and track.IsPlaying then
					speedScale = track.Speed
				end
			elseif self.CurrentBaseTrack and self.CurrentBaseTrack.IsPlaying then
				speedScale = self.CurrentBaseTrack.Speed
			end
			local strafeCfg = Setting.StrafeBlend or {}
			-- BasePos 须先于 setStrafeBlend（其要求 gait == BasePos）
			self.BasePos = basePos
			Animate.setStrafeBlend(self, basePos, weights, speedScale, {
				markerMinWeight = strafeCfg.MARKER_LEADER_WEIGHT,
				phaseSync = phaseSync,
				weightEpsilon = strafeCfg.WEIGHT_EPSILON,
				trackFade = fade,
				weightFade = fade,
			})
			_fireBasePosChanged(self, oldBasePos, basePos)
			return
		end

		local phase = if phaseSync then _readLocomotionPhase(self) else nil
		self:switchBaseAction(basePos, fade)
		self.BasePos = basePos
		if phase ~= nil and self.CurrentBaseTrack then
			_applyLocomotionPhase(self.CurrentBaseTrack, phase)
		end
		_fireBasePosChanged(self, oldBasePos, basePos)
		return
	end

	self:switchBaseAction(basePos, fadeTime)
	self.BasePos = basePos
	_fireBasePosChanged(self, oldBasePos, basePos)
end

--[[
	切换基本行为轨道（不更新 BasePos 字段，不触发 BasePosChanged）
	@param self AnimateType - 动画实例
	@param basePos BaseAnimateEnum - 目标轨道名
	@param fadeTime number? - 淡入秒数；离开衔接轨时用 _transitionExitFadeOut 作为 Stop 淡出
]]
function Animate.switchBaseAction(self:AnimateType, basePos:BaseAnimateEnum, fadeTime:number?)

	if basePos == self.BasePos then
		return
	end

	local fade = fadeTime or BASE_ACTION_FADE_TIME
	if self.BaseActions[basePos] and self.BaseActions[basePos]["AnimationTrack"] then
		if self.CurrentBaseTrack then
			local stopFade = fade
			if _isTransitionPose(self.BasePos) and self._transitionExitFadeOut ~= nil then
				stopFade = self._transitionExitFadeOut
				self._transitionExitFadeOut = nil
			end
			_stopBaseAction(self, stopFade)
		end
		self.CurrentBaseTrack = self.BaseActions[basePos]["AnimationTrack"]
		_playBaseAction(self, fade)
	end

end

--[[
	播放衔接轨（StartRun/StopWalk 等）；Stopped 或 middle 到期后执行 onComplete。
	@param self AnimateType - 动画实例
	@param transitionPos BaseAnimateEnum - 衔接姿态名（须已 bindBaseAction）
	@param onComplete (() -> ())? - 衔接完成回调；userCancelled 后不执行
	@param options TransitionPlayOptions? - fadeIn/fadeOut/middleDuration/animationSpeed；nil 用 BASE_ACTION_FADE_TIME
	@return boolean - 是否成功开始播放（无轨时 false）
	@return ((number?) -> ())? - 取消函数；参数为可选淡出覆盖秒数；失败时为 nil
]]
function Animate.playTransition(
	self: AnimateType,
	transitionPos: BaseAnimateEnum,
	onComplete: any,
	options: TransitionPlayOptions | nil
)
	if not self.BaseActions[transitionPos] or not self.BaseActions[transitionPos]["AnimationTrack"] then
		return false, nil
	end
	local track = self.BaseActions[transitionPos]["AnimationTrack"]

	local legacyFade = (options and options.fadeTime) or BASE_ACTION_FADE_TIME
	local fadeIn = (options and options.fadeIn) or legacyFade
	local fadeOut = (options and options.fadeOut) or legacyFade
	local middleDuration = (options and options.middleDuration) or 0
	if middleDuration < 0 then
		middleDuration = 0
	end

	local animationSpeed = 1
	if options and options.animationSpeed ~= nil then
		animationSpeed = options.animationSpeed
	end

	self._transitionExitFadeOut = fadeOut

	Animate.clearStrafeBlend(self, fadeOut, false)

	if self.CurrentBaseTrack then
		_stopBaseAction(self, fadeOut)
	end
	local oldBasePos = self.BasePos
	self.CurrentBaseTrack = track
	self.BasePos = transitionPos

	_fireBasePosChanged(self, oldBasePos, transitionPos)
	local transitionStartClock = os.clock()
	local minCompleteClock = transitionStartClock + fadeIn + middleDuration

	local userCancelled = false
	local delayThread: thread? = nil
	local conn: RBXScriptConnection? = nil

	--[[
		清除本实例上的衔接取消句柄（仅当仍指向本次 cancel）
	]]
	local function clearCancelRef()
		if self._locomotionTransitionCancel ~= nil then
			self._locomotionTransitionCancel = nil
		end
	end

	--[[
		在 fadeIn+middle 到期后执行 onComplete；已被取消则跳过
	]]
	local function invokeComplete()
		if userCancelled or not onComplete then
			return
		end
		local function run()
			if userCancelled then
				return
			end
			onComplete()
		end
		local remain = minCompleteClock - os.clock()
		if remain > 0 then
			delayThread = task.delay(remain, function()
				delayThread = nil
				run()
			end)
		else
			run()
		end
	end

	--[[
		打断衔接轨：Stop 轨道，之后 Stopped/onComplete 均不执行
		@param fadeOutOverride number? - 覆盖淡出秒数；nil 用本次 fadeOut
	]]
	local function cancelTransition(fadeOutOverride: number?)
		if userCancelled then
			return
		end
		userCancelled = true
		if delayThread ~= nil then
			task.cancel(delayThread :: thread)
			delayThread = nil
		end
		if conn ~= nil then
			conn:Disconnect()
			conn = nil
		end
		clearCancelRef()
		local fo = fadeOutOverride or fadeOut or 0.08
		pcall(function()
			track:Stop(fo)
		end)
	end

	self._locomotionTransitionCancel = cancelTransition

	_playBaseAction(self, fadeIn)
	track:AdjustSpeed(animationSpeed)
	conn = track.Stopped:Connect(function()
		if conn ~= nil then
			conn:Disconnect()
			conn = nil
		end
		if userCancelled then
			return
		end
		clearCancelRef()
		invokeComplete()
	end)

	return true, cancelTransition
end

--[[
	暂停基本行为播放（BaseActionEnabled=false，当前轨 Stop）
	@param self AnimateType - 动画实例
]]
function Animate.stopBaseAction(self:AnimateType)

	if not self.BaseActionEnabled then
		return
	end
	self.BaseActionEnabled = false

	Animate.clearStrafeBlend(self, 0.1, false)
	if self.CurrentBaseTrack then
		_stopBaseAction(self, 0.1)
	end
end

--[[
	恢复基本行为使能（BaseActionEnabled=true）。
	不盲播冻结的 CurrentBaseTrack；调用方须 invalidateBasePose 后按当前态 setBasePos。
	@param self AnimateType - 动画实例
]]
function Animate.resumeBaseAction(self:AnimateType)

	if self.BaseActionEnabled then
		return
	end
	self.BaseActionEnabled = true
end

--[[
	失效当前 BasePos 哨兵，使下次 setBasePos(目标) 必走 switchBaseAction 真正 Play。
	不触发 BasePosChanged；不 Play、不改 CurrentBaseTrack 指针（轨应已在 pause 时 Stop）。
	解 pauseBase 后与 resumeBaseAction 联用，避免同名稳定态 early return 导致无腿。
	@param self AnimateType - 动画实例
]]
function Animate.invalidateBasePose(self: AnimateType)
	self.BasePos = ""
end

local STRAFE_CARDINALS = { "Forward", "Right", "Back", "Left" }
local STRAFE_OPPOSITE = { Forward = "Back", Back = "Forward", Left = "Right", Right = "Left" }
local GAIT_NAMES = { "Walk", "Run" }

--[[
	步态名 + 方位 → BaseActions 键（Forward 即 Walk/Run）
	@param gait string - "Walk" | "Run"
	@param cardinal string - Forward/Left/Right/Back
	@return string - 轨道名
]]
local function _strafePosName(gait: string, cardinal: string): string
	if cardinal == "Forward" then
		return gait
	end
	return gait .. "_" .. cardinal
end

--[[
	某步态的全部方向轨名（含 Forward）
	@param gait string - "Walk" | "Run"
	@return { string } - { gait, gait_Left, gait_Right, gait_Back }
]]
local function _gaitFamilyPosNames(gait: string): { string }
	return { gait, gait .. "_Left", gait .. "_Right", gait .. "_Back" }
end

--[[
	停止 Walk/Run 族方向轨（可保留 keep 中的轨）。用于防 Idle/衔接下残留移动轨叠播。
	@param self AnimateType - 动画实例
	@param fade number - 淡出秒数
	@param keep { [string]: any }? - 需要保留的 posName 集合；nil 表示全停
]]
local function _stopGaitFamilyTracks(self: AnimateType, fade: number, keep: { [string]: any }?)
	for _, gaitName in ipairs(GAIT_NAMES) do
		for _, posName in ipairs(_gaitFamilyPosNames(gaitName)) do
			if not (keep and keep[posName] ~= nil) then
				local slot = self.BaseActions[posName]
				local track = slot and slot.AnimationTrack
				if track and track.IsPlaying then
					pcall(function()
						track:Stop(fade)
						track:AdjustWeight(1, 0)
					end)
				end
				if self._strafePlaying[posName] then
					self._strafePlaying[posName] = nil
				end
			end
		end
	end
end

--[[
	从正在播放的轨读取归一化脚相位 [0,1)；须在停轨之前调用。
	优先 strafe leader → CurrentBaseTrack → 任一 Walk/Run 族正在播的轨。
	@param self AnimateType - 动画实例
	@return number? - 相位；无可读轨时 nil
]]
local function _capturePlayingLocomotionPhase(self: AnimateType): number?
	--[[
		从单条轨读取归一化相位
		@param track AnimationTrack? - 候选轨
		@return number? - [0,1)；未播或 Length 非法时 nil
	]]
	local function fromTrack(track: AnimationTrack?): number?
		if not track or not track.IsPlaying then
			return nil
		end
		local len = track.Length
		if type(len) ~= "number" or len ~= len or len <= 1e-3 then
			return nil
		end
		local t = track.TimePosition
		if type(t) ~= "number" or t ~= t then
			return nil
		end
		local phase = (t / len) % 1
		if phase < 0 then
			phase += 1
		end
		return phase
	end

	if self._strafeLeaderPos then
		local slot = self.BaseActions[self._strafeLeaderPos]
		local phase = fromTrack(slot and slot.AnimationTrack)
		if phase ~= nil then
			return phase
		end
	end

	local phase = fromTrack(self.CurrentBaseTrack)
	if phase ~= nil then
		return phase
	end

	for _, gaitName in ipairs(GAIT_NAMES) do
		for _, posName in ipairs(_gaitFamilyPosNames(gaitName)) do
			local slot = self.BaseActions[posName]
			phase = fromTrack(slot and slot.AnimationTrack)
			if phase ~= nil then
				return phase
			end
		end
	end
	return nil
end

--[[
	清除方向混合轨
	@param self AnimateType - 动画实例
	@param fadeTime number? - 淡出秒数；nil 时 0.1
	@param restoreGait boolean? - 是否在 BasePos 仍为 Walk/Run 时恢复单轨步态；默认 true。
	  切 Jump/Land/衔接前须传 false，否则会先把 Run 播回来再切姿态，造成错乱。
]]
function Animate.clearStrafeBlend(self: AnimateType, fadeTime: number?, restoreGait: boolean?)
	local fade = fadeTime or 0.1
	local shouldRestore = if restoreGait == nil then true else restoreGait

	-- 始终扫停 Walk/Run 族（含未登记进 _strafePlaying 的孤儿轨），避免待机叠移动
	_stopGaitFamilyTracks(self, fade, nil)

	self._strafeActive = false
	self._strafeGait = nil
	self._strafeLeaderPos = nil
	self._strafeLeaderWeight = 0
	self._strafeWeights = { Forward = 0, Left = 0, Right = 0, Back = 0 }

	if not shouldRestore then
		return
	end

	local gait = self.BasePos
	if self.BaseActionEnabled and (gait == "Walk" or gait == "Run") then
		local slot = self.BaseActions[gait]
		local track = slot and slot.AnimationTrack
		if track then
			self.CurrentBaseTrack = track
			if not track.IsPlaying then
				_playBaseAction(self, fade)
			end
			pcall(function()
				track:AdjustWeight(1, fade)
			end)
		end
	end
end

--[[
	ShiftLock 下按四向权重混合 Walk/Run 方向轨（最多两轨 Playing）
	@param self AnimateType - 动画实例
	@param gait string - "Walk" | "Run"；须与当前 BasePos 一致
	@param weights { Forward: number, Left: number, Right: number, Back: number } - 目标和约 1
	@param speedScale number - AdjustSpeed 倍率
	@param options any? - 可选：markerMinWeight/phaseSync/weightEpsilon/trackFade/weightFade；nil 用默认
]]
function Animate.setStrafeBlend(
	self: AnimateType,
	gait: string,
	weights: { Forward: number, Left: number, Right: number, Back: number },
	speedScale: number,
	options: any?
)
	if not self.BaseActionEnabled then
		return
	end
	-- 禁止在 Jump/Fall/Land/衔接轨期间叠方向轨或把 BasePos 改回 Walk/Run
	if self.BasePos ~= "Walk" and self.BasePos ~= "Run" then
		Animate.clearStrafeBlend(self, 0.05, false)
		return
	end
	if gait ~= "Walk" and gait ~= "Run" then
		Animate.clearStrafeBlend(self, 0.1, false)
		return
	end
	if gait ~= self.BasePos then
		Animate.clearStrafeBlend(self, 0.05, true)
		return
	end

	local eps = (options and options.weightEpsilon) or 0.02
	local markerMin = (options and options.markerMinWeight) or 0.55
	local phaseSync = if options and options.phaseSync ~= nil then options.phaseSync else true
	local trackFade = (options and options.trackFade) or 0.14
	local weightFade = (options and options.weightFade) or 0.1
	self._strafeMarkerMinWeight = markerMin
	self._strafePhaseSync = phaseSync == true

	-- 取权重最高的两个 cardinal
	local ranked = {}
	for _, card in ipairs(STRAFE_CARDINALS) do
		local w = weights[card] or 0
		if w > eps then
			table.insert(ranked, { card = card, w = w })
		end
	end
	table.sort(ranked, function(a, b)
		return a.w > b.w
	end)

	if #ranked == 0 then
		Animate.clearStrafeBlend(self, trackFade)
		return
	end

	-- 对立向（前↔后 / 左↔右）禁止双轨并存，否则身体会「拧」一下
	local maxN = math.min(2, #ranked)
	if maxN == 2 and STRAFE_OPPOSITE[ranked[1].card] == ranked[2].card then
		maxN = 1
	end

	local keep: { [string]: number } = {}
	local sum = 0
	for i = 1, maxN do
		sum += ranked[i].w
	end
	if sum <= 1e-4 then
		Animate.clearStrafeBlend(self, trackFade)
		return
	end

	for i = 1, maxN do
		local card = ranked[i].card
		local posName = _strafePosName(gait, card)
		keep[posName] = ranked[i].w / sum
	end

	local leaderPos = _strafePosName(gait, ranked[1].card)
	local leaderWeight = keep[leaderPos] or 0
	local leaderTrack = self.BaseActions[leaderPos] and self.BaseActions[leaderPos].AnimationTrack

	-- 相位须在停旧轨之前捕获（跨步态 retarget 时旧 leader 停后 IsPlaying=false）
	local leaderPhase: number? = if phaseSync then _capturePlayingLocomotionPhase(self) else nil

	-- 扫停不在 keep 中的全部步态族轨（含旧步态族；防叠轨）
	_stopGaitFamilyTracks(self, trackFade, keep)

	-- 相位：仅新开轨时对齐一次；禁止对已在播的 follower 每帧写 TimePosition
	for posName, w in pairs(keep) do
		local slot = self.BaseActions[posName]
		local track = slot and slot.AnimationTrack
		if track then
			if not track.IsPlaying then
				track:Play(trackFade)
				if phaseSync and leaderPhase ~= nil and track.Length > 1e-3 then
					track.TimePosition = leaderPhase * track.Length
				end
			end
			track:AdjustSpeed(speedScale)
			track:AdjustWeight(w, weightFade)
			self._strafePlaying[posName] = true
		end
	end

	-- 只更新 CurrentBaseTrack 指针，绝不改写 BasePos（须已是 Walk/Run）
	if leaderTrack then
		self.CurrentBaseTrack = leaderTrack
	end

	self._strafeActive = true
	self._strafeGait = gait
	self._strafeWeights = {
		Forward = weights.Forward or 0,
		Left = weights.Left or 0,
		Right = weights.Right or 0,
		Back = weights.Back or 0,
	}
	self._strafeLeaderPos = leaderPos
	self._strafeLeaderWeight = leaderWeight
end

--[[
	FootStep Marker 是否应由该轨触发（Strafe 下仅 leader 且权重足够）
	@param self AnimateType - 动画实例
	@param posName string - BaseActions 键名
	@return boolean - 是否允许发脚步
]]
function Animate.CanEmitFootStepFrom(self: AnimateType, posName: string): boolean
	if not self._strafeActive then
		return true
	end
	if self._strafeLeaderPos ~= posName then
		return false
	end
	return self._strafeLeaderWeight >= (self._strafeMarkerMinWeight or 0.55)
end

--[[
	销毁单个动作槽（Marker 连接、Track、Animation Instance）
	@param actionSlot { [string]: any } - BaseActions 条目；含 Animation / AnimationTrack / MarkerConnections
]]
local function _destroyActionSlot(actionSlot: { [string]: any })
	_disconnectMarkerConnections(actionSlot)
	if actionSlot.AnimationTrack then
		pcall(function()
			actionSlot.AnimationTrack:Stop(0)
			actionSlot.AnimationTrack:Destroy()
		end)
		actionSlot.AnimationTrack = nil
	end
	if actionSlot.Animation then
		actionSlot.Animation:Destroy()
		actionSlot.Animation = nil
	end
end

--[[
	销毁动画实例：停止所有轨、断开 Marker/Stopped 连接、清空回调
	@param self AnimateType - 动画实例
]]
function Animate.destroy(self: AnimateType)
	if self._locomotionTransitionCancel then
		pcall(self._locomotionTransitionCancel)
		self._locomotionTransitionCancel = nil
	end

	Animate.clearStrafeBlend(self, 0)

	if self.CurrentBaseTrack then
		pcall(function()
			self.CurrentBaseTrack:Stop(0)
		end)
		self.CurrentBaseTrack = nil
	end

	for _, slot in pairs(self.BaseActions) do
		_destroyActionSlot(slot)
	end

	table.clear(self.BaseActions)
	table.clear(self.BasePosChangedCallbacks)
	self.BaseActionEnabled = false
end

local AnimateObject = Animate.new()

return AnimateObject
