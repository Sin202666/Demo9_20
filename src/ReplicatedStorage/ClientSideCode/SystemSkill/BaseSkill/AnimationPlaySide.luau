--[[
	技能 Action.Animation 播放端（怪物 / 召唤物等非玩家主体）

	- "Client"（默认）：在各同步客户端通过 SkillAction 播放（沿用 isReleasePlayerOnly 策略）
	- "Server"：仅在服务端 SkillAction 播放，客户端跳过 Animation，避免双播

	玩家主体（characterType == "Player"）忽略 animationPlaySide，始终在施法者客户端播放。
	空间镜像（characterType == "Mirror"）复用玩家技能 module（默认 Client 动画），须在服务端 SkillAction 驱动动作。
]]

local module = {}

local VALID_SIDES = {
	Client = true,
	Server = true,
}

function module.isPlayerSubjectSkill(baseSkill): boolean
	return baseSkill.characterType == "Player"
end

function module.isMirrorSubjectSkill(baseSkill): boolean
	return baseSkill.characterType == "Mirror"
end

function module.normalizeSide(raw: any): "Client" | "Server"
	if type(raw) ~= "string" then
		return "Client"
	end
	local key = string.gsub(raw, "^%s*(.-)%s*$", "%1")
	if string.lower(key) == "server" then
		return "Server"
	end
	return "Client"
end

function module.resolvePlaySide(skillModule: any): "Client" | "Server"
	if not skillModule then
		return "Client"
	end
	return module.normalizeSide(skillModule.animationPlaySide)
end

function module.shouldRunServerSkillAction(baseSkill): boolean
	if module.isPlayerSubjectSkill(baseSkill) then
		return false
	end
	if module.isMirrorSubjectSkill(baseSkill) then
		return true
	end
	return module.resolvePlaySide(baseSkill.skillModule) == "Server"
end

function module.shouldSkipClientAnimation(baseSkill): boolean
	return module.shouldRunServerSkillAction(baseSkill)
end

function module.isValidConfiguredSide(raw: any): boolean
	if raw == nil then
		return true
	end
	return VALID_SIDES[module.normalizeSide(raw)] == true
end

return module
