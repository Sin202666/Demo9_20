--[[
	Module: AutoBattleNet-Type
	Description: AutoBattleNet 类型桩
	Author: 程莘
	Created: 2026-09-22
	Last Modified: 2026-09-22
]]

export type AutoBattleNetProxy = {
	FireServer: (self: AutoBattleNetProxy, ...any) -> (),
	FireClient: (self: AutoBattleNetProxy, player: Player, ...any) -> (),
	FireAllClients: (self: AutoBattleNetProxy, ...any) -> (),
}

local module: {
	ReqStart: AutoBattleNetProxy,
	ReqAbort: AutoBattleNetProxy,
	SyncState: AutoBattleNetProxy,
	BattleEnd: AutoBattleNetProxy,
	FireSessionChanged: (...any) -> (),
} = {} :: any

return module
