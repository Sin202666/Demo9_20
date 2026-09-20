--[[
	Module: LogicEntityMotion
	Description: 逻辑怪平面位移积分 + 服射线贴地/挡墙（无 Humanoid；M0 沿墙滑移；写回 EnemyLogicalStore.cframe）
	Author: 林奥宇
	Created: 2026-08-12
	Last Modified: 2026-09-01

	功能：
	- setGoal / clearGoal：写入实体 _logicalGoal；clear 时 moveState=idle 并清卡住态；击退硬锁时 setGoal 忽略
	- integrate：水平逼近目标 → 挡墙截断或切向滑移 → 下打 Ray 贴地 → Store.setCFrame；无 goal 时消费 _desiredLook
	- 贴墙不再无条件 clearGoal；到 _logicalGoal 只 clearGoal；仅平面距 _desiredPos ≤ ARRIVE_EPS 才清 desired（D17）
	- 连续多帧步长≈0：交替侧偏置临时积分点（_stuckSteerPos）；M2 可读 _needRepath
	- snapGroundY / clampStepByWall：供 Create 出生预贴地、LogicalDisplace / LogicalAirborne 复用
	- clampStepByWall 仍是「硬截断」；受击路径不要走滑移

	与相关模块：
	- RangerAi：只写 _desiredPos / _desiredLook；本模块禁止被 Ranger 直接 setGoal / setCFrame
	- LogicalMoveCommand.applyDesired：独占 setGoal（优先 _pathSteerPos）；Pause 时 clearGoal 但保留 _desiredPos
	- integrate：有 _logicalGoal 时位移朝向=前进方向；无 goal 时消费 _desiredLook 原地转朝向
	- LogicalDisplace / LogicalAirborne：继续调用 clampStepByWall，被墙挡住即停
	- EnemySim：Airborne / Displace / 移动锁之后才 integrate
	- M2 PathFollow 把路点交给 applyDesired，不在本模块读 _desiredPos

	卡住参数（模块常量；「卡住帧数」可被 GameConfig.怪物系统 覆盖）：
	- STUCK_FRAMES_DEFAULT=30（约 0.5s @ Heartbeat）
	- 改向后临时点保持 STUCK_STEER_HOLD_SEC=0.75s，避免 Ranger 节流把点立刻写回

	约束：
	- 仅服务端仿真层使用；不驱动 Instance（权威仍纯数据，对齐 I1 / I7=A）
	- 射线过滤用 RayCast 预设 "Ground"（Include workspace.场景，IgnoreWater）
	- 站高/半宽来自 rec.bboxSize（无服 HRP）；entity.logicalStandOffset 可覆盖站高
	- 击退锁定字段由 LogicalDisplace 写入（本模块读 until，不反向 require）
	- 浮空锁由 LogicalAirborne 写 _airLockUntil（本模块同读；EnemySim 浮空活跃时不调用 integrate）
	- 禁止每怪 Heartbeat；滑移射线每帧最多 +2 条短探（左右切向各 1）

	加载：
		local LogicEntityMotion = Utils.LogicEntityMotion

	示例：
		-- 业务走 LogicalMoveCommand.applyDesired（独占 setGoal）；本模块只被 EnemySim 调 integrate
		LogicalMoveCommand.applyDesired(rec)
		LogicEntityMotion.integrate(rec, dt)
		-- 受击位移请用 clampStepByWall，不要对击退向量做切向滑移
]]

local Workspace = game:GetService("Workspace")

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local EnemyLogicalStore = Utils.EnemyLogicalStore
local RayCast = Utils.RayCast
local SystemGameConfig = Utils.SystemGameConfig

local LogicEntityMotion = {}

--============================================================================--
-- 常量
--============================================================================--

