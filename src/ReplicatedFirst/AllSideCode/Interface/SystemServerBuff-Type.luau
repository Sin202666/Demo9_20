local module = {}

--[[
	从 DataStore 拉取并刷新 workspace 上的服务器 BUFF
	@return nil - 读取失败时 Log 并提前返回
]]
function module.Refresh()
end

--[[
	注册服务器 BUFF 定时刷新，由 UpdateManager 在 Start 前调用一次
	@return nil
]]
function module.Init()
end

return module
