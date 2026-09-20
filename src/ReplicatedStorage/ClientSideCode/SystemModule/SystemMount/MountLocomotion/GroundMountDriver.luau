--[[
	Module: GroundMountDriver
	Description: 陆地坐骑 Locomotion（Humanoid + CMS + 托雷特向转向/跳跃手感；真模型/Part 回退）
	Author: 林奥宇
	Created: 2026-08-27
	Last Modified: 2026-08-27

	托雷特转向逻辑（与步行 Humanoid 的差异）：
	1. DesiredHeading 来自 ControlModule 真输入（勿用被 Move 覆盖的 MoveDirection）
	2. 坐骑偏航以有限角速度转向该方向（低速快、高速慢；速度带幂次分段）
	3. 位移只沿当前马头前方推进（Humanoid:Move(forward*throttleEff)），禁止侧滑 strafing
	4. 弯中掉推力：throttleEff = throttle × turnAlignFactor（TurnCruiseDot 内满推力；急弯才降）
	5. 巡航弧偏航轴后移（TurnPivotBackStuds×speed01）：鼻尖甩开、后躯更贴弯心；原地/180/空中仍绕 HRP
	6. 地面急回头：一帧反向即锁定目标偏航，松杆也会自动拧完 180（提交式）
	7. 偏航写入保留线速度并清 Y 角速度；劫持 moveFunction；每帧钉 AutoRotate=false
	8. 瞬 180：二段跳打开翻转窗，限速追朝向（禁止一帧硬切 CFrame）
	9. 跳跃前冲（D.4.2）：继承/MinFlat 地板 + 软保速（Push 窗不回拉）+ LeapPush 润色；二段跳加远地板 + blend 改向
	10. 表现：MountPresentation 真模型 Idle/Run/Jump；缺模回退 Part 占位
	11. 首跳：JumpHeight=0 关引擎跳；空格 → Presentation.requestJump → Takeoff Marker/Fallback 再手动点火
	12. 乘骑期 Character.MountActive=true，供 Animate 总闸与步行态分离
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local ActionArbiter = Utils.ActionArbiter
local EnumMgr = Utils.EnumMgr
local HttpService = Utils.HttpService
local Players = Utils.Players
local UserInputService = Utils.UserInputService
local Workspace = workspace

local MountPresentation = require(script.Parent.Parent.MountPresentation)

local GroundMountDriver = {}
GroundMountDriver.__index = GroundMountDriver

local PLACEHOLDER_SIZE = Vector3.new(3.2, 2.4, 5.5)
local PLACEHOLDER_COLOR = Color3.fromRGB(110, 82, 56)
local PLACEHOLDER_OFFSET = CFrame.new(0, -1.2, 0)
local MOUNT_FACING_OWNER_ID = "Mount:GroundFacing"

local MOVE_INPUT_THRESHOLD = 0.08
local DEFAULT_ACCEL_SEC = 0.9
local DEFAULT_DECEL_SEC = 1.35
-- 低速原地回转（°/s）；高速巡航弧线更钝
local DEFAULT_TURN_RATE_DEG = 220
local DEFAULT_TURN_HIGH_SPEED_MUL = 0.38
-- >1：高速段更早变钝（非单线性）
local DEFAULT_TURN_SPEED_POW = 1.35
-- 弯中推力下限（勿贴地板；缓弯由 TurnCruiseDot 死区保满推力）
local DEFAULT_TURN_ALIGN_MIN = 0.65
local DEFAULT_TURN_ALIGN_POW = 1.1
-- look·intent >= 此值（约 ≤35°）时不砍 Move 幅度
local DEFAULT_TURN_CRUISE_DOT = 0.85
-- 巡航弯偏航轴相对 HRP 沿马头后方的距离（stud）；×speed01，静止为 0
-- 体高约 5 stud 的马：巡航满速时轴后移约半身长，鼻尖甩、后躯贴弯心
local DEFAULT_TURN_PIVOT_BACK = 4.5
-- 地面急回头：look·intent 须近正对向（约 ≥175°，cos≈-0.996）才按朝向提交
local DEFAULT_ABOUT_FACE_DOT = -0.996
local DEFAULT_ABOUT_FACE_TRAVEL_DOT = -0.996
local DEFAULT_ABOUT_FACE_COMPLETE_DEG = 12
local DEFAULT_ABOUT_FACE_ALIGN_MIN = 0
-- 对向时直接作为 turnRate 倍率（忽略高速变钝）
local DEFAULT_ABOUT_FACE_TURN_MUL = 2.9
-- 对向主动刹水平速度（stud/s²）
local DEFAULT_ABOUT_FACE_BRAKE = 160
-- 马头局部 +Z（背向）超过此值视为「向后」触发（越高越不易误触）
local DEFAULT_ABOUT_FACE_STICK_BACK = 0.9
-- 连续提交式 180 之间的冷却（自完成时刻起算）
local DEFAULT_ABOUT_FACE_COOLDOWN_SEC = 0.2
-- 常态空中转向；翻转窗内更高但仍受转速上限（禁止一帧硬切）
local DEFAULT_AIR_TURN_MUL = 0.85
local DEFAULT_AIR_FLIP_TURN_MUL = 2.6
local DEFAULT_DOUBLE_JUMP_FLIP_WINDOW_SEC = 0.4
-- 翻转窗内水平速度每秒朝马头对齐的比例
local DEFAULT_AIR_FLIP_VEL_ALIGN = 8
local DEFAULT_DOUBLE_JUMP_VEL_BLEND0 = 0.45
local DEFAULT_DOUBLE_JUMP_REDIRECT_SEC = 0.22
local DEFAULT_JUMP_HEIGHT = 22
local DEFAULT_DOUBLE_JUMP_SPEED = 55
local DEFAULT_AIR_GRAVITY_SCALE = 0.72
local DEFAULT_AIR_THROTTLE_MUL = 1
local DEFAULT_AIR_FLIP_THROTTLE_MUL = 1
local DEFAULT_AIR_SPEED_MAINTAIN_SOFT = 0.9
local DEFAULT_AIR_SPEED_LEAN_RATE = 8
local DEFAULT_AIR_COAST_DECEL = 6
-- 首跳：继承为主；静止给 MinFlat 地板（保速基准用满 MinFlat，勿用 Snap）
local DEFAULT_FIRST_JUMP_MIN_FLAT = 16
local DEFAULT_FIRST_JUMP_SNAP_FRAC = 0.6
local DEFAULT_FIRST_JUMP_RAMP_SEC = 0.06
local DEFAULT_FIRST_JUMP_LOOK_ABSORB = 0.08
-- 短时前向润色包络（非主推进；疾驰仍弱于静止）
local DEFAULT_LEAP_PUSH_SEC = 0.24
local DEFAULT_LEAP_PUSH_ACCEL = 55
local DEFAULT_LEAP_PUSH_POW = 1.35
local DEFAULT_LEAP_STAND_PUSH_MUL = 1.2
local DEFAULT_LEAP_GALLOP_PUSH_MUL = 0.45
-- 二段跳：垂直 + 水平加远地板 + 短时润色
local DEFAULT_DOUBLE_JUMP_MIN_FLAT = 18
local DEFAULT_DOUBLE_JUMP_PUSH_SEC = 0.22
local DEFAULT_DOUBLE_JUMP_PUSH_ACCEL = 70
local DEFAULT_CAN_DOUBLE_JUMP = true
local DOUBLE_JUMP_AIR_DELAY_SEC = 0.08
local STANDSTILL_SPEED01 = 0.22
local MOUNT_ACTIVE_ATTR = "MountActive"

export type FeelParams = {
	accelSec: number,
	decelSec: number,
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
	airGravityScale: number,
	airThrottleMul: number,
	airFlipThrottleMul: number,
	airSpeedMaintainSoft: number,
	airSpeedLeanRate: number,
	airCoastDecel: number,
	firstJumpMinFlat: number,
	firstJumpSnapFrac: number,
	firstJumpRampSec: number,
	firstJumpLookAbsorb: number,
	leapPushSec: number,
	leapPushAccel: number,
	leapPushPow: number,
	leapStandPushMul: number,
	leapGallopPushMul: number,
	doubleJumpMinFlat: number,
	doubleJumpPushSec: number,
	doubleJumpPushAccel: number,
}

--[[
	从角色 CharacterScripts 取 CMS Bind
	运行时 require 角色下 ModuleScript（非 Utils 静态模块；pcall 防缺脚本）
	@param character Model - 玩家角色
	@return any? - CharacterMoveSpeedBind
]]
local function _getMoveSpeedBind(character: Model): any?
	local folder = character:FindFirstChild("CharacterScripts")
	if not folder then
		return nil
	end
	local mod = folder:FindFirstChild("CharacterMoveSpeedBind")
	if not mod or not mod:IsA("ModuleScript") then
		return nil
	end
	local ok, bind = pcall(require, mod)
	if ok then
		return bind
	end
	return nil
end

--[[
	取 ControlModule（真摇杆/键盘，不被 Humanoid:Move 覆盖）
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
	local controls = pm:GetControls()
	return controls
end

--[[
	水平单位化；过小返回 nil
	@param v Vector3 - 任意向量
	@return Vector3? - 水平单位向量
]]
local function _flatUnit(v: Vector3): Vector3?
	local flat = Vector3.new(v.X, 0, v.Z)
	if flat.Magnitude < 1e-4 then
		return nil
	end
	return flat.Unit
end

--[[
	解析摇杆世界水平方向与油门；优先 ControlModule.inputMoveVector（同帧已算好的世界向量）
	@param controlModule any? - ControlModule
	@param hum Humanoid - 角色
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
			-- 本帧明确无输入
			if mag < 1e-4 then
				-- 再试 raw（键盘状态可能已更新但尚未 OnRenderStepped）
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
	解析 ExtJson / 表字段为手感参数
	@param cfg table - MountCfg 深拷贝行
	@return FeelParams - 手感参数
]]
local function _parseFeelParams(cfg: { [string]: any }): FeelParams
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

	local function _numRange(key: string, default: number, lo: number, hi: number): number
		local v = tonumber(ext[key]) or tonumber(cfg[key])
		if type(v) == "number" and v == v then
			return math.clamp(v, lo, hi)
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

	return {
		accelSec = _num("AccelSec", DEFAULT_ACCEL_SEC),
		decelSec = _num("DecelSec", DEFAULT_DECEL_SEC),
		turnRateDeg = _num("TurnRateDeg", DEFAULT_TURN_RATE_DEG),
		turnHighSpeedMul = math.clamp(_num("TurnHighSpeedMul", DEFAULT_TURN_HIGH_SPEED_MUL), 0.05, 1),
		turnSpeedPow = math.clamp(_num("TurnSpeedPow", DEFAULT_TURN_SPEED_POW), 0.5, 3),
		turnAlignMin = _unit01("TurnAlignMin", DEFAULT_TURN_ALIGN_MIN),
		turnAlignPow = math.clamp(_num("TurnAlignPow", DEFAULT_TURN_ALIGN_POW), 0.25, 4),
		turnCruiseDot = _numRange("TurnCruiseDot", DEFAULT_TURN_CRUISE_DOT, 0, 1),
		turnPivotBackStuds = _numRange("TurnPivotBackStuds", DEFAULT_TURN_PIVOT_BACK, 0, 8),
		aboutFaceDot = _numRange("AboutFaceDot", DEFAULT_ABOUT_FACE_DOT, -1, 0),
		aboutFaceTravelDot = _numRange("AboutFaceTravelDot", DEFAULT_ABOUT_FACE_TRAVEL_DOT, -1, 0),
		aboutFaceCompleteDeg = math.clamp(_num("AboutFaceCompleteDeg", DEFAULT_ABOUT_FACE_COMPLETE_DEG), 2, 45),
		aboutFaceAlignMin = _unit01("AboutFaceAlignMin", DEFAULT_ABOUT_FACE_ALIGN_MIN),
		aboutFaceTurnMul = math.clamp(_num("AboutFaceTurnMul", DEFAULT_ABOUT_FACE_TURN_MUL), 0.5, 5),
		aboutFaceBrake = math.clamp(_num("AboutFaceBrake", DEFAULT_ABOUT_FACE_BRAKE), 0, 400),
		aboutFaceStickBack = math.clamp(_num("AboutFaceStickBack", DEFAULT_ABOUT_FACE_STICK_BACK), 0.1, 0.95),
		aboutFaceCooldownSec = _numRange("AboutFaceCooldownSec", DEFAULT_ABOUT_FACE_COOLDOWN_SEC, 0, 3),
		airTurnMul = math.clamp(_num("AirTurnMul", DEFAULT_AIR_TURN_MUL), 0.1, 1.5),
		airFlipTurnMul = math.clamp(_num("AirFlipTurnMul", DEFAULT_AIR_FLIP_TURN_MUL), 0.5, 5),
		doubleJumpFlipWindowSec = math.clamp(_num("DoubleJumpFlipWindowSec", DEFAULT_DOUBLE_JUMP_FLIP_WINDOW_SEC), 0.05, 1),
		airFlipVelAlign = math.clamp(_num("AirFlipVelAlign", DEFAULT_AIR_FLIP_VEL_ALIGN), 1, 30),
		doubleJumpVelBlend0 = math.clamp(_numRange("DoubleJumpVelBlend0", DEFAULT_DOUBLE_JUMP_VEL_BLEND0, 0, 1), 0, 1),
		doubleJumpRedirectSec = math.clamp(_num("DoubleJumpRedirectSec", DEFAULT_DOUBLE_JUMP_REDIRECT_SEC), 0.05, 1),
		jumpHeight = _num("JumpHeight", DEFAULT_JUMP_HEIGHT),
		canDoubleJump = canDouble,
		doubleJumpSpeed = _num("DoubleJumpSpeed", DEFAULT_DOUBLE_JUMP_SPEED),
		airGravityScale = math.clamp(_num("AirGravityScale", DEFAULT_AIR_GRAVITY_SCALE), 0.35, 1),
		airThrottleMul = math.clamp(_num("AirThrottleMul", DEFAULT_AIR_THROTTLE_MUL), 0.2, 1.5),
		airFlipThrottleMul = math.clamp(_num("AirFlipThrottleMul", DEFAULT_AIR_FLIP_THROTTLE_MUL), 0.2, 1.5),
		airSpeedMaintainSoft = math.clamp(_numRange("AirSpeedMaintainSoft", DEFAULT_AIR_SPEED_MAINTAIN_SOFT, 0, 1.2), 0, 1.2),
		airSpeedLeanRate = math.clamp(_num("AirSpeedLeanRate", DEFAULT_AIR_SPEED_LEAN_RATE), 1, 30),
		airCoastDecel = _numRange("AirCoastDecel", DEFAULT_AIR_COAST_DECEL, 0, 80),
		firstJumpMinFlat = _numRange("FirstJumpMinFlat", DEFAULT_FIRST_JUMP_MIN_FLAT, 0, 60),
		firstJumpSnapFrac = math.clamp(_numRange("FirstJumpSnapFrac", DEFAULT_FIRST_JUMP_SNAP_FRAC, 0, 1), 0, 1),
		firstJumpRampSec = math.clamp(_num("FirstJumpRampSec", DEFAULT_FIRST_JUMP_RAMP_SEC), 0.02, 0.25),
		firstJumpLookAbsorb = math.clamp(_numRange("FirstJumpLookAbsorb", DEFAULT_FIRST_JUMP_LOOK_ABSORB, 0, 0.35), 0, 0.35),
		leapPushSec = math.clamp(_num("LeapPushSec", DEFAULT_LEAP_PUSH_SEC), 0, 0.5),
		leapPushAccel = _numRange("LeapPushAccel", DEFAULT_LEAP_PUSH_ACCEL, 0, 120),
		leapPushPow = math.clamp(_num("LeapPushPow", DEFAULT_LEAP_PUSH_POW), 0.5, 3),
		leapStandPushMul = math.clamp(_num("LeapStandPushMul", DEFAULT_LEAP_STAND_PUSH_MUL), 0, 2),
		leapGallopPushMul = math.clamp(_num("LeapGallopPushMul", DEFAULT_LEAP_GALLOP_PUSH_MUL), 0, 2),
		doubleJumpMinFlat = _numRange("DoubleJumpMinFlat", DEFAULT_DOUBLE_JUMP_MIN_FLAT, 0, 60),
		doubleJumpPushSec = math.clamp(_num("DoubleJumpPushSec", DEFAULT_DOUBLE_JUMP_PUSH_SEC), 0, 0.5),
		doubleJumpPushAccel = _numRange("DoubleJumpPushAccel", DEFAULT_DOUBLE_JUMP_PUSH_ACCEL, 0, 120),
	}
end

--[[
	创建 Part 占位坐骑并焊到 HRP
	@param character Model - 玩家角色
	@param mountId number - 配置 ID（命名用）
	@return (BasePart?, WeldConstraint?) - 占位 Part 与焊点
]]
local function _createPlaceholderModel(character: Model, mountId: number): (BasePart?, WeldConstraint?)
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp or not hrp:IsA("BasePart") then
		return nil, nil
	end

	local part = Instance.new("Part")
	part.Name = "MountPlaceholder_" .. tostring(mountId)
	part.Size = PLACEHOLDER_SIZE
	part.Color = PLACEHOLDER_COLOR
	part.Material = Enum.Material.SmoothPlastic
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.Anchored = false
	part.CFrame = hrp.CFrame * PLACEHOLDER_OFFSET
	part.Parent = character

	local weld = Instance.new("WeldConstraint")
	weld.Name = "MountWeld"
	weld.Part0 = hrp
	weld.Part1 = part
	weld.Parent = part

	return part, weld
end

--[[
	平面朝向 → Y 偏航
	@param flat Vector3 - 水平单位方向
	@return number - yaw 弧度
]]
local function _yawFromFlat(flat: Vector3): number
	return math.atan2(-flat.X, -flat.Z)
end

--[[
	最短角差 [-pi, pi]
	@param from number - 当前
	@param to number - 目标
	@return number - 差值
]]
local function _shortestAngle(from: number, to: number): number
	return (to - from + math.pi) % (2 * math.pi) - math.pi
end

--[[
	是否视为空中（可二段跳）
	@param hum Humanoid - 角色
	@return boolean - 空中
]]
local function _isAirborne(hum: Humanoid): boolean
	local state = hum:GetState()
	if state == Enum.HumanoidStateType.Freefall or state == Enum.HumanoidStateType.Jumping then
		return true
	end
	return hum.FloorMaterial == Enum.Material.Air
end

--[[
	是否跳跃键
	@param input InputObject - 输入
	@return boolean - 是跳跃键
]]
local function _isJumpKey(input: InputObject): boolean
	if input.KeyCode == Enum.KeyCode.Space or input.KeyCode == Enum.KeyCode.ButtonA then
		return true
	end
	return input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode == Enum.KeyCode.Space
end

export type GroundMountDriver = typeof(setmetatable({} :: {
	locomotionType: string,
	mountId: number,
	_active: boolean,
	_character: Model?,
	_humanoid: Humanoid?,
	_hrp: BasePart?,
	_modifierOwnerId: string?,
	_placeholderPart: BasePart?,
	_weld: WeldConstraint?,
	_presentation: any?,
	_feel: FeelParams?,
	_cruiseMul: number,
	_savedJumpHeight: number?,
	_savedAutoRotate: boolean?,
	_doubleJumpUsed: boolean,
	_airborneSince: number?,
	_takeoffFlatSpeed: number?,
	_takeoffHandled: boolean,
	_takeoffSpeed01: number?,
	_minFlatRampUntil: number?,
	_minFlatTarget: number?,
	_leapPushUntil: number?,
	_doubleLeapPushUntil: number?,
	_redirectAim: Vector3?,
	_redirectUntil: number?,
	_airFlipUntil: number?,
	_aboutFaceActive: boolean,
	_aboutFaceTargetYaw: number?,
	_aboutFaceReadyAt: number,
	_controlModule: any?,
	_savedMoveFunction: any?,
	_facingToken: string?,
	_airForceAttach: Attachment?,
	_airForce: VectorForce?,
	_jumpConn: RBXScriptConnection?,
	_stateConn: RBXScriptConnection?,
	_firstJumpPending: boolean,
}, GroundMountDriver))

--[[
	构造 GroundMountDriver
	@param mountId number - mountConf 主键
	@return GroundMountDriver - 驱动实例
]]
function GroundMountDriver.new(mountId: number): GroundMountDriver
	local self = setmetatable({
		locomotionType = EnumMgr.MountLocomotionType.GroundMount,
		mountId = mountId,
		_active = false,
		_character = nil,
		_humanoid = nil,
		_hrp = nil,
		_modifierOwnerId = nil,
		_placeholderPart = nil,
		_weld = nil,
		_presentation = nil,
		_feel = nil,
		_cruiseMul = 1,
		_savedJumpHeight = nil,
		_savedAutoRotate = nil,
		_doubleJumpUsed = false,
		_airborneSince = nil,
		_takeoffFlatSpeed = nil,
		_takeoffHandled = false,
		_takeoffSpeed01 = nil,
		_minFlatRampUntil = nil,
		_minFlatTarget = nil,
		_leapPushUntil = nil,
		_doubleLeapPushUntil = nil,
		_redirectAim = nil,
		_redirectUntil = nil,
		_airFlipUntil = nil,
		_aboutFaceActive = false,
		_aboutFaceTargetYaw = nil,
		_aboutFaceReadyAt = 0,
		_controlModule = nil,
		_savedMoveFunction = nil,
		_facingToken = nil,
		_airForceAttach = nil,
		_airForce = nil,
		_jumpConn = nil,
		_stateConn = nil,
		_firstJumpPending = false,
	}, GroundMountDriver)
	return self
end

--[[
	劫持 ControlModule.moveFunction：骑乘期间禁止默认 Player:Move(摇杆世界方向)
	@param self GroundMountDriver - 驱动
]]
local function _hijackControlMove(self: GroundMountDriver)
	local cm = self._controlModule
	if not cm or self._savedMoveFunction ~= nil then
		return
	end
	if type(cm.moveFunction) ~= "function" then
		return
	end
	self._savedMoveFunction = cm.moveFunction
	-- 仍让 ControlModule 算 inputMoveVector；只吞掉最终 Move，改由本驱动写马头推进
	cm.moveFunction = function(_player: Player, _moveVector: Vector3, _relativeToCamera: boolean) end
end

--[[
	恢复 ControlModule.moveFunction
	@param self GroundMountDriver - 驱动
]]
local function _restoreControlMove(self: GroundMountDriver)
	local cm = self._controlModule
	if cm and self._savedMoveFunction ~= nil then
		cm.moveFunction = self._savedMoveFunction
	end
	self._savedMoveFunction = nil
end

--[[
	占朝向闸（FacingOnly）：即便未开 ShiftLock 也声明 External，避免其它系统抢偏航
	@param self GroundMountDriver - 驱动
	@param character Model - 角色
]]
local function _acquireFacingGate(self: GroundMountDriver, character: Model)
	local arbiter = ActionArbiter.GetForCharacter(character)
	if not arbiter or type(arbiter.Acquire) ~= "function" then
		return
	end
	self._facingToken = arbiter:Acquire({
		ownerId = MOUNT_FACING_OWNER_ID,
		priority = ActionArbiter.Priority.FacingBridge,
		blendPolicy = ActionArbiter.BlendPolicy.FacingOnly,
		reason = "GroundMountDriver",
	})
end

--[[
	释放朝向闸
	@param self GroundMountDriver - 驱动
	@param character Model? - 角色
]]
local function _releaseFacingGate(self: GroundMountDriver, character: Model?)
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
	限速写入水平偏航（保留线速度、清 Y 角速度，避免被物理拧回）
	pivotBackStuds>0 时绕「马头后方」虚拟点转：鼻尖扫更大弧、后躯更贴弯心；
	约等于 0 时退化为原地绕 HRP（原地回转 / 提交式 180 / 空中用）
	@param hrp BasePart - HRP
	@param newYaw number - 目标偏航弧度
	@param pivotBackStuds number? - 沿当前马头后方的枢轴距离（stud）；nil/0=绕 HRP
]]
local function _applyYaw(hrp: BasePart, newYaw: number, pivotBackStuds: number?)
	local linVel = hrp.AssemblyLinearVelocity
	local pos = hrp.Position
	local back = if type(pivotBackStuds) == "number" then math.max(0, pivotBackStuds) else 0
	if back > 1e-3 then
		local oldLook = _flatUnit(hrp.CFrame.LookVector) or Vector3.new(0, 0, -1)
		local fromYaw = _yawFromFlat(oldLook)
		local delta = _shortestAngle(fromYaw, newYaw)
		local pivot = Vector3.new(pos.X, pos.Y, pos.Z) - oldLook * back
		local offset = Vector3.new(pos.X - pivot.X, 0, pos.Z - pivot.Z)
		local rotated = CFrame.Angles(0, delta, 0):VectorToWorldSpace(offset)
		pos = Vector3.new(pivot.X + rotated.X, pos.Y, pivot.Z + rotated.Z)
	end
	hrp.CFrame = CFrame.new(pos) * CFrame.Angles(0, newYaw, 0)
	hrp.AssemblyLinearVelocity = linVel
	local ang = hrp.AssemblyAngularVelocity
	hrp.AssemblyAngularVelocity = Vector3.new(ang.X, 0, ang.Z)
end

--[[
	清空本段空中跳跃状态
	@param self GroundMountDriver - 驱动
]]
local function _clearAirJumpState(self: GroundMountDriver)
	self._airborneSince = nil
	self._takeoffFlatSpeed = nil
	self._takeoffHandled = false
	self._takeoffSpeed01 = nil
	self._minFlatRampUntil = nil
	self._minFlatTarget = nil
	self._leapPushUntil = nil
	self._doubleLeapPushUntil = nil
	self._redirectAim = nil
	self._redirectUntil = nil
	self._doubleJumpUsed = false
	self._airFlipUntil = nil
	-- 注意：勿清 _firstJumpPending（地面起跳窗与空中态独立）
end

--[[
	抬高空中保速基准（只升不降）
	@param self GroundMountDriver - 驱动
	@param flatSpeed number - 候选水平速
]]
local function _raiseTakeoffFlatSpeed(self: GroundMountDriver, flatSpeed: number)
	if flatSpeed ~= flatSpeed or flatSpeed <= 0 then
		return
	end
	local cur = self._takeoffFlatSpeed
	if type(cur) ~= "number" or flatSpeed > cur then
		self._takeoffFlatSpeed = flatSpeed
	end
end

--[[
	从 HRP 当前水平速同步保速基准
	@param self GroundMountDriver - 驱动
	@param hrp BasePart - HRP
]]
local function _syncTakeoffFlatFromHrp(self: GroundMountDriver, hrp: BasePart)
	local vel = hrp.AssemblyLinearVelocity
	_raiseTakeoffFlatSpeed(self, Vector3.new(vel.X, 0, vel.Z).Magnitude)
end

--[[
	起跳继承：保留地面 flat，极轻吸向马头/意图；静止才软爬 MinFlat
	@param self GroundMountDriver - 驱动
	@param speed01 number - 相对巡航速度 [0,1]
]]
local function _applyTakeoffInherit(self: GroundMountDriver, speed01: number)
	if self._takeoffHandled or not self._active or not self._feel then
		return
	end
	local hum = self._humanoid
	local hrp = self._hrp
	local feel = self._feel
	if not hum or not hrp or not hum.Parent or not hrp.Parent then
		return
	end

	local look = _flatUnit(hrp.CFrame.LookVector) or Vector3.new(0, 0, -1)
	local intent = select(1, _readStickIntent(self._controlModule, hum))
	local dir = if intent then intent else look

	local vel = hrp.AssemblyLinearVelocity
	local flat = Vector3.new(vel.X, 0, vel.Z)
	local flatSpeed = flat.Magnitude
	local newFlat = flat

	if flatSpeed > 1e-3 then
		local absorb = feel.firstJumpLookAbsorb * (1 - speed01 * 0.65)
		newFlat = (flat.Unit:Lerp(dir, absorb)) * flatSpeed
		-- 疾驰：保速基准 = 继承水平速
		self._takeoffFlatSpeed = math.max(flatSpeed, newFlat.Magnitude)
	elseif speed01 <= STANDSTILL_SPEED01 and feel.firstJumpMinFlat > 0 then
		local snapSpeed = feel.firstJumpMinFlat * feel.firstJumpSnapFrac
		newFlat = dir * snapSpeed
		self._minFlatTarget = feel.firstJumpMinFlat
		self._minFlatRampUntil = os.clock() + feel.firstJumpRampSec
		-- 静止：保速基准用满 MinFlat（勿用 Snap，否则 SoftMaintain 回拉吃掉前冲）
		self._takeoffFlatSpeed = feel.firstJumpMinFlat
	else
		self._takeoffFlatSpeed = math.max(flatSpeed, newFlat.Magnitude)
	end

	hrp.AssemblyLinearVelocity = Vector3.new(newFlat.X, vel.Y, newFlat.Z)
	self._takeoffSpeed01 = speed01
	self._takeoffHandled = true

	if feel.leapPushSec > 0 and feel.leapPushAccel > 0 then
		self._leapPushUntil = os.clock() + feel.leapPushSec
	end
end

--[[
	首跳物理点火：按 JumpHeight 给垂直速 + 水平继承（动画 Takeoff 后调用）
	@param self GroundMountDriver - 驱动
]]
local function _commitFirstJump(self: GroundMountDriver)
	if not self._active or not self._feel then
		return
	end
	local hum = self._humanoid
	local hrp = self._hrp
	local feel = self._feel
	if not hum or not hrp or not hum.Parent or not hrp.Parent then
		return
	end
	if _isAirborne(hum) then
		self._firstJumpPending = false
		return
	end

	self._firstJumpPending = false
	local jumpVel = math.sqrt(2 * Workspace.Gravity * math.max(feel.jumpHeight, 0.1))
	local vel = hrp.AssemblyLinearVelocity
	hrp.AssemblyLinearVelocity = Vector3.new(vel.X, jumpVel, vel.Z)
	pcall(function()
		hum:ChangeState(Enum.HumanoidStateType.Jumping)
	end)

	if self._airborneSince == nil then
		self._airborneSince = os.clock()
	end

	local cruise = math.max(self._cruiseMul * 16, 1)
	local flatSpeed = Vector3.new(vel.X, 0, vel.Z).Magnitude
	local speed01 = math.clamp(flatSpeed / cruise, 0, 1)
	_applyTakeoffInherit(self, speed01)
end

--[[
	请求首跳：有表现层则等 Takeoff；占位则立即点火
	@param self GroundMountDriver - 驱动
]]
local function _requestFirstJump(self: GroundMountDriver)
	if not self._active or not self._feel then
		return
	end
	local hum = self._humanoid
	if not hum or _isAirborne(hum) then
		return
	end
	if self._firstJumpPending then
		return
	end

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
	二段跳：Y 短促升力 + 水平 blend 改向 + 加远地板 + 打开 Redirect/Flip 窗
	@param self GroundMountDriver - 驱动
]]
local function _tryDoubleJump(self: GroundMountDriver)
	if not self._active or not self._feel or not self._feel.canDoubleJump then
		return
	end
	if self._doubleJumpUsed then
		return
	end
	local hum = self._humanoid
	local hrp = self._hrp
	if not hum or not hrp or not hum.Parent or not hrp.Parent then
		return
	end
	if not _isAirborne(hum) then
		return
	end
	local since = self._airborneSince
	if type(since) ~= "number" or (os.clock() - since) < DOUBLE_JUMP_AIR_DELAY_SEC then
		return
	end

	self._doubleJumpUsed = true
	local feel = self._feel
	local look = _flatUnit(hrp.CFrame.LookVector) or Vector3.new(0, 0, -1)
	local intent = select(1, _readStickIntent(self._controlModule, hum))
	local aim = intent or look

	local vel = hrp.AssemblyLinearVelocity
	local flat = Vector3.new(vel.X, 0, vel.Z)
	local flatSpeed = flat.Magnitude
	local blend0 = feel.doubleJumpVelBlend0
	-- 二段跳加远：水平至少 DoubleJumpMinFlat（托雷特「加高+加远+改向」）
	local floorSpeed = math.max(feel.doubleJumpMinFlat, feel.firstJumpMinFlat)
	local newFlat: Vector3
	if flatSpeed > 1e-3 then
		local redirected = flat:Lerp(aim * flatSpeed, blend0)
		local speed = math.max(redirected.Magnitude, floorSpeed)
		if redirected.Magnitude > 1e-3 then
			newFlat = redirected.Unit * speed
		else
			newFlat = aim * speed
		end
	else
		newFlat = aim * floorSpeed
	end

	hrp.AssemblyLinearVelocity = Vector3.new(newFlat.X, feel.doubleJumpSpeed, newFlat.Z)
	self._takeoffFlatSpeed = math.max(newFlat.Magnitude, floorSpeed)
	self._redirectAim = aim
	local redirectSec = math.max(feel.doubleJumpRedirectSec, feel.doubleJumpFlipWindowSec)
	self._redirectUntil = os.clock() + redirectSec
	self._airFlipUntil = os.clock() + feel.doubleJumpFlipWindowSec

	if feel.doubleJumpPushSec > 0 and feel.doubleJumpPushAccel > 0 then
		self._doubleLeapPushUntil = os.clock() + feel.doubleJumpPushSec
	end
