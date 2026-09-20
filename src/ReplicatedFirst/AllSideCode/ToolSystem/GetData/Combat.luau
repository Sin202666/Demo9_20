--[[
	Module: GetData.Combat
	Description: 会话战斗属性读写与精简 GetDmg（无敌窗 / finalDamage 优先 / 攻防公式）
	Author: 林奥宇
	Created: 2026-07-30
	Last Modified: 2026-09-01

	功能：
	- GetPlrAttr / GetPlrAttrValue：读 Player 或 Model 下 Folder「战斗属性」NumberValue
	- SetPlrAttr：写会话 NumberValue（不进 DataStore）
	- GetDmg：战斗开关 / 闪避无敌 / hitData.finalDamage 优先 / 攻防公式
	- GetSkillPurityDamageRateMul：纯度 → 伤害倍率（0.5 + 纯度/2）
	- IsCombatEnabled / IsPlrDodgeInvincible：总开关与无敌窗查询

	与相关模块的关系：
	- 权威承伤走服 SystemPlrAttr.HitPlr；本模块只提供会话 Instance 与公式，不算结算权威
	- SetPlrAttr 仅应由服务端 SystemPlrAttr.InitPlr 等写口调用；客户端改本地 Instance 不会复制到服
	- GetDmg 的 hitData.finalDamage 须由服 DamageResolver / HitResolver 写入，禁止把客上报当最终事实
	- 缺省数值回落 GameConfig「战斗系统」，兼容旧键「战斗」

	加载方式（一般由 GetData/init 聚合，亦可 GetData.Combat.*）：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local GetData = Utils.GetData
		local EnumMgr = Utils.EnumMgr

	使用示例：
		local atk = GetData.GetPlrAttr(plr, EnumMgr.PlrAttr.Atk)
		local dmg, isCrit = GetData.GetDmg(attackerModel, beHitPlr, { damageRate = 1.2 })
		local purityMul = GetData.GetSkillPurityDamageRateMul(0.8)
]]

-- ========================================
-- 服务引用
-- ========================================
local Workspace = game:GetService("Workspace")

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Players = Utils.Players
local InsMgr = Utils.InsMgr
local EnumMgr = Utils.EnumMgr
local SystemGameConfig = Utils.SystemGameConfig

-- ========================================
-- 模块定义
-- ========================================
local Combat = {}

-- ========================================
-- 常量定义
-- ========================================
local PlrAttr = EnumMgr.PlrAttr
local ElementTp = EnumMgr.ElementTp

local ATTR_FOLDER = "战斗属性"
local DODGE_INVULN_NAME = "闪避无敌"
local PURITY_BASE = 0.5
local PURITY_SPAN = 0.5
local REDUCTION_CAP = 0.9

local ATTR_DEFAULT_SPEC: { [string]: { configKey: string, fallback: number } } = {
	[PlrAttr.Atk] = { configKey = "默认攻击", fallback = 100 },
	[PlrAttr.HP] = { configKey = "默认生命", fallback = 1000 },
	[PlrAttr.Atk_P] = { configKey = "默认攻击百分比", fallback = 0 },
	[PlrAttr.Crit_Rate] = { configKey = "默认暴击率", fallback = 0 },
	[PlrAttr.Crit_Dmg] = { configKey = "默认暴击伤害", fallback = 0.5 },
	[PlrAttr.Dmg_Bonus] = { configKey = "默认最终伤害加成", fallback = 0 },
	[PlrAttr.Dmg_Reduction] = { configKey = "默认最终伤害减免", fallback = 0 },
}

-- ========================================
-- 私有函数
-- ========================================

--[[
	读取战斗默认数值（优先「战斗系统」，回落旧键「战斗」）
	@param key string - GameConfig「战斗系统」/「战斗」下的键名
	@param fallback number - 配置缺失或非 number 时的回落值
	@return number - 配置值或 fallback
]]
local function _combatDefault(key: string, fallback: number): number
	local v = SystemGameConfig.GetValue({ "战斗系统", key })
	if type(v) == "number" then
		return v
	end
	local legacy = SystemGameConfig.GetValue({ "战斗", key })
	if type(legacy) == "number" then
		return legacy
	end
	return fallback
end

