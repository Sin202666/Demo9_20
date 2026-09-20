--[[
	SkillAimLead — 瞄准预判（水平面）

	配置写在「组技能」GroupSkillModule 的 module.Data 中（非子技能 SkillModule）：
	- aimLeadEnabled：true / 1 时启用
	- aimLeadSeconds：预判未来多少秒的目标位置（秒，>0）
	- aimLeadMaxStuds：可选，最大提前量长度（Studs），防止过远

	与投掷类技能中仅用 XZ、Y 与起点对齐的表现一致，速度取 AssemblyLinearVelocity 的水平分量。
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SkillAimLead = {}

local function isLeadEnabled(skillData: any): boolean
	if type(skillData) ~= "table" then
		return false
	end
	local e = skillData.aimLeadEnabled
	return e == true or e == 1
end

local function getLeadSeconds(skillData: any): number
	if type(skillData) ~= "table" then
		return 0
	end
	local t = skillData.aimLeadSeconds
	if type(t) ~= "number" or t <= 0 then
		return 0
	end
	return t
end

local function clampHorizontal(delta: Vector3, maxStuds: number?): Vector3
	local h = Vector3.new(delta.X, 0, delta.Z)
	local m = h.Magnitude
	if m < 1e-6 then
		return h
	end
	local cap = maxStuds
	if type(cap) == "number" and cap > 0 and m > cap then
		return h.Unit * cap
	end
	return h
end

--- 根据技能 Data 与瞄准部件，计算水平预判后的世界坐标（无预判时返回 aimPart.Position）
function SkillAimLead.computeHorizontalAimPoint(aimPart: BasePart?, fallbackPosition: Vector3, skillData: any?): Vector3
	if not aimPart then
		return fallbackPosition
	end
	if not isLeadEnabled(skillData) then
		return aimPart.Position
	end
	local leadT = getLeadSeconds(skillData)
	if leadT <= 0 then
		return aimPart.Position
	end
	local vel = aimPart.AssemblyLinearVelocity
	local horizVel = Vector3.new(vel.X, 0, vel.Z)
	local delta = horizVel * leadT
	local maxStuds = nil
	if type(skillData) == "table" and type(skillData.aimLeadMaxStuds) == "number" and skillData.aimLeadMaxStuds > 0 then
		maxStuds = skillData.aimLeadMaxStuds
	end
	delta = clampHorizontal(delta, maxStuds)
	return aimPart.Position + delta
end

--- 按组技能名读取 GroupSkillModule 下模块的 module.Data 中的预判字段（失败返回 nil）
function SkillAimLead.getDataForGroupAbility(groupSkillName: string): any?
	if type(groupSkillName) ~= "string" or groupSkillName == "" then
		return nil
	end
	local cc = ReplicatedStorage:FindFirstChild("ClientSideCode")
	local ss = cc and cc:FindFirstChild("SystemSkill")
	local groupFolder = ss and ss:FindFirstChild("GroupSkillModule")
	if not groupFolder then
		return nil
	end
	local gScript = groupFolder:FindFirstChild(groupSkillName)
	if not gScript or not gScript:IsA("ModuleScript") then
		return nil
	end
	local okG, groupMod = pcall(require, gScript)
	if not okG or type(groupMod) ~= "table" then
		return nil
	end
	local data = groupMod.Data
	if type(data) ~= "table" then
		return nil
	end
	return data
end

return SkillAimLead