local ARRIVE_EPS = 0.35
local DEFAULT_SPEED = 8
local GROUND_RAY_DOWN = 64
local GROUND_RAY_TAG = "Ground"
local FALLBACK_STAND_OFFSET = 2.5
local FALLBACK_HALF_R = 1.5
local FALLBACK_RAY_LIFT = 4
--- 挡墙额外皮肤（Stud）；在水平半宽之外再留空隙
local WALL_SKIN = 0.35
--- 本帧可推进的最小步长；更小则视为贴墙停住
local MIN_MOVE_STEP = 0.05
--- 左右侧射线相对中心的横向偏置系数（× 水平半宽）
local SIDE_RAY_OFFSET_MUL = 0.65
local DEFAULT_BBOX = Vector3.new(4, 5, 4)
--- 切向探空短射线长度（Stud）
local SLIDE_PROBE_LEN = 2
--- 左右自由距差小于此值时沿用上一侧，避免贴墙左右抖
local SLIDE_SIDE_HYSTERESIS = 0.35
--- 卡住帧数缺省（可被 GameConfig.怪物系统.卡住帧数 覆盖）
local STUCK_FRAMES_DEFAULT = 30
--- 卡住改向：临时点相对当前的侧向位移下限（Stud）
local STUCK_NUDGE_MIN = 5
--- 卡住改向侧向位移 = max(MIN, 半宽 × MUL)
local STUCK_NUDGE_MUL = 3
--- 临时积分点最长存活秒；到期回落 _logicalGoal
local STUCK_STEER_HOLD_SEC = 0.75
--- setGoal 平面位移超过此值才丢弃卡住改向（与 Ranger 追击 2 stud 节流对齐）
local GOAL_RESET_STUCK_EPS = 2.0
--- 追击倍率超过此值播 run，否则 walk
local CHASE_RUN_MUL = 1.15
--- 平面方向退化阈值
local FLAT_DIR_EPS = 1e-4
--- integrate 单帧 dt 上限（秒）
local MAX_DT = 0.1

--============================================================================--
-- 私有：锁窗 / bbox
--============================================================================--

local _stuckFramesCached: number? = nil

--[[
	是否处于击退/浮空硬锁（LogicalDisplace / LogicalAirborne 写入的 until 字段；避免 require 循环）
	@param entity any - AI 态
	@return boolean - true 时禁止 setGoal / integrate
]]
local function _isMoveLocked(entity: any): boolean
	if type(entity) ~= "table" then
		return false
	end
	local now = Workspace:GetServerTimeNow()
	local untilT = entity._logicalDisplaceUntil
	if type(untilT) == "number" and now < untilT then
		return true
	end
	untilT = entity._moveLockUntil
	if type(untilT) == "number" and now < untilT then
		return true
	end
	untilT = entity._airLockUntil
	return type(untilT) == "number" and now < untilT
end

--[[
	击退软减速倍率（硬锁外、_chaseSlowUntil 内）
	@param entity any - AI 态
	@return number - (0, 1]；无折扣为 1
]]
local function _getChaseSlowMul(entity: any): number
	if type(entity) ~= "table" then
		return 1
	end
	local untilT = entity._chaseSlowUntil
	if type(untilT) ~= "number" or Workspace:GetServerTimeNow() >= untilT then
		return 1
	end
	local mul = tonumber(entity._chaseSlowMul)
	if not mul or mul <= 0 then
		return 1
	end
	return math.clamp(mul, 0, 1)
end

--[[
	解析逻辑怪 bbox（Create 写入的权威体积）
	@param rec any - LogicalRecord
	@return Vector3 - 有效 bbox
]]
local function _getBBox(rec: any): Vector3
	local bbox = rec and rec.bboxSize
	if typeof(bbox) == "Vector3" and bbox.X > 0 and bbox.Y > 0 and bbox.Z > 0 then
		return bbox
	end
	return DEFAULT_BBOX
end

