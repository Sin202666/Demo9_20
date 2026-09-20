--[[
	Module: LogicalAirborne
	Description: 逻辑怪浮空控制（Launch/Juggle/Fall/Land；对照鬼泣5怪物侧；经 EnemySim 步进）
	Author: 林奥宇
	Created: 2026-08-17
	Last Modified: 2026-08-28

	功能：
	- tryApplyFromHitbox：Hit 后分流 Launch / Juggle / Slam；空中命中即使用地面击退档名也 Juggle
	- applyLaunch / applyJuggle / applySlam / applyHorizontalImpulse
	- step：EnemySim 批处理积分 Y+水平；浮空期间不贴地；落地再 snap
	- isActive / isAirLocked / cancel

	模块关系：
	- LogicalAirborneProfile：PhysicsEffectName → 动力学参数
	- HitResolver.applyLogicalEnemyHit：优先本模块，未处理再 LogicalDisplace
	- EnemySim.step：Airborne.step 优先于 Displace；isAirLocked 跳过 AI
	- LogicEntityMotion：读 _airLockUntil；浮空时不得 integrate 贴地
	- LogicalDisplace：Launch 前 cancel 地面击退

	约束：
	- 仅服务端仿真路径调用（由 HitResolver / EnemySim 保证；无 IsServer 业务分支）
	- 禁止每怪 Heartbeat；不进 StatusEffect Phase（O1）
	- 浮空中水平冲量不取消 Airborne（O2）
	- 首包不做玩家 Enemy Step

	加载：
		local LogicalAirborne = Utils.LogicalAirborne
		LogicalAirborne.tryApplyFromHitbox(logicalId, hitbox)
		if LogicalAirborne.step(rec, dt) then continue end
]]

local Workspace = game:GetService("Workspace")

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local EnemyLogicalStore = Utils.EnemyLogicalStore
local LogicEntityMotion = Utils.LogicEntityMotion
local LogicalAirborneProfile = Utils.LogicalAirborneProfile
local LogicalDisplace = Utils.LogicalDisplace
local LogicalDisplaceProfile = Utils.LogicalDisplaceProfile

local LogicalAirborne = {}

--============================================================================--
-- 常量
--============================================================================--

local MIN_DIR_EPSILON = 1e-4
local MIN_DT = 0
local MAX_DT = 0.1
local LAND_Y_EPS = 0.12
local STATE_LAUNCHING = "Launching"
local STATE_FLOATING = "Floating"
local STATE_FALLING = "Falling"

local WEIGHT_MUL: { [string]: number } = {
	Light = 0.85,
	Medium = 1,
	Heavy = 1.35,
	SuperHeavy = 0, -- 0 = 禁飞
}

local DEFAULT_WEIGHT = "Medium"

--============================================================================--
-- 私有：时间 / 方向 / 权重
--============================================================================--

--[[
	当前服务端时间
	@return number - Workspace:GetServerTimeNow()
]]
local function _now(): number
	return Workspace:GetServerTimeNow()
end

--[[
	水平单位方向
	@param direction Vector3? - 原始方向；非 Vector3 则 nil
	@return Vector3? - 平面单位向量；退化返回 nil
]]
local function _flatUnit(direction: Vector3?): Vector3?
	if typeof(direction) ~= "Vector3" then
		return nil
	end
	local flat = Vector3.new(direction.X, 0, direction.Z)
	if flat.Magnitude < MIN_DIR_EPSILON then
		return nil
	end
	return flat.Unit
end

--[[
	从 hitbox 解析水平推开方向
	@param hitbox any - 技能 Hitbox（可含 getWorldCenter / hitbox Part）
	@param targetPos Vector3 - 目标权威中心
	@return Vector3? - 平面单位推开方向
]]
local function _resolveDirectionFromHitbox(hitbox: any, targetPos: Vector3): Vector3?
	local hitboxPos: Vector3? = nil
	if hitbox and hitbox.getWorldCenter then
		hitboxPos = hitbox:getWorldCenter()
	else
		local hitboxPart = hitbox and hitbox.hitbox
		if hitboxPart and typeof(hitboxPart) == "Instance" and hitboxPart:IsA("BasePart") then
			hitboxPos = hitboxPart.Position
		end
	end
	if not hitboxPos then
		return nil
	end
	return _flatUnit(Vector3.new(targetPos.X - hitboxPos.X, 0, targetPos.Z - hitboxPos.Z))
end

