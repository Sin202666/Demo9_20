--[[
	Module: CharacterMotion.Types
	Description: CharacterMotion 电机配方、Drive/Impulse 写入与 Begin/Interrupt 选项类型
	Author: 林奥宇
	Created: 2026-08-05
	Last Modified: 2026-08-31

	与兄弟模块：
	- init.luau 对外 API 的 opts 形状以此为准（BeginOpts / ImpulseOpts / KnockbackOpts）
	- VelocityMotor / Recipes 运行时字段应对齐本文件 export type
	- 仅类型导出，无运行时逻辑；require 后得到空表
	- 运行时 opts 以 init.luau 校验为准；本文件供分析器与注释对照

	加载：
		-- 一般经 CharacterMotion 使用，无需单独 require Types
		local Types = require(script.Parent.Types)
]]

export type VerticalMode = "PreserveY"

export type CollisionPolicy = "MaxForceClip" | "StopOnHit" | "SlideAlong"

export type ImpulseDecay = "Linear" | "QuadOut" | "QuadIn"

-- 可编速度包络关键帧：t∈[0,1] 归一化时间，factor 乘 |planeSpeed|
export type SpeedKey = {
	t: number,
	factor: number,
}

export type PlanarRecipe = {
	planeSpeed: number,
	tweenDuration: number,
	vectorEndFactor: number,
	maxDistance: number,
	verticalMode: VerticalMode?,
	collisionPolicy: CollisionPolicy?,
	maxForce: number?,
	clearImpulsesOnBegin: boolean?,
	-- true 时客户端按 maxDistance 硬截断 Drive；NewRoll 默认 false（仅服包络用 maxDistance）
	enforceMaxDistance: boolean?,
	-- Drive+Impulse 合成平面速上限；缺省用 Constants.DEFAULT_COMPOSE_CAP
	composeCap: number?,
	-- Drive 曲线缓动；缺省 Quad / Out（与历史行为一致）
	easingStyle: Enum.EasingStyle?,
	easingDirection: Enum.EasingDirection?,
	-- 有 keys 时按分段线性求 factor*planeSpeed*dir；无则 start→goal Lerp
	speedKeys: { SpeedKey }?,
}

export type BeginOpts = {
	sessionId: string,
	recipe: PlanarRecipe,
	directionWorld: Vector3,
	controlMask: { Jump: boolean?, Sprint: boolean?, Move: boolean? }?,
	controlLockSource: string?,
	adoptIfPresent: boolean?,
	elapsedSec: number?,
	faceDirection: Vector3?,
	-- Drive 源仲裁 tier；缺省 Constants.MOTION_TIER_DRIVE
	motionTier: number?,
}

export type EndOpts = {
	preservePhysicsToken: boolean?,
	releaseControlLock: boolean?,
	-- soft-merge 预测交接：只摘 Session/锁，勿 EndDriveKeepMarker（否则 Adopt 见 IMPULSE_ENDED 失败）
	keepDriveActive: boolean?,
}

export type InterruptOpts = {
	earlyEndBoostDuration: number?,
	-- >0 时绝对覆写峰值；未设或 <=0 则按 |lastPlanar| * scale 推导
	earlyEndBoostPeakSpeed: number?,
	earlyEndBoostScale: number?,
	earlyEndBoostMin: number?,
	earlyEndBoostMax: number?,
	earlyEndBoostEasingStyle: Enum.EasingStyle?,
	earlyEndBoostEasingDirection: Enum.EasingDirection?,
	-- true：只拆 Drive 并返回 peak，由调用方在 ForceCleanup 后再 AddImpulse
	deferImpulse: boolean?,
}

export type ImpulseOpts = {
	id: string,
	planarVelocity: Vector3?,
	direction: Vector3?,
	speed: number?,
	durationSec: number?,
	decay: ImpulseDecay?,
	maxSpeed: number?,
	maxDistance: number?,
	massScale: number?,
	collisionPolicy: CollisionPolicy?,
	followMoveDirection: boolean?,
	peakSpeed: number?,
	composeCap: number?,
	-- 源仲裁 tier；缺省 Constants.MOTION_TIER_IMPULSE
	motionTier: number?,
}

-- ApplyKnockback 专用：在 ImpulseOpts 上叠加击退默认与 Drive 策略
export type KnockbackOpts = {
	id: string,
	planarVelocity: Vector3?,
	direction: Vector3?,
	speed: number?,
	durationSec: number?,
	decay: ImpulseDecay?,
	maxSpeed: number?,
	maxDistance: number?,
	massScale: number?,
	collisionPolicy: CollisionPolicy?,
	composeCap: number?,
	-- 空中（Jumping/Freefall）时 speed/planar 倍率；默认 1
	airMultiplier: number?,
	-- true：先拆当前 Drive Session 再施加击退；默认 false（与 Drive 叠加）
	interruptDrive: boolean?,
	-- 源仲裁 tier；缺省 Constants.MOTION_TIER_KNOCKBACK
	motionTier: number?,
}

export type SessionInfo = {
	sessionId: string,
	character: Model,
	attach: Attachment?,
	-- @deprecated 历史误导名；与 driveActive 同值，请用 driveActive
	impulseActive: boolean,
	driveActive: boolean,
	controlLockHeld: boolean,
	impulseCount: number,
	driveTier: number?,
	maxImpulseTier: number?,
}

return {}
