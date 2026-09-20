--[[
	Module: NetWork
	Description: 统一游戏通信路由——四管道 × 多 Channel 架构
	Author: 林奥宇
	Created: 2026-07-01
	Last Modified: 2026-09-03

	功能：
	- 入站分发：RemoteEvent / RemoteFunction / BindableEvent / BindableFunction
	- 按 msgName 解析 Channel，稀疏配置回落 Default
	- 服务端 Remote 入站经 RequestRateLimit（频率 + 异常检测）
	- 双端门面 FireLocalOrClient / FireClientIfServer，避免业务模块 IsServer 分支

	------------------------------------------------------------------------
	与相关模块的关系
	------------------------------------------------------------------------
	NetWork           — 本模块（init）：发送门面、Init 编排、对外 Register
	ChannelPipes      — 同目录：管道实例加载与 Channel 路由
	InboundDispatch   — 同目录：入站分发、中间件、handler 登记表
	NetWorkManager    — 仅调用 Init()；服端先 RequestRateLimit.Init 再本模块 Init
	NetMsg            — msgName 常量；业务用 Utils.NetMsg
	NetChannel        — ChannelId 常量（Default / Skill 等）
	NetPipeConfig     — Channel → 四管道 Studio 实例名
	NetChannelMap     — msgName → ChannelId；未声明走 Default
	RequestRateLimit  — 服端入站中间件；HandlerOptions 可跳过限频或异常检测
	业务 System       — 在 RegisterNetWork() 里注册 handler，自行做玩家/数据/业务校验

	------------------------------------------------------------------------
	管道与参数约定
	------------------------------------------------------------------------
	- 四管道：RemoteEvent / RemoteFunction / BindableEvent / BindableFunction
	- 跨端 payload 首参为 msgName；服端 Remote 由 Roblox 注入 player 作为首参
	- 某 Channel 未配置某管道时回落 Default 对应实例
	- 禁止服务端 → 客户端 RemoteFunction（OnClientInvoke 一律拒绝）
	- IS_SERVER / IS_CLIENT 仅用于管道绑定与发送门控，不承载业务结算

	HandlerOptions（RegisterServerRemoteEvent / RegisterServerRemoteFunction 第三参，均为可选）：
		skipRateLimit        boolean? — true 跳过 CheckRateLimit；默认 false
		skipCheatDetection   boolean? — true 跳过异常检测；默认 false
		middlewareDataIndex  number?  — 从 handler 的 ... 取第几个参数给中间件（1 起）；默认 1
		channel              string?  — 须与 NetChannelMap[msgName] 一致；省略则走 Map 或 Default
		                              与 Map 不一致时任意环境 error（启动期配置错误）

	RegisterOptions（Bindable 注册第三参）：
		channel string? — 含义同上，仅校验不改发送路由
		replace boolean? — true 覆盖已有同名 handler；角色克隆脚本重注册必须带，否则 error 重复注册

	------------------------------------------------------------------------
	发送约束
	------------------------------------------------------------------------
	- 服务端 → 客户端：仅 FireClient / FireAllClients / FireClientIfServer
	- 客户端 → 服务端：FireServer / InvokeServer
	- 同端解耦：FireBindable / InvokeBindable（不跨网络）
	- FireLocalOrClient：客户端 Bindable，服务端 FireClient

	------------------------------------------------------------------------
	加载方式
	------------------------------------------------------------------------
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local NetWork = Utils.NetWork
		local NetMsg = Utils.NetMsg

	------------------------------------------------------------------------
	使用示例
	------------------------------------------------------------------------
	-- 业务模块 RegisterNetWork（由各 System 自己调用，不要在本模块 Init 里注册业务）
	NetWork.RegisterServerRemoteEvent(NetMsg.SOME_MSG, function(player, payload)
		-- 玩家 / 数据 / 业务校验后结算
	end)

	-- 客户端发送
	NetWork.FireServer(NetMsg.SOME_MSG, payload)

	-- 服务端下发；双端共用提示走 FireLocalOrClient，避免业务 IsServer 分支
	NetWork.FireClient(player, NetMsg.SOME_MSG, payload)
	NetWork.FireLocalOrClient(player, NetMsg.SOME_MSG, payload)
]]

-- ============================================================================
-- Services
-- ============================================================================

local RunService = game:GetService("RunService")

-- ============================================================================
-- Requires
-- ============================================================================

local ChannelPipes = require(script.ChannelPipes)
local InboundDispatch = require(script.InboundDispatch)

-- ============================================================================
-- Module definition
-- ============================================================================

local NetWork = {}

