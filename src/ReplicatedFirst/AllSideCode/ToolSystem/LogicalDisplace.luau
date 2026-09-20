--[[
	Module: LogicalDisplace
	Description: 逻辑怪受击位移（权威 Store CFrame + 白名单轨迹事件；经 EnemySim 步进，禁每怪 Heartbeat）
	Author: 林奥宇
	Created: 2026-08-17
	Last Modified: 2026-09-01

	功能：
	- tryApplyFromHitbox：HitResolver 逻辑怪命中后调用（PhysicsEffectName → 挡墙截断 → 下发轨迹）
	- apply：对 LogicalRecord 施加权威位移并 FireClient 轨迹
	- step：EnemySim 批处理内插值写 Store；返回 true 时调用方应跳过 AI/普通 integrate
	- isActive / isMoveLocked / getChaseSpeedMul：位移窗、击退硬锁与软减速查询
	- cancel：递增 gen 使旧 step 会话失效并清锁

	模块关系：
	- LogicalDisplaceProfile：PhysicsEffectName → distance/duration/easing（本模块不解析配表）
	- HitResolver.applyLogicalEnemyHit：扣血后调用 tryApplyFromHitbox（仅服务端结算路径）
	- EnemySim.step：每帧优先 LogicalDisplace.step；活跃或 isMoveLocked 则跳过追击；软减速由 getChaseSpeedMul 供 integrate
	- SystemLogicalEnemy.OnDisplace：客户端按同 start/end/duration/t0 播轨迹（表现，无权威）
	- LogicEntityMotion：clampStepByWall / snapGroundY 复用挡墙与贴地；integrate 读取 chase 软减速

	约束：
	- 仅服务端调用 apply / tryApplyFromHitbox / step（由 HitResolver、EnemySim 保证；本模块不做 IsServer 分支）
	- 击退插值 + MOVE_LOCK_TAIL 内禁止追击；其后 CHASE_SLOW_TAIL 内追击速度打折
	- tryApply 内先同步锁移动，再 task.defer 一帧施加轨迹
	- 对照 RP18 LogicalDisplace；本仓无服端 Model，以 LogicalRecord.cframe 为权威
	- 位姿只经 EnemyLogicalStore.setCFrame；与 Airborne / Motion.integrate 由 EnemySim 互斥，不并行抢写

	加载：
		local LogicalDisplace = Utils.LogicalDisplace
		-- 服 Hit 后：
		LogicalDisplace.tryApplyFromHitbox(logicalId, hitbox)
		-- EnemySim 内：
		if LogicalDisplace.step(rec, dt) then continue end
]]

local Workspace = game:GetService("Workspace")

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Players = Utils.Players
local TweenService = Utils.TweenService
local Log = Utils.Log
local NetWork = Utils.NetWork
local NetMsg = Utils.NetMsg
local LogicalDisplaceProfile = Utils.LogicalDisplaceProfile
local EnemyLogicalStore = Utils.EnemyLogicalStore
local LogicEntityMotion = Utils.LogicEntityMotion

local LogicalDisplace = {}

--============================================================================--
-- 常量
--============================================================================--

local MIN_DIR_EPSILON = 1e-4
local MIN_STEP = 0.05
local MAX_DT = 0.1
--- 击退结束后仍禁止 AI 追击/积分的尾窗（秒）
local MOVE_LOCK_TAIL_SEC = 0.35
--- 尾窗结束后追击速度折扣持续（秒）；0 表示无软减速段
local CHASE_SLOW_TAIL_SEC = 0.4
--- 软减速段追击速度倍率（相对 walkSpeed×chaseSpeedMul）
local CHASE_SLOW_MUL = 0.35
local DEFAULT_EASING_STYLE_NAME = "Quad"
local DEFAULT_EASING_DIRECTION_NAME = "Out"
local FALLBACK_LOOK = Vector3.new(0, 0, -1)

--============================================================================--
-- 私有：时间 / 方向 / 缓动
--============================================================================--

