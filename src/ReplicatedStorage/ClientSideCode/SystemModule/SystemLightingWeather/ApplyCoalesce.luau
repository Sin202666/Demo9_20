--[[
	Module: SystemLightingWeather/ApplyCoalesce
	Description: 同帧 defer coalesce（全量 apply / 单通道 reconcile 合并）
	Author: 林奥宇
	Created: 2026-08-05
	Last Modified: 2026-08-31

	语义：
	- 同帧多次请求合并为一次 flush；已挂全量则增量 reconcile 被吸收
	- 仅 reconcile 时按通道去重；多通道同帧升格全量（一次 bump applyGen）
	- transitionTime last-wins
	- LightingApplyPending：排队未 flush 时为 true
	- 生产全量/增量入口：requestFullApply / requestReconcileChannel / applyEffectiveIfChangedCoalesced
	- isLive：destroy / 换单例后作废已 defer 的 token 回调

	由 SystemLightingWeather 持有；勿被业务直接 require。
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Lighting = Utils.Lighting
local ApplyPipeline = require(script.Parent.ApplyPipeline)

local ApplyCoalesce = {}

export type AttrNames = ApplyPipeline.AttrNames

export type CoalesceHost = {
	_degraded: boolean?,
	_lightingSystem: any?,
	_customState: any?,
	_effectiveName: string,
	_applyCoalesceToken: number,
	_pendingFullApply: boolean,
	_pendingApplyTransition: number?,
	_pendingReconcileChannels: { [string]: boolean },
}

export type CoalesceDeps = {
	attrs: AttrNames,
	-- true 表示 host 仍是当前有效单例（未 destroy / 未换实例）
	isLive: (host: CoalesceHost) -> boolean,
}

-- ========================================
-- 私有函数
-- ========================================
--[[
	编排层是否可写通道

	@param host CoalesceHost - Weather 实例字段
	@return boolean - true 可写
]]
local function _isReady(host: CoalesceHost): boolean
	return host._degraded ~= true and host._lightingSystem ~= nil and host._customState ~= nil
end

-- ========================================
-- 公共函数
-- ========================================
--[[
	同步 LightingApplyPending

	@param attrs AttrNames - Attribute 名表
	@param pending boolean - true=已排队未 flush
	@return nil - 无返回值
]]
function ApplyCoalesce.setApplyPending(attrs: AttrNames, pending: boolean)
	local attrName = attrs.applyPending
	if attrName then
		Lighting:SetAttribute(attrName, pending == true)
	end
end

--[[
	取消排队并清空 pending（destroy / 重置）

	@param host CoalesceHost - Weather 实例
	@param attrs AttrNames - Attribute 名表
	@return nil - 无返回值
]]
function ApplyCoalesce.cancelAndClear(host: CoalesceHost, attrs: AttrNames)
	host._applyCoalesceToken += 1
	host._pendingFullApply = false
	host._pendingApplyTransition = nil
	host._pendingReconcileChannels = {}
	ApplyCoalesce.setApplyPending(attrs, false)
end

--[[
	同帧 flush：全量优先；多通道 reconcile 升格全量；单通道走增量

	@param host CoalesceHost - Weather 实例
	@param deps CoalesceDeps - attrs + isLive
	@param transitionTime number - 过渡秒数（已 normalize）
	@return nil - 无返回值
]]
local function _flushPendingApply(host: CoalesceHost, deps: CoalesceDeps, transitionTime: number)
	local attrs = deps.attrs
	local wantFull = host._pendingFullApply == true
	local channels = host._pendingReconcileChannels
	host._pendingFullApply = false
	host._pendingApplyTransition = nil
	host._pendingReconcileChannels = {}

	if wantFull then
		ApplyPipeline.applyEffectiveWeather(host :: any, attrs, transitionTime)
		ApplyCoalesce.setApplyPending(attrs, false)
		return
	end

	local soleClass: string? = nil
	local channelCount = 0
	for className in channels do
		channelCount += 1
		soleClass = className
		if channelCount > 1 then
			ApplyPipeline.applyEffectiveWeather(host :: any, attrs, transitionTime)
			ApplyCoalesce.setApplyPending(attrs, false)
			return
		end
	end

	if soleClass then
		ApplyPipeline.reconcileChannel(host :: any, attrs, soleClass, transitionTime)
	end
	ApplyCoalesce.setApplyPending(attrs, false)
end

--[[
	调度同帧 coalesce defer（token 作废旧回调）

	@param host CoalesceHost - Weather 实例
	@param deps CoalesceDeps - attrs + isLive
	@return nil - 无返回值
]]
local function _scheduleApplyFlush(host: CoalesceHost, deps: CoalesceDeps)
	host._applyCoalesceToken += 1
	local token = host._applyCoalesceToken
	task.defer(function()
		if not deps.isLive(host) or host._applyCoalesceToken ~= token then
			return
		end
		local t = host._pendingApplyTransition
		if typeof(t) ~= "number" then
			t = 0
		end
		_flushPendingApply(host, deps, t)
	end)
end

--[[
	同帧合并全量 apply：吸收待 reconcile 通道；transitionTime last-wins

	@param host CoalesceHost - Weather 实例
	@param deps CoalesceDeps - attrs + isLive
	@param transitionTime number - 过渡秒数（已 normalize）
	@return nil - 无返回值
]]
function ApplyCoalesce.requestFullApply(host: CoalesceHost, deps: CoalesceDeps, transitionTime: number)
	if not _isReady(host) then
		return
	end
	host._pendingFullApply = true
	host._pendingReconcileChannels = {}
	host._pendingApplyTransition = transitionTime
	ApplyCoalesce.setApplyPending(deps.attrs, true)
	_scheduleApplyFlush(host, deps)
end

--[[
	同帧合并单通道 reconcile；若已挂全量则只更新 transition

	@param host CoalesceHost - Weather 实例
	@param deps CoalesceDeps - attrs + isLive
	@param className string - 效果 ClassName
	@param transitionTime number - 过渡秒数（已 normalize）
	@return nil - 无返回值
]]
function ApplyCoalesce.requestReconcileChannel(
	host: CoalesceHost,
	deps: CoalesceDeps,
	className: string,
	transitionTime: number
)
	if not _isReady(host) then
		return
	end
	host._pendingApplyTransition = transitionTime
	ApplyCoalesce.setApplyPending(deps.attrs, true)
	if host._pendingFullApply then
		_scheduleApplyFlush(host, deps)
		return
	end
	host._pendingReconcileChannels[className] = true
	_scheduleApplyFlush(host, deps)
end

--[[
	生效名变化或 force 时请求全量 apply（经 coalesce；生产唯一入口）

	@param host CoalesceHost - Weather 实例
	@param deps CoalesceDeps - attrs + isLive
	@param transitionTime number - 过渡秒数
	@param force boolean? - 强制重放
	@return boolean - 恒 true（已 noop 或已排队）
]]
function ApplyCoalesce.applyEffectiveIfChangedCoalesced(
	host: CoalesceHost,
	deps: CoalesceDeps,
	transitionTime: number,
	force: boolean?
): boolean
	local nextName = ApplyPipeline.getEffectiveWeatherName(host :: any)
	if not force and nextName == host._effectiveName then
		ApplyPipeline.syncLightingNameAttributes(host :: any, deps.attrs)
		return true
	end
	ApplyCoalesce.requestFullApply(host, deps, transitionTime)
	return true
end

return ApplyCoalesce
