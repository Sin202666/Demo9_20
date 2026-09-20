--[[
	流程一致性校验验收用例
	故意制造错误配置，验证 SkillModuleValidator.validateBaseSkill / validateWindows 能全部抓出

	运行方式：在 Studio 中 require 本模块并调用 runAll()
]]

local SkillModuleValidator = require(script.Parent.SkillModuleValidator)
local SkillEventConst = require(script.Parent.SkillEventConst)
local EVT = SkillEventConst

local CASES = {
	{ name = "1. 不可达状态" },
	{ name = "2. 非终态无出口" },
	{ name = "3. 顺序倒挂" },
	{ name = "4. 终态有出边" },
	{ name = "5a. Duration 无 StateTimeout 出边" },
	{ name = "5b. window 标记到终态" },
	{ name = "6. open > close 开闭倒挂" },
	{ name = "7. profile 引用缺失" },
	{ name = "8. condition 永真吞噬 warning", kind = "warning-expected" },
}

local function runAll()
	local passed = 0
	local failed = 0

	-- 1. 不可达状态：Orphan 无入边，从 InitialState 无法到达
	do
		local module = {
			States = {
				Startup = { Duration = 0.5 },
				Orphan = { Duration = 0 },
				Finished = { Duration = 0, IsTerminal = true },
				Interrupted = { Duration = 0, IsTerminal = true },
			},
			InitialState = "Startup",
			Transitions = {
				{ From = "Startup", To = "Finished", Event = EVT.StateTimeout },
				{ From = "Startup", To = "Interrupted", Event = EVT.Interrupt },
			},
		}
		local ok = SkillModuleValidator.validateBaseSkill(module, { skillName = "UnreachableState" })
		if not ok then
			passed = passed + 1
			print(("[FlowConsistencyValidationTest] %s: 通过（已抓出）"):format(CASES[1].name))
		else
			failed = failed + 1
			warn(("[FlowConsistencyValidationTest] %s: 失败（未抓出 Orphan）"):format(CASES[1].name))
		end
	end

	-- 2. 非终态无出口：Stuck 无 Duration 超时且无出边
	do
		local module = {
			States = {
				Startup = { Duration = 0.5 },
				Stuck = { Duration = -1 },
				Finished = { Duration = 0, IsTerminal = true },
				Interrupted = { Duration = 0, IsTerminal = true },
			},
			InitialState = "Startup",
			Transitions = {
				{ From = "Startup", To = "Stuck", Event = EVT.StateTimeout },
				{ From = "Startup", To = "Interrupted", Event = EVT.Interrupt },
			},
		}
		local ok = SkillModuleValidator.validateBaseSkill(module, { skillName = "NoExitState" })
		if not ok then
			passed = passed + 1
			print(("[FlowConsistencyValidationTest] %s: 通过（已抓出）"):format(CASES[2].name))
		else
			failed = failed + 1
			warn(("[FlowConsistencyValidationTest] %s: 失败（未抓出 Stuck）"):format(CASES[2].name))
		end
	end

	-- 3. 顺序倒挂：Recovery -> Finished，但 order[Finished] < order[Recovery]
	do
		local module = {
			States = {
				Startup = { Duration = 0.5 },
				Recovery = { Duration = 0.2 },
				Finished = { Duration = 0, IsTerminal = true },
				Interrupted = { Duration = 0, IsTerminal = true },
			},
			InitialState = "Startup",
			StateOrder = { Startup = 1, Recovery = 2, Finished = 1, Interrupted = 4 },
			Transitions = {
				{ From = "Startup", To = "Recovery", Event = EVT.StateTimeout },
				{ From = "Recovery", To = "Finished", Event = EVT.StateTimeout },
				{ From = "Startup", To = "Interrupted", Event = EVT.Interrupt },
			},
		}
		local ok = SkillModuleValidator.validateBaseSkill(module, { skillName = "OrderInversion" })
		if not ok then
			passed = passed + 1
			print(("[FlowConsistencyValidationTest] %s: 通过（已抓出）"):format(CASES[3].name))
		else
			failed = failed + 1
			warn(("[FlowConsistencyValidationTest] %s: 失败（未抓出 order[Finished]=1 < order[Recovery]=2）"):format(CASES[3].name))
		end
	end

	-- 4. 终态有出边
	do
		local module = {
			States = {
				Startup = { Duration = 0.5 },
				Finished = { Duration = 0, IsTerminal = true },
				Interrupted = { Duration = 0, IsTerminal = true },
			},
			InitialState = "Startup",
			Transitions = {
				{ From = "Startup", To = "Finished", Event = EVT.StateTimeout },
				{ From = "Finished", To = "Startup", Event = "Resurrect" },
				{ From = "Startup", To = "Interrupted", Event = EVT.Interrupt },
			},
		}
		local ok = SkillModuleValidator.validateBaseSkill(module, { skillName = "TerminalHasOutgoing" })
		if not ok then
			passed = passed + 1
			print(("[FlowConsistencyValidationTest] %s: 通过（已抓出）"):format(CASES[4].name))
		else
			failed = failed + 1
			warn(("[FlowConsistencyValidationTest] %s: 失败（未抓出）"):format(CASES[4].name))
		end
	end

	-- 5a. Duration >= 0 但无 StateTimeout 出边（半失效配置）
	do
		local module = {
			States = {
				Startup = { Duration = 0.5 },
				Waiting = { Duration = 1 },
				Finished = { Duration = 0, IsTerminal = true },
				Interrupted = { Duration = 0, IsTerminal = true },
			},
			InitialState = "Startup",
			Transitions = {
				{ From = "Startup", To = "Waiting", Event = "Manual" },
				{ From = "Waiting", To = "Finished", Event = "Manual" },
				{ From = "Startup", To = "Interrupted", Event = EVT.Interrupt },
			},
		}
		local ok = SkillModuleValidator.validateBaseSkill(module, { skillName = "DurationNoStateTimeout" })
		if not ok then
			passed = passed + 1
			print(("[FlowConsistencyValidationTest] %s: 通过（已抓出）"):format(CASES[5].name))
		else
			failed = failed + 1
			warn(("[FlowConsistencyValidationTest] %s: 失败（未抓出）"):format(CASES[5].name))
		end
	end

	-- 5b. window 标记到终态（validateWindows）
	do
		local magicMissileModule = {
			States = {
				Startup = { Duration = 0.5 },
				ProjectileFlying = { Duration = -1 },
				Recovery = { Duration = 0.2 },
				Finished = { Duration = 0, IsTerminal = true },
				Interrupted = { Duration = 0, IsTerminal = true },
			},
			StateOrder = { Startup = 1, ProjectileFlying = 2, Recovery = 3, Finished = 4, Interrupted = 5 },
		}
		local groupModule = {
			Skill = { [1] = { baseSkillName = "MagicMissile1" } },
			ChainWindows = {
				BadWindow = { open = { state = "ProjectileFlying", elapsed = 0 }, close = { state = "Finished", elapsed = 0 } },
			},
		}
		local ok, errs = SkillModuleValidator.validateGroupSkill(groupModule, {
			resolveBaseSkill = function() return magicMissileModule end,
		})
		if not ok and errs and #errs > 0 then
			passed = passed + 1
			print(("[FlowConsistencyValidationTest] %s: 通过（已抓出）"):format(CASES[6].name))
		else
			failed = failed + 1
			warn(("[FlowConsistencyValidationTest] %s: 失败（未抓出 close.state=Finished）"):format(CASES[6].name))
		end
	end

	-- 6. open > close 开闭顺序倒挂
	do
		local baseModule = {
			States = {
				Startup = { Duration = 0.5 },
				ProjectileFlying = { Duration = -1 },
				Recovery = { Duration = 0.2 },
				Finished = { Duration = 0, IsTerminal = true },
				Interrupted = { Duration = 0, IsTerminal = true },
			},
			StateOrder = { Startup = 1, ProjectileFlying = 2, Recovery = 3, Finished = 4, Interrupted = 5 },
		}
		local groupModule = {
			Skill = { [1] = { baseSkillName = "TestSkill" } },
			ChainWindows = {
				BadOrder = {
					open = { state = "Recovery", elapsed = 0 },
					close = { state = "ProjectileFlying", elapsed = 0 },
				},
			},
		}
		local ok = SkillModuleValidator.validateGroupSkill(groupModule, {
			resolveBaseSkill = function() return baseModule end,
		})
		if not ok then
			passed = passed + 1
			print(("[FlowConsistencyValidationTest] %s: 通过（已抓出）"):format(CASES[7].name))
		else
			failed = failed + 1
			warn(("[FlowConsistencyValidationTest] %s: 失败（未抓出）"):format(CASES[7].name))
		end
	end

	-- 7. profile 引用缺失（damageProfileId）
	do
		local module = {
			hitboxConfig = {
				{ HitboxIndex = 1, damageProfileId = "MissingProfile" },
			},
			DamageProfiles = { ValidOnly = {} },
		}
		local ok = SkillModuleValidator.validateBaseSkill(module, { skillName = "ProfileRefMissing" })
		if not ok then
			passed = passed + 1
			print(("[FlowConsistencyValidationTest] %s: 通过（已抓出）"):format(CASES[8].name))
		else
			failed = failed + 1
			warn(("[FlowConsistencyValidationTest] %s: 失败（未抓出）"):format(CASES[8].name))
		end
	end

	-- 8. condition 永真吞噬（literal=true warning）
	do
		local warnings = {}
		local groupModule = {
			Skill = {
				[1] = { baseSkillName = "Skill1", condition = { type = "literal", value = true } },
				[2] = { baseSkillName = "Skill2", condition = { type = "literal", value = false } },
			},
		}
		local ok = SkillModuleValidator.validateGroupSkill(groupModule, { skillName = "AlwaysTrue", warnings = warnings })
		if ok and #warnings > 0 then
			passed = passed + 1
			print(("[FlowConsistencyValidationTest] %s: 通过（已产生）"):format(CASES[9].name))
		elseif ok then
			failed = failed + 1
			warn(("[FlowConsistencyValidationTest] %s: 失败（未产生 warning）"):format(CASES[9].name))
		else
			failed = failed + 1
			warn(("[FlowConsistencyValidationTest] %s: 失败（校验报错）"):format(CASES[9].name))
		end
	end

	print(("[FlowConsistencyValidationTest] 完成: %d 通过, %d 失败"):format(passed, failed))
	return passed, failed
end

return {
	runAll = runAll,
}