--[[
	当前服务端时间（与客户端轨迹 t0 对齐）
	@return number - Workspace:GetServerTimeNow()
]]
local function _now(): number
	return Workspace:GetServerTimeNow()
end

--[[
	将方向压到 plane（默认 xz）
	@param direction Vector3 - 原始击退方向（可含 Y）
	@param plane string? - "xz"（默认）或 "xyz"；其它值按 xz 处理
	@return Vector3? - 单位方向；过短或非 Vector3 时 nil
]]
local function _flattenDirection(direction: Vector3, plane: string?): Vector3?
	if typeof(direction) ~= "Vector3" then
		return nil
	end
	local dir = direction
	if plane ~= "xyz" then
		dir = Vector3.new(direction.X, 0, direction.Z)
	end
	if dir.Magnitude < MIN_DIR_EPSILON then
		return nil
	end
	return dir.Unit
end

--[[
	解析 EasingStyle 枚举名
	@param name string? - Enum.EasingStyle 成员名；非法时回退 Quad
	@return Enum.EasingStyle - 解析结果或 Quad
]]
local function _parseEasingStyle(name: string?): Enum.EasingStyle
	if type(name) ~= "string" then
		return Enum.EasingStyle.Quad
	end
	local ok, style = pcall(function()
		return (Enum.EasingStyle :: any)[name]
	end)
	if ok and style then
		return style
	end
	Log.warn("[LogicalDisplace] unknown EasingStyle:", name)
	return Enum.EasingStyle.Quad
end

--[[
	解析 EasingDirection 枚举名
	@param name string? - Enum.EasingDirection 成员名；非法时回退 Out
	@return Enum.EasingDirection - 解析结果或 Out
]]
local function _parseEasingDirection(name: string?): Enum.EasingDirection
	if type(name) ~= "string" then
		return Enum.EasingDirection.Out
	end
	local ok, dir = pcall(function()
		return (Enum.EasingDirection :: any)[name]
	end)
	if ok and dir then
		return dir
	end
	Log.warn("[LogicalDisplace] unknown EasingDirection:", name)
	return Enum.EasingDirection.Out
end

--[[
	从 hitbox 解析水平击退方向（目标中心相对盒心：从盒心推开）
	@param hitbox any - 须能取世界中心：优先 getWorldCenter()，否则 hitbox.hitbox BasePart.Position
	@param targetPos Vector3 - 逻辑怪当前中心
	@return Vector3? - xz 单位方向；重合或无法取盒心时 nil
]]
local function _resolveDirectionFromHitbox(hitbox: any, targetPos: Vector3): Vector3?
	local hitboxPos: Vector3? = nil
	if hitbox.getWorldCenter then
		hitboxPos = hitbox:getWorldCenter()
	else
		local hitboxPart = hitbox.hitbox
		if hitboxPart and typeof(hitboxPart) == "Instance" and hitboxPart:IsA("BasePart") then
			hitboxPos = hitboxPart.Position
		end
	end
	if not hitboxPos then
		return nil
	end
	local flat = Vector3.new(targetPos.X - hitboxPos.X, 0, targetPos.Z - hitboxPos.Z)
	if flat.Magnitude < MIN_DIR_EPSILON then
		return nil
	end
	return flat.Unit
end

--============================================================================--
-- 私有：写位姿 / 网络下行 / 移速锁
--============================================================================--

--[[
	写权威位姿（贴地 Y + 保持水平朝向）
	@param rec any - LogicalRecord（须含 id、cframe）
	@param nextPos Vector3 - 期望中心（Y 可被贴地覆盖）
]]
local function _writePose(rec: any, nextPos: Vector3)
	local look = rec.cframe.LookVector
	local flatLook = Vector3.new(look.X, 0, look.Z)
	if flatLook.Magnitude < MIN_DIR_EPSILON then
		flatLook = FALLBACK_LOOK
	else
		flatLook = flatLook.Unit
	end
	local y = LogicEntityMotion.snapGroundY(rec, nextPos)
	local pos = Vector3.new(nextPos.X, y, nextPos.Z)
	local cf = CFrame.lookAt(pos, pos + flatLook)
	EnemyLogicalStore.setCFrame(rec.id, cf)