--[[
	解析体重倍率；SuperHeavy 返回 nil 表示禁飞
	@param entity any - AI 态（读 airWeight）
	@return number? - 倍率；nil = 不可 Launch
]]
local function _getWeightMul(entity: any): number?
	local w = DEFAULT_WEIGHT
	if type(entity) == "table" and type(entity.airWeight) == "string" and entity.airWeight ~= "" then
		w = entity.airWeight
	end
	local mul = WEIGHT_MUL[w]
	if mul == nil then
		mul = WEIGHT_MUL[DEFAULT_WEIGHT]
	end
	if mul == nil or mul <= 0 then
		return nil
	end
	return mul
end

--[[
	装甲是否仍阻止击飞（消耗 1 层）
	@param entity any - AI 态（读 _armorRemain / launchArmor）
	@return boolean - true = 本击仍被装甲吸收，不可飞
]]
local function _consumeArmorBlock(entity: any): boolean
	local remain = tonumber(entity._armorRemain)
	if remain == nil then
		remain = tonumber(entity.launchArmor) or 0
		entity._armorRemain = remain
	end
	if remain > 0 then
		entity._armorRemain = remain - 1
		return true
	end
	return false
end

--[[
	确保 entity 表存在
	@param rec any - LogicalRecord
	@return any - rec.entity 表
]]
local function _ensureEntity(rec: any): any
	local entity = rec.entity
	if type(entity) ~= "table" then
		entity = {}
		rec.entity = entity
	end
	return entity
end

--[[
	写权威位姿（浮空：不贴地；保持水平朝向）
	@param rec any - LogicalRecord
	@param nextPos Vector3 - 下一帧中心（含空中 Y）
]]
local function _writePoseAir(rec: any, nextPos: Vector3)
	local look = rec.cframe.LookVector
	local flatLook = Vector3.new(look.X, 0, look.Z)
	if flatLook.Magnitude < MIN_DIR_EPSILON then
		flatLook = Vector3.new(0, 0, -1)
	else
		flatLook = flatLook.Unit
	end
	local cf = CFrame.lookAt(nextPos, nextPos + flatLook)
	EnemyLogicalStore.setCFrame(rec.id, cf)
end

--[[
	落地写姿（贴地）
	@param rec any - LogicalRecord
	@param nextPos Vector3 - 落地前中心（Y 将被 snap）
]]
local function _writePoseLand(rec: any, nextPos: Vector3)
	local look = rec.cframe.LookVector
	local flatLook = Vector3.new(look.X, 0, look.Z)
	if flatLook.Magnitude < MIN_DIR_EPSILON then
		flatLook = Vector3.new(0, 0, -1)
	else
		flatLook = flatLook.Unit
	end
	local y = LogicEntityMotion.snapGroundY(rec, nextPos)
	local pos = Vector3.new(nextPos.X, y, nextPos.Z)
	EnemyLogicalStore.setCFrame(rec.id, CFrame.lookAt(pos, pos + flatLook))
end

--[[
	武装空锁（锁 AI）
	@param entity any - AI 态
	@param untilT number - 锁截止的服务端时间
]]
local function _armAirLock(entity: any, untilT: number)
	entity._airLockUntil = untilT
	entity._logicalGoal = nil
	entity._chaseMode = nil
end

--[[
	按 moveState 标记脏同步
	@param rec any - LogicalRecord
	@param entity any - AI 态
	@param moveState string - 表现层移动态
]]
local function _setMoveState(rec: any, entity: any, moveState: string)
	if entity.moveState ~= moveState then
		entity.moveState = moveState
		rec.dirtyTransform = true
	end
end

--============================================================================--
-- 公共：查询 / 取消
--============================================================================--

--[[
	取消浮空会话
	@param rec any - LogicalRecord
]]
function LogicalAirborne.cancel(rec: any)
	if type(rec) ~= "table" then
		return
	end
	local entity = rec.entity
	if type(entity) ~= "table" then
		return
	end
	entity._air = nil
	entity._airGen = (entity._airGen or 0) + 1
	entity._airLockUntil = nil
end

--[[
	是否处于浮空仿真中
	@param rec any - LogicalRecord
	@return boolean - true 表示 _air 会话仍在
]]
function LogicalAirborne.isActive(rec: any): boolean
	if type(rec) ~= "table" then
		return false
	end
	local entity = rec.entity
	if type(entity) ~= "table" then
		return false
	end
	local air = entity._air
	return type(air) == "table" and type(air.state) == "string"
end

