--[[
	技能模块加载期校验器（唯一外部入口）
	在 require 后立即校验，将非法配置挡在加载期，避免运行时报错

	作者必读：报错术语与《技能模块作者规范》一一对应
	docs/技能模块作者规范.md

	分层结构：
	- 第一层（总入口）：validateBaseSkill、validateGroupSkill
	- 第二层（子领域）：validateStates、validateInitialState、validateTransitions、
	  validateStateOrder、validateStateGraph、validateWindows、validateDeriveList、
	  validateDamageProfiles、validateProjectileProfiles
	- 第三层（报错）：failOnError

	Warning 可治理：warningCode、severity、suppressions
	- options.suppressions: { [warningCode] = true } 豁免指定 warning
	- options.env: "development" | "production"，生产构建可禁止未豁免的 block_production 级 warning
	- 示例：validateBaseSkill(m, { suppressions = { SkillFuncCondition = true }, env = "production" })
]]

local SkillStateMachine = require(script.Parent.SkillStateMachine)
local SkillModuleValidator = {}

-- Warning 代码（可治理、可豁免、可按环境阻断）
-- 生产默认禁 function condition，特批须加 suppressions 并写注释说明原因
SkillModuleValidator.WARNING_CODES = {
	TransitionFuncCondition = "TransitionFuncCondition",
	SkillFuncCondition = "SkillFuncCondition",
	SkillLiteralTrueAlways = "SkillLiteralTrueAlways",
	WindowOrderRisk = "WindowOrderRisk",
}

-- 严重级别：warn=仅输出；block_production=生产环境可阻断
SkillModuleValidator.WARNING_SEVERITY = {
	warn = "warn",
	block_production = "block_production",
}

local function addError(errors, msg)
	table.insert(errors, msg)
end

--[[
	添加结构化 warning（支持后续 suppressions、按 env 阻断）
	@param warnings table
	@param code string WARNING_CODES 之一
	@param message string 人类可读描述
	@param severity string? 默认 WARNING_SEVERITY.warn
]]
local function addWarning(warnings, code, message, severity)
	if not warnings then return end
	table.insert(warnings, {
		code = code,
		message = message,
		severity = severity or SkillModuleValidator.WARNING_SEVERITY.warn,
	})
end

local function formatWarning(w)
	if type(w) == "string" then return w end
	if type(w) == "table" and w.message then
		return ("[%s] %s"):format(w.code or "?", w.message)
	end
	return tostring(w)
end

-- suppressions[code] 可为 true 或 string（原因），均视为已豁免
local function isWarningSuppressed(w, suppressions)
	if type(w) ~= "table" or not w.code then return false end
	if not suppressions then return false end
	local v = suppressions[w.code]
	return v == true or (type(v) == "string" and v ~= "")
end

local function shouldBlockInProduction(w, env)
	if env ~= "production" then return false end
	return type(w) == "table" and w.severity == SkillModuleValidator.WARNING_SEVERITY.block_production
end

--[[
	校验 Data.skillName 与模块名一致，防止错名发布（影响冷却归属、埋点、同步日志等）
	@param moduleScriptName string 模块脚本名（ModuleScript.Name）
	@param skillModule table 技能模块
	@param errors table 错误列表
]]
local function validateModuleNameConsistency(moduleScriptName, skillModule, errors)
	if type(moduleScriptName) ~= "string" then
		return
	end
	local data = skillModule and skillModule.Data
	-- BaseSkill 模板可能无 Data，无则跳过；GroupSkill 必有 Data
	if not data then
		return
	end
	local skillName = data.skillName
	if type(skillName) ~= "string" or skillName == "" then
		table.insert(errors, ("Data.skillName 缺失：期望=%s"):format(moduleScriptName))
		return
	end
	if skillName ~= moduleScriptName then
		table.insert(errors, ("Data.skillName 与模块名不一致：module=%s data=%s"):format(moduleScriptName, skillName))
	end
end

--[[
	校验 States 存在且为表
]]
function SkillModuleValidator.validateStates(skillModule, errors)
	if not skillModule.States then
		addError(errors, "States 缺失")
		return false
	end
	if type(skillModule.States) ~= "table" then
		addError(errors, "States 必须为 table")
		return false
	end
	return true
end

