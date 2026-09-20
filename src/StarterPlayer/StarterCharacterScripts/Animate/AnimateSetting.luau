--[[
	Module: AnimateSetting
	Description: Animate 角色动画系统的可调配置（地面衔接、落地、FOV、动作速度基准、MotionPhase 单表派生等）。
	Author: 林奥宇
	Created: 2026-07-03
	Last Modified: 2026-09-03

	使用：local Setting = require(script.AnimateSetting)；只读引用，勿在运行时篡改表内容。
	与 CharacterMoveSpeed 协作：
	- EXPECTED_WALKSPEED_ATTRIBUTE、RUN_LOCOMOTION_WALKSPEED_THRESHOLD 参与跑走判定
	- 时长权威在 MotionPhase（accelPhase/decelPhase + 比例）；SpeedCurve / Transition / IDLE_ENTER_FADE 由 Build 派生，禁止手填漂移
	朝向权威：ShiftLockFacing 描述 Animate 何时可写 HRP 偏航（仅 init RenderStep 写口消费）；冲突态让出给 ActionArbiter.facingOwner。
	动作仲裁：ActionArbiter 表控制 Attribute Bridge；新业务请直调 Utils.ActionArbiter。
	方向混合：StrafeBlend（ShiftLock 下 Cardinal 双轨权重）。
	图腿姿：GraphLoco（默认关；开且 Load 成功则同一 animate 包装只喂已发布图，不改 FSM）。
	步态互切：GaitBlend（稳态 Walk↔Run 短 fade + 归一化脚相位对齐；Strafe 激活时保留 cardinal 权重跨族 retarget；非 Idle/衔接/跳跃）。
	侧移/后退起停（定稿）：ShiftLock 非前向一律跳过 Start*/Stop*，短 fade 直切稳定态；勿播前向衔接片冒充。
	  方向起停资源待时机成熟再补；补齐前勿把 TransitionEnable 当侧移开关。
	落地/起跳：LAND_* / MIN_JUMP_* 仅 FSM 自打断；抗业务 Idle 靠 init 绑定 Priority（Jump=Movement，Land=Action）。
	落地强锁条件化：无移动意图满锁 LAND_LOCO_INTERRUPT_LOCK_SEC；有意图（含 LAND_MOVE_INTENT_STICKY_SEC 粘滞）时旁路强锁
	  并短 fade 早切 Walk/Run（LAND_TO_MOVE_FADE），让 StrafeBlend 尽快接手，避免 ShiftLock 侧移落地短暂前向卡姿。
	空中方向（定稿）：无 Fall 四向轨前，ShiftLock 下 Jump/Fall 用 AirLean 程序倾侧表达 MoveYaw；
	  本项目为 R6：写 HumanoidRootPart.RootJoint.C0，不写 R15 Waist；勿半开空中 Cardinal 混合。
	  侧移落地：Land 窗内保持 lean，待地面 Walk/Run 就绪后再放，避免先回正再侧移。
	攀爬接近：ClimbAssist 表；GroundLocomotion 消费 suppressRunLean（Run 视觉→Walk）。

	调参入口：只改 MotionPhase（及 TransitionEnable / GaitBlend / GraphLoco / AirLean / ClimbAssist 等非时长开关）。
	消费入口：仍读 Setting.SpeedCurve / Setting.Transition（派生只读结果）。
	FOV：有移动意图时进入跟 max(Running, ExpectedWalkSpeed)；退出 = 速度滞回或 Stop*/无意图（过 AntiFlicker）。
	  满开时长由 StartRun commit 派生 changeSpeed；收镜时长由 StopRun commit 派生 resumeSpeed。
	  抑制：cameraOwner ~= Default，或 Gate suppressLoco / pauseBaseTracks（sprint 缓收，输出不断层）。
	  技能前冲脉冲：经 CameraImpulse.emit → AnimateFov；与 sprint 同 Helper，禁止平行 Helper。
	  cancel/解闸：dash 残量 handoff 进 sprint 或短 fade，禁止硬切 0。
]]

local Setting = {}

-- 腾空时间阈值(秒)，超过此值落地使用 Land，否则使用 LightLand
Setting.FALL_LAND_THRESHOLD = 0.6