end

--[[
	空中松杆：水平速度软衰减
	@param hrp BasePart - HRP
	@param decel number - stud/s²
	@param dt number - 帧间隔
]]
local function _applyAirCoastDecel(hrp: BasePart, decel: number, dt: number)
	if decel <= 0 or dt <= 0 then
		return
	end
	local vel = hrp.AssemblyLinearVelocity
	local flat = Vector3.new(vel.X, 0, vel.Z)
	local speed = flat.Magnitude
	if speed < 1e-3 then
		return
	end
	local newSpeed = math.max(0, speed - decel * dt)
	local newFlat = if newSpeed <= 1e-3 then Vector3.zero else flat.Unit * newSpeed
	hrp.AssemblyLinearVelocity = Vector3.new(newFlat.X, vel.Y, newFlat.Z)
end

--[[
	绑定跳跃输入与空中状态计时
	@param self GroundMountDriver - 驱动
]]
local function _bindJumpHooks(self: GroundMountDriver)
	local hum = self._humanoid
	if not hum then
		return
	end

	self._jumpConn = UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if not _isJumpKey(input) then
			return
		end
		local humNow = self._humanoid
		if not humNow then
			return
		end
		if _isAirborne(humNow) then
			if gameProcessed then
				-- 空中二段跳仍接受（UI 吃键时也尽量响应）
			end
			_tryDoubleJump(self)
			return
		end
		if gameProcessed then
			return
		end
		_requestFirstJump(self)
	end)

	self._stateConn = hum.StateChanged:Connect(function(_old, newState)
		if newState == Enum.HumanoidStateType.Freefall or newState == Enum.HumanoidStateType.Jumping then
			if self._airborneSince == nil then
				self._airborneSince = os.clock()
			end
			self._aboutFaceActive = false
			self._aboutFaceTargetYaw = nil
		elseif newState == Enum.HumanoidStateType.Landed
			or newState == Enum.HumanoidStateType.Running
			or newState == Enum.HumanoidStateType.Climbing
		then
			local presentation = self._presentation
			if presentation and presentation.onLanded then
				presentation:onLanded()
			end
			_clearAirJumpState(self)
		end
	end)
