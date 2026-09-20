--[[
	Module: LogicalPathFollow
	Description: 逻辑怪路点跟随（配额 Compute + _pathSteerPos）；禁止 setGoal
	Author: 林奥宇
	Created: 2026-08-28
	Last Modified: 2026-09-01

	功能：
	- tick：按 desired 推进路点、写 _pathSteerPos、按需入队；Pause / ScriptDir / 直线可达则清空 steer
	- flushCompute：EnemySim 实体循环之后调用一次；每帧最多 N 次 task.spawn ComputeAsync
	- invalidate：卡住 / 模式切换 / Despawn；_pathGen++ 并丢掉队列里同 id 任务
	- getDebug / getStats：路点与配额观察（深拷贝；T5 看每秒 Compute）

	与相关模块：
	- 只写 _pathSteerPos / _path / _pathGen 等；禁止 LogicEntityMotion.setGoal（D11 / D19）
	- applyDesired 有 steer 则 setGoal(steer)，否则 desired 直线
	- Motion 到积分点不清 desired；Follow 距路点 ≤ 2 stud 推进（D17）
	- Ranger / Command 只写 _desiredPos；本模块不改模式

	谁寻路（D19）：
	- Pause / ScriptDir：不入队
	- Auto：寻路启用
	- ScriptGoal：寻路启用且 _pathWanted ~= false
	- 无路径 / PathStatus 失败：steer 空，直线 + M0；backoff 1s

	加载：
		local LogicalPathFollow = Utils.LogicalPathFollow
		LogicalPathFollow.tick(rec, dt)
		LogicalPathFollow.flushCompute()
		LogicalPathFollow.invalidate(rec)
]]

local Workspace = game:GetService("Workspace")

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local PathFindUtil = Utils.PathFindUtil
local EnemyLogicalStore = Utils.EnemyLogicalStore
local SystemGameConfig = Utils.SystemGameConfig
local Copy = Utils.Copy
local Log = Utils.Log
local EnumMgr = Utils.EnumMgr

local LogicalPathFollow = {}

--============================================================================--
-- 常量
--============================================================================--

local DriveMode = EnumMgr.LogicalDriveMode
local MODE_AUTO = DriveMode.Auto
local MODE_SCRIPT_GOAL = DriveMode.ScriptGoal
local MODE_SCRIPT_DIR = DriveMode.ScriptDir
local MODE_PAUSE = DriveMode.Pause

local REPATH_DEST_EPS = 6
local PATH_MAX_AGE = 4.5
local PATH_FAIL_BACKOFF = 1.0
local WAYPOINT_ARRIVE = 2
local DEFAULT_QUOTA = 3
local MAX_QUOTA = 8
local DEFAULT_BBOX = Vector3.new(4, 5, 4)

export type PathFollowDebug = {
	waypointCount: number,
	pathIndex: number?,
	pending: boolean,
	lastStatus: string?,
	gen: number?,
	hasSteer: boolean,
}

export type PathFollowStats = {
	queued: number,
	computesLastSec: number,
}

--============================================================================--
-- 私有：队列 / 模式
--============================================================================--

type ComputeJob = {
	recId: number,
	dest: Vector3,
	gen: number,
	start: Vector3,
	agentParams: any,
}

local _queue: { ComputeJob } = {}
local _computesWindow = 0
local _computesWindowAt = 0
local _computesLastSec = 0

--[[
	平面 XZ 距离
	@param a Vector3 - 点 A
	@param b Vector3 - 点 B
	@return number - 平面距
]]
local function _distFlat(a: Vector3, b: Vector3): number
	local dx = a.X - b.X
	local dz = a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

--[[
	当前驱动模式（缺省 Auto；取值与 EnumMgr.LogicalDriveMode 对齐）
	@param entity any - 命令 / AI 态
	@return string - Auto / ScriptGoal / ScriptDir / Pause
]]
local function _readMode(entity: any): string
	local mode = entity and entity._driveMode
	if mode == MODE_SCRIPT_GOAL or mode == MODE_SCRIPT_DIR or mode == MODE_PAUSE then
		return mode
	end
	return MODE_AUTO
end

--[[
	全局寻路闸
	@return boolean - GameConfig 寻路启用 ~= false
]]
local function _isPathEnabled(): boolean
	return SystemGameConfig.GetValue({ "怪物系统", "寻路启用" }) ~= false
end

--[[
	本帧是否允许为该怪请求 / 跟随 Path
	@param entity any - 命令态
	@return boolean - true 才寻路
]]
local function _shouldPath(entity: any): boolean
	if not _isPathEnabled() then
		return false
	end
	local mode = _readMode(entity)
	if mode == MODE_PAUSE or mode == MODE_SCRIPT_DIR then
		return false
	end
	if mode == MODE_SCRIPT_GOAL and entity._pathWanted == false then
		return false
	end
	return true
end

