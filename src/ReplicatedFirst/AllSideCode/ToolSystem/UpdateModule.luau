--!strict
--[[
	Module: UpdateModule
	Description: 服务端定时更新调度——单一 Heartbeat 驱动的注册式任务循环
	Author: 林奥宇
	Created: 2026-07-01
	Last Modified: 2026-09-01

	功能：
	- 单一 Heartbeat 驱动所有已注册间隔任务，替代各模块独立 while/task.wait 轮询
	- Register：业务 System 在 require 时登记间隔与回调
	- Start：UpdateManager 预加载完成后启动循环（重复调用幂等）
	- INTERVAL：预置间隔常量（已 freeze，勿改字段）

	与相关模块：
	- 服务端编排入口是 UpdateManager：预加载会 Register 的 System，再调用 Start()
	- 业务 System（SystemBUFF / SystemSave / SystemRank 等）只 Register，不自己绑 Heartbeat
	- 客户端不要用本模块做定时；Register / Start 仅服务端生效，客户端调用会 Log.warn 并忽略
	  （例如排行榜刷新应在客户端自建循环，或走已有客户端 Manager）

	预置间隔（UpdateModule.INTERVAL）：
	- FAST = 0.1    HALF = 0.5    SEC = 1
	- SEC_30 = 30   SEC_120 = 120  SEC_300 = 300

	RegisterOptions：
	- initialElapsed  number?  初始已累计时间（秒），默认 0；用于错峰，避免同间隔任务同帧扎堆
	- spawn           boolean? 是否在 task.spawn 中执行回调，默认 false；耗时或可能 yield 的逻辑应设 true

	端侧 / 调用约束：
	- 仅服务端：Register / Start 在客户端无效
	- 不在 Init() 里 Register——属于模块加载期行为；Init 只绑事件
	- 新增注册方须加入 UpdateManager 预加载，保证 Start() 前完成登记
	- 无 Unregister / Stop：任务与 Heartbeat 随服务器会话常驻
	- 单帧只触发一次：elapsed 达到 interval 后减去一个 interval 并回调；卡顿余量留到后续帧补触发

	加载方式：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local UpdateModule = Utils.UpdateModule

	使用示例：
		-- System 模块末尾注册（优先 INTERVAL，避免魔法数字）
		local UpdateModule = Utils.UpdateModule
		UpdateModule.Register(UpdateModule.INTERVAL.SEC, function(elapsed: number)
			module.UpdateBuff(elapsed)
		end)

		-- 耗时任务：协程执行 + 错峰首次触发
		UpdateModule.Register(UpdateModule.INTERVAL.SEC_120, function(_elapsed: number)
			module.UploadData()
		end, { spawn = true, initialElapsed = UpdateModule.INTERVAL.SEC_120 })

		-- UpdateManager 中
		local _SystemBUFF = Utils.SystemBUFF
		UpdateModule.Start()
]]

-- ============================================================================
-- 服务引用 / 模块引用
-- ============================================================================

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local RunService = Utils.RunService
local Log = Utils.Log

-- ============================================================================
-- 模块定义
-- ============================================================================

local UpdateModule = {}

-- ============================================================================
-- 类型
-- ============================================================================

export type UpdateCallback = (elapsed: number) -> ()

export type RegisterOptions = {
	-- 初始已累计时间，用于错峰触发（秒）；缺省 0
	initialElapsed: number?,
	-- 是否在独立协程中执行回调；缺省 false
	spawn: boolean?,
}

type UpdateEntry = {
	interval: number,
	elapsed: number,
	callback: UpdateCallback,
	spawn: boolean,
}

-- ============================================================================
-- 常量
-- ============================================================================

local INTERVAL = table.freeze({
	FAST = 0.1,
	HALF = 0.5,
	SEC = 1,
	SEC_30 = 30,
	SEC_120 = 120,
	SEC_300 = 300,
})

UpdateModule.INTERVAL = INTERVAL

-- ============================================================================
-- 私有变量
-- ============================================================================

local _entries: { UpdateEntry } = {}
local _heartbeatConnection: RBXScriptConnection? = nil
local _isServer = RunService:IsServer()

-- ============================================================================
-- 私有函数
-- ============================================================================

