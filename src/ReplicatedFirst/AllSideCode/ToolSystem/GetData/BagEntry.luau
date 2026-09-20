--[[
	Module: GetData.BagEntry
	Description: 按 onlyID 查询背包条目及 CfgFind 配置（只读；条目深拷贝，配置为冻结引用）
	Author: 林奥宇
	Created: 2026-07-03
	Last Modified: 2026-09-01

	功能：
	- GetDataAndCfg：按 onlyID 查单条 Bag 记录 + CfgFind 配置行

	与 GetData.Bag 的关系：
	- Bag 按物品 id 读数量；本模块按 onlyID 查单条 Bag 记录 + 配置行
	- 条目由 Copy.deepCopy 返回；配置为 CfgFind 冻结只读引用（禁止写字段）
	- 省略 bagData 时仅客户端从 LocalPlayer.PlayerData 读取；服务端必须传入 bagData

	加载方式（一般由 GetData/init 聚合）：
		local BagEntry = require(script.BagEntry)
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local RunService = Utils.RunService
local CfgFind = Utils.CfgFind
local Copy = Utils.Copy
local PlayerData = Utils.PlayerData
local Players = Utils.Players

local BagEntry = {}

local SAVE_KEY_BAG = "Bag"

--[[
	在 Bag 数组中按 onlyID 查找条目（返回原表引用，调用方须再深拷贝）
	@param bagData table - 玩家 Bag 数组；元素含 onlyID / id / tp 字段
	@param onlyID number - 背包条目唯一 id
	@return table? - 匹配的背包条目原引用；未找到为 nil
]]
local function _findBagEntryByOnlyID(bagData: { any }, onlyID: number): { [string]: any }?
	for _, entry in pairs(bagData) do
		if entry.onlyID == onlyID then
			return entry
		end
	end
	return nil
end

--[[
	根据 onlyID 获取背包条目与配置（条目为副本；配置为冻结引用，不可篡改内存缓存）
	@param onlyID number - 背包条目 onlyID
	@param bagData table? - 可选 Bag 数组（元素含 onlyID、id、tp）；省略时仅客户端从 LocalPlayer PlayerData 读取
	@return table? - 背包条目深拷贝（含 id、tp、onlyID 等）
	@return table? - CfgFind 配置行冻结引用；未找到任一侧为 nil
]]
function BagEntry.GetDataAndCfg(onlyID: number, bagData: { any }?): ({ [string]: any }?, { [string]: any }?)
	if not onlyID then
		return nil, nil
	end

	if not bagData then
		if not RunService:IsClient() then
			return nil, nil
		end
		bagData = PlayerData.GetPlrDataByKey(Players.LocalPlayer, SAVE_KEY_BAG)
	end

	if type(bagData) ~= "table" then
		return nil, nil
	end

	local thisData = _findBagEntryByOnlyID(bagData, onlyID)
	if not thisData then
		return nil, nil
	end

	local cfg = CfgFind.FindCfgByID(thisData.id, thisData.tp)
	if not cfg then
		return nil, nil
	end

	return Copy.deepCopy(thisData), cfg
end

return BagEntry
