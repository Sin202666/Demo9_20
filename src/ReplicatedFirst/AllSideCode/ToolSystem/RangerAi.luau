--[[
	Module: RangerAi
	Description: 逻辑怪 Ranger 精简状态机（Idle / Wandering / Chasing；批处理进 EnemySim）
	Author: 林奥宇
	Created: 2026-08-12
	Last Modified: 2026-08-28

	功能：
	- assemble：按 enemyConf 装配 entity（挂 LogicalRecord.entity）
	- step：Idle↔Wandering 巡逻；检测距内索敌进 Chasing；环带风筝位移
	- 位移意图只写 entity._desiredPos；积分由 EnemySim → LogicalMoveCommand.applyDesired
	- 朝向意图只写 entity._desiredLook；由 LogicEntityMotion.integrate 在无 _logicalGoal 时写 Store

	约束（L4 首包）：
	- 无物理 Script / 无每怪 Heartbeat / 无 SimplePath / 无技能释放
	- 对照 RP18 Ranger 几何意图（安全距 + 攻击距），不做 BandWander / Attacking
	- 禁止 LogicEntityMotion.setGoal / clearGoal（M1 单一 desired 写口）
	- 禁止 EnemyLogicalStore.setCFrame（§1.7：权威 cframe 仅 Motion / Airborne / Displace）

	加载：
		local RangerAi = Utils.RangerAi
		RangerAi.assemble(rec, cfg)
		RangerAi.step(rec, dt)
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Players = Utils.Players

local RangerAi = {}

local STATE_IDLE = "Idle"
local STATE_WANDERING = "Wandering"
local STATE_CHASING = "Chasing"

local DEFAULT_WALK_SPEED = 8
local DEFAULT_IDLE_MIN, DEFAULT_IDLE_MAX = 2, 5
local DEFAULT_WANDER_TIME_MIN, DEFAULT_WANDER_TIME_MAX = 3, 8
local DEFAULT_WANDER_RANGE_MIN, DEFAULT_WANDER_RANGE_MAX = 4, 12
local DEFAULT_DETECTION = 60
local DEFAULT_ATTACK_RANGE = 12
local DEFAULT_PATIENT_RANGE = 80

--[[
	解析 {min,max} 配表字段；空表/非法则回退默认
	@param v any - 配表值
	@param dMin number - 默认下限
	@param dMax number - 默认上限
	@return number, number - min, max
]]
local function _pair(v: any, dMin: number, dMax: number): (number, number)
	if type(v) == "table" then
		local a = tonumber(v[1])
		local b = tonumber(v[2])
		if a and b and b >= a and a >= 0 then
			return a, b
		end
		if a and a > 0 then
			return a, a
		end
	elseif typeof(v) == "number" and v > 0 then
		return v, v
	end
	return dMin, dMax
end

--[[
	钳制 Ranger 安全距（须 < attackRange）
	@param attackRange number - 攻击距
	@param fromCfg number? - 配表 rangerSafeDistance
	@return number - 安全距
]]
local function _clampSafeDistance(attackRange: number, fromCfg: number?): number
	local atk = attackRange
	if atk <= 0 then
		return 2
	end
	local rs: number
	if typeof(fromCfg) == "number" and fromCfg > 0 then
		rs = fromCfg
	else
		rs = atk * 0.55
	end
	rs = math.min(rs, atk - 0.5)
	rs = math.max(rs, 1)
	return rs
end

--[[
	从 enemyConf 构建运行时配置
	@param cfg table - enemyConf 行
	@return table - AI 配置
]]
local function _buildConfig(cfg: any): any
	local attackRange = tonumber(cfg.attackRange) or DEFAULT_ATTACK_RANGE
	if attackRange <= 0 then
		attackRange = DEFAULT_ATTACK_RANGE
	end
	local detectionRange = tonumber(cfg.detectionRange) or DEFAULT_DETECTION
	if detectionRange <= 0 then
		detectionRange = DEFAULT_DETECTION
	end
	local patientRange = tonumber(cfg.patientRange) or DEFAULT_PATIENT_RANGE
	if patientRange <= 0 then
		patientRange = math.max(detectionRange, DEFAULT_PATIENT_RANGE)
	end
	local idleMin, idleMax = _pair(cfg.idleTime, DEFAULT_IDLE_MIN, DEFAULT_IDLE_MAX)
	local wanderTMin, wanderTMax = _pair(cfg.wanderTime, DEFAULT_WANDER_TIME_MIN, DEFAULT_WANDER_TIME_MAX)
	local wanderRMin, wanderRMax = _pair(cfg.wanderRange, DEFAULT_WANDER_RANGE_MIN, DEFAULT_WANDER_RANGE_MAX)
	local chaseMul = tonumber(cfg.chaseRunSpeedMul) or 1
	if chaseMul <= 0 then
		chaseMul = 1
	end
	local walkSpeed = tonumber(cfg.spMax) or DEFAULT_WALK_SPEED
	if walkSpeed <= 0 then
		walkSpeed = DEFAULT_WALK_SPEED
	end

	return {
		attackRange = attackRange,
		rangerSafeDistance = _clampSafeDistance(attackRange, tonumber(cfg.rangerSafeDistance)),
		detectionRange = detectionRange,
		patientRange = patientRange,
		idleTimeMin = idleMin,
		idleTimeMax = idleMax,
		wanderTimeMin = wanderTMin,
		wanderTimeMax = wanderTMax,
		wanderRangeMin = wanderRMin,
		wanderRangeMax = wanderRMax,
		walkSpeed = walkSpeed,
		chaseSpeedMul = chaseMul,
		proactiveDetection = cfg.proactiveDetectionAggro ~= 0 and cfg.proactiveDetectionAggro ~= "0" and cfg.proactiveDetectionAggro ~= false,
	}
end

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
	是否允许与该玩家交互（空白名单=全开）
	@param rec any - LogicalRecord
	@param userId number - 玩家 UserId
	@return boolean - true 表示空白名单或 userId 在 allowedSet
]]
local function _canInteract(rec: any, userId: number): boolean
	if next(rec.allowedSet) == nil then
		return true
	end
	return rec.allowedSet[userId] == true