-- ============================================================================
-- Types & Constants
-- ============================================================================

export type HandlerOptions = InboundDispatch.HandlerOptions
export type RegisterOptions = InboundDispatch.RegisterOptions

local IS_SERVER = RunService:IsServer()
local IS_CLIENT = RunService:IsClient()

-- ============================================================================
-- Private state
-- ============================================================================

local _initialized = false

-- ============================================================================
-- Private helpers
-- ============================================================================

--[[
	懒初始化（Fire/Invoke 在 Manager.Init 前调用时补齐管道，不重复绑定）
	@return nil
]]
local function _ensureInitialized()
	if _initialized then
		return
	end
	NetWork.Init()
end

--[[
	发送 API 端侧门控
	@param allowed boolean - 当前端是否允许调用
	@param apiName string - API 名，用于 error 文案
	@param sideLabel string - 「客户端」或「服务端」
	@return nil
]]
local function _assertSide(allowed: boolean, apiName: string, sideLabel: string)
	if not allowed then
		error("[NetWork] " .. apiName .. " 仅" .. sideLabel .. "可用")
	end
end

-- ============================================================================
-- Public API — 注册
-- ============================================================================

--[[
	注册服务端 RemoteEvent（客户端 → 服务端）
	@param msgName string - 路由键，须与 NetMsg 常量一致
	@param handler (player: Player, ...any) -> () - 入站处理；首参为 player，其余为业务 payload
	@param options HandlerOptions? - 中间件与 channel 校验；nil 表示不跳过检查、channel 走 Map
	@return nil
]]
function NetWork.RegisterServerRemoteEvent(
	msgName: string,
	handler: (player: Player, ...any) -> (),
	options: HandlerOptions?
)
	InboundDispatch.RegisterServerRemoteEvent(msgName, handler, options)
end

--[[
	注册客户端 RemoteEvent（服务端 → 客户端）
	@param msgName string - 路由键，须与 NetMsg 常量一致
	@param handler (...any) -> () - 入站处理；参数为业务 payload（无 player）
	@return nil
]]
function NetWork.RegisterClientRemoteEvent(msgName: string, handler: (...any) -> ())
	InboundDispatch.RegisterClientRemoteEvent(msgName, handler)
end

--[[
	注册服务端 RemoteFunction（客户端 → 服务端）
	@param msgName string - 路由键，须与 NetMsg 常量一致
	@param handler (player: Player, ...any) -> any - 入站处理；返回值回给 InvokeServer，任意可序列化值
	@param options HandlerOptions? - 中间件与 channel 校验；nil 表示不跳过检查、channel 走 Map
	@return nil
]]
function NetWork.RegisterServerRemoteFunction(
	msgName: string,
	handler: (player: Player, ...any) -> any,
	options: HandlerOptions?
)
	InboundDispatch.RegisterServerRemoteFunction(msgName, handler, options)
end

--[[
	注册同端 BindableEvent
	@param msgName string - 路由键，须与 NetMsg 常量一致
	@param handler (...any) -> () - 入站处理；参数为业务 payload
	@param registerOptions RegisterOptions? - 可选 channel 校验；replace=true 覆盖已有同名 handler
	@return nil
]]
function NetWork.RegisterBindableEvent(
	msgName: string,
	handler: (...any) -> (),
	registerOptions: RegisterOptions?
)
	InboundDispatch.RegisterBindableEvent(msgName, handler, registerOptions)
end

--[[
	注册同端 BindableFunction
	@param msgName string - 路由键，须与 NetMsg 常量一致
	@param handler (...any) -> any - 入站处理；返回值回给 InvokeBindable
	@param registerOptions RegisterOptions? - 可选 channel 校验；nil 则走 Map 或 Default
	@return nil
]]
function NetWork.RegisterBindableFunction(
	msgName: string,
	handler: (...any) -> any,
	registerOptions: RegisterOptions?
)
	InboundDispatch.RegisterBindableFunction(msgName, handler, registerOptions)
end

-- ============================================================================
-- Public API — 发送
-- ============================================================================

--[[
	客户端向服务端发送 RemoteEvent
	@param msgName string - 路由键
	@param ... any - 业务 payload，由对应 handler 解析；本模块不读内容
	@return nil
]]
function NetWork.FireServer(msgName: string, ...)
	_assertSide(IS_CLIENT, "FireServer", "客户端")
	_ensureInitialized()
	local remoteEvent = ChannelPipes.Resolve("RemoteEvent", msgName) :: RemoteEvent
	remoteEvent:FireServer(msgName, ...)
end

