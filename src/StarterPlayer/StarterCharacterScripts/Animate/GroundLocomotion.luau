--[[
	Module: GroundLocomotion
	Description: 地面/空中 locomotion 动画状态机（跑走衔接、落地锁、停步防抖门闩、游泳攀爬跳跃 Fall）。
	Author: 林奥宇
	Created: 2026-07-03
	Last Modified: 2026-08-31

	使用：
	local loco = GroundLocomotion.create(deps)
	-- deps.isLocoSuppressed：ActionArbiter 抑制时 update / 跳跃落地演出 early return
	-- deps.getSuppressRunLean：ClimbAssist 接近梯子时 Run 视觉覆盖为 Walk（不改权威 _groundStable）
	Humanoid.Running:Connect(loco.onRunning)
	RunService.Heartbeat:Connect(function(dt) loco.update(dt) end)
	角色销毁时 loco.destroy()

	落地/起跳：LAND_* / MIN_JUMP_* 时间锁只防本 FSM 自打断；抗业务 Idle 盖视觉靠
	init 绑定的 Animator Priority（Jump=Movement，Land/LightLand=Action）。
	落地强锁条件化：无移动意图满锁 LAND_LOCO_INTERRUPT_LOCK_SEC；有意图（当帧或
	LAND_MOVE_INTENT_STICKY_SEC 粘滞）且 LAND_LOCO_LOCK_BYPASS_ON_MOVE_INTENT 时旁路强锁，
	并以 LAND_TO_MOVE_FADE 早切 Walk/Run（StrafeBlend 尽快接手；粘滞吸收落地 MoveDirection 抖动）。
	稳态 Walk↔Run：传入 GaitBlend.FADE，由 AnimateModule 做短 fade + 脚相位对齐。
	停步选片：按 _lastStopGait（最近稳定 Walk/Run），不按当帧 WalkSpeed，避免先松 Sprint 再松方向丢 StopRun。
	Run→Walk 降档门闩：LocoAntiFlicker.RUN_DEMOTE_HOLD_SEC 内保持 Run，窗内松方向直接 StopRun。
	侧移/后退起停（定稿）：ShiftLock 非前向跳过 Start*/Stop*，短 fade 直切；方向起停资源未就绪前不半开。
	解 pauseBase：resyncAfterBaseUnpause 按当前 Humanoid/意图短 fade 直切稳定态（跳过 Start*/Stop*）。
	冲刺 FOV 退出同相：shouldReleaseSprintFov 供 AnimateFov（Stop* 起拍 / 无意图且过 AntiFlicker）。
	空中姿态查询：getAirPose 供 AirLean（仅 Jump/Fall）。
	地面走跑就绪：isGroundMovePose 供 AirLean 落地交接（侧移落地勿在 Land 窗回正）。
	攀爬接近：ClimbAssist.suppressRunLean 时 Run→Walk 视觉覆盖 + getGroundStable 对 Strafe 返回 Walk。
]]

local Class = require(game.ReplicatedFirst.AllSideCode.Class.Class)
local FootLand = require(script.Parent.FootLand)

type BaseAnimateEnum = typeof(Class.BaseAnimateEnum)
type AnimateType = typeof(Class.AnimateType)

export type GroundLocomotionDeps = {
	animate: AnimateType,
	humanoid: Humanoid,
	character: Model,
	localPlayer: Player,
	setting: any,
	getRunAnimationSpeed: (walkspeed: number, posName: string) -> number,
	getRelativeMoveDirection: () -> string,
	isShiftLocked: () -> boolean,
	isLocoSuppressed: () -> boolean,
	-- true：ShiftLock 稳定态只设 Walk/Run，方向交给 StrafeBlend
	isStrafeBlendEnabled: (() -> boolean)?,
	-- ClimbAssist：接近梯子且应压 Run 前倾时返回 true
	getSuppressRunLean: (() -> boolean)?,
}


export type GroundLocomotion = {
	onRunning: (walkspeed: number) -> (),
	onJumping: (active: boolean) -> (),
	onFreeFalling: (active: boolean) -> (),
	onClimbing: (climbspeed: number) -> (),
	onSwimming: (swimspeed: number) -> (),
	onStateChanged: (oldState: Enum.HumanoidStateType, newState: Enum.HumanoidStateType) -> (),
	update: (dt: number) -> (),
	abortDriver: () -> (),
	clearLandTimingWindows: () -> (),
	getGroundStable: () -> string,
	canStrafeBlend: () -> boolean,
	-- Jump / Fall 时返回姿态名，否则 nil（供 AirLean）
	getAirPose: () -> string?,
	-- 地面走跑视觉已就绪（_pose 为 Walk/Run；含扇区硬切），供 AirLean 交接放 lean
	isGroundMovePose: () -> boolean,
	resyncAfterBaseUnpause: () -> (),
	shouldReleaseSprintFov: () -> boolean,
	destroy: () -> (),
}


local GroundLocomotion = {}