end

--[[
	白名单/全员下发客户端轨迹（表现用，权威仍在 Store）
	@param rec any - LogicalRecord；allowedPlayerIds 非空则只推白名单
	@param startPos Vector3 - 轨迹起点（贴地后）
	@param endPos Vector3 - 轨迹终点（挡墙截断 + 贴地后）
	@param duration number - 秒；须 > 0
	@param easingStyle string - Enum.EasingStyle 名，供客户端解析
	@param easingDirection string - Enum.EasingDirection 名
	@param t0 number - 服务端起始时间（GetServerTimeNow）
]]
local function _fireClientDisplace(
	rec: any,
	startPos: Vector3,
	endPos: Vector3,
	duration: number,
	easingStyle: string,
	easingDirection: string,
	t0: number
)
	if not NetWork or not NetMsg or not NetMsg.ENEMY_LOGICAL_DISPLACE then
		return
	end

	local payload = {
		id = rec.id,
		startX = startPos.X,
		startY = startPos.Y,
		startZ = startPos.Z,
		endX = endPos.X,
		endY = endPos.Y,
		endZ = endPos.Z,
		duration = duration,
		easingStyle = easingStyle,
		easingDirection = easingDirection,
		t0 = t0,
	}

	local targets: { Player } = {}
	local allowed = rec.allowedPlayerIds
	if type(allowed) == "table" and #allowed > 0 then
		for _, userId in ipairs(allowed) do
			local plr = Players:GetPlayerByUserId(userId)
			if plr then
				table.insert(targets, plr)
			end
		end
	else
		for _, plr in ipairs(Players:GetPlayers()) do
			table.insert(targets, plr)
		end
	end

	for _, plr in ipairs(targets) do
		NetWork.FireClient(plr, NetMsg.ENEMY_LOGICAL_DISPLACE, payload)
	end
end

--[[
	写入击退期间的移动锁定与软减速尾窗（apply / 命中预锁共用）
	@param entity any - LogicalRecord.entity；写入 _moveLockUntil / _chaseSlowUntil / _chaseSlowMul
	@param duration number - 击退插值时长（秒）
	@param t0 number - 起始服务端时间
]]
local function _armMoveLocks(entity: any, duration: number, t0: number)
	local lockEnd = t0 + math.max(duration, 0) + MOVE_LOCK_TAIL_SEC
	entity._moveLockUntil = lockEnd
	if CHASE_SLOW_TAIL_SEC > 0 then
		entity._chaseSlowUntil = lockEnd + CHASE_SLOW_TAIL_SEC
		entity._chaseSlowMul = CHASE_SLOW_MUL
	else
		entity._chaseSlowUntil = nil
		entity._chaseSlowMul = nil
	end
end

--============================================================================--
-- 公共 API
--============================================================================--

--[[
	取消进行中的逻辑位移
	会递增 _logicalDisplaceGen，使旧 step 会话失效；apply 内会再 +1 作为新会话 gen（双递增为有意约定）
	@param rec any - LogicalRecord；须含 entity 表，否则无操作
]]
function LogicalDisplace.cancel(rec: any)
	if type(rec) ~= "table" then
		return
	end
	local entity = rec.entity
	if type(entity) ~= "table" then
		return
	end
	entity._logicalDisplace = nil
	entity._logicalDisplaceGen = (entity._logicalDisplaceGen or 0) + 1
	entity._logicalDisplaceUntil = nil
	entity._moveLockUntil = nil
	entity._chaseSlowUntil = nil
	entity._chaseSlowMul = nil
end

--[[
	是否仍在逻辑受击位移插值中
	@param rec any - LogicalRecord
	@return boolean - true 表示 _logicalDisplaceUntil 未到期
]]
function LogicalDisplace.isActive(rec: any): boolean
	if type(rec) ~= "table" then
		return false
	end
	local entity = rec.entity
	if type(entity) ~= "table" then
		return false
	end
	local untilT = entity._logicalDisplaceUntil
	return type(untilT) == "number" and _now() < untilT
end

