--[[
	BaseSkillExecutionContext - 技能执行上下文
	职责：持有 characterId/type、skillPower/skillPurity、skillCastId/instanceId/index、
	     releaseCF/targetCF、combatSeed、timing params 等

	调用方：BaseSkillClient / BaseSkillServer 在 new() 时创建，start/setSkillInputData 时更新
]]

local GetSkillData = require(script.Parent.GetSkillData)

local BaseSkillExecutionContext = {}

--[[
	创建执行上下文
	@param params table {
		characterId: number,
		characterType: "Player" | "NPC",
		skillPower: number?,
		skillPurity: number?,
		skillCastId: string?,
		baseSkillInstanceId: string?,
		activeBaseSkillIndex: number?,
		releaseCF: CFrame?,
		targetCF: CFrame?,
		moveDirectionStr: string?,
		combatSeed: number?,
		trackTargetId: any?,
		skillID: number?,
		mpTp: string?,
	}
	@return table context
]]
function BaseSkillExecutionContext.create(params)
	params = params or {}
	local ctx = {
		characterId = params.characterId,
		characterType = params.characterType,
		skillPower = params.skillPower or 1,
		skillPurity = params.skillPurity or 1,
		skillCastId = params.skillCastId,
		baseSkillInstanceId = params.baseSkillInstanceId,
		activeBaseSkillIndex = params.activeBaseSkillIndex,
		releaseCF = params.releaseCF,
		targetCF = params.targetCF,
		moveDirectionStr = params.moveDirectionStr,
		combatSeed = params.combatSeed,
		trackTargetId = params.trackTargetId,
		skillTargetData = params.skillTargetData,
		skillID = params.skillID,
		mpTp = params.mpTp,
		-- 派生字段
		character = nil,
		skillInputData = nil,
	}
	ctx.character = GetSkillData.getCharacter(ctx.characterType, ctx.characterId)
	ctx.skillInputData = {
		characterId = ctx.characterId,
		characterType = ctx.characterType,
		releaseCF = ctx.releaseCF,
		targetCF = ctx.targetCF,
		moveDirectionStr = ctx.moveDirectionStr,
		character = ctx.character,
		skillCastId = ctx.skillCastId,
		baseSkillInstanceId = ctx.baseSkillInstanceId,
		activeBaseSkillIndex = ctx.activeBaseSkillIndex,
		trackTargetId = ctx.trackTargetId,
		skillTargetData = ctx.skillTargetData,
	}
	return ctx
end

--[[
	刷新 character 引用（characterId/characterType 变更时）
]]
function BaseSkillExecutionContext.refreshCharacter(ctx)
	ctx.character = GetSkillData.getCharacter(ctx.characterType, ctx.characterId)
	if ctx.skillInputData then
		ctx.skillInputData.character = ctx.character
	end
end

--[[
	更新上下文（start / setSkillInputData 时写入）
]]
function BaseSkillExecutionContext.update(ctx, updates)
	if not updates then return end
	for k, v in pairs(updates) do
		if k ~= "skillInputData" and k ~= "character" then
			ctx[k] = v
		end
		if k == "trackTargetId" and ctx.skillInputData then
			ctx.skillInputData.trackTargetId = v
		end
		if k == "skillTargetData" and ctx.skillInputData then
			ctx.skillInputData.skillTargetData = v
		end
	end
	if ctx.skillInputData then
		if updates.skillCastId ~= nil then ctx.skillInputData.skillCastId = updates.skillCastId end
		if updates.baseSkillInstanceId ~= nil then ctx.skillInputData.baseSkillInstanceId = updates.baseSkillInstanceId end
		if updates.activeBaseSkillIndex ~= nil then ctx.skillInputData.activeBaseSkillIndex = updates.activeBaseSkillIndex end
		if updates.releaseCF ~= nil then ctx.skillInputData.releaseCF = updates.releaseCF end
		if updates.targetCF ~= nil then 
			local _skillDistanceLimit = updates.skillModule.skillDistanceLimit
			if _skillDistanceLimit then
				ctx.skillInputData.targetCF = GetSkillData.getLimitedTargetCF(ctx.skillInputData.releaseCF,updates.targetCF,_skillDistanceLimit) 
			else
				ctx.skillInputData.targetCF = updates.targetCF 
			end
		end
		if updates.moveDirectionStr ~= nil then ctx.skillInputData.moveDirectionStr = updates.moveDirectionStr end
		if updates.approachLandWorldPos ~= nil then ctx.skillInputData.approachLandWorldPos = updates.approachLandWorldPos end
		if updates.moveFaceMode ~= nil then ctx.skillInputData.moveFaceMode = updates.moveFaceMode end
		if updates.moveFaceWorldPos ~= nil then ctx.skillInputData.moveFaceWorldPos = updates.moveFaceWorldPos end
		if updates.multThunderPathPoints ~= nil then
			ctx.skillInputData.multThunderPathPoints = updates.multThunderPathPoints
		end
		if typeof(updates.multThunderSpawnGround) == "Vector3" then
			ctx.skillInputData.multThunderSpawnGround = updates.multThunderSpawnGround
		end
		if updates.character ~= nil then ctx.skillInputData.character = updates.character end
	end
end

return BaseSkillExecutionContext
