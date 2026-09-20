--[[
	旁观者表现最大时长估算（服务端一次计算，经 BaseSkillStarted 下发客户端）
	- 组技能 Data.clientObserverMaxDuration > 0 时直接使用（策划覆盖）
	- 否则：各段 BaseSkill 取 skillTotalTime，否则对各 State.Duration 求和（非终态）+ 各段 visualFadeoutTime，最后 + Data.clientObserverFxTailSeconds
]]
local BaseSkillDefinitionLoader = require(script.Parent.BaseSkillDefinitionLoader)
local SkillDataSchema = require(script.Parent.SkillDataSchema)

local ClientObserverDurationEstimator = {}

local DEFAULT_TAIL = 0.5
local FALLBACK_SINGLE_SEGMENT = 30
local ABS_MIN = 2
local ABS_MAX = 180

local function sumStateDurations(skillModule: any): number
	local states = skillModule and skillModule.States
	if type(states) ~= "table" then
		return 0
	end
	local s = 0
	for _, cfg in pairs(states) do
		if type(cfg) == "table" and not cfg.IsTerminal then
			local d = cfg.Duration
			if type(d) == "number" and d > 0 then
				s += d
			end
		end
	end
	return s
end

local function segmentUpperBoundSeconds(baseSkillName: string): (number, number)
	local def = BaseSkillDefinitionLoader.load(baseSkillName)
	if not def or not def.skillModule then
		return FALLBACK_SINGLE_SEGMENT, 0
	end
	local m = def.skillModule
	local t = m.skillTotalTime
	if type(t) == "number" and t > 0 then
		local fade = m.visualFadeoutTime
		local fadeN = (type(fade) == "number" and fade > 0) and fade or 0
		return t, fadeN
	end
	local sumD = sumStateDurations(m)
	if sumD <= 0 then
		sumD = FALLBACK_SINGLE_SEGMENT
	end
	local fade = m.visualFadeoutTime
	local fadeN = (type(fade) == "number" and fade > 0) and fade or 0
	return sumD, fadeN
end

--[[
	@param groupSkillModule table 组技能 require 结果（含 Skill 列表与 Data）
	@return number 秒，已夹在 [ABS_MIN, ABS_MAX]
]]
function ClientObserverDurationEstimator.estimateForGroupSkill(groupSkillModule: any): number
	if type(groupSkillModule) ~= "table" then
		return ABS_MAX
	end
	local data = SkillDataSchema.normalizeSkillData(groupSkillModule.Data)
	local override = data.clientObserverMaxDuration
	if type(override) == "number" and override > 0 then
		return math.clamp(override, ABS_MIN, ABS_MAX)
	end
	local tail = data.clientObserverFxTailSeconds
	if type(tail) ~= "number" or tail < 0 then
		tail = DEFAULT_TAIL
	end
	local skillList = groupSkillModule.Skill
	if type(skillList) ~= "table" then
		return math.clamp(FALLBACK_SINGLE_SEGMENT + tail, ABS_MIN, ABS_MAX)
	end
	local total = 0
	for _, seg in skillList do
		if type(seg) == "table" and type(seg.baseSkillName) == "string" then
			local segT, fade = segmentUpperBoundSeconds(seg.baseSkillName)
			total += segT + fade
		end
	end
	if total <= 0 then
		total = FALLBACK_SINGLE_SEGMENT
	end
	total += tail
	return math.clamp(total, ABS_MIN, ABS_MAX)
end

return ClientObserverDurationEstimator