--[[
	落地 FSM 门闩（只防本模块自打断，不挡业务 AnimationTrack）。
	抗业务 Idle 盖落地靠 Animator Priority（Land=Action）；勿靠加长这些秒数。
	强锁条件化：LAND_LOCO_LOCK_BYPASS_ON_MOVE_INTENT 为 true 且有移动意图（当帧 MoveDirection
	或 LAND_MOVE_INTENT_STICKY_SEC 内最近有过意图）时，仅取消 interrupt 强锁；
	切到 Walk/Run 后由 _applyStableLocomotionVisual 置 0 _landHoldIdleUntil。
	粘滞用于吸收落地瞬间 MoveDirection 偶发归零，避免偶发前向卡姿。
]]
-- 落地后本模块至少维持 Land pose、不主动切 Idle 的时长（秒）
Setting.LAND_ANIM_TIME = 0.48

-- Land 开始后强锁：无移动意图时 FSM 不向 Jump/Fall/地面 locomotion 让步
Setting.LAND_LOCO_INTERRUPT_LOCK_SEC = 0.12

-- true：落地强锁期间若有移动意图则旁路强锁，早切 Walk/Run（StrafeBlend 可立刻开）
Setting.LAND_LOCO_LOCK_BYPASS_ON_MOVE_INTENT = true

-- 最近一次有 MoveDirection 意图后的粘滞秒数；落地旁路/早切 Walk/Run 可用，不单独驱动地面 Idle→走
Setting.LAND_MOVE_INTENT_STICKY_SEC = 0.2

-- Land → Walk/Run 覆盖 fade（秒）；短于默认 BaseAction fade，加快前向 Land 淡出
Setting.LAND_TO_MOVE_FADE = 0.08

--[[
	奔跑起跳后落地：Land FSM 锁结束后的额外秒数内，禁止 StopRun / StopWalk 衔接轨。
	已停步（无 MoveDirection）时仍允许直接切 Idle；仅当起跳时地面稳定态为 Run 时生效。
]]
Setting.LAND_POST_STOP_SUPPRESS_AFTER_RUN_JUMP = 0.35

-- Humanoid.Running 速度大于此值视为「在移动」
Setting.WALK_ANIMATION_SPEED = 0.1

-- 有方向输入也算「在动/起步」，避免 Running 回调晚于 Heartbeat
Setting.MOVE_INTENT_FOR_LOCO = 0.01

--[[
	短间隔点按 WASD 防抽搐（方案 A：保留 Start*，用停步侧门闩）：
	- STOP_RELEASE_DELAY_SEC：松键后短暂保持循环；期间再按则取消停步
	- MIN_STABLE_MOVE_FOR_STOP_SEC：手势过短则跳过 Stop* 直接 Idle
	- RUN_DEMOTE_HOLD_SEC：松冲刺后 Run→Walk 降档短时保持 Run，避免先闪 Walk 再松方向丢 StopRun
	- Start* 被松键打断时直接回 Idle，不接 Stop*
	- 不推迟起步动画；不做「默认跳过 Start*」
	停步选片：按最近稳定步态 _lastStopGait（非当帧 WalkSpeed），见 GroundLocomotion。
]]
Setting.LocoAntiFlicker = {
	STOP_RELEASE_DELAY_SEC = 0.1,
	MIN_STABLE_MOVE_FOR_STOP_SEC = 0.3,
	-- 松 Sprint 后短暂禁止动画降到 Walk；窗内再松方向 → 仍走 StopRun
	RUN_DEMOTE_HOLD_SEC = 0.15,
}

-- 兼容旧名：等同 LocoAntiFlicker.MIN_STABLE_MOVE_FOR_STOP_SEC
Setting.SHORT_LOCO_SKIP_STOP_SEC = 0.3

-- 行走/跑步/攀爬动作速度基准（等于 WalkSpeed 时动作倍率为 1）
Setting.WALK_ACTION_SCALE_SPEED = 15
Setting.RUN_ACTION_SCALE_SPEED = 21
Setting.CLIMB_ACTION_SCALE_SPEED = 20

-- 跳跃 FSM：最短 Jump 时长（秒）后再允许切 Fall；不挡业务轨
Setting.MIN_JUMP_ANIMATION_TIME = 0.3

-- Freefall 切换 Fall 的最短腾空时间（秒），过滤小台阶
Setting.FREEFALL_MIN_DURATION = 0.08

-- 方向迟滞角度（度），减少 Forward/Left/Right/Back 边界抖动
Setting.DIR_HYSTERESIS = 10