--[[
	属性缺省值（无 NumberValue 或宿主无效时）
	@param attr string - EnumMgr.PlrAttr 键；未知键回落 0
	@return number - GameConfig 默认或元素/冷却固定值
]]
local function _defaultForAttr(attr: string): number
	if attr == PlrAttr.Ele then
		return ElementTp.None or 0
	end
	if attr == PlrAttr.Skill_CDR or attr == PlrAttr.Skill_Haste then
		return 0
	end
	local spec = ATTR_DEFAULT_SPEC[attr]
	if spec then
		return _combatDefault(spec.configKey, spec.fallback)
	end
	return 0
end

--[[
	将 Player 或角色 Model 解析为属性宿主
	@param target any - Player、角色 Model，或其它 Instance；非 Instance 为 nil
	@return Instance? - Player（优先）或无主 Model；无法解析为 nil
]]
local function _resolveAttrHost(target: any): Instance?
	if typeof(target) ~= "Instance" then
		return nil
	end
	if target:IsA("Player") then
		return target
	end
	if target:IsA("Model") then
		local plr = Players:GetPlayerFromCharacter(target)
		if plr then
			return plr
		end
		return target
	end
	return nil
end

--[[
	确保宿主下存在「战斗属性」Folder（不存在则创建）
	@param host Instance - Player 或无主 Model
	@return Folder - 属性文件夹
]]
local function _ensureAttrFolder(host: Instance): Folder
	return InsMgr.GetIns(ATTR_FOLDER, "Folder", host) :: Folder
end

--[[
	从受击目标解析 Player（无敌窗只挂在 Player 上）
	@param beHit any - Player、角色 Model 或其它；nil/非 Instance 为 nil
	@return Player? - 受击玩家；可破坏物或非玩家 Model 为 nil
]]
local function _resolveDefenderPlayer(beHit: any): Player?
	if beHit == nil then
		return nil
	end
	if typeof(beHit) ~= "Instance" then
		return nil
	end
	if beHit:IsA("Player") then
		return beHit
	end
	if beHit:IsA("Model") then
		return Players:GetPlayerFromCharacter(beHit)
	end
	return nil
end

--[[
	元素克制倍率（一期恒 1；二期再接克制表）
	@param _atkEle number - 攻击元素 EnumMgr.ElementTp
	@param _defEle number - 受击元素 EnumMgr.ElementTp
	@return number - 倍率，一期恒 1
]]
local function _elementMul(_atkEle: number, _defEle: number): number
	return 1
end

--[[
	技能纯度 → 伤害倍率：0.5 + 纯度/2；缺省按 1，超出 [0,1] 时 clamp
	@param skillPurity any - 纯度 0～1；非数字或 nil 按 1
	@return number - 伤害倍率 ∈ [0.5, 1]
]]
local function _skillPurityDamageRateMul(skillPurity: any): number
	local p = tonumber(skillPurity)
	if p == nil then
		p = 1
	end
	p = math.clamp(p, 0, 1)
	return PURITY_BASE + p * PURITY_SPAN
end

-- ========================================
-- 公共函数
-- ========================================

--[[
	战斗系统总开关（GameConfig.战斗系统.启用）
	@return boolean - false 时伤害/无敌/Buff 权威路径应 no-op
]]
function Combat.IsCombatEnabled(): boolean
	return SystemGameConfig.GetValue({ "战斗系统", "启用" }) ~= false
end

--[[
	写入会话战斗属性 NumberValue（不进 DataStore）
	仅服务端 SystemPlrAttr 等权威写口应调用；客户端写入不复制到服
	@param target any - Player 或角色 Model；无法解析则忽略
	@param attr string - EnumMgr.PlrAttr 键；空串忽略
	@param value number - 写入值；非数字按 0
]]
function Combat.SetPlrAttr(target: any, attr: string, value: number)
	local host = _resolveAttrHost(target)
	if not host or type(attr) ~= "string" or attr == "" then
		return
	end
	local folder = _ensureAttrFolder(host)
	local nv = InsMgr.GetIns(attr, "NumberValue", folder) :: NumberValue
	nv.Value = tonumber(value) or 0
end

--[[
	读取会话战斗属性；无 NumberValue 时回落 GameConfig 默认
	@param target any - Player 或角色 Model；无法解析则返回该 attr 的默认
	@param attr string - EnumMgr.PlrAttr 键；空/无效仍按默认表回落
	@return number - 属性值或默认
]]
function Combat.GetPlrAttr(target: any, attr: string): number
	local host = _resolveAttrHost(target)
	if not host or type(attr) ~= "string" or attr == "" then
		return _defaultForAttr(attr or "")
	end
	local folder = host:FindFirstChild(ATTR_FOLDER)
	if folder then
		local nv = folder:FindFirstChild(attr)
		if nv and nv:IsA("NumberValue") then
			return nv.Value
		end
	end
	return _defaultForAttr(attr)
