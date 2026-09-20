--[[
	BaseSkillTargetFind - 基础技能目标查找
	职责：根据技能类型和目标类型，查找目标位置
	调用方：BaseSkillClient / BaseSkillServer
]]
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Class = require(game.ReplicatedFirst.AllSideCode.Class.Class)

local Players = Utils.Players

local BaseSkillTargetFind = {}

type SkillTarget = Class.SkillTarget

--[[
	查找目标位置
	@param targetData: SkillTarget - 目标数据
	@return targetCF: CFrame? - 目标位置
]]
function BaseSkillTargetFind.findTarget(targetData: SkillTarget?)
	if not targetData then
		return nil
	end

	local targetCF = nil

	if targetData.targetType == "Player" then
		local player = Players:GetPlayerByUserId(tonumber(targetData.targetCharacterID))
        if player and player.Character and player.Character.PrimaryPart then
			targetCF = player.Character.PrimaryPart.CFrame
        end
		
	elseif targetData.targetType == "NPC" then
		local monsterFolder = workspace:FindFirstChild("Monster")
		if not monsterFolder then
			return nil
		end
		local npc: Model? = monsterFolder:FindFirstChild(tostring(targetData.targetCharacterID)) :: Model?
		if npc and npc.PrimaryPart then
			targetCF = npc.PrimaryPart.CFrame
		end
		
	end
	
	return targetCF
	
end

return BaseSkillTargetFind
