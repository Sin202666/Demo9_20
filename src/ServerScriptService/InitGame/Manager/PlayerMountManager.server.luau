--[[
	Module: PlayerMountManager
	Description: 服务端坐骑 Remote 薄编排（路由至 SystemMount）
	Author: 林奥宇
	Created: 2026-08-27
	Last Modified: 2026-08-28

	配置（GameConfig.坐骑系统.启用）：
	- false 时本 Manager 不 Init、不注册 Remote
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local SystemGameConfig = Utils.SystemGameConfig

if SystemGameConfig.GetValue({ "坐骑系统", "启用" }) == false then
	return
end

local EnumMgr = Utils.EnumMgr
local Log = Utils.Log
local NetWork = Utils.NetWork
local NetMsg = Utils.NetMsg
local SystemMount = Utils.SystemMount

SystemMount.Init()

NetWork.RegisterServerRemoteEvent(NetMsg.MOUNT_REQ_ENTER, function(player: Player, mountId: any)
	local numId = tonumber(mountId)
	if not numId then
		numId = SystemMount.GetEquippedMountId(player)
	end
	if not numId then
		return
	end
	local ok, err = SystemMount.TryEnter(player, numId)
	if not ok then
		Log.warn("[PlayerMountManager] TryEnter 失败:", player.Name, numId, err)
	end
end)

NetWork.RegisterServerRemoteEvent(NetMsg.MOUNT_REQ_EXIT, function(player: Player)
	local ok, err = SystemMount.TryExit(player, EnumMgr.MountForceExitReason.PlayerRequest)
	if not ok then
		Log.warn("[PlayerMountManager] TryExit 失败:", player.Name, err)
	end
end)
