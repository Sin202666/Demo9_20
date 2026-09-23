--[[
	Module: WorldGenManager
	Description: 服务端编排——启动时调用 SystemWorldGen.Init 生成固定区域完整体素地图
	Author: 程莘
	Created: 2026-09-23
	Last Modified: 2026-09-23

	功能：
	- 薄编排：仅 Utils.SystemWorldGen.Init()
	- 不实现噪声 / 剔除 / 合并 / Clone 细节

	与相关模块：
	- SystemWorldGen：唯一业务入口
	- 不改 workspace.场景；输出在 workspace.程序化地图

	端侧约束：
	- 仅服务端脚本，InitGame/Manager 启动自动运行
	- 禁止其它模块再调 SystemWorldGen.Init（除非明确要重生）

	示例：
		-- 本文件位于 ServerScriptService/InitGame/Manager，服务器启动时自动运行
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local SystemWorldGen = Utils.SystemWorldGen

--SystemWorldGen.Init()
