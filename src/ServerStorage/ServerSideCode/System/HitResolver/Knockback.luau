--[[
	Module: HitResolver.Knockback
	Description: 玩家角色击退下发（只经 SystemCharacterMotion）
	Author: 林奥宇
	Created: 2026-09-01
	Last Modified: 2026-09-01

	NPC 目标本期不走客户端电机。禁止 BodyVelocity 写角色。
	业务只经 Utils.HitResolver.applyHit，不要直接 require 本文件。
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Players = Utils.Players
local SystemCharacterMotion = Utils.SystemCharacterMotion

local BaseSkillFolder = game.ReplicatedStorage.ClientSideCode.SystemSkill.BaseSkill
local GetSkillData = require(BaseSkillFolder.GetSkillData)

local Knockback = {}

--[[
	对玩家角色下发击退：服 → 所有者客户端 CharacterMotion.ApplyKnockback。

	@param baseSkill any - 技能实例（取 skillCastId / skillID）
	@param hitbox any - 命中盒（取所有者与 _hitCounter）
	@param partParent Model - 受击角色 Model
	@param knockback number - 击退速度（stud/s）；<=0 则不下发
	@param hitboxWorldPosition Vector3? - 命中盒世界坐标（攻击者位缺失时兜底）
	@return nil
]]
function Knockback.dispatchPlayerKnockback(
	baseSkill: any,
	hitbox: any,
	partParent: Model,
	knockback: number,
	hitboxWorldPosition: Vector3?
)
	if type(knockback) ~= "number" or knockback <= 0 then
		return
	end
	local beHitPlr = Players:GetPlayerFromCharacter(partParent)
	if not beHitPlr then
		return
	end
	if not SystemCharacterMotion or not SystemCharacterMotion.FireKnockback then
		return
	end

	local targetHRP = partParent:FindFirstChild("HumanoidRootPart")
	local toPos = if targetHRP and targetHRP:IsA("BasePart")
		then targetHRP.Position
		else partParent:GetPivot().Position

	local fromPos: Vector3? = nil
	local attackerModel = GetSkillData.getCharacter(hitbox.hitboxOwnerType, hitbox.hitboxOwnerId)
	if attackerModel then
		local aHRP = attackerModel:FindFirstChild("HumanoidRootPart")
		if aHRP and aHRP:IsA("BasePart") then
			fromPos = aHRP.Position
		end
	end
	if typeof(fromPos) ~= "Vector3" and typeof(hitboxWorldPosition) == "Vector3" then
		fromPos = hitboxWorldPosition
	end
	if typeof(fromPos) ~= "Vector3" then
		fromPos = toPos
	end

	local dir = Vector3.new(toPos.X - fromPos.X, 0, toPos.Z - fromPos.Z)
	if dir.Magnitude < 1e-4 and attackerModel then
		local aHRP = attackerModel:FindFirstChild("HumanoidRootPart")
		if aHRP and aHRP:IsA("BasePart") then
			local look = aHRP.CFrame.LookVector
			dir = Vector3.new(look.X, 0, look.Z)
		end
	end
	if dir.Magnitude < 1e-4 then
		dir = Vector3.new(0, 0, -1)
	else
		dir = dir.Unit
	end

	local castId = tostring(baseSkill.skillCastId or baseSkill.skillID or "hit")
	local hitIndex = hitbox._hitCounter or 0
	local id = "Knock:" .. castId .. ":" .. tostring(hitIndex)

	SystemCharacterMotion.FireKnockback(beHitPlr, {
		id = id,
		direction = dir,
		speed = knockback,
	})
end

return Knockback
