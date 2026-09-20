--[[
	Module: MountNet
	Description: 坐骑域通信门面（封装 NetWork，兼容 RemoteEvent FireClient/FireServer 调用形态）
	Author: 林奥宇
	Created: 2026-08-27
	Last Modified: 2026-08-28

	用途：
	- SystemMount / PlayerMountManager 经本模块发收，不直接依赖 Msg 下 Remote 实例
	- Manager 侧用 NetWork.Register* 注册同名 NetMsg

	加载：
		local MountNet = Utils.MountNet

	协议（Phase 0 契约，Phase 1 实现）：
	- ReqEnter(mountId) / ReqExit()
	- SyncState(sessionSnapshot, serverTime)
	- ForceExit(reason, mountId?)
	- FireSessionChanged（同端 Bindable，供 UI / 客户端 Driver 订阅）
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local NetWork = Utils.NetWork
local NetMsg = Utils.NetMsg

local MountNet = {}

--[[
	把 NetMsg 名包装成 FireServer/FireClient/FireAllClients 形态
	@param msgName string - NetMsg 键
	@return table - 兼容 RemoteEvent 调用面的代理（FireServer / FireClient / FireAllClients）
]]
local function _proxy(msgName: string)
	return {
		FireServer = function(_, ...)
			NetWork.FireServer(msgName, ...)
		end,
		FireClient = function(_, player: Player, ...)
			NetWork.FireClient(player, msgName, ...)
		end,
		FireAllClients = function(_, ...)
			NetWork.FireAllClients(msgName, ...)
		end,
	}
end

MountNet.ReqEnter = _proxy(NetMsg.MOUNT_REQ_ENTER)
MountNet.ReqExit = _proxy(NetMsg.MOUNT_REQ_EXIT)
MountNet.SyncState = _proxy(NetMsg.MOUNT_SYNC_STATE)
MountNet.ForceExit = _proxy(NetMsg.MOUNT_FORCE_EXIT)

--[[
	同端 Bindable：本地 Session 变更（UI / Client Driver 订阅）
	@param session table - MountSession 快照
	@param prevState string? - 变更前 SessionState
]]
function MountNet.FireSessionChanged(...)
	NetWork.FireBindable(NetMsg.MOUNT_SESSION_CHANGED, ...)
end

return MountNet