--[[
	贴地后 HRP/权威中心相对地面的站高
	优先 entity.logicalStandOffset；否则 bbox.Y/2
	@param rec any - LogicalRecord
	@return number - 站立抬高 stud
]]
local function _getStandOffset(rec: any): number
	local entity = rec and rec.entity
	local override = entity and rawget(entity, "logicalStandOffset")
	if typeof(override) == "number" and override > 0 then
		return override
	end
	local halfY = _getBBox(rec).Y * 0.5
	if halfY <= 0 then
		return FALLBACK_STAND_OFFSET
	end
	return halfY
end

--[[
	贴地射线起点上抬量：站高 + 半高（保证从脚以上射出）
	@param rec any - LogicalRecord
	@return number - 上抬 stud
]]
local function _getGroundRayLift(rec: any): number
	local stand = _getStandOffset(rec)
	local lift = stand + _getBBox(rec).Y * 0.5
	if lift <= 0 then
		return FALLBACK_RAY_LIFT
	end
	return lift
end

--[[
	水平半宽（挡墙空隙）
	@param rec any - LogicalRecord
	@return number - 半宽 stud
]]
local function _getBodyHalfRadius(rec: any): number
	local bbox = _getBBox(rec)
	local halfR = math.max(bbox.X, bbox.Z) * 0.5
	if halfR <= 0 then
		return FALLBACK_HALF_R
	end
	return halfR
end

--[[
	连续无效步进多少帧视为卡住（读配置一次后缓存）
	@return number - 帧阈值，≥1
]]
local function _getStuckFramesThreshold(): number
	if _stuckFramesCached then
		return _stuckFramesCached
	end
	local v = SystemGameConfig.GetValue({ "怪物系统", "卡住帧数" })
	if type(v) == "number" and v >= 1 then
		_stuckFramesCached = math.floor(v)
	else
		_stuckFramesCached = STUCK_FRAMES_DEFAULT
	end
	return _stuckFramesCached :: number
end

--[[
	贴地：对场景向下射线，取地面 Y + 站高
	@param rec any - LogicalRecord
	@param pos Vector3 - 参考位置
	@return number - 贴地后 Y（失败则原 Y）
]]
local function _snapY(rec: any, pos: Vector3): number
	local lift = _getGroundRayLift(rec)
	local origin = Vector3.new(pos.X, pos.Y + lift, pos.Z)
	local result = RayCast.RayCastDirection(origin, Vector3.new(0, -1, 0), lift + GROUND_RAY_DOWN, GROUND_RAY_TAG)
	if result then
		return result.Position.Y + _getStandOffset(rec)
	end
	return pos.Y
end

--[[
	沿移动方向水平挡墙：中心 + 左右偏置共 3 条射线，截断本帧步长
	@param rec any - LogicalRecord
	@param cur Vector3 - 当前权威中心
	@param dir Vector3 - 单位水平方向
	@param step number - 本帧期望步长
	@return number - 允许步长（≥0）
]]
local function _clampStepByWall(rec: any, cur: Vector3, dir: Vector3, step: number): number
	if step <= 0 then
		return 0
	end

	local halfR = _getBodyHalfRadius(rec)
	local clearance = halfR + WALL_SKIN
	local rayLen = step + clearance
	if rayLen <= 0 then
		return 0
	end

	local side = Vector3.new(-dir.Z, 0, dir.X) * (halfR * SIDE_RAY_OFFSET_MUL)
	local origins = {
		cur,
		cur + side,
		cur - side,
	}

	local allowed = step
	for _, origin in ipairs(origins) do
		local hit = RayCast.RayCastDirection(origin, dir, rayLen, GROUND_RAY_TAG)
		if hit then
			local remain = hit.Distance - clearance
			if remain < allowed then
				allowed = remain
			end
		end
	end

	if allowed < MIN_MOVE_STEP then
		return 0
	end
	return allowed
end

