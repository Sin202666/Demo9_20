--[[
	Module: MountRootDriver
	Description: GroundMount DriveMode=MountRoot（B）：马为物理根，玩家上鞍；托雷特主从
	Author: 林奥宇
	Created: 2026-08-27
	Last Modified: 2026-08-28

	与 GroundMountDriver（HumanoidHost / A）对照：
	- A：Humanoid:Move 推人，马焊在人上
	- B：写马物理根速度/偏航，人 PlatformStand + 焊鞍；不走 CMS 日常走路

	能力（v1+ / D.9 / Phase 1.5 P1）：
	- 偏航：AlignOrientation 追逻辑 yaw（限速步进）；禁每帧 CFrame 拧朝向
	- 后蹄枢轴：用 ω×r 切向速叠加，不再位移瞬移
	- 地面巡航：水平幅度≈cruise×throttle；缓弯不 × turnAlign；近正交才涌现掉速
	- Walk/Gallop：满油蓄力才进顶速；Walk 帽 cruise×WalkSpeedMul
	- 两段减速：松杆先滑（SlipDecelSec）后刹（BrakeDecelSec）
	- 提交式地面 180、二段跳 Redirect/Flip 改向（与 A 同口径）
	- 首跳 Takeoff Marker、空中减重力；空中水平软保速 / Coast / LeapPush
	- 落地：边沿收态 + 锁 Y + 短时水平顿挫；须曾真正离地
	- 地面高度：上鞍一次性 CFrame；运行时只在大误差/移动时用 Y 速度跟，待机锁死防抖
	- MountPresentation.attachRoot + 步态 Idle/Walk·Run/Jump；MountActive 总闸

	加载：由 SystemMount 按 ExtJson.DriveMode=MountRoot 工厂创建
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local ActionArbiter = Utils.ActionArbiter
local EnumMgr = Utils.EnumMgr
local HttpService = Utils.HttpService
local Players = Utils.Players
local UserInputService = Utils.UserInputService
local Workspace = workspace

local MountPresentation = require(script.Parent.Parent.MountPresentation)

local MountRootDriver = {}
MountRootDriver.__index = MountRootDriver

local MOUNT_FACING_OWNER_ID = "Mount:RootFacing"
local MOUNT_ACTIVE_ATTR = "MountActive"
local MOVE_INPUT_THRESHOLD = 0.08
local BASE_CRUISE_SPEED = 16

local DEFAULT_ACCEL_SEC = 0.9
local DEFAULT_DECEL_SEC = 1.35
-- Walk 顶速占 Gallop 巡航的比例；满油须蓄力才进 Gallop
local DEFAULT_WALK_SPEED_MUL = 0.42
local DEFAULT_GALLOP_ENTER_THROTTLE = 0.82
local DEFAULT_GALLOP_ENTER_HOLD_SEC = 0.55
local DEFAULT_GALLOP_EXIT_THROTTLE = 0.28
local DEFAULT_BRAKE_SPEED01 = 0.36
local GAIT_WALK = "Walk"
local GAIT_GALLOP = "Gallop"
-- 贴地：死区内交给碰撞静置；超差才用速度跟（禁每帧 CFrame）
local HOOF_DEADZONE = 0.22
local HOOF_STEP_FORCE = 0.55
local HOOF_SEEK_GAIN = 10
local HOOF_SEEK_MAX = 14
local IDLE_REST_FLAT_SPEED = 0.45
local DEFAULT_TURN_RATE_DEG = 220
local DEFAULT_TURN_HIGH_SPEED_MUL = 0.38
local DEFAULT_TURN_SPEED_POW = 1.35
local DEFAULT_TURN_ALIGN_MIN = 0.65
local DEFAULT_TURN_ALIGN_POW = 1.1
local DEFAULT_TURN_CRUISE_DOT = 0.85
local DEFAULT_TURN_PIVOT_BACK = 3.5
-- 左右换向时后轴短窗衰减，避免大枢轴 CFrame 反向拧出横晃
local TURN_PIVOT_REVERSE_BLEND_SEC = 0.14
-- 过严（~-1）导致点 S 难触发；对齐 A 文档常用区间
local DEFAULT_ABOUT_FACE_DOT = -0.75
local DEFAULT_ABOUT_FACE_TRAVEL_DOT = -0.75
local DEFAULT_ABOUT_FACE_COMPLETE_DEG = 12
local DEFAULT_ABOUT_FACE_ALIGN_MIN = 0
local DEFAULT_ABOUT_FACE_TURN_MUL = 2.9
local DEFAULT_ABOUT_FACE_BRAKE = 160
local DEFAULT_ABOUT_FACE_STICK_BACK = 0.9
local DEFAULT_ABOUT_FACE_COOLDOWN_SEC = 0.2
-- 近正交才咬推力（缓弯 / 巡航弧保持满幅度）
local EMERGENT_TURN_ALIGN_DOT = 0.35
-- 落地短时水平衰减（勿靠弹性）
local LAND_STAGGER_SEC = 0.14
local LAND_STAGGER_SPEED_MUL0 = 0.62
-- AlignOrientation 追逻辑 yaw；限速在逻辑侧，约束只负责平滑直立
local YAW_ALIGN_RESPONSIVENESS = 120
local YAW_ALIGN_MAX_TORQUE = 1e8
local DEFAULT_AIR_TURN_MUL = 0.85
local DEFAULT_AIR_FLIP_TURN_MUL = 2.6
local DEFAULT_DOUBLE_JUMP_FLIP_WINDOW_SEC = 0.4
local DEFAULT_AIR_FLIP_VEL_ALIGN = 8
local DEFAULT_DOUBLE_JUMP_VEL_BLEND0 = 0.45
local DEFAULT_DOUBLE_JUMP_REDIRECT_SEC = 0.22
local DEFAULT_JUMP_HEIGHT = 22
local DEFAULT_DOUBLE_JUMP_SPEED = 55
local DEFAULT_DOUBLE_JUMP_MIN_FLAT = 18
local DEFAULT_AIR_GRAVITY_SCALE = 0.72
local DEFAULT_AIR_SPEED_MAINTAIN_SOFT = 0.9
local DEFAULT_AIR_COAST_DECEL = 6
local DEFAULT_FIRST_JUMP_MIN_FLAT = 16
local DEFAULT_FIRST_JUMP_SNAP_FRAC = 0.6
local DEFAULT_FIRST_JUMP_LOOK_ABSORB = 0.08
local DEFAULT_LEAP_PUSH_SEC = 0.24
local DEFAULT_LEAP_PUSH_ACCEL = 55
local DEFAULT_LEAP_PUSH_POW = 1.35
local DEFAULT_LEAP_STAND_PUSH_MUL = 1.2
local DEFAULT_LEAP_GALLOP_PUSH_MUL = 0.45
local DEFAULT_CAN_DOUBLE_JUMP = true
local DEFAULT_DOUBLE_JUMP_AIR_DELAY_SEC = 0.12
local GROUND_RAY_EXTRA = 1.25
local STANDSTILL_SPEED01 = 0.22
-- 落地后短窗强制 Y=0，吃掉接触残余竖直速（与 Hull 无弹性配合）
local LAND_Y_LOCK_SEC = 0.08
-- 有水平速落地时加长锁 Y，压刮地冲量回弹
local LAND_Y_LOCK_SPEED_EXTRA = 0.1
-- B 减重力吃满后，仅靠 √scale 反算仍比 A（Humanoid 再吃高度）偏高；再压有效顶点
local FIRST_JUMP_HEIGHT_MUL = 0.58
-- 二段跳：表速上再乘；减重力下强化「加高」
local DOUBLE_JUMP_VERT_MUL = 1.2
-- 二段跳水平前冲倍率（相对当前水平速/地板取 max 后再乘）
local DOUBLE_JUMP_FLAT_MUL = 2
-- 原地一段跳前冲 = 二段跳水平目标（MinFlat/cruise 地板 × FLAT_MUL）的该比例
local FIRST_JUMP_STAND_OF_DOUBLE_FLAT = 0.6
-- 调试：转向枢轴可视化小方块（定稿后关）
local DEBUG_TURN_PIVOT_MARKER = false
local DEBUG_TURN_PIVOT_SIZE = Vector3.new(0.55, 0.55, 0.55)

export type RootFeel = {
	accelSec: number,
	decelSec: number,
	walkSpeedMul: number,
	gallopEnterThrottle: number,
	gallopEnterHoldSec: number,
	gallopExitThrottle: number,
	walkAccelSec: number,
	gallopAccelSec: number,
	slipDecelSec: number,
	brakeDecelSec: number,
	brakeSpeed01: number,
	doubleJumpAirDelaySec: number,
	turnRateDeg: number,
	turnHighSpeedMul: number,
	turnSpeedPow: number,
	turnAlignMin: number,
	turnAlignPow: number,
	turnCruiseDot: number,
	turnPivotBackStuds: number,
	aboutFaceDot: number,
	aboutFaceTravelDot: number,
	aboutFaceCompleteDeg: number,
	aboutFaceAlignMin: number,
	aboutFaceTurnMul: number,
	aboutFaceBrake: number,
	aboutFaceStickBack: number,
	aboutFaceCooldownSec: number,
	airTurnMul: number,
	airFlipTurnMul: number,
	doubleJumpFlipWindowSec: number,
	airFlipVelAlign: number,
	doubleJumpVelBlend0: number,
	doubleJumpRedirectSec: number,
	jumpHeight: number,
	canDoubleJump: boolean,
	doubleJumpSpeed: number,
	doubleJumpMinFlat: number,
	airGravityScale: number,
	airSpeedMaintainSoft: number,
	airCoastDecel: number,
	firstJumpMinFlat: number,
	firstJumpSnapFrac: number,
	firstJumpLookAbsorb: number,
	leapPushSec: number,
	leapPushAccel: number,
	leapPushPow: number,
	leapStandPushMul: number,
	leapGallopPushMul: number,
	cruiseSpeed: number,
}

--[[
	取 ControlModule
	运行时 require PlayerModule（非 Utils 静态模块；pcall 防缺脚本）
	@return any? - ControlModule
]]
local function _getControlModule(): any?
	local player = Players.LocalPlayer
	if not player then
		return nil
	end
	local scripts = player:FindFirstChild("PlayerScripts")
	local pmScript = scripts and scripts:FindFirstChild("PlayerModule")
	if not pmScript or not pmScript:IsA("ModuleScript") then
		return nil
	end
	local ok, pm = pcall(require, pmScript)
	if not ok or type(pm) ~= "table" or type(pm.GetControls) ~= "function" then
		return nil
	end
	return pm:GetControls()
end

--[[
	水平单位化
	@param v Vector3 - 向量
	@return Vector3? - 水平单位
]]
local function _flatUnit(v: Vector3): Vector3?
	local flat = Vector3.new(v.X, 0, v.Z)
	if flat.Magnitude < 1e-4 then
		return nil
	end
	return flat.Unit
end

--[[
	偏航弧度
	@param flat Vector3 - 水平方向
	@return number - yaw
]]
local function _yawFromFlat(flat: Vector3): number
	return math.atan2(-flat.X, -flat.Z)
end

--[[
	最短角差
	@param from number - 当前
	@param to number - 目标
	@return number - delta
]]
local function _shortestAngle(from: number, to: number): number
	local d = (to - from + math.pi) % (2 * math.pi) - math.pi
	return d
end

--[[
	解析摇杆世界水平方向与油门；优先 ControlModule.inputMoveVector（已是世界向量，勿再按相机转一次）
	@param controlModule any? - ControlModule
	@param hum Humanoid - 角色（回退 MoveDirection）
	@return (Vector3?, number) - 单位期望朝向、油门 [0,1]
]]
local function _readStickIntent(controlModule: any?, hum: Humanoid): (Vector3?, number)
	if controlModule then
		-- 同帧 ControlModule 已写入的世界空间输入（BindToRenderStep 晚于 Input 时可用）
		local inputMove = controlModule.inputMoveVector
		if typeof(inputMove) == "Vector3" then
			local flat = Vector3.new(inputMove.X, 0, inputMove.Z)
			local mag = flat.Magnitude
			if mag >= MOVE_INPUT_THRESHOLD then
				return flat.Unit, math.clamp(mag, 0, 1)
			end
		end

		if type(controlModule.GetMoveVector) == "function" then
			local raw = controlModule:GetMoveVector()
			if typeof(raw) == "Vector3" then
				local rawFlat = Vector3.new(raw.X, 0, raw.Z)
				local throttle = math.clamp(rawFlat.Magnitude, 0, 1)
				if throttle >= MOVE_INPUT_THRESHOLD then
					local world = raw
					local cameraRelative = true
					local active = controlModule.activeController
					if active and type(active.IsMoveVectorCameraRelative) == "function" then
						cameraRelative = active:IsMoveVectorCameraRelative()
					end
					if cameraRelative and type(controlModule.calculateRawMoveVector) == "function" then
						world = controlModule:calculateRawMoveVector(hum, raw)
					end
					local intent = _flatUnit(world)
					if intent then
						return intent, throttle
					end
				else
					return nil, 0
				end
			end
		end
	end

	local md = hum.MoveDirection
	local intent = _flatUnit(md)
	if intent then
		return intent, math.clamp(md.Magnitude, 0, 1)
	end
	return nil, 0
end

--[[
	解析手感
	@param cfg table - MountCfg
	@return RootFeel - 手感
]]
local function _parseFeel(cfg: { [string]: any }): RootFeel
	local ext: { [string]: any } = {}
	local raw = cfg.ExtJson
	if type(raw) == "string" and raw ~= "" then
		local ok, decoded = pcall(function()
			return HttpService:JSONDecode(raw)
		end)
		if ok and type(decoded) == "table" then
			ext = decoded
		end
	end

	local function _num(key: string, default: number): number
		local v = tonumber(ext[key]) or tonumber(cfg[key])
		if type(v) == "number" and v == v and v > 0 then
			return v
		end
		return default
	end

	local function _unit01(key: string, default: number): number
		local v = tonumber(ext[key]) or tonumber(cfg[key])
		if type(v) == "number" and v == v then
			return math.clamp(v, 0, 1)
		end
		return default
	end

	local canDouble = DEFAULT_CAN_DOUBLE_JUMP
	local canRaw = ext.CanDoubleJump
	if canRaw == false or canRaw == 0 or canRaw == "0" then
		canDouble = false
	elseif canRaw == true or canRaw == 1 or canRaw == "1" then
		canDouble = true
	end

	local speedMul = tonumber(cfg.SpeedMul) or 1
	if speedMul <= 0 then
		speedMul = 1
	end

	local accelSec = _num("AccelSec", DEFAULT_ACCEL_SEC)
	local decelSec = _num("DecelSec", DEFAULT_DECEL_SEC)

	return {
		accelSec = accelSec,
		decelSec = decelSec,
		walkSpeedMul = math.clamp(_unit01("WalkSpeedMul", DEFAULT_WALK_SPEED_MUL), 0.15, 0.85),
		gallopEnterThrottle = math.clamp(_unit01("GallopEnterThrottle", DEFAULT_GALLOP_ENTER_THROTTLE), 0.5, 1),
		gallopEnterHoldSec = math.clamp(_num("GallopEnterHoldSec", DEFAULT_GALLOP_ENTER_HOLD_SEC), 0, 3),
		gallopExitThrottle = math.clamp(_unit01("GallopExitThrottle", DEFAULT_GALLOP_EXIT_THROTTLE), 0.05, 0.7),
		walkAccelSec = _num("WalkAccelSec", math.max(0.2, accelSec * 0.55)),
		gallopAccelSec = _num("GallopAccelSec", accelSec),
		slipDecelSec = _num("SlipDecelSec", decelSec),
		brakeDecelSec = _num("BrakeDecelSec", math.max(0.18, decelSec * 0.4)),
		brakeSpeed01 = math.clamp(_unit01("BrakeSpeed01", DEFAULT_BRAKE_SPEED01), 0.12, 0.7),
		doubleJumpAirDelaySec = math.clamp(_num("DoubleJumpAirDelaySec", DEFAULT_DOUBLE_JUMP_AIR_DELAY_SEC), 0.04, 0.6),
		turnRateDeg = _num("TurnRateDeg", DEFAULT_TURN_RATE_DEG),
		turnHighSpeedMul = math.clamp(_num("TurnHighSpeedMul", DEFAULT_TURN_HIGH_SPEED_MUL), 0.05, 1),
		turnSpeedPow = math.clamp(_num("TurnSpeedPow", DEFAULT_TURN_SPEED_POW), 0.5, 3),
		turnAlignMin = _unit01("TurnAlignMin", DEFAULT_TURN_ALIGN_MIN),
		turnAlignPow = math.clamp(_num("TurnAlignPow", DEFAULT_TURN_ALIGN_POW), 0.25, 4),
		turnCruiseDot = math.clamp(_num("TurnCruiseDot", DEFAULT_TURN_CRUISE_DOT), 0, 1),
		turnPivotBackStuds = math.clamp(_num("TurnPivotBackStuds", DEFAULT_TURN_PIVOT_BACK), 0, 16),
		aboutFaceDot = math.clamp(_num("AboutFaceDot", DEFAULT_ABOUT_FACE_DOT), -1, 0),
		aboutFaceTravelDot = math.clamp(_num("AboutFaceTravelDot", DEFAULT_ABOUT_FACE_TRAVEL_DOT), -1, 0),
		aboutFaceCompleteDeg = math.clamp(_num("AboutFaceCompleteDeg", DEFAULT_ABOUT_FACE_COMPLETE_DEG), 2, 45),
		aboutFaceAlignMin = _unit01("AboutFaceAlignMin", DEFAULT_ABOUT_FACE_ALIGN_MIN),
		aboutFaceTurnMul = math.clamp(_num("AboutFaceTurnMul", DEFAULT_ABOUT_FACE_TURN_MUL), 0.5, 5),
		aboutFaceBrake = math.clamp(_num("AboutFaceBrake", DEFAULT_ABOUT_FACE_BRAKE), 0, 400),
		aboutFaceStickBack = math.clamp(_num("AboutFaceStickBack", DEFAULT_ABOUT_FACE_STICK_BACK), 0.1, 0.95),
		aboutFaceCooldownSec = math.clamp(_num("AboutFaceCooldownSec", DEFAULT_ABOUT_FACE_COOLDOWN_SEC), 0, 3),
		airTurnMul = math.clamp(_num("AirTurnMul", DEFAULT_AIR_TURN_MUL), 0.1, 1.5),
		airFlipTurnMul = math.clamp(_num("AirFlipTurnMul", DEFAULT_AIR_FLIP_TURN_MUL), 0.5, 5),
		doubleJumpFlipWindowSec = math.clamp(_num("DoubleJumpFlipWindowSec", DEFAULT_DOUBLE_JUMP_FLIP_WINDOW_SEC), 0.05, 1),
		airFlipVelAlign = math.clamp(_num("AirFlipVelAlign", DEFAULT_AIR_FLIP_VEL_ALIGN), 1, 30),
		doubleJumpVelBlend0 = math.clamp(_num("DoubleJumpVelBlend0", DEFAULT_DOUBLE_JUMP_VEL_BLEND0), 0, 1),
		doubleJumpRedirectSec = math.clamp(_num("DoubleJumpRedirectSec", DEFAULT_DOUBLE_JUMP_REDIRECT_SEC), 0.05, 1),
		jumpHeight = _num("JumpHeight", DEFAULT_JUMP_HEIGHT),
		canDoubleJump = canDouble,
		doubleJumpSpeed = _num("DoubleJumpSpeed", DEFAULT_DOUBLE_JUMP_SPEED),
		doubleJumpMinFlat = math.clamp(_num("DoubleJumpMinFlat", DEFAULT_DOUBLE_JUMP_MIN_FLAT), 0, 60),
		airGravityScale = math.clamp(_num("AirGravityScale", DEFAULT_AIR_GRAVITY_SCALE), 0.35, 1),
		airSpeedMaintainSoft = _unit01("AirSpeedMaintainSoft", DEFAULT_AIR_SPEED_MAINTAIN_SOFT),
		airCoastDecel = math.clamp(_num("AirCoastDecel", DEFAULT_AIR_COAST_DECEL), 0, 40),
		firstJumpMinFlat = math.clamp(_num("FirstJumpMinFlat", DEFAULT_FIRST_JUMP_MIN_FLAT), 0, 60),
		firstJumpSnapFrac = _unit01("FirstJumpSnapFrac", DEFAULT_FIRST_JUMP_SNAP_FRAC),
		firstJumpLookAbsorb = math.clamp(_unit01("FirstJumpLookAbsorb", DEFAULT_FIRST_JUMP_LOOK_ABSORB), 0, 0.35),
		leapPushSec = math.clamp(_num("LeapPushSec", DEFAULT_LEAP_PUSH_SEC), 0, 0.5),
		leapPushAccel = math.clamp(_num("LeapPushAccel", DEFAULT_LEAP_PUSH_ACCEL), 0, 120),
		leapPushPow = math.clamp(_num("LeapPushPow", DEFAULT_LEAP_PUSH_POW), 0.5, 3),
		leapStandPushMul = math.clamp(_num("LeapStandPushMul", DEFAULT_LEAP_STAND_PUSH_MUL), 0, 2),
		leapGallopPushMul = math.clamp(_num("LeapGallopPushMul", DEFAULT_LEAP_GALLOP_PUSH_MUL), 0, 2),
		cruiseSpeed = BASE_CRUISE_SPEED * speedMul,
	}
end

--[[
	地面步态：满油蓄力进 Gallop，低于退出阈值回 Walk
	@param self MountRootDriver - 驱动
	@param stickMag number - 摇杆幅度 0~1
	@param dt number - 帧时
	@param onGround boolean - 仅地面蓄力/退出
]]
local function _tickGait(self: MountRootDriver, stickMag: number, dt: number, onGround: boolean)
	if not onGround then
		return
	end
	local feel = self._feel
	if not feel then
		return
	end
	if stickMag >= feel.gallopEnterThrottle then
		self._gallopHold = self._gallopHold + dt
		if self._gait ~= GAIT_GALLOP and self._gallopHold >= feel.gallopEnterHoldSec then
			self._gait = GAIT_GALLOP
		end
	else
		self._gallopHold = 0
		if stickMag < feel.gallopExitThrottle then
			self._gait = GAIT_WALK
		end
	end
end

--[[
	油门积分：Walk 帽顶速；Gallop 才爬满巡航；松杆先滑后刹
	@param self MountRootDriver - 驱动
	@param targetThrottle number - 摇杆目标 0~1
	@param dt number - 帧时
]]
local function _tickThrottle(self: MountRootDriver, targetThrottle: number, dt: number)
	local feel = self._feel
	if not feel then
		return
	end
	local cap = if self._gait == GAIT_GALLOP then 1 else feel.walkSpeedMul
	local target = math.min(math.clamp(targetThrottle, 0, 1), cap)
	local cur = self._throttle01
	if target > cur then
		local gallopRamp = self._gait == GAIT_GALLOP and cur >= (feel.walkSpeedMul * 0.92)
		local accelSec = if gallopRamp then feel.gallopAccelSec else feel.walkAccelSec
		local rate = 1 / math.max(accelSec, 0.05)
		self._throttle01 = math.min(target, cur + rate * dt)
	else
		local slip = cur > feel.brakeSpeed01
		local decelSec = if slip then feel.slipDecelSec else feel.brakeDecelSec
		local rate = 1 / math.max(decelSec, 0.05)
		self._throttle01 = math.max(target, cur - rate * dt)
	end
end

--[[
	物理根是否贴地（射线）；不等于「运动学已落地」
	@param root BasePart - 物理根
	@return boolean - 射线贴地
]]
local function _isGrounded(root: BasePart): boolean
	local origin = root.Position
	local half = root.Size.Y * 0.5
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { root.Parent :: Instance }
	local result = Workspace:Raycast(origin, Vector3.new(0, -(half + GROUND_RAY_EXTRA), 0), params)
	return result ~= nil
end

--[[
	清空中水平/改向态（不清 _firstJumpPending：地面起跳窗与空中态独立，对齐 A）
	@param self MountRootDriver - 驱动
]]
local function _clearAirFlightState(self: MountRootDriver)
	self._airborneSince = nil
	self._doubleJumpUsed = false
	self._airHoldFlatSpeed = nil
	self._leapPushUntil = nil
	self._leapPushSpeed01 = nil
	self._redirectAim = nil
	self._redirectUntil = nil
	self._airFlipUntil = nil
	self._hasLeftGround = false
end

export type MountRootDriver = typeof(setmetatable({} :: {
	locomotionType: string,
	mountId: number,
	driveMode: string,
	_active: boolean,
	_character: Model?,
	_humanoid: Humanoid?,
	_hrp: BasePart?,
	_root: BasePart?,
	_presentation: any?,
	_feel: RootFeel?,
	_controlModule: any?,
	_savedMoveFunction: any?,
	_facingToken: string?,
	_savedJumpHeight: number?,
	_savedAutoRotate: boolean?,
	_throttle01: number,
	_gait: string,
	_gallopHold: number,
	_doubleJumpUsed: boolean,
	_airborneSince: number?,
	_firstJumpPending: boolean,
	_airHoldFlatSpeed: number?,
	_leapPushUntil: number?,
	_leapPushSpeed01: number?,
	_redirectAim: Vector3?,
	_redirectUntil: number?,
	_airFlipUntil: number?,
	_landYLockUntil: number?,
	_landStaggerUntil: number?,
	_hasLeftGround: boolean,
	_lastYawDeltaSign: number,
	_pivotReverseUntil: number?,
	_pivotTangVel: Vector3?,
	_logicalYaw: number?,
	_yawAttach: Attachment?,
	_yawAlign: AlignOrientation?,
	_aboutFaceActive: boolean,
	_aboutFaceTargetYaw: number?,
	_aboutFaceReadyAt: number,
	_jumpConn: RBXScriptConnection?,
	_airForceAttach: Attachment?,
	_airForce: VectorForce?,
	_pivotMarker: BasePart?,
	_pivotMarkerFull: BasePart?,
}, MountRootDriver))

--[[
	构造
	@param mountId number - mountConf 主键
	@return MountRootDriver - 实例
]]
function MountRootDriver.new(mountId: number): MountRootDriver
	local self = setmetatable({
		locomotionType = EnumMgr.MountLocomotionType.GroundMount,
		mountId = mountId,
		driveMode = EnumMgr.MountDriveMode.MountRoot,
		_active = false,
		_character = nil,
		_humanoid = nil,
		_hrp = nil,
		_root = nil,
		_presentation = nil,
		_feel = nil,
		_controlModule = nil,
		_savedMoveFunction = nil,
		_facingToken = nil,
		_savedJumpHeight = nil,
		_savedAutoRotate = nil,
		_throttle01 = 0,
		_gait = GAIT_WALK,
		_gallopHold = 0,
		_doubleJumpUsed = false,
		_airborneSince = nil,
		_firstJumpPending = false,
		_airHoldFlatSpeed = nil,
		_leapPushUntil = nil,
		_leapPushSpeed01 = nil,
		_redirectAim = nil,
		_redirectUntil = nil,
		_airFlipUntil = nil,
		_landYLockUntil = nil,
		_landStaggerUntil = nil,
		_hasLeftGround = false,
		_lastYawDeltaSign = 0,
		_pivotReverseUntil = nil,
		_pivotTangVel = nil,
		_logicalYaw = nil,
		_yawAttach = nil,
		_yawAlign = nil,
		_aboutFaceActive = false,
		_aboutFaceTargetYaw = nil,
		_aboutFaceReadyAt = 0,
		_jumpConn = nil,
		_airForceAttach = nil,
		_airForce = nil,
		_pivotMarker = nil,
		_pivotMarkerFull = nil,
	}, MountRootDriver)
	return self
end

--[[
	劫持 moveFunction
	@param self MountRootDriver - 驱动
]]
local function _hijackControlMove(self: MountRootDriver)
	local cm = self._controlModule
	if not cm or self._savedMoveFunction ~= nil then
		return
	end
	if type(cm.moveFunction) ~= "function" then
		return
	end
	self._savedMoveFunction = cm.moveFunction
	cm.moveFunction = function(_player: Player, _moveVector: Vector3, _relativeToCamera: boolean) end
end

--[[
	恢复 moveFunction
	@param self MountRootDriver - 驱动
]]
local function _restoreControlMove(self: MountRootDriver)
	local cm = self._controlModule
	if cm and self._savedMoveFunction ~= nil then
		cm.moveFunction = self._savedMoveFunction
	end
	self._savedMoveFunction = nil
end

--[[
	占朝向闸
	@param self MountRootDriver - 驱动
	@param character Model - 角色
]]
local function _acquireFacingGate(self: MountRootDriver, character: Model)
	local arbiter = ActionArbiter.GetForCharacter(character)
	if not arbiter or type(arbiter.Acquire) ~= "function" then
		return
	end
	self._facingToken = arbiter:Acquire({
		ownerId = MOUNT_FACING_OWNER_ID,
		priority = ActionArbiter.Priority.FacingBridge,
		blendPolicy = ActionArbiter.BlendPolicy.FacingOnly,
		reason = "MountRootDriver",
	})
end

--[[
	释放朝向闸
	@param self MountRootDriver - 驱动
	@param character Model? - 角色
]]
local function _releaseFacingGate(self: MountRootDriver, character: Model?)
	if self._facingToken and character then
		local arbiter = ActionArbiter.GetForCharacter(character)
		if arbiter and type(arbiter.Release) == "function" then
			arbiter:Release(self._facingToken)
		end
	elseif character then
		local arbiter = ActionArbiter.GetForCharacter(character)
		if arbiter and type(arbiter.ReleaseByOwner) == "function" then
			arbiter:ReleaseByOwner(MOUNT_FACING_OWNER_ID)
		end
	end
	self._facingToken = nil
end

--[[
	水平速度朝向目标方向软对齐
	@param root BasePart - 物理根
	@param dir Vector3 - 目标水平单位方向
	@param rate number - 每秒对齐比例
	@param dt number - 帧时
]]
local function _alignFlatVelToDir(root: BasePart, dir: Vector3, rate: number, dt: number)
	local aim = _flatUnit(dir)
	if not aim then
		return
	end
	local vel = root.AssemblyLinearVelocity
	local flat = Vector3.new(vel.X, 0, vel.Z)
	local speed = flat.Magnitude
	if speed < 1e-3 then
		return
	end
	local alpha = math.clamp(rate * dt, 0, 1)
	local newFlat = flat:Lerp(aim * speed, alpha)
	root.AssemblyLinearVelocity = Vector3.new(newFlat.X, vel.Y, newFlat.Z)
end

--[[
	提交式 180 时刹水平速
	@param root BasePart - 物理根
	@param brake number - 减速度 stud/s²
	@param dt number - 帧时
]]
local function _applyAboutFaceBrake(root: BasePart, brake: number, dt: number)
	if brake <= 0 then
		return
	end
	local vel = root.AssemblyLinearVelocity
	local flat = Vector3.new(vel.X, 0, vel.Z)
	local speed = flat.Magnitude
	if speed < 1e-3 then
		return
	end
	local newSpeed = math.max(0, speed - brake * dt)
	local newFlat = if newSpeed <= 1e-3 then Vector3.zero else flat.Unit * newSpeed
	root.AssemblyLinearVelocity = Vector3.new(newFlat.X, vel.Y, newFlat.Z)
end

--[[
	是否触发提交式地面 180
	@param feel RootFeel - 手感
	@param look Vector3 - 马头
	@param intent Vector3 - 意图
	@param root BasePart - 物理根
	@return boolean - 可提交
]]
local function _shouldCommitAboutFace(feel: RootFeel, look: Vector3, intent: Vector3, root: BasePart): boolean
	if look:Dot(intent) <= feel.aboutFaceDot then
		return true
	end
	local localIntent = root.CFrame:VectorToObjectSpace(intent)
	if localIntent.Z >= feel.aboutFaceStickBack then
		return true
	end
	local travel = _flatUnit(root.AssemblyLinearVelocity)
	if travel and travel:Dot(intent) <= feel.aboutFaceTravelDot then
		return true
	end
	return false
end

--[[
	开始提交式 180
	@param self MountRootDriver - 驱动
	@param look Vector3 - 马头
	@param intent Vector3 - 意图
]]
local function _beginAboutFace(self: MountRootDriver, look: Vector3, intent: Vector3)
	local targetFlat = intent
	local reverseLook = -look
	if reverseLook:Dot(intent) >= 0.7 then
		targetFlat = reverseLook
	end
	self._aboutFaceActive = true
	self._aboutFaceTargetYaw = _yawFromFlat(targetFlat)
end

--[[
	结束提交式 180
	@param self MountRootDriver - 驱动
]]
local function _endAboutFace(self: MountRootDriver)
	self._aboutFaceActive = false
	self._aboutFaceTargetYaw = nil
	local feel = self._feel
	local cd = if feel then feel.aboutFaceCooldownSec else DEFAULT_ABOUT_FACE_COOLDOWN_SEC
	self._aboutFaceReadyAt = os.clock() + cd
end

--[[
	是否可新开 180
	@param self MountRootDriver - 驱动
	@return boolean - 可提交
]]
local function _canStartAboutFace(self: MountRootDriver): boolean
	return os.clock() >= (self._aboutFaceReadyAt or 0)
end

--[[
	销毁枢轴可视化
	@param self MountRootDriver - 驱动
]]
local function _destroyPivotMarkers(self: MountRootDriver)
	if self._pivotMarker then
		self._pivotMarker:Destroy()
		self._pivotMarker = nil
	end
	if self._pivotMarkerFull then
		self._pivotMarkerFull:Destroy()
		self._pivotMarkerFull = nil
	end
end

--[[
	创建转向枢轴调试方块
	@param name string - Instance 名
	@param color Color3 - 颜色
	@param transparency number - 透明度
	@return BasePart - 方块
]]
local function _makePivotMarker(name: string, color: Color3, transparency: number): BasePart
	local part = Instance.new("Part")
	part.Name = name
	part.Size = DEBUG_TURN_PIVOT_SIZE
	part.Color = color
	part.Material = Enum.Material.Neon
	part.Transparency = transparency
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Parent = Workspace
	return part
end

--[[
	创建转向枢轴可视化
	@param self MountRootDriver - 驱动
]]
local function _setupPivotMarkers(self: MountRootDriver)
	_destroyPivotMarkers(self)
	if not DEBUG_TURN_PIVOT_MARKER then
		return
	end
	-- 亮青：本帧有效枢轴（×speed01）；亮品红：表配满距 TurnPivotBackStuds
	self._pivotMarker = _makePivotMarker("MountTurnPivotEffective", Color3.fromRGB(0, 255, 200), 0.15)
	self._pivotMarkerFull = _makePivotMarker("MountTurnPivotFull", Color3.fromRGB(255, 64, 220), 0.35)
end

--[[
	刷新枢轴方块位置
	@param self MountRootDriver - 驱动
	@param root BasePart - 物理根
	@param look Vector3 - 水平马头
	@param effectiveBack number - 本帧实际后移距
	@param fullBack number - 表配满距
]]
local function _updatePivotMarkers(
	self: MountRootDriver,
	root: BasePart,
	look: Vector3,
	effectiveBack: number,
	fullBack: number
)
	local pos = root.Position
	-- 贴地显示，便于对照蹄位
	local y = pos.Y - root.Size.Y * 0.5 + DEBUG_TURN_PIVOT_SIZE.Y * 0.5
	local lookFlat = _flatUnit(look) or Vector3.new(0, 0, -1)
	local eff = self._pivotMarker
	if eff and eff.Parent then
		local back = math.max(0, effectiveBack)
		eff.CFrame = CFrame.new(pos.X - lookFlat.X * back, y, pos.Z - lookFlat.Z * back)
		eff.Transparency = if back > 1e-3 then 0.15 else 0.75
	end
	local full = self._pivotMarkerFull
	if full and full.Parent then
		local backFull = math.max(0, fullBack)
		full.CFrame = CFrame.new(pos.X - lookFlat.X * backFull, y, pos.Z - lookFlat.Z * backFull)
	end
end

--[[
	地面转向后移距：有转向意图时用满距（贴后蹄），不再 ×speed01（否则中低速缩回腹心）
	@param feel RootFeel - 手感
	@param airborne boolean - 空中
	@param turning boolean - 本帧有转向意图
	@return number - 沿马头后方 stud
]]
local function _computeTurnPivotBack(feel: RootFeel, airborne: boolean, turning: boolean): number
	if airborne or not turning or feel.turnPivotBackStuds <= 1e-3 then
		return 0
	end
	return feel.turnPivotBackStuds
end

--[[
	由逻辑偏航得到水平 Look（与 atan2(-lx,-lz) 互逆）
	@param yaw number - 偏航（rad）
	@return Vector3 - 单位水平朝向
]]
local function _lookFromYaw(yaw: number): Vector3
	return Vector3.new(-math.sin(yaw), 0, -math.cos(yaw))
end

--[[
	读当前逻辑 Look；无逻辑 yaw 时回退物理根
	@param self MountRootDriver - 驱动
	@param root BasePart - 物理根
	@return Vector3 - 单位水平朝向
]]
local function _currentLook(self: MountRootDriver, root: BasePart): Vector3
	local yaw = self._logicalYaw
	if type(yaw) == "number" then
		return _lookFromYaw(yaw)
	end
	return _flatUnit(root.CFrame.LookVector) or Vector3.new(0, 0, -1)
end

--[[
	安装偏航 AlignOrientation（OneAttachment；只追逻辑 yaw，禁止 CFrame 瞬移朝向）
	@param self MountRootDriver - 驱动
	@param root BasePart - 物理根
]]
local function _setupYawConstraint(self: MountRootDriver, root: BasePart)
	if self._yawAlign then
		return
	end
	local attach = Instance.new("Attachment")
	attach.Name = "MountRootYawAttach"
	attach.Parent = root
	local ao = Instance.new("AlignOrientation")
	ao.Name = "MountRootYawAlign"
	ao.Mode = Enum.OrientationAlignmentMode.OneAttachment
	ao.Attachment0 = attach
	ao.RigidityEnabled = false
	ao.Responsiveness = YAW_ALIGN_RESPONSIVENESS
	ao.MaxTorque = YAW_ALIGN_MAX_TORQUE
	ao.MaxAngularVelocity = math.huge
	ao.CFrame = CFrame.Angles(0, _yawFromFlat(_flatUnit(root.CFrame.LookVector) or Vector3.new(0, 0, -1)), 0)
	ao.Parent = root
	self._yawAttach = attach
	self._yawAlign = ao
	self._logicalYaw = _yawFromFlat(_flatUnit(root.CFrame.LookVector) or Vector3.new(0, 0, -1))
end

--[[
	拆除偏航约束
	@param self MountRootDriver - 驱动
]]
local function _teardownYawConstraint(self: MountRootDriver)
	if self._yawAlign then
		self._yawAlign:Destroy()
		self._yawAlign = nil
	end
	if self._yawAttach then
		self._yawAttach:Destroy()
		self._yawAttach = nil
	end
	self._logicalYaw = nil
	self._pivotTangVel = nil
end

--[[
	写马根偏航目标（AlignOrientation + 后蹄枢轴切向速；不写 CFrame 朝向）
	@param self MountRootDriver - 驱动
	@param root BasePart - 物理根
	@param newYaw number - 目标偏航
	@param pivotBackStuds number - 后移距离
	@param dt number - 帧时
]]
local function _applyYaw(
	self: MountRootDriver,
	root: BasePart,
	newYaw: number,
	pivotBackStuds: number,
	dt: number
)
	local fromYaw = self._logicalYaw
	if type(fromYaw) ~= "number" then
		fromYaw = _yawFromFlat(_flatUnit(root.CFrame.LookVector) or Vector3.new(0, 0, -1))
	end
	local delta = _shortestAngle(fromYaw, newYaw)
	self._logicalYaw = newYaw

	local ao = self._yawAlign
	if ao then
		ao.CFrame = CFrame.Angles(0, newYaw, 0)
	end

	local back = math.max(0, pivotBackStuds)
	if back > 1e-3 and math.abs(delta) > 1e-5 and dt > 1e-5 then
		local oldLook = _lookFromYaw(fromYaw)
		local omega = delta / dt
		-- ω×r，r = look*back（枢轴在身后）；切向垂直于马头
		local rx, rz = oldLook.X * back, oldLook.Z * back
		self._pivotTangVel = Vector3.new(omega * rz, 0, -omega * rx)
	else
		self._pivotTangVel = nil
	end

	-- 抑制翻滚/俯仰角速度；偏航交 AlignOrientation
	local ang = root.AssemblyAngularVelocity
	root.AssemblyAngularVelocity = Vector3.new(0, ang.Y, 0)
end

--[[
	涌现式弯中掉速：巡航死区满幅度；仅近正交才按 severity×speed 咬地板
	@param feel RootFeel - 手感
	@param alignDot number - look·intent
	@param speed01 number - 相对巡航速
	@param aboutFace boolean - 提交式 180
	@return number - 水平速度乘子 ∈ [turnAlignMin, 1]
]]
local function _computeEmergentTurnSpeedMul(
	feel: RootFeel,
	alignDot: number,
	speed01: number,
	aboutFace: boolean
): number
	if aboutFace then
		return feel.aboutFaceAlignMin
	end
	if alignDot >= EMERGENT_TURN_ALIGN_DOT then
		return 1
	end
	local span = EMERGENT_TURN_ALIGN_DOT
	local severity = math.clamp((span - alignDot) / span, 0, 1)
	severity = severity ^ feel.turnAlignPow
	local bite = severity * (speed01 ^ 1.15)
	return 1 - (1 - feel.turnAlignMin) * bite
end

--[[
	换向时衰减后轴（防止左右切换瞬间绕远枢轴横甩）
	@param self MountRootDriver - 驱动
	@param delta number - 本帧偏航增量（rad）
	@param now number - 当前时间
	@param pivotBack number - 原后移距
	@return number - 衰减后后移距
]]
local function _applyPivotReverseBlend(
	self: MountRootDriver,
	delta: number,
	now: number,
	pivotBack: number
): number
	if pivotBack <= 1e-3 then
		return 0
	end
	local sign = if delta > 1e-5 then 1 elseif delta < -1e-5 then -1 else 0
	local last = self._lastYawDeltaSign or 0
	if sign ~= 0 and last ~= 0 and sign ~= last then
		self._pivotReverseUntil = now + TURN_PIVOT_REVERSE_BLEND_SEC
	end
	if sign ~= 0 then
		self._lastYawDeltaSign = sign
	end
	local reverseUntil = self._pivotReverseUntil
	if type(reverseUntil) ~= "number" or now >= reverseUntil then
		self._pivotReverseUntil = nil
		return pivotBack
	end
	local u = 1 - (reverseUntil - now) / TURN_PIVOT_REVERSE_BLEND_SEC
	u = math.clamp(u, 0, 1)
	-- 平滑加速回到满距：换向瞬间枢轴≈0，再爬回后蹄
	return pivotBack * (u * u)
end

--[[
	推进提交式 180
	@param self MountRootDriver - 驱动
	@param feel RootFeel - 手感
	@param look Vector3 - 马头
	@param dt number - 帧时
	@param root BasePart - 物理根
	@return (boolean, Vector3) - 仍在执行, 新 look
]]
local function _tickAboutFace(
	self: MountRootDriver,
	feel: RootFeel,
	look: Vector3,
	dt: number,
	root: BasePart
): (boolean, Vector3)
	local targetYaw = self._aboutFaceTargetYaw
	if type(targetYaw) ~= "number" then
		_endAboutFace(self)
		return false, look
	end

	_applyAboutFaceBrake(root, feel.aboutFaceBrake, dt)

	local maxRad = math.rad(feel.turnRateDeg) * feel.aboutFaceTurnMul
	local fromYaw = _yawFromFlat(look)
	local delta = _shortestAngle(fromYaw, targetYaw)
	local maxStep = maxRad * dt
	if math.abs(delta) > maxStep then
		delta = math.sign(delta) * maxStep
	end
	_applyYaw(self, root, fromYaw + delta, 0, dt)
	look = _currentLook(self, root)

	local remain = math.abs(_shortestAngle(_yawFromFlat(look), targetYaw))
	if remain <= math.rad(feel.aboutFaceCompleteDeg) then
		_applyYaw(self, root, targetYaw, 0, dt)
		look = _currentLook(self, root)
		_endAboutFace(self)
		return false, look
	end
	return true, look
end

--[[
	空中减重力
	@param self MountRootDriver - 驱动
	@param root BasePart - 物理根
]]
local function _setupAirGravity(self: MountRootDriver, root: BasePart)
	local attach = Instance.new("Attachment")
	attach.Name = "MountRootAirGravityAttach"
	attach.Parent = root
	local force = Instance.new("VectorForce")
	force.Name = "MountRootAirGravityAssist"
	force.Attachment0 = attach
	force.RelativeTo = Enum.ActuatorRelativeTo.World
	force.ApplyAtCenterOfMass = true
	force.Force = Vector3.zero
	force.Parent = root
	self._airForceAttach = attach
	self._airForce = force
end

--[[
	更新空中减重力
	@param self MountRootDriver - 驱动
	@param root BasePart - 物理根
	@param airborne boolean - 空中
]]
local function _updateAirGravity(self: MountRootDriver, root: BasePart, airborne: boolean)
	local force = self._airForce
	local feel = self._feel
	if not force or not feel then
		return
	end
	if not airborne or feel.airGravityScale >= 0.999 then
		force.Force = Vector3.zero
		return
	end
	local lift = root.AssemblyMass * Workspace.Gravity * (1 - feel.airGravityScale)
	force.Force = Vector3.new(0, lift, 0)
end

--[[
	首跳垂直初速：减重力反算 + 额外 HEIGHT_MUL（对齐 A 被 Humanoid 压矮后的体感）
	有效顶点 ≈ JumpHeight × FIRST_JUMP_HEIGHT_MUL（在 airGravityScale 下）
	@param feel RootFeel - 手感
	@return number - 写入马根的垂直速
]]
local function _firstJumpVertSpeed(feel: RootFeel): number
	local h = math.max(feel.jumpHeight, 0.1) * FIRST_JUMP_HEIGHT_MUL
	return math.sqrt(2 * Workspace.Gravity * feel.airGravityScale * h)
end

--[[
	首跳水平继承：疾驰保留 flat；原地给 MinFlat 前冲 + LeapPush 窗
	@param self MountRootDriver - 驱动
	@param root BasePart - 物理根
	@param jumpVel number - 已算好的垂直初速
]]
local function _applyFirstJumpFlat(self: MountRootDriver, root: BasePart, jumpVel: number)
	local feel = self._feel
	local hum = self._humanoid
	if not feel then
		return
	end
	local look = _flatUnit(root.CFrame.LookVector) or Vector3.new(0, 0, -1)
	local intent = if hum then select(1, _readStickIntent(self._controlModule, hum)) else nil
	local dir = intent or look

	local vel = root.AssemblyLinearVelocity
	local flat = Vector3.new(vel.X, 0, vel.Z)
	local flatSpeed = flat.Magnitude
	local cruise = math.max(feel.cruiseSpeed, 1)
	local speed01 = math.clamp(flatSpeed / cruise, 0, 1)
	local newFlat = flat

	if flatSpeed > 1e-3 then
		local absorb = feel.firstJumpLookAbsorb * (1 - speed01 * 0.65)
		newFlat = flat.Unit:Lerp(dir, absorb) * flatSpeed
		self._airHoldFlatSpeed = math.max(flatSpeed, newFlat.Magnitude, self._airHoldFlatSpeed or 0)
	elseif speed01 <= STANDSTILL_SPEED01 then
		-- 原地：前冲对齐二段跳水平目标的 60%（与 DoubleJumpMinFlat × FLAT_MUL 同口径）
		local doubleFlatTarget = math.max(feel.doubleJumpMinFlat, feel.cruiseSpeed * 0.4) * DOUBLE_JUMP_FLAT_MUL
		local standFlat = doubleFlatTarget * FIRST_JUMP_STAND_OF_DOUBLE_FLAT
		-- Snap 直接给满目标，避免 SnapFrac 再砍一刀导致体感过弱
		newFlat = dir * standFlat
		self._airHoldFlatSpeed = math.max(standFlat, self._airHoldFlatSpeed or 0)
	else
		self._airHoldFlatSpeed = math.max(flatSpeed, newFlat.Magnitude, self._airHoldFlatSpeed or 0)
	end

	root.AssemblyLinearVelocity = Vector3.new(newFlat.X, jumpVel, newFlat.Z)
	self._leapPushSpeed01 = speed01
	if feel.leapPushSec > 0 and feel.leapPushAccel > 0 then
		self._leapPushUntil = os.clock() + feel.leapPushSec
	end
end

--[[
	LeapPush 包络增量（首跳短时前冲润色）
	@param root BasePart - 物理根
	@param pushDir Vector3 - 推进方向
	@param pushStart number - 包络起点
	@param pushDuration number - 时长
	@param pushAccel number - 峰值加速度
	@param pushPow number - 衰减幂
	@param speedMul number - 静止/疾驰倍率
	@param dt number - 帧时
]]
local function _applyLeapPushDelta(
	root: BasePart,
	pushDir: Vector3,
	pushStart: number,
	pushDuration: number,
	pushAccel: number,
	pushPow: number,
	speedMul: number,
	dt: number
)
	if pushDuration <= 0 or pushAccel <= 0 or speedMul <= 0 or dt <= 0 then
		return
	end
	local elapsed = os.clock() - pushStart
	if elapsed < 0 or elapsed >= pushDuration then
		return
	end
	local t = elapsed / pushDuration
	local factor = (1 - t) ^ pushPow
	local deltaV = pushDir * (pushAccel * factor * speedMul * dt)
	local vel = root.AssemblyLinearVelocity
	local flat = Vector3.new(vel.X, 0, vel.Z) + deltaV
	root.AssemblyLinearVelocity = Vector3.new(flat.X, vel.Y, flat.Z)
end

--[[
	首跳点火（写马根垂直速 + 水平前冲继承）
	@param self MountRootDriver - 驱动
]]
local function _commitFirstJump(self: MountRootDriver)
	if not self._active or not self._feel or not self._root then
		return
	end
	local root = self._root
	local feel = self._feel
	if _isGrounded(root) == false and self._airborneSince ~= nil then
		self._firstJumpPending = false
		return
	end
	self._firstJumpPending = false
	self._landYLockUntil = nil
	self._hasLeftGround = false
	local jumpVel = _firstJumpVertSpeed(feel)
	_applyFirstJumpFlat(self, root, jumpVel)
	if self._airborneSince == nil then
		self._airborneSince = os.clock()
	end
end

--[[
	请求首跳
	@param self MountRootDriver - 驱动
]]
local function _requestFirstJump(self: MountRootDriver)
	if not self._active or not self._feel or not self._root then
		return
	end
	-- 已在空中权威（含起跳后仍射线贴地）则禁止再一段跳
	if self._airborneSince ~= nil or self._firstJumpPending then
		return
	end
	if not _isGrounded(self._root) then
		return
	end
	-- 起跳前清落地锁，避免短窗把 jumpY 压回 0
	self._landYLockUntil = nil
	local presentation = self._presentation
	if presentation and presentation.requestJump and presentation.isAttached and presentation:isAttached() then
		self._firstJumpPending = true
		local accepted = presentation:requestJump(function()
			_commitFirstJump(self)
		end)
		if not accepted then
			self._firstJumpPending = false
			_commitFirstJump(self)
		end
		return
	end
	_commitFirstJump(self)
end

--[[
	二段跳：垂直冲量 + 水平 blend 改向 + Redirect/Flip 窗
	@param self MountRootDriver - 驱动
]]
local function _tryDoubleJump(self: MountRootDriver)
	if not self._active or not self._feel or not self._feel.canDoubleJump or not self._root then
		return
	end
	if self._doubleJumpUsed or self._airborneSince == nil then
		return
	end
	local feel = self._feel
	if os.clock() - self._airborneSince < feel.doubleJumpAirDelaySec then
		return
	end
	local root = self._root
	local hum = self._humanoid
	self._doubleJumpUsed = true

	local look = _flatUnit(root.CFrame.LookVector) or Vector3.new(0, 0, -1)
	local intent = if hum then select(1, _readStickIntent(self._controlModule, hum)) else nil
	local aim = intent or look

	local vel = root.AssemblyLinearVelocity
	local flat = Vector3.new(vel.X, 0, vel.Z)
	local flatSpeed = flat.Magnitude
	local blend0 = feel.doubleJumpVelBlend0
	local floorSpeed = math.max(feel.doubleJumpMinFlat, feel.cruiseSpeed * 0.4)
	local newFlat: Vector3
	if flatSpeed > 1e-3 then
		local redirected = flat:Lerp(aim * flatSpeed, blend0)
		local speed = math.max(redirected.Magnitude, floorSpeed) * DOUBLE_JUMP_FLAT_MUL
		if redirected.Magnitude > 1e-3 then
			newFlat = redirected.Unit * speed
		else
			newFlat = aim * (floorSpeed * DOUBLE_JUMP_FLAT_MUL)
		end
	else
		newFlat = aim * (floorSpeed * DOUBLE_JUMP_FLAT_MUL)
	end

	-- 二段跳：表速直接写（减重力下自然加高）；勿再缩 √scale，否则相对首跳偏矮
	local jumpY = feel.doubleJumpSpeed * DOUBLE_JUMP_VERT_MUL
	root.AssemblyLinearVelocity = Vector3.new(newFlat.X, jumpY, newFlat.Z)
	-- 写入保速基准，Redirect 窗结束后仍按此前冲水平速，勿塌回 cruise
	self._airHoldFlatSpeed = newFlat.Magnitude
	self._redirectAim = aim
	local redirectSec = math.max(feel.doubleJumpRedirectSec, feel.doubleJumpFlipWindowSec)
	self._redirectUntil = os.clock() + redirectSec
	self._airFlipUntil = os.clock() + feel.doubleJumpFlipWindowSec
end

--[[
	绑定跳跃输入
	@param self MountRootDriver - 驱动
]]
local function _bindJumpHooks(self: MountRootDriver)
	self._jumpConn = UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if input.KeyCode ~= Enum.KeyCode.Space and input.KeyCode ~= Enum.KeyCode.ButtonA then
			return
		end
		local root = self._root
		if not root then
			return
		end
		-- 起跳后仍可能射线贴地：已 inFlight 则走二段跳，勿再当地面一段跳
		local inFlight = self._airborneSince ~= nil or self._firstJumpPending == true
		if not inFlight and _isGrounded(root) then
			if gameProcessed then
				return
			end
			_requestFirstJump(self)
		else
			_tryDoubleJump(self)
		end
	end)
end

--[[
	进入
	@param self MountRootDriver - 驱动
	@param ctx table - MountEnterContext
	@return boolean - 成功
]]
function MountRootDriver.enter(self: MountRootDriver, ctx: { [string]: any }): boolean
	local character = ctx.character
	if not character or not character.Parent then
		return false
	end
	local hum = character:FindFirstChildWhichIsA("Humanoid")
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hum or not hrp or not hrp:IsA("BasePart") then
		return false
	end

	local cfg = ctx.cfg or {}
	local feel = _parseFeel(cfg)

	-- 须在 attachRoot 之前保存：Presentation 会关 AutoRotate，事后读到的是 false
	self._savedJumpHeight = hum.JumpHeight
	self._savedAutoRotate = hum.AutoRotate

	local presentation = MountPresentation.new()
	if not presentation:attachRoot(character, cfg) then
		self._savedJumpHeight = nil
		self._savedAutoRotate = nil
		presentation:detach()
		return false
	end
	local root = presentation:getPhysicsRoot()
	if not root then
		self._savedJumpHeight = nil
		self._savedAutoRotate = nil
		presentation:detach()
		return false
	end

	self._character = character
	self._humanoid = hum
	self._hrp = hrp
	self._root = root
	self._presentation = presentation
	self._feel = feel
	self._throttle01 = 0
	self._gait = GAIT_WALK
	self._gallopHold = 0
	self._doubleJumpUsed = false
	self._airborneSince = nil
	self._firstJumpPending = false
	self._airHoldFlatSpeed = nil
	self._leapPushUntil = nil
	self._leapPushSpeed01 = nil
	self._redirectAim = nil
	self._redirectUntil = nil
	self._airFlipUntil = nil
	self._landYLockUntil = nil
	self._landStaggerUntil = nil
	self._hasLeftGround = false
	self._lastYawDeltaSign = 0
	self._pivotReverseUntil = nil
	self._pivotTangVel = nil
	self._aboutFaceActive = false
	self._aboutFaceTargetYaw = nil
	self._aboutFaceReadyAt = 0

	hum.JumpHeight = 0
	hum.AutoRotate = false
	character:SetAttribute(MOUNT_ACTIVE_ATTR, true)

	self._controlModule = _getControlModule()
	_hijackControlMove(self)
	_acquireFacingGate(self, character)
	_setupYawConstraint(self, root)
	_setupAirGravity(self, root)
	_bindJumpHooks(self)
	_setupPivotMarkers(self)
	self._active = true
	return true
end

--[[
	每帧更新
	@param self MountRootDriver - 驱动
	@param dt number - 帧时
]]
function MountRootDriver.update(self: MountRootDriver, dt: number)
	if not self._active or not self._feel or not self._root or not self._humanoid then
		return
	end
	local root = self._root
	local hum = self._humanoid
	local feel = self._feel
	if not root.Parent or not hum.Parent then
		return
	end

	-- 保持站桩焊死，防止 Humanoid 抢回地面 loco 把人留在原地
	if not hum.PlatformStand then
		hum.PlatformStand = true
	end

	-- 射线贴地 ≠ 运动学空中；起跳窗内即使仍挨地也走空中水平权威
	local now = os.clock()
	local rayGrounded = _isGrounded(root)
	local leapPushActive = type(self._leapPushUntil) == "number" and now < (self._leapPushUntil :: number)
	local pendingJump = self._firstJumpPending == true

	-- 真正离地过一次后才允许落地（替代 LeapPush 挡落地：有杆短跳易在推窗内贴地）
	if self._airborneSince ~= nil and not rayGrounded then
		self._hasLeftGround = true
	end

	-- 先边沿落地：必须在合成 airborne 之前清 _airborneSince，否则会永远 inFlight
	-- 已真正离地后再贴地即收态（不再用 LeapPush / LAND_MAX 挡：有杆刮地冲量常抬 Y）
	if rayGrounded and self._airborneSince ~= nil and not pendingJump and self._hasLeftGround then
		local presentationLand = self._presentation
		if presentationLand and presentationLand.onLanded then
			presentationLand:onLanded()
		end
		local vLand = root.AssemblyLinearVelocity
		local flatMag = Vector3.new(vLand.X, 0, vLand.Z).Magnitude
		if vLand.Y ~= 0 then
			root.AssemblyLinearVelocity = Vector3.new(vLand.X, 0, vLand.Z)
		end
		local speed01 = math.clamp(flatMag / math.max(feel.cruiseSpeed, 1), 0, 1)
		self._landYLockUntil = now + LAND_Y_LOCK_SEC + LAND_Y_LOCK_SPEED_EXTRA * speed01
		self._landStaggerUntil = now + LAND_STAGGER_SEC
		_clearAirFlightState(self)
	end

	-- 落地可能已清 LeapPush；必须重算，否则同帧 inFlight 仍真 → 立刻写回空中态（有杆短跳典型弹跳）
	leapPushActive = type(self._leapPushUntil) == "number" and now < (self._leapPushUntil :: number)
	local inFlight = self._airborneSince ~= nil or pendingJump or leapPushActive
	local airborne = (not rayGrounded) or inFlight
	local onGroundLoco = rayGrounded and not inFlight
	local landYLock = type(self._landYLockUntil) == "number" and now < (self._landYLockUntil :: number)
	-- 仅贴地时锁 Y；弹起离地后勿冻在半空
	if landYLock and not rayGrounded then
		landYLock = false
		self._landYLockUntil = nil
	elseif not landYLock then
		self._landYLockUntil = nil
	end
	local inFlipWindow = type(self._airFlipUntil) == "number" and now < (self._airFlipUntil :: number)
	if not inFlipWindow then
		self._airFlipUntil = nil
	end

	if airborne then
		if self._airborneSince == nil and not pendingJump then
			-- 跌落等：非起跳 pending 进入空中
			self._airborneSince = now
		end
		_endAboutFace(self)
	end

	-- 减重力只在真正离地后开，避免起跳仍挨地时上抬力顶壳
	_updateAirGravity(self, root, not rayGrounded)

	local intent, stickMag = _readStickIntent(self._controlModule, hum)
	local targetThrottle = if intent then stickMag else 0
	_tickGait(self, targetThrottle, dt, onGroundLoco)
	_tickThrottle(self, targetThrottle, dt)

	local look = _currentLook(self, root)
	local flatSpeed = Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z).Magnitude
	local speed01 = math.clamp(flatSpeed / math.max(feel.cruiseSpeed, 1), 0, 1)

	-- 真·地面才可提交 180（起跳窗 / 空中不算）
	if onGroundLoco and intent and not self._aboutFaceActive and _canStartAboutFace(self)
		and _shouldCommitAboutFace(feel, look, intent, root)
	then
		_beginAboutFace(self, look, intent)
	end

	local aboutFaceActive = self._aboutFaceActive and onGroundLoco
	local turning = (not aboutFaceActive) and intent ~= nil
	local pivotBackShow = _computeTurnPivotBack(feel, airborne, turning)
	self._pivotTangVel = nil
	if aboutFaceActive then
		local _still
		_still, look = _tickAboutFace(self, feel, look, dt, root)
		self._throttle01 = 0
		self._gait = GAIT_WALK
		self._gallopHold = 0
		self._lastYawDeltaSign = 0
		self._pivotReverseUntil = nil
		pivotBackShow = 0
	elseif intent then
		local desiredYaw = _yawFromFlat(intent)
		local fromYaw = _yawFromFlat(look)
		local delta = _shortestAngle(fromYaw, desiredYaw)
		local turnMul: number
		if inFlipWindow then
			turnMul = feel.airFlipTurnMul
		elseif airborne then
			turnMul = feel.airTurnMul
		else
			turnMul = 1 - (1 - feel.turnHighSpeedMul) * (speed01 ^ feel.turnSpeedPow)
		end
		local maxStep = math.rad(feel.turnRateDeg) * turnMul * dt
		if math.abs(delta) > maxStep then
			delta = math.sign(delta) * maxStep
		end
		local pivotBack = _applyPivotReverseBlend(self, delta, now, pivotBackShow)
		pivotBackShow = pivotBack
		_applyYaw(self, root, fromYaw + delta, pivotBack, dt)
		look = _currentLook(self, root)
	else
		self._lastYawDeltaSign = 0
		self._pivotReverseUntil = nil
		-- 无转向意图：仍把 AO 钉在逻辑 yaw，压俯仰翻滚
		local yawHold = self._logicalYaw
		if type(yawHold) == "number" then
			local ao = self._yawAlign
			if ao then
				ao.CFrame = CFrame.Angles(0, yawHold, 0)
			end
		end
	end
	-- 品红始终标表配后蹄位；青块为本帧实际枢轴
	_updatePivotMarkers(self, root, look, pivotBackShow, feel.turnPivotBackStuds)

	-- 空中二段跳改向窗：速度朝 redirectAim / 马头软对齐
	local redirectActive = type(self._redirectUntil) == "number" and now < (self._redirectUntil :: number)
	if airborne then
		if redirectActive and self._redirectAim then
			_alignFlatVelToDir(root, self._redirectAim, feel.airFlipVelAlign, dt)
		elseif inFlipWindow then
			_alignFlatVelToDir(root, look, feel.airFlipVelAlign, dt)
		end
	elseif self._redirectUntil then
		self._redirectUntil = nil
		self._redirectAim = nil
	end

	local alignDot = 1
	if intent then
		alignDot = math.clamp(look:Dot(intent), -1, 1)
	end
	-- 缓弯不再每帧 × turnAlign；仅近正交涌现掉速（D.8 / D.9）
	local turnSpeedMul = 1
	if aboutFaceActive then
		turnSpeedMul = feel.aboutFaceAlignMin
	elseif onGroundLoco and intent then
		turnSpeedMul = _computeEmergentTurnSpeedMul(feel, alignDot, speed01, false)
	end

	local throttleEff = if aboutFaceActive then 0 else self._throttle01
	local idleRest = onGroundLoco
		and throttleEff < 0.04
		and (not intent)
		and flatSpeed < IDLE_REST_FLAT_SPEED
		and not aboutFaceActive

	local targetFlat: Vector3
	if airborne then
		local hold = self._airHoldFlatSpeed
		if type(hold) ~= "number" or hold <= 0 then
			local curBoot = Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z)
			hold = curBoot.Magnitude
			if hold > 1e-3 then
				self._airHoldFlatSpeed = hold
			end
		end
		if type(hold) == "number" and hold > 1e-3 then
			if redirectActive or inFlipWindow then
				local velNow = root.AssemblyLinearVelocity
				local curFlat = Vector3.new(velNow.X, 0, velNow.Z)
				if curFlat.Magnitude > 1e-3 then
					targetFlat = curFlat
					if curFlat.Magnitude > hold then
						self._airHoldFlatSpeed = curFlat.Magnitude
					end
				else
					targetFlat = look * hold
				end
			elseif leapPushActive or throttleEff > 0.05 then
				-- Push 窗或有杆：按保速基准维持（起跳仍挨地也不塌成 cruise×0）
				local targetSpeed = math.max(hold * feel.airSpeedMaintainSoft, feel.cruiseSpeed * throttleEff)
				targetFlat = look * targetSpeed
			else
				local newHold = math.max(0, hold - feel.airCoastDecel * dt)
				self._airHoldFlatSpeed = if newHold > 0.5 then newHold else nil
				local speed = self._airHoldFlatSpeed or 0
				local velNow = root.AssemblyLinearVelocity
				local curFlat = Vector3.new(velNow.X, 0, velNow.Z)
				if curFlat.Magnitude > 1e-3 and speed > 0 then
					targetFlat = curFlat.Unit * speed
				else
					targetFlat = look * speed
				end
			end
		else
			targetFlat = look * (feel.cruiseSpeed * throttleEff)
		end
	else
		-- 真·地面巡航：幅度≈油门；枢轴切向叠加（后蹄作轴）
		targetFlat = look * (feel.cruiseSpeed * throttleEff * turnSpeedMul)
		local tang = self._pivotTangVel
		if tang and onGroundLoco then
			targetFlat = targetFlat + tang
		end
	end

	-- 落地顿挫：短时水平衰减后回到满幅
	local staggerUntil = self._landStaggerUntil
	if type(staggerUntil) == "number" and now < staggerUntil and onGroundLoco then
		local u = 1 - (staggerUntil - now) / LAND_STAGGER_SEC
		u = math.clamp(u, 0, 1)
		local staggerMul = LAND_STAGGER_SPEED_MUL0 + (1 - LAND_STAGGER_SPEED_MUL0) * u
		targetFlat = targetFlat * staggerMul
	elseif type(staggerUntil) == "number" then
		self._landStaggerUntil = nil
	end

	local vel = root.AssemblyLinearVelocity
	local newY = vel.Y
	if idleRest then
		targetFlat = Vector3.zero
		newY = 0
	elseif landYLock then
		newY = 0
	elseif onGroundLoco then
		-- 碰撞静置：小误差不写 CFrame。台阶/斜坡大误差才用竖直速度跟
		local presentation = self._presentation
		local dy: number? = nil
		if presentation and presentation.getGroundYError then
			dy = presentation:getGroundYError()
		end
		local moving = throttleEff > 0.05 or flatSpeed > 1
		if type(dy) == "number" and math.abs(dy) > HOOF_DEADZONE and (moving or math.abs(dy) > HOOF_STEP_FORCE) then
			newY = math.clamp(dy * HOOF_SEEK_GAIN, -HOOF_SEEK_MAX, HOOF_SEEK_MAX)
		else
			newY = 0
		end
	end
	root.AssemblyLinearVelocity = Vector3.new(targetFlat.X, newY, targetFlat.Z)
	if idleRest then
		root.AssemblyAngularVelocity = Vector3.zero
	end

	-- 首跳 LeapPush 润色
	if airborne and leapPushActive then
		local pushStart = (self._leapPushUntil :: number) - feel.leapPushSec
		local pushSpeed01 = self._leapPushSpeed01 or 0
		local pushMul = feel.leapStandPushMul * (1 - pushSpeed01) + feel.leapGallopPushMul * pushSpeed01
		local pushDir = intent or look
		_applyLeapPushDelta(
			root,
			pushDir,
			pushStart,
			feel.leapPushSec,
			feel.leapPushAccel,
			feel.leapPushPow,
			pushMul,
			dt
		)
		local after = root.AssemblyLinearVelocity
		local afterFlat = Vector3.new(after.X, 0, after.Z).Magnitude
		if afterFlat > (self._airHoldFlatSpeed or 0) then
			self._airHoldFlatSpeed = afterFlat
		end
	elseif self._leapPushUntil and not leapPushActive then
		self._leapPushUntil = nil
		self._leapPushSpeed01 = nil
	end

	-- 禁止人型再推
	hum:Move(Vector3.zero, false)

	local presentation = self._presentation
	if presentation and presentation.tickSeatControls then
		presentation:tickSeatControls()
	end
	if presentation and presentation.updateGait then
		presentation:updateGait({
			airborne = airborne,
			flatSpeed = flatSpeed,
			gait = self._gait,
			speed01 = speed01,
		})
	end
