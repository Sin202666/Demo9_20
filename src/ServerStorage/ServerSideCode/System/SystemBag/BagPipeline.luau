--[[
	Module: BagPipeline
	Description: 入包管线（容量预检 + 写入 + 现有 Bindable）；不 require 其它 System
	Author: 林奥宇
	Created: 2026-09-04
	Last Modified: 2026-09-04

	功能：
	- AddItems：可选第 4 参 opts.capacity；默认 None 不检满仓
	- 满仓整批拒绝，错误码 BAG_FULL；不写一半
	- 写入后只广播已有 RECORD_ITEM_GAIN，禁止钩子再入包成环

	与 BagInventory / BagCapacity 的关系：
	- 本模块是 AddItems 的实际写路径；Inventory 门面保持原签名兼容
	- 容量/堆叠只查 GetData.BagCapacity 闭集表
	- GRANT_AWARD / 商店 / 邮件 / 签到不传 opts，行为与改前一致
	- 不要在此 require SystemTool / SystemTask / 其它 System

	加载方式（仅 SystemBag 内部）：
		local BagPipeline = require(script.Parent.BagPipeline)

	使用示例：
		local ok, onlyIdOrErr = BagPipeline.AddItems(plr, ids, counts)
		local ok2, err = BagPipeline.AddItems(plr, ids, counts, { capacity = BagCapacity.Capacity.None })
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local PlayerData = Utils.PlayerData
local CfgFind = Utils.CfgFind
local Log = Utils.Log
local NetMsg = Utils.NetMsg
local NetWork = Utils.NetWork
local GetData = Utils.GetData

local BagShared = require(script.Parent.BagShared)
local BagValueSync = require(script.Parent.BagValueSync)

local BagCapacity = GetData.BagCapacity

local BagPipeline = {}

-- ========================================
-- 私有函数
-- ========================================

--[[
	可叠物品写入：已有格加 count，否则新建一行

	@param plr Player - 玩家对象
	@param itemID number - 物品 ID
	@param addCount number - 数量
	@param cfg table - 物品配置行
	@param bagData table - 当前 Bag 字典
	@return number?, { number } - last onlyID、新建行 onlyID；失败 nil, {}
]]
local function _writeStackable(
	plr: Player,
	itemID: number,
	addCount: number,
	cfg: any,
	bagData: any
): (number?, { number })
	local newOnlyIds: { number } = {}
	for slotKey, slotData in bagData do
		if slotData.id == itemID then
			local nowCount = bagData[slotKey].count + addCount
			local addOnlyID = bagData[slotKey].onlyID
			PlayerData.ChangePlrData(plr, { "Bag", slotKey, "count" }, nowCount)
			return addOnlyID, newOnlyIds
		end
	end

	local newOnlyID = BagShared.getOnlyID(plr)
	local addOnlyID = tonumber(newOnlyID)
	PlayerData.ChangePlrData(plr, { "Bag", tostring(addOnlyID) }, {
		id = itemID,
		tp = cfg.tp,
		count = addCount,
		onlyID = newOnlyID,
	})
	if addOnlyID then
		table.insert(newOnlyIds, addOnlyID)
	end
	return addOnlyID, newOnlyIds
end

--[[
	不可叠物品写入：每件一行

	@param plr Player - 玩家对象
	@param itemID number - 物品 ID
	@param addCount number - 件数
	@param cfg table - 物品配置行
	@return number?, { number } - last onlyID、新建行 onlyID；失败 nil, {}
]]
local function _writeUnique(plr: Player, itemID: number, addCount: number, cfg: any): (number?, { number })
	local newOnlyIds: { number } = {}
	local addOnlyID: number? = nil
	for _ = 1, addCount do
		local newOnlyID = BagShared.getOnlyID(plr)
		addOnlyID = tonumber(newOnlyID)
		PlayerData.ChangePlrData(plr, { "Bag", tostring(newOnlyID) }, {
			id = itemID,
			tp = cfg.tp,
			count = 1,
			onlyID = newOnlyID,
		})
		if addOnlyID then
			table.insert(newOnlyIds, addOnlyID)
		end
	end
	return addOnlyID, newOnlyIds
end

--[[
	向背包写入单个物品（不检容量；调用方已预检）

	@param plr Player - 玩家对象
	@param itemID number - 物品 ID
	@param itemCount number? - 数量，默认 1
	@return number?, { number } - last onlyID、本调用新建行的 onlyID 列表；失败 nil, {}
]]
local function _writeItem(plr: Player, itemID: number, itemCount: number?): (number?, { number })
	local emptyIds: { number } = {}
	itemCount = itemCount or 1

	local numItemID = tonumber(itemID) :: number?
	local numItemCount = tonumber(itemCount) :: number?
	if not numItemID or not numItemCount then
		return nil, emptyIds
	end

	itemID = numItemID
	local addCount = math.floor(numItemCount)
	if not BagShared.validatePlayer(plr) or itemID == 0 or addCount < 0 then
		return nil, emptyIds
	end

	local cfg = CfgFind.FindCfgByID(itemID)
	if not cfg then
		Log.warn("没有这个物品的配置表:", itemID)
		return nil, emptyIds
	end

	local bagData = BagShared.getBagData(plr)
	if not bagData then
		return nil, emptyIds
	end

	local addOnlyID: number?
	local newOnlyIds: { number }
	if BagShared.isStackable(cfg) then
		addOnlyID, newOnlyIds = _writeStackable(plr, itemID, addCount, cfg, bagData)
	else
		addOnlyID, newOnlyIds = _writeUnique(plr, itemID, addCount, cfg)
	end

	if not addOnlyID then
		return nil, newOnlyIds
	end

	NetWork.FireBindable(NetMsg.RECORD_ITEM_GAIN, { plr, itemID, addCount })
	BagValueSync.update(plr)
	return addOnlyID, newOnlyIds
end

--[[
	解析 AddItems 第 4 参；缺省为 None

	@param opts { capacity: string? }? - 可选；capacity 为 BagCapacity.Capacity 键
	@return string?, string? - 策略名；失败时第二值为 INVALID_PARAM
]]
local function _resolveOptsCapacity(opts: any): (string?, string?)
	if opts == nil then
		return BagCapacity.Capacity.None, nil
	end
	if type(opts) ~= "table" then
		return nil, BagShared.ERROR_INVALID_PARAM
	end
	if opts.capacity == nil then
		return BagCapacity.Capacity.None, nil
	end
	if type(opts.capacity) ~= "string" or not BagCapacity.HasCapacityPolicy(opts.capacity) then
		return nil, BagShared.ERROR_INVALID_PARAM
	end
	return opts.capacity, nil
end

-- ========================================
-- 公共函数
-- ========================================

--[[
	批量添加物品（可选容量策略；默认不检满仓）

	@param plr Player - 玩家对象
	@param itemIDVt {number} - 物品 ID 列表
	@param itemCountVt {number} - 对应数量列表
	@param opts { capacity: string? }? - 可选；capacity 为 BagCapacity.Capacity 键，默认 None
	@return boolean, number|string?, { number }? - 成功 true、最后 onlyID、新建行 onlyID 列表；失败 false 与 errorCode
]]
function BagPipeline.AddItems(
	plr: Player,
	itemIDVt: { number },
	itemCountVt: { number },
	opts: { capacity: string? }?
): (boolean, number | string?, { number }?)
	if not BagShared.validatePlayer(plr) then
		return false, BagShared.ERROR_INVALID_PLAYER
	end
	if type(itemIDVt) ~= "table" or type(itemCountVt) ~= "table" then
		return false, BagShared.ERROR_INVALID_PARAM
	end

	local policyName, optsErr = _resolveOptsCapacity(opts)
	if not policyName then
		return false, optsErr
	end

	local bagData = BagShared.getBagData(plr)
	if not bagData then
		return false, BagShared.ERROR_NO_BAG_DATA
	end

	local batchItems = {}
	for index, itemId in itemIDVt do
		local cfg = CfgFind.FindCfgByID(itemId)
		if cfg then
			table.insert(batchItems, {
				id = itemId,
				count = itemCountVt[index],
				cfg = cfg,
			})
		else
			Log.warn("AddItems 跳过无效物品配置:", itemId)
		end
	end

	if BagCapacity.WouldExceedBatch(bagData, batchItems, policyName) then
		return false, BagShared.ERROR_BAG_FULL
	end

	local lastOnlyID: number? = nil
	local addedAny = false
	local newOnlyIds: { number } = {}

	for _, item in ipairs(batchItems) do
		local addOnlyID, createdIds = _writeItem(plr, item.id, item.count)
		if addOnlyID then
			addedAny = true
			lastOnlyID = addOnlyID
			for _, createdId in ipairs(createdIds) do
				table.insert(newOnlyIds, createdId)
			end
		end
	end

	if not addedAny then
		return false, BagShared.ERROR_INVALID_ITEM
	end

	return true, lastOnlyID, newOnlyIds
end

return BagPipeline
