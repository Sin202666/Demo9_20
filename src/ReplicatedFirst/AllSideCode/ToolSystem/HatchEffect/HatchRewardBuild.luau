--[[
	Module: HatchEffect/HatchRewardBuild
	Description: 从物品 ID 构建抽蛋奖励模型列表
	Author: 林奥宇
	Created: 2026-01-29
	Last Modified: 2026-09-01

	由 HatchEffect.init 内部调用。GetModel 默认 Clone，调用方负责 Debris / 销毁。
]]

-- ============================================================================
-- 依赖
-- ============================================================================

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local VisibleMgr = Utils.VisibleMgr
local EnumMgr = Utils.EnumMgr
local CfgFind = Utils.CfgFind
local ResourceUtil = Utils.ResourceUtil
local Log = Utils.Log

local HatchRewardBuild = {}

-- ============================================================================
-- 私有函数
-- ============================================================================

--[[
	克隆并配置单个宠物奖励模型。

	@param itemId number - 宠物 CfgFind ID（EnumMgr.ItemType.Pet）
	@return Model? - 已关闭拖尾/碰撞的克隆模型；缺配置或 GetModel 失败时 nil
]]
local function _buildPetModel(itemId: number): Model?
	local rewardCfg = CfgFind.FindCfgByID(tonumber(itemId), EnumMgr.ItemType.Pet)
	if not rewardCfg or not rewardCfg["Model"] then
		Log.warn(itemId, "缺少模型")
		return nil
	end

	local rewardModel = ResourceUtil.GetModel(ResourceUtil.ModelCategory.Pet, rewardCfg["Model"])
	if not rewardModel then
		Log.warn(itemId, "缺少模型实例")
		return nil
	end

	VisibleMgr.DisableTrail(rewardModel)
	VisibleMgr.AnchoredAll(rewardModel)
	VisibleMgr.UnCollideAll(rewardModel)
	VisibleMgr.UnTouchAll(rewardModel)
	VisibleMgr.UnQueryAll(rewardModel)

	rewardModel:SetAttribute("xyd", rewardCfg["xyd"])
	rewardModel:SetAttribute("idle", rewardCfg["NormalIdleName"])

	return rewardModel
end

-- ============================================================================
-- 公共 API
-- ============================================================================

--[[
	按配置稀有度 xyd 降序排列物品 ID（与模型 / PetInfo 展示顺序一致）。
	返回新表，不修改入参。

	@param itemIds {number} - 宠物 ID 列表
	@return {number} - 按 xyd 降序的 ID 副本；缺配置的 ID 视为 xyd=0
]]
function HatchRewardBuild.sortItemIdsByXyd(itemIds: {number}): {number}
	local sortedIds = table.clone(itemIds)

	table.sort(sortedIds, function(idA, idB)
		local cfgA = CfgFind.FindCfgByID(idA, EnumMgr.ItemType.Pet)
		local cfgB = CfgFind.FindCfgByID(idB, EnumMgr.ItemType.Pet)
		local xydA = cfgA and cfgA["xyd"] or 0
		local xydB = cfgB and cfgB["xyd"] or 0
		return xydA > xydB
	end)

	return sortedIds
end

--[[
	从物品 ID 列表构建奖励模型表。
	部分 ID 构建失败时跳过该条；结果再按 Attribute xyd 降序（防御未预排序的调用）。

	@param itemIds {number} - 宠物 ID 列表（建议已按 xyd 降序）
	@return {Model} - 可展示的克隆模型列表，可能为空
]]
function HatchRewardBuild.buildPetModels(itemIds: {number}): {Model}
	local rewardModels: {Model} = {}

	for _, itemId in ipairs(itemIds) do
		local rewardModel = _buildPetModel(itemId)
		if rewardModel then
			table.insert(rewardModels, rewardModel)
		end
	end

	table.sort(rewardModels, function(a, b)
		return a:GetAttribute("xyd") > b:GetAttribute("xyd")
	end)

	return rewardModels
end

return HatchRewardBuild
