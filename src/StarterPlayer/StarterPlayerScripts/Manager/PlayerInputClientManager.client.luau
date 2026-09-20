--[[
	Module: PlayerInputClientManager
	Description: 客户端 SystemInput 启动编排（Init + Gameplay Context + 延后加载存档键位）
	Author: 林奥宇
	Created: 2026-08-27
	Last Modified: 2026-08-28

	与 SystemInputBind：本 Manager defer LoadSavedBindings，覆盖各业务 Manager 写入的默认键；
	存档 Remote 由服务端 SystemInputBind 模块加载时注册（UpdateManager 调 Init 只挂限频）。
	仅 LocalPlayer 客户端执行。
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local SystemInput = Utils.SystemInput

SystemInput.Init()
SystemInput.PushContext(SystemInput.ContextIds.Gameplay)

-- 等同帧其它 Manager（如 Skill）写完默认绑定后再套存档覆盖
task.defer(function()
	SystemInput.LoadSavedBindings()
end)
