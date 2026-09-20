--[[
	技能状态机运行器
	供 BaseSkillClient / BaseSkillServer 使用，当技能模块定义 States + Transitions 时驱动主流程

	能力：
	- findTransition: 查找匹配的转换规则（支持 Condition、Priority）
	- shouldStateTimeout: 状态 Duration 超时判定
	- validateStateGraph: 子领域校验（仅供 SkillModuleValidator 调用）
	- 转换锁：由 BaseSkill.TryTransition 通过 transitionLocked 实现重入保护
]]

local SkillEventConst = require(script.Parent.SkillEventConst)
local EVT = SkillEventConst
local SkillStateMachine = {}

--[[
	查找可用的状态转换
	支持可选 Condition(self, payload) 与 Priority（数值越大优先级越高）
	@param transitions table 技能模块的 Transitions
	@param currentState string 当前状态
	@param eventName string 事件名
	@param context table? BaseSkill 实例，供 Condition 使用
	@param payload table? 事件载荷，供 Condition 使用
	@return table? 匹配的转换规则，或 nil
]]
function SkillStateMachine.findTransition(transitions, currentState, eventName, context, payload)
	if not transitions then return nil end
	local candidates = {}
	for _, rule in ipairs(transitions) do
		if rule.From == currentState and rule.Event == eventName then
			if not rule.Condition or (context and rule.Condition(context, payload)) then
				table.insert(candidates, rule)
			end
		end
	end
	if #candidates == 0 then return nil end
	if #candidates == 1 then return candidates[1] end
	-- 多规则时取 Priority 最高者
	table.sort(candidates, function(a, b)
		return (a.Priority or 0) > (b.Priority or 0)
	end)
	return candidates[1]
end

--[[
	检查状态是否应触发 StateDurationElapsed（原 StateTimeout）
	@param stateConfig table 状态配置
	@param enteredAt number 进入状态时的时间
	@param nowTime number 当前时间
	@return boolean
]]
function SkillStateMachine.shouldStateTimeout(stateConfig, enteredAt, nowTime)
	if not stateConfig or not stateConfig.Duration then return false end
	local dur = stateConfig.Duration
	if dur < 0 then return false end -- Duration=-1 表示事件驱动，不自动超时
	return (nowTime - enteredAt) >= dur
end