end

--[[
	创建空中减重力 VectorForce
	@param self GroundMountDriver - 驱动
	@param hrp BasePart - HumanoidRootPart
]]
local function _setupAirGravityAssist(self: GroundMountDriver, hrp: BasePart)
	local attach = Instance.new("Attachment")
	attach.Name = "MountAirGravityAttach"
	attach.Parent = hrp

	local force = Instance.new("VectorForce")
	force.Name = "MountAirGravityAssist"
	force.Attachment0 = attach
	force.RelativeTo = Enum.ActuatorRelativeTo.World
	force.ApplyAtCenterOfMass = true
	force.Force = Vector3.zero
	force.Parent = hrp

	self._airForceAttach = attach
	self._airForce = force
end

--[[
	更新空中减重力（滞空更接近托雷特）
	@param self GroundMountDriver - 驱动
	@param hrp BasePart - HRP
	@param airborne boolean - 是否空中
]]
local function _updateAirGravityAssist(self: GroundMountDriver, hrp: BasePart, airborne: boolean)
	local force = self._airForce
	local feel = self._feel
	if not force or not feel then
		return
	end
	if not airborne then
		force.Force = Vector3.zero
		return
	end
	local scale = feel.airGravityScale
	if scale >= 0.999 then
		force.Force = Vector3.zero
		return
	end
	-- F = m * g * (1 - scale)，抵消部分重力
	local lift = hrp.AssemblyMass * Workspace.Gravity * (1 - scale)
	force.Force = Vector3.new(0, lift, 0)
