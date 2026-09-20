--[[
	Module: NetChannelMap
	Description: msgName → ChannelId 映射；未配置的 msgName 自动走 Default
	Author: LinAoyu
	Created: 2026-07-06
	Last Modified: 2026-07-06

	新增 msgName 时须同步维护本表（Review 检查项）
]]

local NetChannel = require(script.Parent.NetChannel)
local NetMsg = require(script.Parent.NetMsg)

local NetChannelMap: { [string]: string } = {
	[NetMsg.RELEASE_GROUP_SKILL] = NetChannel.SKILL,
	[NetMsg.CLIENT_STOP_SKILL] = NetChannel.SKILL,
	[NetMsg.FIX_SKILL_TIME] = NetChannel.SKILL,
	[NetMsg.STOP_SKILL] = NetChannel.SKILL,
	[NetMsg.SYN_SKILL_EFFECT] = NetChannel.SKILL,
	[NetMsg.SYN_PLAYER_CFRAME] = NetChannel.SKILL,
	[NetMsg.DAMAGE_TIP] = NetChannel.SKILL,
	[NetMsg.ELEMENT_ATTACH_TIP] = NetChannel.SKILL,
	[NetMsg.PLAYER_AIM_SAMPLE] = NetChannel.SKILL,
	[NetMsg.SKILL_HIT_PRESENTATION] = NetChannel.SKILL,
	[NetMsg.NPC_COSMETIC_HIT] = NetChannel.SKILL,
	[NetMsg.BAG_LOCK_ITEMS] = NetChannel.DEFAULT,
	[NetMsg.BACKPACK_TOOLBAR_DRAG] = NetChannel.DEFAULT,
}

return NetChannelMap
