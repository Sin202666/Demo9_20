--[[
	Module: GetData
	Description: 双端只读数据查询薄门面（背包、条目+配置、玩家 Setting/GamePass、会话战斗属性）
	Author: 林奥宇
	Created: 2026-07-02
	Last Modified: 2026-09-04

	功能：
	- Bag：按物品 id 读 Bag/Shard NumberValue，客户端可回退 PlayerData.Bag 字典统计
	- Entry：按 onlyID 查条目 + CfgFind 配置（条目深拷贝，配置为冻结引用）
	- BagCapacity：堆叠/容量/页签闭集表（服客同一份；禁止运行时 Register）
	- BagView：Query / Occupancy / IsFull / ToSlotVM / QueryWarehouse / QueryToolbarSlot（全部深拷贝）
	- Mirror：Setting / GamePass / RedPoint 只读镜像
	- Combat：会话战斗属性与 GetDmg 公式（权威承伤仍走服 SystemPlrAttr）
	- 一期占位：IsPlrInPotionFlow / GetIsFly / GetSkillMpTierEffects（恒 false / 倍率 1）

	导出方式：
	- 命名空间：GetData.Bag.*、GetData.Entry.*、GetData.BagCapacity.*、GetData.BagView.*、GetData.Mirror.*、GetData.Combat.*
	- 扁平兼容：GetData.GetItemCountByID 等（与旧单文件 API 一致；不扁平 BagCapacity / BagView）

	与相关模块的关系：
	- 权威增删改走 SystemBag；本模块只读 Instance 与本地/会话缓存
	- Combat.SetPlrAttr 是会话 Instance 写助手段，仅服务端 SystemPlrAttr 应调用
	- GetDmg.finalDamage 须由服 DamageResolver / HitResolver 预结算，禁止客上报当最终事实
	- RunService:IsClient 仅用于「无 Instance 时回退 PlayerData」，不是权威结算分流

	加载方式：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local GetData = Utils.GetData

	使用示例：
		local count = GetData.GetItemCountByID(plr, EnumMgr.ItemID.Coin)
		local count2 = GetData.Bag.GetItemCountByID(plr, EnumMgr.ItemID.Coin)
		local itemData, cfg = GetData.GetDataAndCfg(onlyID)
		local list = GetData.BagView.Query(plr, GetData.BagView.Filter.ByType(EnumMgr.ItemType.Pet))
		local hasPass = GetData.Mirror.IsHasPass(plr, passTag)
		local dmg, isCrit = GetData.GetDmg(atkModel, beHitPlr, { damageRate = 1 })
]]

-- ========================================
-- 模块引用
-- ========================================
local Bag = require(script.Bag)
local BagEntry = require(script.BagEntry)
local BagCapacity = require(script.BagCapacity)
local BagView = require(script.BagView)
local PlayerMirror = require(script.PlayerMirror)
local Combat = require(script.Combat)

-- ========================================
-- 模块定义
-- ========================================
local GetData = {
	Bag = Bag,
	Entry = BagEntry,
	BagCapacity = BagCapacity,
	BagView = BagView,
	Mirror = PlayerMirror,
	Combat = Combat,
}

-- ========================================
-- 私有函数
-- ========================================

--[[
	将子模块中的函数扁平挂到门面上（仅 function，且门面未占用同名键）
	@param subModule table - 子模块导出表（键为 API 名，值为 function）
]]
local function _mergeFlatApi(subModule: { [string]: any })
	for apiName, apiFn in subModule do
		if type(apiFn) == "function" and GetData[apiName] == nil then
			GetData[apiName] = apiFn
		end
	end
end

_mergeFlatApi(Bag)
_mergeFlatApi(BagEntry)
_mergeFlatApi(PlayerMirror)
_mergeFlatApi(Combat)

-- ========================================
-- 公共函数
-- ========================================

--[[
	是否处于炼药流程（一期恒 false；SkillSyncRouter 画质过滤用）
	@param _plr Player - 玩家
	@return boolean - 始终 false
]]
function GetData.IsPlrInPotionFlow(_plr: Player): boolean
	return false
end

--[[
	是否处于飞行状态（一期恒 false）
	@param _plr Player - 玩家
	@return boolean - 始终 false
]]
function GetData.GetIsFly(_plr: Player): boolean
	return false
end

--[[
	技能药水挡位效果（一期占位；完整挡位表二期再迁）
	@param _mpTp string? - 挡位字符串；一期忽略
	@return { damageRateMul: number } - 伤害倍率等；一期恒 damageRateMul=1
]]
function GetData.GetSkillMpTierEffects(_mpTp: string?): { damageRateMul: number }
	return { damageRateMul = 1 }
end

--[[
	技能药水挡位 → 伤害倍率（HitResolver 路径）
	@param mpTp string? - 挡位字符串；一期忽略
	@return number - 倍率；一期恒 1
]]
function GetData.GetSkillMpTierDamageRateMul(mpTp: string?): number
	return GetData.GetSkillMpTierEffects(mpTp).damageRateMul
end

return GetData