--[[
	校验注册参数（端侧、间隔、回调类型）
	@param interval number - 触发间隔（秒），须为正数
	@param callback UpdateCallback - 到期回调
	@return boolean - 服务端且参数合法时 true；否则已 Log.warn 并 false
]]
local function _validateRegisterArgs(interval: number, callback: UpdateCallback): boolean
	if not _isServer then
		Log.warn("[UpdateModule] Register 仅可在服务端调用")
		return false
	end

	if type(interval) ~= "number" or interval <= 0 then
		Log.warn("[UpdateModule] interval 必须为正数:", interval)
		return false
	end

	if type(callback) ~= "function" then
		Log.warn("[UpdateModule] callback 必须为 function")
		return false
	end

	return true
end

--[[
	pcall 执行任务回调，失败只记日志不中断调度
	@param callback UpdateCallback - 已注册回调
	@param elapsed number - 本次触发时累计的帧时间（秒）
]]
local function _runCallback(callback: UpdateCallback, elapsed: number)
	local ok, err = pcall(callback, elapsed)
	if not ok then
		Log.warn("[UpdateModule] callback 执行失败:", err)
	end
end

--[[
	按 entry.spawn 选择同步或协程执行回调
	@param entry UpdateEntry - 已注册任务项（含 callback / spawn）
	@param elapsed number - 本次触发的累计时间（秒），含超间隔余量
]]
local function _invokeEntryCallback(entry: UpdateEntry, elapsed: number)
	if entry.spawn then
		task.spawn(_runCallback, entry.callback, elapsed)
	else
		_runCallback(entry.callback, elapsed)
	end
end

--[[
	Heartbeat 驱动所有已注册任务；单帧每条最多触发一次
	@param dt number - 本帧间隔（秒）
]]
local function _onHeartbeat(dt: number)
	for _, entry in _entries do
		entry.elapsed += dt

		if entry.elapsed >= entry.interval then
			local elapsed = entry.elapsed
			entry.elapsed -= entry.interval
			_invokeEntryCallback(entry, elapsed)
		end
	end
end

-- ============================================================================
-- 公共 API
-- ============================================================================

--[[
	注册定时更新任务。仅服务端生效；客户端与非法参数会 Log.warn 并忽略。
	须在 UpdateManager.Start 之前完成（通常写在 System 文件末尾）。无卸载接口。

	@param interval number - 触发间隔（秒），须 > 0；优先传 INTERVAL 常量
	@param callback UpdateCallback - 到期回调；参数 elapsed 为自上次触发以来累计秒数
	@param options RegisterOptions? - 可选：initialElapsed（默认 0，错峰用）、spawn（默认 false）
	@return () - 无返回值；失败时静默 return
]]
function UpdateModule.Register(interval: number, callback: UpdateCallback, options: RegisterOptions?)
	if not _validateRegisterArgs(interval, callback) then
		return
	end

	local initialElapsed = 0
	local useSpawn = false

	if options then
		if options.initialElapsed ~= nil then
			if type(options.initialElapsed) ~= "number" or options.initialElapsed < 0 then
				Log.warn("[UpdateModule] initialElapsed 必须为非负数:", options.initialElapsed)
				return
			end
			initialElapsed = options.initialElapsed
		end
		if options.spawn ~= nil then
			if type(options.spawn) ~= "boolean" then
				Log.warn("[UpdateModule] spawn 必须为 boolean:", options.spawn)
				return
			end
			useSpawn = options.spawn
		end
	end

	table.insert(_entries, {
		interval = interval,
		elapsed = initialElapsed,
		callback = callback,
		spawn = useSpawn,
	})
end

--[[
	启动 Heartbeat 主循环。仅 UpdateManager 在预加载完注册方后调用。
	非服务端 Log.warn 后 return；已启动则幂等 return。会话期内不提供 Stop。

	@return () - 无返回值
]]
function UpdateModule.Start()
	if not _isServer then
		Log.warn("[UpdateModule] Start 仅可在服务端调用")
		return
	end

	if _heartbeatConnection then
		return
	end

	_heartbeatConnection = RunService.Heartbeat:Connect(_onHeartbeat)
end

return UpdateModule
