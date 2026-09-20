--[[
	Module: NPCCosmeticHit/NPCCosmeticHitPlay
	Description: NPC「仅表现」受击动画播放（查找 LocalMonster + 播轨）
	Author: 林奥宇
	Created: 2026-08-17
	Last Modified: 2026-08-28
]]

local Workspace = game:GetService("Workspace")

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local AnimationModule = Utils.AnimationModule
local CfgFind = Utils.CfgFind
local SystemLogicalEnemy = Utils.SystemLogicalEnemy

local NPCCosmeticHitPlay = {}

local DEFAULT_ANIM_PRIORITY = Enum.AnimationPriority.Action4
local DEFAULT_FADE_TIME = 0.08
local DEFAULT_ANIM_SPEED = 1

export type CosmeticHitPayload = {
	monsterId: string,
	animName: string,
	fadeTime: number?,
	speed: number?,
	skillid: number?,
}

--[[
	按运行时 id 查找本地表现 Model（优先 SystemLogicalEnemy）
	@param runtimeId string - model.Name / 逻辑怪 id 字符串
	@return Model? - LocalMonster 下模型
]]
function NPCCosmeticHitPlay.findRuntimeNpcModel(runtimeId: string): Model?
	if SystemLogicalEnemy and SystemLogicalEnemy.GetModel then
		local logical = SystemLogicalEnemy.GetModel(runtimeId)
		if logical then
			return logical
		end
	end

	local localFolder = Workspace:FindFirstChild("LocalMonster")
	if localFolder then
		local m = localFolder:FindFirstChild(runtimeId)
		if m and m:IsA("Model") then
			return m
		end
	end

	return nil
end

--[[
	是否允许播放 cosmetic 受击轨
	@param model Model - 运行时 NPC Model
	@param _skillId number? - 技能 ID（预留强制受击）
	@return boolean - true 表示可播
]]
function NPCCosmeticHitPlay.canPlay(model: Model, _skillId: number?): boolean
	if not model or not model.Parent then
		return false
	end
	local cfgId = model:GetAttribute("ID")
	if cfgId == nil then
		return true
	end
	local entityCfg = CfgFind.GetCfgByNameAndID("enemyConf", cfgId)
	if entityCfg and entityCfg.hitstunDisabled == 1 then
		return false
	end
	if model:GetAttribute("SkillActionLock") then
		return false
	end
	return true
end

--[[
	在指定 Model 上播放 cosmetic 受击动画
	@param model Model - 运行时 NPC Model
	@param payload CosmeticHitPayload - 播轨参数
	@return boolean - 是否已尝试播放
]]
function NPCCosmeticHitPlay.playOnModel(model: Model, payload: CosmeticHitPayload): boolean
	if not model or type(payload) ~= "table" then
		return false
	end

	local animName = payload.animName
	if typeof(animName) ~= "string" or animName == "" then
		return false
	end

	if not NPCCosmeticHitPlay.canPlay(model, payload.skillid) then
		return false
	end

	local fade = typeof(payload.fadeTime) == "number" and payload.fadeTime or DEFAULT_FADE_TIME
	local spd = typeof(payload.speed) == "number" and payload.speed or DEFAULT_ANIM_SPEED

	AnimationModule.PlayAnimByModel(
		model,
		animName,
		spd,
		nil,
		nil,
		DEFAULT_ANIM_PRIORITY,
		fade
	)
	return true
end

--[[
	按 payload.monsterId 查找并播放
	@param payload CosmeticHitPayload - 播轨参数
	@return boolean - 是否已尝试播放
]]
function NPCCosmeticHitPlay.playFromPayload(payload: CosmeticHitPayload): boolean
	if type(payload) ~= "table" then
		return false
	end
	local runtimeId = payload.monsterId ~= nil and tostring(payload.monsterId) or nil
	if not runtimeId then
		return false
	end
	local model = NPCCosmeticHitPlay.findRuntimeNpcModel(runtimeId)
	if not model then
		return false
	end
	return NPCCosmeticHitPlay.playOnModel(model, payload)
end

return NPCCosmeticHitPlay