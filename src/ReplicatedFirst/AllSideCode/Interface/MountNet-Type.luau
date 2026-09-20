--[[
	Module: MountNet-Type
	Description: MountNet 类型桩
	Author: 林奥宇
	Created: 2026-08-27
	Last Modified: 2026-08-27
]]

export type MountNetProxy = {
	FireServer: (self: MountNetProxy, ...any) -> (),
	FireClient: (self: MountNetProxy, player: Player, ...any) -> (),
	FireAllClients: (self: MountNetProxy, ...any) -> (),
}

local module: {
	ReqEnter: MountNetProxy,
	ReqExit: MountNetProxy,
	SyncState: MountNetProxy,
	ForceExit: MountNetProxy,
	FireSessionChanged: (...any) -> (),
} = {} :: any

return module
