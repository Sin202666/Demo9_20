--[[
	Module: UISetMgr/StrokeRefreshPump
	Description: UIStroke 分片刷新泵：合入待刷新宿主、写入当下计算倍率、按帧预算写 Thickness
	Author: 林奥宇
	Created: 2026-09-02
	Last Modified: 2026-09-02

	仅供同目录 StrokeAdapt require(script.Parent.StrokeRefreshPump)。业务请走 Utils.UISetMgr。

	功能：
	- Schedule 把宿主合入 pending；同帧多次只 kick 一次（task.defer）
	- 每帧只对预算内将写入的条目 computeUiScale + apply，不预刷整段剩余队列
	- 入队只记描边引用，倍率在写入当下计算（含 catchup 耗时计入本帧时间预算）
	- Parent 丢失或倍率非法不占用 RefreshPerFrame
	- 泵运行中又 Schedule：新描边追加队尾；已处理队头整队走完再补扫
	- 时间预算：本帧一开始就记 t0；while 首次迭代必测时钟，其后每 CLOCK_CHECK_INTERVAL 次再测

	加载方式（仅 StrokeAdapt）：
		local StrokeRefreshPump = require(script.Parent.StrokeRefreshPump)
		StrokeRefreshPump.SetHooks({ ... })
		StrokeRefreshPump.Schedule(host)
		StrokeRefreshPump.Stop()
]]

-- ============================================================================
-- 服务 / 模块引用
-- ============================================================================

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local RunService = Utils.RunService

-- ============================================================================
-- 模块定义
-- ============================================================================

local StrokeRefreshPump = {}

-- ============================================================================
-- 类型
-- ============================================================================

export type StrokeHost = {
	isAdaptEnabled: () -> boolean,
	strokes: { [UIStroke]: boolean },
	strokeRootsBound: { [Instance]: boolean },
	connections: { RBXScriptConnection },
	isLive: () -> boolean,
}

export type QueueItem = {
	stroke: UIStroke,
	uiScale: number,
}

export type PumpHooks = {
	isEnabled: () -> boolean,
	getRefreshPerFrame: () -> number,
	getRefreshTimeBudget: () -> number,
	computeUiScale: (UIStroke) -> number?,
	apply: (UIStroke, number) -> (),
}

-- ============================================================================
-- 常量
-- ============================================================================

local CLOCK_CHECK_INTERVAL = 32

-- ============================================================================
-- 私有变量
-- ============================================================================

local _hooks: PumpHooks? = nil
local _pendingHosts: { [{ [UIStroke]: boolean }]: StrokeHost } = {}
local _queue: { QueueItem } = {}
local _inQueue: { [UIStroke]: boolean } = {}
local _queueIndex = 1
local _catchupNeeded = false
local _replayHead = false
local _active = false
local _kickScheduled = false
local _runId = 0
local _pumpConn: RBXScriptConnection? = nil

-- ============================================================================
-- 私有函数
-- ============================================================================

--[[
	断开 Heartbeat 并清空队列 / pending（不递增 runId）
]]
local function _idle()
	_active = false
	_catchupNeeded = false
	_replayHead = false
	_queueIndex = 1
	table.clear(_pendingHosts)
	table.clear(_queue)
	table.clear(_inQueue)
	if _pumpConn then
		_pumpConn:Disconnect()
		_pumpConn = nil
	end
end

--[[
	将描边追加到队列（不算倍率，写入时再算；已在队列中则跳过）
	@param stroke UIStroke - 目标描边
]]
local function _tryAppend(stroke: UIStroke)
	if _inQueue[stroke] then
		return
	end
	_inQueue[stroke] = true
	table.insert(_queue, {
		stroke = stroke,
		uiScale = 0,
	})
end

--[[
	把 pending 里尚未入队的描边追加到队尾
]]
local function _appendPendingStrokes()
	for _, host in pairs(_pendingHosts) do
		if not host.isLive() or not host.isAdaptEnabled() then
			continue
		end
		for stroke in pairs(host.strokes) do
			if not stroke.Parent then
				host.strokes[stroke] = nil
			else
				_tryAppend(stroke)
			end
		end
	end
end

