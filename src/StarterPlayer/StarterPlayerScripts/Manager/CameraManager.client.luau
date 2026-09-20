--[[
	Module: CameraManager
	Description: 客户端相机模块启动编排
	Author: 中台组
	Created: 2026-07-02
	Last Modified: 2026-08-05

	功能：
	- 启动时初始化 CameraModule（绑定 RenderStep）
	- CameraModule.Init 内将 ShiftLock 开关键重绑为 Ctrl（与奔跑 LeftShift 分离）
	- CameraMode 栈随 Init 启动；引擎 ShiftLock 映射为 Engine:MouseLock

	说明：
	本 Manager 必须在业务脚本（如 StarterCharacterScripts/Animate）注册相机事件之前执行。
	StarterPlayerScripts/Manager 默认先于 StarterCharacterScripts 运行，一般无需额外排序。

	完整 API、事件类型、示例见：
	ReplicatedStorage/ClientSideCode/SystemModule/CameraModule/init.luau 文件头「使用说明」
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local CameraModule = Utils.CameraModule

local ok, err = CameraModule.Init()
if not ok then
	warn("CameraManager: CameraModule.Init 失败", err)
end
