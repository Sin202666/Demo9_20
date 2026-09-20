--[[
	Module: NetWorkManager
	Description: 服务端启动统一通信管道与请求限频，不包含业务注册
	Author: 林奥宇
	Created: 2026-06-30
	Last Modified: 2026-08-31

	功能：
	- RequestRateLimit.Init：限频中间件
	- NetWork.Init：统一 Remote / Bindable 管道

	调用关系：
	- 业务注册在各 System（如 SystemSet / SystemBag），本脚本只编排启动
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local RequestRateLimit = Utils.RequestRateLimit
local NetWork = Utils.NetWork

RequestRateLimit.Init()
NetWork.Init()
