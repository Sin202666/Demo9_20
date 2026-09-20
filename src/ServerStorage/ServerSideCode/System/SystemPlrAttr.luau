--[[
	Module: SystemPlrAttr
	Description: 玩家战斗属性与承伤权威（InitPlr / WudiPlr / ChangeHP / HitPlr）
	Author: 林奥宇
	Created: 2026-07-30
	Last Modified: 2026-08-28

	仅服务端；客户端仍用 ToolSystem stub。Utils.SystemPlrAttr 服务端优先本模块。
	门控：GameConfig「战斗系统.启用」—— false 时 Init/Wudi/ChangeHP/HitPlr 均 no-op。

	加载：
		local SystemPlrAttr = Utils.SystemPlrAttr
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local GetData = Utils.GetData
local InsMgr = Utils.InsMgr
local EnumMgr = Utils.EnumMgr
local HumanModule = Utils.HumanModule
local FindPlayerByID = Utils.FindPlayerByID
local SystemGameConfig = Utils.SystemGameConfig

local PlrAttr = EnumMgr.PlrAttr
local DODGE_INVULN_NAME = "闪避无敌"

local SystemPlrAttr = {}

--[[
	战斗系统总开关（与 GetData.IsCombatEnabled 同路径）
	@return boolean - true 表示战斗系统启用，承伤/无敌 API 可生效
]]
function SystemPlrAttr.IsEnabled(): boolean
	if GetData.IsCombatEnabled then
		return GetData.IsCombatEnabled()
	end
	return SystemGameConfig.GetValue({ "战斗系统", "启用" }) ~= false
end

--[[
	读取闪避无敌默认秒数（优先战斗系统，回落「闪避」）
	@return number - 无敌持续秒；配置缺失时为 0.35
]]
local function _defaultInvulnSec(): number
	local v = SystemGameConfig.GetValue({ "战斗系统", "闪避无敌时间" })
	if type(v) == "number" and v > 0 then
		return v
	end
	v = SystemGameConfig.GetValue({ "闪避", "无敌时间" })
	if type(v) == "number" and v > 0 then
		return v
	end
	return 0.35
end

--[[
	初始化玩家会话战斗属性，并同步 Humanoid 生命
	@param plr Player - 玩家
]]
function SystemPlrAttr.InitPlr(plr: Player)
	if not SystemPlrAttr.IsEnabled() then
		return
	end
	if typeof(plr) ~= "Instance" or not plr:IsA("Player") then
		return
	end

	local defaultAtk = SystemGameConfig.GetValue({ "战斗系统", "默认攻击" })
	local defaultHp = SystemGameConfig.GetValue({ "战斗系统", "默认生命" })
	local defaultAtkP = SystemGameConfig.GetValue({ "战斗系统", "默认攻击百分比" })
	local defaultCritRate = SystemGameConfig.GetValue({ "战斗系统", "默认暴击率" })
	local defaultCritDmg = SystemGameConfig.GetValue({ "战斗系统", "默认暴击伤害" })
	local defaultBonus = SystemGameConfig.GetValue({ "战斗系统", "默认最终伤害加成" })
	local defaultReduction = SystemGameConfig.GetValue({ "战斗系统", "默认最终伤害减免" })

	GetData.SetPlrAttr(plr, PlrAttr.Atk, type(defaultAtk) == "number" and defaultAtk or 100)
	GetData.SetPlrAttr(plr, PlrAttr.HP, type(defaultHp) == "number" and defaultHp or 1000)
	GetData.SetPlrAttr(plr, PlrAttr.Atk_P, type(defaultAtkP) == "number" and defaultAtkP or 0)
	GetData.SetPlrAttr(plr, PlrAttr.Crit_Rate, type(defaultCritRate) == "number" and defaultCritRate or 0)
	GetData.SetPlrAttr(plr, PlrAttr.Crit_Dmg, type(defaultCritDmg) == "number" and defaultCritDmg or 0.5)
	GetData.SetPlrAttr(plr, PlrAttr.Dmg_Bonus, type(defaultBonus) == "number" and defaultBonus or 0)
	GetData.SetPlrAttr(plr, PlrAttr.Dmg_Reduction, type(defaultReduction) == "number" and defaultReduction or 0)
	GetData.SetPlrAttr(plr, PlrAttr.Ele, EnumMgr.ElementTp.None)
	GetData.SetPlrAttr(plr, PlrAttr.Skill_CDR, 0)
	GetData.SetPlrAttr(plr, PlrAttr.Skill_Haste, 0)

	local hp = GetData.GetPlrAttr(plr, PlrAttr.HP)
	local humanoid = HumanModule.GetHumanoid(plr)
	if humanoid then
		humanoid.MaxHealth = math.max(1, hp)
		humanoid.Health = humanoid.MaxHealth
	end
end

--[[
	写入闪避无敌窗（Player 下 NumberValue「闪避无敌」= 到期 ServerTime）
	@param userIdOrPlr number|Player - UserId 或 Player
	@param duration number? - 秒；缺省读战斗系统闪避无敌时间
]]
function SystemPlrAttr.WudiPlr(userIdOrPlr: any, duration: number?)
	if not SystemPlrAttr.IsEnabled() then
		return
	end
	local plr: Player? = nil
	if typeof(userIdOrPlr) == "Instance" and userIdOrPlr:IsA("Player") then
		plr = userIdOrPlr
	elseif type(userIdOrPlr) == "number" then
		plr = FindPlayerByID.Find(userIdOrPlr) or Players:GetPlayerByUserId(userIdOrPlr)
	end
	if not plr then
		return
	end

	local sec = tonumber(duration)
	if sec == nil or sec <= 0 then
		sec = _defaultInvulnSec()
	end

	local nv = InsMgr.GetIns(DODGE_INVULN_NAME, "NumberValue", plr) :: NumberValue
	local expireAt = Workspace:GetServerTimeNow() + sec
	if nv.Value < expireAt then
		nv.Value = expireAt
	end
end

--[[
	修改玩家生命（dmg 为增量：负数为扣血）
	@param plr Player - 玩家
	@param dmg number - 生命变化量（负=受伤）
	@param _isCrit boolean? - 是否暴击（表现预留）
	@param _attacker any? - 攻击方（表现预留）
]]
function SystemPlrAttr.ChangeHP(plr: Player, dmg: number, _isCrit: boolean?, _attacker: any?)
	if not SystemPlrAttr.IsEnabled() then
		return
	end
	if typeof(plr) ~= "Instance" or not plr:IsA("Player") then
		return
	end
	local humanoid = HumanModule.GetHumanoid(plr)
	if not humanoid or humanoid.Health <= 0 then
		return
	end
	local delta = tonumber(dmg) or 0
	if delta == 0 then
		return
	end
	local newHp = math.clamp(humanoid.Health + delta, 0, humanoid.MaxHealth)
	humanoid.Health = newHp
end

--[[
	NPC/召唤物等对玩家造成伤害
	@param attackerModel any - 攻击方 Model（可 nil）
	@param beHitPlr Player - 受击玩家
	@param hitData table? - GetDmg 用 hitData（可含 finalDamage）
	@return number - 实际造成伤害（正数）；0 表示未造成
]]
function SystemPlrAttr.HitPlr(attackerModel: any, beHitPlr: Player, hitData: any?): number
	if not SystemPlrAttr.IsEnabled() then
		return 0
	end
	if typeof(beHitPlr) ~= "Instance" or not beHitPlr:IsA("Player") then
		return 0
	end
	local damage, isCrit = GetData.GetDmg(attackerModel, beHitPlr, hitData)
	if damage <= 0 then
		return 0
	end
	SystemPlrAttr.ChangeHP(beHitPlr, -damage, isCrit, attackerModel)
	return damage
end

return SystemPlrAttr