--[[
	将水平 Look 压成单位向量（退化时朝 -Z）
	@param look Vector3 - 原始朝向
	@return Vector3 - 平面单位朝向
]]
local function _flatLookUnit(look: Vector3): Vector3
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < FLAT_DIR_EPS then
		return Vector3.new(0, 0, -1)
	end
	return flat.Unit
end

--[[
	写回带贴地 Y 的权威 CFrame
	@param rec any - LogicalRecord
	@param pos Vector3 - 平面位置（Y 将被贴地覆盖）
	@param lookDir Vector3 - 平面朝向（可不单位）
]]
local function _setCFrameSnapped(rec: any, pos: Vector3, lookDir: Vector3)
	local y = _snapY(rec, pos)
	local nextPos = Vector3.new(pos.X, y, pos.Z)
	local flat = _flatLookUnit(lookDir)
	EnemyLogicalStore.setCFrame(rec.id, CFrame.lookAt(nextPos, nextPos + flat))
end

--[[
	无位移目标时消费朝向意图（Ranger 环带 hold）；有 goal 时由位移方向写朝向
	@param rec any - LogicalRecord
	@param entity any - AI 态
	@return boolean - 本帧是否改动了位姿
]]
local function _applyDesiredLook(rec: any, entity: any): boolean
	local look = entity._desiredLook
	if typeof(look) ~= "Vector3" then
		return false
	end
	entity._desiredLook = nil
	_setCFrameSnapped(rec, rec.cframe.Position, look)
	return true
end

--[[
	清除卡住计数与临时改向点（到达 / 清目标 / 硬锁时调用）
	@param entity any - AI 态
]]
local function _clearStuckState(entity: any)
	entity._stuckFrames = 0
	entity._stuckSteerPos = nil
	entity._stuckSteerUntil = nil
	entity._needRepath = nil
	entity._stuckSide = nil
	entity._slideSide = nil
end

--[[
	终局才清 _desiredPos（中间路点到达不得清，否则 Wander Idle / ScriptGoal 提前 Auto）
	@param entity any - AI 态
	@param cur Vector3 - 当前权威中心
]]
local function _clearDesiredIfArrived(entity: any, cur: Vector3)
	local desired = entity._desiredPos
	if typeof(desired) ~= "Vector3" then
		return
	end
	local dx = desired.X - cur.X
	local dz = desired.Z - cur.Z
	if (dx * dx + dz * dz) <= (ARRIVE_EPS * ARRIVE_EPS) then
		entity._desiredPos = nil
	end
end

--[[
	切向探空：该方向还能走多远（扣除身体空隙）
	@param rec any - LogicalRecord
	@param cur Vector3 - 当前权威中心
	@param dir Vector3 - 单位水平方向
	@param probeLen number - 探测长度
	@return number - [0, probeLen]
]]
local function _probeFreeDistance(rec: any, cur: Vector3, dir: Vector3, probeLen: number): number
	if probeLen <= 0 then
		return 0
	end
	local halfR = _getBodyHalfRadius(rec)
	local clearance = halfR + WALL_SKIN
	local rayLen = probeLen + clearance
	local hit = RayCast.RayCastDirection(cur, dir, rayLen, GROUND_RAY_TAG)
	if not hit then
		return probeLen
	end
	local remain = hit.Distance - clearance
	if remain < 0 then
		return 0
	end
	if remain > probeLen then
		return probeLen
	end
	return remain
end

