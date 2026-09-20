--[[
	派生条件上下文（只读、无副作用）
	约定：condition(ctx) 仅调用 ctx 提供的 helper，禁止写入状态、禁止直接读运行态细节
	实现：仅依赖 runtime 的显式 getter 接口，不访问内部结构

	Helper：
	- CheckChainInput(index, maxBufferTime?)  是否有派生到 index 的按键输入（限时缓冲，默认 0.25 秒）
	- CheckInput(name)        兼容旧 API，等价于 CheckInputBuffered(name, 0.3)
	- CheckInputBuffered(name, duration)  某输入是否在最近 duration 秒内发生过（避免粘住）
	- ElapsedAfter(time)      当前状态段进入后的已运行时间是否超过 time（基于 State.enteredAt）
	- ElapsedAfterInState(state, time)  当前状态为 state 且该状态已运行超过 time 时返回 true
	- InWindow(windowName)    是否在 GroupSkill 模块 ChainWindows[windowName] 定义的派生窗口内
	                          需 BaseSkill 模块提供 StateOrder，GroupSkill 模块提供 ChainWindows
	- ElapsedInWindow(startState, startElapsed, endState, endElapsed)
	    从「startState 内 elapsed > startElapsed」到「endState 内 elapsed > endElapsed」这段时间内返回 true
	    需 BaseSkill 模块提供 StateOrder，否则返回 false
	- TotalElapsedAfter(time) 整段 BaseSkill 从启动开始的累计时间是否超过 time
	- CurrentBaseSkillStateIs(state)  当前 BaseSkill 状态机是否处于 state
	- StatePassed(state)  当前状态已经过某状态点（基于 StateOrder）
	- StateBefore(state)  当前还未到某状态（基于 StateOrder）
	- ControlStateIs(state)  当前 BaseSkill 控制权状态是否为 state（"Locked"|"ChainOpen"|"Released"）
	- CurrentBaseSkillIndexIs(index)  当前段索引是否为 index
]]

export type ChainConditionContext = {
	CheckChainInput: (index: number, maxBufferTime: number?) -> boolean,
	CheckInput: (name: string) -> boolean,
	CheckInputBuffered: (name: string, duration: number) -> boolean,
	ElapsedAfter: (time: number) -> boolean,
	ElapsedAfterInState: (state: string, time: number) -> boolean,
	InWindow: (windowName: string) -> boolean,
	ElapsedInWindow: (startState: string, startElapsed: number, endState: string, endElapsed: number) -> boolean,
	TotalElapsedAfter: (time: number) -> boolean,
	CurrentBaseSkillStateIs: (state: string) -> boolean,
	StatePassed: (state: string) -> boolean,
	StateBefore: (state: string) -> boolean,
	ControlStateIs: (state: string) -> boolean,
	CurrentBaseSkillIndexIs: (index: number) -> boolean,
}

local function getStateOrderFromRuntime(runtime)
	local baseSkill = runtime:GetCurrentBaseSkill()
	if not baseSkill or not baseSkill.skillModule then return nil end
	return baseSkill.skillModule.StateOrder
end

--[[
	安全取状态顺序，未知状态名返回 nil（不兜底 0/99，避免误判通过）
]]
local function getStateOrderSafe(stateOrder, stateName)
	if stateOrder == nil or stateName == nil then return nil end
	return stateOrder[stateName]
end

local function warnUnknownState(context, currentState, targetState, extra)
	local skillName = context and context.owner and context.owner.skillName or "?"
	local castId = context and context.skillCastId or "?"
	local msg = ("[ChainConditionContext] 未知状态或配置缺失: current=%s target=%s skill=%s castId=%s"):format(
		tostring(currentState),
		tostring(targetState),
		tostring(skillName),
		tostring(castId)
	)
	if extra and extra ~= "" then msg = msg .. " " .. tostring(extra) end
	warn(msg)
end

--[[
	是否已过某时间点（state + elapsed）
	未知状态名一律返回 false + warn
]]
local function isPastPoint(stateName, elapsed, point, stateOrder, runtime)
	if not stateName or elapsed == nil or not point or not stateOrder then return false end
	local order = getStateOrderSafe(stateOrder, stateName)
	local pointOrder = getStateOrderSafe(stateOrder, point.state)
	if order == nil or pointOrder == nil then
		warnUnknownState(runtime, stateName, point and point.state, "isPastPoint")
		return false
	end
	local threshold = point.elapsed or 0
	return (stateName == point.state and elapsed > threshold) or (order > pointOrder)
end