end

--[[
	检测距内最近玩家 HRP
	@param rec any - LogicalRecord
	@param origin Vector3 - 查询原点
	@param maxRange number - 最大平面距
	@return BasePart?, number? - HRP 与 UserId
]]
local function _findNearestTarget(rec: any, origin: Vector3, maxRange: number): (BasePart?, number?)
	local bestPart: BasePart? = nil
	local bestUid: number? = nil
	local bestDist = maxRange
	for _, plr in Players:GetPlayers() do
		if not _canInteract(rec, plr.UserId) then
			continue
		end
		local char = plr.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if not hrp or not hrp:IsA("BasePart") then
			continue
		end
		local hum = char:FindFirstChildOfClass("Humanoid")
		if not hum or hum.Health <= 0 then
			continue
		end
		local d = _distFlat(origin, hrp.Position)
		if d < bestDist then
			bestDist = d
			bestPart = hrp
			bestUid = plr.UserId
		end
	end
	return bestPart, bestUid
end

--[[
	仅朝向目标（不位移）；写 entity._desiredLook，由 integrate 在无 goal 时消费。
	小角度变化清意图，避免环带站桩每帧脏同步。
	@param rec any - LogicalRecord
	@param lookAt Vector3 - 朝向点
]]
local function _faceToward(rec: any, lookAt: Vector3)
	local entity = rec.entity
	if type(entity) ~= "table" then
		return
	end
	local pos = rec.cframe.Position
	local flat = Vector3.new(lookAt.X - pos.X, 0, lookAt.Z - pos.Z)
	if flat.Magnitude < 1e-4 then
		return
	end
	local look = flat.Unit
	local cur = Vector3.new(rec.cframe.LookVector.X, 0, rec.cframe.LookVector.Z)
	if cur.Magnitude > 1e-4 then
		cur = cur.Unit
		if cur:Dot(look) > 0.995 then
			entity._desiredLook = nil
			return
		end
	end
	entity._desiredLook = look
end

