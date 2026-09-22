--[[
	Module: PlayerAutoBattleManager
	Description: 服务端自动战斗 Remote 薄编排（路由至 SystemAutoBattle）
	Author: 程莘
	Created: 2026-09-22
	Last Modified: 2026-09-22

	配置（GameConfig.自动战斗.启用）：
	- false 时本 Manager 不 Init、不注册 Remote
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local SystemGameConfig = Utils.SystemGameConfig

if SystemGameConfig.GetValue({ "自动战斗", "启用" }) == false then
	return
end

local Log = Utils.Log
local NetWork = Utils.NetWork
local NetMsg = Utils.NetMsg
local SystemAutoBattle = Utils.SystemAutoBattle

SystemAutoBattle.Init()

NetWork.RegisterServerRemoteEvent(NetMsg.AUTO_BATTLE_REQ_START, function(player: Player)
	local ok, err = SystemAutoBattle.TryStart(player)
	if not ok then
		Log.warn("[PlayerAutoBattleManager] TryStart 失败:", player.Name, err)
	end
end)

NetWork.RegisterServerRemoteEvent(NetMsg.AUTO_BATTLE_REQ_ABORT, function(player: Player)
	local ok, err = SystemAutoBattle.TryAbort(player)
	if not ok then
		Log.warn("[PlayerAutoBattleManager] TryAbort 失败:", player.Name, err)
	end
end)