--[[
	在 ±切向中选更空的一侧；自由距接近时沿用上一侧，避免左右抖
	@param rec any - LogicalRecord
	@param entity any - AI 态（读写 _slideSide）
	@param cur Vector3 - 当前权威中心
	@param forwardDir Vector3 - 被挡住的前进单位方向
	@return Vector3? - 单位切向；退化时 nil
]]
local function _pickSlideTangent(rec: any, entity: any, cur: Vector3, forwardDir: Vector3): Vector3?
	local t = Vector3.new(-forwardDir.Z, 0, forwardDir.X)
	if t.Magnitude < FLAT_DIR_EPS then
		return nil
	end
	t = t.Unit
	local freePos = _probeFreeDistance(rec, cur, t, SLIDE_PROBE_LEN)
	local freeNeg = _probeFreeDistance(rec, cur, -t, SLIDE_PROBE_LEN)
	local prefer = entity._slideSide
	if prefer ~= 1 and prefer ~= -1 then
		prefer = if freePos >= freeNeg then 1 else -1
	end
	local chosen: number
	if freePos > freeNeg + SLIDE_SIDE_HYSTERESIS then
		chosen = 1
	elseif freeNeg > freePos + SLIDE_SIDE_HYSTERESIS then
		chosen = -1
	else
		chosen = prefer
	end
	entity._slideSide = chosen
	if chosen == 1 then
		return t
	end
	return -t
end

--[[
	本帧平面步进：能沿前进方向走则走（可短于期望，擦墙减速）；否则切向滑移
	切向步长不超过原 step，避免单帧沿墙滑过远
	@param rec any - LogicalRecord
	@param entity any - AI 态
	@param cur Vector3 - 当前权威中心
	@param forwardDir Vector3 - 单位前进方向
	@param step number - 本帧期望步长
	@return number - 实际步长（≥0）
	@return Vector3 - 实际移动单位方向
]]
local function _tryPlanarStep(rec: any, entity: any, cur: Vector3, forwardDir: Vector3, step: number): (number, Vector3)
	local allowed = _clampStepByWall(rec, cur, forwardDir, step)
	if allowed >= MIN_MOVE_STEP then
		return allowed, forwardDir
	end
	local tangent = _pickSlideTangent(rec, entity, cur, forwardDir)
	if tangent then
		local slideStep = _clampStepByWall(rec, cur, tangent, step)
		if slideStep >= MIN_MOVE_STEP then
			return slideStep, tangent
		end
	end
	return 0, forwardDir
end

--[[
	卡住改向：沿交替切向在身旁放临时积分点（无寻路时的绕障）
	不改 _logicalGoal，避免 Ranger 下一帧用玩家点覆盖后又立刻对撞
	@param entity any - AI 态
	@param rec any - LogicalRecord
	@param cur Vector3 - 当前权威中心
	@param dir Vector3 - 被挡住的前进方向
]]
local function _applyStuckRedirect(entity: any, rec: any, cur: Vector3, dir: Vector3)
	local side = entity._stuckSide
	if side ~= 1 and side ~= -1 then
		side = 1
	end
	entity._stuckSide = -side

	local tangent = Vector3.new(-dir.Z, 0, dir.X)
	if tangent.Magnitude < FLAT_DIR_EPS then
		tangent = Vector3.new(1, 0, 0)
	else
		tangent = tangent.Unit
	end

	local halfR = _getBodyHalfRadius(rec)
	local nudge = math.max(STUCK_NUDGE_MIN, halfR * STUCK_NUDGE_MUL)
	local steer = cur + tangent * (side * nudge)
	entity._stuckSteerPos = Vector3.new(steer.X, cur.Y, steer.Z)
	entity._stuckSteerUntil = Workspace:GetServerTimeNow() + STUCK_STEER_HOLD_SEC
	entity._stuckFrames = 0
	entity._needRepath = true
end

--[[
	本帧积分目标：未过期的卡住临时点优先，否则 _logicalGoal
	@param entity any - AI 态
	@param logicalGoal Vector3 - Ranger/命令写入的世界目标
	@param cur Vector3 - 当前权威中心（用于对齐 Y）
	@return Vector3 - 平面积分点
]]
local function _resolveIntegrateGoal(entity: any, logicalGoal: Vector3, cur: Vector3): Vector3
	local steer = entity._stuckSteerPos
	if typeof(steer) ~= "Vector3" then
		return logicalGoal
	end
	local untilT = entity._stuckSteerUntil
	if type(untilT) == "number" and Workspace:GetServerTimeNow() >= untilT then
		entity._stuckSteerPos = nil
		entity._stuckSteerUntil = nil
		return logicalGoal
	end
	return Vector3.new(steer.X, cur.Y, steer.Z)
