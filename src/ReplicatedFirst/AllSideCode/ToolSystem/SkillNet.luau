--[[
	Module: SkillNet
	Description: 技能域通信门面（封装 NetWork，兼容原 RemoteEvent FireClient/FireServer 调用形态）
	Author: 林奥宇
	Created: 2026-07-29
	Last Modified: 2026-08-28

	用途：
	- SkillSyncRouter / GroupSkill* 通过本模块发收，不直接依赖 Msg 下独立 Remote 实例
	- Manager 侧用 NetWork.Register* 注册同名 NetMsg

	加载：
		local SkillNet = Utils.SkillNet
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local NetWork = Utils.NetWork
local NetMsg = Utils.NetMsg

local SkillNet = {}

--[[
	按 NetMsg 键生成 FireServer / FireClient / FireAllClients 代理表。
	@param msgName string - NetMsg 通道名（如 RELEASE_GROUP_SKILL）
	@return table - 含 FireServer/FireClient/FireAllClients；不 Connect Remote
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

SkillNet.ReleaseGroupSkill = _proxy(NetMsg.RELEASE_GROUP_SKILL)
SkillNet.ClientStopSkill = _proxy(NetMsg.CLIENT_STOP_SKILL)
SkillNet.FixSkillTime = _proxy(NetMsg.FIX_SKILL_TIME)
SkillNet.StopSkill = _proxy(NetMsg.STOP_SKILL)
SkillNet.SynSkillEffect = _proxy(NetMsg.SYN_SKILL_EFFECT)
SkillNet.SynPlayerCFrame = _proxy(NetMsg.SYN_PLAYER_CFRAME)
SkillNet.DamageTip = _proxy(NetMsg.DAMAGE_TIP)
SkillNet.ElementAttachTip = _proxy(NetMsg.ELEMENT_ATTACH_TIP)
SkillNet.PlayerAimSample = _proxy(NetMsg.PLAYER_AIM_SAMPLE)

--[[
	同端 Bindable：绑定组技能
	@param ... any - 与 NetMsg.BIND_GROUP_SKILL 一致：player、skillName、slotIndex、可选 power/purity/magic、skillID、mpTp
]]
function SkillNet.FireBindGroupSkill(...)
	NetWork.FireBindable(NetMsg.BIND_GROUP_SKILL, ...)
end

--[[
	同端 Bindable：解绑组技能
	@param ... any - 与 NetMsg.UNBIND_GROUP_SKILL 一致：player、slotIndex
]]
function SkillNet.FireUnbindGroupSkill(...)
	NetWork.FireBindable(NetMsg.UNBIND_GROUP_SKILL, ...)
end

return SkillNet
