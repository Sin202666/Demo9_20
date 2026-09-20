--[[
	Module: BagValueSync
	Description: 玩家 Bag 文件夹与 NumberValue 实例同步
	Author: 林奥宇
	Created: 2026-06-30
	Last Modified: 2026-08-31
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local EnumMgr = Utils.EnumMgr
local CfgFind = Utils.CfgFind

local BagShared = require(script.Parent.BagShared)

-- ========================================
-- 模块定义
-- ========================================
local BagValueSync = {}

-- ========================================
-- 私有函数
-- ========================================

--[[
	获取或创建玩家下的 Bag 文件夹（用于客户端读取数量）

	@param plr Player - 玩家对象
	@return Folder - Bag 文件夹
]]
local function _getBagFolder(plr: Player): Folder
	local bagFolder: Folder? = plr:FindFirstChild("Bag") :: Folder?
	if not bagFolder then
		local newFolder = Instance.new("Folder")
		newFolder.Name = "Bag"
		newFolder.Parent = plr
		return newFolder :: Folder
	end
	return bagFolder :: Folder
end

-- ========================================
-- 公共函数
-- ========================================

--[[
	同步 Bag 文件夹下 NumberValue 与 GamePass 状态

	@param plr Player - 玩家对象
	@return nil
]]
function BagValueSync.update(plr: Player)
	local bagData = BagShared.getBagData(plr)
	if not bagData then
		return
	end

	local bagFolder = _getBagFolder(plr)
	local gamePassFolder: Folder? = plr:FindFirstChild(EnumMgr.PlayerInst.GamePassFolder) :: Folder?
	local passValuesByName: { [string]: NumberValue } = {}
	if gamePassFolder then
		for _, child in gamePassFolder:GetChildren() do
			if child:IsA("NumberValue") then
				passValuesByName[child.Name] = child
			end
		end
	end

	local valuesByName: { [string]: ValueBase } = {}
	for _, child in bagFolder:GetChildren() do
		if child:IsA("ValueBase") then
			child.Value = 0
			valuesByName[child.Name] = child
		end
	end

	for _, itemData in bagData do
		local valueIns = valuesByName[tostring(itemData.id)]
		if valueIns then
			valueIns.Value = itemData.count
		end

		if itemData.count and itemData.count > 0 then
			local cfg = CfgFind.FindCfgByID(itemData.id, EnumMgr.ItemType.GamePass)
			if cfg and cfg.OnlyTag then
				local passValue = passValuesByName[cfg.OnlyTag]
				if passValue then
					passValue.Value = 1
				end
			end
		end
	end
end

--[[
	为可叠加展示物品创建 Bag 下 NumberValue 实例

	@param plr Player - 玩家对象
	@return Folder - Bag 文件夹
]]
function BagValueSync.createValueInstances(plr: Player): Folder
	local bagFolder = _getBagFolder(plr)
	local existingNames: { [string]: boolean } = {}
	for _, child in bagFolder:GetChildren() do
		existingNames[child.Name] = true
	end

	for configKey, configEntry in BagShared.itemdataConf do
		if configEntry.isShow == EnumMgr.BagShow.InBag and configEntry.hasCount == EnumMgr.BagStack.Stackable then
			local itemId = BagShared.resolveItemId(configKey, configEntry)
			local valueName = if itemId then tostring(itemId) else nil
			if valueName and not existingNames[valueName] then
				local value = Instance.new("NumberValue")
				value.Name = valueName
				value.Value = 0
				value.Parent = bagFolder
				existingNames[valueName] = true
			end
		end
	end

	return bagFolder
end

return BagValueSync