end

--[[
	解析本帧平面移速（walkSpeed × 追击倍率 × 软减速）
	@param entity any - AI 态（walkSpeed / state / chaseSpeedMul / 软减速 until）
	@return number - stud/s，至少 DEFAULT_SPEED
]]
local function _resolvePlanarSpeed(entity: any): number
	local speed = tonumber(entity.walkSpeed) or DEFAULT_SPEED
	if speed <= 0 then
		speed = DEFAULT_SPEED
	end
	if entity.state == "Chasing" and typeof(entity.chaseSpeedMul) == "number" and entity.chaseSpeedMul > 0 then
		speed = speed * entity.chaseSpeedMul
	end
	return speed * _getChaseSlowMul(entity)
end

--[[
	到达积分点：clearGoal + 终局清 desired + 贴地写回当前朝向
	@param rec any - LogicalRecord
	@param entity any - AI 态
	@param cur Vector3 - 当前权威中心
]]
local function _arriveAndSnap(rec: any, entity: any, cur: Vector3)
	LogicEntityMotion.clearGoal(entity)
	_clearDesiredIfArrived(entity, cur)
	_setCFrameSnapped(rec, cur, rec.cframe.LookVector)
end

--============================================================================--
-- 公共 API
--============================================================================--

--[[
	贴地后的世界 Y（供 Create 出生预贴地等复用）
	@param rec any - LogicalRecord（至少含 bboxSize；entity 可选）
	@param pos Vector3 - 参考位置
	@return number - 贴地 Y
]]
function LogicEntityMotion.snapGroundY(rec: any, pos: Vector3): number
	if typeof(pos) ~= "Vector3" then
		return 0
	end
	return _snapY(rec, pos)
end

--[[
	沿方向挡墙截断步长（供外部位移复用；硬截断，不做切向滑移）
	@param rec any - LogicalRecord
	@param cur Vector3 - 当前权威中心
	@param dir Vector3 - 单位水平方向
	@param step number - 期望步长
	@return number - 允许步长（≥0）
]]
function LogicEntityMotion.clampStepByWall(rec: any, cur: Vector3, dir: Vector3, step: number): number
	if typeof(cur) ~= "Vector3" or typeof(dir) ~= "Vector3" then
		return 0
	end
	return _clampStepByWall(rec, cur, dir, tonumber(step) or 0)
end

--[[
	设置逻辑移动目标（平面）；击退硬锁期间忽略，避免盖掉受击位移
	desired 平面跳变超过 GOAL_RESET_STUCK_EPS 时丢弃卡住临时点，让积分跟新目标
	@param entity any - LogicalRecord.entity；字段：_logicalGoal / _stuckSteerPos / _stuckSteerUntil / _stuckFrames；硬锁 _logicalDisplaceUntil / _moveLockUntil / _airLockUntil
	@param goal Vector3 - 世界目标点（Y 可忽略）
]]
function LogicEntityMotion.setGoal(entity: any, goal: Vector3)
	if type(entity) ~= "table" or typeof(goal) ~= "Vector3" then
		return
	end
	if _isMoveLocked(entity) then
		return
	end
	local prev = entity._logicalGoal
	entity._logicalGoal = goal
	if typeof(prev) ~= "Vector3" then
		entity._stuckFrames = 0
		entity._stuckSteerPos = nil
		entity._stuckSteerUntil = nil
		return
	end
	local dx = prev.X - goal.X
	local dz = prev.Z - goal.Z
	if (dx * dx + dz * dz) >= (GOAL_RESET_STUCK_EPS * GOAL_RESET_STUCK_EPS) then
		entity._stuckFrames = 0
		entity._stuckSteerPos = nil
		entity._stuckSteerUntil = nil
	end
