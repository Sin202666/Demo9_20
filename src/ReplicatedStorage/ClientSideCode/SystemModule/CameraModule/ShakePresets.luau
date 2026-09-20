--[[
	Module: ShakePresets
	Description: CameraModule 震动类型预设表（与 EnumMgr.CameraShakeType 1-8 对齐）
	Author: 林奥宇
	Created: 2026-08-03
	Last Modified: 2026-08-31

	功能：
	- 提供冻结的 ShakeTypeConfig 表供 ShakeRuntime / CameraModule 只读查询
	- 衰减与 Attack 缺省值来自 GameConfig.CameraModule

	使用：
	local ShakePresets = require(script.Parent.ShakePresets)
	local cfg = ShakePresets.Get(shakeType)
]]

local CameraConfig = require(script.Parent.CameraConfig)

local ShakePresets = {}

export type ShakeTypeConfig = {
	name: string,
	trauma: number,
	roughness: number,
	posInfluence: Vector3,
	rotInfluence: Vector3,
	decayPerSec: number,
	attackSec: number,
}

local TRAUMA_DECAY_PER_SEC = CameraConfig.TRAUMA_DECAY_PER_SEC

-- rotInfluence ≈ 旧 Magnitude × RotationInfluence，使 trauma^2 路径峰值接近历史预设
local SHAKE_TYPE_CONFIG: { [number]: ShakeTypeConfig } = table.freeze({
	[1] = table.freeze({
		name = "Attack",
		trauma = 0.7,
		roughness = 10,
		posInfluence = Vector3.new(0.15, 0.15, 0.15),
		rotInfluence = Vector3.new(3.6, 3, 3),
		decayPerSec = TRAUMA_DECAY_PER_SEC,
		attackSec = 0.02,
	}),
	[2] = table.freeze({
		name = "Clash",
		trauma = 0.85,
		roughness = 18,
		posInfluence = Vector3.new(0.3, 0.3, 0.3),
		rotInfluence = Vector3.new(6, 6, 6),
		decayPerSec = TRAUMA_DECAY_PER_SEC,
		attackSec = 0.04,
	}),
	[3] = table.freeze({
		name = "BigClash",
		trauma = 1.0,
		roughness = 22,
		posInfluence = Vector3.new(0.5, 0.5, 0.5),
		rotInfluence = Vector3.new(10, 10, 10),
		decayPerSec = TRAUMA_DECAY_PER_SEC,
		attackSec = 0.06,
	}),
	[4] = table.freeze({
		name = "LongClash",
		trauma = 0.95,
		roughness = 20,
		posInfluence = Vector3.new(0.5, 0.5, 0.5),
		rotInfluence = Vector3.new(10, 10, 10),
		decayPerSec = TRAUMA_DECAY_PER_SEC * 0.55,
		attackSec = 0.08,
	}),
	[5] = table.freeze({
		name = "MagicHit",
		trauma = 0.7,
		roughness = 8,
		posInfluence = Vector3.new(0.35, 0, 0.35),
		rotInfluence = Vector3.new(0, 4, 0),
		decayPerSec = TRAUMA_DECAY_PER_SEC * 1.15,
		attackSec = 0.03,
	}),
	[6] = table.freeze({
		name = "Land",
		trauma = 0.75,
		roughness = 12,
		posInfluence = Vector3.new(0.1, 0.35, 0.1),
		rotInfluence = Vector3.new(4, 1.5, 1.5),
		decayPerSec = TRAUMA_DECAY_PER_SEC * 1.1,
		attackSec = 0.03,
	}),
	[7] = table.freeze({
		name = "Explosion",
		trauma = 1.0,
		roughness = 24,
		posInfluence = Vector3.new(0.55, 0.55, 0.55),
		rotInfluence = Vector3.new(11, 11, 11),
		decayPerSec = TRAUMA_DECAY_PER_SEC * 0.75,
		attackSec = 0.07,
	}),
	[8] = table.freeze({
		name = "Ambient",
		trauma = 0.45,
		roughness = 4,
		posInfluence = Vector3.new(0.12, 0.08, 0.12),
		rotInfluence = Vector3.new(1.5, 1.5, 1.5),
		decayPerSec = TRAUMA_DECAY_PER_SEC * 0.4,
		attackSec = 0.2,
	}),
})

--[[
	按类型取震动配置
	@param shakeType number - EnumMgr.CameraShakeType
	@return ShakeTypeConfig? - 对应类型的冻结配置；非法类型为 nil
]]
function ShakePresets.Get(shakeType: number): ShakeTypeConfig?
	return SHAKE_TYPE_CONFIG[shakeType]
end

--[[
	获取全部预设（只读冻结表）
	@return { [number]: ShakeTypeConfig } - 冻结的 1-8 预设表，调用方勿改写
]]
function ShakePresets.GetAll(): { [number]: ShakeTypeConfig }
	return SHAKE_TYPE_CONFIG
end

return ShakePresets