-- 游泳时 MoveDirection 模长阈值，低于此视为 SwimIdle
Setting.SWIM_MOVE_DIRECTION_THRESHOLD = 0.01

--[[
	各地面衔接轨是否播放过渡动画；为 false 时直接切到目标稳定态（Run/Walk/Idle）。
	本表只管「前向」起停是否播片；ShiftLock 侧移/后退不读本表。

	产品定稿（侧移/后退）：
	- 暂时永远短 fade 直切 Idle↔Walk/Run（GroundLocomotion._shouldSkipTransitionForNonForwardStrafe）
	- 禁止用前向 Start*/Stop* 冒充侧移/后退起停
	- 方向起停资源待时机成熟再补；补齐后再开对应路径，勿提前半开

	前向默认（按资源品质）：
	- StartRun / StartWalk：开
	- StopRun：开（仅前向跑停）
	- StopWalk：关（走停直切 Idle）
]]
Setting.TransitionEnable = {
	StartRun = true,
	StartWalk = true,
	StopRun = true, -- 仅前向；侧移/后退由代码跳过（定稿：fade 直切）
	StopWalk = false, -- 前向走停品质未达标，直切 Idle
}

--[[
	移→待机 fade 窗口内再次按下移动：跳过 Start*，并用短 fade 切回走跑，避免「动作延迟」。
	SKIP_START_SEC：Build 后与 IDLE_ENTER_FADE 对齐；MOVE_FADE：回切走跑的 crossfade（非 phase，可手填）。
]]
Setting.IDLE_REENTER = {
	SKIP_START_SEC = 0.2, -- Build 会覆盖为 IDLE_ENTER_FADE
	MOVE_FADE = 0.08,
}

--[[
	地面跑走期望：Humanoid.WalkSpeed **严格大于** 此值视为「跑步」。
]]
Setting.RUN_LOCOMOTION_WALKSPEED_THRESHOLD = 16

--[[
	Player 上由 CharacterMoveSpeed 写入的「当前状态最大 WalkSpeed」属性名。
]]
Setting.EXPECTED_WALKSPEED_ATTRIBUTE = "ExpectedWalkSpeed"

--[[
	位移–衔接时间轴唯一手填源（MotionPhase）。
	Build 派生：
	- SpeedCurve.ACCEL/DECEL_DURATION = accelPhase / decelPhase
	- Transition.*.fadeIn/middle/commit 由 phase × 比例算出
	- IDLE_ENTER_FADE = min(decelPhase * idleEnterOfDecel, idleEnterMaxSeconds)

	公理：visible = fadeIn+middle ≤ clipPhase；commit ≤ clipPhase；commit ≥ fadeIn。
	位移 ACCEL/DECEL 只用 accelPhase/decelPhase；clip 可设 phaseSeconds 加长衔接戏（Start* 推荐）。
	禁止再手填 ACCEL_DURATION / middleDuration / commitStableAfterSeconds。
]]
Setting.MotionPhase = {
	ENABLE = true,
	accelPhase = 0.28,
	decelPhase = 0.28,

	accelEasingStyle = Enum.EasingStyle.Quad,
	accelEasingDirection = Enum.EasingDirection.Out,
	decelEasingStyle = Enum.EasingStyle.Quad,
	decelEasingDirection = Enum.EasingDirection.Out,

	-- 无 Stop* 直切 Idle 时，fade 占 decelPhase 的比例与上限
	idleEnterOfDecel = 0.7,
	idleEnterMaxSeconds = 0.2,

	debugPrintMotionPhase = false,

	Defaults = {
		visibleRatio = 1.0,
		fadeInOfVisible = 0.35,
		commitRatio = 0.9,
		fadeOutSeconds = 0.15,
		animationSpeed = 1,
	},

	--[[
		按 clip 覆盖比例 / fadeOut / speed / phaseSeconds。
		phaseSeconds：可选，覆盖该 clip 的衔接可见时钟（可大于 accel/decel）；
		位移仍只用 accelPhase/decelPhase。Start* 宜略长，否则 commit 太早像「没有起步」。
	]]
	Clips = {
		StartRun = {
			phaseSeconds = 0.35, -- 原 0.55 的 75%
			fadeInOfVisible = 0.45,
			commitRatio = 0.85,
			fadeOutSeconds = 0.2,
		},
		StopRun = { fadeInOfVisible = 0.5, commitRatio = 0.9, visibleRatio = 0.7 },
		StartWalk = {
			phaseSeconds = 0.4,
			fadeInOfVisible = 0.5,
			commitRatio = 0.9,
		},
		StopWalk = { fadeInOfVisible = 0.5, commitRatio = 1.0, fadeOutSeconds = 0.1, animationSpeed = 1.5 },
	},
}

