--[[
	Module: InitBackpack
	Description: Main.Backpack 薄启动（业务在 GuiScripts/Backpack）
	Author: 林奥宇
	Created: 2026-09-04
	Last Modified: 2026-09-04

	功能：
	- GameConfig「背包UI.启用」= false：强制藏 Main.Backpack，不 require UI、不 CharacterAdded 重试
	- 启用时 PlayerGui.ScreenGui.Main.Backpack 存在则 Backpack.init
	- 缺节点时 CharacterAdded 重试一次路径，避免静默失败

	约定：
	- 本文件为 StarterPlayerScripts LocalScript，启动即跑；无 Init() / 模块表
	- 业务不进 Manager；不自建整窗 Instance
	- 关闭只拦 HUD；库存镜像与金币顶栏不在本脚本
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local SystemGameConfig = Utils.SystemGameConfig
local LocalPlayer = Utils.LocalPlayer
local Log = Utils.Log

--[[
	关闭背包 UI 时强制藏 Main.Backpack（Place 可能默认显示）
	@return nil
]]
local function _hideMainBackpack(): ()
	local pg = LocalPlayer:WaitForChild("PlayerGui", math.huge) :: PlayerGui
	local sg = pg:WaitForChild("ScreenGui", math.huge) :: ScreenGui
	local main = sg:WaitForChild("Main", math.huge) :: Frame
	local backpack = main:FindFirstChild("Backpack")
	if backpack and backpack:IsA("GuiObject") then
		backpack.Visible = false
	end
end

if SystemGameConfig.GetValue({ "背包UI", "启用" }) == false then
	_hideMainBackpack()
	return
end

local ReplicatedStorage = Utils.ReplicatedStorage
local guiScripts = ReplicatedStorage.ClientSideCode.GuiScripts.ModuleScript
local Backpack = require(guiScripts.Backpack)

local initialized = false

--[[
	尝试从 PlayerGui 初始化背包 HUD

	@return boolean - 是否成功
]]
local function _tryInitFromPlayerGui(): boolean
	if initialized then
		return true
	end
	local pg = LocalPlayer:WaitForChild("PlayerGui", math.huge) :: PlayerGui
	local sg = pg:WaitForChild("ScreenGui", math.huge) :: ScreenGui
	local main = sg:WaitForChild("Main", math.huge) :: Frame
	if not main:FindFirstChild("Backpack") then
		Log.warn("[InitBackpack] Main.Backpack missing — Place 须有工具栏+仓库 Temp（节点名见 GuiScripts/Backpack/AllUI）")
		return false
	end
	if not Backpack.init(main) then
		Log.warn("[InitBackpack] Backpack.init failed")
		return false
	end
	initialized = true
	return true
end

if not _tryInitFromPlayerGui() then
	local conn: RBXScriptConnection? = nil
	conn = LocalPlayer.CharacterAdded:Connect(function()
		task.defer(function()
			if _tryInitFromPlayerGui() and conn then
				conn:Disconnect()
				conn = nil
			end
		end)
	end)
end