--[[
	创建地面 locomotion 驱动器
	@param deps GroundLocomotionDeps - 动画实例与外部查询回调
	@return GroundLocomotion - 事件处理与 update / 查询 API
]]
function GroundLocomotion.create(deps: GroundLocomotionDeps): GroundLocomotion
	local animate = deps.animate
	local humanoid = deps.humanoid
	local character = deps.character
	local localPlayer = deps.localPlayer
	local setting = deps.setting

	local _pose = "Idle"
	local _groundMoveSpeed = 0
	local _jumpFallDeadline = 0
	local _freefallStartTime = 0
	local _isFreefall = false

	local _groundDesired = "Idle"
	local _groundStable = "Idle"
	local _groundTransition: string? = nil
	local _groundTransitionToken = 0
	local _transitionMinVisibleEndClock = 0
	local _groundAnimateCancel: ((fadeOutOverride: number?) -> ())? = nil
	-- 本次地面移动手势起点（进入 Walk/Run）；用于短按跳过 Stop*
	local _locoGestureStartClock = 0
	-- 进入 Walk/Run 稳定态的时刻
	local _locoStableEnteredClock = 0
	-- 停步门闩：已松键但尚未达到 STOP_RELEASE_DELAY
	local _stopPendingSince = 0
	-- 最近一次稳定走跑步态；松方向选 Stop* 用此值，不看当帧 WalkSpeed
	local _lastStopGait: "Walk" | "Run" | nil = nil
	-- Run→Walk 降档门闩：松冲刺后短时保持 Run（见 RUN_DEMOTE_HOLD_SEC）
	local _runDemotePendingSince = 0
	-- Run 降到 Walk 后，停步选片仍短时视为 Run（与 RUN_DEMOTE_HOLD_SEC 同长）
	local _stopGaitWalkStickySince = 0
	-- ShiftLock 下最近一次「有输入」时的相对方向（Strafe 开启时也必须每帧刷新，否则停步误判 Forward 播 StopRun）
	local _lastActiveMoveDir = "Forward"
	-- 进入 Idle 视觉的时刻；用于移→待机途中再启动时跳过 Start* / 缩短 fade
	local _idleEnteredClock = 0

	local LAND_ANIM_TIME = setting.LAND_ANIM_TIME
	local LAND_LOCO_INTERRUPT_LOCK_SEC = setting.LAND_LOCO_INTERRUPT_LOCK_SEC
	local _landLockDeadline = 0
	local _landHoldIdleUntil = 0
	local _skipLocoStopAfterLand = false
	-- 最近一次 MoveDirection 达到意图阈值的时刻（落地粘滞旁路用）
	local _lastMoveIntentClock = 0
	local _airStartTime = 0
	local _airJumpFromRun = false
	local _suppressLocoStopUntil = 0

	local WALK_ANIMATION_SPEED = setting.WALK_ANIMATION_SPEED
	local MOVE_INTENT_FOR_LOCO = setting.MOVE_INTENT_FOR_LOCO
	local FALL_LAND_THRESHOLD = setting.FALL_LAND_THRESHOLD
	local MIN_JUMP_ANIMATION_TIME = setting.MIN_JUMP_ANIMATION_TIME
	local FREEFALL_MIN_DURATION = setting.FREEFALL_MIN_DURATION or 0.08

	--[[
		ClimbAssist 是否要求压 Run 前倾（接近梯子）
		@return boolean - true 表示应将 Run 视觉覆盖为 Walk
]]
	local function _shouldSuppressRunLean(): boolean
		if deps.getSuppressRunLean then
			return deps.getSuppressRunLean() == true
		end
		return false
	end

	--[[
		攀爬接近抑制切入 Walk 视觉的 fade
		@return number - 秒
	]]
	local function _climbAssistSuppressFade(): number
		local cfg = setting.ClimbAssist
		local f = cfg and cfg.SUPPRESS_FADE
		if type(f) == "number" and f == f and f >= 0 then
			return f
		end
		return 0.05
	end

	local _TRANSITION_IMPLIED_STABLE: { [string]: "Idle" | "Walk" | "Run" } = {
		StartRun = "Run",
		StartWalk = "Walk",
		StopRun = "Idle",
		StopWalk = "Idle",
	}

	--[[
		衔接轨播放参数（AnimateSetting.Transition，由 MotionPhase 派生）
		@param transitionName string - StartRun/StopRun 等
		@return table? - TransitionPlayOptions 字段 fadeTime/fadeIn/fadeOut/middleDuration/animationSpeed；无配置时 nil
]]
	local function _transitionOpts(transitionName: string)
		local pack = setting.Transition and setting.Transition[transitionName]
		if not pack then
			return nil
		end
		return {
			fadeTime = pack.fadeTime,
			fadeIn = pack.fadeIn,
			fadeOut = pack.fadeOut,
			middleDuration = pack.middleDuration,
			animationSpeed = pack.animationSpeed,
		}
	end

	--[[
		是否跳过本次落地关键帧；loco 被 Gate 抑制时跳过
		@param _airTime number - 离地时长（秒）
		@param _wouldHeavyLand boolean - 若不跳过是否会播 Land
		@return boolean - true 表示跳过 Land/LightLand 演出
	]]
	local function _shouldSkipLandAnimation(_airTime: number, _wouldHeavyLand: boolean): boolean
		if deps.isLocoSuppressed() then
			return true
		end
		return false
	end

	--[[
		中断当前地面衔接轨驱动
	]]
	local function abortDriver()
		if not _groundTransition and not _groundAnimateCancel then
			return
		end
		if _groundAnimateCancel then
			_groundAnimateCancel()
			_groundAnimateCancel = nil
		end
		_groundTransitionToken += 1
		_groundTransition = nil
	end

	--[[
		清除落地 FSM 时间窗（强锁与 Idle 保持；不负责挡业务 AnimationTrack）
	]]
	local function clearLandTimingWindows()
		_landLockDeadline = 0
		_landHoldIdleUntil = 0
	end

	--[[
		查询衔接轨是否在 Setting 中启用
		@param name string - StartRun | StartWalk | StopRun | StopWalk
		@return boolean - 是否播放衔接动画
	]]
	local function _isGroundTransitionEnabled(name: "StartRun" | "StartWalk" | "StopRun" | "StopWalk"): boolean
		local te = setting.TransitionEnable
		if te and te[name] ~= nil then
			return te[name] == true
		end
		return true
	end

	--[[
		侧移/后退是否跳过地面起停衔接（产品定稿：暂时永远跳过，短 fade 直切）。
		ShiftLock 且最近活跃方向非 Forward → 跳过 Start*/Stop*；勿播前向衔接片冒充。
		方向取自移动中持续刷新的 _lastActiveMoveDir
		（不能仅在松键时读 getRelativeMoveDirection：Strafe 开启时停步前可能从未更新，会误判 Forward）。
		方向起停资源就绪后再改此策略；此前勿半开。
		@return boolean - true 表示应跳过 Start*/Stop* 直切稳定态
	]]
	local function _shouldSkipTransitionForNonForwardStrafe(): boolean
		if not deps.isShiftLocked() then
			return false
		end
		return _lastActiveMoveDir ~= "Forward"
	end

	--[[
		@Run 与 @Walk 分界 WalkSpeed 阈值
		@return number - 严格大于此值视为跑步
	]]
	local function _runLocoWalkSpeedThreshold(): number
		local t = setting.RUN_LOCOMOTION_WALKSPEED_THRESHOLD
		if type(t) == "number" and t == t then
			return t
		end
		return 16
	end

	--[[
		有效 WalkSpeed：max(Humanoid.WalkSpeed, Player.ExpectedWalkSpeed)
		@return number - 参与跑走判定的 WalkSpeed
	]]
	local function _walkSpeedForLocomotionCompare(): number
		local actual = humanoid.WalkSpeed
		local attrName = setting.EXPECTED_WALKSPEED_ATTRIBUTE or "ExpectedWalkSpeed"
		local expected = localPlayer:GetAttribute(attrName)
		if type(expected) == "number" and expected == expected and expected >= 0 then
			return math.max(actual, expected)
		end
		return actual
	end

	--[[
		是否有方向输入意图（WASD / 摇杆）
		@return boolean - MoveDirection 达到起步阈值
	]]
	local function _hasMoveInputIntent(): boolean
		return humanoid.MoveDirection.Magnitude >= MOVE_INTENT_FOR_LOCO
	end

	--[[
		记录当帧真实移动意图（供落地粘滞窗口使用）
	]]
	local function _noteMoveIntentIfAny()
		if not _hasMoveInputIntent() then
			return
		end
		_lastMoveIntentClock = time()
		_lastActiveMoveDir = deps.getRelativeMoveDirection()
	end

	--[[
		粘滞窗口内是否仍视为「刚有过移动意图」
		@return boolean - true 表示 LAND_MOVE_INTENT_STICKY_SEC 内曾有过意图
]]
	local function _hasStickyRecentMoveIntent(): boolean
		if _lastMoveIntentClock <= 0 then
			return false
		end
		local sticky = setting.LAND_MOVE_INTENT_STICKY_SEC
		if type(sticky) ~= "number" or sticky ~= sticky or sticky <= 0 then
			sticky = 0.2
		end
		return (time() - _lastMoveIntentClock) <= sticky
	end

	--[[
		落地强锁旁路 / Land 窗早切 Walk/Run 用的意图（当帧或粘滞）
		@return boolean - true 表示应旁路 interrupt 强锁
]]
	local function _hasLandLockBypassIntent(): boolean
		if setting.LAND_LOCO_LOCK_BYPASS_ON_MOVE_INTENT ~= true then
			return false
		end
		return _hasMoveInputIntent() or _hasStickyRecentMoveIntent()
	end

	--[[
		有移动输入时刷新最后活动方向（供停步/起步跳过判定）
	]]
	local function _refreshLastActiveMoveDir()
		if not _hasMoveInputIntent() then
			return
		end
		_lastActiveMoveDir = deps.getRelativeMoveDirection()
	end

	--[[
		是否处于「刚进 Idle、可快速再切入移动」窗口
		@return boolean - true 表示应跳过 Start* 并可用短 fade
		@return number? - 建议的回切 fade（秒）；不在窗口时 nil
]]
	local function _idleReenterMoveOptions(): (boolean, number?)
		local pack = setting.IDLE_REENTER
		local skipSec = pack and pack.SKIP_START_SEC
		if type(skipSec) ~= "number" or skipSec ~= skipSec or skipSec < 0 then
			skipSec = setting.IDLE_ENTER_FADE
		end
		if type(skipSec) ~= "number" or skipSec ~= skipSec or skipSec <= 0 then
			return false, nil
		end
		if _idleEnteredClock <= 0 or (time() - _idleEnteredClock) >= skipSec then
			return false, nil
		end
		local moveFade = pack and pack.MOVE_FADE
		if type(moveFade) ~= "number" or moveFade ~= moveFade or moveFade < 0 then
			moveFade = 0.08
		end
		return true, moveFade
	end

	--[[
		是否有移动速度或方向输入意图
		@param runningSpeed number - Humanoid.Running 回调速度
		@return boolean - 视为在移动
	]]
	local function _hasLocomotionMoveOrIntent(runningSpeed: number): boolean
		if runningSpeed > WALK_ANIMATION_SPEED then
			return true
		end
		return _hasMoveInputIntent()
	end

	--[[
		读取 LocoAntiFlicker 数值配置
		@param key string - LocoAntiFlicker 键名（如 STOP_RELEASE_DELAY_SEC）
		@param default number - 缺省秒数
		@return number - 合法非负秒数；非法则 default 或 SHORT_LOCO_SKIP_STOP_SEC 兼容值
]]
	local function _locoGateSec(key: string, default: number): number
		local pack = setting.LocoAntiFlicker
		local v = pack and pack[key]
		if type(v) == "number" and v == v and v >= 0 then
			return v
		end
		if key == "MIN_STABLE_MOVE_FOR_STOP_SEC" then
			local legacy = setting.SHORT_LOCO_SKIP_STOP_SEC
			if type(legacy) == "number" and legacy == legacy and legacy >= 0 then
				return legacy
			end
		end
		return default
	end

	--[[
		记录本次走跑手势起点（仅首次；短按 SkipStop 用）
	]]
	local function _markLocoGestureStart()
		if _locoGestureStartClock <= 0 then
			_locoGestureStartClock = time()
		end
	end

	--[[
		标记已进入 Walk/Run 稳定循环
	]]
	local function _markLocoStableEntered()
		_locoStableEnteredClock = time()
	end

	--[[
		清除走跑手势与起停门闩
	]]
	local function _clearLocoGesture()
		_locoGestureStartClock = 0
		_locoStableEnteredClock = 0
		_stopPendingSince = 0
		_runDemotePendingSince = 0
		_stopGaitWalkStickySince = 0
		_lastStopGait = nil
	end

	--[[
		记录可用于停步选片的最近稳定步态。
		Run 立即生效；Walk 若自 Run 降档则短时不覆盖，避免先松 Sprint 再松方向丢 StopRun。
		@param gait "Walk" | "Run" - 当前稳定走跑态
	]]
	local function _noteStopGait(gait: "Walk" | "Run")
		if gait == "Run" then
			_lastStopGait = "Run"
			_stopGaitWalkStickySince = 0
			return
		end
		if _lastStopGait == "Run" then
			local sticky = _locoGateSec("RUN_DEMOTE_HOLD_SEC", 0.15)
			if sticky > 0 then
				if _stopGaitWalkStickySince <= 0 then
					_stopGaitWalkStickySince = time()
				end
				if (time() - _stopGaitWalkStickySince) < sticky then
					return
				end
			end
		end
		_lastStopGait = "Walk"
		_stopGaitWalkStickySince = 0
	end

	--[[
		解析松方向时应播的停步来源步态
		优先 _lastStopGait；缺失时回退当帧 WalkSpeed 与跑走阈值比较。
		@return "Walk" | "Run" - 用于选 StopWalk / StopRun
	]]
	local function _resolveStopFromGait(): "Walk" | "Run"
		if _lastStopGait == "Run" or _lastStopGait == "Walk" then
			return _lastStopGait
		end
		if _walkSpeedForLocomotionCompare() > _runLocoWalkSpeedThreshold() then
			return "Run"
		end
		return "Walk"
	end

	--[[
		本次手势是否短到应跳过 Stop* 直接 Idle
		@return boolean - true 表示跳过停步衔接轨
	]]
	local function _shouldSkipStopForShortGesture(): boolean
		local skipSec = _locoGateSec("MIN_STABLE_MOVE_FOR_STOP_SEC", 0.3)
		if skipSec <= 0 then
			return false
		end
		local nowClock = time()
		if _locoGestureStartClock > 0 and (nowClock - _locoGestureStartClock) < skipSec then
			return true
		end
		if _locoStableEnteredClock > 0 and (nowClock - _locoStableEnteredClock) < skipSec then
			return true
		end
		return false
	end

	--[[
		根据速度与 WalkSpeed 计算期望稳定态
		@param moveSpeed number - 当前移动速度
		@return "Idle" | "Walk" | "Run" - 期望 locomotion 稳定态
	]]
	local function _computeDesiredLocomotion(moveSpeed: number): "Idle" | "Walk" | "Run"
		-- Land 窗粘滞：落地 MoveDirection 偶发归零时仍可进走跑
		local landSticky = _pose == "Land" and _hasStickyRecentMoveIntent()
		if not _hasMoveInputIntent() and not landSticky then
			return "Idle"
		end
		-- 无输入时视为应收束：惯性残余 Running 不驱动 Run/Walk（Land 粘滞除外）
		if not landSticky and not _hasLocomotionMoveOrIntent(moveSpeed) then
			return "Idle"
		end
		if _walkSpeedForLocomotionCompare() > _runLocoWalkSpeedThreshold() then
			return "Run"
		end
		return "Walk"
	end

	--[[
		把 Walk/Run 视觉挂到 Animate（Strafe 连续混合，或 ENABLE=false 时扇区硬切）
		@param gait "Walk" | "Run" - 目标步态
		@param speed number - 当前移动速度（AdjustSpeed）
		@param fadeTime number? - crossfade 秒数
	]]
	local function _applyGaitVisual(gait: "Walk" | "Run", speed: number, fadeTime: number?)
		animate:setBaseSpeed(gait, deps.getRunAnimationSpeed(speed, gait))
		local strafeOn = deps.isShiftLocked()
			and deps.isStrafeBlendEnabled
			and deps.isStrafeBlendEnabled()
		if strafeOn or not deps.isShiftLocked() then
			animate:setBasePos(gait, fadeTime)
			return
		end
		-- StrafeBlend.ENABLE=false：扇区硬切降级
		local direction = deps.getRelativeMoveDirection()
		if direction == "Left" then
			animate:setBasePos(gait .. "_Left", fadeTime)
		elseif direction == "Right" then
			animate:setBasePos(gait .. "_Right", fadeTime)
		elseif direction == "Back" then
			animate:setBasePos(gait .. "_Back", fadeTime)
		else
			animate:setBasePos(gait, fadeTime)
		end
	end

	--[[
		应用 Run/Walk/Idle 循环动画到 Animate
		@param stable "Idle" | "Walk" | "Run" - 目标稳定态（权威语义；ClimbAssist 可把 Run 视觉覆盖为 Walk）
		@param speed number - 当前移动速度（用于 AdjustSpeed）
		@param fadeTime number? - 覆盖默认 crossfade；再启动回切走跑时宜传短 fade
		  从 Land 切 Walk/Run 时强制使用 LAND_TO_MOVE_FADE，加快前向 Land 淡出
	]]
	local function _applyStableLocomotionVisual(stable: "Idle" | "Walk" | "Run", speed: number, fadeTime: number?)
		local visualStable = stable
		local climbOverride = false
		if stable == "Run" and _shouldSuppressRunLean() then
			visualStable = "Walk"
			climbOverride = true
			local climbFade = _climbAssistSuppressFade()
			if fadeTime == nil or fadeTime > climbFade then
				fadeTime = climbFade
			end
		end

		if (visualStable == "Walk" or visualStable == "Run") and _pose == "Land" then
			local landFade = setting.LAND_TO_MOVE_FADE
			if type(landFade) ~= "number" or landFade ~= landFade or landFade < 0 then
				landFade = 0.08
			end
			fadeTime = landFade
		end
		if visualStable ~= "Idle" then
			_landHoldIdleUntil = 0
		end
		local nowStable = time()
		if visualStable == "Idle" then
			if _pose == "Land" and nowStable < _landHoldIdleUntil then
				return
			end
		end

		if visualStable == "Run" then
			_applyGaitVisual("Run", speed, fadeTime)
			_pose = "Run"
			_idleEnteredClock = 0
			_noteStopGait("Run")
		elseif visualStable == "Walk" then
			_applyGaitVisual("Walk", speed, fadeTime)
			_pose = "Walk"
			_idleEnteredClock = 0
			-- ClimbAssist 覆盖期间勿把 _lastStopGait 写成 Walk（否则松键丢 StopRun）
			if not climbOverride then
				_noteStopGait("Walk")
			end
		else
			local idleFade = fadeTime
			if idleFade == nil then
				idleFade = setting.IDLE_ENTER_FADE
				if type(idleFade) ~= "number" or idleFade ~= idleFade or idleFade < 0 then
					idleFade = 0.2
				end
			end
			animate:setBasePos("Idle", idleFade)
			-- 仅在「进入」Idle 时打点；每帧刷新会导致 IDLE_REENTER 永远命中并跳过 Start*
			if _pose ~= "Idle" then
				_idleEnteredClock = time()
				_clearLocoGesture()
			end
			_pose = "Idle"
		end
		if stable == "Idle" then
			clearLandTimingWindows()
		end
	end

	--[[
		落地弱锁期间是否应阻止 Idle/Stop 收尾（仅 FSM：不替代 Land 轨的 Action Priority）
		@param nowClock number - time()
		@return boolean - 是否保持 Land 不被本模块 Idle 打断
]]
	local function _holdingLandAgainstIdle(nowClock: number): boolean
		return _pose == "Land" and nowClock < _landHoldIdleUntil
	end

	--[[
		开始播放地面衔接轨（StartRun/StopWalk 等）
		@param transitionName string - 衔接轨名称
		@param stableAfter "Idle" | "Walk" | "Run" - 衔接结束后的稳定态
		@param speed number - 当前移动速度
	]]
	local function _beginGroundTransition(transitionName: string, stableAfter: "Idle" | "Walk" | "Run", speed: number)
		local drv = setting.GroundLocomotionDriver
		if drv and drv.debugPrintGroundTransition then
			print(
				"[GroundTransition] 衔接:",
				transitionName,
				"目标稳定态:",
				stableAfter,
				"移动速度:",
				speed,
				"WalkSpeed:",
				humanoid.WalkSpeed,
				"有效(含预期):",
				_walkSpeedForLocomotionCompare(),
				"跑走阈值:",
				_runLocoWalkSpeedThreshold()
			)
		end
		_groundTransitionToken += 1
		local myToken = _groundTransitionToken
		local minVis = 0.06
		if drv and drv.transitionMinVisibleSeconds ~= nil then
			minVis = math.max(0, drv.transitionMinVisibleSeconds :: number)
		end
		_transitionMinVisibleEndClock = time() + minVis
		_groundTransition = transitionName
		_pose = transitionName
		if transitionName == "StartRun" or transitionName == "StartWalk" then
			_markLocoGestureStart()
			if transitionName == "StartRun" then
				_noteStopGait("Run")
			else
				_noteStopGait("Walk")
			end
		end

		if stableAfter == "Run" then
			animate:setBaseSpeed("Run", deps.getRunAnimationSpeed(speed, "Run"))
		elseif stableAfter == "Walk" then
			animate:setBaseSpeed("Walk", deps.getRunAnimationSpeed(speed, "Walk"))
		end

		--[[
			衔接 commit 时刻：先停衔接轨再切稳定态，避免 Start*/Stop* 与循环叠播
		]]
		local function _commitTransitionStableEarly()
			if not character.Parent then
				return
			end
			if myToken ~= _groundTransitionToken then
				return
			end
			if _groundTransition ~= transitionName then
				return
			end
			-- 必须先停衔接轨再切稳定态，否则 Start*/Stop* 会与 Idle/Walk/Run 叠播
			local cancel = _groundAnimateCancel
			_groundAnimateCancel = nil
			_groundTransitionToken += 1
			_groundTransition = nil
			if cancel then
				cancel()
			end
			_groundStable = stableAfter
			if stableAfter == "Walk" or stableAfter == "Run" then
				_markLocoStableEntered()
			end
			_applyStableLocomotionVisual(stableAfter, _groundMoveSpeed)
		end

		local ok, cancelFn = animate:playTransition(transitionName, function()
			if not character.Parent then
				return
			end
			if myToken ~= _groundTransitionToken then
				return
			end
			if _groundTransition ~= transitionName then
				return
			end
			_groundTransition = nil
			_groundAnimateCancel = nil
			_groundStable = stableAfter
			if stableAfter == "Walk" or stableAfter == "Run" then
				_markLocoStableEntered()
			end
			_applyStableLocomotionVisual(stableAfter, _groundMoveSpeed)
		end, _transitionOpts(transitionName))

		if not ok then
			_groundTransition = nil
			_groundAnimateCancel = nil
			_groundTransitionToken += 1
			_groundStable = stableAfter
			if stableAfter == "Walk" or stableAfter == "Run" then
				_markLocoStableEntered()
			end
			_applyStableLocomotionVisual(stableAfter, speed)
			return
		end

		_groundAnimateCancel = cancelFn

		local pack = setting.Transition and setting.Transition[transitionName]
		local commitAfter = pack and pack.commitStableAfterSeconds
		if type(commitAfter) == "number" and commitAfter == commitAfter and commitAfter > 0 then
			task.delay(commitAfter, _commitTransitionStableEarly)
		end
	end

	--[[
		刷新地面 locomotion FSM（意图态 → 衔接轨 → 稳定态）
		含停步门闩（方案 A）：保留 Start*；松键防抖 / 短手势跳过 Stop / Start 打断回 Idle。
		停步选片按 _lastStopGait；Run→Walk 受 RUN_DEMOTE_HOLD_SEC 门闩约束。
		@param desired "Idle" | "Walk" | "Run" - 本帧期望稳定态
		@param speed number - 当前移动速度
	]]
	local function _refreshGroundLocomotion(desired: "Idle" | "Walk" | "Run", speed: number)
		local now = time()
		_groundDesired = desired
		if desired == "Walk" or desired == "Run" then
			_skipLocoStopAfterLand = false
			clearLandTimingWindows()
			-- 再按：取消停步等待，继续走跑循环
			_stopPendingSince = 0
			_refreshLastActiveMoveDir()
		end
		if desired == "Run" then
			_runDemotePendingSince = 0
			_stopGaitWalkStickySince = 0
		end

		if _groundTransition then
			local trName = _groundTransition
			local implied = trName and _TRANSITION_IMPLIED_STABLE[trName]
			if implied and desired ~= implied then
				-- StartRun 期间 Walk 闪一下：保持起步戏，勿打断成硬切
				if trName == "StartRun" and desired == "Walk" then
					return
				end
				-- StartWalk 升到 Run：改播 StartRun，勿直切 Run
				if trName == "StartWalk" and desired == "Run" then
					if _groundAnimateCancel then
						_groundAnimateCancel()
						_groundAnimateCancel = nil
					end
					_groundTransitionToken += 1
					_groundTransition = nil
					if _isGroundTransitionEnabled("StartRun") then
						_beginGroundTransition("StartRun", "Run", speed)
					else
						_groundStable = "Run"
						_markLocoStableEntered()
						_applyStableLocomotionVisual("Run", speed)
					end
					return
				end
				-- 再启动移动：立刻打断 Stop*/Start*，勿等 minVisible（否则手感延迟）
				local canInterrupt = (desired == "Walk" or desired == "Run") or (now >= _transitionMinVisibleEndClock)
				if canInterrupt then
					if _groundAnimateCancel then
						_groundAnimateCancel()
						_groundAnimateCancel = nil
					end
					_groundTransitionToken += 1
					_groundTransition = nil
					_groundStable = desired
					local reenter, moveFade = false, nil
					if desired == "Idle" then
						_clearLocoGesture()
					elseif desired == "Walk" or desired == "Run" then
						_markLocoStableEntered()
						reenter, moveFade = _idleReenterMoveOptions()
					end
					_applyStableLocomotionVisual(desired, speed, if reenter then moveFade else nil)
					return
				end
			end
			return
		end

		local runWalkSpeedTh = _runLocoWalkSpeedThreshold()

		-- 立刻起步：有输入即播 Start*（或直切稳定态）；不推迟动画
		-- ShiftLock 非前进 / Idle fade 窗口内再启动：跳过 Start*，短 fade 回切
		if _groundStable == "Idle" and (desired == "Walk" or desired == "Run") then
			_markLocoGestureStart()
			local reenter, moveFade = _idleReenterMoveOptions()
			if reenter or _shouldSkipTransitionForNonForwardStrafe() then
				_groundStable = desired
				_markLocoStableEntered()
				_applyStableLocomotionVisual(desired, speed, moveFade)
			elseif _walkSpeedForLocomotionCompare() > runWalkSpeedTh then
				if _isGroundTransitionEnabled("StartRun") then
					_beginGroundTransition("StartRun", "Run", speed)
				else
					_groundStable = "Run"
					_markLocoStableEntered()
					_applyStableLocomotionVisual("Run", speed)
				end
			elseif _isGroundTransitionEnabled("StartWalk") then
				_beginGroundTransition("StartWalk", "Walk", speed)
			else
				_groundStable = "Walk"
				_markLocoStableEntered()
				_applyStableLocomotionVisual("Walk", speed)
			end
		elseif desired == "Idle" and (_groundStable == "Run" or _groundStable == "Walk") then
			if _holdingLandAgainstIdle(now) then
				return
			end
			if _skipLocoStopAfterLand then
				_skipLocoStopAfterLand = false
				_groundStable = "Idle"
				_applyStableLocomotionVisual("Idle", speed)
				return
			end
			if _suppressLocoStopUntil > 0 and now < _suppressLocoStopUntil then
				_groundStable = "Idle"
				_applyStableLocomotionVisual("Idle", speed)
				return
			end
			-- 松键防抖：短时间内再按则上方已清 _stopPendingSince 并保持循环
			local stopDelay = _locoGateSec("STOP_RELEASE_DELAY_SEC", 0.12)
			if stopDelay > 0 then
				if _stopPendingSince <= 0 then
					_stopPendingSince = now
				end
				if (now - _stopPendingSince) < stopDelay then
					_applyStableLocomotionVisual(_groundStable, speed)
					return
				end
			end
			_stopPendingSince = 0
			_runDemotePendingSince = 0
			-- 短手势：跳过 Stop*，直接 Idle
			if _shouldSkipStopForShortGesture() then
				_groundStable = "Idle"
				_applyStableLocomotionVisual("Idle", speed)
				return
			end
			-- 定稿：侧移/后退跳过 Stop*，短 fade 直切 Idle（勿播前向 StopRun）
			if _shouldSkipTransitionForNonForwardStrafe() then
				_groundStable = "Idle"
				_clearLocoGesture()
				_applyStableLocomotionVisual("Idle", speed)
				return
			end
			-- 按最近稳定步态选 Stop*（先松 Sprint 再松方向仍可 StopRun）
			local stopFrom = _resolveStopFromGait()
			if stopFrom == "Run" then
				if _isGroundTransitionEnabled("StopRun") then
					_beginGroundTransition("StopRun", "Idle", speed)
				else
					_groundStable = "Idle"
					_applyStableLocomotionVisual("Idle", speed)
				end
			else
				if _isGroundTransitionEnabled("StopWalk") then
					_beginGroundTransition("StopWalk", "Idle", speed)
				else
					_groundStable = "Idle"
					_applyStableLocomotionVisual("Idle", speed)
				end
			end
		elseif _groundStable ~= desired then
			if _holdingLandAgainstIdle(now) and desired ~= "Walk" and desired ~= "Run" then
				return
			end
			-- Run→Walk 降档门闩：短时保持 Run，窗内松方向走上方 Idle 分支（StopRun）
			if _groundStable == "Run" and desired == "Walk" then
				local demoteHold = _locoGateSec("RUN_DEMOTE_HOLD_SEC", 0.15)
				if demoteHold > 0 then
					if _runDemotePendingSince <= 0 then
						_runDemotePendingSince = now
					end
					if (now - _runDemotePendingSince) < demoteHold then
						_applyStableLocomotionVisual("Run", speed)
						return
					end
				end
				_runDemotePendingSince = 0
			else
				_runDemotePendingSince = 0
			end
			if desired == "Walk" or desired == "Run" then
				_markLocoGestureStart()
				_markLocoStableEntered()
			end
			-- 稳态 Walk↔Run：短 gait fade（相位对齐在 Animate.setBasePos）
			local gaitFade: number? = nil
			if (_groundStable == "Walk" or _groundStable == "Run")
				and (desired == "Walk" or desired == "Run")
			then
				local gb = setting.GaitBlend
				local f = gb and gb.FADE
				if type(f) == "number" and f == f and f >= 0 then
					gaitFade = f
				end
			end
			_groundStable = desired
			_applyStableLocomotionVisual(desired, speed, gaitFade)
		else
			-- 稳态保持：走跑继续调速；Idle 勿每帧重入（会刷新 idle 时钟误跳过 Start*）
			if desired == "Walk" or desired == "Run" then
				_applyStableLocomotionVisual(desired, speed)
			end
		end
	end

	--[[
		落地锁期间若已出现收束到 Idle 的意图，记录以便落地结束后跳过 StopRun/StopWalk
	]]
	local function _maybeRecordSkipLocoStopWhileLanding()
		local desiredDuringLand = _computeDesiredLocomotion(_groundMoveSpeed)
		if desiredDuringLand == "Idle" and (_groundStable == "Run" or _groundStable == "Walk") then
			_skipLocoStopAfterLand = true
		end
	end

	--[[
		按速度刷新地面 FSM（含攀爬接近时打断 Start*）
		@param speed number - 当前地面移动速度
	]]
	local function _applyGroundLocomotion(speed: number)
		-- 接近梯子：打断 Start*，避免起步戏继续保持跑姿前倾
		if _shouldSuppressRunLean() and (_groundTransition == "StartRun" or _groundTransition == "StartWalk") then
			local wasStartRun = _groundTransition == "StartRun"
			if _groundAnimateCancel then
				_groundAnimateCancel()
				_groundAnimateCancel = nil
			end
			_groundTransitionToken += 1
			_groundTransition = nil
			_groundStable = if wasStartRun then "Run" else "Walk"
			_markLocoStableEntered()
			_applyStableLocomotionVisual(_groundStable, speed, _climbAssistSuppressFade())
			return
		end
		local desired = _computeDesiredLocomotion(speed)
		_refreshGroundLocomotion(desired, speed)
	end

	--[[
		跑跳落地后设置 StopRun/StopWalk 抑制截止时间
	]]
	local function _applyRunJumpLandSuppress(landEnd: number)
		local extra = setting.LAND_POST_STOP_SUPPRESS_AFTER_RUN_JUMP
		if type(extra) == "number" and extra == extra and extra > 0 then
			_suppressLocoStopUntil = landEnd + extra
		else
			_suppressLocoStopUntil = landEnd
		end
	end

	--[[
		Humanoid.Running：更新地面移动速度（攀爬/游泳态忽略，避免污染地面速度）
		@param walkspeed number - Running 回调速度
	]]
	local function onRunning(walkspeed: number)
		local stRunning = humanoid:GetState()
		if stRunning ~= Enum.HumanoidStateType.Climbing and stRunning ~= Enum.HumanoidStateType.Swimming then
			_groundMoveSpeed = walkspeed
		end
	end

	--[[
		Humanoid.Jumping：起跳切 Jump 姿态；Gate 抑制时跳过
		@param active boolean - true 表示进入跳跃
	]]
	local function onJumping(active: boolean)
		if active == false then
			return
		end
		if deps.isLocoSuppressed() then
			return
		end
		_airJumpFromRun = (_groundStable == "Run")
		_airStartTime = time()
		abortDriver()
		animate:setBasePos("Jump")
		_jumpFallDeadline = time() + MIN_JUMP_ANIMATION_TIME
		_pose = "Jump"
	end

	--[[
		Humanoid.FreeFalling：记录腾空起止时刻，供 Fall 最短时长过滤
		@param active boolean - true 进入自由落体，false 结束
	]]
	local function onFreeFalling(active: boolean)
		if active and not _isFreefall then
			_isFreefall = true
			_freefallStartTime = time()
			if _airStartTime == 0 then
				_airStartTime = time()
			end
		elseif not active and _isFreefall then
			_isFreefall = false
		end
	end

	--[[
		Humanoid.Climbing：用攀爬速度覆盖 _groundMoveSpeed（供 Climb 轨调速）
		@param climbspeed number - 攀爬速度
	]]
	local function onClimbing(climbspeed: number)
		_groundMoveSpeed = climbspeed
	end

	--[[
		Humanoid.Swimming：用游泳速度覆盖 _groundMoveSpeed
		@param swimspeed number - 游泳速度
	]]
	local function onSwimming(swimspeed: number)
		_groundMoveSpeed = swimspeed
	end

	--[[
		Humanoid.StateChanged：仅处理 Landed，播 Land/LightLand 并开落地时间窗
		@param _oldState Enum.HumanoidStateType - 切换前状态（未使用）
		@param newState Enum.HumanoidStateType - 新状态
	]]
	local function onStateChanged(_oldState: Enum.HumanoidStateType, newState: Enum.HumanoidStateType)
		if newState ~= Enum.HumanoidStateType.Landed then
			return
		end
		if deps.isLocoSuppressed() then
			return
		end
		_skipLocoStopAfterLand = false
		abortDriver()
		_isFreefall = false
		local airTime = (_airStartTime > 0) and (time() - _airStartTime) or 0
		local wouldHeavyLand = airTime >= FALL_LAND_THRESHOLD

		if _shouldSkipLandAnimation(airTime, wouldHeavyLand) then
			clearLandTimingWindows()
			if _airJumpFromRun then
				_airJumpFromRun = false
				_applyRunJumpLandSuppress(time() + LAND_ANIM_TIME)
			end
		else
			local landPos = wouldHeavyLand and "Land" or "LightLand"
			animate:setBasePos(landPos)
			_pose = "Land"
			FootLand.OnLanded(character, wouldHeavyLand)
			local landedAt = time()
			local landEnd = landedAt + LAND_ANIM_TIME
			_landHoldIdleUntil = landEnd
			if _airJumpFromRun then
				_airJumpFromRun = false
				_applyRunJumpLandSuppress(landEnd)
			end
			-- 有意图（含粘滞）：不进强锁，同帧早切 Walk/Run，避免等下一 Heartbeat 且防 MD 抖动
			if _hasLandLockBypassIntent() then
				_landLockDeadline = 0
				_applyGroundLocomotion(_groundMoveSpeed)
			else
				_landLockDeadline = landedAt + LAND_LOCO_INTERRUPT_LOCK_SEC
			end
		end
	end

	--[[
		每帧更新 locomotion 姿态（由 Heartbeat 调用）
		@param _dt number - 帧间隔（未使用，保留签名）
	]]
	local function update(_dt: number)
		local now = time()

		-- 空中/落地全程刷新意图时钟，供粘滞旁路使用
		_noteMoveIntentIfAny()

		if deps.isLocoSuppressed() then
			return
		end

		local st = humanoid:GetState()
		local isNowFreefall = _isFreefall or st == Enum.HumanoidStateType.Freefall
		local onGround = humanoid.FloorMaterial ~= Enum.Material.Air

		if st == Enum.HumanoidStateType.Swimming then
			abortDriver()
			clearLandTimingWindows()
			local swimThreshold = setting.SWIM_MOVE_DIRECTION_THRESHOLD
			if type(swimThreshold) ~= "number" or swimThreshold ~= swimThreshold or swimThreshold < 0 then
				swimThreshold = MOVE_INTENT_FOR_LOCO
			end
			local hasSwimMoveIntent = humanoid.MoveDirection.Magnitude >= swimThreshold
			local swimPose: BaseAnimateEnum = if hasSwimMoveIntent then "Swim" else "SwimIdle"
			if _pose ~= swimPose then
				animate:setBasePos(swimPose)
				_pose = swimPose
			end
			return
		end

		if st == Enum.HumanoidStateType.Climbing then
			abortDriver()
			clearLandTimingWindows()
			animate:setBaseSpeed("Climb", deps.getRunAnimationSpeed(_groundMoveSpeed, "Climb"))
			if _pose ~= "Climb" then
				animate:setBasePos("Climb")
				_pose = "Climb"
			end
			return
		end

		if _landLockDeadline > 0 and now < _landLockDeadline then
			-- 有移动意图（含粘滞）且允许旁路：取消 interrupt 强锁，本帧继续 loco
			if _hasLandLockBypassIntent() then
				_landLockDeadline = 0
			else
				-- FSM 强锁：不向 Jump/Fall/loco 让步；不挡外部 AnimationTrack
				_maybeRecordSkipLocoStopWhileLanding()
				return
			end
		end
		if _holdingLandAgainstIdle(now) then
			_maybeRecordSkipLocoStopWhileLanding()
		end

		if st == Enum.HumanoidStateType.Jumping then
			abortDriver()
			clearLandTimingWindows()
			if _pose ~= "Jump" then
				animate:setBasePos("Jump")
				_pose = "Jump"
			end
			return
		end

		if isNowFreefall then
			abortDriver()
			clearLandTimingWindows()
			local freefallLongEnough = (now - _freefallStartTime) >= FREEFALL_MIN_DURATION
			local jumpAllowFall = now >= _jumpFallDeadline

			if jumpAllowFall and freefallLongEnough then
				if _pose ~= "Fall" then
					animate:setBasePos("Fall")
					_pose = "Fall"
				end
			end
			return
		end

		if not onGround then
			abortDriver()
			clearLandTimingWindows()
			if now >= _jumpFallDeadline and _pose ~= "Fall" then
				animate:setBasePos("Fall")
				_pose = "Fall"
			end
			return
		end

		_applyGroundLocomotion(_groundMoveSpeed)
	end

	--[[
		当前地面稳定步态（Strafe 跟视觉族：抑制 Run 前倾时对外报 Walk）
		@return string - Idle | Walk | Run 等；权威 _groundStable 仍可为 Run
	]]
	local function getGroundStable(): string
		-- StrafeBlend 须跟视觉族：抑制 Run 前倾时对外报 Walk，权威 _groundStable 仍可为 Run
		if _shouldSuppressRunLean() and _groundStable == "Run" then
			return "Walk"
		end
		return _groundStable
	end

	--[[
		当前是否处于腾空 loco 姿态（供 AirLean；非 Jump/Fall 返回 nil）
		@return string? - "Jump" | "Fall" | nil
	]]
	local function getAirPose(): string?
		if _pose == "Jump" or _pose == "Fall" then
			return _pose
		end
		return nil
	end

	--[[
		地面走跑视觉是否已挂上（Walk/Run；含 Strafe 前向基轨与扇区硬切）
		Land/衔接期间为 false，供 AirLean 在侧移落地时延后回正。
		@return boolean - true 表示 _pose 已是 Walk/Run
	]]
	local function isGroundMovePose(): boolean
		return _pose == "Walk" or _pose == "Run"
	end

	--[[
		是否允许 StrafeBlend：须已进入 Walk/Run 稳定循环，且无衔接轨/跳跃落地等抢占姿态。
		仅看 _groundStable 会在 Jump/Stop* 期间仍返回 Run，导致方向轨叠在其它动作上错乱。
		注意：换键瞬间 MoveDirection 会短暂归零，此处不可要求「有移动意图」，
		否则会 shutdown 恢复前向，表现为左↔右先闪向前再切目标方向。
		@return boolean - true 表示本帧可更新方向混合
	]]
	local function canStrafeBlend(): boolean
		if deps.isLocoSuppressed() then
			return false
		end
		if _groundTransition ~= nil then
			return false
		end
		if _groundStable ~= "Walk" and _groundStable ~= "Run" then
			return false
		end
		if _pose ~= "Walk" and _pose ~= "Run" then
			return false
		end
		local basePos = animate.BasePos
		if basePos ~= "Walk" and basePos ~= "Run" then
			return false
		end
		return true
	end

	--[[
		解 pauseBase 后同帧接腿：按当前 Humanoid / 意图短 fade 直切稳定态。
		跳过 Start*/Stop*（技能结束应「已在目标态」，不是再播起步/停步戏）。
		调用前须 Animate.resumeBaseAction + invalidateBasePose，否则同名稳定态可能不播。
	]]
	local function resyncAfterBaseUnpause()
		abortDriver()
		clearLandTimingWindows()
		_pose = ""
		_stopPendingSince = 0
		_skipLocoStopAfterLand = false

		local reenter = setting.IDLE_REENTER
		local shortFade = 0.08
		if reenter and type(reenter.MOVE_FADE) == "number" and reenter.MOVE_FADE == reenter.MOVE_FADE and reenter.MOVE_FADE >= 0 then
			shortFade = reenter.MOVE_FADE
		end

		local st = humanoid:GetState()
		local onGround = humanoid.FloorMaterial ~= Enum.Material.Air
		local isNowFreefall = _isFreefall or st == Enum.HumanoidStateType.Freefall

		if st == Enum.HumanoidStateType.Swimming then
			local swimThreshold = setting.SWIM_MOVE_DIRECTION_THRESHOLD
			if type(swimThreshold) ~= "number" or swimThreshold ~= swimThreshold or swimThreshold < 0 then
				swimThreshold = MOVE_INTENT_FOR_LOCO
			end
			local hasSwimMoveIntent = humanoid.MoveDirection.Magnitude >= swimThreshold
			local swimPose: BaseAnimateEnum = if hasSwimMoveIntent then "Swim" else "SwimIdle"
			animate:setBasePos(swimPose, shortFade)
			_pose = swimPose
			_groundStable = "Idle"
			return
		end

		if st == Enum.HumanoidStateType.Climbing then
			animate:setBaseSpeed("Climb", deps.getRunAnimationSpeed(_groundMoveSpeed, "Climb"))
			animate:setBasePos("Climb", shortFade)
			_pose = "Climb"
			_groundStable = "Idle"
			return
		end

		if st == Enum.HumanoidStateType.Jumping then
			animate:setBasePos("Jump", shortFade)
			_pose = "Jump"
			return
		end

		if isNowFreefall or not onGround then
			-- 解闸直切 Fall：不套 Jump→Fall 最短时长门闩（技能结束应立刻可读腾空）
			animate:setBasePos("Fall", shortFade)
			_pose = "Fall"
			return
		end

		local desired = _computeDesiredLocomotion(_groundMoveSpeed)
		_groundStable = desired
		if desired == "Walk" or desired == "Run" then
			_markLocoGestureStart()
			_markLocoStableEntered()
		else
			_clearLocoGesture()
		end
		_applyStableLocomotionVisual(desired, _groundMoveSpeed, shortFade)
	end

	--[[
		冲刺 FOV 是否应开始回收（与停步戏 / 无意图同相；仍受 AnimateFov minHold 约束）。
		StopRun/StopWalk 起拍即 true；无意图但 AntiFlicker 停步等待窗内仍 false（腿还在 Run）。
		@return boolean - true 表示应开始收冲刺 FOV
	]]
	local function shouldReleaseSprintFov(): boolean
		if _groundTransition == "StopRun" or _groundTransition == "StopWalk" then
			return true
		end
		if _hasMoveInputIntent() then
			return false
		end
		-- 停步防抖窗内仍持 Run 循环：暂不因意图丢失收 FOV
		if _stopPendingSince > 0 then
			return false
		end
		return true
	end

	--[[
		销毁：中断衔接驱动并清落地时间窗（连接由 Animate 入口统一 Disconnect）
	]]
	local function destroy()
		abortDriver()
		clearLandTimingWindows()
		_lastMoveIntentClock = 0
	end

	return {
		onRunning = onRunning,
		onJumping = onJumping,
		onFreeFalling = onFreeFalling,
		onClimbing = onClimbing,
		onSwimming = onSwimming,
		onStateChanged = onStateChanged,
		update = update,
		abortDriver = abortDriver,
		clearLandTimingWindows = clearLandTimingWindows,
		getGroundStable = getGroundStable,
		canStrafeBlend = canStrafeBlend,
		getAirPose = getAirPose,
		isGroundMovePose = isGroundMovePose,
		resyncAfterBaseUnpause = resyncAfterBaseUnpause,
		shouldReleaseSprintFov = shouldReleaseSprintFov,
		destroy = destroy,
	}
end

return GroundLocomotion
