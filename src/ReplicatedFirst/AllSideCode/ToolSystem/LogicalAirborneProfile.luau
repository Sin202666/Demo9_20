--[[
	Module: LogicalAirborneProfile
	Description: 逻辑怪浮空/击飞参数；从 PhysicsEffectName 映射（对照鬼泣5 Launch/Juggle/Slam）
	Author: 林奥宇
	Created: 2026-08-17
	Last Modified: 2026-08-28

	功能：
	- fromPhysicsName：技能 hitbox.PhysicsEffectName → kind + 浮空动力学参数
	- isAirborneEffect：是否为浮空档（供 HitResolver 分流）

	模块关系：
	- LogicalAirborne.tryApplyFromHitbox：命中后用本表解析再 applyLaunch / applyJuggle / applySlam
	- 与 LogicalDisplaceProfile 互斥：同名不会同时出现在两表；Hit 先查本表

	约束：
	- 首包不做玩家 Enemy Step；本表仅怪物侧运动语义
	- SuperHeavy 禁飞由 LogicalAirborne 读 enemy 权重，不在本表硬编码

	加载：
		local LogicalAirborneProfile = Utils.LogicalAirborneProfile
		local p = LogicalAirborneProfile.fromPhysicsName("中击飞")
]]

local LogicalAirborneProfile = {}

export type AirborneParams = {
	kind: string, -- "Launch" | "Juggle" | "Slam"
	launchVy: number,
	floatSec: number,
	juggleVy: number,
	juggleFloatAdd: number,
	gravity: number,
	floatGravityMul: number,
	maxHeight: number,
	horizontalDrift: number,
	landLockSec: number,
}

local PHYSICS_NAME_MAP: { [string]: AirborneParams } = {
	["轻上挑"] = {
		kind = "Launch",
		launchVy = 18,
		floatSec = 0.35,
		juggleVy = 5,
		juggleFloatAdd = 0.14,
		gravity = 48,
		floatGravityMul = 0.25,
		maxHeight = 12,
		horizontalDrift = 2.5,
		landLockSec = 0.15,
	},
	["中击飞"] = {
		kind = "Launch",
		launchVy = 24,
		floatSec = 0.45,
		juggleVy = 6,
		juggleFloatAdd = 0.16,
		gravity = 50,
		floatGravityMul = 0.25,
		maxHeight = 15,
		horizontalDrift = 3.5,
		landLockSec = 0.2,
	},
	["重击飞"] = {
		kind = "Launch",
		launchVy = 28,
		floatSec = 0.55,
		juggleVy = 7,
		juggleFloatAdd = 0.18,
		gravity = 52,
		floatGravityMul = 0.22,
		maxHeight = 18,
		horizontalDrift = 4.5,
		landLockSec = 0.25,
	},
	["空中连段"] = {
		kind = "Juggle",
		launchVy = 10,
		floatSec = 0.3,
		juggleVy = 6,
		juggleFloatAdd = 0.2,
		gravity = 50,
		floatGravityMul = 0.25,
		maxHeight = 15,
		horizontalDrift = 2,
		landLockSec = 0.15,
	},
	["下砸"] = {
		kind = "Slam",
		launchVy = 0,
		floatSec = 0,
		juggleVy = 0,
		juggleFloatAdd = 0,
		gravity = 90,
		floatGravityMul = 1,
		maxHeight = 18,
		horizontalDrift = 1,
		landLockSec = 0.28,
	},
}

--- 空中命中且无浮空档时的默认 Juggle（A2：地面击退档打在空中怪上仍续浮空）
local DEFAULT_JUGGLE: AirborneParams = {
	kind = "Juggle",
	launchVy = 8,
	floatSec = 0.28,
	juggleVy = 5,
	juggleFloatAdd = 0.14,
	gravity = 50,
	floatGravityMul = 0.25,
	maxHeight = 15,
	horizontalDrift = 2.5,
	landLockSec = 0.18,
}

--[[
	深拷贝参数表
	@param src AirborneParams - 源参数
	@return AirborneParams - 新表，字段与 src 相同
]]
local function _copy(src: AirborneParams): AirborneParams
	return {
		kind = src.kind,
		launchVy = src.launchVy,
		floatSec = src.floatSec,
		juggleVy = src.juggleVy,
		juggleFloatAdd = src.juggleFloatAdd,
		gravity = src.gravity,
		floatGravityMul = src.floatGravityMul,
		maxHeight = src.maxHeight,
		horizontalDrift = src.horizontalDrift,
		landLockSec = src.landLockSec,
	}
end

--[[
	由技能 PhysicsEffectName 解析浮空参数
	@param physicsEffectName string - hitbox.PhysicsEffectName
	@return AirborneParams? - 有效参数；非浮空档为 nil
]]
function LogicalAirborneProfile.fromPhysicsName(physicsEffectName: string): AirborneParams?
	if type(physicsEffectName) ~= "string" or physicsEffectName == "" then
		return nil
	end
	local mapped = PHYSICS_NAME_MAP[physicsEffectName]
	if not mapped then
		return nil
	end
	return _copy(mapped)
end

--[[
	是否为浮空/击飞/下砸档
	@param physicsEffectName string - PhysicsEffectName
	@return boolean - true 表示本表可解析为浮空参数
]]
function LogicalAirborneProfile.isAirborneEffect(physicsEffectName: string): boolean
	return LogicalAirborneProfile.fromPhysicsName(physicsEffectName) ~= nil
end

--[[
	空中默认连段参数（无浮空档名时）
	@return AirborneParams - DEFAULT_JUGGLE 的拷贝
]]
function LogicalAirborneProfile.getDefaultJuggle(): AirborneParams
	return _copy(DEFAULT_JUGGLE)
end

return LogicalAirborneProfile