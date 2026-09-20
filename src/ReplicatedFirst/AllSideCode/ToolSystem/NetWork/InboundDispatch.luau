--[[
	Module: InboundDispatch
	Description: NetWork 入站分发、中间件与 handler 注册表
	Author: 林奥宇
	Created: 2026-08-31
	Last Modified: 2026-09-03

	功能：
	- 五类 handler 登记（服/客 RemoteEvent、服 RemoteFunction、Bindable Event/Function）
	- 服务端 Remote 经 RequestRateLimit；限频模块未就绪则拒绝
	- 入站 msgName 须为非空 string；管道实例须与 Channel 路由一致

	由 NetWork/init 调用 BindAll / Register*；业务不要直接 require 本文件。
]]

-- ============================================================================
-- Services
-- ============================================================================

local RunService = game:GetService("RunService")

-- ============================================================================
-- Requires
-- ============================================================================

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local AllSideCode = game.ReplicatedFirst.AllSideCode
local ToolBasic = AllSideCode.ToolBasic
local NetChannel = require(ToolBasic.NetChannel)
local NetChannelMap = require(ToolBasic.NetChannelMap)
local ChannelPipes = require(script.Parent.ChannelPipes)

-- ============================================================================
-- Module definition
-- ============================================================================

local InboundDispatch = {}

-- ============================================================================
-- Types & Constants
-- ============================================================================

type PipeKind = ChannelPipes.PipeKind

local IS_SERVER = RunService:IsServer()
local IS_CLIENT = RunService:IsClient()
local IS_DEV = RunService:IsStudio()
-- 须与 RequestRateLimit 内 CHEAT_TYPE_REQUEST_PATTERN_ABNORMAL 取值一致
local CHEAT_REASON_REQUEST_PATTERN_ABNORMAL = "request_pattern_abnormal"

export type HandlerOptions = {
	skipRateLimit: boolean?,
	skipCheatDetection: boolean?,
	middlewareDataIndex: number?,
	channel: string?,
}

export type RegisterOptions = {
	channel: string?,
	-- true：覆盖已有同名 handler（角色脚本每克隆一次 Module 环境，须覆盖进程级登记）
	replace: boolean?,
}

type ServerHandlerEntry = {
	handler: (...any) -> any,
	options: HandlerOptions?,
	channelId: string,
	pipeKind: PipeKind,
}

type NamedHandlerEntry = {
	handler: (...any) -> any,
	channelId: string,
	pipeKind: PipeKind,
}

-- ============================================================================
-- Private state
-- ============================================================================

local _cachedLog: any? = nil
local _cachedRateLimit: any? = nil

local _serverRemoteEventHandlers: { [string]: ServerHandlerEntry } = {}
local _clientRemoteEventHandlers: { [string]: NamedHandlerEntry } = {}
local _serverRemoteFunctionHandlers: { [string]: ServerHandlerEntry } = {}
local _bindableEventHandlers: { [string]: NamedHandlerEntry } = {}
local _bindableFunctionHandlers: { [string]: NamedHandlerEntry } = {}

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
	延迟取 RequestRateLimit（顶层 require 会经 Log→WorldUtil 绕回本模块）
	@return any? - RequestRateLimit 模块；尚未可加载时为 nil
]]
local function _getRequestRateLimit(): any?
	if not _cachedRateLimit then
		_cachedRateLimit = Utils.RequestRateLimit
	end
	return _cachedRateLimit
end

--[[
	解析注册时 ChannelId；与 NetChannelMap 不一致则立即 error（任意环境，启动期暴露配错）
	@param msgName string - 路由键
	@param optionsChannel string? - HandlerOptions / RegisterOptions.channel；nil 表示不覆盖
	@return string - 最终 ChannelId（options > Map > Default）
]]
local function _resolveRegisterChannelId(msgName: string, optionsChannel: string?): string
	local mapChannel = NetChannelMap[msgName]
	if optionsChannel and mapChannel and optionsChannel ~= mapChannel then
		error(
			string.format(
				"[NetWork] Register channel %s 与 NetChannelMap %s 不一致: %s",
				tostring(optionsChannel),
				tostring(mapChannel),
				tostring(msgName)
			)
		)
	end
	return optionsChannel or mapChannel or NetChannel.DEFAULT