--[[
	浮空或落地硬直锁：禁止 AI / 贴地 integrate
	@param rec any - LogicalRecord
	@return boolean - true 表示应跳过 Ranger 与 integrate
]]
function LogicalAirborne.isAirLocked(rec: any): boolean
	if LogicalAirborne.isActive(rec) then
		return true
	end
	if type(rec) ~= "table" then
		return false
	end
	local entity = rec.entity
	if type(entity) ~= "table" then
		return false
	end
	local untilT = entity._airLockUntil
	return type(untilT) == "number" and _now() < untilT
end

--============================================================================--
-- 公共：施加
--============================================================================--

--[[
	施加击飞（地面 → Launching）
	@param rec any - LogicalRecord
	@param params any - AirborneParams
	@param horizontalDir Vector3? - 可选水平漂移方向
	@return boolean - 是否成功
]]
function LogicalAirborne.applyLaunch(rec: any, params: any, horizontalDir: Vector3?): boolean
	if type(rec) ~= "table" or not rec.alive or typeof(rec.id) ~= "number" then
		return false
	end
	if type(params) ~= "table" then
		return false
	end
	local entity = _ensureEntity(rec)
	local weightMul = _getWeightMul(entity)
	if not weightMul then
		return false
	end
	if _consumeArmorBlock(entity) then
		_armAirLock(entity, _now() + 0.12)
		_setMoveState(rec, entity, "idle")
		return false
	end

	local launchVy = (tonumber(params.launchVy) or 0) / weightMul
	if launchVy <= 0 then
		return false
	end

	if LogicalDisplace and LogicalDisplace.cancel then
		LogicalDisplace.cancel(rec)
	end

	local gen = (entity._airGen or 0) + 1
	entity._airGen = gen

	local pos = rec.cframe.Position
	local groundY = LogicEntityMotion.snapGroundY(rec, pos)
	local drift = tonumber(params.horizontalDrift) or 0
	local dir = _flatUnit(horizontalDir)
	local vxz = Vector3.zero
	if dir and drift > 0 then
		vxz = dir * drift
	end

	entity._air = {
		gen = gen,
		state = STATE_LAUNCHING,
		vy = launchVy,
		vxz = vxz,
		floatRemain = tonumber(params.floatSec) or 0.4,
		juggleCount = 0,
		groundY0 = groundY,
		gravity = tonumber(params.gravity) or 50,
		floatGravityMul = tonumber(params.floatGravityMul) or 0.25,
		maxHeight = tonumber(params.maxHeight) or 15,
		juggleVy = tonumber(params.juggleVy) or 5,
		juggleFloatAdd = tonumber(params.juggleFloatAdd) or 0.14,
		landLockSec = tonumber(params.landLockSec) or 0.2,
		horizontalDrift = drift,
	}
	_armAirLock(entity, _now() + 30) -- 浮空全程锁；落地时改写
	_setMoveState(rec, entity, "air_launch")
	rec.dirtyTransform = true
	return true
end

--[[
	空中连段：续 float、小抬升；可叠加水平冲量（O2）
	@param rec any - LogicalRecord
	@param params any - AirborneParams
	@param horizontalDir Vector3? - 水平冲量方向
	@return boolean - 是否成功进入/续上浮空
]]
function LogicalAirborne.applyJuggle(rec: any, params: any, horizontalDir: Vector3?): boolean
	if type(rec) ~= "table" or not rec.alive then
		return false
	end
	if type(params) ~= "table" then
		return false
	end
	local entity = _ensureEntity(rec)
	local air = entity._air
	if type(air) ~= "table" then
		-- 不在空中则退化为轻击飞
		return LogicalAirborne.applyLaunch(rec, params, horizontalDir)
	end

	local weightMul = _getWeightMul(entity) or 1
	local n = (tonumber(air.juggleCount) or 0) + 1
	air.juggleCount = n
	local decay = math.pow(0.85, math.max(n - 1, 0))
	local addFloat = (tonumber(params.juggleFloatAdd) or air.juggleFloatAdd or 0.14) * decay
	local juggleVy = ((tonumber(params.juggleVy) or air.juggleVy or 5) / weightMul) * decay

	air.floatRemain = math.max(tonumber(air.floatRemain) or 0, 0) + addFloat
	air.vy = math.max(tonumber(air.vy) or 0, 0) + juggleVy
	air.state = STATE_LAUNCHING
	air.gravity = tonumber(params.gravity) or air.gravity
	air.floatGravityMul = tonumber(params.floatGravityMul) or air.floatGravityMul
	air.maxHeight = tonumber(params.maxHeight) or air.maxHeight
	air.landLockSec = tonumber(params.landLockSec) or air.landLockSec

	local drift = tonumber(params.horizontalDrift) or air.horizontalDrift or 0
	local dir = _flatUnit(horizontalDir)
	if dir and drift > 0 then
		-- O2：叠加水平冲量，不取消浮空
		local impulse = dir * drift
		local cur = if typeof(air.vxz) == "Vector3" then air.vxz else Vector3.zero
		air.vxz = cur + impulse
	end

	_armAirLock(entity, _now() + 30)
	_setMoveState(rec, entity, "air_float")
	rec.dirtyTransform = true
	return true