end

--[[
	离开
	@param self MountRootDriver - 驱动
	@param _reason string - 原因
]]
function MountRootDriver.exit(self: MountRootDriver, _reason: string)
	if self._jumpConn then
		self._jumpConn:Disconnect()
		self._jumpConn = nil
	end

	local character = self._character
	local hum = self._humanoid

	_restoreControlMove(self)
	_releaseFacingGate(self, character)

	if self._presentation then
		if self._presentation.cancelJumpRequest then
			self._presentation:cancelJumpRequest()
		end
		self._presentation:detach()
		self._presentation = nil
	end

	if character then
		character:SetAttribute(MOUNT_ACTIVE_ATTR, nil)
	end

	if hum and hum.Parent then
		if self._savedJumpHeight ~= nil then
			hum.JumpHeight = self._savedJumpHeight
		end
		if self._savedAutoRotate ~= nil then
			hum.AutoRotate = self._savedAutoRotate
		end
	end

	if self._airForce then
		self._airForce:Destroy()
		self._airForce = nil
	end
	if self._airForceAttach then
		self._airForceAttach:Destroy()
		self._airForceAttach = nil
	end
	_teardownYawConstraint(self)
	_destroyPivotMarkers(self)

	self._active = false
	self._character = nil
	self._humanoid = nil
	self._hrp = nil
	self._root = nil
	self._feel = nil
	self._controlModule = nil
	self._savedJumpHeight = nil
	self._savedAutoRotate = nil
	self._throttle01 = 0
	self._gait = GAIT_WALK
	self._gallopHold = 0
	self._doubleJumpUsed = false
	self._airborneSince = nil
	self._firstJumpPending = false
	self._airHoldFlatSpeed = nil
	self._leapPushUntil = nil
	self._leapPushSpeed01 = nil
	self._redirectAim = nil
	self._redirectUntil = nil
	self._airFlipUntil = nil
	self._landYLockUntil = nil
	self._landStaggerUntil = nil
	self._hasLeftGround = false
	self._lastYawDeltaSign = 0
	self._pivotReverseUntil = nil
	self._aboutFaceActive = false
	self._aboutFaceTargetYaw = nil
	self._aboutFaceReadyAt = 0
end

--[[
	销毁
	@param self MountRootDriver - 驱动
]]
function MountRootDriver.destroy(self: MountRootDriver)
	self:exit(EnumMgr.MountForceExitReason.InvalidState)
end

--[[
	是否激活
	@param self MountRootDriver - 驱动
	@return boolean - Active
]]
function MountRootDriver.isActive(self: MountRootDriver): boolean
	return self._active
end

--[[
	平面速度
	@param self MountRootDriver - 驱动
	@return number? - 速度
]]
function MountRootDriver.getFlatSpeed(self: MountRootDriver): number?
	if not self._active or not self._root then
		return nil
	end
	local vel = self._root.AssemblyLinearVelocity
	return Vector3.new(vel.X, 0, vel.Z).Magnitude
end

return MountRootDriver
