--[[
	Module: BagUseItem
	Description: 消耗品使用与 UseScript 预加载
	Author: 林奥宇
	Created: 2026-06-30
	Last Modified: 2026-08-31
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local PlayerData = Utils.PlayerData
local EnumMgr = Utils.EnumMgr
local CfgFind = Utils.CfgFind
local Log = Utils.Log
local ServerStorage = Utils.ServerStorage

local BagInventory = require(script.Parent.BagInventory)

-- ========================================
-- 模块定义
-- ========================================
local BagUseItem = {}

-- ========================================
-- 私有变量
-- ========================================
local _useScriptCache: { [string]: any } = {}

do
	local itemScriptFolder = ServerStorage.ServerSideCode.ItemScript
	for _, child in itemScriptFolder:GetChildren() do
		if child:IsA("ModuleScript") then
			_useScriptCache[child.Name] = require(child)
		end
	end
end

-- ========================================
-- 公共函数
-- ========================================

--[[
	使用消耗品

	@param plr Player - 玩家对象
	@param onlyID number - 唯一 ID
	@param num number? - 使用数量，默认 1
	@return any? - UseScript.Use 的返回值；脚本未约定统一字段形。校验失败、扣减失败或脚本报错为 nil
]]
function BagUseItem.UseItem(plr: Player, onlyID: number, num: number?)
	local numOnlyID = tonumber(onlyID) :: number?
	if not numOnlyID then
		return nil
	end

	onlyID = numOnlyID
	local useCount = num or 1
	if type(useCount) ~= "number" or useCount < 1 then
		return nil
	end
	useCount = math.floor(useCount)

	local itemData = PlayerData.GetPlrDataByKey(plr, { "Bag", tostring(onlyID) })
	if not itemData or type(itemData.count) ~= "number" or itemData.count < useCount then
		return nil
	end

	local cfg = CfgFind.FindCfgByID(itemData.id, EnumMgr.ItemType.UseItem)
	if not cfg then
		return nil
	end

	local useItemScript = _useScriptCache[cfg.UseScript]
	if not useItemScript then
		Log.warn("UseItem 未找到使用脚本:", cfg.UseScript)
		return nil
	end

	local itemId = itemData.id
	if BagInventory.RemoveItem(plr, { itemId }, { useCount }) ~= true then
		return nil
	end

	local ok, result = pcall(function()
		return useItemScript.Use(plr, cfg.parms, useCount)
	end)
	if not ok then
		Log.warn("UseItem 脚本执行失败:", cfg.UseScript, result)
		local restored = BagInventory.AddItems(plr, { itemId }, { useCount })
		if not restored then
			Log.warn("UseItem 回滚入包失败:", itemId, useCount)
		end
		return nil
	end

	return result
end

return BagUseItem