--[[
	服务端向指定客户端发送 RemoteEvent；目标无效时打日志并跳过（不抛错）
	@param player Player - 目标玩家，须在线（Parent ~= nil）
	@param msgName string - 路由键
	@param ... any - 业务 payload，由对应 handler 解析
	@return nil
]]
function NetWork.FireClient(player: Player, msgName: string, ...)
	_assertSide(IS_SERVER, "FireClient", "服务端")
	if not InboundDispatch.IsValidPlayer(player) then
		InboundDispatch.LogWarn("[NetWork] FireClient 目标玩家无效:", msgName)
		return
	end
	_ensureInitialized()
	local remoteEvent = ChannelPipes.Resolve("RemoteEvent", msgName) :: RemoteEvent
	remoteEvent:FireClient(player, msgName, ...)
end

--[[
	服务端向全体客户端发送 RemoteEvent
	@param msgName string - 路由键
	@param ... any - 业务 payload，由对应 handler 解析
	@return nil
]]
function NetWork.FireAllClients(msgName: string, ...)
	_assertSide(IS_SERVER, "FireAllClients", "服务端")
	_ensureInitialized()
	local remoteEvent = ChannelPipes.Resolve("RemoteEvent", msgName) :: RemoteEvent
	remoteEvent:FireAllClients(msgName, ...)
end

--[[
	客户端调用服务端 RemoteFunction。网络异常与 handler 失败均捕获，返回 nil 并打日志。

	@param msgName string - 路由键
	@param ... any - 业务 payload，由对应 handler 解析
	@return any? - 服务端 handler 返回值；失败或被中间件拒绝时为 nil
]]
function NetWork.InvokeServer(msgName: string, ...): any?
	_assertSide(IS_CLIENT, "InvokeServer", "客户端")
	_ensureInitialized()
	local remoteFunction = ChannelPipes.Resolve("RemoteFunction", msgName) :: RemoteFunction
	local ok, result = pcall(remoteFunction.InvokeServer, remoteFunction, msgName, ...)
	if not ok then
		InboundDispatch.LogWarn("[NetWork] InvokeServer 失败:", msgName, result)
		return nil
	end
	return result
end

--[[
	同端广播 BindableEvent
	@param msgName string - 路由键
	@param ... any - 业务 payload，由对应 handler 解析
	@return nil
]]
function NetWork.FireBindable(msgName: string, ...)
	_ensureInitialized()
	local bindableEvent = ChannelPipes.Resolve("BindableEvent", msgName) :: BindableEvent
	bindableEvent:Fire(msgName, ...)
end

--[[
	按运行端路由提示类消息：客户端走 Bindable，服务端走 FireClient。
	用于双端共用下发门面，避免业务模块内 IsServer/IsClient 分支。
	@param player Player - 服务端下发时的目标玩家；客户端调用时可传 LocalPlayer（不参与 Bindable）
	@param msgName string - 路由键
	@param ... any - 业务 payload
	@return nil
]]
function NetWork.FireLocalOrClient(player: Player, msgName: string, ...)
	if IS_CLIENT then
		NetWork.FireBindable(msgName, ...)
		return
	end
	NetWork.FireClient(player, msgName, ...)
end

--[[
	仅服务端向指定客户端发送；非服务端时不发送、不抛错
	@param player Player - 目标玩家，须在线
	@param msgName string - 路由键
	@param ... any - 业务 payload
	@return boolean - 已在服务端发送为 true；非服务端或玩家无效为 false
]]
function NetWork.FireClientIfServer(player: Player, msgName: string, ...): boolean
	if not IS_SERVER then
		return false
	end
	if not InboundDispatch.IsValidPlayer(player) then
		InboundDispatch.LogWarn("[NetWork] FireClientIfServer 目标玩家无效:", msgName)
		return false
	end
	NetWork.FireClient(player, msgName, ...)
	return true
end

--[[
	同端调用 BindableFunction
	@param msgName string - 路由键
	@param ... any - 业务 payload，由对应 handler 解析
	@return any? - handler 返回值；异常时为 nil
]]
function NetWork.InvokeBindable(msgName: string, ...): any?
	_ensureInitialized()
	local bindableFunction = ChannelPipes.Resolve("BindableFunction", msgName) :: BindableFunction
	return bindableFunction:Invoke(msgName, ...)
end

-- ============================================================================
-- Init
-- ============================================================================

--[[
	加载全部 Channel 管道实例并绑定入站监听（Manager 启动时调用，幂等）
	@return nil
]]
function NetWork.Init()
	if _initialized then
		return
	end
	_initialized = true
	ChannelPipes.LoadAll()
	InboundDispatch.BindAll()
end

return NetWork