end

--[[
	GetPlrAttr 旧名别名（签名与返回值相同）
	@param target any - Player 或角色 Model
	@param attr string - EnumMgr.PlrAttr 键
	@return number - 属性值或默认
]]
function Combat.GetPlrAttrValue(target: any, attr: string): number
	return Combat.GetPlrAttr(target, attr)
end

--[[
	玩家是否处于闪避无敌窗（Player 下 NumberValue「闪避无敌」> ServerTime）
	@param plr Player - 玩家；非 Player Instance 为 false
	@return boolean - 无敌中为 true
]]
function Combat.IsPlrDodgeInvincible(plr: Player): boolean
	if typeof(plr) ~= "Instance" or not plr:IsA("Player") then
		return false
	end
	local wudi = plr:FindFirstChild(DODGE_INVULN_NAME)
	if wudi and wudi:IsA("NumberValue") then
		return wudi.Value > Workspace:GetServerTimeNow()
	end
	return false
end

--[[
	技能纯度 → 伤害倍率（与 GetDmg / HitResolver 同公式）
	@param skillPurity any - 纯度 0～1；非数字或 nil 按 1
	@return number - 伤害倍率 ∈ [0.5, 1]
]]
function Combat.GetSkillPurityDamageRateMul(skillPurity: any): number
	return _skillPurityDamageRateMul(skillPurity)
end

--[[
	计算伤害。顺序：战斗关闭 → 0；闪避无敌 → 0；hitData.finalDamage 优先 → 否则 Atk 公式
	hitData.finalDamage 只接受服 DamageResolver / HitResolver 的预结算，禁止客上报当最终事实
	@param atk any - 攻击方 Player 或 Model；无法解析时按默认攻击
	@param beHit any? - 受击 Player/Model；nil 表示可破坏物（跳过无敌与减伤）
	@param hitData table? - 可选字段：finalDamage number?、isCrit boolean?、damageRate number?（缺省 1）、skillPurity number?、eleTp number?
	@return number - 非负整数伤害
	@return boolean - 是否暴击（finalDamage 路径取 hitData.isCrit）
]]
function Combat.GetDmg(atk: any, beHit: any?, hitData: any?): (number, boolean)
	if not Combat.IsCombatEnabled() then
		return 0, false
	end

	hitData = hitData or {}

	local defPlr = _resolveDefenderPlayer(beHit)
	if defPlr and Combat.IsPlrDodgeInvincible(defPlr) then
		return 0, false
	end

	local finalFromHit = tonumber(hitData.finalDamage)
	if finalFromHit ~= nil then
		local dmg = math.max(0, math.floor(finalFromHit + 0.5))
		return dmg, hitData.isCrit == true
	end

	local atkHost = _resolveAttrHost(atk) or atk
	local baseAtk = Combat.GetPlrAttr(atkHost, PlrAttr.Atk)
	local atkP = Combat.GetPlrAttr(atkHost, PlrAttr.Atk_P)
	local panel = baseAtk * (1 + atkP)
	if panel <= 0 then
		panel = _combatDefault("默认攻击", 100)
	end

	local damageRate = tonumber(hitData.damageRate) or 1
	local purityMul = _skillPurityDamageRateMul(hitData.skillPurity)

	local atkEle = tonumber(hitData.eleTp) or Combat.GetPlrAttr(atkHost, PlrAttr.Ele)
	local defEle = ElementTp.None
	if beHit ~= nil then
		defEle = Combat.GetPlrAttr(beHit, PlrAttr.Ele)
	end
	local eleMul = _elementMul(atkEle, defEle)

	local bonus = Combat.GetPlrAttr(atkHost, PlrAttr.Dmg_Bonus)
	local reduction = 0
	if beHit ~= nil then
		reduction = Combat.GetPlrAttr(beHit, PlrAttr.Dmg_Reduction)
	end

	local isCrit = hitData.isCrit == true
	local critMul = 1
	if isCrit then
		local critDmg = Combat.GetPlrAttr(atkHost, PlrAttr.Crit_Dmg)
		critMul = 1 + critDmg
	end

	local raw = panel * damageRate * purityMul * eleMul * (1 + bonus) * (1 - math.clamp(reduction, 0, REDUCTION_CAP)) * critMul
	local dmg = math.max(0, math.floor(raw + 0.5))
	return dmg, isCrit
end

return Combat