end

--[[
	进入骑乘
	@param self GroundMountDriver - 驱动
	@param ctx table - MountEnterContext
	@return boolean - 是否成功
]]
function GroundMountDriver.enter(self: GroundMountDriver, ctx: { [string]: any }): boolean
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
	local speedMul = tonumber(cfg.SpeedMul) or 1
	if speedMul <= 0 then
		speedMul = 1
	end
	local feel = _parseFeelParams(cfg)

	local bind = _getMoveSpeedBind(character)
	if not bind then
		return false
	end

	local ownerId = "Mount:" .. tostring(self.mountId)
	self._cruiseMul = speedMul
	self._feel = feel
	self._modifierOwnerId = ownerId
	self._character = character
	self._humanoid = hum
	self._hrp = hrp

	bind.pushModifier(ownerId, {
		mul = speedMul,
		accelDuration = feel.accelSec,
		decelDuration = feel.decelSec,
	})

	-- 真模型优先；缺资源回退 Part 占位
	local presentation = MountPresentation.new()
	local usedModel = presentation:attach(character, cfg)
	if usedModel then
		self._presentation = presentation
		self._placeholderPart = nil
		self._weld = nil
	else
		presentation:detach()
		local part, weld = _createPlaceholderModel(character, self.mountId)
		if not part then
			bind.popModifier(ownerId)
			self._character = nil
			self._humanoid = nil
			self._hrp = nil
			self._modifierOwnerId = nil
			self._feel = nil
			return false
		end
		self._presentation = nil
		self._placeholderPart = part
		self._weld = weld
	end

	self._savedJumpHeight = hum.JumpHeight
	self._savedAutoRotate = hum.AutoRotate
	-- 关闭引擎自动跳；首跳由 Takeoff 承诺后手动点火
	hum.JumpHeight = 0
	hum.AutoRotate = false
	character:SetAttribute(MOUNT_ACTIVE_ATTR, true)

	self._doubleJumpUsed = false
	self._firstJumpPending = false
	_clearAirJumpState(self)
	self._aboutFaceActive = false
	self._aboutFaceTargetYaw = nil
	self._aboutFaceReadyAt = 0
	self._controlModule = _getControlModule()
	_hijackControlMove(self)
	_acquireFacingGate(self, character)
	_setupAirGravityAssist(self, hrp)
	self._active = true

	_bindJumpHooks(self)
	return true
