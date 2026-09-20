--[[
	SkillStateRuntime - 状态机壳层（纯 Lua 混入层）
	职责：current / enteredAt / lock、TryTransition、Enter/Exit 调度
	客户端和服务端各自提供：callEnterHandler、callExitHandler、onTerminalReached、onFatalError（可选）

	终态约束（IsTerminal）：
	- 终态不可再转出：TryTransition 在终态时直接返回 false
	- 进入终态时触发 onTerminalReached，由 BaseSkill.markFinished 统一收尾

	转换采用事务式处理：Enter 失败时回滚状态并触发 onFatalError，避免半成功脏状态。
]]

local SkillStateMachine = require(script.Parent.SkillStateMachine)

local SkillStateRuntime = {}

--[[
	创建状态机初始数据（供 initSkillMaterial 使用）
	@param skillModule table 技能模块
	@return table { current, enteredAt, transitionLocked, version }
	version：每次转换递增，供异步回调比对，防止旧回调污染新状态
]]
function SkillStateRuntime.createStateData(skillModule)
	if not skillModule.States or not skillModule.InitialState then
		return nil
	end
	return {
		current = skillModule.InitialState,
		enteredAt = 0,
		transitionLocked = false,
		version = 0,
	}
end

--[[
	尝试状态转换（含重入保护、事务式回滚）
	@param skillInstance table 技能实例，需有 skillModule、skillRunData、nowTime、skillName
	@param eventName string 事件名
	@param payload any? 载荷
	@param handlers table { callEnterHandler, callExitHandler, onTerminalReached, onFatalError? }
	@return boolean 是否成功转换
]]
function SkillStateRuntime.tryTransition(skillInstance, eventName, payload, handlers)
	local sm = skillInstance.skillModule
	local runData = skillInstance.skillRunData
	if not sm.Transitions or not runData.State then return false end
	if runData.State.transitionLocked then return false end

	-- 终态不可再转出（框架约束）
	local currentCfg = sm.States and sm.States[runData.State.current]
	if currentCfg and currentCfg.IsTerminal then
		return false
	end

	local rule = SkillStateMachine.findTransition(sm.Transitions, runData.State.current, eventName, skillInstance, payload)
	if not rule then return false end

	local callEnterHandler = handlers.callEnterHandler
	local callExitHandler = handlers.callExitHandler
	local onTerminalReached = handlers.onTerminalReached
	local onFatalError = handlers.onFatalError

	local fromState = runData.State.current
	local fromEnteredAt = runData.State.enteredAt
	local fromVersion = runData.State.version or 0

	runData.State.transitionLocked = true

	-- Exit 单独 pcall，失败时仍触发 fatal（Exit 可能已部分执行）
	local exitOk, exitErr = pcall(callExitHandler, skillInstance, fromState, payload)
	if not exitOk then
		runData.State.transitionLocked = false
		warn("[SkillStateRuntime] ExitHandler 异常:", skillInstance.skillName, eventName, fromState, exitErr)
		if type(onFatalError) == "function" then
			pcall(onFatalError, skillInstance, "ExitFailed")
		end
		return false
	end

	runData.State.current = rule.To
	runData.State.enteredAt = skillInstance.nowTime
	runData.State.version = fromVersion + 1

	-- Enter 单独 pcall，失败时回滚并触发 fatal
	local enterOk, enterErr = pcall(callEnterHandler, skillInstance, rule.To, payload)
	if not enterOk then
		runData.State.current = fromState
		runData.State.enteredAt = fromEnteredAt
		runData.State.version = fromVersion
		runData.State.transitionLocked = false
		warn("[SkillStateRuntime] EnterHandler 异常，已回滚:", skillInstance.skillName, eventName, rule.To, enterErr)
		if type(onFatalError) == "function" then
			pcall(onFatalError, skillInstance, "EnterFailed")
		end
		return false
	end

	runData.State.transitionLocked = false

	-- 进入终态时触发统一收尾（markFinished），pcall 防止报错影响状态已完成的转换
	local toCfg = sm.States and sm.States[rule.To]
	if toCfg and toCfg.IsTerminal and onTerminalReached then
		local ok, err = pcall(onTerminalReached, skillInstance, rule.To)
		if not ok then
			warn("[SkillStateRuntime] onTerminalReached 异常:", skillInstance.skillName, rule.To, err)
			if type(handlers.onFatalError) == "function" then
				pcall(handlers.onFatalError, skillInstance, "TerminalReachedFailed")
			end
		end
	end
	return true
end

--[[
	获取当前状态
	@param runData table 技能运行数据
	@return string? 当前状态名
]]
function SkillStateRuntime.getCurrentState(runData)
	if runData and runData.State then
		return runData.State.current
	end
	return nil
end

--[[
	获取当前状态版本号（供异步回调比对，防止旧回调污染新状态）
	@param skillInstance table 技能实例
	@return number
]]
function SkillStateRuntime.getStateVersion(skillInstance)
	local runData = skillInstance and skillInstance.skillRunData
	if runData and runData.State then
		return runData.State.version or 0
	end
	return 0
end

--[[
	异步回调时检查版本是否仍有效，若已切换状态则跳过
	@param skillInstance table 技能实例
	@param version number 进入异步逻辑时记录的 version
	@return boolean 是否仍属于当前状态（可继续执行）
]]
function SkillStateRuntime.isVersionValid(skillInstance, version)
	local runData = skillInstance and skillInstance.skillRunData
	if not runData or not runData.State then return false end
	return (runData.State.version or 0) == version
end

return SkillStateRuntime