Setting.GroundLocomotionDriver = {
	transitionMinVisibleSeconds = 0.06,
	debugPrintGroundTransition = false,
}

--[[
	稳态 Walk↔Run 互切（非 Idle 起停 / 非 Start* Stop*）：
	- FADE：短 crossfade，避免整族硬切
	- PHASE_SYNC：切前读归一化脚相位，Play 后写回 TimePosition；false 时仅短 fade
	与 StrafeBlend.PHASE_SYNC 语义相同、作用域不同（跨步态 vs 同步态方向轨）。
	Strafe 激活时：保留 cardinal 权重直接 retarget 到新步态族，不清成前向单轨。
]]
Setting.GaitBlend = {
	FADE = 0.12,
	PHASE_SYNC = true,
}

--[[
	Animation Graph 腿姿双跑（图复刻 Animate）。
	ENABLE=false：现网基轨 + StrafeBlend，行为不变。
	ENABLE=true：先 Load 已发布图；失败走完整现网；成功则包装同一 animate，只 SetParameter。
	不改 GroundLocomotion FSM；不写 CFrame / WalkSpeed / RootJoint；不 Unbind 偏航。
	与 LocoGraphSpike.SPIKE_ENABLE 运行时互斥（同时真则一方拒绝并 Log）。
	GRAPH_ANIMATION_ID 须与已发布图一致，勿改成未发布草稿。
]]
Setting.GraphLoco = {
	ENABLE = false,
	GRAPH_ANIMATION_ID = "rbxassetid://90774329769612",
}

--[[
	ShiftLock 朝向：角色水平朝向 = 摄像机水平看向（不随 WASD 转身）。
	消费方：init.client 的 RenderStep(Character+1) 唯一写 HRP；Heartbeat 不写偏航。
	后退/侧移由 StrafeBlend 权重表现（ENABLE=false 时降级为扇区硬切）。
	minYawErrorDegrees=0 表示每帧强制对齐。
]]
Setting.ShiftLockFacing = {
	minYawErrorDegrees = 0,
}

--[[
	ShiftLock 方向连续混合（Cardinal Dual-Track）。
	ENABLE=false 时 GroundLocomotion 回退为 Walk_Left 等扇区硬切。
	- YAW_SMOOTH_RATE：先平滑转向角再映射权重，避免前↔后对立插值跳变
	- ZERO_INPUT_HOLD_SEC：换键瞬间保持上一方向混合，超时停步且不恢复 Forward
	- WEIGHT_SMOOTH_RATE：次级权重软化；0=关闭（推荐，主平滑交给 yaw）
	- TRACK_FADE / WEIGHT_FADE：切轨与调权淡入淡出
]]
Setting.StrafeBlend = {
	ENABLE = true,
	YAW_SMOOTH_RATE = 12,
	WEIGHT_SMOOTH_RATE = 0,
	ZERO_INPUT_HOLD_SEC = 0.15,
	MIN_MOVE_MAGNITUDE = 0.01,
	MARKER_LEADER_WEIGHT = 0.55,
	PHASE_SYNC = true,
	WEIGHT_EPSILON = 0.02,
	TRACK_FADE = 0.14,
	WEIGHT_FADE = 0.1,
	-- true：Output 约每 0.25s 打一次 F/L/R/B 权重（仅斜向移动时权重会明显变化）
	debugPrintWeights = false,
}

--[[
	空中方向程序 lean（R6）：ShiftLock + Jump/Fall 时按相机相对 MoveYaw 倾斜躯干。
	写口：HumanoidRootPart.RootJoint.C0 = baseC0 * lean（动画 Transform 之后由 Stepped 写）。
	不改 HRP 偏航 / 移速；非 ShiftLock、Gate suppress/pause 时瞬时复位。
	落地交接：仍有移动意图且尚未进入 Walk/Run 时保持 lean；地面腿轨就绪后再放。
	Fall 四向动画混合另议；本表勿当 Cardinal 开关。
]]
Setting.AirLean = {
	ENABLE = true,
	maxRollDegrees = 30, -- 左/右（MoveYaw 符号）
	maxPitchDegrees = 8, -- 前倾/后仰
	smoothRate = 10,
	zeroInputHoldSec = 0.1,
	-- 地面走跑就绪或无意图后，lean 归零时长（秒）；0=瞬时
	resetSmoothSec = 0.05,
	minMoveMagnitude = 0.01,
}

