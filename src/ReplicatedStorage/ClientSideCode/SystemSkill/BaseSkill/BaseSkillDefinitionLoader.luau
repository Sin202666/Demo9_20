--[[
	BaseSkillDefinitionLoader - 技能定义加载器
	职责：找模块、require、validate、缓存 definition

	调用方：BaseSkillClient / BaseSkillServer 在 new() 时通过 load() 获取定义
]]

local SkillModuleValidator = require(script.Parent.SkillModuleValidator)

local BaseSkillDefinitionLoader = {}

-- 缓存：skillName -> { skillModule, skillName }
local _cache = {}

-- 模块目录（与 BaseSkillClient/Server 一致）
local function getBaseSkillFolder()
	return script.Parent.Parent.SkillModule
end

--[[
	加载技能定义
	@param skillName string 技能名称
	@return table { skillModule, skillName } 或 nil, errorMessage
]]
function BaseSkillDefinitionLoader.load(skillName)
	if _cache[skillName] then
		return _cache[skillName]
	end

	local folder = getBaseSkillFolder()
	local mod = folder:FindFirstChild(skillName)
	if not mod or not mod:IsA("ModuleScript") then
		return nil, ("技能模块 '%s' 未找到（目录或资源未同步）"):format(skillName)
	end

	local ok, result = pcall(require, mod)
	if not ok then
		return nil, ("技能模块 '%s' require 失败: %s"):format(skillName, tostring(result))
	end

	local validOk, validErrs = SkillModuleValidator.validateForRelease("BaseSkill", result, {
		skillName = skillName,
		moduleScriptName = mod.Name,
		env = "production",
		suppressions = nil,
	})
	if not validOk then
		SkillModuleValidator.failOnError(skillName, validErrs, true)
		local hasStatesErr = false
		for _, e in ipairs(validErrs or {}) do
			if type(e) == "string" and (e:find("States") or e:find("InitialState")) then
				hasStatesErr = true
				break
			end
		end
		return nil, hasStatesErr and "校验失败：仅支持状态机范式，必须定义 States + InitialState" or ("校验失败：%s"):format((validErrs and validErrs[1]) or "未知")
	end

	local definition = {
		skillModule = result,
		skillName = skillName,
	}
	_cache[skillName] = definition
	return definition
end

--[[
	清除缓存（测试或热重载用）
]]
function BaseSkillDefinitionLoader.clearCache()
	table.clear(_cache)
end

return BaseSkillDefinitionLoader