--[[
	校验 InitialState 存在且存在于 States
]]
function SkillModuleValidator.validateInitialState(skillModule, errors)
	if not skillModule.InitialState then
		addError(errors, "InitialState 缺失")
		return false
	end
	if not skillModule.States or not skillModule.States[skillModule.InitialState] then
		addError(errors, ("InitialState '%s' 不存在于 States"):format(tostring(skillModule.InitialState)))
		return false
	end
	return true
end

--[[
	校验 Transitions 中 From/To 引用的状态都存在
	支持格式：{ { From, To, Event }, ... }
	语义：对 Condition 为 function 的规则给出 warning（无法静态验证）
]]
function SkillModuleValidator.validateTransitions(skillModule, errors, warnings)
	local states = skillModule.States or {}
	local transitions = skillModule.Transitions
	if not transitions then
		return true -- 无 Transitions 则跳过
	end
	if type(transitions) ~= "table" then
		addError(errors, "Transitions 必须为 table")
		return false
	end
	local hasError = false
	for _, rule in ipairs(transitions) do
		if rule.From and not states[rule.From] then
			addError(errors, ("Transition From '%s' 不存在于 States"):format(tostring(rule.From)))
			hasError = true
		end
		if rule.To and not states[rule.To] then
			addError(errors, ("Transition To '%s' 不存在于 States"):format(tostring(rule.To)))
			hasError = true
		end
		-- B. Condition 吞噬：function 无法静态验证
		if type(rule.Condition) == "function" then
			addWarning(warnings, SkillModuleValidator.WARNING_CODES.TransitionFuncCondition,
				("Transition %s->%s Event=%s 使用 function Condition，无法静态验证"):format(
					tostring(rule.From), tostring(rule.To), tostring(rule.Event)),
				SkillModuleValidator.WARNING_SEVERITY.warn)
		end
	end
	return not hasError
end

--[[
	校验 StateOrder 包含所有参与窗口判断的状态
	若 StateOrder 存在，则其中每个状态名必须在 States 中存在
	若 States 存在且 StateOrder 存在，则 StateOrder 应覆盖 States 中所有非终态（用于 InWindow 等）
]]
function SkillModuleValidator.validateStateOrder(skillModule, errors)
	local stateOrder = skillModule.StateOrder
	if not stateOrder then
		return true -- 无 StateOrder 则跳过（非弹道类技能可能不需要）
	end
	if type(stateOrder) ~= "table" then
		addError(errors, "StateOrder 必须为 table")
		return false
	end
	local states = skillModule.States or {}
	local hasError = false
	for stateName, _ in pairs(stateOrder) do
		if not states[stateName] then
			addError(errors, ("StateOrder 引用状态 '%s' 不存在于 States"):format(tostring(stateName)))
			hasError = true
		end
	end
	return not hasError
end

--[[
	子领域校验：状态图流程正确性（可达性、终态、死状态、StateOrder 倒挂、优先级冲突）
	委托 SkillStateMachine.validateStateGraph
]]
function SkillModuleValidator.validateStateGraph(skillModule, errors, _warnings)
	if not skillModule.States or not skillModule.InitialState then
		return
	end
	SkillStateMachine.validateStateGraph(skillModule, errors)
end

--[[
	StateActions：按状态挂载客户端 SkillAction，键须存在于 States；action 须为 SkillAction 模块名
]]
function SkillModuleValidator.validateStateActions(skillModule, errors)
	local sa = skillModule.StateActions
	if sa == nil then
		return true
	end
	if type(sa) ~= "table" then
		addError(errors, "StateActions 必须为 table")
		return false
	end
	local states = skillModule.States
	local skillFolder = script.Parent.SkillAction
	for stateKey, rows in pairs(sa) do
		if type(stateKey) ~= "string" then
			addError(errors, ("StateActions 状态键必须为 string，当前为 %s"):format(tostring(stateKey)))
		elseif not states or not states[stateKey] then
			addError(errors, ("StateActions['%s'] 不是合法状态名"):format(stateKey))
		end
		if type(rows) ~= "table" then
			addError(errors, ("StateActions['%s'] 必须为数组"):format(tostring(stateKey)))
		else
			for i, row in ipairs(rows) do
				if type(row) ~= "table" then
					addError(errors, ("StateActions['%s'][%d] 必须为 table"):format(stateKey, i))
				elseif type(row.action) ~= "string" or row.action == "" then
					addError(errors, ("StateActions['%s'][%d].action 非法"):format(stateKey, i))
				else
					local mod = skillFolder:FindFirstChild(row.action)
					if not mod or not mod:IsA("ModuleScript") then
						addError(errors, ("StateActions['%s'][%d] 未知 action '%s'"):format(stateKey, i, row.action))
					end
				end
			end
		end
	end
	return true