end

--[[
	计算本帧 yaw 倍率
	@param feel FeelParams - 手感
	@param speed01 number - 相对巡航速度 [0,1]
	@param aboutFace boolean - 地面急回头粘滞中
	@param airborne boolean - 是否空中
	@param inFlipWindow boolean - 二段跳翻转窗内
	@return number - 乘到 turnRateDeg 上的倍率
]]
local function _computeTurnMul(
	feel: FeelParams,
	speed01: number,
	aboutFace: boolean,
	airborne: boolean,
	inFlipWindow: boolean
): number
	if inFlipWindow then
		return feel.airFlipTurnMul
	end
	if airborne then
		return feel.airTurnMul
	end
	if aboutFace then
		-- 急回头：忽略高速变钝，固定较高倍率（仍受 turnRateDeg * mul * dt 上限）
		return feel.aboutFaceTurnMul
	end
	return 1 - (1 - feel.turnHighSpeedMul) * (speed01 ^ feel.turnSpeedPow)
end

--[[
	弯中 / 急回头推力因子
	@param feel FeelParams - 手感
	@param alignDot number - look·intent
	@param aboutFace boolean - 是否对向
	@return number - turnAlignFactor；巡航弧内（alignDot >= turnCruiseDot）恒为 1
]]
local function _computeTurnAlignFactor(feel: FeelParams, alignDot: number, aboutFace: boolean): number
	if aboutFace then
		return feel.aboutFaceAlignMin
	end
	if alignDot >= feel.turnCruiseDot then
		return 1
	end
	local alignMin = feel.turnAlignMin
	local t = math.clamp(alignDot, 0, 1)
	local pow = feel.turnAlignPow
	if pow ~= 1 then
		t = t ^ pow
	end
	return alignMin + (1 - alignMin) * t
