--[[
	Module: RankManager
	Description: 客户端排行榜展示启动（薄 Manager）
	Author: 林奥宇
	Created: 2026-09-01
	Last Modified: 2026-09-01

	职责：
	- 调用 SystemRankManager.Init，绑定格子与定时刷新
	- 不写 workspace 榜单缓存 / 前 3 名（权威在服务端 SystemRank）

	加载：
		StarterPlayerScripts 自动运行；业务请走 Utils.SystemRankManager
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local SystemRankManager = Utils.SystemRankManager

SystemRankManager.Init()