end

--[[
	开发环境未注册 msgName 时抛错，正式环境静默并打日志
	@param msgName string - 入站路由键
	@param channelLabel string - 管道标签（如 ServerRemoteEvent），仅用于日志
	@return nil
]]
local function _handleMissingHandler(msgName: string, channelLabel: string)
	local message = string.format("[NetWork] 未注册 %s: %s", channelLabel, tostring(msgName))
	if IS_DEV then
		error(message)
	end
	_logWarn(message)
end

--[[
	禁止同一 msgName 重复注册
	@param registry {[string]: any} - handler 登记表，键为 msgName
	@param msgName string - 路由键
	@param channelLabel string - 管道标签，用于 error 文案
	@return nil
]]
local function _assertUnique(registry: { [string]: any }, msgName: string, channelLabel: string)
	if registry[msgName] ~= nil then
		error(string.format("[NetWork] 重复注册 %s: %s", channelLabel, tostring(msgName)))
	end
end

--[[
	注册参数校验：非空 msgName + function handler
	@param msgName any - 调用方传入的路由键
	@param handler any - 调用方传入的处理函数
	@param channelLabel string - 管道标签，用于 error 文案
	@return nil
]]
local function _assertRegisterArgs(msgName: any, handler: any, channelLabel: string)
	if typeof(msgName) ~= "string" or msgName == "" then
		error(string.format("[NetWork] %s msgName 必须是非空 string", channelLabel))
	end
	if typeof(handler) ~= "function" then
		error(string.format("[NetWork] %s handler 必须是 function", channelLabel))
	end
end

--[[
	入站 msgName 是否为非空字符串（网络侧不可信）
	@param msgName any - Remote / Bindable 上报的首个业务参
	@return boolean - 非空 string 为 true
]]
local function _isValidMsgName(msgName: any): boolean
	return typeof(msgName) == "string" and msgName ~= ""
end

--[[
	校验入站 / 下发目标玩家是否有效且仍在数据模型中
	@param player any - 声称的 Player；可能为伪造值
	@return boolean - 是在线 Player 实例为 true
]]
local function _isValidInboundPlayer(player: any): boolean
	return typeof(player) == "Instance" and player:IsA("Player") and player.Parent ~= nil
end

--[[
	从 handler 可变参中提取给异常检测的 payload
	@param args {any} - `{...}` 打包后的业务参数数组（不含 player / msgName）
	@param options HandlerOptions? - 可指定 middlewareDataIndex；nil 时取第 1 个
	@return any - args[index]；缺省 index=1，越界为 nil
]]
local function _extractMiddlewareData(args: { any }, options: HandlerOptions?): any
	local index = 1
	if options and options.middlewareDataIndex then
		index = options.middlewareDataIndex
	end
	return args[index]
end

--[[
	服务端 Remote 入站中间件：频率限制与异常检测；限频模块未就绪则拒绝（失败关闭）
	@param player Player - 已通过在线校验的玩家
	@param msgName string - 路由键
	@param data any - 抽取出的 payload，交给 DetectDataAnomaly（可为 nil/number/table）
	@param options HandlerOptions? - 跳过开关；nil 表示两项都检查
	@return boolean - 允许继续处理为 true；应丢弃本次请求为 false
]]
local function _passServerRemoteMiddleware(player: Player, msgName: string, data: any, options: HandlerOptions?): boolean
	if options and options.skipRateLimit and options.skipCheatDetection then
		return true
	end

	local requestRateLimit = _getRequestRateLimit()
	if not requestRateLimit then
		_logWarn("[NetWork] RequestRateLimit 未就绪，拒绝入站:", msgName)
		return false
	end

	local skipCheat = options and options.skipCheatDetection
	if not skipCheat and requestRateLimit.IsCheatDetectionEnabled(msgName) then
		local dataAnomaly = requestRateLimit.DetectDataAnomaly(data)
		if dataAnomaly then
			if requestRateLimit.RecordCheatAndCheck(player, msgName, dataAnomaly) then
				return false
			end
		end

		if requestRateLimit.DetectRequestPatternAnomaly(player.UserId) then
			if requestRateLimit.RecordCheatAndCheck(player, msgName, CHEAT_REASON_REQUEST_PATTERN_ABNORMAL) then
				return false
			end
		end
	end

	if options and options.skipRateLimit then
		return true
	end

	return requestRateLimit.CheckRateLimit(player, msgName)
