-- ============================================================================
-- 复制工具模块
-- 提供深拷贝和表比较功能
-- ============================================================================

local module = {}

-- ============================================================================
-- 公共API
-- ============================================================================

--[[
	深拷贝表（递归复制所有嵌套表）
	@param original: any - 要复制的原始表
	@return any - 深拷贝后的新表
]]
function module.deepCopy(original: any): any
	if not original then
		return {}
	end
	
	local copy = {}
	for k, v in pairs(original) do
		if type(v) == "table" then
			copy[k] = module.deepCopy(v)
		else
			copy[k] = v
		end
	end
	return copy
end

--[[
	判断两个表是否相等（递归比较所有嵌套表）
	@param t1: any - 第一个表
	@param t2: any - 第二个表
	@return boolean - 是否相等
]]
function module.IsEqual(t1: any, t2: any): boolean
	-- 如果两个都不是表，直接比较值
	if type(t1) ~= "table" or type(t2) ~= "table" then
		return t1 == t2
	end
	
	-- 如果都是 nil，返回 true
	if t1 == nil and t2 == nil then
		return true
	end
	
	-- 如果一个是 nil，另一个不是，返回 false
	if t1 == nil or t2 == nil then
		return false
	end
	
	-- 检查 t1 的所有键值对是否在 t2 中存在且相等
	for k, v in pairs(t1) do
		if not module.IsEqual(t2[k], v) then
			return false
		end
	end
	
	-- 检查 t2 的所有键是否在 t1 中存在（避免 t2 有额外键）
	for k in pairs(t2) do
		if t1[k] == nil then
			return false
		end
	end
	
	return true
end

return module
