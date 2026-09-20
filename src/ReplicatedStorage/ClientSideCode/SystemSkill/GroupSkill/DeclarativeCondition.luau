--[[
	DeclarativeCondition - 声明式派生条件解析
	支持 data-driven condition，与 function(ctx) 等价，便于校验、编辑器、测试

	支持运算符：all, any, not
	支持条件类型：chain_input, window, state_before, state_passed, literal

	示例：
	condition = {
		all = {
			{ type = "chain_input", index = 2, buffer = 0.25 },
			{ type = "window", name = "Combo2" },
		}
	}
]]

export type ChainConditionContext = {
	CheckChainInput: (index: number, maxBufferTime: number?) -> boolean,
	InWindow: (windowName: string) -> boolean,
	StateBefore: (state: string) -> boolean,
	StatePassed: (state: string) -> boolean,
}

--[[
	解析并求值声明式条件
	@param cond table 条件对象（支持 all/any/not 组合 + 叶子类型）
	@param ctx ChainConditionContext 派生条件上下文
	@return boolean 条件是否通过
]]
local function evaluateDeclarative(cond, ctx)
	if type(cond) ~= "table" or not ctx then
		return false
	end

	-- 运算符：all
	if cond.all ~= nil then
		local list = cond.all
		if type(list) ~= "table" then return false end
		for _, sub in ipairs(list) do
			if not evaluateDeclarative(sub, ctx) then
				return false
			end
		end
		return true
	end

	-- 运算符：any
	if cond.any ~= nil then
		local list = cond.any
		if type(list) ~= "table" then return false end
		for _, sub in ipairs(list) do
			if evaluateDeclarative(sub, ctx) then
				return true
			end
		end
		return false
	end

	-- 运算符：not（用方括号避免与关键字冲突）
	if cond["not"] ~= nil then
		return not evaluateDeclarative(cond["not"], ctx)
	end

	-- 叶子条件
	local t = cond.type
	if type(t) ~= "string" then return false end

	if t == "chain_input" then
		local index = cond.index
		if type(index) ~= "number" then return false end
		local buffer = cond.buffer
		if buffer ~= nil and type(buffer) ~= "number" then return false end
		return ctx.CheckChainInput(index, buffer)
	end

	if t == "window" then
		local name = cond.name
		if type(name) ~= "string" then return false end
		return ctx.InWindow(name)
	end

	if t == "state_before" then
		local state = cond.state
		if type(state) ~= "string" then return false end
		return ctx.StateBefore(state)
	end

	if t == "state_passed" then
		local state = cond.state
		if type(state) ~= "string" then return false end
		return ctx.StatePassed(state)
	end

	-- literal：固定 true/false（便于测试、占位）
	if t == "literal" then
		return not not cond.value
	end

	return false
end

--[[
	判断 condition 是否为声明式格式（table 形式）
	@param condition any
	@return boolean
]]
local function isDeclarative(condition)
	return type(condition) == "table"
end

return {
	evaluate = evaluateDeclarative,
	isDeclarative = isDeclarative,
}
