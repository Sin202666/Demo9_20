--[[
	Module: PlayerSkillManager
	Description: 服务端玩家技能启动编排（Remote 转发 SystemPlayerSkill；装备在 SystemSkill）
	Author: 林奥宇
	Created: 2026-07-29
	Last Modified: 2026-08-31

	职责：
	- 门控 GameConfig「技能系统.启用」
	- 脚本加载时同步 SystemPlayerSkill.Init（须先于 SystemSkill.Init(player)）
	- Register RELEASE_GROUP_SKILL / CLIENT_STOP_SKILL → SystemPlayerSkill
	- Register PLAYER_AIM_SAMPLE → PlayerAimSync.OnSample；PlayerAimSync.Init 清缓冲

	不：CombatWorld.Init（UpdateManager）；不持槽表；不做跨槽/坐骑/释放裁决。

	配置（GameConfig.技能系统.启用）：
	- false 时本 Manager 不注册、不运行
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local SystemGameConfig = Utils.SystemGameConfig

if SystemGameConfig.GetValue({ "技能系统", "启用" }) == false then
	return
end

local NetWork = Utils.NetWork
local NetMsg = Utils.NetMsg
local SystemPlayerSkill = Utils.SystemPlayerSkill
local PlayerAimSync = Utils.PlayerAimSync

SystemPlayerSkill.Init()
PlayerAimSync.Init()

NetWork.RegisterServerRemoteEvent(NetMsg.RELEASE_GROUP_SKILL, function(player: Player, slotIndex: number, releaseData: any)
	SystemPlayerSkill.OnRelease(player, slotIndex, releaseData)
end)

NetWork.RegisterServerRemoteEvent(NetMsg.CLIENT_STOP_SKILL, function(player: Player, skillName: string)
	SystemPlayerSkill.OnClientStop(player, skillName)
end)

NetWork.RegisterServerRemoteEvent(NetMsg.PLAYER_AIM_SAMPLE, function(player: Player, pos: any, clientTime: any?)
	PlayerAimSync.OnSample(player, pos, clientTime)
end)
