--[[
	技能数据 Schema 与归一化
	统一 Data 结构，集中默认值，避免散落在运行时代码

	type SkillData = {
		skillName: string,
		skillCooldown: number,
		skillElementType: number, -- Utils.EnumMgr.ElementTp
		-- 组技能可选：aimLeadEnabled / aimLeadSeconds / aimLeadMaxStuds（见 SkillAimLead）
		syncRadius: number?,
		hitConfirmRadius: number?,
		stopSyncRadius: number?,
		damageTipRadius: number?,
		suppressions: { [string]: boolean|string }?,
		clientObserverMaxDuration: number?,
		clientObserverFxTailSeconds: number?,
	}
]]

local SkillDataSchema = {}

-- 全局总闸：客户端表现预测（predictPresentation）；单技能仍须 Data.predictPresentation == true
-- 语义：无 Hitbox 本地模拟至 ControlOpenState/Phase1 后 hold，确认后 soft-merge（见 BaseSkillClient / GroupSkillClient）
-- 跨槽打断默认中档 50（GroupSkill* DEFAULT_INTERRUPTION_PRIORITY）；未声明 InterruptionPriority 的技能按 50
local GLOBAL_PREDICT_PRESENTATION_ENABLED = true

local DEFAULTS = {
	skillCooldown = 0,
	syncRadius = 120,
	damageTipRadius = 60,
}

-- schema 字段白名单（用于 extras 过滤）
local SCHEMA_KEYS = {
	skillName = true,
	skillCooldown = true,
	skillElementType = true,
	syncRadius = true,
	hitConfirmRadius = true,
	stopSyncRadius = true,
	damageTipRadius = true,
	suppressions = true,
	-- 组技能：是否启用客户端表现预测（须 GLOBAL 总闸 + 本字段均为 true；推至 ControlOpenState 后 hold）
	predictPresentation = true,
	-- 旁观者整次 cast 表现兜底超时（秒），>0 时覆盖自动估算
	clientObserverMaxDuration = true,
	-- 兜底时长末尾余量（秒），用于特效回收；并入服务端下发的 clientObserverMaxDuration 估算
	clientObserverFxTailSeconds = true,
}

--[[
	归一化技能数据，补全默认值
	@param data table? 原始 Data（nil 时返回全默认）
	@return table 归一化后的 Data（新表，含 schema 字段 + 原表 extras）
]]
function SkillDataSchema.normalizeSkillData(data)
	data = data or {}
	local syncRadius = type(data.syncRadius) == "number" and data.syncRadius or DEFAULTS.syncRadius
	local result = {
		skillName = data.skillName,
		skillCooldown = type(data.skillCooldown) == "number" and data.skillCooldown or DEFAULTS.skillCooldown,
		skillElementType = data.skillElementType,
		syncRadius = syncRadius,
		hitConfirmRadius = type(data.hitConfirmRadius) == "number" and data.hitConfirmRadius or syncRadius,
		stopSyncRadius = type(data.stopSyncRadius) == "number" and data.stopSyncRadius or syncRadius,
		damageTipRadius = type(data.damageTipRadius) == "number" and data.damageTipRadius or DEFAULTS.damageTipRadius,
		suppressions = data.suppressions,
		predictPresentation = GLOBAL_PREDICT_PRESENTATION_ENABLED and data.predictPresentation == true,
		clientObserverMaxDuration = type(data.clientObserverMaxDuration) == "number" and data.clientObserverMaxDuration > 0 and data.clientObserverMaxDuration or nil,
		clientObserverFxTailSeconds = type(data.clientObserverFxTailSeconds) == "number" and data.clientObserverFxTailSeconds >= 0 and data.clientObserverFxTailSeconds or nil,
	}
	for k, v in pairs(data) do
		if not SCHEMA_KEYS[k] then
			result[k] = v
		end
	end
	return result
end

return SkillDataSchema