end

local AnimationPlaySide = require(script.Parent.AnimationPlaySide)

--[[
	animationPlaySide：可选 "Client" | "Server"，仅对非玩家主体在运行时生效
]]
function SkillModuleValidator.validateAnimationPlaySide(skillModule, errors)
	local side = skillModule.animationPlaySide
	if side == nil then
		return true
	end
	if not AnimationPlaySide.isValidConfiguredSide(side) then
		addError(errors, ('animationPlaySide 必须为 "Client" 或 "Server"，当前为 %s'):format(tostring(side)))
	end
	return true
end

--[[
	校验 ChainWindows 结构及引用的状态
	语义：open.order < close.order；同状态时 open.elapsed <= close.elapsed；窗口不能跨越终态
	多段技能需显式指定 baseSkillName 或 baseSkillIndex，只校验归属的那一段，避免全遍历误判

	@param groupModule table GroupSkill 模块
	@param resolveBaseSkill function(baseSkillName) -> baseSkillModule? 解析基础技能模块，用于校验窗口状态
]]
function SkillModuleValidator.validateWindows(groupModule, errors, resolveBaseSkill)
	local chainWindows = groupModule.ChainWindows
	if not chainWindows then
		return true -- 无 ChainWindows 则跳过
	end
	if type(chainWindows) ~= "table" then
		addError(errors, "ChainWindows 必须为 table")
		return false
	end
	local skillList = groupModule.Skill or {}
	local skillCount = 0
	for k in pairs(skillList) do
		if type(k) == "number" and k > 0 then
			skillCount = math.max(skillCount, k)
		end
	end
	local hasError = false
	for windowName, window in pairs(chainWindows) do
		if not window or type(window) ~= "table" then
			addError(errors, ("ChainWindows['%s'] 配置缺失"):format(tostring(windowName)))
			hasError = true
			continue
		end
		local open = window.open
		local close = window.close
		if not open or type(open) ~= "table" then
			addError(errors, ("ChainWindows['%s'].open 缺失"):format(tostring(windowName)))
			hasError = true
		elseif not open.state then
			addError(errors, ("ChainWindows['%s'].open.state 缺失"):format(tostring(windowName)))
			hasError = true
		end
		if not close or type(close) ~= "table" then
			addError(errors, ("ChainWindows['%s'].close 缺失"):format(tostring(windowName)))
			hasError = true
		elseif not close.state then
			addError(errors, ("ChainWindows['%s'].close.state 缺失"):format(tostring(windowName)))
			hasError = true
		end
		-- 确定归属 BaseSkill：baseSkillName > baseSkillIndex > 单段时推断
		local baseSkillName = window.baseSkillName
		if not baseSkillName and type(window.baseSkillIndex) == "number" then
			local entry = skillList[window.baseSkillIndex]
			baseSkillName = entry and entry.baseSkillName
		end
		if not baseSkillName and skillCount == 1 then
			for _, entry in pairs(skillList) do
				if entry and entry.baseSkillName then
					baseSkillName = entry.baseSkillName
					break
				end
			end
		end
		if skillCount > 1 and not baseSkillName then
			addError(errors, ("ChainWindows['%s'] 缺少 baseSkillName 或 baseSkillIndex，多段技能需显式指定归属"):format(tostring(windowName)))
			hasError = true
		end
		-- 校验窗口引用的状态在归属 BaseSkill 的 StateOrder 中存在，且不能为终态
		if resolveBaseSkill and baseSkillName and open and open.state and close and close.state then
			local baseModule = resolveBaseSkill(baseSkillName)
			if baseModule and baseModule.StateOrder then
				if not baseModule.StateOrder[open.state] then
					addError(errors, ("ChainWindows['%s'].open.state '%s' 不存在于 %s.StateOrder"):format(
						tostring(windowName), tostring(open.state), tostring(baseSkillName)))
					hasError = true
				end
				if not baseModule.StateOrder[close.state] then
					addError(errors, ("ChainWindows['%s'].close.state '%s' 不存在于 %s.StateOrder"):format(
						tostring(windowName), tostring(close.state), tostring(baseSkillName)))
					hasError = true
				end
				local baseStates = baseModule.States or {}
				if baseStates[open.state] and baseStates[open.state].IsTerminal == true then
					addError(errors, ("ChainWindows['%s'].open.state '%s' 为终态，窗口不能以终态为起点"):format(
						tostring(windowName), tostring(open.state)))
					hasError = true
				end
				if baseStates[close.state] and baseStates[close.state].IsTerminal == true then
					addError(errors, ("ChainWindows['%s'].close.state '%s' 为终态，窗口不能以终态为终点"):format(
						tostring(windowName), tostring(close.state)))
					hasError = true
				end
				local openOrder = baseModule.StateOrder and baseModule.StateOrder[open.state]
				local closeOrder = baseModule.StateOrder and baseModule.StateOrder[close.state]
				if openOrder ~= nil and closeOrder ~= nil and type(openOrder) == "number" and type(closeOrder) == "number" then
					if openOrder > closeOrder then
						addError(errors, ("ChainWindows['%s'] open.state 顺序 %s >= close.state 顺序 %s，开闭倒挂"):format(
							tostring(windowName), tostring(openOrder), tostring(closeOrder)))
						hasError = true
					elseif openOrder == closeOrder then
						local openElapsed = (open.elapsed and type(open.elapsed) == "number") and open.elapsed or 0
						local closeElapsed = (close.elapsed and type(close.elapsed) == "number") and close.elapsed or 0
						if openElapsed > closeElapsed then
							addError(errors, ("ChainWindows['%s'] 同状态 open.elapsed=%s > close.elapsed=%s"):format(
								tostring(windowName), tostring(openElapsed), tostring(closeElapsed)))
							hasError = true
						end
					end
				end
			end
		end
	end
	return not hasError
