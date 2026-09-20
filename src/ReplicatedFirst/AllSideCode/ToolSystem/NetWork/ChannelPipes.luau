--[[
	Module: ChannelPipes
	Description: NetWork 管道实例加载与 Channel 路由（不含 handler 分发）
	Author: 林奥宇
	Created: 2026-08-31
	Last Modified: 2026-08-31

	功能：
	- 按 NetPipeConfig 加载 Msg 下四管道实例；Default 必须存在
	- msgName → ChannelId → 实例；稀疏配置回落 Default
	- 供 init 发送路径与 InboundDispatch 入站实例比对使用

	由 NetWork/init 调用 LoadAll；业务不要直接 require 本文件。
]]

-- ============================================================================
-- Services
-- ============================================================================

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- ============================================================================
-- Requires
-- ============================================================================

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local AllSideCode = game.ReplicatedFirst.AllSideCode
local ToolBasic = AllSideCode.ToolBasic
local NetChannel = require(ToolBasic.NetChannel)
local NetPipeConfig = require(ToolBasic.NetPipeConfig)
local NetChannelMap = require(ToolBasic.NetChannelMap)

-- ============================================================================
-- Module definition
-- ============================================================================

local ChannelPipes = {}

-- ============================================================================
-- Types & Constants
-- ============================================================================

export type PipeKind = "RemoteEvent" | "RemoteFunction" | "BindableEvent" | "BindableFunction"

local PIPE_KIND_TO_MSG_FOLDER: { [PipeKind]: string } = {
	RemoteEvent = "RemoteEvent",
	RemoteFunction = "RemoteFunction",
	BindableEvent = "Event",
	BindableFunction = "Function",
}

local ALL_PIPE_KINDS: { PipeKind } = {
	"RemoteEvent",
	"RemoteFunction",
	"BindableEvent",
	"BindableFunction",
}

local MSG_FOLDER_NAME = "Msg"
local PIPE_WAIT_TIMEOUT_SEC = 15
local IS_DEV = RunService:IsStudio()

-- ============================================================================
-- Private state
-- ============================================================================

local _cachedLog: any? = nil
local _pipeInstances: { [PipeKind]: { [string]: Instance } } = {
	RemoteEvent = {},
	RemoteFunction = {},
	BindableEvent = {},
	BindableFunction = {},
}

-- ============================================================================
-- Private helpers
-- ============================================================================

--[[
	统一 warn；Log 未就绪时静默（延迟加载，避免 Log→WorldUtil→NetWork 循环）
	@param ... any - 原样转给 Log.warn 的可变参数（字符串/数字/Instance 等可打印值）
	@return nil
]]
local function _logWarn(...: any)
	if not _cachedLog then
		_cachedLog = Utils.Log
	end
	if _cachedLog then
		_cachedLog.warn(...)
	end
end

--[[
	获取 Msg 子目录下必须存在的通信实例（Default 通道）；超时则 error
	@param subFolderName string - Msg 子目录名（RemoteEvent / RemoteFunction / Event / Function）
	@param instanceName string - Studio 实例名（来自 NetPipeConfig）
	@return Instance - 已存在的通信实例
]]
local function _getMsgInstance(subFolderName: string, instanceName: string): Instance
	local msgFolder = ReplicatedStorage:WaitForChild(MSG_FOLDER_NAME, PIPE_WAIT_TIMEOUT_SEC)
	if not msgFolder then
		error(string.format("[NetWork] 等待 Msg 目录超时: %s", MSG_FOLDER_NAME))
	end
	local subFolder = msgFolder:WaitForChild(subFolderName, PIPE_WAIT_TIMEOUT_SEC)
	if not subFolder then
		error(string.format("[NetWork] 等待 Msg 子目录超时: %s", subFolderName))
	end
	local instance = subFolder:WaitForChild(instanceName, PIPE_WAIT_TIMEOUT_SEC)
	if not instance then
		error(string.format("[NetWork] 等待管道实例超时: %s / %s", subFolderName, instanceName))
	end
	return instance
end

--[[
	尝试获取 Msg 子目录下的可选 Channel 实例（缺失不抛错）
	@param subFolderName string - Msg 子目录名
	@param instanceName string - Studio 实例名
	@return Instance? - 找到则返回实例；目录或实例不存在为 nil
]]
local function _tryGetMsgInstance(subFolderName: string, instanceName: string): Instance?
	local msgFolder = ReplicatedStorage:FindFirstChild(MSG_FOLDER_NAME)
	if not msgFolder then
		return nil
	end
	local subFolder = msgFolder:FindFirstChild(subFolderName)
	if not subFolder then
		return nil
	end
	return subFolder:FindFirstChild(instanceName)
end

--[[
	按 msgName 解析 ChannelId（发送与入站路由的唯一来源）
	@param msgName string - 路由键，须与 NetMsg 常量一致
	@return string - ChannelId；未配置则为 NetChannel.DEFAULT
]]
local function _resolveChannelId(msgName: string): string
	return NetChannelMap[msgName] or NetChannel.DEFAULT
end