--[[
	击退插值或移速锁定尾窗内：禁止 AI 设目标 / 积分追击
	@param rec any - LogicalRecord
	@return boolean - true 时应跳过 RangerAi + integrate
]]
function LogicalDisplace.isMoveLocked(rec: any): boolean
	if LogicalDisplace.isActive(rec) then
		return true
	end
	if type(rec) ~= "table" then
		return false
	end
	local entity = rec.entity
	if type(entity) ~= "table" then
		return false
	end
	local untilT = entity._moveLockUntil
	return type(untilT) == "number" and _now() < untilT
end

--[[
	当前追击/行走速度倍率（击退硬锁为 0；软减速段为 CHASE_SLOW_MUL）
	@param rec any - LogicalRecord
	@return number - [0, 1]；1 表示无折扣
]]
function LogicalDisplace.getChaseSpeedMul(rec: any): number
	if LogicalDisplace.isMoveLocked(rec) then
		return 0
	end
	if type(rec) ~= "table" then
		return 1
	end
	local entity = rec.entity
	if type(entity) ~= "table" then
		return 1
	end
	local untilT = entity._chaseSlowUntil
	if type(untilT) ~= "number" or _now() >= untilT then
		return 1
	end
	local mul = tonumber(entity._chaseSlowMul)
	if not mul or mul < 0 then
		return CHASE_SLOW_MUL
	end
	return math.clamp(mul, 0, 1)
end

--[[
	对逻辑怪施加权威位移并下发轨迹（仅服务端调用）
	@param rec any - LogicalRecord（须 alive、含 id/cframe；无 entity 时会挂临时表）
	@param params table - DisplaceParams：distance(number)、duration(number)、easingStyle?(string)、easingDirection?(string)、plane?("xz"|"xyz")
	@param direction Vector3 - 击退方向（由 plane 压平）
	@return boolean - 是否成功启动；距离/时长无效、方向过短或挡墙后步长过小则为 false
]]
function LogicalDisplace.apply(rec: any, params: any, direction: Vector3): boolean
	if type(rec) ~= "table" or not rec.alive or typeof(rec.id) ~= "number" then
		return false
	end
	if type(params) ~= "table" then
		return false
	end
	local distance = tonumber(params.distance) or 0
	local duration = tonumber(params.duration) or 0
	if distance <= 0 or duration <= 0 then
		return false
	end

	local entity = rec.entity
	if type(entity) ~= "table" then
		-- 无 AI entity 时仍允许位移：挂临时表
		entity = {}
		rec.entity = entity
	end

	local dir = _flattenDirection(direction, params.plane)
	if not dir then
		return false
	end

	LogicalDisplace.cancel(rec)
	local gen = (entity._logicalDisplaceGen or 0) + 1
	entity._logicalDisplaceGen = gen

	local startPos = rec.cframe.Position
	local allowed = LogicEntityMotion.clampStepByWall(rec, startPos, dir, distance)
	if allowed < MIN_STEP then
		entity._logicalDisplaceUntil = nil
		return false
	end

	local endRaw = Vector3.new(
		startPos.X + dir.X * allowed,
		startPos.Y,
		startPos.Z + dir.Z * allowed
	)
	local endY = LogicEntityMotion.snapGroundY(rec, endRaw)
	local endPos = Vector3.new(endRaw.X, endY, endRaw.Z)
	local startY = LogicEntityMotion.snapGroundY(rec, startPos)
	startPos = Vector3.new(startPos.X, startY, startPos.Z)

	local easingStyleName = if type(params.easingStyle) == "string" then params.easingStyle else DEFAULT_EASING_STYLE_NAME
	local easingDirectionName = if type(params.easingDirection) == "string" then params.easingDirection else DEFAULT_EASING_DIRECTION_NAME
	local easingStyle = _parseEasingStyle(easingStyleName)
	local easingDirection = _parseEasingDirection(easingDirectionName)

	local t0 = _now()
	entity._logicalDisplaceUntil = t0 + duration
	_armMoveLocks(entity, duration, t0)
	entity._logicalGoal = nil
	entity.moveState = "idle"
	entity._chaseMode = nil
	entity._logicalDisplace = {
		gen = gen,
		startPos = startPos,
		endPos = endPos,
		duration = duration,
		t0 = t0,
		easingStyle = easingStyle,
		easingDirection = easingDirection,
		elapsed = 0,
	}

	_fireClientDisplace(rec, startPos, endPos, duration, easingStyleName, easingDirectionName, t0)
	return true
