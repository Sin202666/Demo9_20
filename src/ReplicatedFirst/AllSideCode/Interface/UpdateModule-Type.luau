--[[
	Module: UpdateModule-Type
	Description: UpdateModule 类型声明（完整使用说明见 ToolSystem/UpdateModule.luau 文件头）
	Author: 林奥宇
	Created: 2026-07-01
	Last Modified: 2026-09-01
]]

export type UpdateCallback = (elapsed: number) -> ()

export type RegisterOptions = {
	initialElapsed: number?,
	spawn: boolean?,
}

local UpdateModule = {}

UpdateModule.INTERVAL = {
	FAST = 0.1,
	HALF = 0.5,
	SEC = 1,
	SEC_30 = 30,
	SEC_120 = 120,
	SEC_300 = 300,
}

--[[
	注册定时更新任务（仅服务端生效）
	@param interval number - 触发间隔（秒），须 > 0
	@param callback UpdateCallback - 到期回调，参数为累计秒数
	@param options RegisterOptions? - initialElapsed 默认 0；spawn 默认 false
	@return () - 无返回值；失败时静默 return
]]
function UpdateModule.Register(interval: number, callback: UpdateCallback, options: RegisterOptions?)
end

--[[
	启动 Heartbeat 主循环（仅 UpdateManager 调用，重复调用幂等）
	@return () - 无返回值
]]
function UpdateModule.Start()
end

return UpdateModule
