--[[
	Module: LogicalDisplaceProfile
	Description: 逻辑怪受击位移参数；从 PhysicsEffectName 映射（非物理语义）
	Author: 林奥宇
	Created: 2026-08-17
	Last Modified: 2026-09-01

	功能：
	- fromPhysicsName：技能 hitbox.PhysicsEffectName → distance/duration/easing
	- 对齐 RP18 常用档（含陨石「中等力度受击物理效果」）

	模块关系：
	- LogicalDisplace.tryApplyFromHitbox：命中后用本表解析参数再 apply
	- 技能 hitbox.PhysicsEffectName / hitPhysicsEffectName：须与下方 PHYSICS_NAME_MAP 键一致
	- 与 LogicalAirborneProfile 互斥分流：Hit 先查浮空表，未命中再走本表

	约束：
	- 本表只映射地面击退；不写 Store、不发 Remote
	- fromPhysicsName 返回字段拷贝，调用方改表不影响内部映射

	加载：
		local LogicalDisplaceProfile = Utils.LogicalDisplaceProfile
		local p = LogicalDisplaceProfile.fromPhysicsName("中等力度受击物理效果")
]]

local LogicalDisplaceProfile = {}

--============================================================================--
-- 类型 / 常量
--============================================================================--

export type DisplaceParams = {
	distance: number,
	duration: number,
	easingStyle: string,
	easingDirection: string,
	plane: string,
}

local PHYSICS_NAME_MAP: { [string]: DisplaceParams } = {
	["通用受击物理效果"] = {
		distance = 6.5,
		duration = 0.2,
		easingStyle = "Quad",
		easingDirection = "Out",
		plane = "xz",
	},
	["中等力度受击物理效果"] = {
		distance = 9.5,
		duration = 0.2,
		easingStyle = "Quad",
		easingDirection = "Out",
		plane = "xz",
	},
	["默认击退"] = {
		distance = 5.5,
		duration = 0.22,
		easingStyle = "Quad",
		easingDirection = "Out",
		plane = "xz",
	},
	["中等击退"] = {
		distance = 10,
		duration = 0.28,
		easingStyle = "Quad",
		easingDirection = "Out",
		plane = "xz",
	},
	["重击退"] = {
		distance = 14,
		duration = 0.32,
		easingStyle = "Quad",
		easingDirection = "Out",
		plane = "xz",
	},
}

--============================================================================--
-- 私有
--============================================================================--

--[[
	拷贝位移参数，避免外部改坏映射表
	@param src DisplaceParams - 源参数（distance/duration/easingStyle/easingDirection/plane）
	@return DisplaceParams - 新表，字段与 src 相同
]]
local function _copy(src: DisplaceParams): DisplaceParams
	return {
		distance = src.distance,
		duration = src.duration,
		easingStyle = src.easingStyle,
		easingDirection = src.easingDirection,
		plane = src.plane,
	}
end

--============================================================================--
-- 公共 API
--============================================================================--

--[[
	由技能 PhysicsEffectName 解析逻辑位移参数
	@param physicsEffectName string - hitbox.PhysicsEffectName
	@return DisplaceParams? - 有效参数拷贝；无法解析时 nil
]]
function LogicalDisplaceProfile.fromPhysicsName(physicsEffectName: string): DisplaceParams?
	if type(physicsEffectName) ~= "string" or physicsEffectName == "" then
		return nil
	end
	local mapped = PHYSICS_NAME_MAP[physicsEffectName]
	if not mapped then
		return nil
	end
	return _copy(mapped)
end

return LogicalDisplaceProfile