end

--[[
	清除本帧积分点与卡住态；不清 _desiredPos（Pause / 受击锁要保留意图）
	@param entity any - LogicalRecord.entity；清 _logicalGoal / _stuck* / _needRepath；写 moveState=idle
]]
function LogicEntityMotion.clearGoal(entity: any)
	if type(entity) ~= "table" then
		return
	end
	entity._logicalGoal = nil
	entity.moveState = "idle"
	_clearStuckState(entity)
end

--[[
	积分一帧位移并写回 Store.cframe（挡墙 / 切向滑移 + 贴地）
	贴墙不清目标；到积分点只 clearGoal，终局才清 _desiredPos。浮空/击退请走 Displace/Airborne，勿对本函数期望滑移。
	无 _logicalGoal 时消费 _desiredLook（§1.7：Ranger 不得直写 Store）。
	@param rec any - LogicalRecord（须含 id / cframe / bboxSize / entity）；entity 另含 _logicalGoal / _desiredPos / _desiredLook / walkSpeed / chaseSpeedMul / state
	@param dt number - 帧间隔秒
	@return boolean - 本帧是否改动了位姿
]]
function LogicEntityMotion.integrate(rec: any, dt: number): boolean
	if type(rec) ~= "table" or not rec.alive then
		return false
	end
	local entity = rec.entity
	if type(entity) ~= "table" then
		return false
	end
	-- 击退硬锁：清目标，禁止积分追击
	if _isMoveLocked(entity) then
		if entity._logicalGoal ~= nil then
			LogicEntityMotion.clearGoal(entity)
		end
		return false
	end
	local logicalGoal = entity._logicalGoal
	if typeof(logicalGoal) ~= "Vector3" then
		return _applyDesiredLook(rec, entity)
	end

	local dtClamped = math.clamp(tonumber(dt) or 0, 0, MAX_DT)
	if dtClamped <= 0 then
		return false
	end

	local speed = _resolvePlanarSpeed(entity)
	local cur = rec.cframe.Position
	local flatLogical = Vector3.new(logicalGoal.X, cur.Y, logicalGoal.Z)
	local distLogical = (flatLogical - cur).Magnitude
	if distLogical <= ARRIVE_EPS then
		_arriveAndSnap(rec, entity, cur)
		return true
	end

	local goal = _resolveIntegrateGoal(entity, logicalGoal, cur)
	local delta = Vector3.new(goal.X, cur.Y, goal.Z) - cur
	local dist = delta.Magnitude
	if dist <= ARRIVE_EPS then
		-- 临时改向点已到：丢掉 steer，本帧改追真正 desired
		entity._stuckSteerPos = nil
		entity._stuckSteerUntil = nil
		delta = flatLogical - cur
		dist = delta.Magnitude
		if dist <= ARRIVE_EPS then
			_arriveAndSnap(rec, entity, cur)
			return true
		end
	end

	local dir = delta.Unit
	local step = math.min(dist, speed * dtClamped)
	local moved, moveDir = _tryPlanarStep(rec, entity, cur, dir, step)
	if moved <= 0 then
		entity._stuckFrames = (tonumber(entity._stuckFrames) or 0) + 1
		if entity._stuckFrames >= _getStuckFramesThreshold() then
			_applyStuckRedirect(entity, rec, cur, dir)
		end
		entity.moveState = "idle"
		_setCFrameSnapped(rec, cur, dir)
		return true
	end

	entity._stuckFrames = 0
	local nextPos = cur + moveDir * moved
	if entity.state == "Chasing" and typeof(entity.chaseSpeedMul) == "number" and entity.chaseSpeedMul > CHASE_RUN_MUL then
		entity.moveState = "run"
	else
		entity.moveState = "walk"
	end
	_setCFrameSnapped(rec, nextPos, moveDir)
	return true
end

return LogicEntityMotion
