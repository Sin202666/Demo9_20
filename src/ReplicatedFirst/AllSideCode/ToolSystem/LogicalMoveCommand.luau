--[[
	Module: LogicalMoveCommand
	Description: 逻辑怪移动命令层（Auto / ScriptGoal / ScriptDir / Pause）；独占 setGoal
	Author: 林奥宇
	Created: 2026-08-28
	Last Modified: 2026-09-01

	功能：
	- setMode：写入 _driveMode 与 payload；供 SystemEnemy 五 API 转入
	- tick：ScriptGoal 到达或超时回 Auto；ScriptDir 每帧写前瞻 _desiredPos 并倒数
	- applyDesired：非 Pause 且有 _desiredPos 时 setGoal(_pathSteerPos 或 desired)；否则 clearGoal（不清 desired）
	- shouldSkipAi / getMode：EnemySim 跳过 Ranger、关卡读模式

	与相关模块：
	- 关卡只打 SystemEnemy.PauseMoveAi / ResumeMoveAi / SetMoveGoal / SetMoveDir / GetMoveDriveMode
	- RangerAi 只写 _desiredPos / _desiredLook，禁止 setGoal / clearGoal / setCFrame
	- LogicEntityMotion.integrate 只读 _logicalGoal（含 M0 _stuckSteerPos）
	- 受击锁：EnemySim 不调用 tick / apply；保留 _driveMode 与 _desiredPos
	- M2 PathFollow 插在 tick/Ranger 之后、apply 之前；有 _pathSteerPos 则积分路点，否则直线

	模式语义（审评 D11–D14）：
	- Auto：Ranger（若有）写 desired → apply → integrate
	- ScriptGoal：跳过 Ranger；走到点或 timeoutSec 到期回 Auto；缺省 timeout 则一直走
	- ScriptDir：跳过 Ranger；按方向走 durationSec 后回 Auto
	- Pause：跳过 Ranger；apply 清积分点但保留 _desiredPos 供 Resume
	- SetMoveGoal 到达是回 Auto，不是 Resume；覆盖前 Chase 则到点后仍可能 Chase

	加载：
		local LogicalMoveCommand = Utils.LogicalMoveCommand
		LogicalMoveCommand.setMode(rec, EnumMgr.LogicalDriveMode.Pause)
		LogicalMoveCommand.tick(rec, dt)
		LogicalMoveCommand.applyDesired(rec)
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local LogicEntityMotion = Utils.LogicEntityMotion
local EnumMgr = Utils.EnumMgr

local LogicalMoveCommand = {}

local DriveMode = EnumMgr.LogicalDriveMode
local MODE_AUTO = DriveMode.Auto
local MODE_SCRIPT_GOAL = DriveMode.ScriptGoal
local MODE_SCRIPT_DIR = DriveMode.ScriptDir
local MODE_PAUSE = DriveMode.Pause

local DEFAULT_ARRIVE_EPS = 0.35
local SCRIPT_DIR_LOOKAHEAD = 3
local DEFAULT_WALK_SPEED = 8

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
	压成水平单位方向；退化返回 nil
	@param v Vector3 - 原始方向
	@return Vector3? - 平面单位向量
]]
local function _flatDir(v: Vector3): Vector3?
	local flat = Vector3.new(v.X, 0, v.Z)
	if flat.Magnitude < 1e-4 then
		return nil
	end
	return flat.Unit
end

--[[
	保证 rec.entity 为表（无 Ranger 时命令仍可走点）
	@param rec any - LogicalRecord
	@return any? - entity；rec 非法则 nil
]]
local function _ensureEntity(rec: any): any?
	if type(rec) ~= "table" then
		return nil
	end
	local entity = rec.entity
	if type(entity) ~= "table" then
		entity = {
			moveState = "idle",
			walkSpeed = DEFAULT_WALK_SPEED,
			_driveMode = MODE_AUTO,
		}
		rec.entity = entity
	end
	return entity
end

--[[
	当前驱动模式（缺省 Auto）
	@param entity any - AI / 命令态
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
	回 Auto；clearDesired 时丢掉脚本点，让 Ranger 重写；同时清 _pathWanted（D19）
	@param entity any - 命令态
	@param clearDesired boolean - true 清 _desiredPos / _desiredDir
]]
local function _enterAuto(entity: any, clearDesired: boolean)
	entity._driveMode = MODE_AUTO
	entity._commandTimeout = nil
	entity._commandArriveEps = nil
	entity._desiredDir = nil
	entity._pathWanted = nil
	if clearDesired then
		entity._desiredPos = nil
	end
end

--[[
	解析到达半径
	@param raw any - opts.arriveEps
	@return number - >0 的半径
]]
local function _arriveEps(raw: any): number
	local n = tonumber(raw)
	if n and n > 0 then
		return n
	end
	return DEFAULT_ARRIVE_EPS
end