end

--[[
	校验 Skill（DeriveList）结构：index 合法、condition 为函数
	语义：condition 为 function 时 warning；声明式 literal 为 true 时 warning（AlwaysTrue）
]]
function SkillModuleValidator.validateDeriveList(groupModule, errors, warnings)
	local skillList = groupModule.Skill
	if not skillList then
		addError(errors, "Skill 缺失")
		return false
	end
	if type(skillList) ~= "table" then
		addError(errors, "Skill 必须为 table")
		return false
	end
	local maxIndex = 0
	for k, _ in pairs(skillList) do
		if type(k) == "number" and k > maxIndex then
			maxIndex = k
		end
	end
	local hasError = false
	for index = 1, maxIndex do
		local entry = skillList[index]
		if not entry then
			addError(errors, ("Skill[%d] 缺失"):format(index))
			hasError = true
			continue
		end
		if not entry.baseSkillName or type(entry.baseSkillName) ~= "string" then
			addError(errors, ("Skill[%d].baseSkillName 缺失或非法"):format(index))
			hasError = true
		end
		if entry.condition ~= nil and type(entry.condition) ~= "function" and type(entry.condition) ~= "table" then
			addError(errors, ("Skill[%d].condition 必须为 function 或声明式 table"):format(index))
			hasError = true
		end
		-- B. Condition 吞噬：function 无法静态验证；声明式 literal=true 为 AlwaysTrue
		if type(entry.condition) == "function" then
			addWarning(warnings, SkillModuleValidator.WARNING_CODES.SkillFuncCondition,
				("Skill[%d] condition 为 function，无法静态验证"):format(index),
				SkillModuleValidator.WARNING_SEVERITY.block_production)
		elseif type(entry.condition) == "table" and entry.condition.type == "literal" and entry.condition.value == true then
			addWarning(warnings, SkillModuleValidator.WARNING_CODES.SkillLiteralTrueAlways,
				("Skill[%d] condition 为 literal=true，等价于 AlwaysTrue，可能覆盖后续条件"):format(index),
				SkillModuleValidator.WARNING_SEVERITY.block_production)
		end
	end
	return not hasError
end

-- 统计 GroupSkill 中 function condition 数量（ReleaseGate 用）
function SkillModuleValidator.countFunctionConditions(groupModule)
	local count = 0
	local skillList = groupModule and groupModule.Skill
	if type(skillList) ~= "table" then return 0 end
	for _, entry in pairs(skillList) do
		if entry and type(entry.condition) == "function" then
			count = count + 1
		end
	end
	return count
end