--[[
	查 Channel 在某管道上的 Studio 实例名；未配置则查 Default
	@param pipeKind PipeKind - 管道类型
	@param channelId string - ChannelId
	@return string? - 实例名；Default 也未配置时为 nil
]]
local function _getInstanceNameForChannel(pipeKind: PipeKind, channelId: string): string?
	local channelConfig = NetPipeConfig.channels[channelId]
	if channelConfig and channelConfig[pipeKind] then
		return channelConfig[pipeKind]
	end
	local defaultConfig = NetPipeConfig.channels[NetChannel.DEFAULT]
	if defaultConfig then
		return defaultConfig[pipeKind]
	end
	return nil
end

--[[
	配置层有效 Channel：该管道未声明时回落 Default
	@param pipeKind PipeKind - 管道类型（由 API 决定，不由 Map 决定）
	@param msgName string - 路由键
	@param warnIfFallback boolean - Studio 下回落时是否打日志（发送路径 true，入站比对 false）
	@return string - 实际使用的 ChannelId
]]
local function _getEffectiveChannelId(pipeKind: PipeKind, msgName: string, warnIfFallback: boolean): string
	local mapChannelId = _resolveChannelId(msgName)
	local channelConfig = NetPipeConfig.channels[mapChannelId]
	if channelConfig and channelConfig[pipeKind] then
		return mapChannelId
	end
	if warnIfFallback and mapChannelId ~= NetChannel.DEFAULT and IS_DEV then
		_logWarn(
			string.format("[NetWork] Channel %s 未配置 %s，回落 Default", tostring(mapChannelId), pipeKind)
		)
	end
	return NetChannel.DEFAULT
end

--[[
	已加载表中取管道实例；指定 Channel 缺失时回落 Default 实例
	@param pipeKind PipeKind - 管道类型
	@param channelId string - ChannelId
	@return Instance? - 实例；Default 也未加载时为 nil
]]
local function _getPipeInstanceByChannel(pipeKind: PipeKind, channelId: string): Instance?
	local instance = _pipeInstances[pipeKind][channelId]
	if not instance and channelId ~= NetChannel.DEFAULT then
		instance = _pipeInstances[pipeKind][NetChannel.DEFAULT]
	end
	return instance
end

-- ============================================================================
-- Public API
-- ============================================================================

--[[
	按管道类型与 msgName 解析目标通信实例；缺失则 error
	@param pipeKind PipeKind - 管道类型
	@param msgName string - 路由键
	@return Instance - 目标实例
]]
function ChannelPipes.Resolve(pipeKind: PipeKind, msgName: string): Instance
	local effectiveChannelId = _getEffectiveChannelId(pipeKind, msgName, true)
	local instance = _getPipeInstanceByChannel(pipeKind, effectiveChannelId)
	if not instance then
		error(
			string.format(
				"[NetWork] 管道实例未加载: %s / %s (%s)",
				pipeKind,
				tostring(effectiveChannelId),
				tostring(_getInstanceNameForChannel(pipeKind, effectiveChannelId))
			)
		)
	end
	return instance
end

--[[
	入站实例是否与 msgName 路由目标一致（防止跨 Channel 管道注入）
	@param pipeKind PipeKind - 该 handler 所属管道
	@param msgName string - 路由键
	@param inbound Instance - 实际触发监听的实例
	@return boolean - 一致为 true
]]
function ChannelPipes.IsInboundMatch(pipeKind: PipeKind, msgName: string, inbound: Instance): boolean
	local expected = _getPipeInstanceByChannel(pipeKind, _getEffectiveChannelId(pipeKind, msgName, false))
	return expected ~= nil and inbound == expected
end

--[[
	遍历某管道已加载的全部实例（Init 绑定时用）
	@param pipeKind PipeKind - 管道类型
	@param callback (Instance) -> () - 对每个实例调用一次
	@return nil
]]
function ChannelPipes.ForEach(pipeKind: PipeKind, callback: (Instance) -> ())
	for _, instance in _pipeInstances[pipeKind] do
		callback(instance)
	end
end

--[[
	加载 NetPipeConfig 声明的全部管道实例；Default 四实例必须存在
	@return nil
]]
function ChannelPipes.LoadAll()
	for channelId, channelPipes in NetPipeConfig.channels do
		for pipeKind, instanceName in channelPipes do
			local subFolder = PIPE_KIND_TO_MSG_FOLDER[pipeKind :: PipeKind]
			local instance: Instance?

			if channelId == NetChannel.DEFAULT then
				instance = _getMsgInstance(subFolder, instanceName)
			else
				instance = _tryGetMsgInstance(subFolder, instanceName)
				if not instance and IS_DEV then
					_logWarn(
						string.format(
							"[NetWork] Channel %s %s 实例缺失（可选）: %s",
							tostring(channelId),
							pipeKind,
							instanceName
						)
					)
				end
			end

			if instance then
				_pipeInstances[pipeKind :: PipeKind][channelId] = instance
			end
		end
	end

	for _, pipeKind in ALL_PIPE_KINDS do
		if not _pipeInstances[pipeKind][NetChannel.DEFAULT] then
			error(
				string.format(
					"[NetWork] Default 通道 %s 实例缺失: %s",
					pipeKind,
					tostring(_getInstanceNameForChannel(pipeKind, NetChannel.DEFAULT))
				)
			)
		end
	end
end

return ChannelPipes
