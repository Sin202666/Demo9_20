--[[
	Module: LeaseStackValidationTest
	Description: SystemLightingWeather/LeaseStack 纯逻辑验收用例
	Author: 中台组 林奥宇
	Created: 2026-08-04
	Last Modified: 2026-08-05

	覆盖：priority / 优胜选取 / TTL 过期 / StaleWarn / HardMax / snapshot / 配置常量
	运行方式：在 Studio 中 require 本模块并调用 runAll()
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local EnumMgr = Utils.EnumMgr
local LeaseStack = require(script.Parent.LeaseStack)

local WeatherWriterPriority = EnumMgr.WeatherWriterPriority

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
		print(("[LeaseStackValidationTest] %s: 通过"):format(name))
		return passed + 1, failed
	end
	warn(("[LeaseStackValidationTest] %s: 失败"):format(name))
	return passed, failed + 1
end

--[[
	运行全部用例

	@return boolean - 全部通过为 true
]]
function M.runAll(): boolean
	local passed = 0
	local failed = 0

	-- 1. resolvePriority：nil → Skill；非法拒绝；白名单通过
	do
		local p1 = LeaseStack.resolvePriority(nil)
		passed, failed = _check("resolvePriority nil→Skill", p1 == WeatherWriterPriority.Skill, passed, failed)

		local p2 = LeaseStack.resolvePriority(WeatherWriterPriority.Baseline)
		passed, failed = _check("resolvePriority Baseline 拒绝", p2 == nil, passed, failed)

		local p3 = LeaseStack.resolvePriority(WeatherWriterPriority.Dungeon)
		passed, failed = _check("resolvePriority Dungeon 通过", p3 == WeatherWriterPriority.Dungeon, passed, failed)
	end

	-- 2. getWinningLease：高 priority 胜；平局取更大 order
	do
		local leases = {
			a = {
				name = "Day",
				priority = WeatherWriterPriority.Skill,
				order = 1,
				expiresAt = nil,
				acquiredAt = 0,
				writerId = "a",
			},
			b = {
				name = "Night",
				priority = WeatherWriterPriority.Dungeon,
				order = 2,
				expiresAt = nil,
				acquiredAt = 0,
				writerId = "b",
			},
		}
		local win, writer = LeaseStack.getWinningLease(leases)
		passed, failed = _check(
			"getWinningLease 高 priority",
			win ~= nil and win.name == "Night" and writer == "b",
			passed,
			failed
		)

		local samePrio = {
			a = {
				name = "A",
				priority = WeatherWriterPriority.Skill,
				order = 1,
				expiresAt = nil,
				acquiredAt = 0,
				writerId = "a",
			},
			b = {
				name = "B",
				priority = WeatherWriterPriority.Skill,
				order = 3,
				expiresAt = nil,
				acquiredAt = 0,
				writerId = "b",
			},
		}
		local win2, writer2 = LeaseStack.getWinningLease(samePrio)
		passed, failed = _check(
			"getWinningLease 平局 order",
			win2 ~= nil and win2.name == "B" and writer2 == "b",
			passed,
			failed
		)
	end

	-- 3. collectExpiredWriters / getSoonestExpireDelay
	do
		local now = 1000
		local leases = {
			alive = {
				name = "Day",
				priority = WeatherWriterPriority.Skill,
				order = 1,
				expiresAt = now + 50,
				acquiredAt = now,
				writerId = "alive",
			},
			dead = {
				name = "Night",
				priority = WeatherWriterPriority.Skill,
				order = 2,
				expiresAt = now - 1,
				acquiredAt = now - 100,
				writerId = "dead",
			},
			forever = {
				name = "Dungeon",
				priority = WeatherWriterPriority.Dungeon,
				order = 3,
				expiresAt = nil,
				acquiredAt = now - 10,
				writerId = "forever",
			},
		}
		local expired = LeaseStack.collectExpiredWriters(leases, now)
		passed, failed = _check(
			"collectExpiredWriters",
			#expired == 1 and expired[1] == "dead",
			passed,
			failed
		)

		local delay = LeaseStack.getSoonestExpireDelay(leases, now)
		passed, failed = _check("getSoonestExpireDelay", delay == 50, passed, failed)

		local noExpire = {
			x = {
				name = "X",
				priority = WeatherWriterPriority.Dungeon,
				order = 1,
				expiresAt = nil,
				acquiredAt = now,
				writerId = "x",
			},
		}
		passed, failed = _check(
			"getSoonestExpireDelay 无过期项",
			LeaseStack.getSoonestExpireDelay(noExpire, now) == nil,
			passed,
			failed
		)

		local stale = LeaseStack.collectStaleWriters(leases, now, 5, nil)
		passed, failed = _check(
			"collectStaleWriters 过久无 TTL",
			#stale == 1 and stale[1] == "forever",
			passed,
			failed
		)
		local staleSkipped = LeaseStack.collectStaleWriters(leases, now, 5, { forever = true })
		passed, failed = _check("collectStaleWriters 已告警跳过", #staleSkipped == 0, passed, failed)
		local staleDelay = LeaseStack.getSoonestStaleWarnDelay(noExpire, now, 30, nil)
		passed, failed = _check("getSoonestStaleWarnDelay", staleDelay == 30, passed, failed)

		local hardWriters = LeaseStack.collectHardMaxWriters(leases, now, 5)
		passed, failed = _check(
			"collectHardMaxWriters 过久无 TTL",
			#hardWriters == 1 and hardWriters[1] == "forever",
			passed,
			failed
		)
		local hardDisabled = LeaseStack.collectHardMaxWriters(leases, now, 0)
		passed, failed = _check("collectHardMaxWriters 关闭", #hardDisabled == 0, passed, failed)
		local hardDelay = LeaseStack.getSoonestHardMaxDelay(noExpire, now, 30)
		passed, failed = _check("getSoonestHardMaxDelay", hardDelay == 30, passed, failed)
		local hardDelayOff = LeaseStack.getSoonestHardMaxDelay(noExpire, now, 0)
		passed, failed = _check("getSoonestHardMaxDelay 关闭", hardDelayOff == nil, passed, failed)
	end

	-- 4. snapshotLeases 深拷贝 / countLeases
	do
		local leases = {
			a = {
				name = "Day",
				priority = WeatherWriterPriority.Skill,
				order = 1,
				expiresAt = 10,
				acquiredAt = 1,
				writerId = "a",
			},
		}
		local snaps = LeaseStack.snapshotLeases(leases)
		passed, failed = _check("snapshotLeases 数量", #snaps == 1, passed, failed)
		if snaps[1] then
			snaps[1].name = "Mutated"
			passed, failed = _check("snapshotLeases 深拷贝", leases.a.name == "Day", passed, failed)
			passed, failed = _check("snapshotLeases 含 acquiredAt", snaps[1].acquiredAt == 1, passed, failed)
		else
			passed, failed = _check("snapshotLeases 深拷贝", false, passed, failed)
		end
		passed, failed = _check("countLeases", LeaseStack.countLeases(leases) == 1, passed, failed)
		passed, failed = _check("countLeases 空表", LeaseStack.countLeases({}) == 0, passed, failed)
	end

	-- 5. WeatherMaxActiveLeases / StaleWarn / HardMax 配置存在且合法
	do
		local maxLeases = EnumMgr.WeatherMaxActiveLeases
		passed, failed = _check(
			"WeatherMaxActiveLeases 为正整数",
			typeof(maxLeases) == "number" and maxLeases >= 1,
			passed,
			failed
		)
		local staleWarn = EnumMgr.WeatherLeaseStaleWarnSec
		passed, failed = _check(
			"WeatherLeaseStaleWarnSec 为正数",
			typeof(staleWarn) == "number" and staleWarn > 0,
			passed,
			failed
		)
		local hardMax = EnumMgr.WeatherLeaseHardMaxSec
		passed, failed = _check(
			"WeatherLeaseHardMaxSec 为非负且 >= StaleWarn（或关闭）",
			typeof(hardMax) == "number" and hardMax >= 0 and (hardMax == 0 or hardMax >= staleWarn),
			passed,
			failed
		)
	end

	print(("[LeaseStackValidationTest] 完成：通过 %d / 失败 %d"):format(passed, failed))
	return failed == 0
end

return M
