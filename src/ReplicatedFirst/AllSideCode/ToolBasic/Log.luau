--[[
	Module: Log
	Description: 开发服 / Studio 下的统一日志门面，正式环境静默
	Author: 林奥宇
	Created: 2026-06-30
	Last Modified: 2026-08-31

	功能：
	- print / warn / printf：仅 isDebug 时输出
	- isDebug：当前是否调试模式

	加载方式：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local Log = Utils.Log
		Log.warn("msg")
]]

local Log = {}

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local RunService = Utils.RunService
local WorldUtil = Utils.WorldUtil

local serName = WorldUtil.GetServerType()
local isStudio = RunService:IsStudio()
local isDebug = false

if serName == "开发服" or isStudio == true then
	isDebug = true
end

--[[
	打印日志（仅在调试模式下）
	@param ... any - 要打印的内容
]]
function Log.print(...: any)
	if isDebug then
		print(...)
	end
end

--[[
	打印警告日志（仅在调试模式下）
	@param ... any - 要打印的内容
]]
function Log.warn(...: any)
	if isDebug then
		warn(...)
	end
end

--[[
	格式化打印日志（仅在调试模式下）
	@param format string - 格式化字符串
	@param ... any - 格式化参数
]]
function Log.printf(format: string, ...: any)
	if isDebug then
		print(string.format(format, ...))
	end
end

--[[
	获取当前是否为调试模式
	@return boolean - 是否为调试模式
]]
function Log.isDebug(): boolean
	return isDebug
end

return Log