end

--[[
	pcall 调用 handler，不向对端泄露堆栈
	@param handler (...any) -> any - 已注册的处理函数
	@param ... any - 传给 handler 的参数（服端含 player，其余为业务 payload）
	@return boolean, ...any - pcall 语义：成功 true+返回值；失败 false+错误对象
]]
local function _safeCall(handler: (...any) -> any, ...: any): (boolean, ...any)
	return pcall(handler, ...)
end

--[[
	服务端 Remote 入站分发（Event / Function 共用）：校验 → 管道匹配 → 中间件 → handler
	@param registry {[string]: ServerHandlerEntry} - 对应管道的注册表
	@param channelLabel string - 日志用管道名
	@param inbound Instance - 实际触发的 Remote 实例
	@param player Player - Roblox 注入的发送者
	@param msgName any - 不可信路由键
	@param ... any - 业务 payload
	@return any? - RemoteFunction 成功时的 handler 返回值；失败或 Event 路径为 nil
]]
local function _dispatchServerRemote(
	registry: { [string]: ServerHandlerEntry },
	channelLabel: string,
	inbound: Instance,
	player: Player,
	msgName: any,
	...: any
): any?
	if not _isValidMsgName(msgName) or not _isValidInboundPlayer(player) then
		return nil
	end

	local entry = registry[msgName]
	if not entry then
		_handleMissingHandler(msgName, channelLabel)
		return nil
	end

	if not ChannelPipes.IsInboundMatch(entry.pipeKind, msgName, inbound) then
		return nil
	end

	local middlewareData = _extractMiddlewareData({ ... }, entry.options)
	if not _passServerRemoteMiddleware(player, msgName, middlewareData, entry.options) then
		return nil
	end

	local ok, result = _safeCall(entry.handler, player, ...)
	if not ok then
		_logWarn("[NetWork] " .. channelLabel .. " 处理失败:", msgName, result)
		return nil
	end
	return result
end

--[[
	客户端 RemoteEvent / 同端 Bindable 入站分发
	@param registry {[string]: NamedHandlerEntry} - 对应管道的注册表
	@param channelLabel string - 日志用管道名
	@param inbound Instance - 实际触发的实例
	@param msgName any - 不可信路由键
	@param ... any - 业务 payload
	@return any? - BindableFunction 成功时的返回值；其余为 nil
]]
local function _dispatchNamed(
	registry: { [string]: NamedHandlerEntry },
	channelLabel: string,
	inbound: Instance,
	msgName: any,
	...: any
): any?
	if not _isValidMsgName(msgName) then
		return nil
	end

	local entry = registry[msgName]
	if not entry then
		_handleMissingHandler(msgName, channelLabel)
		return nil
	end

	if not ChannelPipes.IsInboundMatch(entry.pipeKind, msgName, inbound) then
		return nil
	end

	local ok, result = _safeCall(entry.handler, ...)
	if not ok then
		_logWarn("[NetWork] " .. channelLabel .. " 处理失败:", msgName, result)
		return nil
	end
	return result
end

--[[
	绑定单个 RemoteEvent 的服务端入站
	@param remoteEvent RemoteEvent - 已加载的管道实例
	@return nil
]]
local function _bindServerRemoteEventInstance(remoteEvent: RemoteEvent)
	remoteEvent.OnServerEvent:Connect(function(player: Player, msgName: any, ...: any)
		_dispatchServerRemote(_serverRemoteEventHandlers, "ServerRemoteEvent", remoteEvent, player, msgName, ...)
	end)
end

--[[
	绑定单个 RemoteFunction 的服务端入站
	@param remoteFunction RemoteFunction - 已加载的管道实例
	@return nil
]]
local function _bindServerRemoteFunctionInstance(remoteFunction: RemoteFunction)
	remoteFunction.OnServerInvoke = function(player: Player, msgName: any, ...: any)
		return _dispatchServerRemote(
			_serverRemoteFunctionHandlers,
			"ServerRemoteFunction",
			remoteFunction,
			player,
			msgName,
			...
		)
	end