--[[
	进入 Idle
	@param entity any - AI 态
	@param cfg any - 运行时配置
]]
local function _enterIdle(entity: any, cfg: any)
	entity.state = STATE_IDLE
	entity._chaseMode = nil
	entity._desiredPos = nil
	entity._desiredLook = nil
	local span = math.max(0, cfg.idleTimeMax - cfg.idleTimeMin)
	entity.timers.idle = cfg.idleTimeMin + entity.rng:NextNumber() * span
	entity.targetUserId = nil
end

--[[
	进入 Wandering：出生点附近随机点
	@param rec any - LogicalRecord
	@param entity any - AI 态
	@param cfg any - 运行时配置
]]
local function _enterWandering(rec: any, entity: any, cfg: any)
	entity.state = STATE_WANDERING
	entity._chaseMode = nil
	entity._desiredLook = nil
	local span = math.max(0, cfg.wanderTimeMax - cfg.wanderTimeMin)
	entity.timers.wander = cfg.wanderTimeMin + entity.rng:NextNumber() * span
	local angle = entity.rng:NextNumber(0, math.pi * 2)
	local distSpan = math.max(0, cfg.wanderRangeMax - cfg.wanderRangeMin)
	local dist = cfg.wanderRangeMin + entity.rng:NextNumber() * distSpan
	local offset = Vector3.new(math.cos(angle) * dist, 0, math.sin(angle) * dist)
	local goal = entity.spawnPos + offset
	goal = Vector3.new(goal.X, rec.cframe.Position.Y, goal.Z)
	entity._desiredPos = goal
end

--[[
	进入 Chasing
	@param entity any - AI 态
	@param userId number - 目标玩家 UserId
]]
local function _enterChasing(entity: any, userId: number)
	entity.state = STATE_CHASING
	entity.targetUserId = userId
	entity._chaseMode = "hold"
	entity._desiredPos = nil
end

--[[
	Chasing：环带风筝；滞后切换 + 目标节流，避免边界每帧 approach/retreat/hold 抖动
	@param rec any - LogicalRecord
	@param entity any - AI 态
	@param cfg any - 运行时配置
	@param targetPos Vector3 - 目标世界坐标
]]
local function _updateChaseMove(rec: any, entity: any, cfg: any, targetPos: Vector3)
	local pos = rec.cframe.Position
	local dist = _distFlat(pos, targetPos)
	local safe = cfg.rangerSafeDistance
	local atk = cfg.attackRange
	local mode = entity._chaseMode
	if type(mode) ~= "string" then
		mode = "hold"
	end

	-- 滞后：离开当前模式才切换，防止在 safe/atk 边界抖
	if mode == "approach" then
		if dist <= atk * 0.88 then
			mode = "hold"
		end
	elseif mode == "retreat" then
		-- 略大于 safe 即收束，避免 goal 落在安全圈上反复 Arrive→idle→再走
		if dist >= safe * 1.05 then
			mode = "hold"
		end
	else
		if dist > atk then
			mode = "approach"
		elseif dist < safe then
			mode = "retreat"
		else
			mode = "hold"
		end
	end
	entity._chaseMode = mode

	if mode == "approach" then
		entity._desiredLook = nil
		-- 直接追玩家；由滞后切 hold，勿把 goal 钉在攻击环上（会 Arrive 清目标导致顿挫）
		local goal = Vector3.new(targetPos.X, pos.Y, targetPos.Z)
		local prev = entity._desiredPos
		if typeof(prev) == "Vector3" and _distFlat(prev, goal) < 2.0 then
			return
		end
		entity._desiredPos = goal
	elseif mode == "retreat" then
		entity._desiredLook = nil
		local dir = Vector3.new(pos.X - targetPos.X, 0, pos.Z - targetPos.Z)
		if dir.Magnitude < 1e-4 then
			dir = Vector3.new(rec.cframe.LookVector.X, 0, rec.cframe.LookVector.Z)
			if dir.Magnitude < 1e-4 then
				dir = Vector3.new(0, 0, -1)
			else
				dir = dir.Unit
			end
		else
			dir = dir.Unit
		end
		-- 目标略超安全距，先被滞后收成 hold，减少环上 Arrive 抖动
		local goal = targetPos + dir * (safe * 1.2)
		goal = Vector3.new(goal.X, pos.Y, goal.Z)
		local prev = entity._desiredPos
		if typeof(prev) == "Vector3" and _distFlat(prev, goal) < 1.5 then
			return
		end
		entity._desiredPos = goal
	else
		-- 环带内站桩朝向
		entity._desiredPos = nil
		_faceToward(rec, targetPos)
	end