--[[
	子领域校验：状态图流程正确性（可达性、终态、死状态、StateOrder 倒挂、优先级冲突）
	报错术语见《技能模块作者规范》StateOrder 语义、约束章节
	仅供 SkillModuleValidator 调用，外部统一走 SkillModuleValidator.validateBaseSkill
	@param skillModule table 技能模块
	@param errors table 错误列表，校验失败时追加
]]
function SkillStateMachine.validateStateGraph(skillModule, errors)
	local function addErr(msg)
		table.insert(errors, msg)
	end
	if not skillModule.States or not skillModule.InitialState then
		return -- 非状态机技能，跳过
	end

	local states = skillModule.States
	local transitions = skillModule.Transitions or {}

	-- 校验 OnEnter/OnExit 回调引用
	for stateName, cfg in pairs(states) do
		if type(cfg.OnEnterClient) == "string" and cfg.OnEnterClient ~= "" and not skillModule[cfg.OnEnterClient] then
			addErr(("状态 '%s' OnEnterClient '%s' 函数不存在"):format(stateName, cfg.OnEnterClient))
		end
		if type(cfg.OnEnterServer) == "string" and cfg.OnEnterServer ~= "" and not skillModule[cfg.OnEnterServer] then
			addErr(("状态 '%s' OnEnterServer '%s' 函数不存在"):format(stateName, cfg.OnEnterServer))
		end
		if type(cfg.OnExitClient) == "string" and cfg.OnExitClient ~= "" and not skillModule[cfg.OnExitClient] then
			addErr(("状态 '%s' OnExitClient '%s' 函数不存在"):format(stateName, cfg.OnExitClient))
		end
		if type(cfg.OnExitServer) == "string" and cfg.OnExitServer ~= "" and not skillModule[cfg.OnExitServer] then
			addErr(("状态 '%s' OnExitServer '%s' 函数不存在"):format(stateName, cfg.OnExitServer))
		end
	end

	-- 流程正确性：终态、死状态、可达性
	local function isTerminal(stateName)
		local cfg = states[stateName]
		return cfg and cfg.IsTerminal == true
	end
	local hasOutgoing = {}
	local outgoingEdges = {}
	for _, rule in ipairs(transitions) do
		hasOutgoing[rule.From] = true
		outgoingEdges[rule.From] = outgoingEdges[rule.From] or {}
		table.insert(outgoingEdges[rule.From], rule.To)
	end

	local reachable = {}
	do
		local queue = { skillModule.InitialState }
		reachable[skillModule.InitialState] = true
		local head = 1
		while head <= #queue do
			local from = queue[head]
			head = head + 1
			for _, to in ipairs(outgoingEdges[from] or {}) do
				if not reachable[to] then
					reachable[to] = true
					table.insert(queue, to)
				end
			end
		end
	end

	for stateName, cfg in pairs(states) do
		if isTerminal(stateName) then
			if hasOutgoing[stateName] then
				addErr(("终态 '%s' 存在出边，会导致终态复活，框架语义不允许（IsTerminal 状态不应有转出）"):format(stateName))
			end
		else
			local dur = cfg and cfg.Duration
			local canTimeout = (type(dur) == "number" and dur >= 0)
			local hasExit = canTimeout or hasOutgoing[stateName]
			if not hasExit then
				addErr(("状态 '%s' 为死状态：无 Duration 超时且无出边，无法离开"):format(stateName))
			end
			if not reachable[stateName] then
				addErr(("状态 '%s' 永远不可达：从 InitialState 无法到达"):format(stateName))
			end
		end
	end

	-- StateOrder 顺序一致性：每条边 From->To 应满足 order[From] < order[To]
	local stateOrder = skillModule.StateOrder
	if stateOrder and type(stateOrder) == "table" then
		for _, rule in ipairs(transitions) do
			local fromOrder = stateOrder[rule.From]
			local toOrder = stateOrder[rule.To]
			if fromOrder ~= nil and toOrder ~= nil and type(fromOrder) == "number" and type(toOrder) == "number" then
				if fromOrder >= toOrder then
					addErr(("StateOrder 顺序倒挂：Transition %s -> %s，order[%s]=%s >= order[%s]=%s"):format(
						rule.From, rule.To, rule.From, tostring(fromOrder), rule.To, tostring(toOrder)))
				end
			end
		end
	end

	-- 同 From+Event 多规则同 Priority 冲突检测
	local fromEventToPriorities = {}
	for _, rule in ipairs(transitions) do
		local key = rule.From .. "|" .. (rule.Event or "")
		fromEventToPriorities[key] = fromEventToPriorities[key] or {}
		table.insert(fromEventToPriorities[key], { To = rule.To, Priority = rule.Priority or 0 })
	end
	for key, list in pairs(fromEventToPriorities) do
		if #list > 1 then
			local priorities = {}
			for _, r in ipairs(list) do
				priorities[r.Priority] = (priorities[r.Priority] or 0) + 1
			end
			for pri, count in pairs(priorities) do
				if count > 1 then
					addErr(("From+Event '%s' 存在 %d 条同优先级 %s 规则，行为歧义"):format(key, count, tostring(pri)))
					break
				end
			end
		end
	end

	-- A. Timeout 语义：非终态 Duration >= 0 时，必须有 Event=StateTimeout 的离开路径
	local hasStateTimeoutOut = {}
	for _, rule in ipairs(transitions) do
		if rule.Event == EVT.StateTimeout then
			hasStateTimeoutOut[rule.From] = true
		end
	end
	for stateName, cfg in pairs(states) do
		if not isTerminal(stateName) then
			local dur = cfg and cfg.Duration
			if type(dur) == "number" and dur >= 0 then
				if not hasStateTimeoutOut[stateName] then
					addErr(("状态 '%s' Duration=%s 但无 StateTimeout 出边，Duration 无实际意义（半失效配置）"):format(stateName, tostring(dur)))
				end
			end
		end
	end
end

return SkillStateMachine