end

--[[
	绑定单个 RemoteEvent 的客户端入站
	@param remoteEvent RemoteEvent - 已加载的管道实例
	@return nil
]]
local function _bindClientRemoteEventInstance(remoteEvent: RemoteEvent)
	remoteEvent.OnClientEvent:Connect(function(msgName: any, ...: any)
		_dispatchNamed(_clientRemoteEventHandlers, "ClientRemoteEvent", remoteEvent, msgName, ...)
	end)
end

--[[
	绑定单个 RemoteFunction 的客户端入站（一律拒绝 S→C RemoteFunction）
	@param remoteFunction RemoteFunction - 已加载的管道实例
	@return nil
]]
local function _bindClientRemoteFunctionInstance(remoteFunction: RemoteFunction)
	remoteFunction.OnClientInvoke = function(msgName: any)
		local message = string.format(
			"[NetWork] 禁止服务端→客户端 RemoteFunction: %s（请改用 FireClient）",
			tostring(msgName)
		)
		if IS_DEV then
			error(message)
		end
		_logWarn(message)
		return nil
	end
end

--[[
	绑定单个 BindableEvent 的同端入站
	@param bindableEvent BindableEvent - 已加载的管道实例
	@return nil
]]
local function _bindBindableEventInstance(bindableEvent: BindableEvent)
	bindableEvent.Event:Connect(function(msgName: any, ...: any)
		_dispatchNamed(_bindableEventHandlers, "BindableEvent", bindableEvent, msgName, ...)
	end)
end

--[[
	绑定单个 BindableFunction 的同端入站
	@param bindableFunction BindableFunction - 已加载的管道实例
	@return nil
]]
local function _bindBindableFunctionInstance(bindableFunction: BindableFunction)
	bindableFunction.OnInvoke = function(msgName: any, ...: any)
		return _dispatchNamed(_bindableFunctionHandlers, "BindableFunction", bindableFunction, msgName, ...)
	end
end

-- ============================================================================
-- Public API
-- ============================================================================

--[[
	校验目标玩家是否有效且在线（发送路径与入站共用规则）
	@param player any - 声称的 Player
	@return boolean - 是在线 Player 实例为 true
]]
function InboundDispatch.IsValidPlayer(player: any): boolean
	return _isValidInboundPlayer(player)
end

--[[
	对已加载的全部管道实例绑定入站监听（Init 内仅调用一次）
	@return nil
]]
function InboundDispatch.BindAll()
	if IS_SERVER then
		ChannelPipes.ForEach("RemoteEvent", function(instance: Instance)
			_bindServerRemoteEventInstance(instance :: RemoteEvent)
		end)
		ChannelPipes.ForEach("RemoteFunction", function(instance: Instance)
			_bindServerRemoteFunctionInstance(instance :: RemoteFunction)
		end)
	end

	if IS_CLIENT then
		ChannelPipes.ForEach("RemoteEvent", function(instance: Instance)
			_bindClientRemoteEventInstance(instance :: RemoteEvent)
		end)
		ChannelPipes.ForEach("RemoteFunction", function(instance: Instance)
			_bindClientRemoteFunctionInstance(instance :: RemoteFunction)
		end)
	end

	ChannelPipes.ForEach("BindableEvent", function(instance: Instance)
		_bindBindableEventInstance(instance :: BindableEvent)
	end)
	ChannelPipes.ForEach("BindableFunction", function(instance: Instance)
		_bindBindableFunctionInstance(instance :: BindableFunction)
	end)
end

--[[
	注册服务端 RemoteEvent（客户端 → 服务端）
	@param msgName string - 路由键，须与 NetMsg 常量一致
	@param handler (player: Player, ...any) -> () - 入站处理；首参为 player，其余为业务 payload
	@param options HandlerOptions? - 中间件与 channel 校验；nil 表示不跳过检查、channel 走 Map
	@return nil
]]
function InboundDispatch.RegisterServerRemoteEvent(
	msgName: string,
	handler: (player: Player, ...any) -> (),
	options: HandlerOptions?
)
	_assertRegisterArgs(msgName, handler, "ServerRemoteEvent")
	local channelId = _resolveRegisterChannelId(msgName, options and options.channel)
	_assertUnique(_serverRemoteEventHandlers, msgName, "ServerRemoteEvent")
	_serverRemoteEventHandlers[msgName] = {
		handler = handler,
		options = options,
		channelId = channelId,
		pipeKind = "RemoteEvent",
	}