--[[
	写入驱动模式
	@param rec any - LogicalRecord
	@param mode string - Auto / ScriptGoal / ScriptDir / Pause
	@param payload any? - ScriptGoal: { pos: Vector3, timeoutSec: number?, arriveEps: number?, usePath: boolean? }；ScriptDir: { dir: Vector3, durationSec: number }
	@return boolean - 是否接受
]]
function LogicalMoveCommand.setMode(rec: any, mode: string, payload: any?): boolean
	local entity = _ensureEntity(rec)
	if not entity then
		return false
	end
	if mode == MODE_PAUSE then
		entity._driveMode = MODE_PAUSE
		entity._commandTimeout = nil
		entity._commandArriveEps = nil
		entity._desiredDir = nil
		-- 保留 _desiredPos，Resume 后 Wander/Chase 可续
		return true
	end
	if mode == MODE_AUTO then
		_enterAuto(entity, false)
		return true
	end
	if mode == MODE_SCRIPT_GOAL then
		if type(payload) ~= "table" or typeof(payload.pos) ~= "Vector3" then
			return false
		end
		entity._driveMode = MODE_SCRIPT_GOAL
		entity._desiredPos = payload.pos
		entity._desiredDir = nil
		local timeout = tonumber(payload.timeoutSec)
		if timeout and timeout > 0 then
			entity._commandTimeout = timeout
		else
			entity._commandTimeout = nil
		end
		entity._commandArriveEps = _arriveEps(payload.arriveEps)
		if payload.usePath == false then
			entity._pathWanted = false
		elseif payload.usePath == true then
			entity._pathWanted = true
		else
			entity._pathWanted = nil
		end
		return true
	end
	if mode == MODE_SCRIPT_DIR then
		if type(payload) ~= "table" then
			return false
		end
		local dir = typeof(payload.dir) == "Vector3" and _flatDir(payload.dir) or nil
		local duration = tonumber(payload.durationSec)
		if not dir or not duration or duration <= 0 then
			return false
		end
		entity._driveMode = MODE_SCRIPT_DIR
		entity._desiredDir = dir
		entity._commandTimeout = duration
		entity._commandArriveEps = nil
		return true
	end
	return false
end

--[[
	推进超时与 ScriptDir 前瞻点；锁窗内不要调用
	@param rec any - LogicalRecord
	@param dt number - 帧间隔秒
]]
function LogicalMoveCommand.tick(rec: any, dt: number)
	local entity = rec and rec.entity
	if type(entity) ~= "table" then
		return
	end
	local dtClamped = math.clamp(tonumber(dt) or 0, 0, 0.1)
	if dtClamped <= 0 then
		return
	end
	local mode = _readMode(entity)
	if mode == MODE_PAUSE or mode == MODE_AUTO then
		return
	end

	if mode == MODE_SCRIPT_DIR then
		local dir = entity._desiredDir
		if typeof(dir) ~= "Vector3" then
			_enterAuto(entity, true)
			return
		end
		local flat = _flatDir(dir)
		if not flat then
			_enterAuto(entity, true)
			return
		end
		entity._desiredDir = flat
		local pos = rec.cframe and rec.cframe.Position
		if typeof(pos) == "Vector3" then
			entity._desiredPos = pos + flat * SCRIPT_DIR_LOOKAHEAD
		end
		local remain = tonumber(entity._commandTimeout)
		if remain then
			remain -= dtClamped
			entity._commandTimeout = remain
			if remain <= 0 then
				_enterAuto(entity, true)
			end
		end
		return
	end

	-- ScriptGoal：无 desired 视为已由 Motion 到达；有点则按 arriveEps / timeout
	if typeof(entity._desiredPos) ~= "Vector3" then
		_enterAuto(entity, true)
		return
	end
	local remain = tonumber(entity._commandTimeout)
	if remain then
		remain -= dtClamped
		entity._commandTimeout = remain
		if remain <= 0 then
			_enterAuto(entity, true)
			return
		end
	end
	local pos = rec.cframe and rec.cframe.Position
	if typeof(pos) == "Vector3" then
		local eps = tonumber(entity._commandArriveEps) or DEFAULT_ARRIVE_EPS
		if _distFlat(pos, entity._desiredPos) <= eps then
			_enterAuto(entity, true)
		end
	end
end

--[[
	把路点或 _desiredPos 落到本帧积分点；Pause / 无点则只清 _logicalGoal
	有 _pathSteerPos 时优先（PathFollow 禁止自己 setGoal）
	@param rec any - LogicalRecord
]]
function LogicalMoveCommand.applyDesired(rec: any)
	local entity = rec and rec.entity
	if type(entity) ~= "table" then
		return
	end
	if _readMode(entity) == MODE_PAUSE then
		LogicEntityMotion.clearGoal(entity)
		return
	end
	local desired = entity._desiredPos
	if typeof(desired) ~= "Vector3" then
		LogicEntityMotion.clearGoal(entity)
		return
	end
	local steer = entity._pathSteerPos
	if typeof(steer) == "Vector3" then
		LogicEntityMotion.setGoal(entity, steer)
		return
	end
	LogicEntityMotion.setGoal(entity, desired)
end

--[[
	非 Auto 时跳过 Ranger（计时与索敌冻结）
	@param rec any - LogicalRecord
	@return boolean - true 跳过 AI
]]
function LogicalMoveCommand.shouldSkipAi(rec: any): boolean
	local entity = rec and rec.entity
	if type(entity) ~= "table" then
		return false
	end
	return _readMode(entity) ~= MODE_AUTO
end

--[[
	当前模式（无 entity 视为 Auto）
	@param rec any - LogicalRecord
	@return string - Auto / ScriptGoal / ScriptDir / Pause
]]
function LogicalMoveCommand.getMode(rec: any): string
	local entity = rec and rec.entity
	if type(entity) ~= "table" then
		return MODE_AUTO
	end
	return _readMode(entity)
end

return LogicalMoveCommand
