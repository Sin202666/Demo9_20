--!strict
--[[
	Module: TranslationHelper
	Description: 文本本地化查表与 UI 实例绑定
	Author: 林奥宇
	Created: 2026-07-02
	Last Modified: 2026-09-01

	功能：
	- TranslateByKey / CheckTranslateByKey：只要字符串，不绑 UI
	- SetText：给 TextLabel / TextBox（PlaceholderText）/ ProximityPrompt（ActionText）绑键，切语言可刷新
	- SetRawText / SetText_UnTrans：纯数字、玩家名、已拼好展示串；会去掉「代码本地化」标签
	- SetLabel：用实例 Name 当 Key，等价 SetText(ins, ins.Name)

	与相关模块：
	- 文案源是 config/Localization/LocalizationTable.xlsx，打表生成 Language.luau（禁止手改）
	- LanguageCfg 负责查表与占位替换，本模块是业务唯一入口
	- TranslationManager 监听 LocaleId，刷新带「代码本地化」的控件；静态 UI 用标签「本地化」+ Name=Key
	- Key 只能是调用处字面量或配置表 Zh* 字段，完整约定见 docs/文本本地化开发规范.md

	加载方式：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local TranslationHelper = Utils.TranslationHelper

	示例：
		TranslationHelper.SetText(title, "确认")
		TranslationHelper.SetText(stockLabel, "库存为", { MathMgr.getNumStr(remain) })
		TranslationHelper.SetRawText(countLabel, "x" .. tostring(n))
		local tip = TranslationHelper.TranslateByKey("请求过于频繁，请稍后再试")
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Log = Utils.Log
local LanguageCfg = require(script.LanguageCfg)

-- ========================================
-- 模块定义
-- ========================================
local TranslationHelper = {}

-- ========================================
-- 常量定义
-- ========================================
local LOCALIZATION_TAG = "代码本地化"
local ATTR_KEY = "_key"
local ATTR_MAX_INDEX = "_maxIndex"
local ATTR_ARG_PREFIX = "_arg"
local ATTR_ARG_TABLE_PREFIX = "_arg_table"
local INSTANCE_PATH_DEPTH = 3

-- ========================================
-- 私有函数
-- ========================================

--[[
	检查实例是否支持文本设置

	@param instance Instance - 待检查实例
	@return boolean - 是否为 TextLabel、TextBox 或 ProximityPrompt
]]
local function _isTextInstance(instance: Instance): boolean
	return instance:IsA("TextLabel") or instance:IsA("TextBox") or instance:IsA("ProximityPrompt")
end

--[[
	按实例类型写入最终展示文本（本地化路径：TextBox 写 PlaceholderText）

	@param instance Instance - TextLabel、TextBox 或 ProximityPrompt
	@param text string - 主文案
	@param addText string? - 追加在末尾的附加文案；nil 不追加。可变数字应走 {1} 而不是本参数
]]
local function _setTextContent(instance: Instance, text: string, addText: string?)
	local finalText = addText and (text .. addText) or text

	if instance:IsA("ProximityPrompt") then
		instance.ActionText = finalText
	elseif instance:IsA("TextBox") then
		instance.PlaceholderText = finalText
	elseif instance:IsA("TextLabel") then
		instance.Text = finalText
	end
end

--[[
	按实例类型写入原始展示文本（TextBox 写 Text，与输入框/已拼好串一致）

	@param instance Instance - TextLabel、TextBox 或 ProximityPrompt
	@param text string - 直接展示的文案
]]
local function _setRawTextContent(instance: Instance, text: string)
	if instance:IsA("ProximityPrompt") then
		instance.AutoLocalize = false
		instance.ActionText = text
	elseif instance:IsA("TextBox") then
		instance.AutoLocalize = false
		instance.Text = text
	elseif instance:IsA("TextLabel") then
		instance.AutoLocalize = false
		instance.Text = text
	end
end

--[[
	按实例类型清空展示文本

	@param instance Instance - TextLabel、TextBox 或 ProximityPrompt
]]
local function _clearTextContent(instance: Instance)
	if instance:IsA("ProximityPrompt") then
		instance.ActionText = ""
	elseif instance:IsA("TextBox") then
		instance.PlaceholderText = ""
	elseif instance:IsA("TextLabel") then
		instance.Text = ""
	end
end

--[[
	清除实例上由 SetText 写入的本地化 Attribute，避免误删业务 Attribute

	@param instance Instance - 已绑定本地化的 UI 实例
]]
local function _clearLocalizationAttributes(instance: Instance)
	instance:SetAttribute(ATTR_KEY, nil)
	instance:SetAttribute(ATTR_MAX_INDEX, nil)

	for attributeName in pairs(instance:GetAttributes()) do
		if string.sub(attributeName, 1, #ATTR_ARG_PREFIX) == ATTR_ARG_PREFIX then
			instance:SetAttribute(attributeName, nil)
		end
	end
end

--[[
	解除代码本地化绑定，避免 TranslationManager 在切语言时覆盖原文

	@param instance Instance - 目标文本实例
]]
local function _unbindFromCodeLocalization(instance: Instance)
	_clearLocalizationAttributes(instance)
	if instance:HasTag(LOCALIZATION_TAG) then
		instance:RemoveTag(LOCALIZATION_TAG)
	end
end

--[[
	拼出实例短路径，供缺键告警定位

	@param instance Instance - 目标实例
	@return string - Name 与最多 3 级祖先 Name，用 / 连接
]]
local function _instancePathHint(instance: Instance): string
	local names = { instance.Name }
	local current = instance.Parent
	local depth = 0
	while current and depth < INSTANCE_PATH_DEPTH do
		table.insert(names, current.Name)
		current = current.Parent
		depth += 1
	end
	return table.concat(names, "/")
end

--[[
	计算参数表的最大数字索引，供 TranslationManager 按序还原

	@param args table - 占位符参数表，通常为数组形态 { value1, value2 }
	@return number - 最大数字索引；无数字键时返回 0
]]
local function _getArgsMaxIndex(args: { [any]: any }): number
	local maxIndex = 0
	for argKey in pairs(args) do
		if typeof(argKey) == "number" and argKey > maxIndex then
			maxIndex = argKey
		end
	end
	return maxIndex
end

-- ========================================
-- 公共函数
-- ========================================

--[[
	获取当前语言 localeId

	@return string - Roblox LocaleId
]]
function TranslationHelper.GetLocaleId(): string
	return LanguageCfg.GetLocaleId()
end

--[[
	设置当前语言 localeId

	@param localeId string - Roblox LocaleId，如 zh-cn、en-us
]]
function TranslationHelper.SetLocaleId(localeId: string)
	LanguageCfg.SetLocaleId(localeId)
end

--[[
	通过翻译键查表

	@param key string? - Language 表中的翻译键，非展示文案；nil 或空串返回 ""
	@param arguments table? - 占位符参数表，键为占位符名或数字下标，值为 string 或 {嵌套翻译键}；nil 不替换
	@return string - 翻译后的文案；缺键时为「未本地化-{键}」
]]
function TranslationHelper.TranslateByKey(key: string?, arguments: { [any]: any }?): string
	if not key or key == "" then
		return ""
	end

	return LanguageCfg.FormatByKey(key, arguments)
end

--[[
	设置文本并写入本地化 Attribute，供语言切换时重新翻译

	会打上「代码本地化」标签。第四参 addText 切语言时不会被 TranslationManager 带上，可变数字请用 {1}。

	@param ins Instance - TextLabel、TextBox 或 ProximityPrompt
	@param key string? - Language 表翻译键，非展示文案；nil 或空串时清空文本、解除绑定并告警
	@param args table? - 占位符参数表，须用数字下标才能在切语言后还原；nil 表示无占位
	@param addText string? - 追加在翻译结果末尾的文案；nil 不追加
]]
function TranslationHelper.SetText(ins: Instance, key: string?, args: { [any]: any }?, addText: string?)
	if not ins then
		return
	end

	if not _isTextInstance(ins) then
		return
	end

	if not key or key == "" then
		_unbindFromCodeLocalization(ins)
		_clearTextContent(ins)
		Log.warn("本地化错误 - 键值为空", _instancePathHint(ins))
		return
	end

	if not ins:HasTag(LOCALIZATION_TAG) then
		ins:AddTag(LOCALIZATION_TAG)
	end

	_clearLocalizationAttributes(ins)

	ins:SetAttribute(ATTR_KEY, key)

	if args then
		ins:SetAttribute(ATTR_MAX_INDEX, _getArgsMaxIndex(args))
		for argKey, argValue in pairs(args) do
			if typeof(argValue) == "table" then
				ins:SetAttribute(ATTR_ARG_TABLE_PREFIX .. argKey, argValue[1])
			else
				ins:SetAttribute(ATTR_ARG_PREFIX .. argKey, argValue)
			end
		end
	end

	local translatedText, isAutoLocal = LanguageCfg.FormatByKey(key, args)

	ins.AutoLocalize = isAutoLocal

	if translatedText then
		_setTextContent(ins, translatedText, addText)
	end
end

--[[
	设置原始文本，不参与本地化查表

	会清掉 _key / _arg* 并移除「代码本地化」，切语言时不再刷新。
	TextBox 写 Text（输入内容），不是 PlaceholderText。

	@param ins Instance - TextLabel、TextBox 或 ProximityPrompt
	@param text string - 直接展示的文案
]]
function TranslationHelper.SetRawText(ins: Instance, text: string)
	if not ins then
		return
	end

	if not _isTextInstance(ins) then
		return
	end

	_unbindFromCodeLocalization(ins)
	_setRawTextContent(ins, text)
end

--[[
	设置未翻译原文（SetRawText 兼容别名）

	@param ins Instance - TextLabel、TextBox 或 ProximityPrompt
	@param text string - 直接展示的文案，不参与查表与语言切换刷新
	@param _legacyUnused boolean? - 旧版第三参，保留兼容、当前忽略
]]
function TranslationHelper.SetText_UnTrans(ins: Instance, text: string, _legacyUnused: boolean?)
	TranslationHelper.SetRawText(ins, text)
end

--[[
	检查翻译键是否已在 Language 表中配置

	@param key string? - Language 表翻译键，非展示文案；nil 或空串视为未配置
	@param _arguments table? - 旧版占位参数，保留兼容、查存在性时忽略
	@return boolean - 已配置为 true；未配置、nil 或空串为 false
]]
function TranslationHelper.CheckTranslateByKey(key: string?, _arguments: { [any]: any }?): boolean
	if not key or key == "" then
		return false
	end

	return LanguageCfg.HasKey(key)
end

--[[
	以实例 Name 作为翻译键设置文本

	@param ins Instance - TextLabel、TextBox 或 ProximityPrompt
]]
function TranslationHelper.SetLabel(ins: Instance)
	if not ins then
		return
	end

	if _isTextInstance(ins) then
		TranslationHelper.SetText(ins, ins.Name)
	end
end

return TranslationHelper
