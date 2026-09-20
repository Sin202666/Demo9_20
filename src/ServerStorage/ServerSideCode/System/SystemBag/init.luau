--[[
	Module: SystemBag
	Description: 背包领域业务逻辑（物品增删查、锁定、交易与使用）
	Author: 林奥宇
	Created: 2026-06-30
	Last Modified: 2026-09-04

	功能：
	- 物品增删查、锁定、交易扣除、消耗品使用（服务端权威）
	- 入包管线 BagPipeline：AddItems 可选 opts.capacity，默认 None 不检满仓
	- SetEquip：唯一写 Bag.equip（0=仓库，1~N=快捷栏；仅 Filter.Toolbar）
	- RegisterNetWork：GRANT_AWARD Bindable + BAG_LOCK_ITEMS Remote（lockAll 由服扫 Window）
	- BAG_LOCK_ITEMS：GameConfig「背包UI.启用」= false 时拒绝；不关 AddItems / GRANT_AWARD
	- 玩家 Bag 文件夹 NumberValue 镜像（供 GetData / 客户端读数量）
	- 仅对新存档发放 itemdataConf.newPlayerInit 初始物品
	- 同端 Bindable GRANT_AWARD 入包（不传 opts）

	与相关模块的关系：
	- SystemSave / PlayerData：会话读写只经 PlayerData.ChangePlrData（内部 ChangeStat）
	- GetData：只读 Bag NumberValue 或客户端缓存，禁止当发出入口；容量表 GetData.BagCapacity
	- SystemShop / SystemEmail / SystemCode / SystemDailyAward / SystemBuyRoblox：发奖调用 AddItems
	- SystemRecord：监听 RECORD_ITEM_GAIN / RECORD_ITEM_REMOVE Bindable
	- 结构补全与版本迁移不在本模块；进服不按配表 init 抬堆叠

	加载方式（仅服务端）：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local SystemBag = Utils.SystemBag

	使用示例：
		SystemBag.SetupPlayerBag(player)
		SystemBag.InitNewPlayerItemsIfNeeded(player, isNewFromSave)
		local ok, onlyIdOrErr = SystemBag.AddItems(player, { itemId }, { count })
		local ok2, err = SystemBag.AddItems(player, { itemId }, { count }, { capacity = "None" })
		if ok then
			SystemBag.SetEquip(player, onlyIdOrErr, 1)
			SystemBag.UseItem(player, onlyIdOrErr)
		end

	约束：
		- 修改类成功 true，失败 false + UPPER_SNAKE_CASE errorCode（见 BagShared.ERROR_*，含 BAG_FULL）
		- AddItems 成功时第二值为最后写入的 onlyID；第 4 参 opts 可省略
		- RemoveTradeItem 成功时第二值为扣除条目拷贝
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local NetWork = Utils.NetWork
local NetMsg = Utils.NetMsg
local EnumMgr = Utils.EnumMgr
local RequestRateLimit = Utils.RequestRateLimit
local GetData = Utils.GetData
local SystemGameConfig = Utils.SystemGameConfig

local BagShared = require(script.BagShared)
local BagValueSync = require(script.BagValueSync)
local BagInventory = require(script.BagInventory)
local BagTrade = require(script.BagTrade)
local BagUseItem = require(script.BagUseItem)
local BagEquip = require(script.BagEquip)

-- ========================================
-- 模块定义
-- ========================================
local SystemBag = {}

local BagCapacity = GetData.BagCapacity

local MAX_LOCK_LIST = 64
local RATE_LOCK_MAX = 8
local RATE_LOCK_WINDOW_SEC = 2
local BAG_UI_ENABLED_PATH = { "背包UI", "启用" }

-- ========================================
-- 私有函数
-- ========================================

--[[
	背包 UI 是否启用（只门控锁物品 Remote；不关库存）
	@return boolean - true 表示启用
]]
local function _isBagUiEnabled(): boolean
	return SystemGameConfig.GetValue(BAG_UI_ENABLED_PATH) ~= false
end

--[[
	按 itemdataConf.newPlayerInit 为新玩家发放初始物品

	@param plr Player - 玩家对象
	@return nil
]]
local function _grantNewPlayerItems(plr: Player)
	for configKey, configEntry in BagShared.itemdataConf do
		if configEntry.isShow == EnumMgr.BagShow.InBag
			and configEntry.hasCount == EnumMgr.BagStack.Stackable
			and tonumber(configEntry.newPlayerInit)
		then
			local itemId = BagShared.resolveItemId(configKey, configEntry)
			if itemId then
				SystemBag.AddItems(plr, { itemId }, { tonumber(configEntry.newPlayerInit) })
			end
		end
	end
end

--[[
	收集 Window 白名单 onlyID（lockAll 由服枚举，不信客机全表）

	@param plr Player - 玩家对象
	@param wantLock boolean? - nil 表示全部 Window 行；true 仅未锁，false 仅已锁
	@return { number } - onlyID 列表
]]
local function _collectWindowOnlyIds(plr: Player, wantLock: boolean?): { number }
	local result = {}
	local bagData = BagShared.getBagData(plr)
	if type(bagData) ~= "table" then
		return result
	end
	for _, row in pairs(bagData) do
		if type(row) == "table" and BagCapacity.IsFilterType(BagCapacity.Filter.Window, row.tp) then
			local onlyID = tonumber(row.onlyID) or 0
			if onlyID > 0 then
				local locked = BagShared.isItemLocked(row)
				if wantLock == nil or (wantLock and not locked) or (wantLock == false and locked) then
					table.insert(result, onlyID)
				end
			end
		end
	end
	return result
end

--[[
	校验客机提交的 onlyID 列表：存在 + Window 类型；超长截断

	@param plr Player - 玩家对象
	@param rawList any - 客机 onlyID 数组
	@return { number } - 合法 onlyID
]]
local function _filterSubmittedWindowOnlyIds(plr: Player, rawList: any): { number }
	local result = {}
	if type(rawList) ~= "table" then
		return result
	end
	local seen = 0
	for _, rawId in rawList do
		if seen >= MAX_LOCK_LIST then
			break
		end
		local onlyID = tonumber(rawId) or 0
		if onlyID > 0 then
			local item = SystemBag.GetItemByOnlyID(plr, onlyID)
			if type(item) == "table" and BagCapacity.IsFilterType(BagCapacity.Filter.Window, item.tp) then
				table.insert(result, onlyID)
				seen += 1
			end
		end
	end
	return result
end

--[[
	BAG_LOCK_ITEMS：单条 / 列表 / lockAll|unlockAll（后者由服扫包）

	@param player Player - 玩家
	@param data any - { onlyID, isLock } 或 { onlyIDs, isLock } 或 { mode }
	@return nil
]]
local function _onBagLockItems(player: Player, data: any)
	if not _isBagUiEnabled() then
		return
	end
	if not player or not player.Parent then
		return
	end
	if type(data) ~= "table" then
		return
	end

	local mode = data.mode
	if mode == EnumMgr.BagLockMode.LockAll then
		local ids = _collectWindowOnlyIds(player, true)
		if #ids > 0 then
			SystemBag.LockItem(player, ids, true)
		end
		return
	end
	if mode == EnumMgr.BagLockMode.UnlockAll then
		local ids = _collectWindowOnlyIds(player, false)
		if #ids > 0 then
			SystemBag.LockItem(player, ids, false)
		end
		return
	end

	local onlyID = tonumber(data.onlyID)
	local isLock = data.isLock
	if onlyID and onlyID > 0 and (isLock == 0 or isLock == 1 or type(isLock) == "boolean") then
		local filtered = _filterSubmittedWindowOnlyIds(player, { onlyID })
		if #filtered > 0 then
			local lockState = if isLock == true or isLock == 1 then true else false
			SystemBag.LockItem(player, filtered, lockState)
		end
		return
	end

	if type(data.onlyIDs) == "table" and (isLock == 0 or isLock == 1 or type(isLock) == "boolean") then
		local filtered = _filterSubmittedWindowOnlyIds(player, data.onlyIDs)
		if #filtered > 0 then
			local lockState = if isLock == true or isLock == 1 then true else false
			SystemBag.LockItem(player, filtered, lockState)
		end
	end
end

-- ========================================
-- 公共函数（聚合子模块）
-- ========================================

SystemBag.GetItemByOnlyID = BagInventory.GetItemByOnlyID
SystemBag.GetItemCountByID = BagInventory.GetItemCountByID
SystemBag.AddData = BagInventory.AddData
SystemBag.AddItems = BagInventory.AddItems
SystemBag.RemoveAllItem = BagInventory.RemoveAllItem
SystemBag.RemoveItemByOnlyID = BagInventory.RemoveItemByOnlyID
SystemBag.RemoveItem = BagInventory.RemoveItem

SystemBag.CanRemove = BagTrade.CanRemove
SystemBag.RemoveTradeItem = BagTrade.RemoveTradeItem
SystemBag.LockItem = BagTrade.LockItem

SystemBag.UseItem = BagUseItem.UseItem
SystemBag.SetEquip = BagEquip.SetEquip
SystemBag.SwapToolbarSlots = BagEquip.SwapToolbarSlots

--[[
	玩家数据加载后同步 Bag Value 实例（不改存档数量）

	@param plr Player - 玩家对象
	@return nil
]]
function SystemBag.SetupPlayerBag(plr: Player)
	local bagData = BagShared.getBagData(plr)
	if not bagData then
		return
	end

	BagValueSync.createValueInstances(plr)
	BagValueSync.update(plr)
end

--[[
	仅当 SystemSave 判定为新存档时发放初始物品

	@param plr Player - 玩家对象
	@param isNewFromSave boolean - SystemSave.InitialPlayerData 返回的是否新玩家
	@return boolean - 是否执行了新玩家物品发放
]]
function SystemBag.InitNewPlayerItemsIfNeeded(plr: Player, isNewFromSave: boolean): boolean
	if not isNewFromSave then
		return false
	end

	_grantNewPlayerItems(plr)
	return true
end

--[[
	注册背包通信（GRANT_AWARD Bindable + BAG_LOCK_ITEMS Remote）

	@return nil
]]
function SystemBag.RegisterNetWork()
	if RequestRateLimit and RequestRateLimit.SetRateLimitConfig then
		RequestRateLimit.SetRateLimitConfig(NetMsg.BAG_LOCK_ITEMS, {
			maxRequests = RATE_LOCK_MAX,
			timeWindow = RATE_LOCK_WINDOW_SEC,
		})
	end

	NetWork.RegisterBindableEvent(NetMsg.GRANT_AWARD, function(data: any)
		local plr = data[1]
		local award = data[2]
		local count = data[3]
		if plr and award and count then
			SystemBag.AddItems(plr, award, count)
		end
	end)

	NetWork.RegisterServerRemoteEvent(NetMsg.BAG_LOCK_ITEMS, _onBagLockItems)
end

SystemBag.RegisterNetWork()

return SystemBag
