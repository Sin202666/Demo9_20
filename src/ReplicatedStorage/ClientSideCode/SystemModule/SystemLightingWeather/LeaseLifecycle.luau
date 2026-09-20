--[[
	Module: SystemLightingWeather/LeaseLifecycle
	Description: lease TTL / StaleWarn / HardMax 调度与扫描释放
	Author: 林奥宇
	Created: 2026-08-05
	Last Modified: 2026-08-31

	职责：
	- 按最近 expiresAt / StaleWarn / HardMax 调度 task.delay
	- 无 TTL 过久：写 LightingStaleLeaseWriters + 一次性 Log.warn（不自动释放）
	- TTL 到期 / HardMax：移出栈并经 deps.applyIfChanged 触发画面 reconcile
	- isLive：destroy 后作废已 delay 的 token 回调

	依赖 LeaseStack（纯逻辑）与调用方注入的 applyIfChanged（通常为 ApplyCoalesce）。
	由 SystemLightingWeather 持有；勿被业务直接 require。
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Log = Utils.Log
local Lighting = Utils.Lighting
local EnumMgr = Utils.EnumMgr
local LeaseStack = require(script.Parent.LeaseStack)
local ApplyPipeline = require(script.Parent.ApplyPipeline)

local WeatherLeaseExpireTransitionSec = EnumMgr.WeatherLeaseExpireTransitionSec
local WeatherLeaseStaleWarnSec = EnumMgr.WeatherLeaseStaleWarnSec
local WeatherLeaseHardMaxSec = EnumMgr.WeatherLeaseHardMaxSec
local DEFAULT_STALE_WARN_SEC = 600
local DEFAULT_HARD_MAX_SEC = 1800

local LeaseLifecycle = {}

export type AttrNames = ApplyPipeline.AttrNames
export type WeatherLease = LeaseStack.WeatherLease

export type LifecycleHost = {
	_degraded: boolean?,
	_lightingSystem: any?,
	_customState: any?,
	_leases: { [string]: WeatherLease },
	_staleWarnedWriters: { [string]: boolean },
	_forceAcquireAt: { [string]: number },
	_sweepToken: number,
}

export type LifecycleDeps = {
	attrs: AttrNames,
	isLive: (host: LifecycleHost) -> boolean,
	-- 释放后请求画面对齐（通常 ApplyCoalesce.applyEffectiveIfChangedCoalesced）
	applyIfChanged: (host: LifecycleHost, transitionTime: number, force: boolean?) -> boolean,
}

-- ========================================
-- 私有函数
-- ========================================
--[[
	编排层是否可写通道

	@param host LifecycleHost - Weather 实例字段
	@return boolean - true 可写
]]
local function _isReady(host: LifecycleHost): boolean
	return host._degraded ~= true and host._lightingSystem ~= nil and host._customState ~= nil
end

--[[
	取两个可选 delay 的较小值

	@param a number? - 延迟 A
	@param b number? - 延迟 B
	@return number? - min；皆 nil 则 nil
]]
local function _minDelay(a: number?, b: number?): number?
	if a ~= nil and b ~= nil then
		return math.min(a, b)
	end
	return a or b
end

--[[
	解析 StaleWarn 秒数

	@return number - 告警阈值
]]
local function _resolveStaleWarnSec(): number
	local warnSec = WeatherLeaseStaleWarnSec
	if typeof(warnSec) ~= "number" or warnSec <= 0 then
		return DEFAULT_STALE_WARN_SEC
	end
	return warnSec
end

-- ========================================
-- 公共函数
-- ========================================
--[[
	解析无 TTL 硬上限秒数（<=0 关闭）

	@return number - 硬上限；0 表示关闭自动释放
]]
function LeaseLifecycle.resolveHardMaxSec(): number
	local hardMax = WeatherLeaseHardMaxSec
	if typeof(hardMax) ~= "number" then
		return DEFAULT_HARD_MAX_SEC
	end
	if hardMax <= 0 then
		return 0
	end
	return hardMax
end

--[[
	扫描无 TTL 过久 lease：写 LightingStaleLeaseWriters + 一次性 Log.warn（不自动释放）

	@param host LifecycleHost - Weather 实例
	@param deps LifecycleDeps - attrs 等
	@return nil - 无返回值
]]
function LeaseLifecycle.warnStaleLeases(host: LifecycleHost, deps: LifecycleDeps)
	local warnSec = _resolveStaleWarnSec()
	local staleWriters = LeaseStack.collectStaleWriters(host._leases, time(), warnSec, host._staleWarnedWriters)
	for _, writerId in staleWriters do
		host._staleWarnedWriters[writerId] = true
		local lease = host._leases[writerId]
		Log.warn(
			"SystemLightingWeather: 无 TTL lease 存活过久，请 FORCE_CLEAR / RELEASE",
			writerId,
			lease and lease.name,
			warnSec
		)
	end

	local names = {}
	for writerId, lease in host._leases do
		if lease.expiresAt == nil and host._staleWarnedWriters[writerId] then
			table.insert(names, writerId)
		end
	end
	table.sort(names)
	local attrName = deps.attrs.staleLeaseWriters
	if attrName then
		Lighting:SetAttribute(attrName, if #names > 0 then table.concat(names, ",") else nil)
	end
end

--[[
	按最近 expiresAt / StaleWarn / HardMax 调度下一次维护（无待办则不挂定时器）

	@param host LifecycleHost - Weather 实例
	@param deps LifecycleDeps - isLive + applyIfChanged
	@param onSweep (host) -> () - 到期回调（通常 self:sweepExpiredLeases）
	@return nil - 无返回值
]]
function LeaseLifecycle.scheduleSweep(
	host: LifecycleHost,
	deps: LifecycleDeps,
	onSweep: (host: LifecycleHost) -> ()
)
	host._sweepToken += 1
	local token = host._sweepToken
	local now = time()
	local expireDelay = LeaseStack.getSoonestExpireDelay(host._leases, now)
	local staleDelay = LeaseStack.getSoonestStaleWarnDelay(
		host._leases,
		now,
		_resolveStaleWarnSec(),
		host._staleWarnedWriters
	)
	local hardMaxDelay = LeaseStack.getSoonestHardMaxDelay(host._leases, now, LeaseLifecycle.resolveHardMaxSec())
	local delaySec = _minDelay(_minDelay(expireDelay, staleDelay), hardMaxDelay)
	if delaySec == nil then
		return
	end
	task.delay(delaySec, function()
		if not deps.isLive(host) or host._sweepToken ~= token then
			return
		end
		onSweep(host)
	end)
end

--[[
	作废已调度的 sweep（destroy）

	@param host LifecycleHost - Weather 实例
	@return nil - 无返回值
]]
function LeaseLifecycle.cancelSweep(host: LifecycleHost)
	host._sweepToken += 1
end

--[[
	扫描并释放过期 / HardMax lease，并刷新 StaleWarn；释放后经 applyIfChanged 对齐画面

	@param host LifecycleHost - Weather 实例
	@param deps LifecycleDeps - applyIfChanged / attrs
	@param onSweep (host) -> () - 再次调度用（通常再调 sweepExpiredLeases 入口）
	@return nil - 无返回值
]]
function LeaseLifecycle.sweepExpired(
	host: LifecycleHost,
	deps: LifecycleDeps,
	onSweep: (host: LifecycleHost) -> ()
)
	if not _isReady(host) then
		return
	end
	local now = time()
	local hardMaxSec = LeaseLifecycle.resolveHardMaxSec()
	local expiredWriters = LeaseStack.collectExpiredWriters(host._leases, now)
	local hardMaxWriters = LeaseStack.collectHardMaxWriters(host._leases, now, hardMaxSec)

	local toRelease: { string } = {}
	local releasedSet: { [string]: boolean } = {}
	for _, writerId in expiredWriters do
		if not releasedSet[writerId] then
			releasedSet[writerId] = true
			table.insert(toRelease, writerId)
		end
	end
	for _, writerId in hardMaxWriters do
		if not releasedSet[writerId] then
			releasedSet[writerId] = true
			table.insert(toRelease, writerId)
		end
	end

	if #toRelease == 0 then
		LeaseLifecycle.warnStaleLeases(host, deps)
		LeaseLifecycle.scheduleSweep(host, deps, onSweep)
		return
	end

	local hardMaxSet: { [string]: boolean } = {}
	for _, writerId in hardMaxWriters do
		hardMaxSet[writerId] = true
	end

	for _, writerId in toRelease do
		local lease = host._leases[writerId]
		if lease then
			if hardMaxSet[writerId] then
				Log.warn(
					"SystemLightingWeather: 无 TTL lease 达到 HardMax，容灾自动释放",
					writerId,
					lease.name,
					hardMaxSec
				)
			else
				Log.print("SystemLightingWeather: lease TTL 到期自动释放", writerId, lease.name)
			end
			host._leases[writerId] = nil
			host._forceAcquireAt[writerId] = nil
			host._staleWarnedWriters[writerId] = nil
		end
	end
	local expireTransition = WeatherLeaseExpireTransitionSec
	if typeof(expireTransition) ~= "number" or expireTransition < 0 then
		expireTransition = 0.5
	end
	LeaseLifecycle.warnStaleLeases(host, deps)
	deps.applyIfChanged(host, expireTransition, false)
	LeaseLifecycle.scheduleSweep(host, deps, onSweep)
end

return LeaseLifecycle