--[[
	直线可达启发式是否开启（距离键 >0 启用，不再当强制 Path 门槛）
	@return boolean
]]
local function _isDirectSkipEnabled(): boolean
	local v = SystemGameConfig.GetValue({ "怪物系统", "直线可达跳过寻路距离" })
	if type(v) ~= "number" then
		return true
	end
	return v > 0
end

--[[
	本帧 Compute 配额
	@return number - [0, 8]
]]
local function _getQuota(): number
	local v = SystemGameConfig.GetValue({ "怪物系统", "寻路每帧计算数" })
	if type(v) ~= "number" then
		return DEFAULT_QUOTA
	end
	return math.clamp(math.floor(v), 0, MAX_QUOTA)
end

--[[
	从队列去掉该 id 的待算任务（invalidate 时调用）
	@param recId number - 运行时 id
]]
local function _dropQueuedForId(recId: number)
	local i = 1
	while i <= #_queue do
		if _queue[i].recId == recId then
			table.remove(_queue, i)
		else
			i += 1
		end
	end
end

--[[
	丢掉路点 / steer / pending，并增加代数
	@param rec any - LogicalRecord（至少含 id / entity）
]]
local function _invalidateEntity(rec: any)
	local entity = rec.entity
	if type(entity) ~= "table" then
		return
	end
	entity._pathGen = (tonumber(entity._pathGen) or 0) + 1
	entity._path = nil
	entity._pathIndex = nil
	entity._pathSteerPos = nil
	entity._pathDest = nil
	entity._pathAt = nil
	entity._pathPending = nil
	entity._pathPendingGen = nil
	local recId = tonumber(rec.id)
	if recId then
		_dropQueuedForId(recId)
	end
end

--[[
	停止跟路：有缓存则 invalidate，否则只清 steer
	@param rec any - LogicalRecord
	@param entity any - AI 态
]]
local function _stopFollowing(rec: any, entity: any)
	if entity._path or entity._pathSteerPos or entity._pathPending then
		_invalidateEntity(rec)
	else
		entity._pathSteerPos = nil
	end
end

--[[
	推进路点并写入 _pathSteerPos；已过终局附近则清空 steer
	@param entity any - AI 态
	@param pos Vector3 - 当前权威中心
	@param desired Vector3 - 最终目标
]]
local function _advanceAndSteer(entity: any, pos: Vector3, desired: Vector3)
	local points = entity._path
	if type(points) ~= "table" or #points == 0 then
		entity._pathSteerPos = nil
		return
	end
	local idx = tonumber(entity._pathIndex) or 1
	if idx < 1 then
		idx = 1
	end
	while idx <= #points do
		local wp = points[idx]
		if typeof(wp) ~= "Vector3" then
			idx += 1
			continue
		end
		if _distFlat(pos, wp) <= WAYPOINT_ARRIVE then
			idx += 1
		else
			break
		end
	end
	entity._pathIndex = idx
	if idx > #points then
		entity._path = nil
		entity._pathIndex = nil
		entity._pathSteerPos = nil
		return
	end
	local wp = points[idx]
	if typeof(wp) ~= "Vector3" then
		entity._pathSteerPos = nil
		return
	end
	if idx == #points and _distFlat(wp, desired) <= WAYPOINT_ARRIVE then
		entity._pathSteerPos = nil
		return
	end
	entity._pathSteerPos = wp
end

--[[
	入队一次 Compute（已 pending 或 backoff 内则跳过）
	@param rec any - LogicalRecord
	@param entity any - AI 态
	@param dest Vector3 - 最终目标
]]
local function _tryEnqueue(rec: any, entity: any, dest: Vector3)
	if entity._pathPending then
		return
	end
	local failUntil = tonumber(entity._pathFailUntil)
	if failUntil and Workspace:GetServerTimeNow() < failUntil then
		return
	end
	local recId = tonumber(rec.id)
	local start = rec.cframe and rec.cframe.Position
	if not recId or typeof(start) ~= "Vector3" then
		return
	end
	local gen = tonumber(entity._pathGen) or 0
	entity._pathGen = gen
	entity._pathPending = true
	entity._pathPendingGen = gen
	local bbox = rec.bboxSize
	if typeof(bbox) ~= "Vector3" then
		bbox = DEFAULT_BBOX
	end
	table.insert(_queue, {
		recId = recId,
		dest = dest,
		gen = gen,
		start = start,
		agentParams = PathFindUtil.agentParamsFromBBox(bbox),
	})
end

--[[
	Compute 回调：代数匹配才写路点
	@param job ComputeJob - 投递快照
	@param status Enum.PathStatus - 引擎状态
	@param points { Vector3 }? - 路点
]]
local function _onComputeDone(job: ComputeJob, status: Enum.PathStatus, points: { Vector3 }?)
	local rec = EnemyLogicalStore.get(job.recId)
	if not rec or not rec.alive then
		return
	end
	local entity = rec.entity
	if type(entity) ~= "table" then
		return
	end
	if entity._pathPendingGen == job.gen then
		entity._pathPending = nil
		entity._pathPendingGen = nil
	end
	if (tonumber(entity._pathGen) or 0) ~= job.gen then
		return
	end
	if status ~= Enum.PathStatus.Success or type(points) ~= "table" or #points == 0 then
		entity._path = nil
		entity._pathIndex = nil
		entity._pathSteerPos = nil
		entity._pathStatus = tostring(status)
		entity._pathFailUntil = Workspace:GetServerTimeNow() + PATH_FAIL_BACKOFF
		return
	end
	entity._path = points
	entity._pathIndex = 1
	entity._pathDest = job.dest
	entity._pathAt = Workspace:GetServerTimeNow()
	entity._pathStatus = "Success"
	entity._pathFailUntil = nil
