--[[
    技能同步统一日志工具
    用于联调时追踪 BaseSkillStarted / BaseSkillDerived / StopSkill 等关键事件
    格式: [SkillSync][技能名][Cast:xxx][Base:xxx][Client/Server] 事件名 [详情]
]]

local SkillSyncLog = {}

local SIDE_SERVER = "Server"
local SIDE_CLIENT = "Client"

--[[
    打印技能同步日志
    @param skillName string 技能名（groupSkillName 或 baseSkillName）
    @param skillCastId string? 施法实例 ID
    @param baseSkillInstanceId string? 基础技能实例 ID
    @param side "Server" | "Client"
    @param eventName string 事件名（如 BaseSkillStarted, BaseSkillDerived, StopSkill）
    @param details string? 可选详情（如 reason=Finished）
]]
function SkillSyncLog.log(skillName: string?, skillCastId: string?, baseSkillInstanceId: string?, side: "Server" | "Client", eventName: string, details: string?)
	local sn = skillName or "?"
	local cast = skillCastId or "?"
	local base = baseSkillInstanceId or "?"
	local sideStr = side == SIDE_SERVER and SIDE_SERVER or SIDE_CLIENT
	local detailStr = details and (" " .. details) or ""
	--print(string.format("[SkillSync][%s][Cast:%s][Base:%s][%s] %s%s", sn, cast, base, sideStr, eventName, detailStr))
end

return SkillSyncLog