end

--[[
	装配 Ranger entity 到记录
	@param rec any - LogicalRecord（须已 put）
	@param cfg table - enemyConf 行
	@return any - entity
]]
function RangerAi.assemble(rec: any, cfg: any): any
	local runtimeCfg = _buildConfig(cfg or {})
	local entity = {
		ai = "Ranger",
		state = STATE_IDLE,
		spawnPos = rec.cframe.Position,
		walkSpeed = runtimeCfg.walkSpeed,
		chaseSpeedMul = runtimeCfg.chaseSpeedMul,
		moveState = "idle",
		timers = { idle = 0, wander = 0 },
		targetUserId = nil,
		_logicalGoal = nil,
		_desiredPos = nil,
		_desiredLook = nil,
		_driveMode = "Auto",
		cfg = runtimeCfg,
		rng = Random.new(rec.id * 997 + rec.cfgId),
		-- 浮空权重（配表可选；缺省 Medium；SuperHeavy 禁飞）
		airWeight = if type(cfg.airWeight) == "string" and cfg.airWeight ~= "" then cfg.airWeight else "Medium",
		launchArmor = math.max(0, tonumber(cfg.launchArmor) or 0),
		_armorRemain = nil,
	}
	rec.entity = entity
	_enterIdle(entity, runtimeCfg)
	return entity
end

--[[
	是否为本模块可驱动的实体
	@param rec any - LogicalRecord
	@return boolean - true 表示 entity.ai == "Ranger"
]]
function RangerAi.isRanger(rec: any): boolean
	local entity = rec and rec.entity
	return type(entity) == "table" and entity.ai == "Ranger"
end

--[[
	一帧 AI（不含位移积分）
	@param rec any - LogicalRecord
	@param dt number - 帧间隔秒
]]
function RangerAi.step(rec: any, dt: number)
	if not rec or not rec.alive or not RangerAi.isRanger(rec) then
		return
	end
	local entity = rec.entity
	local cfg = entity.cfg
	local dtClamped = math.clamp(tonumber(dt) or 0, 0, 0.1)
	if dtClamped <= 0 then
		return
	end

	local pos = rec.cframe.Position

	if entity.state == STATE_IDLE then
		entity.timers.idle -= dtClamped
		if cfg.proactiveDetection then
			local targetPart, uid = _findNearestTarget(rec, pos, cfg.detectionRange)
			if targetPart and uid then
				_enterChasing(entity, uid)
				_updateChaseMove(rec, entity, cfg, targetPart.Position)
				return
			end
		end
		if entity.timers.idle <= 0 then
			_enterWandering(rec, entity, cfg)
		end
		return
	end

	if entity.state == STATE_WANDERING then
		entity.timers.wander -= dtClamped
		if cfg.proactiveDetection then
			local targetPart, uid = _findNearestTarget(rec, pos, cfg.detectionRange)
			if targetPart and uid then
				_enterChasing(entity, uid)
				_updateChaseMove(rec, entity, cfg, targetPart.Position)
				return
			end
		end
		if entity.timers.wander <= 0 or entity._desiredPos == nil then
			_enterIdle(entity, cfg)
		end
		return
	end

	if entity.state == STATE_CHASING then
		local uid = entity.targetUserId
		local plr = uid and Players:GetPlayerByUserId(uid)
		local hrp = plr and plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
		local hum = plr and plr.Character and plr.Character:FindFirstChildOfClass("Humanoid")
		if not plr or not hrp or not hrp:IsA("BasePart") or not hum or hum.Health <= 0 then
			_enterIdle(entity, cfg)
			return
		end
		if not _canInteract(rec, uid) then
			_enterIdle(entity, cfg)
			return
		end
		local dist = _distFlat(pos, hrp.Position)
		if dist > cfg.patientRange then
			_enterIdle(entity, cfg)
			return
		end
		_updateChaseMove(rec, entity, cfg, hrp.Position)
	end
end

return RangerAi
