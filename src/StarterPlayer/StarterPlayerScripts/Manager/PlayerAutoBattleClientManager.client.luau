--[[
	Module: PlayerAutoBattleClientManager
	Description: 客户端自动战斗 Sync 编排（路由 SystemAutoBattle + AutoBattleHud）
	Author: 程莘
	Created: 2026-09-22
	Last Modified: 2026-09-22

	配置（GameConfig.自动战斗.启用）：
	- false 时本 Manager 不 Init、不收 Sync
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local SystemGameConfig = Utils.SystemGameConfig

if SystemGameConfig.GetValue({ "自动战斗", "启用" }) == false then
	return
end

local NetWork = Utils.NetWork
local NetMsg = Utils.NetMsg
local ReplicatedStorage = Utils.ReplicatedStorage
local SystemAutoBattle = Utils.SystemAutoBattle

SystemAutoBattle.InitLocal()

local guiScripts = ReplicatedStorage.ClientSideCode.GuiScripts.ModuleScript
local AutoBattleHud = require(guiScripts.AutoBattleHud)
AutoBattleHud.Init()

NetWork.RegisterClientRemoteEvent(NetMsg.AUTO_BATTLE_SYNC_STATE, function(payload: any)
	SystemAutoBattle.OnSyncState(payload)
end)

NetWork.RegisterClientRemoteEvent(NetMsg.AUTO_BATTLE_BATTLE_END, function(payload: any)
	SystemAutoBattle.OnBattleEnd(payload)
end)