--[[
	校验 DamageProfiles 引用存在
	D. 引用完整性：hitboxConfig[].damageProfileId 必须存在于 DamageProfiles
]]
function SkillModuleValidator.validateDamageProfiles(skillModule, errors)
	local damageProfiles = skillModule.DamageProfiles
	if not damageProfiles then
		return true
	end
	if type(damageProfiles) ~= "table" then
		addError(errors, "DamageProfiles 必须为 table")
		return false
	end
	-- D. hitboxConfig.damageProfileId 引用校验
	local hitboxConfig = skillModule.hitboxConfig
	if type(hitboxConfig) == "table" then
		for i, entry in ipairs(hitboxConfig) do
			if type(entry) == "table" and type(entry.damageProfileId) == "string" then
				local id = entry.damageProfileId
				if not damageProfiles[id] then
					addError(errors, ("hitboxConfig[%d].damageProfileId '%s' 不存在于 DamageProfiles"):format(i, id))
				end
			end
		end
	end
	return true
end

--[[
	校验 ProjectileProfiles 引用存在（若模块有该字段）
	D. 引用完整性：projectileProfileId、impactProfileId、visualProfileId 如存在则校验
]]
function SkillModuleValidator.validateProjectileProfiles(skillModule, errors)
	local projectileProfiles = skillModule.ProjectileProfiles
	if not projectileProfiles then
		return true
	end
	if type(projectileProfiles) ~= "table" then
		addError(errors, "ProjectileProfiles 必须为 table")
		return false
	end
	-- D. 顶层 projectileProfileId 等引用校验（若模块有该字段）
	for _, key in ipairs({ "projectileProfileId", "impactProfileId", "visualProfileId" }) do
		local profileId = skillModule[key]
		if type(profileId) == "string" and profileId ~= "" then
			if not projectileProfiles[profileId] then
				addError(errors, ("%s '%s' 不存在于 ProjectileProfiles"):format(key, profileId))
			end
		end
	end
	return true
end

--[[
	校验 BaseSkill 模块
	@param skillModule table 技能模块
	@param options table? { skillName = string }
	@return boolean ok, table errors
]]
function SkillModuleValidator.validateBaseSkill(skillModule, options)
	local errors = {}
	local warnings = (options and options.warnings) or {}
	local name = (options and options.skillName) or "Unknown"
	local moduleScriptName = options and options.moduleScriptName
	if type(moduleScriptName) == "string" then
		validateModuleNameConsistency(moduleScriptName, skillModule, errors)
	end
	-- 范式约束：必须定义 States + InitialState，缺一则 fail-fast；状态机校验无条件执行
	SkillModuleValidator.validateStates(skillModule, errors)
	SkillModuleValidator.validateInitialState(skillModule, errors)
	SkillModuleValidator.validateTransitions(skillModule, errors, warnings)
	SkillModuleValidator.validateStateOrder(skillModule, errors)
	SkillModuleValidator.validateStateGraph(skillModule, errors, warnings)
	SkillModuleValidator.validateStateActions(skillModule, errors)
	SkillModuleValidator.validateAnimationPlaySide(skillModule, errors)
	SkillModuleValidator.validateDamageProfiles(skillModule, errors)
	SkillModuleValidator.validateProjectileProfiles(skillModule, errors)
	if #errors > 0 then
		return false, errors, warnings
	end
	local suppressions = options and options.suppressions
	local env = options and options.env
	local blockErrors = {}
	for _, w in ipairs(warnings) do
		if isWarningSuppressed(w, suppressions) then
			-- 已豁免，跳过
		elseif shouldBlockInProduction(w, env) then
			table.insert(blockErrors, formatWarning(w))
		else
			warn(("[SkillModuleValidator] %s: %s"):format(name, formatWarning(w)))
		end
	end
	if #blockErrors > 0 then
		return false, blockErrors, warnings
	end
	return true, {}, warnings
end

--[[
	发布用严格校验：warning 视为 error，阻断发布
	@return boolean ok, table errors
]]
function SkillModuleValidator.validateBaseSkillStrict(skillModule, options)
	local ok, errs, warnings = SkillModuleValidator.validateBaseSkill(skillModule, options)
	if not ok then
		return false, errs
	end
	if warnings and #warnings > 0 then
		local suppressions = options and options.suppressions
		local errStrs = {}
		for _, w in ipairs(warnings) do
			if not isWarningSuppressed(w, suppressions) then
				table.insert(errStrs, formatWarning(w))
			end
		end
		if #errStrs > 0 then
			return false, errStrs
		end
	end
	return true, {}
end

