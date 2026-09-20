local module = {}

--[[
	获取整个配置对象的深拷贝。只需单个键时用 GetValue。

	@return table? - GameConfig 全表深拷贝；加载失败为 nil
]]
function module.Get(): any?
end

--[[
	按路径取配置值。table 返回深拷贝，标量原样返回。

	@param path string | {string} - 配置路径。字符串为顶层键；字符串数组为嵌套键
	@return any? - nil 表示缺失或路径非法；boolean/number/string 原样返回；table 为深拷贝
]]
function module.GetValue(path: string | { string }): any?
end

--[[
	清除本模块的配置指针。不能热替换 GameConfig ModuleScript。
]]
function module.ClearCache()
end

return module
