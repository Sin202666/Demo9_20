--!strict
--[[
	Module: LanguageCfg
	Description: 多语言翻译配置查表、占位符替换与语言回退
	Author: 林奥宇
	Created: 2026-07-02
	Last Modified: 2026-09-01

	功能：
	- 将 Language.luau 打表结果建为 Key → localeId → 文案 的查表
	- FormatByKey：当前语言 → zh-tw 回退 zh-cn → 再回退 en-us
	- 替换 {1} / {name} 占位；值为 { "另一条Key" } 时再查表

	与相关模块：
	- 仅供同目录 TranslationHelper 内部 require，不要从业务侧直接引用
	- Language.luau 是 Excel 打表产物，禁止手改；本模块在构建索引后丢掉源表引用以便 GC
	- 业务入口一律 Utils.TranslationHelper；切语言由 TranslationManager 调 SetLocaleId

	加载方式（仅内部）：
		local LanguageCfg = require(script.LanguageCfg)

	示例：
		LanguageCfg.SetLocaleId("zh-cn")
		local text, autoLocalize = LanguageCfg.FormatByKey("确认")
		local withArg = LanguageCfg.FormatByKey("库存为", { "3" })
]]

-- ========================================
-- 模块引用
-- ========================================
local ConfigInstance = require(script.Parent.Language)

-- ========================================
-- 模块定义
-- ========================================
local LanguageCfg = {}

-- ========================================
-- 常量定义
-- ========================================
local DEFAULT_LOCALE_ID = "en-us"

local LOCALE_FALLBACK = {
	["zh-tw"] = "zh-cn",
}

local UNLOCALIZED_PREFIX = "未本地化-"

-- ========================================
-- 私有变量
-- ========================================
local _localeId = DEFAULT_LOCALE_ID
local _cfg: { [string]: { [string]: string } } = {}
local _keyMap = ConfigInstance.key

-- ========================================
-- 私有函数
-- ========================================

--[[
	构建翻译键到各语言文案的查表

	Language 表除 key 外每个分组的数组下标对应 key[分组名] 里的 localeId 顺序。

	@return {[string]: {[string]: string}} - 键为翻译键，值为 localeId → 文案
]]
local function _buildCfg(): { [string]: { [string]: string } }
	local cfg: { [string]: { [string]: string } } = {}

	for configKey, configGroup in pairs(ConfigInstance) do
		if configKey == "key" then
			continue
		end

		local localeOrder = _keyMap[configKey]
		if typeof(localeOrder) ~= "table" then
			continue
		end

		for translateKey, localeTexts in pairs(configGroup) do
			local localeCfg = {}
			for localeIndex, text in pairs(localeTexts) do
				localeCfg[tostring(localeOrder[localeIndex])] = text
			end
			cfg[translateKey] = localeCfg
		end
	end

	return cfg
end

--[[
	把 gsub 替换串里的 % 写成 %%，避免被当成捕获引用

	@param value string - 占位符替换后的原文
	@return string - 可安全作为 string.gsub 替换串的文本
]]
local function _escapeGsubReplacement(value: string): string
	return (string.gsub(value, "%%", "%%%%"))
end

--[[
	替换模板字符串中的 {key} 占位符

	替换值里的 % 会转义；嵌套表取 [1] 作为 LanguageCfg 键再查表。

	@param template string - 含占位符的模板文案
	@param args table - 占位符参数表，值为 string / number 或 {嵌套翻译键}
	@return string - 替换后的文案
]]
local function _replacePlaceholders(template: string, args: { [any]: any }): string
	local resultStr = template
	for placeholderKey, placeholderValue in pairs(args) do
		local token = "{" .. tostring(placeholderKey) .. "}"
		local replacement: string
		if typeof(placeholderValue) == "table" then
			replacement = LanguageCfg.FormatByKey(placeholderValue[1])
		else
			replacement = tostring(placeholderValue)
		end
		resultStr = string.gsub(resultStr, token, _escapeGsubReplacement(replacement))
	end
	return resultStr
end

--[[
	有占位参数则替换，否则原样返回

	@param text string - 已选定语言的模板文案
	@param args table? - 占位符参数表；nil 时不替换
	@return string - 最终展示文案
]]
local function _applyArgs(text: string, args: { [any]: any }?): string
	if args then
		return _replacePlaceholders(text, args)
	end
	return text
end

-- ========================================
-- 公共函数
-- ========================================

--[[
	获取当前语言 localeId

	@return string - Roblox LocaleId，默认 en-us
]]
function LanguageCfg.GetLocaleId(): string
	return _localeId
end

--[[
	设置当前语言 localeId（由 TranslationManager 在客户端切换语言时调用）

	@param localeId string - Roblox LocaleId，如 zh-cn、en-us；非字符串或空串忽略
]]
function LanguageCfg.SetLocaleId(localeId: string)
	if typeof(localeId) ~= "string" or localeId == "" then
		return
	end
	_localeId = localeId
end

--[[
	翻译键是否已在打表结果中

	@param translateKey string - Language 表键名，非展示文案
	@return boolean - 查表命中为 true；空串或未配置为 false
]]
function LanguageCfg.HasKey(translateKey: string): boolean
	return typeof(translateKey) == "string" and translateKey ~= "" and _cfg[translateKey] ~= nil
end

--[[
	根据翻译键格式化文案

	回退：当前 locale → LOCALE_FALLBACK（zh-tw→zh-cn）→ en-us。
	回退到默认语言时第二返回值为 true，供调用方打开 AutoLocalize。

	@param translateKey string - Language 表中的翻译键，非展示文案
	@param args table? - 占位符参数表，键为占位符名或数字下标，值为 string 或 {嵌套翻译键}；nil 不替换
	@return string - 翻译后的文案；键不存在或默认语言也缺失时返回「未本地化-{键}」
	@return boolean - 是否应开启实例 AutoLocalize（回退到默认语言或缺键时为 true）
]]
function LanguageCfg.FormatByKey(translateKey: string, args: { [any]: any }?): (string, boolean)
	if typeof(translateKey) ~= "string" or translateKey == "" then
		return UNLOCALIZED_PREFIX .. tostring(translateKey or ""), true
	end

	local data = _cfg[translateKey]
	if not data then
		return UNLOCALIZED_PREFIX .. translateKey, true
	end

	local currentText = data[_localeId]
	if currentText ~= nil then
		return _applyArgs(currentText, args), false
	end

	local fallbackLocale = LOCALE_FALLBACK[_localeId]
	if fallbackLocale then
		local fallbackText = data[fallbackLocale]
		if fallbackText ~= nil then
			return _applyArgs(fallbackText, args), false
		end
	end

	local defaultText = data[DEFAULT_LOCALE_ID]
	if defaultText == nil then
		return UNLOCALIZED_PREFIX .. translateKey, true
	end
	return _applyArgs(defaultText, args), true
end

-- ========================================
-- 初始化
-- ========================================
_cfg = _buildCfg()

for _, localeCfg in _cfg do
	table.freeze(localeCfg)
end
table.freeze(_cfg)

-- 索引已建成，丢掉打表源表引用，避免整表常驻两份
ConfigInstance.key = nil
ConfigInstance.localizationtableConf = nil

return LanguageCfg