--[[
	攀爬接近辅助（ClimbAssist）：HRP 多高度射线探测 Truss，有意图朝梯子推进时
	让 GroundLocomotion 将 Run 视觉覆盖为 Walk（短 fade），避免跑姿前倾挤开梯子。
	不改 WalkSpeed；不替代引擎 Climbing。详见 docs/攀爬接近辅助方案.md。
]]
Setting.ClimbAssist = {
	ENABLE = true,
	PROBE_ENTER = 3.5,
	PROBE_EXIT = 4.5,
	HIP_Y_OFFSET = 0.5,
	CHEST_Y_OFFSET = 1.2,
	NORMAL_Y_MAX = 0.35,
	APPROACH_DOT = 0.35,
	MOVE_INTENT_MIN = 0.01,
	-- 空中：水平速度朝梯子推进达到此值也可触发抑制（studs/s）
	AIR_VEL_INTENT_MIN = 2,
	DECOR_PENETRATE_TIMES = 2,
	DECOR_PENETRATE_STEP = 0.08,
	SUPPRESS_FADE = 0.05,
	MAX_SUPPRESS_SEC = 0.45,
	-- 空中抑制可更长（跳向/下落贴梯）
	AIR_MAX_SUPPRESS_SEC = 0.9,
	-- 0：每帧探测；>0 时仅在未抑制期间降频
	PROBE_INTERVAL_SEC = 0,
}

--[[
	动作仲裁（ActionArbiter）：Animate Create + Attribute Bridge 开关。
	新业务请直调 Acquire；Attribute 仅兼容 JetPacking / FacingOverride。
	Skill 占闸由 SkillActionLock 直调 Acquire；enableSkillActionLock 默认 false。
]]
Setting.ActionArbiter = {
	enableAttributeBridge = true,
	enableSkillActionLock = false,
}

--[[
	落地镜头微反馈（FootLand.OnLanded）；音效仍可由 FootStepManager 材质落地路径承担。
	shakeType 对应 EnumMgr.CameraShakeType 数值。
]]
Setting.LandFeedback = {
	heavyShakeEnabled = true,
	heavyShakeType = 1, -- Attack：轻量瞬时，适合重落地
	lightShakeEnabled = false,
	lightShakeType = 1,
}

--[[
	奔跑时相机 FOV 扩展配置；飞行（JetPacking）期间由 FlightSpeedFov 接管，本模块不生效。
	- sprintEnterSpeed：与 RUN_LOCOMOTION_WALKSPEED_THRESHOLD 同义；勿单独改漂
	- ExpectedWalkSpeed 是状态最大移速天花板（站着也可能是跑速），仅「有移动意图」时参与进入
	- sprintExitSpeed：速度兜底滞回（退出另看 shouldReleaseSprintFov：Stop* / 无意图过 AntiFlicker）
	- changeSpeed：Build 后由 StartRun.commitStableAfterSeconds 派生（满开时长≈commit）
	- resumeSpeed：Build 后由 StopRun.commitStableAfterSeconds 派生（收镜时长≈commit）
	- 抑制：cameraOwner ~= Default，或 Gate suppressLoco / pauseBaseTracks（sprint 缓收，输出不断层）
	- dashImpulse*：NewRoll 前冲脉冲（经 CameraImpulse → AnimateFov；禁止业务平行 Helper）
	- dashCancelFadeSec：无 handoff 时取消脉冲的短收时长
]]
Setting.Fov = {
	sprintEnterSpeed = Setting.RUN_LOCOMOTION_WALKSPEED_THRESHOLD,
	-- 速度兜底：意图同相未触发时仍可在减速中段回收
	sprintExitSpeed = 6,
	sprintMinHold = 0.35,
	sprintResumeDelay = 0,
	maxChangeFov = 2,
	changeSpeed = 30, -- 无 Transition 时回退；Build 后覆盖为 maxChangeFov / StartRun.commit
	resumeSpeed = 15, -- 无 Transition 时回退；Build 后覆盖为 maxChangeFov / StopRun.commit
	dashImpulseAddFov = 6,
	dashImpulseRiseSec = 0.5,
	dashImpulseDownSec = 0.5,
	dashCancelFadeSec = 0.15,
}

