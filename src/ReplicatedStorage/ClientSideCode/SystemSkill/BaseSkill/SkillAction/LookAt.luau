--[[
	朝向目标行为
	支持平滑过渡：优先朝向锁定目标 > 技能释放时记录的目标 > 鼠标位置
	NPC / 召唤物等非玩家主体由其它系统负责朝向（如服务端 NPCCombatFacing），此处不触发
]]
local SkillActionControl = require(script.Parent.Parent.SkillActionControl)
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local HumanModule = Utils.HumanModule
local GetData = Utils.GetData

local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local module = {}

module.isReleasePlayerOnly = true

--- 若为 true：仅 characterType == "Player" 的施法会创建本 Action（怪物等主体在 SkillAction / SkillStateActions 层直接跳过）
module.playerSubjectOnly = true

local BLEND_FACTOR = 0.25

-- 其他玩家施法时本机也会跑 SkillAction；改 LocalPlayer 移速/属性仅适用于施法者本人
local function isLocalPlayerCaster(baseSkill: any): boolean
	if not baseSkill or not LocalPlayer then
		return false
	end
	if baseSkill.characterType ~= "Player" then
		return false
	end
	return baseSkill.characterId == LocalPlayer.UserId
end

--[[
	获取当前期望的朝向目标位置（世界坐标）
	优先级：NowTargetCurrent（锁定目标） > skillInputData.targetCF（释放时目标） > 鼠标位置
]]
local function getDesiredLookTargetPos(baseSkill): Vector3?
	local Character = LocalPlayer.Character
	if not Character or not Character:FindFirstChild("HumanoidRootPart") then
		return nil
	end
	local charPos = Character.HumanoidRootPart:GetPivot().Position

	local NowTargetCurrent = ReplicatedStorage:FindFirstChild("NowTargetCurrent")
	if GetData.GetSetting(LocalPlayer,"AILock") == 1 and NowTargetCurrent and NowTargetCurrent.Value and NowTargetCurrent.Value.Parent and not HumanModule.GetIsShiftLocked() then
		local pos = NowTargetCurrent.Value.Position
		return Vector3.new(pos.X, charPos.Y, pos.Z)
	end

	if baseSkill.skillInputData and baseSkill.skillInputData.targetCF then
		local pos = baseSkill.skillInputData.targetCF.Position
		return Vector3.new(pos.X, charPos.Y, pos.Z)
	end

	local mouse = LocalPlayer:GetMouse()
	local finish = mouse.Hit.Position
	return Vector3.new(finish.X, charPos.Y, finish.Z)
end

function module:Create(actionInfo: any)
	self.actionInfo = actionInfo
	self.state = SkillActionControl.StateEnum.NoStart
	self.startTime = self.actionInfo.startTime
	self.overTime = self.actionInfo.overTime
	self.speedType = self.actionInfo.speedType
end

function module:Init()
	self.state = SkillActionControl.StateEnum.NoStart
end

function module:Run(cumulativeTime: number)
	if self.state ~= SkillActionControl.StateEnum.Play then
		return
	end

	local Character = LocalPlayer.Character
	if not Character or not Character:FindFirstChild("HumanoidRootPart") then
		return
	end

	local targetPos = getDesiredLookTargetPos(self.baseSkill)
	if not targetPos then
		return
	end

	if LocalPlayer:GetAttribute("IsShiftLocked") then
		return
	end

	local characterCf = Character.HumanoidRootPart:GetPivot()

	if (characterCf.Position - targetPos).Magnitude <= 0.1 then
		return
	end


	local desiredCF = CFrame.lookAt(characterCf.Position, targetPos)

	local curCF = Character.HumanoidRootPart.CFrame
	local blendedCF = curCF:Lerp(desiredCF, BLEND_FACTOR)
	Character.HumanoidRootPart.CFrame = CFrame.new(characterCf.Position) * blendedCF.Rotation
end

function module:Start(cumulativeTime: number)
	if self.speedType and isLocalPlayerCaster(self.baseSkill) then
		HumanModule.SetLocalPlayerSpeedAttribute(self.speedType, true)
		HumanModule.UpdateLocalPlayerSpeed(0.1)
		local Character = LocalPlayer.Character
		if Character then
			if not LocalPlayer:GetAttribute("IsShiftLocked") then
				local Humanoid:Humanoid = Character:FindFirstChild("Humanoid")
				if Humanoid then
					Humanoid.AutoRotate = false
				end
			end
		end
	end
end

function module:OnOver(cumulativeTime: number)
	if self.speedType and isLocalPlayerCaster(self.baseSkill) then
		HumanModule.SetLocalPlayerSpeedAttribute(self.speedType, false)
		HumanModule.UpdateLocalPlayerSpeed(0.1)
		local Character = LocalPlayer.Character
		if Character then
			local Humanoid:Humanoid = Character:FindFirstChild("Humanoid")
			if Humanoid then
				Humanoid.AutoRotate = true
			end
		end
	end
end

return module