end

--[[
	命中盒入口：解析 PhysicsEffectName 与方向后排队施加（仅服务端调用）
	成功时先同步预锁再 defer 一帧 apply，避免同帧 AI 抢写位姿
	@param logicalId number - 逻辑怪运行时 id
	@param hitbox any - 须含 hitPhysicsEffectName(string)；以及 getWorldCenter 或 hitbox BasePart
	@return boolean - true 表示已预锁并排队 apply；参数/档案/方向无效则为 false
]]
function LogicalDisplace.tryApplyFromHitbox(logicalId: number, hitbox: any): boolean
	if typeof(logicalId) ~= "number" or not hitbox then
		return false
	end

	local rec = EnemyLogicalStore.get(logicalId)
	if not rec or not rec.alive then
		return false
	end

	local profileName = hitbox.hitPhysicsEffectName
	if type(profileName) ~= "string" or profileName == "" then
		return false
	end
	if not LogicalDisplaceProfile or not LogicalDisplaceProfile.fromPhysicsName then
		Log.warn("[LogicalDisplace] LogicalDisplaceProfile unavailable")
		return false
	end

	local params = LogicalDisplaceProfile.fromPhysicsName(profileName)
	if not params then
		Log.warn("[LogicalDisplace] unknown PhysicsEffectName:", profileName)
		return false
	end

	local direction = _resolveDirectionFromHitbox(hitbox, rec.cframe.Position)
	if not direction then
		return false
	end

	-- 同帧先锁移动，避免 defer 前 AI 仍全速追击
	local entity = rec.entity
	if type(entity) ~= "table" then
		entity = {}
		rec.entity = entity
	end
	local duration = tonumber(params.duration) or 0
	_armMoveLocks(entity, duration, _now())
	entity._logicalGoal = nil
	entity.moveState = "idle"
	entity._chaseMode = nil

	-- 延后一帧：与扣血/表现同序，且避免与同帧 AI 抢写位姿
	task.defer(function()
		local latest = EnemyLogicalStore.get(logicalId)
		if not latest or not latest.alive then
			return
		end
		LogicalDisplace.apply(latest, params, direction)
	end)
	return true
end

--[[
	EnemySim 批处理步进位移；活跃时写 Store（仅服务端仿真路径调用）
	@param rec any - LogicalRecord
	@param dt number - 帧间隔（秒）；内部 clamp 到 [0, MAX_DT]
	@return boolean - true 表示本帧由位移驱动（调用方应跳过 AI 位移）
]]
function LogicalDisplace.step(rec: any, dt: number): boolean
	if type(rec) ~= "table" or not rec.alive then
		return false
	end
	local entity = rec.entity
	if type(entity) ~= "table" then
		return false
	end
	local d = entity._logicalDisplace
	if type(d) ~= "table" then
		return false
	end
	if entity._logicalDisplaceGen ~= d.gen then
		entity._logicalDisplace = nil
		return false
	end

	local duration = tonumber(d.duration) or 0
	if duration <= 0 then
		LogicalDisplace.cancel(rec)
		return false
	end

	d.elapsed = (tonumber(d.elapsed) or 0) + math.clamp(tonumber(dt) or 0, 0, MAX_DT)
	local alpha = math.clamp(d.elapsed / duration, 0, 1)
	local eased = TweenService:GetValue(alpha, d.easingStyle, d.easingDirection)
	local pos = d.startPos:Lerp(d.endPos, eased)
	_writePose(rec, pos)

	if alpha >= 1 then
		entity._logicalDisplace = nil
		entity._logicalDisplaceUntil = nil
	end
	return true
end

return LogicalDisplace
