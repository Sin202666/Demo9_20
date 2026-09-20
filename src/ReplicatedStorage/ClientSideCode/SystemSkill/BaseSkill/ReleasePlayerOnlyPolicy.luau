--[[
	isReleasePlayerOnly 类 Action 在哪个客户端运行（客户端专用）

	玩家主体（施法者为 Player）：
	- 仅在「施法玩家本人」的客户端运行（操控权与本地预测一致，避免在别人客户端上锁本地角色等）

	怪物 / 非玩家主体（施法者 characterType ~= "Player"，如 NPC、Summon、自定义 EntityType）：
	- 技能实例由服务器同步到哪些客户端，就在哪些客户端对该施法者 Model 运行（全员/范围内可见）

	未设置 characterType 时：按非玩家主体处理（与各同步端展示一致，避免误跳过）

	个别 Action 还可声明 playerSubjectOnly（如 LookAt）：非玩家施法主体不创建，与 isReleasePlayerOnly 正交
]]

local Players = game:GetService("Players")

local module = {}

local LocalPlayer = Players.LocalPlayer

function module.isPlayerSubjectSkill(baseSkill): boolean
	return baseSkill.characterType == "Player"
end

--[[
	怪物及其它服务器驱动、需在多客户端展示施法者本身的技能主体（与 isPlayerSubjectSkill 互斥补充）
]]
function module.isMonsterOrSyncedNonPlayerSubjectSkill(baseSkill): boolean
	return not module.isPlayerSubjectSkill(baseSkill)
end

--[[
	当前客户端是否应实例化并执行带 isReleasePlayerOnly 的 SkillAction
]]
function module.shouldRunReleasePlayerOnlyActions(baseSkill): boolean
	if module.isPlayerSubjectSkill(baseSkill) then
		return LocalPlayer.UserId == baseSkill.characterId
	end
	return true
end

return module
