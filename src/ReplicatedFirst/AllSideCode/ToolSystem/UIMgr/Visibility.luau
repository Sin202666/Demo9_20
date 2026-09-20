--[[
	Module: UIMgr/Visibility
	Description: UIMgr 子模块 — 主界面显隐、ScreenGui 启停、模糊/景深、弹窗批量关闭（由 init 合并导出至 Utils.UIMgr）
	Author: 林奥宇
	Created: 2026-08-18
	Last Modified: 2026-09-01

	功能：
	- SetMainUIVisible：主界面 / SystemGui 显隐（可按弹窗标记自动判断）
	- HideGui / ShowGui：宠物相关 UI
	- HideScreenGui / ShowScreenGui：整屏启停
	- UpdateBlurVisible / CloseBlur / VisibleDepth：Lighting 模糊与景深
	- HideOtherUI / HideAllBut / RecoverHideUI：弹窗批量关闭与恢复

	与 init：业务只调 Utils.UIMgr，不要直接 require 本文件。

	加载方式：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local UIMgr = Utils.UIMgr

	示例：
		UIMgr.SetMainUIVisible()
		UIMgr.UpdateBlurVisible()
		UIMgr.HideAllBut("ScreenGui")
		UIMgr.RecoverHideUI()
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Players = Utils.Players
local Lighting = Utils.Lighting
local Log = Utils.Log

local Visibility = {}

local PET_UI_LIST = {
	"抽宠物弹窗",
}

local IGNORE_UI_NAMES = {
	["Mian"] = true,
	["Main"] = true,
	["详情"] = true,
	["UIAnima"] = true,
}

local BLUR_EFFECT_NAME = "UI模糊"
local DEPTH_EFFECT_NAME = "景深"
local SCREEN_GUI_NAME = "ScreenGui"
local SYSTEM_GUI_NAME = "SystemGui"
local REFRESH_UI_MODULE_NAME = "刷新UI"
local HIDE_ALL_BUT_ATTR = "UIMgrPrevEnabled"

local UI_ELEMENT_NAMES = {
	BACKGROUND_BLUR = "背景模糊",
	HIDE_MAIN_UI = "隐藏主界面",
	MAIN = "Main",
}

--[[
	安全 require UI 模块并调用 closeUi（动态挂载的「刷新UI」ModuleScript，无法静态顶 require）
	@param refreshUI ModuleScript - Frame 下的刷新UI 脚本
	@return () - 无返回值
]]
local function _requireCloseUi(refreshUI: ModuleScript)
	local success, uiModel = pcall(require, refreshUI)
	if not success then
		Log.warn("[UIMgr] closeUi require 失败", refreshUI:GetFullName(), uiModel)
		return
	end
	if uiModel and type(uiModel.closeUi) == "function" then
		uiModel:closeUi()
	end
end

--[[
	获取本地玩家的 PlayerGui
	@return PlayerGui? - 本地玩家 GUI 容器，玩家未就绪时 nil
]]
local function _getLocalPlayerGui(): PlayerGui?
	local localPlayer = Players.LocalPlayer
	if not localPlayer then
		return nil
	end
	local playerGui = localPlayer:FindFirstChild("PlayerGui")
	if playerGui and playerGui:IsA("PlayerGui") then
		return playerGui
	end
	return nil
end

--[[
	获取 ScreenGui 实例
	@return ScreenGui? - 主 ScreenGui，不存在时返回 nil
]]
local function _getScreenGui(): ScreenGui?
	local playerGui = _getLocalPlayerGui()
	if not playerGui then
		return nil
	end
	local screenGui = playerGui:FindFirstChild(SCREEN_GUI_NAME)
	if screenGui and screenGui:IsA("ScreenGui") then
		return screenGui
	end
	return nil
end

--[[
	设置宠物相关 UI 可见性
	@param visible boolean - 是否显示
	@return () - 无返回值
]]
local function _setPetUIVisible(visible: boolean): ()
	local screenGui = _getScreenGui()
	if not screenGui then
		return
	end
	for _, uiName in pairs(PET_UI_LIST) do
		local ui = screenGui:FindFirstChild(uiName)
		if ui and ui:IsA("Frame") then
			ui.Visible = visible
		end
	end
end

--[[
	设置主界面可见性
	@param setVisible boolean? - 是否显示（可选，nil 时自动判断）
	@return () - 无返回值
]]
function Visibility.SetMainUIVisible(setVisible: boolean?): ()
	local ScreenGui = _getScreenGui()
	if not ScreenGui then
		return
	end

	local isShow = true
	if setVisible ~= nil then
		isShow = setVisible
	else
		-- 自动判断：检查是否有需要隐藏主界面的窗口
		for _, child in pairs(ScreenGui:GetChildren()) do
			local v: Frame? = child:IsA("Frame") and child :: Frame? or nil
			if v and v.Visible == true then
				local backgroundBlur = v:FindFirstChild(UI_ELEMENT_NAMES.BACKGROUND_BLUR)
				local hideMainUI = v:FindFirstChild(UI_ELEMENT_NAMES.HIDE_MAIN_UI)

				if (backgroundBlur and backgroundBlur:IsA("BoolValue") and backgroundBlur.Value == true) or
				   (hideMainUI and hideMainUI:IsA("BoolValue") and hideMainUI.Value == true) then
					isShow = false
					break
				end
			end
		end
	end

	-- 设置主界面可见性
	local Main: Frame? = ScreenGui:FindFirstChild(UI_ELEMENT_NAMES.MAIN) :: Frame?
	if Main then
		Main.Visible = isShow
	end

	-- 设置系统 GUI 启用状态
	local playerGui = _getLocalPlayerGui()
	if playerGui then
		local SystemGui: ScreenGui? = playerGui:FindFirstChild(SYSTEM_GUI_NAME) :: ScreenGui?
		if SystemGui then
			SystemGui.Enabled = isShow
		end
	end
end

--[[
	隐藏宠物相关 UI
	@return () - 无返回值
]]
function Visibility.HideGui(): ()
	_setPetUIVisible(false)
end

--[[
	显示宠物相关 UI
	@return () - 无返回值
]]
function Visibility.ShowGui(): ()
	_setPetUIVisible(true)
end

--[[
	禁用整个 ScreenGui
	@return () - 无返回值
]]
function Visibility.HideScreenGui(): ()
	local screenGui = _getScreenGui()
	if screenGui then
		screenGui.Enabled = false
	end
end

--[[
	启用整个 ScreenGui
	@return () - 无返回值
]]
function Visibility.ShowScreenGui(): ()
	local screenGui = _getScreenGui()
	if screenGui then
		screenGui.Enabled = true
	end
end

--[[
	根据 ScreenGui 状态与子 UI「背景模糊」标记更新 Lighting 模糊效果
	@return () - 无返回值
]]
function Visibility.UpdateBlurVisible(): ()
	local uiBlurInstance = Lighting:FindFirstChild(BLUR_EFFECT_NAME)
	if not uiBlurInstance or not uiBlurInstance:IsA("BlurEffect") then
		uiBlurInstance = Instance.new("BlurEffect")
		uiBlurInstance.Name = BLUR_EFFECT_NAME
		uiBlurInstance.Parent = Lighting
	end
	local uiBlur = uiBlurInstance :: BlurEffect

	local screenGui = _getScreenGui()
	if not screenGui then
		return
	end

	if not screenGui.Enabled then
		uiBlur.Enabled = false
		return
	end

	for _, child in pairs(screenGui:GetChildren()) do
		if child:IsA("Frame") and child.Visible then
			local blurValue = child:FindFirstChild(UI_ELEMENT_NAMES.BACKGROUND_BLUR)
			if blurValue and blurValue:IsA("BoolValue") and blurValue.Value then
				uiBlur.Enabled = true
				return
			end
		end
	end

	uiBlur.Enabled = false
end

--[[
	强制关闭 Lighting UI 模糊效果（不扫描 ScreenGui；关闭弹窗后若需按 UI 状态恢复请调 UpdateBlurVisible）
	@return () - 无返回值
]]
function Visibility.CloseBlur(): ()
	local uiBlurInstance = Lighting:FindFirstChild(BLUR_EFFECT_NAME)
	if uiBlurInstance and uiBlurInstance:IsA("BlurEffect") then
		(uiBlurInstance :: BlurEffect).Enabled = false
	end
end

--[[
	设置景深效果可见性
	@param visible boolean - 是否启用景深
	@return () - 无返回值
]]
function Visibility.VisibleDepth(visible: boolean): ()
	local depthOfFieldInstance = Lighting:FindFirstChild(DEPTH_EFFECT_NAME)
	if not depthOfFieldInstance or not depthOfFieldInstance:IsA("DepthOfFieldEffect") then
		return
	end
	(depthOfFieldInstance :: DepthOfFieldEffect).Enabled = visible
end

--[[
	关闭除忽略列表外的其他可见弹窗（通过各 UI 的「刷新UI」模块 closeUi）
	@param player Player - 目标玩家
	@return () - 无返回值
]]
function Visibility.HideOtherUI(player: Player): ()
	local playerGui = player:FindFirstChild("PlayerGui")
	if not playerGui or not playerGui:IsA("PlayerGui") then
		return
	end

	local screenGui = playerGui:FindFirstChild(SCREEN_GUI_NAME)
	if not screenGui or not screenGui:IsA("ScreenGui") then
		return
	end

	for _, child in pairs(screenGui:GetChildren()) do
		if child:IsA("Frame") and child.Visible and not IGNORE_UI_NAMES[child.Name] then
			local refreshUI = child:FindFirstChild(REFRESH_UI_MODULE_NAME)
			if refreshUI and refreshUI:IsA("ModuleScript") then
				_requireCloseUi(refreshUI :: ModuleScript)
			end
		end
	end
end

--[[
	隐藏全部 ScreenGui 除了 _unHideUI
	@param _unHideUI string? - 保留显示的 ScreenGui 名称；nil 时隐藏全部
	@return () - 无返回值
]]
function Visibility.HideAllBut(_unHideUI: string?): ()
	local localPlayer = Players.LocalPlayer
	if not localPlayer then
		return
	end

	local playerGui = localPlayer:FindFirstChild("PlayerGui")
	if not playerGui or not playerGui:IsA("PlayerGui") then
		return
	end

	for _, v in playerGui:GetChildren() do
		if v:IsA("ScreenGui") and v.Name ~= _unHideUI and v.Enabled == true then
			v:SetAttribute(HIDE_ALL_BUT_ATTR, true)
			v.Enabled = false
		end
	end
end

--[[
	恢复 HideAllBut 之前隐藏的 ScreenGui
	@return () - 无返回值
]]
function Visibility.RecoverHideUI(): ()
	local localPlayer = Players.LocalPlayer
	if not localPlayer then
		return
	end

	local playerGui = localPlayer:FindFirstChild("PlayerGui")
	if not playerGui or not playerGui:IsA("PlayerGui") then
		return
	end

	for _, v in playerGui:GetChildren() do
		if v:IsA("ScreenGui") then
			local enabled: boolean? = v:GetAttribute(HIDE_ALL_BUT_ATTR)
			if enabled then
				v.Enabled = enabled
				v:SetAttribute(HIDE_ALL_BUT_ATTR, nil)
			end
		end
	end
end

return Visibility
