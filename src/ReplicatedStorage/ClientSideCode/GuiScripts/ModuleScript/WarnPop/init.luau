--[[
	Module: WarnPop
	Description: 通用确认弹窗——标题/正文由调用方 TranslateByKey 后传入，Exit·Back 取消，Ok 确认
	Author: 林奥宇
	Created: 2026-09-04
	Last Modified: 2026-09-04

	功能：
	- updateUi：写入 titleText / tipsText；记录 func、returnUi、confirmFlag
	- Exit / BackBtn：只关本窗，不调 func、不 Refresh 上层
	- Ok：先 SHOW_LOCAL_UI false 关窗，再 func，再 defer REFRESH_LOCAL_UI
	- 叠在其它弹窗上时 closeUi 用 SetMainUIVisible(nil)，避免把下层主界面冲掉

	模块关系：
	- 由 UIManager 按 Frame.Name「WarnPop」动态 require；关窗走 SHOW_LOCAL_UI false（PopBack 由 UIManager 负责）
	- 现网调用方：SystemBuyRoblox 赠送确认（titleText/tipsText + func，只拉起 Prompt）
	- returnUi + confirmFlag 预留给上层 GuiScripts（确认后 RefreshLocalUI）

	约定：
	- ScreenGui.WarnPop；节点见 AllUI（Top._Title / Main._Text / Top._Exit / _Bottom._BackBtn / _OkBtn）
	- titleText / tipsText 必须是调用方 TranslateByKey 的展示串（字面量 Key 写在调用处），本模块 SetRawText
	- 缺省标题/正文：本模块内字面量 SetText「警告」
	- Ok / Back 按钮文案走 UI 静态「本地化」标签；func 禁止改存档/发奖

	打开：
		NetWork.FireBindable(NetMsg.SHOW_LOCAL_UI, "WarnPop", {
			titleText = TranslationHelper.TranslateByKey("确认"),
			tipsText = TranslationHelper.TranslateByKey("赠送确认", { { cfg.ZhName }, target.DisplayName }),
			func = function() end,
		}, true)
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local AddListen = Utils.AddListen
local Log = Utils.Log
local NetMsg = Utils.NetMsg
local NetWork = Utils.NetWork
local TranslationHelper = Utils.TranslationHelper
local UIMgr = Utils.UIMgr

local AllUI = require(script.AllUI)

-- ========================================
-- 模块定义
-- ========================================
local WarnPop = {}

-- ========================================
-- 常量定义
-- ========================================
local UI_NAME = "WarnPop"

-- ========================================
-- 私有变量
-- ========================================
local UI: Frame = AllUI.UIRoot
local _listenersBound = false
local _returnUi: string? = nil
local _confirmFlag: string? = nil
local _confirmFunc: (() -> ())? = nil

-- ========================================
-- 私有函数
-- ========================================

--[[
	从按钮外层 Frame 取可点击子节点：优先 Btn / Button，否则首个 GuiButton
	@param btnFrame Instance? - AllUI.Exit / BackBtn / OkBtn 等容器
	@return GuiButton? - 找不到时 nil
]]
local function _findButton(btnFrame: Instance?): GuiButton?
	if not btnFrame then
		return nil
	end
	local named = btnFrame:FindFirstChild("Btn") or btnFrame:FindFirstChild("Button")
	if named and named:IsA("GuiButton") then
		return named
	end
	local anyButton = btnFrame:FindFirstChildWhichIsA("GuiButton")
	if anyButton and anyButton:IsA("GuiButton") then
		return anyButton
	end
	return nil
end

--[[
	经 UIManager 关闭本窗（PopBack 由 UIManager 播放）
	@return nil
]]
local function _requestClose(): nil
	NetWork.FireBindable(NetMsg.SHOW_LOCAL_UI, UI_NAME, nil, false, true)
	return nil
end

--[[
	取消：关窗，不调确认回调、不通知上层
	@return nil
]]
local function _onCancel(): nil
	_requestClose()
	return nil
end

--[[
	确认：先关窗，再 func，再 defer Refresh 上层
	@return nil
]]
local function _onConfirm(): nil
	local confirmFunc = _confirmFunc
	local returnUi = _returnUi
	local flag = _confirmFlag
	_confirmFunc = nil
	_returnUi = nil
	_confirmFlag = nil
	_requestClose()
	if type(confirmFunc) == "function" then
		confirmFunc()
	end
	if type(returnUi) == "string" and returnUi ~= "" and type(flag) == "string" and flag ~= "" then
		task.defer(function()
			NetWork.FireBindable(NetMsg.REFRESH_LOCAL_UI, returnUi, { [flag] = true })
		end)
	end
	return nil
end

--[[
	给容器绑定点击；找不到 GuiButton 时打日志
	@param frame Frame? - 按钮外层
	@param onClick () -> () - 点击回调
	@param warnName string - 缺失时日志用的节点名
	@return nil
]]
local function _bindClick(frame: Frame?, onClick: () -> (), warnName: string): nil
	local btn = _findButton(frame)
	if not btn then
		Log.warn("WarnPop: 按钮缺失", warnName)
		return nil
	end
	local scaleTarget: GuiObject = if frame then frame else btn
	AddListen.AddMouseClick(btn, onClick, scaleTarget)
	return nil
end

--[[
	绑定 Exit / Back / Ok（只绑一次）
	@return nil
]]
local function _ensureListeners(): nil
	if _listenersBound then
		return nil
	end
	_listenersBound = true
	_bindClick(AllUI.Exit, _onCancel, "Exit")
	_bindClick(AllUI.BackBtn, _onCancel, "BackBtn")
	_bindClick(AllUI.OkBtn, _onConfirm, "OkBtn")
	return nil
end

--[[
	按 uiData 写标题与正文（动态句 SetRawText；缺省字面量「警告」）
	@param uiData any? - 见 updateUi
	@return nil
]]
local function _applyTexts(uiData: any?): nil
	local title = AllUI.Title
	local body = AllUI.Text
	local titleText = if type(uiData) == "table" then uiData.titleText else nil
	local tipsText = if type(uiData) == "table" then uiData.tipsText else nil
	if type(titleText) == "string" and titleText ~= "" then
		TranslationHelper.SetRawText(title, titleText)
	else
		TranslationHelper.SetText(title, "警告")
	end
	if type(tipsText) == "string" and tipsText ~= "" then
		TranslationHelper.SetRawText(body, tipsText)
	else
		TranslationHelper.SetText(body, "警告")
	end
	return nil
end

-- ========================================
-- 公共函数
-- ========================================

--[[
	刷新标题、正文与确认回调
	@param uiData any? - titleText/tipsText 为 TranslateByKey 展示串；func 为确认回调（只允许 Prompt/表现）；returnUi+confirmFlag 确认后 RefreshLocalUI
	@return nil
]]
function WarnPop:updateUi(uiData: any?)
	_returnUi = nil
	_confirmFlag = nil
	_confirmFunc = nil
	if type(uiData) == "table" then
		if type(uiData.func) == "function" then
			_confirmFunc = uiData.func
		end
		if type(uiData.returnUi) == "string" and uiData.returnUi ~= "" then
			_returnUi = uiData.returnUi
		end
		if type(uiData.confirmFlag) == "string" and uiData.confirmFlag ~= "" then
			_confirmFlag = uiData.confirmFlag
		end
	end
	_applyTexts(uiData)
end

--[[
	打开钩子：绑按钮、藏主界面、刷新模糊（显隐由 UIManager PopUp 驱动）
	@return nil
]]
function WarnPop:openUi()
	_ensureListeners()
	UIMgr.SetMainUIVisible(false)
	UIMgr.UpdateBlurVisible()
end

--[[
	关闭钩子：不强制拉回主界面，交给仍打开的下层弹窗
	@return nil
]]
function WarnPop:closeUi()
	UI.Visible = false
	UIMgr.SetMainUIVisible(nil)
	UIMgr.UpdateBlurVisible()
end

return WarnPop
