--[[
	实体身份与阵营工具（EntityUtil）
	职责：统一解析 Model 的 identity、owner、camp，供 HitResolver 做归属与友伤规避

	约定：
	- Player：characterId = UserId, characterType = "Player"
	- NPC：characterId = Model.Name（或 Attribute "EntityId"）, characterType = "NPC"
	- 召唤物/宠物/分身：Model 有 Attribute "OwnerId" + "OwnerType"，归属其主人
	- 阵营：Player 用 Team.Name，NPC/召唤物用 Attribute "Camp"
]]

local Players = game:GetService("Players")

local GetSkillData = require(script.Parent.GetSkillData)

local EntityUtil = {}

--[[
	比较两个实体 id（NPC Name 与 OwnerId 可能存在 number/string 混用）
]]
function EntityUtil.idsEqual(a: any, b: any): boolean
	if a == b then
		return true
	end
	if a == nil or b == nil then
		return false
	end
	return tostring(a) == tostring(b)
end

-- Attribute 约定（可后续抽配置）
local ATTR_OWNER_ID = "OwnerId"
local ATTR_OWNER_TYPE = "OwnerType"
local ATTR_CAMP = "Camp"
local ATTR_ENTITY_ID = "EntityId"
local ATTR_ENTITY_TYPE = "EntityType"

--[[
	获取 Model 的实体身份
	@param model Model 角色/召唤物 Model
	@return id any, type string 或 nil, nil
]]
function EntityUtil.getEntityIdentity(model)
	if not model or not model:IsA("Model") then return nil, nil end

	-- 召唤物/宠物/分身：优先用自定义 EntityId（若有）
	local customId = model:GetAttribute(ATTR_ENTITY_ID)
	local customType = model:GetAttribute(ATTR_ENTITY_TYPE)
	if customId ~= nil and customType ~= nil then
		return customId, tostring(customType)
	end

	-- Player
	local player = Players:GetPlayerFromCharacter(model)
	if player then
		return player.UserId, "Player"
	end

	-- NPC（Monster 文件夹下，或带 Humanoid 的非 Player 角色）
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		local monsterFolder = workspace:FindFirstChild("Monster")
		if monsterFolder and model:IsDescendantOf(monsterFolder) then
			return model.Name, "NPC"
		end
		local summonFolder = workspace:FindFirstChild("Summons")
		if summonFolder and model:IsDescendantOf(summonFolder) then
			return model.Name, "Summon"
		end
		local mirrorFolder = workspace:FindFirstChild("SpaceMirrors")
		if mirrorFolder and model:IsDescendantOf(mirrorFolder) then
			return model.Name, "Mirror"
		end
		-- 其他带 Humanoid 的 Model（如召唤物）：用 Name 作为临时 id，type 从 Attribute 或默认 "Summon"
		local etype = model:GetAttribute(ATTR_ENTITY_TYPE) or "Summon"
		return model.Name, tostring(etype)
	end

	return nil, nil
end

--[[
	获取 Model 的阵营
	@param model Model
	@return camp string? 阵营标识，nil 表示无阵营
]]
function EntityUtil.getEntityCamp(model)
	if not model or not model:IsA("Model") then return nil end

	-- Attribute 优先
	local attrCamp = model:GetAttribute(ATTR_CAMP)
	if attrCamp ~= nil and attrCamp ~= "" then
		return tostring(attrCamp)
	end

	-- 召唤物：继承主人的阵营
	local ownerId, ownerType = EntityUtil.getEntityOwnerId(model)
	if ownerId and ownerType then
		return EntityUtil.getCampById(ownerId, ownerType)
	end

	-- Player：用 Team.Name
	local player = Players:GetPlayerFromCharacter(model)
	if player and player.Team and player.Team.Name then
		return player.Team.Name
	end

	return nil
end

--[[
	根据 id+type 获取阵营（需能解析到 Model）
	@param id any
	@param entityType string "Player" | "NPC" | ...
	@return camp string?
]]
function EntityUtil.getCampById(id, entityType)
	if not id or not entityType then return nil end
	local model = GetSkillData.getCharacter(entityType, id)
	if model then
		return EntityUtil.getEntityCamp(model)
	end
	return nil
end

