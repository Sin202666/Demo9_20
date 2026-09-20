--[[
	Module: MountLocomotion-Type
	Description: MountLocomotion Driver 契约类型桩（Phase 0；实现见 Phase 1+）
	Author: 林奥宇
	Created: 2026-08-27
	Last Modified: 2026-08-27
]]

local MountType = require(script.Parent["Mount-Type"])

export type MountEnterContext = {
	mountId: number,
	locomotionType: MountType.MountLocomotionTypeName,
	driveMode: MountType.MountDriveModeName?,
	cfg: MountType.MountCfgRow,
	character: Model,
	reason: MountType.MountForceExitReasonName?,
}

export type MountLocomotionDriver = {
	locomotionType: MountType.MountLocomotionTypeName,
	mountId: number,
	driveMode: MountType.MountDriveModeName?,
	enter: (self: MountLocomotionDriver, ctx: MountEnterContext) -> boolean,
	update: (self: MountLocomotionDriver, dt: number) -> (),
	exit: (self: MountLocomotionDriver, reason: MountType.MountForceExitReasonName) -> (),
	destroy: (self: MountLocomotionDriver) -> (),
	isActive: (self: MountLocomotionDriver) -> boolean,
	getFlatSpeed: (self: MountLocomotionDriver) -> number?,
}

local module = {}

return module