end

--============================================================================--
-- 公共 API
--============================================================================--

--[[
	丢弃路点缓存并作废进行中的 Compute
	@param rec any - LogicalRecord
]]
function LogicalPathFollow.invalidate(rec: any)
	if type(rec) ~= "table" then
		return
	end
	_invalidateEntity(rec)
end

--[[
	观察用快照（深拷贝；不含路点坐标以免误改缓存）
	@param rec any - LogicalRecord
	@return PathFollowDebug - waypointCount / pathIndex / pending / lastStatus / gen / hasSteer
]]
function LogicalPathFollow.getDebug(rec: any): PathFollowDebug
	local entity = rec and rec.entity
	if type(entity) ~= "table" then
		return Copy.deepCopy({
			waypointCount = 0,
			pending = false,
		})
	end
	local path = entity._path
	return Copy.deepCopy({
		waypointCount = if type(path) == "table" then #path else 0,
		pathIndex = entity._pathIndex,
		pending = entity._pathPending == true,
		lastStatus = entity._pathStatus,
		gen = entity._pathGen,
		hasSteer = typeof(entity._pathSteerPos) == "Vector3",
	})
end

--[[
	全局配额观察
	@return PathFollowStats - queued / computesLastSec（深拷贝）
]]
function LogicalPathFollow.getStats(): PathFollowStats
	return Copy.deepCopy({
		queued = #_queue,
		computesLastSec = _computesLastSec,
	})
end

--[[
	跟路点 / 入队。禁止在此 yield 或调用 PathFindUtil.compute。
	@param rec any - LogicalRecord
	@param _dt number - 帧间隔（本模块不积分，保留签名）
]]
function LogicalPathFollow.tick(rec: any, _dt: number)
	if type(rec) ~= "table" or not rec.alive then
		return
	end
	local entity = rec.entity
	if type(entity) ~= "table" then
		return
	end
	local pos = rec.cframe and rec.cframe.Position
	if typeof(pos) ~= "Vector3" then
		return
	end

	local mode = _readMode(entity)
	if entity._pathFollowMode ~= mode then
		entity._pathFollowMode = mode
		_invalidateEntity(rec)
	end

	if not _shouldPath(entity) then
		_stopFollowing(rec, entity)
		return
	end

	local desired = entity._desiredPos
	if typeof(desired) ~= "Vector3" then
		_stopFollowing(rec, entity)
		return
	end

	if _isDirectSkipEnabled() and PathFindUtil.isDirectClear(pos, desired) then
		_stopFollowing(rec, entity)
		return
	end

	if entity._needRepath then
		_invalidateEntity(rec)
		entity._needRepath = nil
	end

	local now = Workspace:GetServerTimeNow()
	local lastDest = entity._pathDest
	local destMoved = typeof(lastDest) == "Vector3" and _distFlat(lastDest, desired) > REPATH_DEST_EPS
	local aged = type(entity._pathAt) == "number" and (now - entity._pathAt) > PATH_MAX_AGE
	if destMoved or aged then
		_invalidateEntity(rec)
	end

	if type(entity._path) == "table" and #entity._path > 0 then
		_advanceAndSteer(entity, pos, desired)
		return
	end

	_tryEnqueue(rec, entity, desired)
end

--[[
	弹出并 spawn 本帧配额内的 ComputeAsync（只在 EnemySim.step 循环后调用一次）
]]
function LogicalPathFollow.flushCompute()
	local nowClock = os.clock()
	if _computesWindowAt <= 0 then
		_computesWindowAt = nowClock
	elseif nowClock - _computesWindowAt >= 1 then
		_computesLastSec = _computesWindow
		if _computesLastSec > 0 then
			Log.print("[LogicalPathFollow] Compute/s=", _computesLastSec, " queued=", #_queue)
		end
		_computesWindow = 0
		_computesWindowAt = nowClock
	end

	local quota = _getQuota()
	while quota > 0 and #_queue > 0 do
		local job = table.remove(_queue, 1)
		local rec = EnemyLogicalStore.get(job.recId)
		if rec and rec.alive and type(rec.entity) == "table" then
			quota -= 1
			_computesWindow += 1
			task.spawn(function()
				local status, points = PathFindUtil.compute(job.start, job.dest, job.agentParams)
				_onComputeDone(job, status, points)
			end)
		end
	end
end

return LogicalPathFollow
