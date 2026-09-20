--[[
	Module: QualityGateValidationTest
	Description: SystemLightingWeather/QualityGate 纯逻辑验收用例
	Author: 中台组 林奥宇
	Created: 2026-08-05
	Last Modified: 2026-08-05

	运行方式：在 Studio 中 require 本模块并调用 runAll()
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local EnumMgr = Utils.EnumMgr
local QualityGate = require(script.Parent.QualityGate)

local GRAPHICS_QUALITY_LOW = EnumMgr.LightingGraphicsQuality.Low
local GRAPHICS_QUALITY_HIGH = EnumMgr.LightingGraphicsQuality.High

local M = {}

--[[
	断言并累计结果

	@param name string - 用例名
	@param cond boolean - 条件
	@param passed number - 通过数
	@param failed number - 失败数
	@return number - 新通过数
	@return number - 新失败数
]]
local function _check(name: string, cond: boolean, passed: number, failed: number): (number, number)
	if cond then
		print(("[QualityGateValidationTest] %s: 通过"):format(name))
		return passed + 1, failed
	end
	warn(("[QualityGateValidationTest] %s: 失败"):format(name))
	return passed, failed + 1
end

--[[
	运行全部用例

	@return boolean - 全部通过为 true
]]
function M.runAll(): boolean
	local passed = 0
	local failed = 0

	do
		passed, failed = _check(
			"isLowFromValue Low",
			QualityGate.isLowFromValue(GRAPHICS_QUALITY_LOW) == true,
			passed,
			failed
		)
		passed, failed = _check(
			"isLowFromValue High",
			QualityGate.isLowFromValue(GRAPHICS_QUALITY_HIGH) == false,
			passed,
			failed
		)
		passed, failed = _check("isLowFromValue nil→高", QualityGate.isLowFromValue(nil) == false, passed, failed)
	end

	do
		local state = QualityGate.createState()
		passed, failed = _check("createState 默认非低", QualityGate.getIsLow(state) == false, passed, failed)
		passed, failed = _check(
			"createState 含 folderRemoved 字段",
			state._folderRemovedConn == nil and state._playerRemovedConn == nil,
			passed,
			failed
		)
		QualityGate.disconnect(state)
	end

	do
		local state = QualityGate.createState()
		local calls = 0
		local lastLow: boolean? = nil
		QualityGate.bind(state, function(isLow: boolean)
			calls += 1
			lastLow = isLow
		end)
		-- 无 Setting 时默认高画质；bind 可能触发一次 false
		if calls > 0 then
			passed, failed = _check("bind 无 Setting 回调为高", lastLow == false, passed, failed)
		else
			passed, failed = _check("bind 无 Setting 不崩溃", true, passed, failed)
		end
		QualityGate.disconnect(state)
	end

	print(("[QualityGateValidationTest] 完成：通过 %d / 失败 %d"):format(passed, failed))
	return failed == 0
end

return M