--[[
	创建派生条件上下文（由 GroupSkillInstanceRuntime 在 Tick 中调用）
	@param runtime GroupSkillInstanceRuntime 需提供 GetCurrentBaseSkill、GetCurrentBaseSkillState、GetCurrentBaseSkillStateElapsed、GetCurrentBaseSkillTotalTime、GetCurrentBaseSkillControlState、CheckDeriveRequest、CheckInputBuffered、activeBaseSkillIndex、owner.groupSkillModule
	@return ChainConditionContext
]]
local function createChainConditionContext(runtime): ChainConditionContext
	return {
		CheckChainInput = function(index: number, maxBufferTime: number?): boolean
			return runtime:CheckDeriveRequest(index, maxBufferTime)
		end,

		CheckInput = function(name: string): boolean
			return runtime:CheckInputBuffered(name, 0.3)
		end,

		CheckInputBuffered = function(name: string, duration: number): boolean
			return runtime:CheckInputBuffered(name, duration)
		end,

		ElapsedAfter = function(time: number): boolean
			local elapsed = runtime:GetCurrentBaseSkillStateElapsed()
			return elapsed ~= nil and elapsed > time
		end,

		ElapsedAfterInState = function(state, time)
			if runtime:GetCurrentBaseSkillState() ~= state then
				return false
			end
			local elapsed = runtime:GetCurrentBaseSkillStateElapsed()
			return elapsed ~= nil and elapsed > time
		end,

		InWindow = function(windowName)
			local stateOrder = getStateOrderFromRuntime(runtime)
			if not stateOrder then
				warnUnknownState(runtime, nil, nil, ("InWindow(%s) StateOrder 缺失"):format(tostring(windowName)))
				return false
			end
			local groupModule = runtime.owner and runtime.owner.groupSkillModule
			if not groupModule or not groupModule.ChainWindows then
				warnUnknownState(runtime, nil, nil, ("InWindow(%s) ChainWindows 缺失"):format(tostring(windowName)))
				return false
			end
			local window = groupModule.ChainWindows[windowName]
			if not window or not window.open or not window.close then
				warnUnknownState(runtime, nil, nil, ("InWindow(%s) 窗口配置缺失"):format(tostring(windowName)))
				return false
			end

			local stateName = runtime:GetCurrentBaseSkillState()
			local elapsed = runtime:GetCurrentBaseSkillStateElapsed()
			if not stateName or elapsed == nil then return false end

			local passedOpen = isPastPoint(stateName, elapsed, window.open, stateOrder, runtime)
			local passedClose = isPastPoint(stateName, elapsed, window.close, stateOrder, runtime)
			return passedOpen and not passedClose
		end,

		ElapsedInWindow = function(startState, startElapsed, endState, endElapsed)
			local stateOrder = getStateOrderFromRuntime(runtime)
			if not stateOrder then
				warnUnknownState(runtime, nil, nil, "ElapsedInWindow StateOrder 缺失")
				return false
			end

			local stateName = runtime:GetCurrentBaseSkillState()
			local elapsed = runtime:GetCurrentBaseSkillStateElapsed()
			if not stateName or elapsed == nil then return false end

			local passedStart = isPastPoint(stateName, elapsed, { state = startState, elapsed = startElapsed }, stateOrder, runtime)
			local passedEnd = isPastPoint(stateName, elapsed, { state = endState, elapsed = endElapsed }, stateOrder, runtime)
			return passedStart and not passedEnd
		end,

		TotalElapsedAfter = function(time: number): boolean
			local total = runtime:GetCurrentBaseSkillTotalTime()
			return total ~= nil and total > time
		end,

		CurrentBaseSkillStateIs = function(state: string): boolean
			return runtime:GetCurrentBaseSkillState() == state
		end,

		StatePassed = function(stateName: string): boolean
			local stateOrder = getStateOrderFromRuntime(runtime)
			local current = runtime:GetCurrentBaseSkillState()
			if not stateOrder or not current then return false end
			local currentOrder = getStateOrderSafe(stateOrder, current)
			local targetOrder = getStateOrderSafe(stateOrder, stateName)
			if currentOrder == nil or targetOrder == nil then
				warnUnknownState(runtime, current, stateName, "StatePassed")
				return false
			end
			return currentOrder >= targetOrder
		end,

		StateBefore = function(stateName: string): boolean
			local stateOrder = getStateOrderFromRuntime(runtime)
			local current = runtime:GetCurrentBaseSkillState()
			if not stateOrder or not current then return false end
			local currentOrder = getStateOrderSafe(stateOrder, current)
			local targetOrder = getStateOrderSafe(stateOrder, stateName)
			if currentOrder == nil or targetOrder == nil then
				warnUnknownState(runtime, current, stateName, "StateBefore")
				return false
			end
			return currentOrder < targetOrder
		end,

		ControlStateIs = function(stateName: string): boolean
			return runtime:GetCurrentBaseSkillControlState() == stateName
		end,

		CurrentBaseSkillIndexIs = function(index: number): boolean
			return runtime.activeBaseSkillIndex == index
		end,
	}
end

return {
	createChainConditionContext = createChainConditionContext,
}
