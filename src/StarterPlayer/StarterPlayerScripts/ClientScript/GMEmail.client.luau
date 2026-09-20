--[[
	Module: GMEmail
	Description: GM 发邮件门禁与命令（/gmemail）；面板 UI 在 GuiScripts.GMEmail
	Author: 林奥宇
	Created: 2026-08-11
	Last Modified: 2026-08-31

	功能：
	- 非白名单玩家进服零开销（不 require UtilsSystem / 面板模块）
	- 白名单玩家仅注册 /gmemail；首次打开面板时才 require GMEmail 并构建 UI
	- Studio 默认仍须白名单（见 GmEmailWhitelist.GM_EMAIL_ALLOW_IN_STUDIO）

	依赖：
	- ReplicatedFirst.AllSideCode.GmEmailWhitelist（门禁前直 require，避免非白名单加载 UtilsSystem）
	- ReplicatedStorage.ClientSideCode.GuiScripts.ModuleScript.GMEmail（仅首次打开时 require）

	约定：
	- 本文件为 StarterPlayerScripts LocalScript；无 Init() / 模块表
	- 发信权威在服务端 SystemEmail；本脚本只开面板
	- _buildGmMailPanel 内 require 为故意懒加载，勿提前到文件顶

	加载方式：
		本脚本由 StarterPlayer 自动运行，无需 require
]]

local Players = game:GetService("Players")

local GmEmailWhitelist = require(game.ReplicatedFirst.AllSideCode.GmEmailWhitelist)

local LocalPlayer = Players.LocalPlayer

local COMMAND_DEBOUNCE_SEC = 0.25

if not GmEmailWhitelist.IsAllowed(LocalPlayer.UserId) then
	return
end

-- 白名单之后才加载 Utils：非白名单进服仍零开销
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Log = Utils.Log
local TextChatService = Utils.TextChatService

local GM_EMAIL_GUI_ROOT = game.ReplicatedStorage.ClientSideCode.GuiScripts.ModuleScript

type GmMailPanelHandle = {
	Show: () -> (),
	Hide: () -> (),
}

local _gmMailPanel: GmMailPanelHandle? = nil
local _isPanelCreating = false
local _lastGmEmailCommandAt = 0

--[[
	首次打开时懒加载面板模块并构建 UI

	@return GmMailPanelHandle? - 成功为面板句柄；资源缺失或失败为 nil
]]
local function _buildGmMailPanel(): GmMailPanelHandle?
	-- 故意函数内 require：非首次打开不加载 GuiScripts.GMEmail
	local GMEmail = require(GM_EMAIL_GUI_ROOT.GMEmail)
	return GMEmail.create()
end

--[[
	确保 GM 邮件面板已创建（仅首次打开时 build）

	@return GmMailPanelHandle? - 面板句柄；创建中或失败为 nil
]]
local function _ensureGmMailPanel(): GmMailPanelHandle?
	if _gmMailPanel then
		return _gmMailPanel
	end
	if _isPanelCreating then
		return nil
	end
	_isPanelCreating = true
	local buildOk, panelOrErr = pcall(_buildGmMailPanel)
	_isPanelCreating = false
	if not buildOk then
		Log.warn("[GMEmail] 面板初始化失败", panelOrErr)
		return nil
	end
	if panelOrErr == nil then
		return nil
	end
	_gmMailPanel = panelOrErr
	return _gmMailPanel
end

--[[
	打开 GM 发邮件面板

	@return nil - 无权限、创建中或构建失败时静默 return
]]
local function _openGmEmailPanel()
	if not GmEmailWhitelist.IsAllowed(LocalPlayer.UserId) then
		return
	end
	local panel = _ensureGmMailPanel()
	if panel then
		panel.Show()
	end
end

--[[
	处理聊天栏 /gmemail（兼容旧 Chatted 通道）

	@param messageText string - 聊天原文
	@return boolean - 已识别为 GM 命令时 true（无论是否有权限）
]]
local function _tryHandleGmEmailCommand(messageText: string): boolean
	if typeof(messageText) ~= "string" then
		return false
	end
	local normalizedText = string.lower((string.gsub(messageText, "%s+", "")))
	if normalizedText ~= "/gmemail" then
		return false
	end
	if not GmEmailWhitelist.IsAllowed(LocalPlayer.UserId) then
		return true
	end
	local now = os.clock()
	if now - _lastGmEmailCommandAt < COMMAND_DEBOUNCE_SEC then
		return true
	end
	_lastGmEmailCommandAt = now
	_openGmEmailPanel()
	return true
end

local commandOk, commandErr = pcall(function()
	local gmEmailCommand = Instance.new("TextChatCommand")
	gmEmailCommand.Name = "GMEmailCommand"
	gmEmailCommand.PrimaryAlias = "/GMEmail"
	gmEmailCommand.SecondaryAlias = "/gmemail"
	gmEmailCommand.Parent = TextChatService
	gmEmailCommand.Triggered:Connect(function()
		_openGmEmailPanel()
	end)
end)
if not commandOk then
	Log.warn("[GMEmail] 注册 TextChatCommand 失败", commandErr)
end

LocalPlayer.Chatted:Connect(function(messageText)
	_tryHandleGmEmailCommand(messageText)
end)