---------------------------------------------------------------------------
-- MotionPhase → SpeedCurve / Transition / IDLE_ENTER_FADE（加载期派生一次）
---------------------------------------------------------------------------

local CLIP_PHASE_KIND = table.freeze({
	StartRun = "accel",
	StartWalk = "accel",
	StopRun = "decel",
	StopWalk = "decel",
})

--[[
	安全取有限数字，否则回退默认
	@param value any - 候选值
	@param default number - value 非有限数字时的回退
	@return number - 有限数字
]]
local function _finiteNumber(value: any, default: number): number
	if type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge then
		return value
	end
	return default
end

--[[
	合并 Defaults 与 clip 覆盖（仅比例/fadeOut/speed）
	@param defaults table - MotionPhase.Defaults 比例字段
	@param clip any - Clips[name] 覆盖表；非 table 时当空表
	@return table - 已 clamp 的 visibleRatio/fadeInOfVisible/commitRatio/fadeOutSeconds/animationSpeed/phaseSeconds
]]
local function _resolveClipParams(defaults: any, clip: any): any
	local c = if type(clip) == "table" then clip else {}
	local phaseSeconds = c.phaseSeconds
	if type(phaseSeconds) ~= "number" or phaseSeconds ~= phaseSeconds or phaseSeconds < 0 then
		phaseSeconds = nil
	end
	return {
		visibleRatio = math.clamp(_finiteNumber(c.visibleRatio, defaults.visibleRatio), 0, 1),
		fadeInOfVisible = math.clamp(_finiteNumber(c.fadeInOfVisible, defaults.fadeInOfVisible), 0, 1),
		commitRatio = math.clamp(_finiteNumber(c.commitRatio, defaults.commitRatio), 0, 1),
		fadeOutSeconds = math.max(0, _finiteNumber(c.fadeOutSeconds, defaults.fadeOutSeconds)),
		animationSpeed = _finiteNumber(c.animationSpeed, defaults.animationSpeed),
		phaseSeconds = phaseSeconds,
	}
end

--[[
	由 phase + 比例派生单条 Transition 包
	@param phase number - 本 clip 衔接时钟（accel/decel 或 clip.phaseSeconds）
	@param params table - 已合并比例（visibleRatio/fadeInOfVisible/commitRatio/fadeOutSeconds/animationSpeed）
	@return table - TransitionPlayOptions + commitStableAfterSeconds
]]
local function _deriveTransitionPack(phase: number, params: any): any
	local p = math.max(0, phase)
	local visible = p * params.visibleRatio
	local fadeIn = visible * params.fadeInOfVisible
	if fadeIn > p then
		fadeIn = p
	end
	local middle = math.max(0, visible - fadeIn)
	-- commit ≤ phase，且至少混入 fadeIn 后再切循环
	local commit = math.min(p, p * params.commitRatio)
	commit = math.max(commit, math.min(fadeIn, p))
	return {
		fadeIn = fadeIn,
		fadeOut = params.fadeOutSeconds,
		middleDuration = middle,
		animationSpeed = params.animationSpeed,
		commitStableAfterSeconds = commit,
	}
end

