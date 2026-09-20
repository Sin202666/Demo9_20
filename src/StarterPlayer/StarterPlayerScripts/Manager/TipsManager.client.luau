--[[
	Module: TipsManager
	Description: 客户端提示事件路由（Remote / Bindable → TipsRenderer）
	Author: 林奥宇
	Created: 2026-01-19
	Last Modified: 2026-07-02

	功能：
	- 监听 SHOW_TIPS / SHOW_TIPS_2KEY / NEW_SHOW_TIPS* 事件
	- 翻译键提示、结构化提示、模板类型提示的路由与渲染
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local NetMsg = Utils.NetMsg
local NetWork = Utils.NetWork
local TipsRenderer = Utils.TipsRenderer
local TipsConfig = Utils.TipsConfig
local TranslationHelper = Utils.TranslationHelper
local EnumMgr = Utils.EnumMgr
local SoundModule = Utils.SoundModule

--[[
	按提示类型选择模板并渲染，错误类型附加消极音效
	@param text string - 已翻译的完整展示文案
	@param tipType number? - EnumMgr.TipTp；nil 时按 Normal 处理
	@return nil
]]
local function _renderTranslatedTip(text: string, tipType: number?)
	local resolvedType = tipType or EnumMgr.TipTp.Normal

	if resolvedType == EnumMgr.TipTp.Error then
		TipsRenderer.templateTip(text, TipsConfig.TEMPLATE_ERROR)
		SoundModule:PlaySoundLocal({ SoundName = TipsConfig.SOUND_ERROR, Is2D = true })
	else
		TipsRenderer.templateTip(text, TipsConfig.TEMPLATE_NORMAL)
	end
end

--[[
	SHOW_TIPS 回调：单翻译键提示
	@param key string - LanguageCfg 翻译键
	@param arg any? - 翻译占位符参数
	@param tipType number? - EnumMgr.TipTp；nil 时按 Normal 处理
	@return nil - key 为空时静默 return
]]
local function _onShowTips(key: string, arg: any?, tipType: number?)
	if key == nil or key == "" then
		return
	end

	local text = TranslationHelper.TranslateByKey(key, arg)
	_renderTranslatedTip(text, tipType)
end

--[[
	SHOW_TIPS_2KEY 回调：双翻译键拼接提示
	@param key1 string - 第一段 LanguageCfg 翻译键
	@param key2 string - 第二段 LanguageCfg 翻译键
	@param arg any? - 两段共用的翻译占位符参数
	@param tipType number? - EnumMgr.TipTp；nil 时按 Normal 处理
	@return nil - key1 为空时静默 return
]]
local function _onShowTips2Key(key1: string, key2: string, arg: any?, tipType: number?)
	if key1 == nil or key1 == "" then
		return
	end

	local text1 = TranslationHelper.TranslateByKey(key1, arg)
	local text2 = key2 and TranslationHelper.TranslateByKey(key2, arg) or ""
	_renderTranslatedTip(text1 .. text2, tipType)
end

--[[
	注册同一 msgName 的 Bindable 与 ClientRemote 处理器
	@param msgName string - NetMsg 常量，如 SHOW_TIPS
	@param handler (...any) -> () - 事件回调，参数与 FireClient/FireBindable 一致
	@return nil
]]
local function _registerTipsHandler(msgName: string, handler: (...any) -> ())
	NetWork.RegisterBindableEvent(msgName, handler)
	NetWork.RegisterClientRemoteEvent(msgName, handler)
end

--[[
	NEW_SHOW_TIPS 回调：直接渲染多段结构化数据
	@param tipData {any} - TipsRenderer.createTip 入参
	@return nil
]]
local function _onNewShowTips(tipData: { any })
	TipsRenderer.createTip(tipData)
end

--[[
	NEW_SHOW_TIPS_WITH_TYPE 回调：按模板名单句渲染
	@param text string - 展示文案
	@param templateName string - TipsConfig 模板名
	@return nil
]]
local function _onNewShowTipsWithType(text: string, templateName: string)
	TipsRenderer.templateTip(text, templateName)
end

--[[
	NEW_SHOW_TIPS_WITH_TEMP 回调：按服务端模板 Type 构建并渲染
	@param data { [string]: any } - 须含 Type 及对应模板字段
	@return nil
]]
local function _onNewShowTipsWithTemplate(data: { [string]: any })
	TipsRenderer.showFromServerTemplate(data)
end

_registerTipsHandler(NetMsg.SHOW_TIPS, _onShowTips)
_registerTipsHandler(NetMsg.SHOW_TIPS_2KEY, _onShowTips2Key)
_registerTipsHandler(NetMsg.NEW_SHOW_TIPS, _onNewShowTips)
_registerTipsHandler(NetMsg.NEW_SHOW_TIPS_WITH_TYPE, _onNewShowTipsWithType)
_registerTipsHandler(NetMsg.NEW_SHOW_TIPS_WITH_TEMP, _onNewShowTipsWithTemplate)
