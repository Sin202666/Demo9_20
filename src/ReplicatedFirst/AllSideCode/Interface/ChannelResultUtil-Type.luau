--[[
	Module: ChannelResultUtil-Type
	Description: ChannelResultUtil 类型声明（完整说明见 ToolBasic/ChannelResultUtil.luau）
	Author: 中台组 林奥宇
	Created: 2026-08-05
	Last Modified: 2026-08-05
]]

local module = {}

--[[
	是否为预期跳过（运维上不算故障）

	@param reason string? - LightingApplyResult 或 LightingSkipReason
	@return boolean - true 表示 FxBusy / QualitySkip
]]
function module.isExpectedSkip(reason: string?): boolean
end

--[[
	合并 skipReason；FxBusy 优先于 QualitySkip

	@param current string? - 已有 skipReason
	@param incoming string? - 新 skipReason
	@return string? - 合并结果；均为 nil 时 nil
]]
function module.mergeSkipReason(current: string?, incoming: string?): string?
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
function module.fromHideResult(
	handled: boolean,
	resultCode: string?,
	className: string
): (boolean, string?, string?)
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
function module.fromApplyResult(
	result: boolean | string,
	err: string?,
	className: string
): (boolean, string?, string?)
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
function module.accumulateOutcome(
	firstError: string?,
	skipReason: string?,
	ok: boolean,
	err: string?,
	skip: string?
): (string?, string?)
end

return module
