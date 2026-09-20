--[[
	Module: SystemLightingWeather/LeaseStack
	Description: 天气 lease 栈纯逻辑（priority / TTL / 优胜选取 / 无 TTL 告警与硬上限）
	Author: 林奥宇
	Created: 2026-08-04
	Last Modified: 2026-08-31

	无 expiresAt 的 lease（Dungeon 默认）：
	- 超过 WeatherLeaseStaleWarnSec：告警（LightingStaleLeaseWriters），不释放
	- 超过 WeatherLeaseHardMaxSec（>0）：容灾自动释放（业务仍应在副本退出 FORCE_CLEAR / RELEASE）
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Log = Utils.Log
local EnumMgr = Utils.EnumMgr

local WeatherWriterPriority = EnumMgr.WeatherWriterPriority
local WeatherLeaseDefaultTtl = EnumMgr.WeatherLeaseDefaultTtl

local PRIORITY_WHITELIST: { [number]: boolean } = {
	[WeatherWriterPriority.Skill] = true,
	[WeatherWriterPriority.Dungeon] = true,
}

export type WeatherLease = {
	name: string,
	priority: number,
	order: number,
	expiresAt: number?,
	acquiredAt: number,
	writerId: string,
}

export type WeatherLeaseSnapshot = {
	writerId: string,
	name: string,
	priority: number,
	order: number,
	expiresAt: number?,
	acquiredAt: number,
}

-- ========================================
-- 公共函数
-- ========================================
local LeaseStack = {}

--[[
	校验 priority；nil 默认 Skill；非法返回 nil

	@param priority number? - 原始优先级
	@param onInvalid ((string) -> ())? - 非法时回调（写 LastError）
	@return number? - 合法值
]]
function LeaseStack.resolvePriority(priority: number?, onInvalid: ((string) -> ())?): number?
	if priority == nil then
		return WeatherWriterPriority.Skill
	end
	if typeof(priority) == "number" and PRIORITY_WHITELIST[priority] then
		return priority
	end
	Log.warn("SystemLightingWeather: 非法 priority，拒绝 Acquire", priority)
	if onInvalid then
		onInvalid("非法 priority: " .. tostring(priority))
	end
	return nil
end

--[[
	按 priority / 显式 ttl 计算 expiresAt

	@param priority number - 已校验优先级
	@param ttl number? - nil=默认；0=永不过期；>0=秒
	@return number? - time() 截止；nil 永不过期
]]
function LeaseStack.resolveExpiresAt(priority: number, ttl: number?): number?
	local seconds: number
	if typeof(ttl) == "number" then
		if ttl <= 0 then
			return nil
		end
		seconds = ttl
	elseif priority == WeatherWriterPriority.Dungeon then
		seconds = WeatherLeaseDefaultTtl.Dungeon
	elseif priority == WeatherWriterPriority.Skill then
		seconds = WeatherLeaseDefaultTtl.Skill
	else
		seconds = WeatherLeaseDefaultTtl.Other
	end

	if seconds <= 0 then
		return nil
	end
	return time() + seconds
end

--[[
	在 active lease 中取最高 priority；平局取后 Acquire

	@param leases {[string]: WeatherLease} - lease 表
	@return WeatherLease? - 生效 lease
	@return string? - 优胜 writerId
]]
function LeaseStack.getWinningLease(leases: { [string]: WeatherLease }): (WeatherLease?, string?)
	local best: WeatherLease? = nil
	local bestWriter: string? = nil
	for writerId, lease in leases do
		if not best then
			best = lease
			bestWriter = writerId
		elseif lease.priority > best.priority then
			best = lease
			bestWriter = writerId
		elseif lease.priority == best.priority and lease.order > best.order then
			best = lease
			bestWriter = writerId
		end
	end
	return best, bestWriter
end

--[[
	收集已过期 writerId

	@param leases {[string]: WeatherLease} - lease 表
	@param now number - time()
	@return {string} - 过期 writerId 列表
]]
function LeaseStack.collectExpiredWriters(leases: { [string]: WeatherLease }, now: number): { string }
	local expiredWriters = {}
	for writerId, lease in leases do
		if lease.expiresAt and now >= lease.expiresAt then
			table.insert(expiredWriters, writerId)
		end
	end
	return expiredWriters
end

--[[
	收集无 TTL 且存活超过阈值、尚未告警过的 writerId

	@param leases {[string]: WeatherLease} - lease 表
	@param now number - time()
	@param warnSec number - 存活告警阈值（秒）
	@param alreadyWarned {[string]: boolean}? - 已告警集合（跳过）
	@return {string} - 新告警 writerId 列表
]]
function LeaseStack.collectStaleWriters(
	leases: { [string]: WeatherLease },
	now: number,
	warnSec: number,
	alreadyWarned: { [string]: boolean }?
): { string }
	local stale = {}
	if typeof(warnSec) ~= "number" or warnSec <= 0 then
		return stale
	end
	for writerId, lease in leases do
		if lease.expiresAt == nil then
			local acquiredAt = lease.acquiredAt
			if typeof(acquiredAt) == "number" and (now - acquiredAt) >= warnSec then
				if not (alreadyWarned and alreadyWarned[writerId]) then
					table.insert(stale, writerId)
				end
			end
		end
	end
	return stale
end

--[[
	深拷贝 lease 快照列表

	@param leases {[string]: WeatherLease} - lease 表
	@return {WeatherLeaseSnapshot} - 快照数组
]]
function LeaseStack.snapshotLeases(leases: { [string]: WeatherLease }): { WeatherLeaseSnapshot }
	local snapshots: { WeatherLeaseSnapshot } = {}
	for writerId, lease in leases do
		table.insert(snapshots, {
			writerId = writerId,
			name = lease.name,
			priority = lease.priority,
			order = lease.order,
			expiresAt = lease.expiresAt,
			acquiredAt = lease.acquiredAt,
		})
	end
	return snapshots
end

--[[
	统计 lease 数量

	@param leases {[string]: WeatherLease} - lease 表
	@return number - 数量
]]
function LeaseStack.countLeases(leases: { [string]: WeatherLease }): number
	local count = 0
	for _ in leases do
		count += 1
	end
	return count
end

--[[
	距最近一次 expiresAt 的秒数（用于 task.delay 调度）

	@param leases {[string]: WeatherLease} - lease 表
	@param now number - time()
	@return number? - 延迟秒数（>=0）；无过期项为 nil
]]
function LeaseStack.getSoonestExpireDelay(leases: { [string]: WeatherLease }, now: number): number?
	local soonest: number? = nil
	for _, lease in leases do
		if lease.expiresAt then
			if soonest == nil or lease.expiresAt < soonest then
				soonest = lease.expiresAt
			end
		end
	end
	if soonest == nil then
		return nil
	end
	return math.max(0, soonest - now)
end

--[[
	距最近一次「无 TTL lease 达到告警阈值」的秒数

	@param leases {[string]: WeatherLease} - lease 表
	@param now number - time()
	@param warnSec number - 存活告警阈值
	@param alreadyWarned {[string]: boolean}? - 已告警集合
	@return number? - 延迟秒数；无可调度项为 nil
]]
function LeaseStack.getSoonestStaleWarnDelay(
	leases: { [string]: WeatherLease },
	now: number,
	warnSec: number,
	alreadyWarned: { [string]: boolean }?
): number?
	if typeof(warnSec) ~= "number" or warnSec <= 0 then
		return nil
	end
	local soonest: number? = nil
	for writerId, lease in leases do
		if lease.expiresAt == nil and typeof(lease.acquiredAt) == "number" then
			if not (alreadyWarned and alreadyWarned[writerId]) then
				local dueAt = lease.acquiredAt + warnSec
				if soonest == nil or dueAt < soonest then
					soonest = dueAt
				end
			end
		end
	end
	if soonest == nil then
		return nil
	end
	return math.max(0, soonest - now)
end

--[[
	收集无 TTL 且存活达到硬上限的 writerId（容灾强制释放）

	@param leases {[string]: WeatherLease} - lease 表
	@param now number - time()
	@param hardMaxSec number - 硬上限秒数；<=0 视为关闭
	@return {string} - 应强制释放的 writerId 列表
]]
function LeaseStack.collectHardMaxWriters(
	leases: { [string]: WeatherLease },
	now: number,
	hardMaxSec: number
): { string }
	local writers = {}
	if typeof(hardMaxSec) ~= "number" or hardMaxSec <= 0 then
		return writers
	end
	for writerId, lease in leases do
		if lease.expiresAt == nil then
			local acquiredAt = lease.acquiredAt
			if typeof(acquiredAt) == "number" and (now - acquiredAt) >= hardMaxSec then
				table.insert(writers, writerId)
			end
		end
	end
	return writers
end

--[[
	距最近一次「无 TTL lease 达到硬上限」的秒数

	@param leases {[string]: WeatherLease} - lease 表
	@param now number - time()
	@param hardMaxSec number - 硬上限秒数；<=0 视为关闭
	@return number? - 延迟秒数；无可调度项为 nil
]]
function LeaseStack.getSoonestHardMaxDelay(
	leases: { [string]: WeatherLease },
	now: number,
	hardMaxSec: number
): number?
	if typeof(hardMaxSec) ~= "number" or hardMaxSec <= 0 then
		return nil
	end
	local soonest: number? = nil
	for _, lease in leases do
		if lease.expiresAt == nil and typeof(lease.acquiredAt) == "number" then
			local dueAt = lease.acquiredAt + hardMaxSec
			if soonest == nil or dueAt < soonest then
				soonest = dueAt
			end
		end
	end
	if soonest == nil then
		return nil
	end
	return math.max(0, soonest - now)
end

return LeaseStack
