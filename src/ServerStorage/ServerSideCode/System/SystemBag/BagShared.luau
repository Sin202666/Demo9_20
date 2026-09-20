--[[
	Module: BagShared
	Description: SystemBag 共享常量与背包数据访问工具
	Author: 林奥宇
	Created: 2026-06-30
	Last Modified: 2026-09-04

	背包条目形（存档 Bag[tostring(onlyID)]）：
		{ id: number, tp: number?, count: number, onlyID: number, lock: number|boolean?, equip: number? }
	equip：0/缺省=仓库，1~N=快捷栏。错误码含 BAG_FULL（满仓；仅 opts.capacity 对应策略填了 max 时才会返回）
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local PlayerData = Utils.PlayerData
local CfgFind = Utils.CfgFind
local EnumMgr = Utils.EnumMgr
local GetData = Utils.GetData

local BagCapacity = GetData.BagCapacity

-- ========================================
-- 模块定义
-- ========================================
local BagShared = {}

-- ========================================
-- 常量定义
-- ========================================
BagShared.ERROR_INVALID_PLAYER = "INVALID_PLAYER"
BagShared.ERROR_NO_BAG_DATA = "NO_BAG_DATA"
BagShared.ERROR_INVALID_ITEM = "INVALID_ITEM"
BagShared.ERROR_INVALID_PARAM = "INVALID_PARAM"
BagShared.ERROR_ITEM_LOCKED = "ITEM_LOCKED"
BagShared.ERROR_INSUFFICIENT = "INSUFFICIENT_COUNT"
BagShared.ERROR_NOT_TRADEABLE = "NOT_TRADEABLE"
BagShared.ERROR_NOT_FOUND = "NOT_FOUND"
BagShared.ERROR_BAG_FULL = "BAG_FULL"

BagShared.itemdataConf = CfgFind.GetCfgByName("itemdataConf")

-- ========================================
-- 公共函数
-- ========================================

--[[
	校验玩家对象是否有效

	@param player Player - 玩家对象
	@return boolean - 是否有效
]]
function BagShared.validatePlayer(player: Player): boolean
	return player ~= nil and player:IsA("Player")
end

--[[
	从配置表键或条目解析物品 ID

	@param configKey string | number - 配置表键
	@param configEntry table? - 配置行，字段含 id: number?
	@return number? - 物品 ID
]]
function BagShared.resolveItemId(configKey: string | number, configEntry: any): number?
	local itemId = if configEntry then configEntry.id else nil
	return tonumber(itemId or configKey)
end

--[[
	获取玩家背包数据表

	@param plr Player - 玩家对象
	@return table? - 存档 Bag 活引用（仅内部写路径）；未加载为 nil。对外查询须深拷贝
]]
function BagShared.getBagData(plr: Player): any
	local plrData = PlayerData.GetPlrData(plr)
	if not plrData then
		return nil
	end
	return plrData.Bag
end

--[[
	判断物品是否可叠加（规则只来自 GetData.BagCapacity.Stack.Default）

	@param cfg table - 物品配置行，字段含 hasCount: number?
	@return boolean - 是否可叠加
]]
function BagShared.isStackable(cfg: any): boolean
	return BagCapacity.IsStackable(cfg)
end

--[[
	判断背包条目是否处于锁定状态

	@param itemData table - 背包条目，字段含 lock: number|boolean?
	@return boolean - 是否锁定
]]
function BagShared.isItemLocked(itemData: any): boolean
	local lock = itemData.lock
	return lock == EnumMgr.BagLock.Locked or lock == true
end

--[[
	将锁定状态布尔值转为存档数值

	@param lockState boolean - 是否锁定
	@return number - EnumMgr.BagLock.Locked / Unlocked
]]
function BagShared.toLockValue(lockState: boolean): number
	return if lockState then EnumMgr.BagLock.Locked else EnumMgr.BagLock.Unlocked
end

--[[
	分配并递增玩家背包唯一 ID

	@param plr Player - 玩家对象
	@return number - 新的 onlyID
]]
function BagShared.getOnlyID(plr: Player): number
	local plrData = PlayerData.GetPlrData(plr)
	local onlyID = (plrData.onlyID or 1) + 1
	PlayerData.ChangePlrData(plr, "onlyID", onlyID)
	return onlyID
end

return BagShared
