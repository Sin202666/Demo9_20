--[[
	Module: NetPipeConfig
	Description: Channel → 四管道 Studio 实例名映射
	Author: LinAoyu
	Created: 2026-07-06
	Last Modified: 2026-07-06

	结构：
	  channels[channelId][pipeKind] = instanceName
	  pipeKind: "RemoteEvent" | "RemoteFunction" | "BindableEvent" | "BindableFunction"
	  某 Channel 未声明的 pipeKind → NetWork 运行时回落 Default
]]

local NetChannel = require(script.Parent.NetChannel)

local NetPipeConfig = {
	channels = {
		[NetChannel.DEFAULT] = {
			RemoteEvent = "NetWorkRemoteEvent",
			RemoteFunction = "NetWorkRemoteFunction",
			BindableEvent = "NetWorkEvent",
			BindableFunction = "NetWorkBindableFunction",
		},
		[NetChannel.SKILL] = {
			RemoteEvent = "NetWorkRemoteEvent_Skill",
			-- RemoteFunction / BindableEvent / BindableFunction 暂不配置，走 Default 回落
		},
	},
}

return NetPipeConfig
