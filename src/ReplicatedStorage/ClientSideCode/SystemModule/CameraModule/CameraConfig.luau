--[[
	Module: CameraModule.CameraConfig
	Description: CameraModule 共享数值读取。从 GameConfig.CameraModule 取 number，缺省回退；供 init / ShakeRuntime / ShakePresets / CameraMode 使用，避免各文件复制取值函数。
	Author: 林奥宇
	Created: 2026-08-31
	Last Modified: 2026-08-31

	功能：
	- GetNumber(key, fallback)：读 GameConfig.CameraModule[key]，非 number 时返回 fallback
	- 预读震动 / FOV 常量，供 ShakeRuntime 与 init 直接引用（加载时快照，不热更）

	使用：
	local CameraConfig = require(script.Parent.CameraConfig)
	local fov = CameraConfig.DEFAULT_FOV
	local otsX = CameraConfig.GetNumber("OTS肩偏移X", 1.5)
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local GameConfig = Utils.GameConfig

local CameraConfig = {}

--[[
	读取 GameConfig.CameraModule 数值，缺省时回退
	@param key string - CameraModule 配置键（与 GameConfig.CameraModule 中文键一致）
	@param fallback number - 缺省值
	@return number - 配置为 number 时用配置，否则 fallback
]]
function CameraConfig.GetNumber(key: string, fallback: number): number
	local cameraConfig = GameConfig.CameraModule
	local value = cameraConfig and cameraConfig[key]
	if type(value) == "number" then
		return value
	end
	return fallback
end

local getNumber = CameraConfig.GetNumber

CameraConfig.DEFAULT_FOV = getNumber("默认视野角度", 60)
CameraConfig.FOV_EXIT_BLEND_SEC = getNumber("过场FOV过渡秒", 0.15)
CameraConfig.MAX_SHAKE_POS = getNumber("震动最大位移", 1.5)
CameraConfig.MAX_SHAKE_ROT_DEG = getNumber("震动最大转角", 8)
CameraConfig.TRAUMA_DECAY_PER_SEC = getNumber("Trauma衰减每秒", 1.2)
CameraConfig.TRAUMA_ATTACK_SEC = getNumber("Trauma上升秒", 0.05)
CameraConfig.NOISE_FREQUENCY = getNumber("噪声频率", 12)
CameraConfig.ROUGHNESS_FLOOR = getNumber("降频下限", 0.2)
CameraConfig.POS_INFLUENCE = Vector3.new(
	getNumber("位置影响X", 1),
	getNumber("位置影响Y", 1),
	getNumber("位置影响Z", 1)
)
CameraConfig.ROT_INFLUENCE = Vector3.new(
	getNumber("旋转影响X", 1),
	getNumber("旋转影响Y", 1),
	getNumber("旋转影响Z", 1)
)
CameraConfig.IMPULSE_POS_SCALE = getNumber("Impulse位移系数", 0.8)
CameraConfig.IMPULSE_ROT_SCALE = getNumber("Impulse转角系数", 4)
CameraConfig.IMPULSE_SPRING_STIFFNESS = getNumber("Impulse弹簧刚度", 180)
CameraConfig.IMPULSE_SPRING_DAMPING = getNumber("Impulse弹簧阻尼", 22)
CameraConfig.IMPULSE_SPRING_IMPULSE = getNumber("Impulse冲量系数", 12)
CameraConfig.PLAYAT_DEFAULT_MAX_DIST = getNumber("PlayAt默认最大距离", 80)
CameraConfig.PLAYAT_MIN_FULL_DIST = getNumber("PlayAt最小满幅距离", 0)
CameraConfig.PLAYAT_KICK_SCALE = getNumber("PlayAt方向Kick系数", 0.65)

return CameraConfig
