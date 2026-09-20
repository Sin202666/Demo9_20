--[[
	Module: SystemInputBind-Type
	Description: SystemInputBind IDE 类型桩
	Author: 林奥宇
	Created: 2026-08-27
	Last Modified: 2026-08-28
]]

local SystemInputBind = {}

--[[
	读取键位表深拷贝
	@param player Player - 玩家
	@return table - InputBindings
]]
function SystemInputBind.Get(player: Player): { [string]: { [string]: string } }
end

--[[
	写入键位表
	@param player Player - 玩家
	@param bindings table - scheme → actionId → KeyCode.Name
	@return boolean - 成功
	@return string? - 错误码
]]
function SystemInputBind.Set(player: Player, bindings: any): (boolean, string?)
end

--[[
	注册 Remote
]]
function SystemInputBind.RegisterNetWork()
end

--[[
	Manager-only：限频 + 注册 Remote
]]
function SystemInputBind.Init()
end

return SystemInputBind