--[[
	本帧时间预算是否已用尽（首次迭代必测，其后每 CLOCK_CHECK_INTERVAL 次再测）
	@param useTime boolean - 是否启用时间预算
	@param t0 number - 本帧起始 os.clock
	@param loopCount number - 本帧 while 已迭代次数（从 1 起，含本次）
	@param timeBudget number - 秒
	@return boolean - 已超时 true
]]
local function _isTimeBudgetExceeded(useTime: boolean, t0: number, loopCount: number, timeBudget: number): boolean
	if not useTime then
		return false
	end
	if loopCount ~= 1 and loopCount % CLOCK_CHECK_INTERVAL ~= 0 then
		return false
	end
	return (os.clock() - t0) >= timeBudget
end

--[[
	由 pending 全量重建队列（空闲首次 kick；只收集引用）
]]
local function _rebuildFromPending()
	table.clear(_queue)
	table.clear(_inQueue)
	_queueIndex = 1
	_replayHead = false
	_catchupNeeded = false
	_appendPendingStrokes()
end

--[[
	处理本帧预算：先廉价入队，再对将写入的条目现算倍率并 apply（均计入时间预算）
	@return boolean - 仍有剩余工作（含待队头补扫）时 true
]]
local function _processBudget(): boolean
	local hooks = _hooks
	if not hooks or not hooks.isEnabled() then
		_idle()
		return false
	end
	local t0 = os.clock()
	_active = true
	if #_queue == 0 then
		_rebuildFromPending()
	elseif _catchupNeeded then
		_catchupNeeded = false
		_appendPendingStrokes()
	end

	local perFrame = hooks.getRefreshPerFrame()
	local timeBudget = hooks.getRefreshTimeBudget()
	local useTime = timeBudget > 0
	local n = 0
	local loopCount = 0

	while n < perFrame do
		loopCount += 1
		if _isTimeBudgetExceeded(useTime, t0, loopCount, timeBudget) then
			break
		end
		if _queueIndex > #_queue then
			if _replayHead and #_queue > 0 then
				_replayHead = false
				_queueIndex = 1
			else
				break
			end
		end
		if _queueIndex > #_queue then
			break
		end
		local item = _queue[_queueIndex]
		_queueIndex += 1
		if not item.stroke.Parent then
			continue
		end
		local uiScale = hooks.computeUiScale(item.stroke)
		if typeof(uiScale) ~= "number" or uiScale <= 0 then
			continue
		end
		item.uiScale = uiScale
		hooks.apply(item.stroke, uiScale)
		n += 1
	end

	return _queueIndex <= #_queue or _replayHead or _catchupNeeded
end

--[[
	Heartbeat：继续分片；完成后 idle
]]
local function _onHeartbeat()
	local hooks = _hooks
	if not hooks or not hooks.isEnabled() then
		StrokeRefreshPump.Stop()
		return
	end
	if _processBudget() then
		return
	end
	_idle()
end

--[[
	同帧多次 Schedule 合并为一次 defer，首块在 defer 里跑，剩余走 Heartbeat
]]
local function _ensureKick()
	if _kickScheduled then
		return
	end
	_kickScheduled = true
	local runId = _runId
	task.defer(function()
		if runId ~= _runId then
			return
		end
		_kickScheduled = false
		local hooks = _hooks
		if not hooks or not hooks.isEnabled() then
			StrokeRefreshPump.Stop()
			return
		end
		if _processBudget() then
			if not _pumpConn then
				_pumpConn = RunService.Heartbeat:Connect(_onHeartbeat)
			end
			return
		end
		_idle()
	end)
end

-- ============================================================================
-- 公共函数（仅 StrokeAdapt）
-- ============================================================================

--[[
	注入计算与写入回调（StrokeAdapt 加载末尾调用一次）
	@param hooks PumpHooks - isEnabled / 预算 / computeUiScale / apply
]]
function StrokeRefreshPump.SetHooks(hooks: PumpHooks)
	_hooks = hooks
end

--[[
	将宿主合入分片队列；泵运行中新描边追加队尾，已入队条目在写入当下再算倍率
	@param host StrokeHost - 注册项描边宿主
]]
function StrokeRefreshPump.Schedule(host: StrokeHost)
	local hooks = _hooks
	if not hooks or not hooks.isEnabled() then
		return
	end
	if not host.isAdaptEnabled() then
		return
	end
	_pendingHosts[host.strokes] = host
	if _active and #_queue > 0 then
		_catchupNeeded = true
		if _queueIndex > 1 then
			_replayHead = true
		end
	end
	_ensureKick()
end

--[[
	停止泵并丢弃队列（无注册项或总开关关闭）
]]
function StrokeRefreshPump.Stop()
	_runId += 1
	_kickScheduled = false
	_idle()
end

return StrokeRefreshPump
