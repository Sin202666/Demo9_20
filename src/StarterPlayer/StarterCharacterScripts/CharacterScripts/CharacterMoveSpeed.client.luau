--[[
	Module: CharacterMoveSpeed
	Description: 角色移动速度统一控制（MoveSynthesis）；Attribute + Modifier 栈合成后唯一写 WalkSpeed
	Author: 林奥宇
	Created: 2026-07-03
	Last Modified: 2026-08-31

	功能：
	- 状态 Attribute（RELEASE_SKILL_STATE 等）乘算移速
	- CharacterMoveSpeedBind Modifier 栈（技能锁速、CharacterControl:Sprint / Lock:Move、坐骑 accel/decel 覆盖等）；业务禁止裸写 WalkSpeed
	- 奔跑速由 CharacterControl → Control:Sprint Modifier 提供（不再用 RUN_STATE / LeftControl）
	- NetMsg.UPDATE_CHARACTER_SPEED Bindable 触发更新（经 CharacterMoveSpeedBind 单次注册）
	- ExpectedWalkSpeed（LocalPlayer Attribute）：合成后的状态最大移速，供 Animate 等判断跑/走
	- MoveDirection 驱动：无输入降至 0，有输入升至合成目标（曲线取自 AnimateSetting.SpeedCurve；时长可由 Modifier accelDuration/decelDuration 覆盖）

	加载方式：
	角色生成时由引擎启动；Bind 用 require(script.Parent.CharacterMoveSpeedBind)。
	WalkSpeed 只由本脚本写入。

	示例：
		NetWork.FireBindable(NetMsg.UPDATE_CHARACTER_SPEED, 0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		Bind.pushModifier("LockMovement:NewRoll:0", { mul = 0 })
		Bind.pushModifier("Control:Sprint", { add = runAdd })
]]

-- ========================================
-- 服务引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local RunService = Utils.RunService
local TweenService = Utils.TweenService
local SystemGameConfig = Utils.SystemGameConfig
local LocalPlayer = Utils.LocalPlayer

-- ========================================
-- 模块引用
-- ========================================
local CharacterMoveSpeedBind = require(script.Parent:WaitForChild("CharacterMoveSpeedBind"))
local AnimateSetting = require(script.Parent.Parent.Animate.AnimateSetting)

local Character: Model = script.Parent.Parent
local Humanoid: Humanoid = Character:WaitForChild("Humanoid")

-- ========================================
-- 常量
-- ========================================
local DEFAULT_BASE_SPEED = 16
local _walkSpeed = SystemGameConfig.GetValue({ "CharacterMoveSpeed", "玩家行走移动速度" })
local BASE_SPEED = if type(_walkSpeed) == "number" then _walkSpeed else DEFAULT_BASE_SPEED

-- 只消费派生 SpeedCurve（权威在 AnimateSetting.MotionPhase.accel/decelPhase）
local _speedCurve = AnimateSetting.SpeedCurve or {}
local ENABLE_SPEED_SMOOTH_TRANSITION = _speedCurve.ENABLE ~= false

local DECEL_DURATION = (type(_speedCurve.DECEL_DURATION) == "number" and _speedCurve.DECEL_DURATION) or 0.28
local DECEL_EASING_STYLE = _speedCurve.DECEL_EASING_STYLE or Enum.EasingStyle.Quad
local DECEL_EASING_DIRECTION = _speedCurve.DECEL_EASING_DIRECTION or Enum.EasingDirection.Out

local ACCEL_DURATION = (type(_speedCurve.ACCEL_DURATION) == "number" and _speedCurve.ACCEL_DURATION) or 0.28
local ACCEL_EASING_STYLE = _speedCurve.ACCEL_EASING_STYLE or Enum.EasingStyle.Quad
local ACCEL_EASING_DIRECTION = _speedCurve.ACCEL_EASING_DIRECTION or Enum.EasingDirection.Out

local MOVE_DIRECTION_THRESHOLD = 0.01
local SPEED_EPSILON = 0.01
local EXPECTED_SPEED_EPSILON = 1e-4

local EXPECTED_WALKSPEED_ATTR = "ExpectedWalkSpeed"

-- 奔跑加成已迁至 CharacterControl Sprint Modifier；此处仅保留技能态乘算 Attribute
local ATTR_RELEASE_SKILL_STATE = "RELEASE_SKILL_STATE"
local ATTR_RELEASE_SKILL_STATE_HALF = "RELEASE_SKILL_STATE_HALF"
local SKILL_STATE_SPEED_MUL = 0.1
local SKILL_STATE_HALF_SPEED_MUL = 0.5

local ROLE_STATE_SPEED_ADD: { [string]: number } = {}

local ROLE_STATE_SPEED_MUL = {
	[ATTR_RELEASE_SKILL_STATE] = SKILL_STATE_SPEED_MUL,
	[ATTR_RELEASE_SKILL_STATE_HALF] = SKILL_STATE_HALF_SPEED_MUL,
}

-- ========================================
-- 私有变量
-- ========================================
local _lastPublishedExpectedWalkSpeed: number? = nil
local _activeTransitionConnection: RBXScriptConnection? = nil
local _heartbeatConn: RBXScriptConnection? = nil
local _ancestryConn: RBXScriptConnection? = nil

local _moveDirTransition = {
	startSpeed = 0,
	targetSpeed = 0,
	elapsed = 0,
	duration = 0,
	style = Enum.EasingStyle.Quad,
	direction = Enum.EasingDirection.Out,
}

-- ========================================
-- 私有函数
-- ========================================

--[[
	发布 ExpectedWalkSpeed 到 LocalPlayer Attribute（去重写入）

	@param value number - 当前状态可达到的最大移速
]]
local function _publishExpectedWalkSpeed(value: number)
	value = math.max(0, value)
	if _lastPublishedExpectedWalkSpeed ~= nil
		and math.abs(_lastPublishedExpectedWalkSpeed - value) < EXPECTED_SPEED_EPSILON
	then
		return
	end
	_lastPublishedExpectedWalkSpeed = value
	LocalPlayer:SetAttribute(EXPECTED_WALKSPEED_ATTR, value)
end

--[[
	根据 LocalPlayer Attribute 计算 Attribute 层目标移速（不含 Modifier）

	@return number - 加成/乘算后的目标移速（≥ 0）
]]
local function _calculateAttributeTargetSpeed(): number
	local speed = BASE_SPEED
	for attr, v in ROLE_STATE_SPEED_ADD do
		if LocalPlayer:GetAttribute(attr) then
			speed = speed + v
		end
	end
	for attr, v in ROLE_STATE_SPEED_MUL do
		if LocalPlayer:GetAttribute(attr) then
			speed = speed * v
		end
	end
	return math.max(0, speed)
end

--[[
	MoveSynthesis：Attribute 目标 × Modifier 栈

	@return number - 合成后的目标移速（≥ 0）；hardLock 时为 0
]]
local function _calculateSynthesizedSpeed(): number
	return CharacterMoveSpeedBind.applyModifiers(_calculateAttributeTargetSpeed())
end

--[[
	计算缓动因子；GetValue 失败时回退线性 t

	@param t number - 归一化进度 [0, 1]
	@param style Enum.EasingStyle - 缓动样式
	@param direction Enum.EasingDirection - 缓动方向
	@return number - 插值因子
]]
local function _easingFactor(t: number, style: Enum.EasingStyle, direction: Enum.EasingDirection): number
	local success, factor = pcall(function()
		return TweenService:GetValue(t, style, direction)
	end)
	if not success or type(factor) ~= "number" then
		return t
	end
	return factor
end

--[[
	瞬间设置 Humanoid.WalkSpeed

	@param speed number - 目标移速
]]
local function _applySpeedInstant(speed: number)
	if Humanoid and Humanoid.Parent then
		Humanoid.WalkSpeed = speed
	end
end

--[[
	使用 TweenService 缓动过渡到目标移速

	@param duration number - 过渡时间（秒）
	@param easingStyle Enum.EasingStyle? - 缓动样式，默认 Quad
	@param easingDirection Enum.EasingDirection? - 缓动方向，默认 Out
]]
local function _transitionToSpeed(
	duration: number,
	easingStyle: Enum.EasingStyle?,
	easingDirection: Enum.EasingDirection?
)
	if not ENABLE_SPEED_SMOOTH_TRANSITION or type(duration) ~= "number" or duration <= 0 or duration ~= duration then
		local t = _calculateSynthesizedSpeed()
		_publishExpectedWalkSpeed(t)
		_applySpeedInstant(t)
		return
	end

	if not Humanoid or not Humanoid.Parent then
		return
	end

	local startSpeed = Humanoid.WalkSpeed
	local targetSpeed = _calculateSynthesizedSpeed()
	_publishExpectedWalkSpeed(targetSpeed)
	if math.abs(startSpeed - targetSpeed) < SPEED_EPSILON then
		return
	end

	if _activeTransitionConnection then
		_activeTransitionConnection:Disconnect()
		_activeTransitionConnection = nil
	end

	local style = (typeof(easingStyle) == "EnumItem" and easingStyle.EnumType == Enum.EasingStyle)
			and easingStyle
		or Enum.EasingStyle.Quad
	local direction = (typeof(easingDirection) == "EnumItem" and easingDirection.EnumType == Enum.EasingDirection)
			and easingDirection
		or Enum.EasingDirection.Out

	local elapsed = 0
	_activeTransitionConnection = RunService.Heartbeat:Connect(function(dt: number)
		if not Humanoid or not Humanoid.Parent then
			if _activeTransitionConnection then
				_activeTransitionConnection:Disconnect()
				_activeTransitionConnection = nil
			end
			return
		end

		elapsed = elapsed + dt
		local t = math.min(elapsed / duration, 1)
		local factor = _easingFactor(t, style, direction)
		Humanoid.WalkSpeed = startSpeed + (targetSpeed - startSpeed) * factor

		if t >= 1 then
			if _activeTransitionConnection then
				_activeTransitionConnection:Disconnect()
				_activeTransitionConnection = nil
			end
		end
	end)
end

--[[
	更新角色移速（瞬间或缓动）

	@param duration number? - 过渡时间（秒），nil/0 为瞬间
	@param easingStyle Enum.EasingStyle? - 缓动样式
	@param easingDirection Enum.EasingDirection? - 缓动方向
]]
local function _updateCharacterSpeed(
	duration: number?,
	easingStyle: Enum.EasingStyle?,
	easingDirection: Enum.EasingDirection?
)
	if not ENABLE_SPEED_SMOOTH_TRANSITION or type(duration) ~= "number" or duration <= 0 or duration ~= duration then
		local target = _calculateSynthesizedSpeed()
		_publishExpectedWalkSpeed(target)
		_applySpeedInstant(target)
		return
	end
	_transitionToSpeed(duration, easingStyle, easingDirection)
end

--[[
	根据 MoveDirection 每帧插值 WalkSpeed

	@param dt number - 帧间隔（秒）
]]
local function _updateMoveDirectionTransition(dt: number)
	if not Humanoid or not Humanoid.Parent then
		return
	end

	_publishExpectedWalkSpeed(_calculateSynthesizedSpeed())

	if _activeTransitionConnection then
		return
	end

	local hasInput = Humanoid.MoveDirection.Magnitude >= MOVE_DIRECTION_THRESHOLD
	local targetSpeed = hasInput and _calculateSynthesizedSpeed() or 0
	local currentSpeed = Humanoid.WalkSpeed

	if math.abs(currentSpeed - targetSpeed) < SPEED_EPSILON then
		return
	end

	if not ENABLE_SPEED_SMOOTH_TRANSITION then
		_applySpeedInstant(targetSpeed)
		return
	end

	local accelOverride, decelOverride = CharacterMoveSpeedBind.getMotionDurationOverrides()
	local accelDur = if type(accelOverride) == "number" then accelOverride else ACCEL_DURATION
	local decelDur = if type(decelOverride) == "number" then decelOverride else DECEL_DURATION

	local trans = _moveDirTransition
	if math.abs(trans.targetSpeed - targetSpeed) > SPEED_EPSILON then
		trans.startSpeed = currentSpeed
		trans.targetSpeed = targetSpeed
		trans.elapsed = 0
		trans.duration = hasInput and accelDur or decelDur
		trans.style = hasInput and ACCEL_EASING_STYLE or DECEL_EASING_STYLE
		trans.direction = hasInput and ACCEL_EASING_DIRECTION or DECEL_EASING_DIRECTION
	end

	trans.elapsed = trans.elapsed + dt
	local t = math.min(trans.elapsed / trans.duration, 1)
	local factor = _easingFactor(t, trans.style, trans.direction)
	Humanoid.WalkSpeed = trans.startSpeed + (trans.targetSpeed - trans.startSpeed) * factor
end

--[[
	角色销毁时断开单例服务连接并清理 Bindable handler
]]
local function _cleanup()
	CharacterMoveSpeedBind.clearHandler(_updateCharacterSpeed)
	CharacterMoveSpeedBind.clearAllModifiers()

	if _activeTransitionConnection then
		_activeTransitionConnection:Disconnect()
		_activeTransitionConnection = nil
	end
	if _heartbeatConn then
		_heartbeatConn:Disconnect()
		_heartbeatConn = nil
	end
	if _ancestryConn then
		_ancestryConn:Disconnect()
		_ancestryConn = nil
	end
end

-- ========================================
-- 初始化与事件绑定
-- ========================================
_updateCharacterSpeed()

CharacterMoveSpeedBind.setHandler(_updateCharacterSpeed)

_heartbeatConn = RunService.Heartbeat:Connect(function(dt: number)
	if Character.Parent == nil then
		return
	end
	_updateMoveDirectionTransition(dt)
end)

_ancestryConn = Character.AncestryChanged:Connect(function(_child: Instance, parent: Instance?)
	if parent == nil then
		_cleanup()
	end
end)
