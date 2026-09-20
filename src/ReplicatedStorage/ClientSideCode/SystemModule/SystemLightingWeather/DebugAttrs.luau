--[[
	Module: SystemLightingWeather/DebugAttrs
	Description: Lighting 调试 Attribute 名表（Weather / ApplyPipeline 共用）
	Author: 林奥宇
	Created: 2026-08-04
	Last Modified: 2026-08-31

	CurrentLightingName：意图名（lease 优胜或 baseline）
	LightingAppliedName：最近一次天气 apply 成功落地名（与意图对照；失败不推进）
	落地判定：Pending==false 且 AppliedName==CurrentLightingName 且 LastError==nil
	LightingStaleLeaseWriters：无 TTL 且存活超过 WeatherLeaseStaleWarnSec 的 writerId（逗号拼接）
	LightingApplyPending：同帧 coalesce 已排队、尚未 flush（Acquire true ≠ 画面已落地）
	LightingBootReady：编排可用且 LightingConfig 目录存在（上线健康检查阻断项）
]]

local DebugAttrs = {
	currentLighting = "CurrentLightingName",
	appliedLighting = "LightingAppliedName",
	baselineLighting = "CurrentBaselineLightingName",
	leaseCount = "LightingLeaseCount",
	topLeaseWriter = "LightingTopLeaseWriter",
	lastError = "LightingLastError",
	overlayTop = "LightingOverlayTop",
	skipReason = "LightingSkipReason",
	staleLeaseWriters = "LightingStaleLeaseWriters",
	applyPending = "LightingApplyPending",
	bootReady = "LightingBootReady",
}

table.freeze(DebugAttrs)

return DebugAttrs
