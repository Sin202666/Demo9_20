--[[
	Module: GetData.Bag
	Description: 背包数量只读查询（Bag/Shard NumberValue、客户端 Bag 字典回退、Wait 就绪）
	Author: 林奥宇
	Created: 2026-07-03
	Last Modified: 2026-09-04

	功能：
	- GetItemCountByID：读 Player 下 Bag / Shard NumberValue
	- GetItemCountByIDOnClient：仅客户端；无 NumberValue 时按字典统计 PlayerData.Bag
	- WaitBagNumberValue：无限等待 Bag 下对应 id 的 NumberValue（顶栏 UI 绑 Changed）

	与 GetData.Entry / PlayerMirror 的关系：
	- 本模块按物品 id 读数量或等待 NumberValue；不按 onlyID 查条目
	- 条目 + 配置见 GetData.Entry；设置与 GamePass 见 GetData.Mirror
	- IsClient 仅用于「无 Instance 时回退会话缓存」，不是权威结算

	加载方式（一般由 GetData/init 聚合，勿直接 Utils 访问）：
		local Bag = require(script.Bag)
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local RunService = Utils.RunService
local PlayerData = Utils.PlayerData
local Players = Utils.Players
local Log = Utils.Log

-- ========================================
-- 模块定义
-- ========================================
local Bag = {}

-- ========================================
-- 常量定义
-- ========================================
local BAG_FOLDER = "Bag"
local SHARD_FOLDER = "Shard"
local SAVE_KEY_BAG = "Bag"

-- ========================================
-- 私有函数
-- ========================================

--[[
	从 Bag 字典统计指定 id 的数量（无 NumberValue 时的回退；可叠累加 count，否则按行计 1）

	@param bagData table - PlayerData.Bag 字典 { [tostring(onlyID)]: { id, count?, ... } }
	@param itemID number - 物品 id
	@return number - 持有数量
]]
local function _countItemInBagByID(bagData: { any }, itemID: number): number
	local hasNum = 0
	for _, entry in pairs(bagData) do
		if type(entry) == "table" and entry.id == itemID then
			local n = tonumber(entry.count)
			if n then
				hasNum += n
			else
				hasNum += 1
			end
		end
	end
	return hasNum
end

--[[
	读取 Folder 下名为 itemID 的 NumberValue
	@param folder Instance - Bag 或 Shard 文件夹
	@param itemID number - 物品 id（与 NumberValue.Name 对应）
	@return number? - 数量；无 NumberValue 为 nil
]]
local function _readNumberValue(folder: Instance, itemID: number): number?
	local itemValue = folder:FindFirstChild(tostring(itemID))
	if itemValue and itemValue:IsA("NumberValue") then
		return itemValue.Value
	end
	return nil
end

-- ========================================
-- 公共函数
-- ========================================

--[[
	客户端获取物品数量（通过 id）；优先 Bag NumberValue，否则按字典统计本地 Bag
	@param itemID number - 物品 id
	@return number? - 物品数量；非客户端调用返回 nil
]]
function Bag.GetItemCountByIDOnClient(itemID: number): number?
	if not RunService:IsClient() then
		Log.warn("GetData.Bag.GetItemCountByIDOnClient 必须客户端调用")
		return nil
	end

	local plr = Players.LocalPlayer
	local bagFolder: Folder? = plr:FindFirstChild(BAG_FOLDER) :: Folder?
	if not bagFolder then
		local bagData = PlayerData.GetPlrDataByKey(plr, SAVE_KEY_BAG)
		if type(bagData) ~= "table" then
			return 0
		end
		return _countItemInBagByID(bagData, itemID)
	end

	local fromValue = _readNumberValue(bagFolder, itemID)
	if fromValue ~= nil then
		return fromValue
	end

	local bagData = PlayerData.GetPlrDataByKey(plr, SAVE_KEY_BAG)
	if type(bagData) ~= "table" then
		return 0
	end
	return _countItemInBagByID(bagData, itemID)
end

--[[
	获取玩家背包或 Shard 文件夹内某物品的数量（读 NumberValue）
	@param plr Player - 玩家对象
	@param itemID number - 物品 id
	@return number - 物品数量；玩家无效或未找到为 0
]]
function Bag.GetItemCountByID(plr: Player, itemID: number): number
	if not plr then
		return 0
	end

	local bagFolder: Folder? = plr:FindFirstChild(BAG_FOLDER) :: Folder?
	if bagFolder then
		local fromBag = _readNumberValue(bagFolder, itemID)
		if fromBag ~= nil then
			return fromBag
		end
	end

	local shardFolder: Folder? = plr:FindFirstChild(SHARD_FOLDER) :: Folder?
	if not shardFolder then
		return 0
	end

	return _readNumberValue(shardFolder, itemID) or 0
end

--[[
	等待背包数值 Instance 出现（客户端 UI 绑定 Change 事件用）
	启动路径必须拿到实例，故超时为无限；plr 无效或类型不符时 error
	@param plr Player - 玩家对象
	@param itemID number - 物品 id
	@return NumberValue - Bag 下对应 id 的 NumberValue
]]
function Bag.WaitBagNumberValue(plr: Player, itemID: number): NumberValue
	if typeof(plr) ~= "Instance" or not plr:IsA("Player") then
		error("GetData.Bag.WaitBagNumberValue: plr is required")
	end

	local bagFolder = plr:WaitForChild(BAG_FOLDER, math.huge)
	if not bagFolder:IsA("Folder") then
		error("GetData.Bag.WaitBagNumberValue: Bag is not a Folder")
	end

	local itemValue = bagFolder:WaitForChild(tostring(itemID), math.huge)
	if not itemValue:IsA("NumberValue") then
		error("GetData.Bag.WaitBagNumberValue: item value is not NumberValue")
	end
	return itemValue
end

return Bag
