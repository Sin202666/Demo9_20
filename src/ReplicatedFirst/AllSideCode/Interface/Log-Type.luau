local module = {}

--[[
	打印日志（仅在调试模式下）
	@param ...: any - 要打印的内容
]]
function module.print(...: any)
end

--[[
	打印警告日志（仅在调试模式下）
	@param ...: any - 要打印的内容
]]
function module.warn(...: any)
end

--[[
	格式化打印日志（仅在调试模式下）
	@param format: string - 格式化字符串
	@param ...: any - 格式化参数
]]
function module.printf(format: string, ...: any)
end

--[[
	获取当前是否为调试模式
	@return boolean - 是否为调试模式
]]
function module.isDebug(): boolean
end

return module
