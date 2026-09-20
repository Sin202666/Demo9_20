--[[
	语义型校验验收用例
	覆盖：Timeout 语义、Condition 吞噬、Window 开闭顺序、引用完整性

	运行方式：在 Studio 中 require 本模块并调用 runAll()
]]

local SkillModuleValidator = require(script.Parent.SkillModuleValidator)
local SkillEventConst = require(script.Parent.SkillEventConst)
local EVT = SkillEventConst

local function runAll()
	local passed = 0
	local failed = 0

	-- A. Timeout 语义：Duration >= 0 但无 StateTimeout 出边
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
		local ok = SkillModuleValidator.validateBaseSkill(module, { skillName = "NoStateTimeout" })
		if not ok then
			passed = passed + 1
			print("[SemanticValidationTest] A. Duration 无 StateTimeout 出边: 通过（已抓出）")
		else
			failed = failed + 1
			warn("[SemanticValidationTest] A. Duration 无 StateTimeout 出边: 失败（未抓出 Startup/Waiting）")
		end
	end

	-- B. Condition 吞噬：Skill[1] condition = function 应产生 warning（通过即算过，warn 会输出）
	do
		local warnings = {}
		local groupModule = {
			Skill = {
				[1] = { baseSkillName = "MagicMissile1", condition = function() return true end },
			},
		}
		local ok = SkillModuleValidator.validateGroupSkill(groupModule, { skillName = "FuncCondition", warnings = warnings })
		if ok and #warnings > 0 then
			passed = passed + 1
			print("[SemanticValidationTest] B. function condition warning: 通过（已产生 warning）")
		elseif ok then
			failed = failed + 1
			warn("[SemanticValidationTest] B. function condition warning: 失败（未产生 warning）")
		else
			failed = failed + 1
			warn("[SemanticValidationTest] B. function condition: 失败（校验报错）")
		end
	end

	-- C. Window 开闭顺序：open.order > close.order
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
			print("[SemanticValidationTest] C. Window 开闭顺序倒挂: 通过（已抓出）")
		else
			failed = failed + 1
			warn("[SemanticValidationTest] C. Window 开闭顺序倒挂: 失败（未抓出）")
		end
	end

	-- C2. Window 同状态 open.elapsed > close.elapsed
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
				BadElapsed = {
					open = { state = "ProjectileFlying", elapsed = 0.5 },
					close = { state = "ProjectileFlying", elapsed = 0.2 },
				},
			},
		}
		local ok = SkillModuleValidator.validateGroupSkill(groupModule, {
			resolveBaseSkill = function() return baseModule end,
		})
		if not ok then
			passed = passed + 1
			print("[SemanticValidationTest] C2. Window 同状态 elapsed 倒挂: 通过（已抓出）")
		else
			failed = failed + 1
			warn("[SemanticValidationTest] C2. Window 同状态 elapsed 倒挂: 失败（未抓出）")
		end
	end

	-- D. 引用完整性：hitboxConfig.damageProfileId 不存在于 DamageProfiles
	do
		local module = {
			hitboxConfig = {
				{ HitboxIndex = 1, damageProfileId = "NonExistentProfile" },
			},
			DamageProfiles = {
				ValidProfile = {},
			},
		}
		local ok = SkillModuleValidator.validateBaseSkill(module, { skillName = "BadDamageProfileRef" })
		if not ok then
			passed = passed + 1
			print("[SemanticValidationTest] D. damageProfileId 引用缺失: 通过（已抓出）")
		else
			failed = failed + 1
			warn("[SemanticValidationTest] D. damageProfileId 引用缺失: 失败（未抓出）")
		end
	end

	print(("[SemanticValidationTest] 完成: %d 通过, %d 失败"):format(passed, failed))
	return passed, failed
end

return {
	runAll = runAll,
}
