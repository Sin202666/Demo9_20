--[[
	Module: AutoBattleNet
	Description: 自动战斗域通信门面（封装 NetWork，兼容 RemoteEvent FireClient/FireServer 调用形态）
	Author: 程莘
	Created: 2026-09-22
	Last Modified: 2026-09-22

	用途：
	- SystemAutoBattle / PlayerAutoBattleManager 经本模块发收，不直接依赖 Msg 下 Remote 实例
	- Manager 侧用 NetWork.Register* 注册同名 NetMsg

	加载：
		local AutoBattleNet = Utils.AutoBattleNet

	协议：
	- ReqStart() / ReqAbort()
	- SyncState(snapshot) / BattleEnd(result)
	- FireSessionChanged（同端 Bindable，供 HUD / 客户端 Scene 订阅）
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local NetWork = Utils.NetWork
local NetMsg = Utils.NetMsg

local AutoBattleNet = {}

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

AutoBattleNet.ReqStart = _proxy(NetMsg.AUTO_BATTLE_REQ_START)
AutoBattleNet.ReqAbort = _proxy(NetMsg.AUTO_BATTLE_REQ_ABORT)
AutoBattleNet.SyncState = _proxy(NetMsg.AUTO_BATTLE_SYNC_STATE)
AutoBattleNet.BattleEnd = _proxy(NetMsg.AUTO_BATTLE_BATTLE_END)

--[[
	同端 Bindable：本地 Session 变更（HUD / Scene 订阅）
	@param snapshot table? - 战斗快照；结束时可传 nil 或 phase=Ended 的结果
	@param endResult table? - BattleEnd 载荷（可选）
]]
function AutoBattleNet.FireSessionChanged(...)
	NetWork.FireBindable(NetMsg.AUTO_BATTLE_SESSION_CHANGED, ...)
end

return AutoBattleNet
