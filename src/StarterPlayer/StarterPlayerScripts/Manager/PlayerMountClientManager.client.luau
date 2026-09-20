--[[
	Module: PlayerMountClientManager
	Description: 客户端坐骑输入与 Sync 编排（Mount.Toggle Action；路由 SystemMount）
	Author: 林奥宇
	Created: 2026-08-27
	Last Modified: 2026-08-28

	配置（GameConfig.坐骑系统.启用）：
	- false 时本 Manager 不 Init、不订 Mount.Toggle、不收 Sync
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local SystemGameConfig = Utils.SystemGameConfig

if SystemGameConfig.GetValue({ "坐骑系统", "启用" }) == false then
	return
end

local LocalPlayer = Utils.LocalPlayer
local NetWork = Utils.NetWork
local NetMsg = Utils.NetMsg
local SystemMount = Utils.SystemMount
local SystemInput = Utils.SystemInput

-- FireBindable 要求同 msgName 已 RegisterBindableEvent（NetWork 入站分发）
NetWork.RegisterBindableEvent(NetMsg.MOUNT_SESSION_CHANGED, function(_session: any, _prevState: any?)
end)

SystemMount.InitLocal()

NetWork.RegisterClientRemoteEvent(NetMsg.MOUNT_SYNC_STATE, function(payload: any)
	SystemMount.OnSyncState(payload)
end)

NetWork.RegisterClientRemoteEvent(NetMsg.MOUNT_FORCE_EXIT, function(payload: any)
	SystemMount.OnForceExit(payload)
end)

--[[
	Mount.Toggle：Active 则 Exit，否则 Enter 默认装备马
]]
SystemInput.OnAction(SystemInput.ActionIds.MountToggle, function(phase: string)
	if phase ~= SystemInput.Phase.Started then
		return
	end
	if not LocalPlayer then
		return
	end

	if SystemMount.IsLocalActive() then
		SystemMount.RequestExit()
	else
		SystemMount.RequestEnter()
	end
end)
