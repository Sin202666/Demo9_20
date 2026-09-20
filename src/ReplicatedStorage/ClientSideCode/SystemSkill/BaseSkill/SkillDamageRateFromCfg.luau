--[[
	从 skillConf 解析伤害倍率（与 hitbox 配置解耦）
	DamageRate 为数组时按下标 hitboxIndex 取值；缺省回退首元素；无配置回退 1。
	Author: suzhenyu
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local CfgFind = Utils.CfgFind
local EnumMgr = Utils.EnumMgr

local SkillDamageRateFromCfg = {}

local function rateFromDamageRateField(dr: any, hitboxIndex: number): number
	if type(dr) == "number" then
		return dr
	end
	if type(dr) ~= "table" then
		return 1
	end
	if #dr == 0 then
		return 1
	end
	local v = dr[hitboxIndex]
	if type(v) == "number" then
		return v
	end
	v = dr[1]
	if type(v) == "number" then
		return v
	end
	return 1
end

--[[
	@param skillID number? 技能表 ID
	@param hitboxIndex number? 对应 HitboxIndex，默认 1
	@return number 倍率
]]
function SkillDamageRateFromCfg.get(skillID: number?, hitboxIndex: number?): number
	if not skillID or skillID <= 0 then
		return 1
	end
	local idx = hitboxIndex or 1
	local cfg = CfgFind.FindCfgByID(skillID, EnumMgr.ItemType.Skill)
	if not cfg then
		return 1
	end
	return rateFromDamageRateField(cfg.DamageRate, idx)
end

return SkillDamageRateFromCfg
