--[[
	Module: FirstPreload (init.client)
	Description: ReplicatedFirst 加载屏入口：移除默认 LoadingScreen、挂载 UI 并启动资源预加载
	Author: 中台组
	Created: 2024-01-01
	Last Modified: 2026-07-03

	流程：
	1. 创建 IsCloseLoading 标记，循环 RemoveDefaultLoadingScreen
	2. 按 TeleportData 选择 PreloadGui / PreloadGui_Teleport
	3. LoadingUI.Start 驱动进度与关闭
	4. Preload 统计并预热资源（动作并行、静态资源顺序）
]]

-- ============================================================================
-- 服务与依赖
-- ============================================================================

local ReplicatedFirst = game:GetService("ReplicatedFirst")
local TeleportService = game:GetService("TeleportService")
local Players = game:GetService("Players")

local Preload = require(script.Preload)
local LoadingUI = require(script.LoadingUI)

local localPlayer = Players.LocalPlayer

-- ============================================================================
-- 加载完成标记（Player 下，供其他脚本 WaitForChild）
-- ============================================================================

local isCloseLoading = Instance.new("BoolValue")
isCloseLoading.Name = "IsCloseLoading"
isCloseLoading.Value = false
isCloseLoading.Parent = localPlayer

-- ============================================================================
-- 移除 Roblox 默认 LoadingScreen
-- ============================================================================

task.spawn(function()
	for _ = 1, 5 do
		ReplicatedFirst:RemoveDefaultLoadingScreen()
		task.wait(1)
	end
end)

-- ============================================================================
-- 选择 PreloadGui
-- ============================================================================

local teleportCfg = TeleportService:GetLocalPlayerTeleportData()
local preloadGui: ScreenGui

if teleportCfg then
	preloadGui = ReplicatedFirst:WaitForChild("PreloadGui_Teleport") :: ScreenGui
else
	preloadGui = ReplicatedFirst:WaitForChild("PreloadGui") :: ScreenGui
end

-- ============================================================================
-- 进度计数器（由 Preload 模块 InsMgr 创建）
-- ============================================================================

task.wait()

local resTotal = ReplicatedFirst:WaitForChild("总资源数", math.huge) :: NumberValue
local resLoadTime = ReplicatedFirst:WaitForChild("预加载时间", math.huge) :: NumberValue
local resLoaded = ReplicatedFirst:WaitForChild("已加载资源数", math.huge) :: NumberValue

-- ============================================================================
-- 启动 UI 与资源预加载
-- ============================================================================

LoadingUI.Start({
	preloadGui = preloadGui,
	teleportCfg = teleportCfg,
	resTotal = resTotal,
	resLoaded = resLoaded,
	resLoadTime = resLoadTime,
	isCloseLoading = isCloseLoading,
	onFinished = function()
		script:Destroy()
	end,
})

Preload.StartLoadTimer()

task.defer(function()
	local assetIds, animationIds = Preload.StatResInfo()

	task.spawn(function()
		Preload.PreloadAnimations(animationIds)
	end)

	Preload.PreloadAssets(assetIds)
end)
