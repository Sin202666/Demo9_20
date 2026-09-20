--[[
	状态机事件常量
	统一收口，避免字符串散写导致拼错、重命名遗漏
]]
local SkillEventConst = {
	-- 状态机转换事件
	StateTimeout = "StateTimeout",
	Timeout = "Timeout",
	Interrupt = "Interrupt",
	ForceFinish = "ForceFinish",
	EnemyHit = "EnemyHit",
	ObstacleHit = "ObstacleHit",
	-- 持续按住类技能：技能键松开（由 GroupSkill Runtime 与服务端 Tick 投递）
	SkillButtonRelease = "SkillButtonRelease",
	-- Main/Channel 等引导态：玩家跳跃打断（Humanoid→Jumping，键鼠/手柄/触屏统一）
	JumpCancel = "JumpCancel",
	-- 魔法格挡等：服务端在完美防御判定时驱动，经 SkillSync 同步至客户端与观战
	PerfectBlock = "PerfectBlock",
}

-- 同步事件类型（供 SkillSyncEventFactory 与客户端 eventType 判断）
SkillEventConst.SyncEventType = {
	ProjectileHitConfirmed = "ProjectileHitConfirmed",
	BaseSkillStarted = "BaseSkillStarted",
	BaseSkillDerived = "BaseSkillDerived",
	-- 基础技能状态机事件同步（如 MagicBlock1 完美防御 -> BackSwing）
	BaseSkillStateTransition = "BaseSkillStateTransition",
	HitConfirmed = "HitConfirmed", -- 兼容旧协议
	-- 独角兽之怒等：近身追加落雷波次（服务端检测落点 → 客户端播预警/落雷）
	ProximityStrikeWave = "ProximityStrikeWave",
	-- 太阳耀斑：逐颗陨石落点（服务端开飞时裁决 → 客户端表现对齐 Hitbox）
	SolarFlareMeteorShot = "SolarFlareMeteorShot",
	-- 火枪等直线弹道：服务端 buildShootPath 后广播，客户端子弹与 Hitbox 共用
	ProjectilePathConfirmed = "ProjectilePathConfirmed",
}

-- 命中类型（ProjectileHitConfirmed.hitType）
SkillEventConst.HitType = {
	Enemy = "Enemy",
	Obstacle = "Obstacle",
	Timeout = "Timeout",
}

return SkillEventConst
