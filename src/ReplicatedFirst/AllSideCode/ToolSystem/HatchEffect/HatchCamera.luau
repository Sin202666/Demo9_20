--[[
	Module: HatchEffect/HatchCamera
	Description: 抽蛋表现摄像机缩放与位置查询
	Author: 林奥宇
	Created: 2026-01-29
	Last Modified: 2026-09-01

	由 HatchEffect 子模块内部调用，勿经 Utils 直接使用。

	边界（与 CameraModule 所有权约定）：
	- 仅允许改 LocalPlayer.CameraMinZoomDistance；禁止旁路写 CurrentCamera.CFrame / FieldOfView
	- CFrame / FOV 一律经 Utils.CameraModule（主事件 / Helper / 震动）
	- getCamera / getCameraCFrame 每次读 workspace.CurrentCamera，不缓存实例
	- setZoomForHatch 只在首次持有时记下原 CameraMinZoomDistance，restoreZoom 还原该值
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local LocalPlayer = Utils.LocalPlayer

local HatchConfig = require(script.Parent.HatchConfig)

local HatchCamera = {}

local savedMinZoom: number? = nil

--[[
	获取当前摄像机 CFrame（跟随 CurrentCamera 替换）

	@return CFrame - workspace.CurrentCamera.CFrame
]]
function HatchCamera.getCameraCFrame(): CFrame
	return workspace.CurrentCamera.CFrame
end

--[[
	将玩家摄像机最小缩放距离设为抽蛋表现值。
	同一轮表现多次调用时只保存第一次的原值。
	LocalPlayer 缺失时（非客户端误载）直接返回。
]]
function HatchCamera.setZoomForHatch()
	if not LocalPlayer then
		return
	end
	if savedMinZoom == nil then
		savedMinZoom = LocalPlayer.CameraMinZoomDistance
	end
	LocalPlayer.CameraMinZoomDistance = HatchConfig.CAMERA_MIN_ZOOM_MAX
end

--[[
	恢复玩家摄像机最小缩放距离。
	有已保存原值则还原并清空；否则回退到 CAMERA_MIN_ZOOM_MIN。
	LocalPlayer 缺失时直接返回。
]]
function HatchCamera.restoreZoom()
	if not LocalPlayer then
		return
	end
	if savedMinZoom ~= nil then
		LocalPlayer.CameraMinZoomDistance = savedMinZoom
		savedMinZoom = nil
	else
		LocalPlayer.CameraMinZoomDistance = HatchConfig.CAMERA_MIN_ZOOM_MIN
	end
end

--[[
	获取 CurrentCamera 引用（奖励 / 容器模型挂载父级）

	@return Camera - 当前 workspace.CurrentCamera
]]
function HatchCamera.getCamera(): Camera
	return workspace.CurrentCamera
end

return HatchCamera