end

--[[
	对向时主动刹水平速度
	@param hrp BasePart - HRP
	@param brake number - stud/s²
	@param dt number - 帧间隔
]]
local function _applyAboutFaceBrake(hrp: BasePart, brake: number, dt: number)
	if brake <= 0 or dt <= 0 then
		return
	end
	local vel = hrp.AssemblyLinearVelocity
	local flat = Vector3.new(vel.X, 0, vel.Z)
	local speed = flat.Magnitude
	if speed < 1e-3 then
		return
	end
	local newSpeed = math.max(0, speed - brake * dt)
	local newFlat = if newSpeed <= 1e-3 then Vector3.zero else flat.Unit * newSpeed
	hrp.AssemblyLinearVelocity = Vector3.new(newFlat.X, vel.Y, newFlat.Z)
end

--[[
	水平速度朝目标方向限速对齐
	@param hrp BasePart - HRP
	@param targetDir Vector3 - 目标水平方向（单位）
	@param alignPerSec number - 每秒对齐强度
	@param dt number - 帧间隔
]]
local function _alignFlatVelToDir(hrp: BasePart, targetDir: Vector3, alignPerSec: number, dt: number)
	local vel = hrp.AssemblyLinearVelocity
	local flat = Vector3.new(vel.X, 0, vel.Z)
	local speed = flat.Magnitude
	if speed < 1e-3 then
		return
	end
	local target = targetDir * speed
	local alpha = math.clamp(alignPerSec * dt, 0, 1)
	local blended = flat:Lerp(target, alpha)
	hrp.AssemblyLinearVelocity = Vector3.new(blended.X, vel.Y, blended.Z)
end

--[[
	空中软保速：lerp 速度模长与方向，避免硬 max 钉死
	@param hrp BasePart - HRP
	@param look Vector3 - 当前马头
	@param targetSpeed number - 目标水平速（stud/s）
	@param leanRate number - 每秒收敛强度
	@param dt number - 帧间隔
]]
local function _softLeanAirFlatSpeed(hrp: BasePart, look: Vector3, targetSpeed: number, leanRate: number, dt: number)
	if targetSpeed <= 1e-3 or dt <= 0 then
		return
	end
	local vel = hrp.AssemblyLinearVelocity
	local flat = Vector3.new(vel.X, 0, vel.Z)
	local speed = flat.Magnitude
	local alpha = math.clamp(leanRate * dt, 0, 1)
	local outSpeed = speed + (targetSpeed - speed) * alpha
	local dir = look
	if speed > 1e-3 then
		dir = flat.Unit:Lerp(look, alpha * 0.45)
		if dir.Magnitude > 1e-3 then
			dir = dir.Unit
		else
			dir = look
		end
	end
	local out = dir * outSpeed
	hrp.AssemblyLinearVelocity = Vector3.new(out.X, vel.Y, out.Z)
end

