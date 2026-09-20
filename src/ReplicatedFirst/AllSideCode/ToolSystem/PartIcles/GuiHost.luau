--[[
	Module: GuiHost
	Description: 解析插件内部单例 ScreenGui 的正确父容器（ScreenHost / TexturePin）
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-09-01

	功能：
	- resolveContainer：插件 → CoreGui；客户端 LocalScript → LocalPlayer.PlayerGui；服务端 → nil

	模块关系：
	- ScreenHost / TexturePin 只通过本模块取宿主，避免各自判断 Plugin vs Client
	- 服务端无 GUI 渲染，调用方应对 nil 早退（no-op）

	能力探测：
	- IS_PLUGIN 与 Lifecycle 相同：pcall(Selection:Get)，需要 PluginOrOpenCloud

	加载方式：
		local GuiHost = require(script.Parent.GuiHost)

	使用示例：
		local host = GuiHost.resolveContainer()
		if host then gui.Parent = host end
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local CoreGui = Utils.CoreGui
local RunService = Utils.RunService
local Players = Utils.Players
local Selection = Utils.Selection

-- Same idiom Lifecycle.luau:11 uses; Selection:Get requires PluginOrOpenCloud capability.
local IS_PLUGIN = pcall(function() return Selection:Get() end)

local GuiHost = {}

--[[
	解析当前运行环境应挂载插件内部 ScreenGui 的容器。

	@return Instance? - 插件返回 CoreGui；客户端返回 PlayerGui（最多等 5 秒）；服务端或无 LocalPlayer 返回 nil
]]
function GuiHost.resolveContainer()
	if IS_PLUGIN then return CoreGui end
	if RunService:IsClient() then
		local lp = Players.LocalPlayer
		if lp then
			return lp:FindFirstChildOfClass("PlayerGui") or lp:WaitForChild("PlayerGui", 5)
		end
	end
	return nil
end

return GuiHost