end

--[[
	注册客户端 RemoteEvent（服务端 → 客户端）
	@param msgName string - 路由键，须与 NetMsg 常量一致
	@param handler (...any) -> () - 入站处理；参数为业务 payload（无 player）
	@return nil
]]
function InboundDispatch.RegisterClientRemoteEvent(msgName: string, handler: (...any) -> ())
	_assertRegisterArgs(msgName, handler, "ClientRemoteEvent")
	local channelId = _resolveRegisterChannelId(msgName, nil)
	_assertUnique(_clientRemoteEventHandlers, msgName, "ClientRemoteEvent")
	_clientRemoteEventHandlers[msgName] = {
		handler = handler,
		channelId = channelId,
		pipeKind = "RemoteEvent",
	}
end

--[[
	注册服务端 RemoteFunction（客户端 → 服务端）
	@param msgName string - 路由键，须与 NetMsg 常量一致
	@param handler (player: Player, ...any) -> any - 入站处理；返回值回给 InvokeServer，任意可序列化值
	@param options HandlerOptions? - 中间件与 channel 校验；nil 表示不跳过检查、channel 走 Map
	@return nil
]]
function InboundDispatch.RegisterServerRemoteFunction(
	msgName: string,
	handler: (player: Player, ...any) -> any,
	options: HandlerOptions?
)
	_assertRegisterArgs(msgName, handler, "ServerRemoteFunction")
	local channelId = _resolveRegisterChannelId(msgName, options and options.channel)
	_assertUnique(_serverRemoteFunctionHandlers, msgName, "ServerRemoteFunction")
	_serverRemoteFunctionHandlers[msgName] = {
		handler = handler,
		options = options,
		channelId = channelId,
		pipeKind = "RemoteFunction",
	}
end

--[[
	注册同端 BindableEvent
	@param msgName string - 路由键，须与 NetMsg 常量一致
	@param handler (...any) -> () - 入站处理；参数为业务 payload
	@param registerOptions RegisterOptions? - 可选 channel 校验；replace=true 时覆盖已有同名 handler
	@return nil
]]
function InboundDispatch.RegisterBindableEvent(
	msgName: string,
	handler: (...any) -> (),
	registerOptions: RegisterOptions?
)
	_assertRegisterArgs(msgName, handler, "BindableEvent")
	local channelId = _resolveRegisterChannelId(msgName, registerOptions and registerOptions.channel)
	if not (registerOptions and registerOptions.replace == true) then
		_assertUnique(_bindableEventHandlers, msgName, "BindableEvent")
	end
	_bindableEventHandlers[msgName] = {
		handler = handler,
		channelId = channelId,
		pipeKind = "BindableEvent",
	}
end

--[[
	注册同端 BindableFunction
	@param msgName string - 路由键，须与 NetMsg 常量一致
	@param handler (...any) -> any - 入站处理；返回值回给 InvokeBindable
	@param registerOptions RegisterOptions? - 可选 channel 校验；nil 则走 Map 或 Default
	@return nil
]]
function InboundDispatch.RegisterBindableFunction(
	msgName: string,
	handler: (...any) -> any,
	registerOptions: RegisterOptions?
)
	_assertRegisterArgs(msgName, handler, "BindableFunction")
	local channelId = _resolveRegisterChannelId(msgName, registerOptions and registerOptions.channel)
	_assertUnique(_bindableFunctionHandlers, msgName, "BindableFunction")
	_bindableFunctionHandlers[msgName] = {
		handler = handler,
		channelId = channelId,
		pipeKind = "BindableFunction",
	}
end

--[[
	延迟 warn（供 init 发送路径在玩家无效时打日志）
	@param ... any - 原样转给 Log.warn 的可变参数
	@return nil
]]
function InboundDispatch.LogWarn(...: any)
	_logWarn(...)
end

return InboundDispatch
