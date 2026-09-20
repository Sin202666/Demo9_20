--[[
	Module: UISetManager
	Description: 客户端 UI 自适应缩放启动器，向 UISetMgr 注册主要 ScreenGui 并监听 PlayerGui 世界空间 Gui
	Author: 林奥宇
	Created: 2026-08-04
	Last Modified: 2026-09-02

	功能：
	- 等待 PlayerGui，注册 ScreenGui（同步 TipsGui 根 UIScale）
	- 若存在 ScreenGui_Full / UIAnimGui，一并注册弹窗二次适配
	- WatchPlayerGui：自动注册 PlayerGui 内 BillboardGui / SurfaceGui 的描边适配
	- WatchTaggedCollectors：监听标签 StrokeAdapt（workspace 等处的 BillboardGui / SurfaceGui）

	约定：
	- 仅做编排，不包含缩放计算；缩放逻辑在 Utils.UISetMgr
	- Studio 侧请移除各 ScreenGui 下旧的自适应 LocalScript，避免双写 Scale
	- workspace BillboardGui / SurfaceGui：标签 StrokeAdapt 可打在 Gui、其子节点或父级 Model/Part
	- 不要打在 workspace 根或超大地图 Model 上

	依赖：
	- Utils.UISetMgr.RegisterScreenGui
	- Utils.UISetMgr.WatchPlayerGui
	- Utils.UISetMgr.WatchTaggedCollectors
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local UISetMgr = Utils.UISetMgr
local LocalPlayer = Utils.LocalPlayer

local playerGui = LocalPlayer:WaitForChild("PlayerGui", math.huge) :: PlayerGui

local screenGui = playerGui:WaitForChild("ScreenGui", math.huge) :: ScreenGui
UISetMgr.RegisterScreenGui(screenGui, {
	syncTipsGui = true,
	adaptPopups = true,
})

local screenGuiFull = playerGui:FindFirstChild("ScreenGui_Full")
if screenGuiFull and screenGuiFull:IsA("ScreenGui") then
	UISetMgr.RegisterScreenGui(screenGuiFull, {
		adaptPopups = true,
	})
end

local uianimGui = playerGui:FindFirstChild("UIAnimGui")
if uianimGui and uianimGui:IsA("ScreenGui") then
	UISetMgr.RegisterScreenGui(uianimGui, {
		adaptPopups = true,
	})
end

UISetMgr.WatchPlayerGui(playerGui)
UISetMgr.WatchTaggedCollectors()
