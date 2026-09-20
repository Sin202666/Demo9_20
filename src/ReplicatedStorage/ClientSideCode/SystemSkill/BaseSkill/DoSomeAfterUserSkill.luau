--[[
	释放技能之后的一些其他模块逻辑（提纯：缺依赖时 no-op）
]]

local module = {}

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local SystemBag = Utils.SystemBag
local CfgFind = Utils.CfgFind
local EnumMgr = Utils.EnumMgr
local SystemGuide = Utils.SystemGuide
local GameGlobalConfig = Utils.GameGlobalConfig

local function getSkillExp(skillID: number?): number
	if skillID and skillID > 0 then
		local skillCfg = CfgFind.FindCfgByID(skillID, EnumMgr.ItemType.Skill)
		if skillCfg then
			local exp = skillCfg.exp
			if type(exp) == "number" then
				return exp
			end
		end
	end
	return 0
end

function module.UseSkill(_plr: Player, _skillID: number)
	local exp = getSkillExp(_skillID)
	if not _plr or exp <= 0 then
		return
	end

	if SystemBag and SystemBag.KillEnemyPutInBag and EnumMgr.ItemID and EnumMgr.ItemID.Exp then
		SystemBag.KillEnemyPutInBag(_plr, { EnumMgr.ItemID.Exp }, { exp })
	end

	local skillCfg = CfgFind.FindCfgByID(_skillID, EnumMgr.ItemType.Skill)
	if skillCfg and skillCfg.isBase == EnumMgr.SkillTp.Skill then
		if SystemGuide and SystemGuide.CompleteGuide then
			SystemGuide.CompleteGuide(_plr, "释放一次技能", 1)
		end
	end
end

return module
