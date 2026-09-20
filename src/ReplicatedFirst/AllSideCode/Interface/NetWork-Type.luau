local module = {}

export type HandlerOptions = {
	skipRateLimit: boolean?,
	skipCheatDetection: boolean?,
	middlewareDataIndex: number?,
	channel: string?,
}

export type RegisterOptions = {
	channel: string?,
	replace: boolean?,
}

function module.Init()
end

function module.RegisterServerRemoteEvent(msgName: string, handler: (player: Player, ...any) -> (), options: HandlerOptions?)
end

function module.RegisterClientRemoteEvent(msgName: string, handler: (...any) -> ())
end

function module.RegisterServerRemoteFunction(msgName: string, handler: (player: Player, ...any) -> any, options: HandlerOptions?)
end

function module.RegisterBindableEvent(msgName: string, handler: (...any) -> (), registerOptions: RegisterOptions?)
end

function module.RegisterBindableFunction(msgName: string, handler: (...any) -> any, registerOptions: RegisterOptions?)
end

function module.FireServer(msgName: string, ...)
end

function module.FireClient(player: Player, msgName: string, ...)
end

function module.FireAllClients(msgName: string, ...)
end

function module.InvokeServer(msgName: string, ...): any?
end

function module.FireBindable(msgName: string, ...)
end

--[[
	按运行端路由：客户端 Bindable，服务端 FireClient
	@param player Player - 服务端目标玩家
	@param msgName string - 路由键
	@param ... any - 业务 payload
]]
function module.FireLocalOrClient(player: Player, msgName: string, ...)
end

--[[
	仅服务端 FireClient；非服务端返回 false
	@param player Player - 目标玩家
	@param msgName string - 路由键
	@param ... any - 业务 payload
	@return boolean - 是否已发送
]]
function module.FireClientIfServer(player: Player, msgName: string, ...): boolean
end

function module.InvokeBindable(msgName: string, ...): any?
end

return module