--[[
	从 MotionPhase 构建 SpeedCurve、Transition、IDLE_ENTER_FADE
	@param mp table - Setting.MotionPhase（accelPhase/decelPhase/Defaults/Clips）
	@return table - SpeedCurve（ACCEL/DECEL 时长与 easing）
	@return table - Transition 按 clip 名索引的播放包
	@return number - idleEnterFade 秒数
]]
local function _buildMotionPhaseDerived(mp: any): (any, any, number)
	local accelPhase = math.max(0, _finiteNumber(mp.accelPhase, 0.28))
	local decelPhase = math.max(0, _finiteNumber(mp.decelPhase, 0.28))
	local defaults = mp.Defaults or {}
	local defaultParams = {
		visibleRatio = _finiteNumber(defaults.visibleRatio, 1),
		fadeInOfVisible = _finiteNumber(defaults.fadeInOfVisible, 0.35),
		commitRatio = _finiteNumber(defaults.commitRatio, 0.9),
		fadeOutSeconds = _finiteNumber(defaults.fadeOutSeconds, 0.15),
		animationSpeed = _finiteNumber(defaults.animationSpeed, 1),
	}

	local speedCurve = {
		ENABLE = mp.ENABLE ~= false,
		ACCEL_DURATION = accelPhase,
		DECEL_DURATION = decelPhase,
		ACCEL_EASING_STYLE = mp.accelEasingStyle or Enum.EasingStyle.Quad,
		ACCEL_EASING_DIRECTION = mp.accelEasingDirection or Enum.EasingDirection.Out,
		DECEL_EASING_STYLE = mp.decelEasingStyle or Enum.EasingStyle.Quad,
		DECEL_EASING_DIRECTION = mp.decelEasingDirection or Enum.EasingDirection.Out,
	}

	local clips = if type(mp.Clips) == "table" then mp.Clips else {}
	local transition = {}
	for clipName, kind in pairs(CLIP_PHASE_KIND) do
		local params = _resolveClipParams(defaultParams, clips[clipName])
		local phase = params.phaseSeconds
		if phase == nil then
			phase = if kind == "accel" then accelPhase else decelPhase
		end
		transition[clipName] = _deriveTransitionPack(phase, params)
	end

	local idleOf = math.clamp(_finiteNumber(mp.idleEnterOfDecel, 0.7), 0, 1)
	local idleMax = math.max(0, _finiteNumber(mp.idleEnterMaxSeconds, 0.2))
	local idleEnterFade = math.min(decelPhase * idleOf, idleMax)

	if mp.debugPrintMotionPhase == true then
		print(string.format(
			"[MotionPhase] accel=%.3f decel=%.3f idleEnterFade=%.3f",
			accelPhase,
			decelPhase,
			idleEnterFade
		))
		for _, name in ipairs({ "StartRun", "StartWalk", "StopRun", "StopWalk" }) do
			local pack = transition[name]
			if pack then
				print(string.format(
					"[MotionPhase] %s fadeIn=%.3f middle=%.3f visible=%.3f commit=%.3f fadeOut=%.3f",
					name,
					pack.fadeIn,
					pack.middleDuration,
					pack.fadeIn + pack.middleDuration,
					pack.commitStableAfterSeconds,
					pack.fadeOut
				))
			end
		end
	end

	return speedCurve, transition, idleEnterFade
end

local _speedCurve, _transition, _idleEnterFade = _buildMotionPhaseDerived(Setting.MotionPhase)

--[[
	派生只读：CharacterMoveSpeed 消费 ACCEL/DECEL；勿手改时长字段。
]]
Setting.SpeedCurve = _speedCurve

--[[
	派生只读：GroundLocomotion playTransition / commitStable 消费；时长来自 MotionPhase。
]]
Setting.Transition = _transition

--[[
	派生：无 Stop* 直切 Idle 的 crossfade；与 decelPhase 同语言。
]]
Setting.IDLE_ENTER_FADE = _idleEnterFade

-- Idle 再入跳过 Start* 的窗口与 IDLE_ENTER_FADE 对齐
if Setting.IDLE_REENTER then
	Setting.IDLE_REENTER.SKIP_START_SEC = _idleEnterFade
end

-- FOV 进出缓动与 StartRun/StopRun commit 软同相
do
	local fov = Setting.Fov
	if type(fov) == "table" then
		local enter = fov.sprintEnterSpeed
		if type(enter) ~= "number" or enter ~= enter then
			fov.sprintEnterSpeed = Setting.RUN_LOCOMOTION_WALKSPEED_THRESHOLD
		end
		local maxFov = _finiteNumber(fov.maxChangeFov, 8)
		local startCommit = Setting.Transition
			and Setting.Transition.StartRun
			and Setting.Transition.StartRun.commitStableAfterSeconds
		if type(startCommit) == "number" and startCommit == startCommit and startCommit > 1e-4 then
			fov.changeSpeed = maxFov / startCommit
		end
		local stopCommit = Setting.Transition
			and Setting.Transition.StopRun
			and Setting.Transition.StopRun.commitStableAfterSeconds
		if type(stopCommit) == "number" and stopCommit == stopCommit and stopCommit > 1e-4 then
			fov.resumeSpeed = maxFov / stopCommit
		end
	end
end

return Setting