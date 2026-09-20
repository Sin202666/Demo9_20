--[[
	Module: TranslationHelper-Type
	Description: TranslationHelper 类型声明（完整使用说明见 ToolBasic/TranslationHelper/init.luau 文件头）
	Author: 林奥宇
	Created: 2026-07-02
	Last Modified: 2026-09-01
]]

local TranslationHelper = {}

--[[
	获取当前语言 localeId

	@return string - Roblox LocaleId
]]
function TranslationHelper.GetLocaleId(): string
end

--[[
	设置当前语言 localeId

	@param localeId string - Roblox LocaleId，如 zh-cn、en-us
]]
function TranslationHelper.SetLocaleId(localeId: string)
end

--[[
	通过翻译键查表

	@param key string? - Language 表中的翻译键，非展示文案；nil 或空串返回 ""
	@param arguments table? - 占位符参数表，键为占位符名或数字下标，值为 string 或 {嵌套翻译键}；nil 不替换
	@return string - 翻译后的文案；缺键时为「未本地化-{键}」
]]
function TranslationHelper.TranslateByKey(key: string?, arguments: { [any]: any }?): string
end

--[[
	设置文本并写入本地化 Attribute，供语言切换时重新翻译

	@param ins Instance - TextLabel、TextBox 或 ProximityPrompt
	@param key string? - Language 表翻译键，非展示文案；nil 或空串时清空文本、解除绑定并告警
	@param args table? - 占位符参数表，须用数字下标才能在切语言后还原；nil 表示无占位
	@param addText string? - 追加在翻译结果末尾的文案；nil 不追加。可变数字应走 {1}
]]
function TranslationHelper.SetText(ins: Instance, key: string?, args: { [any]: any }?, addText: string?)
end

--[[
	设置原始文本，不参与本地化查表；会去掉「代码本地化」标签

	@param ins Instance - TextLabel、TextBox 或 ProximityPrompt
	@param text string - 直接展示的文案
]]
function TranslationHelper.SetRawText(ins: Instance, text: string)
end

--[[
	设置未翻译原文（SetRawText 兼容别名）

	@param ins Instance - TextLabel、TextBox 或 ProximityPrompt
	@param text string - 直接展示的文案，不参与查表与语言切换刷新
	@param _legacyUnused boolean? - 旧版第三参，保留兼容、当前忽略
]]
function TranslationHelper.SetText_UnTrans(ins: Instance, text: string, _legacyUnused: boolean?)
end

--[[
	检查翻译键是否已在 Language 表中配置

	@param key string? - Language 表翻译键，非展示文案；nil 或空串视为未配置
	@param _arguments table? - 旧版占位参数，保留兼容、查存在性时忽略
	@return boolean - 已配置为 true；未配置、nil 或空串为 false
]]
function TranslationHelper.CheckTranslateByKey(key: string?, _arguments: { [any]: any }?): boolean
end

--[[
	以实例 Name 作为翻译键设置文本

	@param ins Instance - TextLabel、TextBox 或 ProximityPrompt
]]
function TranslationHelper.SetLabel(ins: Instance)
end

return TranslationHelper
