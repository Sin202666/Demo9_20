--[[
	Module: CharacterMotion.Constants
	Description: CharacterMotion 物理令牌、电机与默认常量（Attach/LV、Attribute、扫掠）
	Author: 林奥宇
	Created: 2026-08-05
	Last Modified: 2026-08-31

	IMPULSE_ENDED_ATTR：历史名；语义为「Drive 曲线已结束」，Impulse 层仍可活跃。
	属性改名另开兼容 PR，避免 soft-merge 热更窗口断收养。

	Phase2：motionTier 源仲裁；意图路程预算；Blockcast 扫掠。
	碰撞默认 SlideAlong；合成软主导 COMPOSE_SOFT_DOMINANCE（w = tier/maxTier）。

	只读：本表 return 前 freeze。业务请走 CharacterMotion.GetConstant(name)，
	勿改写共享表。运行时诊断用 LocalPlayer Attribute CM_DebugMotion，勿改 DEBUG_PLANAR_MOTION。
]]

local Constants = {}

Constants.ATTACH_NAME = "CharacterMotionAttach"
Constants.LV_NAME = "CharacterMotionVelocity"
Constants.PHYS_GEN_ATTR = "CharacterMotionPhysGen"
-- 语义 = DriveEnded（兼容旧 Attribute 名，勿擅改）
Constants.IMPULSE_ENDED_ATTR = "ImpulseEnded"
Constants.DASH_START_CLOCK_ATTR = "MotionStartClock"
Constants.SESSION_ID_ATTR = "MotionSessionId"
Constants.COLLISION_HIT_ATTR = "MotionCollisionHit"
Constants.TRAVEL_BUDGET_ATTR = "MotionTravelBudget"
Constants.TRAVELED_ATTR = "MotionTraveled"

-- 兼容 NewRoll 旧令牌名（soft-merge 跨版本/热更窗口）
Constants.LEGACY_ATTACH_NAME = "NewRollDashAttach"
Constants.LEGACY_LV_NAME = "NewRollDashVelocity"
Constants.LEGACY_PHYS_GEN_ATTR = "NewRollPhysicsGen"

Constants.DEFAULT_MAX_FORCE = 50000
-- 平面轴力须足够大以压过贴地摩擦；50000 仍会让地面冲刺明显短于空中
Constants.DEFAULT_MAX_AXES_FORCE = math.huge
Constants.DEFAULT_CONTROL_LOCK_SOURCE = "CharacterMotion:JumpSprint"
Constants.RUBBERBAND_DEFAULT_SEC = 0.12
Constants.ENVELOPE_SLACK = 1.25
-- Drive+Impulse 合成平面速默认上限（stud/s）；nil 表示不钳
Constants.DEFAULT_COMPOSE_CAP = 200
-- 多源并存：v = vDrive*(driveTier/maxTier) + vImpulse*(impulseTier/maxTier)；false 回退裸加
Constants.COMPOSE_SOFT_DOMINANCE = true
-- recipe.tweenDuration 缺省（秒）
Constants.DEFAULT_TWEEN_DURATION = 0.4
-- soft-merge 收养：已推进超过此时长且无令牌则禁二次起冲
Constants.ADOPT_SKIP_ELAPSED_SEC = 0.05
-- 平面向量视为零的模长阈值
Constants.PLANAR_EPS = 1e-4
-- blendToWalk / 衔步：MoveDirection 视为有移向的模长阈值
Constants.MOVE_INTENT_MAG_MIN = 0.1

-- 源仲裁 tier（越高越优先；Drive 异 session：新>=旧才替换，否则拒 Begin）
Constants.MOTION_TIER_KNOCKBACK = 100
Constants.MOTION_TIER_DRIVE = 50
Constants.MOTION_TIER_IMPULSE = 40

-- 碰撞策略严格度（同 tier 取更严）
Constants.POLICY_STRICTNESS = table.freeze({
	StopOnHit = 3,
	SlideAlong = 2,
	MaxForceClip = 1,
})

-- 水平扫掠：速度*dt 之外的皮肤余量（stud）
Constants.COLLISION_PROBE_SKIN = 0.55
-- Blockcast 相对 HRP.Size 的水平/高度缩放
Constants.BLOCKCAST_XZ_SCALE = 0.9
Constants.BLOCKCAST_Y_SCALE = 0.35
Constants.BLOCKCAST_Y_MAX = 2
-- 法线 |Y| 低于此视为墙（可 Stop/Slide）；过高视为地面/天花板，忽略
Constants.WALL_NORMAL_Y_MAX = 0.72
-- 电机默认贴墙滑；MaxForceClip / StopOnHit 须 recipe 或 opts 显式指定
Constants.DEFAULT_COLLISION_POLICY = "SlideAlong"
Constants.DEFAULT_IMPULSE_COLLISION = "SlideAlong"
Constants.DEFAULT_IMPULSE_DECAY = "Linear"
Constants.DEFAULT_IMPULSE_DURATION = 0.15

-- ApplyKnockback 产品默认
Constants.DEFAULT_KNOCKBACK_DECAY = "Linear"
Constants.DEFAULT_KNOCKBACK_COLLISION = "SlideAlong"
Constants.DEFAULT_KNOCKBACK_DURATION = 0.15
Constants.DEFAULT_KNOCKBACK_AIR_MULTIPLIER = 0.85
-- 击退服包络：maxDist ≈ speed * duration * 此系数
Constants.KNOCKBACK_ENVELOPE_DIST_FACTOR = 1.25
Constants.KNOCKBACK_ENVELOPE_MIN_DIST = 8

-- Interrupt 衔步：peak = clamp(|lastPlanar| * scale, MIN, MAX)；不定死绝对值
Constants.DEFAULT_INTERRUPT_BOOST_SCALE = 0.55
Constants.INTERRUPT_BOOST_MIN = 10
Constants.INTERRUPT_BOOST_MAX = 70
Constants.DEFAULT_INTERRUPT_BOOST_COLLISION = "SlideAlong"
-- Drive 自然结束：残速 blendToWalk→WalkSpeed，避免倒 ALV
-- 有移向 / 无操作分时长；曲线用 QuadOut（前段多掉速，少滑）
Constants.DRIVE_END_BLEND_SEC = 0.30
Constants.DRIVE_END_BLEND_IDLE_SEC = 0.525
Constants.DRIVE_END_BLEND_ID = "DriveEndBlend"
-- WalkSpeed 仍为 0（锁速同帧刚放）时，blendToWalk 有移向则用 ExpectedWalkSpeed / 本兜底
Constants.BLEND_WALK_SPEED_FALLBACK = 16
Constants.EXPECTED_WALKSPEED_ATTR = "ExpectedWalkSpeed"
-- Drive/Impulse 活跃期：VelocityMotor 置 PlatformStand，抑 Humanoid 贴地刹车与 LV 抢 XZ
-- 诊断：true 或 LocalPlayer Attribute CM_DebugMotion=true → Output 打 [CM_Debug]
-- 定位地面/空中距差时先开 Attribute；本开关已 freeze，改代码无效
Constants.DEBUG_PLANAR_MOTION = false

return table.freeze(Constants)