--[[
	获取 Model 的归属主人（召唤物/宠物/分身）
	@param model Model
	@return ownerId any, ownerType string 或 nil, nil
]]
function EntityUtil.getEntityOwnerId(model)
	if not model or not model:IsA("Model") then return nil, nil end

	local ownerId = model:GetAttribute(ATTR_OWNER_ID)
	local ownerType = model:GetAttribute(ATTR_OWNER_TYPE)
	if ownerId ~= nil and ownerType ~= nil then
		return ownerId, tostring(ownerType)
	end

	return nil, nil
end

--[[
	根据 id+type 获取其主人的 id+type（若为召唤物等）
	@param id any
	@param entityType string
	@return ownerId any, ownerType string 或 nil, nil
]]
function EntityUtil.getEntityOwnerIdById(id, entityType)
	if not id or not entityType then return nil, nil end
	local model = GetSkillData.getCharacter(entityType, id)
	if model then
		return EntityUtil.getEntityOwnerId(model)
	end
	return nil, nil
end

--[[
	判断两个 Model 是否为同一实体
	@param a Model
	@param b Model
	@return boolean
]]
function EntityUtil.isSameEntity(a, b)
	if not a or not b then return false end
	local idA, typeA = EntityUtil.getEntityIdentity(a)
	local idB, typeB = EntityUtil.getEntityIdentity(b)
	if not idA or not idB then return a == b end
	return idA == idB and typeA == typeB
end

--[[
	目标是否为攻击者的自身/主人/下属召唤物（与 HitResolver.isOwner 语义一致）
]]
function EntityUtil.isOwnedBy(attackerId: any, attackerType: string, targetModel: Model): boolean
	if not attackerId or not attackerType or not targetModel then
		return false
	end

	local targetId, targetType = EntityUtil.getEntityIdentity(targetModel)
	if not targetId or not targetType then
		return false
	end

	if EntityUtil.idsEqual(targetId, attackerId) and targetType == attackerType then
		return true
	end

	local ownerId, ownerType = EntityUtil.getEntityOwnerIdById(attackerId, attackerType)
	if ownerId and ownerType and EntityUtil.idsEqual(targetId, ownerId) and targetType == ownerType then
		return true
	end

	local targetOwnerId, targetOwnerType = EntityUtil.getEntityOwnerId(targetModel)
	if targetOwnerId and targetOwnerType
		and EntityUtil.idsEqual(targetOwnerId, attackerId)
		and targetOwnerType == attackerType
	then
		return true
	end

	return false
end

--[[
	是否为非敌对检测目标（友方/己方/他人玩家召唤物），Hitbox 与弹道遮挡射线共用
]]
function EntityUtil.isNonHostileTarget(attackerId: any, attackerType: string, targetModel: Model): boolean
	if EntityUtil.isOwnedBy(attackerId, attackerType, targetModel) then
		return true
	end
	if EntityUtil.isFriendly({ id = attackerId, type = attackerType }, targetModel) then
		return true
	end
	if EntityUtil.isForeignPlayerOwnedSummon(attackerId, attackerType, targetModel) then
		return true
	end
	return false
end

function EntityUtil.isForeignPlayerOwnedSummon(attackerId: any, attackerType: string, targetModel: Model): boolean
	if attackerType ~= "Player" or typeof(attackerId) ~= "number" then
		return false
	end
	local targetOwnerId, targetOwnerType = EntityUtil.getEntityOwnerId(targetModel)
	if targetOwnerType ~= "Player" or targetOwnerId == nil then
		return false
	end
	return not EntityUtil.idsEqual(targetOwnerId, attackerId)
end

--[[
	判断两个实体（Model 或 id+type）是否同阵营
	@param a Model | { id, type }
	@param b Model | { id, type }
	@return boolean
]]
function EntityUtil.isFriendly(a, b)
	local campA, campB
	if type(a) == "table" and a.id and a.type then
		campA = EntityUtil.getCampById(a.id, a.type)
	elseif typeof(a) == "Instance" and a:IsA("Model") then
		campA = EntityUtil.getEntityCamp(a)
	else
		return false
	end
	if type(b) == "table" and b.id and b.type then
		campB = EntityUtil.getCampById(b.id, b.type)
	elseif typeof(b) == "Instance" and b:IsA("Model") then
		campB = EntityUtil.getEntityCamp(b)
	else
		return false
	end
	if not campA or not campB then return false end
	return campA == campB
end

return EntityUtil