--[[
	LeapPush 时间包络：自事件起算的短时前向 Δv（疾驰弱推）
	@param hrp BasePart - HRP
	@param pushDir Vector3 - 推进方向
	@param pushStart number - 包络起点 os.clock()
	@param pushDuration number - 包络时长（秒）
	@param pushAccel number - 峰值加速度（stud/s²）
	@param pushPow number - 衰减幂次
	@param speedMul number - 速度分段倍率
	@param dt number - 帧间隔
]]
local function _applyLeapPushDelta(
	hrp: BasePart,
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
	local vel = hrp.AssemblyLinearVelocity
	local flat = Vector3.new(vel.X, 0, vel.Z) + deltaV
	hrp.AssemblyLinearVelocity = Vector3.new(flat.X, vel.Y, flat.Z)
end

--[[
	静止起跳 MinFlat 软爬
	@param hrp BasePart - HRP
	@param look Vector3 - 马头
	@param targetSpeed number - 目标水平速
	@param rampSec number - 软爬时长
	@param dt number - 帧间隔
]]
local function _tickMinFlatRamp(hrp: BasePart, look: Vector3, targetSpeed: number, rampSec: number, dt: number)
	if targetSpeed <= 1e-3 or rampSec <= 0 or dt <= 0 then
		return
	end
	local vel = hrp.AssemblyLinearVelocity
	local flat = Vector3.new(vel.X, 0, vel.Z)
	local speed = flat.Magnitude
	local alpha = math.clamp(dt / rampSec, 0, 1)
	local outSpeed = speed + (targetSpeed - speed) * alpha
	hrp.AssemblyLinearVelocity = Vector3.new(look.X * outSpeed, vel.Y, look.Z * outSpeed)
end

--[[
	空中水平速度单一写口：Redirect → 软保速/Coast → LeapPush 润色
	@param self GroundMountDriver - 驱动
	@param hrp BasePart - HRP
	@param look Vector3 - 马头
	@param intent Vector3? - 期望朝向
	@param throttle number - 油门 [0,1]
	@param speed01 number - 相对巡航速度
	@param dt number - 帧间隔
	@param inFlipWindow boolean - 二段跳翻转窗
]]
local function _applyAirHorizontalChain(
	self: GroundMountDriver,
	hrp: BasePart,
	look: Vector3,
	intent: Vector3?,
	throttle: number,
	speed01: number,
	dt: number,
	inFlipWindow: boolean
)
	local feel = self._feel
	if not feel then
		return
	end

	local now = os.clock()
	local pushSpeed01 = self._takeoffSpeed01 or speed01
	local pushMul = feel.leapStandPushMul * (1 - pushSpeed01) + feel.leapGallopPushMul * pushSpeed01
	local leapPushActive = type(self._leapPushUntil) == "number" and now < (self._leapPushUntil :: number)
	local doublePushActive = type(self._doubleLeapPushUntil) == "number" and now < (self._doubleLeapPushUntil :: number)
	local inPushWindow = leapPushActive or doublePushActive

	if self._minFlatRampUntil and now < self._minFlatRampUntil then
		local target = self._minFlatTarget or feel.firstJumpMinFlat
		_tickMinFlatRamp(hrp, look, target, feel.firstJumpRampSec, dt)
		_raiseTakeoffFlatSpeed(self, target)
	elseif self._minFlatRampUntil then
		local target = self._minFlatTarget or feel.firstJumpMinFlat
		_raiseTakeoffFlatSpeed(self, target)
		self._minFlatRampUntil = nil
		self._minFlatTarget = nil
	end

	local redirectActive = type(self._redirectUntil) == "number" and now < (self._redirectUntil :: number)
	if redirectActive and self._redirectAim then
		_alignFlatVelToDir(hrp, self._redirectAim, feel.airFlipVelAlign, dt)
	elseif inFlipWindow then
		_alignFlatVelToDir(hrp, look, feel.airFlipVelAlign, dt)
	end

	if intent and feel.airSpeedMaintainSoft > 0 then
		local takeoff = self._takeoffFlatSpeed
		if type(takeoff) == "number" and takeoff > 0 then
			local target = takeoff * feel.airSpeedMaintainSoft * math.clamp(throttle, 0, 1)
			if inPushWindow then
				-- Push 窗内只补速、不回拉，避免吃掉前冲润色
				local vel = hrp.AssemblyLinearVelocity
				local flatSpeed = Vector3.new(vel.X, 0, vel.Z).Magnitude
				if flatSpeed < target then
					_softLeanAirFlatSpeed(hrp, look, target, feel.airSpeedLeanRate, dt)
				end
			else
				_softLeanAirFlatSpeed(hrp, look, target, feel.airSpeedLeanRate, dt)
			end
		end
	else
		-- Push 窗内勿 coast 回拉；窗后才软衰减
		if not inPushWindow then
			_applyAirCoastDecel(hrp, feel.airCoastDecel, dt)
		end
	end

	if leapPushActive then
		local pushStart = (self._leapPushUntil :: number) - feel.leapPushSec
		_applyLeapPushDelta(hrp, look, pushStart, feel.leapPushSec, feel.leapPushAccel, feel.leapPushPow, pushMul, dt)
		_syncTakeoffFlatFromHrp(self, hrp)
	elseif self._leapPushUntil then
		_syncTakeoffFlatFromHrp(self, hrp)
		self._leapPushUntil = nil
	end

	if doublePushActive then
		local pushDir = self._redirectAim or look
		local pushStart = (self._doubleLeapPushUntil :: number) - feel.doubleJumpPushSec
		_applyLeapPushDelta(
			hrp,
			pushDir,
			pushStart,
			feel.doubleJumpPushSec,
			feel.doubleJumpPushAccel,
			feel.leapPushPow,
			math.max(pushMul, 0.5),
			dt
		)
		_syncTakeoffFlatFromHrp(self, hrp)
	elseif self._doubleLeapPushUntil then
		_syncTakeoffFlatFromHrp(self, hrp)
		self._doubleLeapPushUntil = nil
	end

	if redirectActive == false and self._redirectUntil then
		self._redirectUntil = nil
		self._redirectAim = nil
	end
end

--[[
	是否满足「一帧反向」触发条件（须接近对向；普通急转 ~90° 不应误触）
	@param feel FeelParams - 手感
	@param look Vector3 - 马头
	@param intent Vector3 - 本帧期望朝向
	@param hrp BasePart - HRP
	@return boolean - 可触发提交式 180
]]
local function _shouldCommitAboutFace(feel: FeelParams, look: Vector3, intent: Vector3, hrp: BasePart): boolean
	local alignDot = look:Dot(intent)
	if alignDot <= feel.aboutFaceDot then
		return true
	end
	local localIntent = hrp.CFrame:VectorToObjectSpace(intent)
	if localIntent.Z >= feel.aboutFaceStickBack then
		return true
	end
	-- 行进方向与意图明显对向（刹旧动量掉头）；阈值须严于 aboutFaceDot，避免 ~100° 急转误触
	local travel = _flatUnit(hrp.AssemblyLinearVelocity)
	if travel and travel:Dot(intent) <= feel.aboutFaceTravelDot then
		return true
	end
	return false
end

--[[
	开始提交式地面 180：锁定目标偏航（松杆也会拧完）
	@param self GroundMountDriver - 驱动
	@param look Vector3 - 触发时马头
	@param intent Vector3 - 触发时期望朝向
]]
local function _beginAboutFace(self: GroundMountDriver, look: Vector3, intent: Vector3)
	local targetFlat = intent
	local reverseLook = -look
	-- 接近正反 180 时锁 -look，避免相机微抖把目标拧歪
	if reverseLook:Dot(intent) >= 0.7 then
		targetFlat = reverseLook
	end
	self._aboutFaceActive = true
	self._aboutFaceTargetYaw = _yawFromFlat(targetFlat)
end

--[[
	结束提交式 180，并进入连续掉头冷却
	@param self GroundMountDriver - 驱动
]]
local function _endAboutFace(self: GroundMountDriver)
	self._aboutFaceActive = false
	self._aboutFaceTargetYaw = nil
	local feel = self._feel
	local cd = if feel then feel.aboutFaceCooldownSec else DEFAULT_ABOUT_FACE_COOLDOWN_SEC
	self._aboutFaceReadyAt = os.clock() + cd
end

--[[
	当前是否允许新开提交式 180（冷却中则否）
	@param self GroundMountDriver - 驱动
	@return boolean - 可提交
]]
local function _canStartAboutFace(self: GroundMountDriver): boolean
	return os.clock() >= (self._aboutFaceReadyAt or 0)
end

--[[
	推进提交式 180；松杆无输入时也会继续转到目标
	@param self GroundMountDriver - 驱动
	@param feel FeelParams - 手感
	@param look Vector3 - 当前马头
	@param dt number - 帧间隔
	@param hrp BasePart - HRP
	@return (boolean, Vector3) - 仍在执行?, 新 look
]]
local function _tickAboutFace(
	self: GroundMountDriver,
	feel: FeelParams,
	look: Vector3,
	dt: number,
	hrp: BasePart
): (boolean, Vector3)
	local targetYaw = self._aboutFaceTargetYaw
	if type(targetYaw) ~= "number" then
		_endAboutFace(self)
		return false, look
	end

	_applyAboutFaceBrake(hrp, feel.aboutFaceBrake, dt)

	local turnMul = feel.aboutFaceTurnMul
	local maxRad = math.rad(feel.turnRateDeg) * turnMul
	local fromYaw = _yawFromFlat(look)
	local delta = _shortestAngle(fromYaw, targetYaw)
	local maxStep = maxRad * dt
	if math.abs(delta) > maxStep then
		delta = math.sign(delta) * maxStep
	end
	_applyYaw(hrp, fromYaw + delta)
	look = _flatUnit(hrp.CFrame.LookVector) or look

	local remain = math.abs(_shortestAngle(_yawFromFlat(look), targetYaw))
	if remain <= math.rad(feel.aboutFaceCompleteDeg) then
		_applyYaw(hrp, targetYaw)
		look = _flatUnit(hrp.CFrame.LookVector) or look
		_endAboutFace(self)
		return false, look
	end
	return true, look
end

--[[
	每帧：托雷特式转向 + 仅沿马头前进（须在 ControlModule 之后；且已劫持 moveFunction）
	@param self GroundMountDriver - 驱动
	@param dt number - 帧间隔
]]
function GroundMountDriver.update(self: GroundMountDriver, dt: number)
	if not self._active or not self._feel then
		return
	end
	local hum = self._humanoid
	local hrp = self._hrp
	if not hum or not hrp or not hum.Parent or not hrp.Parent then
		return
	end
	if dt ~= dt or dt <= 0 then
		return
	end

	hum.AutoRotate = false

	local feel = self._feel
	local airborne = _isAirborne(hum)
	local inFlipWindow = type(self._airFlipUntil) == "number" and os.clock() < (self._airFlipUntil :: number)
	if not inFlipWindow then
		self._airFlipUntil = nil
	end

	if self._controlModule == nil then
		self._controlModule = _getControlModule()
		_hijackControlMove(self)
	elseif self._savedMoveFunction == nil then
		_hijackControlMove(self)
	end

	local intent, throttle = _readStickIntent(self._controlModule, hum)
	local look = _flatUnit(hrp.CFrame.LookVector) or Vector3.new(0, 0, -1)

	_updateAirGravityAssist(self, hrp, airborne)

	if airborne then
		_endAboutFace(self)
	elseif intent and not self._aboutFaceActive and _canStartAboutFace(self) and _shouldCommitAboutFace(feel, look, intent, hrp) then
		-- 一帧反向即可提交；后续无输入也会拧完（受连续 180 冷却约束）
		_beginAboutFace(self, look, intent)
	end

	local vel = hrp.AssemblyLinearVelocity
	local flatSpeed = Vector3.new(vel.X, 0, vel.Z).Magnitude
	local cruiseSpeed = math.max(hum.WalkSpeed, 8)
	local speed01 = math.clamp(flatSpeed / cruiseSpeed, 0, 1)

	-- 起跳继承 + 锁定水平速基准
	if airborne then
		if not self._takeoffHandled then
			_applyTakeoffInherit(self, speed01)
		end
		if self._takeoffFlatSpeed == nil then
			self._takeoffFlatSpeed = flatSpeed
		end
		if self._airborneSince == nil then
			self._airborneSince = os.clock()
		end
	else
		_clearAirJumpState(self)
	end

	if self._aboutFaceActive and not airborne then
		local _still
		_still, look = _tickAboutFace(self, feel, look, dt, hrp)
		hum:Move(Vector3.zero, false)
	elseif intent then
		local alignDotForThrust = look:Dot(intent)
		local turnMul = _computeTurnMul(feel, speed01, false, airborne, inFlipWindow)
		local maxRad = math.rad(feel.turnRateDeg) * turnMul
		local fromYaw = _yawFromFlat(look)
		local toYaw = _yawFromFlat(intent)
		local delta = _shortestAngle(fromYaw, toYaw)
		local maxStep = maxRad * dt
		if math.abs(delta) > maxStep then
			delta = math.sign(delta) * maxStep
		end
		-- 地面巡航：偏航轴随速度后移；空中/近静止仍绕 HRP（掉头后躯可甩）
		local pivotBack = 0
		if not airborne and feel.turnPivotBackStuds > 0 then
			pivotBack = feel.turnPivotBackStuds * speed01
		end
		_applyYaw(hrp, fromYaw + delta, pivotBack)
		look = _flatUnit(hrp.CFrame.LookVector) or look

		-- 弯中掉推力看「意图 vs 当前马头」夹角，勿用 yaw 后 look（会与限速转向耦合导致额外掉速）
		local turnAlignFactor = if airborne then 1 else _computeTurnAlignFactor(feel, alignDotForThrust, false)
		local airThrottleMul = 1
		if airborne and inFlipWindow then
			airThrottleMul = feel.airFlipThrottleMul
		elseif airborne then
			airThrottleMul = feel.airThrottleMul
		end
		hum:Move(look * (throttle * turnAlignFactor * airThrottleMul), false)
	else
		hum:Move(Vector3.zero, false)
	end

	if airborne then
		_applyAirHorizontalChain(self, hrp, look, intent, throttle, speed01, dt, inFlipWindow)
	end

	if not airborne and hum.FloorMaterial ~= Enum.Material.Air then
		-- 仅从空中落地时通知表现层；起跳窗（仍在地面）勿 onLanded
		if self._airborneSince ~= nil then
			local presentationLand = self._presentation
			if presentationLand and presentationLand.onLanded then
				presentationLand:onLanded()
			end
		end
		_clearAirJumpState(self)
	end

	local presentation = self._presentation
	if presentation and presentation.updateGait then
		presentation:updateGait({
			airborne = airborne or self._firstJumpPending == true,
			flatSpeed = flatSpeed,
			speed01 = speed01,
			gait = if speed01 >= 0.5 then "Gallop" else "Walk",
		})
	end
end

--[[
	离开骑乘
	@param self GroundMountDriver - 驱动
	@param _reason string - MountForceExitReason
]]
function GroundMountDriver.exit(self: GroundMountDriver, _reason: string)
	if self._jumpConn then
		self._jumpConn:Disconnect()
		self._jumpConn = nil
	end
	if self._stateConn then
		self._stateConn:Disconnect()
		self._stateConn = nil
	end

	local character = self._character
	local ownerId = self._modifierOwnerId
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

	if character and ownerId then
		local bind = _getMoveSpeedBind(character)
		if bind and bind.popModifier then
			bind.popModifier(ownerId)
		end
	end

	if hum and hum.Parent then
		if self._savedJumpHeight ~= nil then
			hum.JumpHeight = self._savedJumpHeight
		end
		if self._savedAutoRotate ~= nil then
			hum.AutoRotate = self._savedAutoRotate
		end
	end

	if self._weld then
		self._weld:Destroy()
		self._weld = nil
	end
	if self._placeholderPart then
		self._placeholderPart:Destroy()
		self._placeholderPart = nil
	end
	if self._airForce then
		self._airForce:Destroy()
		self._airForce = nil
	end
	if self._airForceAttach then
		self._airForceAttach:Destroy()
		self._airForceAttach = nil
	end

	self._active = false
	self._character = nil
	self._humanoid = nil
	self._hrp = nil
	self._modifierOwnerId = nil
	self._feel = nil
	self._controlModule = nil
	self._savedJumpHeight = nil
	self._savedAutoRotate = nil
	self._doubleJumpUsed = false
	self._firstJumpPending = false
	_clearAirJumpState(self)
	self._aboutFaceActive = false
	self._aboutFaceTargetYaw = nil
	self._aboutFaceReadyAt = 0
end
--[[
	销毁驱动
	@param self GroundMountDriver - 驱动
]]
function GroundMountDriver.destroy(self: GroundMountDriver)
	self:exit(EnumMgr.MountForceExitReason.InvalidState)
end

--[[
	是否激活中
	@param self GroundMountDriver - 驱动
	@return boolean - 是否 Active
]]
function GroundMountDriver.isActive(self: GroundMountDriver): boolean
	return self._active
end

--[[
	当前平面速度估计
	@param self GroundMountDriver - 驱动
	@return number? - 速度；未激活时 nil
]]
function GroundMountDriver.getFlatSpeed(self: GroundMountDriver): number?
	if not self._active or not self._hrp then
		return nil
	end
	local vel = self._hrp.AssemblyLinearVelocity
	return Vector3.new(vel.X, 0, vel.Z).Magnitude
end

return GroundMountDriver