--[[
	校验 GroupSkill 模块
	@param groupModule table 组技能模块
	@param options table? { skillName = string, resolveBaseSkill = function(name)->module? }
	@return boolean ok, table errors
]]
function SkillModuleValidator.validateGroupSkill(groupModule, options)
	local errors = {}
	local warnings = (options and options.warnings) or {}
	local name = (options and options.skillName) or "Unknown"
	local moduleScriptName = options and options.moduleScriptName
	if type(moduleScriptName) == "string" then
		validateModuleNameConsistency(moduleScriptName, groupModule, errors)
	end
	local function checkOptionalPriorityNumber(path: string, v: any)
		if v ~= nil and type(v) ~= "number" then
			table.insert(errors, path .. " 必须为 number")
		end
	end
	checkOptionalPriorityNumber("InterruptionPriority", groupModule.InterruptionPriority)
	checkOptionalPriorityNumber("PriorityInterruption", groupModule.PriorityInterruption)
	if groupModule.Data and type(groupModule.Data) == "table" then
		local d = groupModule.Data :: any
		checkOptionalPriorityNumber("Data.InterruptionPriority", d.InterruptionPriority)
		checkOptionalPriorityNumber("Data.interruptionPriority", d.interruptionPriority)
	end
	SkillModuleValidator.validateDeriveList(groupModule, errors, warnings)
	SkillModuleValidator.validateWindows(groupModule, errors, options and options.resolveBaseSkill)
	if #errors > 0 then
		return false, errors, warnings
	end
	local suppressions = options and options.suppressions
	local env = options and options.env
	local blockErrors = {}
	for _, w in ipairs(warnings) do
		if isWarningSuppressed(w, suppressions) then
			-- 已豁免，跳过
		elseif shouldBlockInProduction(w, env) then
			table.insert(blockErrors, formatWarning(w))
		else
			warn(("[SkillModuleValidator] %s: %s"):format(name, formatWarning(w)))
		end
	end
	if #blockErrors > 0 then
		return false, blockErrors, warnings
	end
	return true, {}, warnings
end

--[[
	发布用严格校验：warning 视为 error，阻断发布
]]
function SkillModuleValidator.validateGroupSkillStrict(groupModule, options)
	local ok, errs, warnings = SkillModuleValidator.validateGroupSkill(groupModule, options)
	if not ok then
		return false, errs
	end
	if warnings and #warnings > 0 then
		local suppressions = options and options.suppressions
		local errStrs = {}
		for _, w in ipairs(warnings) do
			if not isWarningSuppressed(w, suppressions) then
				table.insert(errStrs, formatWarning(w))
			end
		end
		if #errStrs > 0 then
			return false, errStrs
		end
	end
	return true, {}
end

--[[
	发布用统一校验入口（生产环境必走 strict，warning 未豁免则 fail）
	@param kind "BaseSkill" | "GroupSkill"
	@param moduleValue table 技能模块
	@param options table { skillName, moduleScriptName?, resolveBaseSkill?, env = "production", suppressions? }
	@return boolean ok, table errors
]]
function SkillModuleValidator.validateForRelease(kind, moduleValue, options)
	if kind == "BaseSkill" then
		return SkillModuleValidator.validateBaseSkillStrict(moduleValue, options)
	elseif kind == "GroupSkill" then
		return SkillModuleValidator.validateGroupSkillStrict(moduleValue, options)
	end
	error("unknown validation kind: " .. tostring(kind))
end

--[[
	统一入口：根据模块类型自动选择校验
	@param skillModule table 技能模块
	@param options table? { skillName, moduleType = "BaseSkill"|"GroupSkill", resolveBaseSkill }
	@return boolean ok, table errors
]]
function SkillModuleValidator.validate(skillModule, options)
	if not skillModule or type(skillModule) ~= "table" then
		return false, { "skillModule 必须为 table" }
	end
	local moduleType = options and options.moduleType
	if moduleType == "GroupSkill" then
		return SkillModuleValidator.validateGroupSkill(skillModule, options)
	end
	-- 默认按 BaseSkill 校验
	return SkillModuleValidator.validateBaseSkill(skillModule, options)
end

--[[
	校验失败时处理：开发环境 error，生产环境可 warn + 返回
	@param skillName string
	@param errors table
	@param strict boolean? 若 true 则 error，否则 warn
]]
function SkillModuleValidator.failOnError(skillName, errors, strict)
	if not errors or #errors == 0 then return end
	local msg = ("[SkillModuleValidator] %s 校验失败:\n  "):format(tostring(skillName or "?")) .. table.concat(errors, "\n  ")
	if strict ~= false then
		error(msg, 2)
	else
		warn(msg)
	end
end

return SkillModuleValidator