end

--[[
	下砸：强制进入 Falling 并加大重力
	@param rec any - LogicalRecord
	@param params any - AirborneParams
	@return boolean - 是否成功强制下落
]]
function LogicalAirborne.applySlam(rec: any, params: any): boolean
	if type(rec) ~= "table" or not rec.alive then
		return false
	end
	local entity = _ensureEntity(rec)
	local air = entity._air
	if type(air) ~= "table" then
		return false
	end
	air.state = STATE_FALLING
	air.vy = math.min(tonumber(air.vy) or 0, -2)
	air.floatRemain = 0
	air.gravity = math.max(tonumber(params and params.gravity) or 90, 60)
	air.landLockSec = tonumber(params and params.landLockSec) or air.landLockSec or 0.28
	_setMoveState(rec, entity, "air_fall")
	rec.dirtyTransform = true
	return true
end

--[[
	仅水平冲量（浮空中短击退，不改 Y 状态）
	@param rec any - LogicalRecord
	@param direction Vector3 - 水平方向
	@param speed number - stud/s 冲量大小
	@return boolean - 是否成功叠加水平速度
]]
function LogicalAirborne.applyHorizontalImpulse(rec: any, direction: Vector3, speed: number): boolean
	if not LogicalAirborne.isActive(rec) then
		return false
	end
	local dir = _flatUnit(direction)
	local spd = tonumber(speed) or 0
	if not dir or spd <= 0 then
		return false
	end
	local entity = rec.entity
	local air = entity._air
	local cur = if typeof(air.vxz) == "Vector3" then air.vxz else Vector3.zero
	air.vxz = cur + dir * spd
	return true
end

--[[
	命中盒入口：浮空分流；未处理返回 false 供 Displace 接手
	@param logicalId number - 逻辑怪 id
	@param hitbox any - 含 hitPhysicsEffectName
	@return boolean - true 表示本模块已处理（含装甲吞击）
]]
function LogicalAirborne.tryApplyFromHitbox(logicalId: number, hitbox: any): boolean
	if typeof(logicalId) ~= "number" or not hitbox then
		return false
	end
	local rec = EnemyLogicalStore.get(logicalId)
	if not rec or not rec.alive then
		return false
	end

	local profileName = hitbox.hitPhysicsEffectName
	local airParams = nil
	if type(profileName) == "string" and profileName ~= "" and LogicalAirborneProfile then
		airParams = LogicalAirborneProfile.fromPhysicsName(profileName)
	end

	local direction = _resolveDirectionFromHitbox(hitbox, rec.cframe.Position)
	local airborne = LogicalAirborne.isActive(rec)

	-- 空中：优先 Juggle / Slam；无浮空档也用默认 Juggle（A2）
	if airborne then
		if airParams and airParams.kind == "Slam" then
			LogicalAirborne.applySlam(rec, airParams)
			return true
		end
		local juggleParams = airParams or (LogicalAirborneProfile and LogicalAirborneProfile.getDefaultJuggle())
		if juggleParams then
			LogicalAirborne.applyJuggle(rec, juggleParams, direction)
		end
		-- O2：地面击退档名在空中时额外水平冲量
		if not airParams and type(profileName) == "string" and LogicalDisplaceProfile then
			local d = LogicalDisplaceProfile.fromPhysicsName(profileName)
			if d and direction then
				local dist = tonumber(d.distance) or 0
				local dur = tonumber(d.duration) or 0.2
				if dist > 0 and dur > 0 then
					LogicalAirborne.applyHorizontalImpulse(rec, direction, dist / dur * 0.35)
				end
			end
		end
		return true
	end

	-- 地面：仅浮空档可 Launch
	if not airParams then
		return false
	end
	if airParams.kind == "Slam" then
		return false
	end

	local entity = _ensureEntity(rec)
	-- SuperHeavy 禁飞：交还 Displace 做地面击退
	if not _getWeightMul(entity) then
		return false
	end

	if airParams.kind == "Juggle" then
		-- 地面打到「空中连段」档：当轻击飞
		airParams = table.clone(airParams)
		airParams.kind = "Launch"
	end

	_armAirLock(entity, _now() + 0.05)
	entity._logicalGoal = nil
	_setMoveState(rec, entity, "idle")

	task.defer(function()
		local latest = EnemyLogicalStore.get(logicalId)
		if not latest or not latest.alive then
			return
		end
		LogicalAirborne.applyLaunch(latest, airParams, direction)
	end)
	return true
