--[[
	Module: Mount-Type
	Description: 坐骑域类型桩与 SystemMount API 签名（Phase 0；实现见 Phase 1）
	Author: 林奥宇
	Created: 2026-08-27
	Last Modified: 2026-09-01
]]

export type MountDriveModeName = "HumanoidHost" | "MountRoot"

export type MountLocomotionTypeName =
	"GroundMount"
	| "WheeledVehicle"
	| "FlyingCreature"
	| "Aircraft"

export type MountSessionStateName =
	"Idle"
	| "Summoning"
	| "Active"
	| "Exiting"

export type MountForceExitReasonName =
	"PlayerRequest"
	| "ZoneBan"
	| "CombatLock"
	| "SkillConflict"
	| "CharacterMotionDrive"
	| "Dialogue"
	| "Cutscene"
	| "Seated"
	| "Death"
	| "Respawn"
	| "LeaveGame"
	| "InvalidState"
	| "AntiCheat"

export type MountCombatPolicyName = "Allow" | "ForceExit" | "DenyEnter"

--[[ mountConf 行（CfgFind.GetMountCfg 深拷贝）]]
export type MountCfgRow = {
	ZhName: string?,
	LocomotionType: MountLocomotionTypeName?,
	Model: string?,
	SummonCd: number?,
	CombatPolicy: MountCombatPolicyName?,
	Icon: string?,
	xyd: number?,
	SpeedMul: number?,
	AttachName: string?,
	CameraProfile: string?,
	AnimSet: string?,
	ExtJson: string?,
	AllowedZones: { string }?,
	DeniedZones: { string }?,
	-- ExtJson / 表字段：DriveMode=HumanoidHost|MountRoot（默认 HumanoidHost）
	DriveMode: MountDriveModeName?,
	-- 亦可写在 ExtJson：ModelScale / HipHeightDelta / AttachOffset / JumpTakeoffMarker / JumpTakeoffFallbackSec
	ModelScale: number?,
	HipHeightDelta: number?,
	AttachOffset: any?,
	JumpTakeoffMarker: string?,
	JumpTakeoffFallbackSec: number?,
}

--[[ 服务端 / 客户端共享 Session 快照（MountSyncState 载荷）]]
export type MountSessionSnapshot = {
	state: MountSessionStateName,
	mountId: number?,
	locomotionType: MountLocomotionTypeName?,
	speedMul: number?,
	serverTime: number?,
	cdUntil: number?,
}

--[[ MountSyncState 完整载荷 ]]
export type MountSyncPayload = {
	session: MountSessionSnapshot,
	serverTime: number,
}

--[[ MountForceExit 载荷 ]]
export type MountForceExitPayload = {
	reason: MountForceExitReasonName,
	mountId: number?,
}

local module = {}

function module.HasMount(_player: Player, _mountId: number): boolean
	return false
end

function module.GetEquippedMountId(_player: Player): number?
	return nil
end

function module.GetSession(_player: Player): MountSessionSnapshot?
	return nil
end

function module.IsActive(_player: Player): boolean
	return false
end

function module.TryEnter(_player: Player, _mountId: number): (boolean, string?)
	return false, "NOT_IMPLEMENTED"
end

function module.TryExit(_player: Player, _reason: MountForceExitReasonName?): (boolean, string?)
	return false, "NOT_IMPLEMENTED"
end

function module.ForceExit(_player: Player, _reason: MountForceExitReasonName): ()
end

function module.SetEquipped(_player: Player, _mountId: number): (boolean, string?)
	return false, "NOT_IMPLEMENTED"
end

function module.Init(): ()
end

function module.InitLocal(): ()
end

function module.destroy(): ()
end

function module.RequestEnter(_mountId: number?): ()
end

function module.RequestExit(): ()
end

function module.GetLocalSession(): MountSessionSnapshot?
	return nil
end

function module.IsLocalActive(): boolean
	return false
end

return module
