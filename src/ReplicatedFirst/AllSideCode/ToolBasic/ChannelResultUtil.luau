--[[
	Module: ChannelResultUtil
	Description: Lighting 通道 hide/apply 跳过原因合并与结果解析（纯工具；SystemLighting / Weather 共用）
	Author: 中台组 林奥宇
	Created: 2026-08-05
	Last Modified: 2026-08-05

	功能：
	- 解析通道 hide 返回值 → (ok, err, skipReason)
	- 解析通道 apply 返回值（boolean 成功 或 LightingApplyResult 字符串）
	- 合并多通道 skipReason（FxBusy 优先于 QualitySkip）
	- 判定是否为预期跳过（不写 LightingLastError）

	通道 hide 约定（ChannelDef.hide）：
	- 返回 (handled: boolean, resultCode: string)
	- handled=true + FxBusy/QualitySkip：预期跳过，skipReason 写入 LightingSkipReason
	- handled=true + Ok：正常 hide
	- handled=false：硬错误

	通道 apply 约定：
	- 多数通道返回 true（成功）
	- ColorCorrection 等返回 EnumMgr.LightingApplyResult 字符串（Ok / FxBusy）
	- 禁止用 ClassName 推断 FxBusy

	加载：
	local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
	local ChannelResultUtil = Utils.ChannelResultUtil
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local EnumMgr = Utils.EnumMgr
local LightingApplyResult = EnumMgr.LightingApplyResult

local EXPECTED_SKIP: { [string]: boolean } = {
	[LightingApplyResult.FxBusy] = true,
	[LightingApplyResult.QualitySkip] = true,
}

local ChannelResultUtil = {}

--[[
	是否为预期跳过（运维上不算故障）

	@param reason string? - LightingApplyResult 或 LightingSkipReason
	@return boolean - true 表示 FxBusy / QualitySkip
]]
function ChannelResultUtil.isExpectedSkip(reason: string?): boolean
	return typeof(reason) == "string" and EXPECTED_SKIP[reason] == true
end

--[[
	合并 skipReason；FxBusy 优先于 QualitySkip

	@param current string? - 已有 skipReason
	@param incoming string? - 新 skipReason
	@return string? - 合并结果；均为 nil 时 nil
]]
function ChannelResultUtil.mergeSkipReason(current: string?, incoming: string?): string?
	if incoming == nil then
		return current
	end
	if current == nil then
		return incoming
	end
	if current == LightingApplyResult.FxBusy or incoming == LightingApplyResult.FxBusy then
		return LightingApplyResult.FxBusy
	end
	return incoming
end

--[[
	解析通道 hide 返回值

	@param handled boolean - hide 是否完成（含预期跳过）
	@param resultCode string? - EnumMgr.LightingApplyResult；nil 视为 Ok
	@param className string - 通道 ClassName（错误文案）
	@return boolean - true 无硬错误
	@return string? - 硬错误文案
	@return string? - 预期 skipReason（FxBusy / QualitySkip）
]]
function ChannelResultUtil.fromHideResult(
	handled: boolean,
	resultCode: string?,
	className: string
): (boolean, string?, string?)
	local code = resultCode or LightingApplyResult.Ok
	if not handled then
		return false, ("hide %s: %s"):format(className, tostring(code)), nil
	end
	if ChannelResultUtil.isExpectedSkip(code) then
		return true, nil, code
	end
	if code == LightingApplyResult.Ok then
		return true, nil, nil
	end
	return false, ("hide %s: %s"):format(className, tostring(code)), nil
end

--[[
	解析通道 apply 返回值

	@param result boolean | string - true 成功；LightingApplyResult 字符串；false 为硬错误
	@param err string? - pcall 或显式硬错误文案（优先于 result）
	@param className string - 通道 ClassName
	@return boolean - true 无硬错误
	@return string? - 硬错误文案
	@return string? - 预期 skipReason
]]
function ChannelResultUtil.fromApplyResult(
	result: boolean | string,
	err: string?,
	className: string
): (boolean, string?, string?)
	if err then
		return false, err, nil
	end
	if typeof(result) == "string" then
		local code = result
		if code == LightingApplyResult.Ok then
			return true, nil, nil
		end
		if ChannelResultUtil.isExpectedSkip(code) then
			return true, nil, code
		end
		return false, ("apply %s: %s"):format(className, tostring(code)), nil
	end
	if result == true then
		return true, nil, nil
	end
	return false, ("apply 返回 false: %s"):format(className), nil
end

--[[
	累计通道 outcome 到 firstError / skipReason

	@param firstError string? - 已有首个错误
	@param skipReason string? - 已有 skipReason
	@param ok boolean - 本通道是否无硬错误
	@param err string? - 本通道硬错误
	@param skip string? - 本通道 skipReason
	@return string? - 更新后 firstError
	@return string? - 更新后 skipReason
]]
function ChannelResultUtil.accumulateOutcome(
	firstError: string?,
	skipReason: string?,
	ok: boolean,
	err: string?,
	skip: string?
): (string?, string?)
	local mergedSkip = ChannelResultUtil.mergeSkipReason(skipReason, skip)
	if not ok and firstError == nil then
		firstError = err
	end
	return firstError, mergedSkip
end

return ChannelResultUtil
