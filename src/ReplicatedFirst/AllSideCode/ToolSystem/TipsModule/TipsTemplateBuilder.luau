--[[
	Module: TipsTemplateBuilder
	Description: 服务端下发的模板类型 → 客户端提示数据构建
	Author: 林奥宇
	Created: 2026-07-02
	Last Modified: 2026-09-01

	功能：
	- 按 TipsConfig.SERVER_TEMPLATE_* 的 Type 构建多段 textData
	- 仅数据组装，不操作 UI（由 TipsRenderer.createTip 展示）
	- 文案经 TranslationHelper.TranslateByKey；须在客户端调用（跟随玩家 LocaleId）

	与兄弟模块：
	- TipsModule.NewShowTipsTemplate 只下发 Type 表，不在此构建
	- TipsRenderer.showFromServerTemplate 是本模块的标准入口

	【引入】
	local TipsTemplateBuilder = require(script.Parent.TipsTemplateBuilder)

	【示例】
	local tipData = TipsTemplateBuilder.buildFromServerData({
		Type = TipsConfig.SERVER_TEMPLATE_REWARD,
		ID = 1001,
		Count = 5,
	})
]]

-- ========================================
-- Requires
-- ========================================

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local TipsConfig = require(script.Parent.TipsConfig)

local TranslationHelper = Utils.TranslationHelper
local CfgFind = Utils.CfgFind
local Log = Utils.Log

-- ========================================
-- Module definition
-- ========================================

local TipsTemplateBuilder = {}

-- ========================================
-- Private functions
-- ========================================

--[[
	组装单段 textData（描边默认关闭，样式与 TipsConfig 模板一致）
	@param text string - 已翻译或直显的段文案
	@param textSize number - 字号，取 TipsConfig.TEXT_SIZE_*
	@param gradient any - UIGradientString：渐变色名（string）或稀有度（number）
	@return { [string]: any } - TipsRenderer 文本段配置
]]
local function _makeSegment(text: string, textSize: number, gradient: any): { [string]: any }
	return {
		Text = text,
		TextSize = textSize,
		Font = TipsConfig.DEFAULT_FONT,
		UIGradientString = gradient,
		UIStorke = 0,
		UIStorkeTransparency = 0,
		UIStorkeColor = TipsConfig.STROKE_COLOR,
	}
end

--[[
	构建「获得」类多段提示的公共前缀文本段
	@return { [string]: any } - 单段 textData（Text / TextSize / Font / UIGradientString / UIStorke*）
]]
local function _buildObtainPrefixSegment()
	return _makeSegment(
		TranslationHelper.TranslateByKey("获得"),
		TipsConfig.TEXT_SIZE_OBTAIN,
		TipsConfig.GRADIENT_TIP_WHITE
	)
end

--[[
	构建数量后缀文本段（x数量）
	@param count any - 展示数量，内部 tostring
	@return table - 单段 textData 配置
]]
local function _buildCountSegment(count: any)
	-- 数量前缀 "x" 为不随语言变化的符号，与本地化规范 SetRawText("x"..n) 约定一致
	return _makeSegment("x" .. tostring(count), TipsConfig.TEXT_SIZE_OBTAIN, TipsConfig.GRADIENT_YELLOW)
end

--[[
	载具合成获得提示数据
	@param data { [string]: any } - 须含 Lv（number）、ID（number 载具配置 ID）、Number（number）；Xyd 可选，缺省取配置 xyd
	@return {any}? - 三段 textData 数组；字段或配置缺失时 nil
]]
local function _buildVehicleFuseTip(data: { [string]: any }): { any }?
	local lv = data.Lv
	local itemId = tonumber(data.ID)
	local number = data.Number

	if lv == nil or not itemId or number == nil then
		return nil
	end

	local itemCfg = CfgFind.FindCfgByID(itemId)
	if not itemCfg or not itemCfg.ZhName then
		return nil
	end

	local xyd = data.Xyd or itemCfg.xyd or 1

	return {
		_buildObtainPrefixSegment(),
		_makeSegment(
			TranslationHelper.TranslateByKey("载具合成等级", { tostring(lv) })
				.. TranslationHelper.TranslateByKey(itemCfg.ZhName),
			TipsConfig.TEXT_SIZE_ITEM,
			xyd
		),
		_buildCountSegment(number),
	}
end

--[[
	获得奖励提示数据
	@param data { [string]: any } - 须含 ID（number 物品配置 ID）、Count（number 数量）
	@return {any}? - 三段 textData 数组；配置不存在时 nil
]]
local function _buildRewardTip(data: { [string]: any }): { any }?
	local itemId = tonumber(data.ID)
	local count = data.Count
	if not itemId or count == nil then
		return nil
	end

	local itemCfg = CfgFind.FindCfgByID(itemId)
	if not itemCfg then
		return nil
	end

	local xyd = itemCfg.xyd or 1

	return {
		_buildObtainPrefixSegment(),
		_makeSegment(
			" " .. TranslationHelper.TranslateByKey(itemCfg.ZhName) .. " ",
			TipsConfig.TEXT_SIZE_ITEM,
			xyd
		),
		_buildCountSegment(count),
	}
end

local _TEMPLATE_BUILDERS: { [string]: (data: { [string]: any }) -> { any }? } = {
	[TipsConfig.SERVER_TEMPLATE_VEHICLE_FUSE] = _buildVehicleFuseTip,
	[TipsConfig.SERVER_TEMPLATE_REWARD] = _buildRewardTip,
}

-- ========================================
-- Public API
-- ========================================

--[[
	根据服务端模板 Type 构建多段提示数据
	@param data { [string]: any } - 须含 Type（string），取值见 TipsConfig.SERVER_TEMPLATE_*
	@return {any}? - TipsRenderer.createTip 入参数组；Type 未知或字段无效时 nil
]]
function TipsTemplateBuilder.buildFromServerData(data: { [string]: any }): { any }?
	local typeName = data.Type
	if typeName == nil then
		Log.warn("[TipsTemplateBuilder] data.Type 缺失")
		return nil
	end

	local builder = _TEMPLATE_BUILDERS[typeName]
	if not builder then
		Log.warn("[TipsTemplateBuilder] 未知 Type", typeName)
		return nil
	end

	local tipData = builder(data)
	if not tipData then
		Log.warn("[TipsTemplateBuilder] 构建失败 Type=", typeName)
	end
	return tipData
end

return TipsTemplateBuilder
