--[[
	Module: GroupSkillServer.Cooldown
	Description: 组技能冷却与 combatSeed 辅助（init / InstanceFactory 共用，业务勿直接 require）
	Author: 林奥宇
	Created: 2026-08-18
	Last Modified: 2026-08-18

	功能：
	- resolveBaseCooldownSeconds：skillConf.CD 或模块默认
	- 玩家槽「技能CD时间戳」读写与是否在 CD
	- getEffectiveCooldownSecondsForPlayer：急速/CDR
	- combatSeedFromCharacterId
	- isGroupSkillOnCooldown：玩家时间戳 / NPC 内存倒计时

	只定义一份，供 new / requestRelease / requestStop / _updateGroupState 使用。
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local Players = Utils.Players
local CfgFind = Utils.CfgFind
local EnumMgr = Utils.EnumMgr
local GetData = Utils.GetData
local SkillFolder = EnumMgr.SkillFolder

local Cooldown = {}

--[[
	解析基础冷却秒数
	@param skillID number? - 技能表 ID
	@param moduleDefault number - 组模块默认 CD
	@return number - 冷却秒
]]
function Cooldown.resolveBaseCooldownSeconds(skillID: number?, moduleDefault: number): number
	if skillID and skillID > 0 then
		local skillCfg = CfgFind.FindCfgByID(skillID, EnumMgr.ItemType.Skill)
		if skillCfg then
			local cd = skillCfg.CD
			if type(cd) == "number" and cd >= 0 then
				return cd
			end
			local n = tonumber(cd)
			if n and n >= 0 then
				return n
			end
		end
	end
	return moduleDefault
end

--[[
	由 characterId 派生 combatSeed 哈希
	@param characterId any - 角色 ID
	@return number - 非负整数
]]
function Cooldown.combatSeedFromCharacterId(characterId: any): number
	if typeof(characterId) == "number" then
		return characterId
	end
	local s = tostring(characterId)
	local h = 0
	for i = 1, #s do
		h = (h * 31 + string.byte(s, i)) % 2147483647
	end
	return h
end

--[[
	玩家有效冷却（含急速/CDR）
	@param self any - GroupSkillServer
	@param player Player - 玩家
	@return number - 秒
]]
function Cooldown.getEffectiveCooldownSecondsForPlayer(self: any, player: Player): number
	local base = self.groupSkillCooldown
	if not self.skillID or self.skillID <= 0 then
		return base
	end
	local skillCfg = CfgFind.FindCfgByID(self.skillID, EnumMgr.ItemType.Skill)
	if not skillCfg or skillCfg.isBase ~= EnumMgr.SkillTp.Skill then
		return base
	end
	local cdr = GetData.GetPlrAttr(player, EnumMgr.PlrAttr.Skill_CDR) or 0
	local haste = GetData.GetPlrAttr(player,EnumMgr.PlrAttr.Skill_Haste) or 0

	return base * (0.2+80/(haste+100)) * math.max(0,1-cdr)
end

--[[
	写入玩家槽冷却结束时间戳
	@param player Player - 玩家
	@param slotIndex number? - 槽位
	@param endTimeOrNow number - 结束时刻
	@return () - 无返回值
]]
function Cooldown.writePlayerSkillCooldownEndTimestamp(player: Player, slotIndex: number?, endTimeOrNow: number)
	if not slotIndex then
		return
	end
	local folder = player:FindFirstChild(SkillFolder.CooldownName)
	if not folder or not folder:IsA("Folder") then
		return
	end
	local nv = folder:FindFirstChild(SkillFolder.SlotPrefix .. tostring(slotIndex))
	if nv and nv:IsA("NumberValue") then
		nv.Value = endTimeOrNow
	end
end

--[[
	读取玩家槽冷却结束时间戳
	@param player Player - 玩家
	@param slotIndex number? - 槽位
	@return number? - 结束时刻
]]
function Cooldown.getPlayerSlotCooldownEndTimestamp(player: Player, slotIndex: number?): number?
	if not slotIndex then
		return nil
	end
	local folder = player:FindFirstChild(SkillFolder.CooldownName)
	if not folder or not folder:IsA("Folder") then
		return nil
	end
	local nv = folder:FindFirstChild(SkillFolder.SlotPrefix .. tostring(slotIndex))
	if nv and nv:IsA("NumberValue") then
		return nv.Value
	end
	return nil
end

--[[
	玩家槽是否在冷却中
	@param player Player - 玩家
	@param slotIndex number? - 槽位
	@return boolean - 是否在 CD
]]
function Cooldown.isPlayerSlotCooldownActiveByTimestamp(player: Player, slotIndex: number?): boolean
	local endTs = Cooldown.getPlayerSlotCooldownEndTimestamp(player, slotIndex)
	if endTs == nil then
		return false
	end
	return workspace:GetServerTimeNow() < endTs
end

--[[
	玩家槽剩余冷却秒
	@param player Player - 玩家
	@param slotIndex number? - 槽位
	@return number - 剩余秒
]]
function Cooldown.getPlayerSlotCooldownRemainingSeconds(player: Player, slotIndex: number?): number
	local endTs = Cooldown.getPlayerSlotCooldownEndTimestamp(player, slotIndex)
	if endTs == nil then
		return 0
	end
	return math.max(0, endTs - workspace:GetServerTimeNow())
end

--[[
	组技能是否在冷却中
	@param self any - GroupSkillServer
	@return boolean - 是否在 CD
]]
function Cooldown.isGroupSkillOnCooldown(self: any): boolean
	if self.characterType == "Player" then
		local player = Players:GetPlayerByUserId(self.characterId)
		if not player then
			return false
		end
		return Cooldown.isPlayerSlotCooldownActiveByTimestamp(player, self.slotIndex)
	end
	return self.groupSkillCooldownRemaining > 0
end

return Cooldown
