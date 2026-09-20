--[[
	Module: SystemLightingValidationTest
	Description: SystemLighting 通道结果 / Tween / PostEffect 语义验收用例
	Author: 中台组 林奥宇
	Created: 2026-08-05
	Last Modified: 2026-08-05

	运行方式：在 Studio 中 require 本模块并调用 runAll()
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local EnumMgr = Utils.EnumMgr
local LightingTweenUtil = Utils.LightingTweenUtil
local ChannelResultUtil = Utils.ChannelResultUtil
local EffectChannelUtil = require(script.Parent.EffectChannelUtil)

local LightingApplyResult = EnumMgr.LightingApplyResult

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
		print(("[SystemLightingValidationTest] %s: 通过"):format(name))
		return passed + 1, failed
	end
	warn(("[SystemLightingValidationTest] %s: 失败"):format(name))
	return passed, failed + 1
end

--[[
	运行全部用例

	@return boolean - 全部通过为 true
]]
function M.runAll(): boolean
	local passed = 0
	local failed = 0

	-- 1. ChannelResultUtil.isExpectedSkip
	do
		passed, failed = _check(
			"isExpectedSkip FxBusy",
			ChannelResultUtil.isExpectedSkip(LightingApplyResult.FxBusy) == true,
			passed,
			failed
		)
		passed, failed = _check(
			"isExpectedSkip QualitySkip",
			ChannelResultUtil.isExpectedSkip(LightingApplyResult.QualitySkip) == true,
			passed,
			failed
		)
		passed, failed = _check(
			"isExpectedSkip ChannelError",
			ChannelResultUtil.isExpectedSkip(LightingApplyResult.ChannelError) == false,
			passed,
			failed
		)
	end

	-- 2. ChannelResultUtil.mergeSkipReason（FxBusy 优先）
	do
		local m1 = ChannelResultUtil.mergeSkipReason(LightingApplyResult.QualitySkip, LightingApplyResult.FxBusy)
		passed, failed = _check("mergeSkipReason FxBusy 优先", m1 == LightingApplyResult.FxBusy, passed, failed)

		local m2 = ChannelResultUtil.mergeSkipReason(nil, LightingApplyResult.QualitySkip)
		passed, failed = _check("mergeSkipReason nil+QualitySkip", m2 == LightingApplyResult.QualitySkip, passed, failed)

		local m3 = ChannelResultUtil.mergeSkipReason(LightingApplyResult.QualitySkip, nil)
		passed, failed = _check("mergeSkipReason QualitySkip+nil", m3 == LightingApplyResult.QualitySkip, passed, failed)
	end

	-- 3. ChannelResultUtil.fromHideResult（CC FxBusy 预期跳过）
	do
		local ok, err, skip = ChannelResultUtil.fromHideResult(true, LightingApplyResult.FxBusy, "ColorCorrectionEffect")
		passed, failed = _check("fromHideResult FxBusy ok", ok == true and err == nil, passed, failed)
		passed, failed = _check("fromHideResult FxBusy skip", skip == LightingApplyResult.FxBusy, passed, failed)

		local ok2, err2, skip2 = ChannelResultUtil.fromHideResult(true, LightingApplyResult.Ok, "BloomEffect")
		passed, failed = _check("fromHideResult Ok", ok2 == true and err2 == nil and skip2 == nil, passed, failed)

		local ok3, err3, skip3 = ChannelResultUtil.fromHideResult(false, LightingApplyResult.ChannelError, "BloomEffect")
		passed, failed = _check("fromHideResult 硬错误", ok3 == false and skip3 == nil and typeof(err3) == "string", passed, failed)
	end

	-- 4. ChannelResultUtil.fromApplyResult（显式结果码；不再按 ClassName 推断）
	do
		local ok, err, skip = ChannelResultUtil.fromApplyResult(LightingApplyResult.FxBusy, nil, "ColorCorrectionEffect")
		passed, failed = _check("fromApplyResult FxBusy ok", ok == true and err == nil, passed, failed)
		passed, failed = _check("fromApplyResult FxBusy skip", skip == LightingApplyResult.FxBusy, passed, failed)

		local ok2, err2, skip2 = ChannelResultUtil.fromApplyResult(true, nil, "BloomEffect")
		passed, failed = _check("fromApplyResult 成功 boolean", ok2 == true and skip2 == nil, passed, failed)

		local okOk, errOk, skipOk = ChannelResultUtil.fromApplyResult(LightingApplyResult.Ok, nil, "ColorCorrectionEffect")
		passed, failed = _check("fromApplyResult Ok 字符串", okOk == true and errOk == nil and skipOk == nil, passed, failed)

		local ok3, err3 = ChannelResultUtil.fromApplyResult(false, "boom", "BloomEffect")
		passed, failed = _check("fromApplyResult 硬错误文案", ok3 == false and err3 == "boom", passed, failed)

		local ok4, err4, skip4 = ChannelResultUtil.fromApplyResult(false, nil, "BloomEffect")
		passed, failed = _check(
			"fromApplyResult boolean false 硬错误",
			ok4 == false and skip4 == nil and typeof(err4) == "string",
			passed,
			failed
		)
	end

	-- 5. ChannelResultUtil.accumulateOutcome
	do
		local err, skip = ChannelResultUtil.accumulateOutcome(nil, nil, true, nil, LightingApplyResult.FxBusy)
		passed, failed = _check("accumulateOutcome 单 skip", skip == LightingApplyResult.FxBusy and err == nil, passed, failed)

		local err2, skip2 = ChannelResultUtil.accumulateOutcome(
			nil,
			LightingApplyResult.QualitySkip,
			true,
			nil,
			LightingApplyResult.FxBusy
		)
		passed, failed = _check("accumulateOutcome 合并 skip", skip2 == LightingApplyResult.FxBusy, passed, failed)

		local err3, skip3 = ChannelResultUtil.accumulateOutcome(nil, nil, false, "通道失败", nil)
		passed, failed = _check("accumulateOutcome 硬错误", err3 == "通道失败" and skip3 == nil, passed, failed)
	end

	-- 6. LightingTweenUtil.normalizeTransitionTime
	do
		passed, failed = _check("normalize nil→0", LightingTweenUtil.normalizeTransitionTime(nil) == 0, passed, failed)
		passed, failed = _check("normalize 负数→0", LightingTweenUtil.normalizeTransitionTime(-3) == 0, passed, failed)
		passed, failed = _check("normalize 正数保留", LightingTweenUtil.normalizeTransitionTime(2.5) == 2.5, passed, failed)
	end

	-- 7. LightingTweenUtil.playOrApply 即时写路径
	do
		local applied = false
		local instance = { Brightness = 0 }
		local tween = LightingTweenUtil.playOrApply(nil, instance :: any, 0, { Brightness = 1 }, function()
			applied = true
			instance.Brightness = 1
		end)
		passed, failed = _check("playOrApply t=0 无 Tween", tween == nil, passed, failed)
		passed, failed = _check("playOrApply t=0 调 applyNow", applied == true, passed, failed)
		passed, failed = _check("playOrApply t=0 写入属性", instance.Brightness == 1, passed, failed)
	end

	-- 8. EffectChannelUtil 关闭语义
	do
		local wrote = false
		local owner = {
			Instance = { Enabled = true },
			TransitionTween = nil,
		}
		local shouldTween = EffectChannelUtil.beginEnabledWrite(owner :: any, false, function()
			wrote = true
		end)
		passed, failed = _check("beginEnabledWrite 关闭返回 false", shouldTween == false, passed, failed)
		passed, failed = _check("beginEnabledWrite 关闭先写目标", wrote == true, passed, failed)
		passed, failed = _check("beginEnabledWrite 关闭后 Enabled=false", owner.Instance.Enabled == false, passed, failed)
	end

	print(("[SystemLightingValidationTest] 完成：通过 %d / 失败 %d"):format(passed, failed))
	return failed == 0
end

return M
