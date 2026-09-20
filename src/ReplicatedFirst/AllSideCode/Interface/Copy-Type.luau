local module = {}

--[[
	深拷贝表（递归复制所有嵌套表）
	@param original: any - 要复制的原始表
	@return any - 深拷贝后的新表
]]
function module.deepCopy(original: any): any
end

--[[
	判断两个表是否相等（递归比较所有嵌套表）
	@param t1: any - 第一个表
	@param t2: any - 第二个表
	@return boolean - 是否相等
]]
function module.IsEqual(t1: any, t2: any): boolean
end

return module
