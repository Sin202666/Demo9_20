--[[
	Module: NetWorkManager
	Description: 客户端启动统一通信管道，不包含业务注册
	Author: 林奥宇
	Created: 2026-06-30
	Last Modified: 2026-08-31

	功能：
	- NetWork.Init：统一 Remote / Bindable 管道

	调用关系：
	- 业务注册在各 System / Manager，本脚本只编排启动
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local NetWork = Utils.NetWork

NetWork.Init()
