local module = {}

--[[
	从 DataStore 拉取并刷新 workspace 上的全局特殊数值
	@return nil - 读取失败时将对应 Value 置 0 并 Log
]]
function module.Refresh()
end

--[[
	注册全局特殊数值定时刷新，由 UpdateManager 在 Start 前调用一次
	@return nil
]]
function module.Init()
end

return module