end

--============================================================================--
-- 公共：步进
--============================================================================--

--[[
	EnemySim 批处理浮空积分
	@param rec any - LogicalRecord
	@param dt number - 帧间隔秒
	@return boolean - true 表示本帧由浮空驱动（跳过 AI/贴地）
]]
function LogicalAirborne.step(rec: any, dt: number): boolean
	if type(rec) ~= "table" or not rec.alive then
		return false
	end
	local entity = rec.entity
	if type(entity) ~= "table" then
		return false
	end
	local air = entity._air
	if type(air) ~= "table" then
		return false
	end
	if entity._airGen ~= air.gen then
		entity._air = nil
		return false
	end

	local dtClamped = math.clamp(tonumber(dt) or 0, MIN_DT, MAX_DT)
	if dtClamped <= 0 then
		return true
	end

	local pos = rec.cframe.Position
	local groundY = LogicEntityMotion.snapGroundY(rec, pos)
	local gravity = tonumber(air.gravity) or 50
	local maxHeight = tonumber(air.maxHeight) or 15
	local groundY0 = tonumber(air.groundY0) or groundY

	-- 水平：挡墙截断
	local vxz = if typeof(air.vxz) == "Vector3" then air.vxz else Vector3.zero
	local horizStep = Vector3.new(vxz.X, 0, vxz.Z) * dtClamped
	local horizMag = Vector3.new(horizStep.X, 0, horizStep.Z).Magnitude
	if horizMag > MIN_DIR_EPSILON then
		local hDir = Vector3.new(horizStep.X, 0, horizStep.Z).Unit
		local allowed = LogicEntityMotion.clampStepByWall(rec, pos, hDir, horizMag)
		pos = Vector3.new(pos.X + hDir.X * allowed, pos.Y, pos.Z + hDir.Z * allowed)
		-- 轻微阻尼，避免空中无限横漂
		air.vxz = vxz * math.max(0, 1 - 1.8 * dtClamped)
	end

	local vy = tonumber(air.vy) or 0
	local state = air.state

	if state == STATE_LAUNCHING then
		local g = gravity
		vy -= g * dtClamped
		pos = Vector3.new(pos.X, pos.Y + vy * dtClamped, pos.Z)
		-- 封顶
		if pos.Y - groundY0 > maxHeight then
			pos = Vector3.new(pos.X, groundY0 + maxHeight, pos.Z)
			vy = math.min(vy, 0)
		end
		air.vy = vy
		if vy <= 0 then
			air.state = STATE_FLOATING
			_setMoveState(rec, entity, "air_float")
		else
			_setMoveState(rec, entity, "air_launch")
		end
	elseif state == STATE_FLOATING then
		local g = gravity * (tonumber(air.floatGravityMul) or 0.25)
		vy -= g * dtClamped
		air.floatRemain = (tonumber(air.floatRemain) or 0) - dtClamped
		pos = Vector3.new(pos.X, pos.Y + vy * dtClamped, pos.Z)
		if pos.Y - groundY0 > maxHeight then
			pos = Vector3.new(pos.X, groundY0 + maxHeight, pos.Z)
			vy = math.min(vy, 0)
		end
		air.vy = vy
		_setMoveState(rec, entity, "air_float")
		if (air.floatRemain or 0) <= 0 then
			air.state = STATE_FALLING
			_setMoveState(rec, entity, "air_fall")
		end
	else
		-- Falling
		vy -= gravity * dtClamped
		air.vy = vy
		pos = Vector3.new(pos.X, pos.Y + vy * dtClamped, pos.Z)
		_setMoveState(rec, entity, "air_fall")
	end

	-- 触地
	if pos.Y <= groundY + LAND_Y_EPS and (air.state == STATE_FALLING or vy <= 0) then
		_writePoseLand(rec, pos)
		local landLock = tonumber(air.landLockSec) or 0.2
		entity._air = nil
		entity._airGen = (entity._airGen or 0) + 1
		_armAirLock(entity, _now() + landLock)
		_setMoveState(rec, entity, "idle")
		rec.dirtyTransform = true
		return true
	end

	_writePoseAir(rec, pos)
	rec.dirtyTransform = true
	return true
end

return LogicalAirborne