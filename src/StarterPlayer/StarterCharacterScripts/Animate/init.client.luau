--[[
	Module: Animate (init.client)
	Description: 角色动画入口脚本，编排 locomotion、StrafeBlend、AirLean、Gate 暂停、FOV 与 Heartbeat 更新。
	Author: 林奥宇
	Created: 2026-07-03
	Last Modified: 2026-09-03

	协作：
	- ActionArbiter：统一动作表现仲裁（抑制 loco / 朝向 / 相机）；本脚本负责 Create
	  suppress/pause 对所有 claim OR；facing/camera 取最高 priority 条
	  BlendPolicy：Override 冻腿；Overlay 不停腿（上身技能）；React / FacingOnly 见 Constants
	- AnimationLayer：外围 Slot 播轨（Upper/FullBody/React）；Overlay 时 Gate 不冻基轨，Strafe 继续
	  Upper 资源须未键腿（经典轨无运行时 Mask）；Priority≥Action2；勿用 Idle 档盖 Land
	- AnimationModule：动画 Asset ID；业务可 opt-in actionClaim（可含 blendPolicy）占闸
	- LocoStyle：3C 基轨风格切换（StyleStack → 批量 bindBaseAction）；本脚本 Create(Default)
	  业务经 Utils.LocoStyle.GetForCharacter(character) 做 PushStyle/SetBaseStyle；勿再手写 BaseAnimation 表
	  Gate pauseBaseTracks 时 LocoStyle 推迟 rebind/续播，解闸自 FlushPending
	- CharacterMoveSpeed：写入 Player.ExpectedWalkSpeed；SpeedCurve/Transition 由 MotionPhase 单表派生
	- CameraModule：ShiftLock Attribute、FOV Helper、落地微震（经 FootLand）
	- GroundLocomotion / StrafeBlend / AirLean / ClimbAssist / AnimateMotionHelpers / AnimateFov：子模块职责拆分
	- ClimbAssist：HRP 探测 Truss，接近时 suppressRunLean → GroundLocomotion 视觉压 Run 前倾
	- AnimateFov：sprint FOV + 技能前冲脉冲（经 CameraImpulse 供 DashStyleRoll）；禁止业务平行 FOV Helper
	- CameraImpulse：技能只 emit FovPulse；本脚本 bind AnimateFov 为唯一消费者
	- ShiftLock 方向：StrafeBlend 连续混合；侧移/后退起停定稿为短 fade 直切（见 AnimateSetting）
	- 空中方向：ShiftLock + Jump/Fall 时 AirLean 写 R6 RootJoint.C0（非 Cardinal 轨）
	- 乘骑：Character.MountActive=true 时进入 Mounted 总闸，停更人型 loco/攀爬/Strafe；步态由 SystemMount

	权威划分：
	- 移速 / 加减速：CharacterMoveSpeed
	- 姿态 / 衔接轨 / 相对方向动画：Animate + GroundLocomotion（受 ActionArbiter.suppressLoco 抑制）
	- 基轨资源风格：LocoStyle（不改 FSM）
	- Gate pauseBase：停基轨；解闸 = resume 使能 + invalidateBasePose + resyncAfterBaseUnpause（按当前意图直切，不回放冻结轨、不播 Start*）
	- Overlay（suppress/pause 均为 false）：基轨与 Strafe 原样继续；上身由 AnimationLayer Upper 轨覆盖
	- ShiftLock 偏航：facingOwner == Animate 时由 RenderStep(Character+1) 唯一写 HRP；Heartbeat 只同步锁定态供 loco
	  Overlay 施法若 facingOwner=External，本写口让出；锁敌朝向由技能 LookAt 等模块写，不经 Animate
	- 方向语义（loco）：ShiftLock 下以相机水平前向为基准（_getShiftLockAwareLookVector），不依赖本帧 HRP 偏航
	- 侧移/后退起停：非前向跳过 Start*/Stop*；方向资源未补齐前不半开
	- 空中 lean：Stepped 写 RootJoint；不改 HRP；Gate suppress/pause 时 reset
	- Mounted：人型 Jump/Land/Climb/Strafe/ClimbAssist 全部停更；勿在此写坐骑 gait

	Animator Priority 分层（抗业务 Idle 盖落地靠档位，不靠时间锁）：
	- Idle：待机 / SwimIdle / 装饰表情
	- Movement：Walk/Run/Fall/Jump/衔接/Climb
	- Action：Land / LightLand（压 Idle 业务与 Movement 腿；真技能用 Action+actionClaim 可合法取消）
	- Action2+：AnimationLayer Upper Overlay（压 Movement 上身，腿仍由未键控透出 loco）

	遗留 Attribute（经 ActionArbiter Bridge）：
	- JetPacking / FacingOverride / SkillActionLock → Acquire；新业务请直调 Acquire 或 AnimationLayer
	- MountActive（Character）：SystemMount 乘骑期置 true；本脚本 Mounted 总闸

	示例：脚本随 Character 生成自动运行；外部可通过 Animate:BasePosChanged 监听姿态变化。
	风格切换：local ctrl = Utils.LocoStyle.GetForCharacter(character); ctrl:PushStyle("Equip", "Heavy", Utils.LocoStyle.Priority.Equip)
]]

-- 用引擎 warn：确认 Studio 吃到本文件（无此行 = 仍在跑旧 Animate）
warn("[Animate] boot live-no-graph")

-- 模块引用
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
-- Class 未挂 Utils（全仓惯例：直接 require Class.Class 取类型）
local Class = require(game.ReplicatedFirst.AllSideCode.Class.Class)
local CameraModule = Utils.CameraModule
local ActionArbiter = Utils.ActionArbiter
local LocoStyle = Utils.LocoStyle
local CameraImpulse = Utils.CameraImpulse
local RunService = Utils.RunService
local LocalPlayer = Utils.LocalPlayer
local UserInputService = Utils.UserInputService
local TweenService = Utils.TweenService
local SystemGameConfig = Utils.SystemGameConfig

local Setting = require(script:WaitForChild("AnimateSetting"))
local AnimateModule = require(script:WaitForChild("AnimateModule"))
local FootLand = require(script:WaitForChild("FootLand"))
local AnimateMotionHelpers = require(script:WaitForChild("AnimateMotionHelpers"))
local GroundLocomotion = require(script:WaitForChild("GroundLocomotion"))
local AnimateFov = require(script:WaitForChild("AnimateFov"))
local StrafeBlend = require(script:WaitForChild("StrafeBlend"))
local AirLean = require(script:WaitForChild("AirLean"))
local ClimbAssist = require(script:WaitForChild("ClimbAssist"))

-- 类型
type AnimateType = typeof(Class.AnimateType)

-- 角色组件
local Character = script.Parent
local Humanoid: Humanoid = Character:WaitForChild("Humanoid")
local HRP: BasePart = Character:WaitForChild("HumanoidRootPart")
local Animate: AnimateType = AnimateModule

-- 私有变量
local _connections: { RBXScriptConnection } = {}
local _playerNowRunSpeed = 0
local _isShiftLocked = false
local _shiftLockFacingOwned = false
local _basePausedByGate = false
local SHIFT_LOCK_FACE_STEP_NAME = "AnimateShiftLockFaceCamera"
-- Spike Disable 后 _cleanup 不会跑，同名 RenderStep 会残留；先清再绑
pcall(function()
	RunService:UnbindFromRenderStep(SHIFT_LOCK_FACE_STEP_NAME)
end)
local MOUNT_ACTIVE_ATTR = "MountActive"
local FLAT_LOOK_EPS = 1e-3
local locoStyle: any = nil
local _wasMountedMode = false

local _arbiterCfg = Setting.ActionArbiter or {}
local arbiter = ActionArbiter.Create(Character, {
	localPlayer = LocalPlayer,
	enableAttributeBridge = _arbiterCfg.enableAttributeBridge ~= false,
	-- Skill 占闸由 SkillActionLock 直调；Attribute Bridge 默认关
	enableSkillActionLock = _arbiterCfg.enableSkillActionLock == true,
})
local _gateSnapshot = arbiter:GetSnapshot()

local _footStepEnabled = SystemGameConfig.GetValue({ "FootStep", "启用" }) ~= false

--[[
	为指定 Base 轨生成 FootStep Marker（Strafe 下仅 leader 触发）
	@param actionName string - BaseActions 键名
	@return table - MarkerEvents 或空表
]]
local function _footStepMarkersFor(actionName: string): { [string]: (string) -> () }
	if not _footStepEnabled then
		return {}
	end
	return {
		["FootStep"] = function(param: string)
			if not Animate:CanEmitFootStepFrom(actionName) then
				return
			end
			FootLand.FootLand(Character, param)
		end,
	}
end

local userAnimateScaleRunSuccess, userAnimateScaleRunValue = pcall(function()
	return UserSettings():IsUserFeatureEnabled("UserAnimateScaleRun")
end)
local userAnimateScaleRun = userAnimateScaleRunSuccess and userAnimateScaleRunValue

--[[
	当前是否视为 ShiftLock（Attribute 或 MouseBehavior.LockCenter）
	@return boolean - true 表示 IsShiftLocked 或鼠标已 LockCenter
]]
local function _readShiftLockState(): boolean
	if LocalPlayer:GetAttribute("IsShiftLocked") == true then
		return true
	end
	return UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter
end

--[[
	ShiftLock 下用相机水平前向作相对方向基准；否则用角色朝向
	@return Vector3 - 水平前向参考向量；无相机时回退 HRP LookVector
]]
local function _getShiftLockAwareLookVector(): Vector3
	if _isShiftLocked then
		local cam = workspace.CurrentCamera
		if cam then
			return cam.CFrame.LookVector
		end
	end
	return HRP:GetPivot().LookVector
end

local motionHelpers = AnimateMotionHelpers.create({
	character = Character,
	hrp = HRP,
	humanoid = Humanoid,
	setting = Setting,
	userAnimateScaleRun = userAnimateScaleRun,
	getReferenceLookVector = _getShiftLockAwareLookVector,
})

--[[
	注册 RBXScriptConnection，便于角色销毁时统一 Disconnect
	@param conn RBXScriptConnection - 待追踪连接；destroy 时统一 Disconnect
]]
local function _trackConnection(conn: RBXScriptConnection)
	table.insert(_connections, conn)
end

--[[
	ActionArbiter 是否抑制 locomotion（读仲裁器当前快照，避免过期 _gateSnapshot）
	@return boolean - true 表示 suppressLoco，本帧不应推进地面 loco
]]
local function _isLocoSuppressed(): boolean
	if arbiter and arbiter.GetSnapshot then
		local snap = arbiter:GetSnapshot()
		_gateSnapshot = snap
		return snap.suppressLoco == true
	end
	return _gateSnapshot.suppressLoco == true
end

--[[
	是否处于乘骑总闸（与步行 loco 分离；由 SystemMount 写 MountActive）
	@return boolean - Mounted
]]
local function _isMountedMode(): boolean
	return Character:GetAttribute(MOUNT_ACTIVE_ATTR) == true
end

--[[
	前向声明：Gate 变更时 pause/resume base（在 groundLoco 创建后赋值）
]]
local _onGateChanged: (any) -> ()

-- ClimbAssist 须先于 GroundLocomotion 创建，以便 deps 闭包可读 getState
local climbAssist = ClimbAssist.create({
	character = Character,
	humanoid = Humanoid,
	hrp = HRP,
	setting = Setting,
	isLocoSuppressed = _isLocoSuppressed,
})

local groundLoco = GroundLocomotion.create({
	animate = Animate,
	humanoid = Humanoid,
	character = Character,
	localPlayer = LocalPlayer,
	setting = Setting,
	getRunAnimationSpeed = motionHelpers.getRunAnimationSpeed,
	getRelativeMoveDirection = motionHelpers.getRelativeMoveDirection,
	isShiftLocked = function()
		return _isShiftLocked
	end,
	isLocoSuppressed = _isLocoSuppressed,
	isStrafeBlendEnabled = function()
		local cfg = Setting.StrafeBlend
		return cfg == nil or cfg.ENABLE ~= false
	end,
	getSuppressRunLean = function()
		return climbAssist.getState().suppressRunLean == true
	end,
})

local strafeBlend = StrafeBlend.create({
	animate = Animate,
	setting = Setting,
	getMoveYaw = motionHelpers.getMoveYaw,
	getCardinalWeights = motionHelpers.getCardinalWeights,
	getRunAnimationSpeed = motionHelpers.getRunAnimationSpeed,
	isShiftLocked = function()
		return _isShiftLocked
	end,
	isLocoSuppressed = _isLocoSuppressed,
	getGroundStable = groundLoco.getGroundStable,
	canStrafeBlend = groundLoco.canStrafeBlend,
	getMoveSpeed = function()
		return _playerNowRunSpeed
	end,
})

local airLean = AirLean.create({
	character = Character,
	hrp = HRP,
	setting = Setting,
	getMoveYaw = motionHelpers.getMoveYaw,
	getAirPose = groundLoco.getAirPose,
	isGroundMovePose = groundLoco.isGroundMovePose,
	isShiftLocked = function()
		return _isShiftLocked
	end,
	isSuppressed = function()
		local snap = _gateSnapshot
		if snap.suppressLoco == true or snap.pauseBaseTracks == true then
			return true
		end
		-- 接近梯子时清掉空中程序 lean，避免 RootJoint 倾侧挤开 Truss
		return climbAssist.getState().suppressRunLean == true
	end,
})

--[[
	根据 Gate 快照暂停或恢复基本动画。
	以 arbiter:GetSnapshot() 为准；并校正 BaseActionEnabled 与 wantPause 脱节（第二次技能后常见）。
	@param snap any - 仲裁快照（含 pauseBaseTracks/suppressLoco/facingOwner）；可能已过期，仅作 GetSnapshot 失败时的回退
]]
_onGateChanged = function(snap)
	local latest = arbiter and arbiter.GetSnapshot and arbiter:GetSnapshot() or snap
	_gateSnapshot = latest
	local wantPause = latest.pauseBaseTracks == true

	if wantPause then
		if not _basePausedByGate or Animate.BaseActionEnabled then
			_basePausedByGate = true
			if Animate.BaseActionEnabled then
				strafeBlend.shutdown()
				airLean.reset()
				groundLoco.abortDriver()
				groundLoco.clearLandTimingWindows()
				Animate:stopBaseAction()
			end
		end
		return
	end

	-- 解冻：_basePausedByGate 或 BaseActionEnabled 任一脱节都强制接腿
	local needResume = _basePausedByGate or not Animate.BaseActionEnabled
	_basePausedByGate = false
	if needResume then
		if not Animate.BaseActionEnabled then
			Animate:resumeBaseAction()
		end
		Animate:invalidateBasePose()
		groundLoco.resyncAfterBaseUnpause()
	elseif latest.suppressLoco == true then
		airLean.reset()
	end
end

local fovController = AnimateFov.create({
	character = Character,
	cameraModule = CameraModule,
	runService = RunService,
	tweenService = TweenService,
	setting = Setting,
	getPlayerRunSpeed = function()
		return _playerNowRunSpeed
	end,
	getExpectedWalkSpeed = function()
		local attrName = Setting.EXPECTED_WALKSPEED_ATTRIBUTE or "ExpectedWalkSpeed"
		local expected = LocalPlayer:GetAttribute(attrName)
		if type(expected) == "number" and expected == expected and expected >= 0 then
			return expected
		end
		return 0
	end,
	getHasMoveIntent = function()
		local threshold = Setting.MOVE_INTENT_FOR_LOCO
		if type(threshold) ~= "number" or threshold ~= threshold or threshold < 0 then
			threshold = 0.01
		end
		return Humanoid.MoveDirection.Magnitude >= threshold
	end,
	shouldSuppressSprintFov = function()
		-- 外部接管镜头，或硬控冻住 loco/基轨，或乘骑 → 抑制 sprint FOV
		if Character:GetAttribute(MOUNT_ACTIVE_ATTR) == true then
			return true
		end
		local snap = _gateSnapshot
		return snap.cameraOwner ~= ActionArbiter.CameraOwner.Default
			or snap.suppressLoco == true
			or snap.pauseBaseTracks == true
	end,
	shouldReleaseSprintFov = function()
		return groundLoco.shouldReleaseSprintFov()
	end,
})
CameraImpulse.bind(Character, {
	playFovPulse = fovController.playDashImpulse,
	cancelFovPulse = fovController.cancelDashImpulse,
	isFovPulseActive = fovController.isDashActive,
})

-- 订阅 Gate；并立即应用当前快照（Bridge 可能已 Acquire）
local _unsubGate: (() -> ())? = arbiter:OnChanged(_onGateChanged)
_onGateChanged(arbiter:GetSnapshot())

-- ---------------------------------------------------------------------------
-- Humanoid 初始状态
-- ---------------------------------------------------------------------------
Humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
Humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
Humanoid:SetStateEnabled(Enum.HumanoidStateType.PlatformStanding, false)

-- ---------------------------------------------------------------------------
-- 动画资源绑定（经 LocoStyle Default；业务切换用 GetForCharacter）
-- ---------------------------------------------------------------------------
locoStyle = LocoStyle.Create(Character, {
	animate = Animate,
	arbiter = arbiter,
	resyncAfterBaseUnpause = groundLoco.resyncAfterBaseUnpause,
	footStepMarkersFor = _footStepMarkersFor,
})

-- 初始 BasePos 已是 Idle，LocoStyle 只绑轨不 resync；Idle 稳态 update 也不重入，不接腿会一直 T-pose
if not Animate.BaseActionEnabled then
	Animate:resumeBaseAction()
end
Animate:invalidateBasePose()
groundLoco.resyncAfterBaseUnpause()
do
	local playingN = 0
	pcall(function()
		local animator = Animate.Animator
		if animator then
			playingN = #animator:GetPlayingAnimationTracks()
		end
	end)
	warn(
		"[Animate] after LocoStyle BasePos=",
		Animate.BasePos,
		"BaseActionEnabled=",
		Animate.BaseActionEnabled,
		"playing=",
		playingN
	)
end

-- ---------------------------------------------------------------------------
-- ShiftLock 朝向
-- ---------------------------------------------------------------------------
--[[
	ShiftLock 期间关闭 AutoRotate；退出时恢复（仅恢复本脚本关掉的情况）
	@param locked boolean - 是否处于 ShiftLock
]]
local function _setAutoRotateForShiftLock(locked: boolean)
	if locked then
		Humanoid.AutoRotate = false
		_shiftLockFacingOwned = true
	elseif _shiftLockFacingOwned then
		Humanoid.AutoRotate = true
		_shiftLockFacingOwned = false
	end
end

--[[
	应用 ShiftLock 状态变化（朝向锁；退出时关闭 StrafeBlend）
	@param locked boolean - 新的锁定状态
]]
local function _applyShiftLockState(locked: boolean)
	if locked == _isShiftLocked then
		_setAutoRotateForShiftLock(locked)
		return
	end
	_isShiftLocked = locked
	_setAutoRotateForShiftLock(locked)
	if not locked then
		strafeBlend.shutdown()
	end
end

--[[
	ShiftLock 下是否由 Animate 拥有偏航写权限（否则不碰 HRP.CFrame）
	@return boolean - true 表示本帧可写朝向
]]
local function _canOwnShiftLockFacing(): boolean
	if not _isShiftLocked or Character.Parent == nil then
		return false
	end
	-- CharacterControl Look 锁：禁止 Animate 写 HRP 朝向（过场/载具 Transfer 等）
	if LocalPlayer:GetAttribute("IsControlLookLocked") == true then
		return false
	end
	-- 朝向所有权只看 Gate.facingOwner（与 suppressLoco 解耦）
	if _gateSnapshot.facingOwner ~= ActionArbiter.FacingOwner.Animate then
		return false
	end
	local st = Humanoid:GetState()
	if st == Enum.HumanoidStateType.Physics
		or st == Enum.HumanoidStateType.Ragdoll
		or st == Enum.HumanoidStateType.PlatformStanding
	then
		return false
	end
	return true
end

--[[
	将 HRP 水平偏航强制对齐摄像机看向（需求：ShiftLock 下不随 WASD 转身）。
	仅由 RenderStep 调用；保留线速度，清掉角速度，避免写 CFrame 后被物理/默认控制拧回移动方向。
	写口唯一：facingOwner==Animate 且非 Look 锁；不改 WalkSpeed / 位置权威。
]]
local function _updateShiftLockFacing()
	if not _canOwnShiftLockFacing() then
		return
	end
	Humanoid.AutoRotate = false
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	local look = cam.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < FLAT_LOOK_EPS then
		return
	end
	flat = flat.Unit
	local pos = HRP.Position
	local targetCF = CFrame.lookAt(pos, pos + flat)

	local facingCfg = Setting.ShiftLockFacing
	local minYawDeg = (facingCfg and type(facingCfg.minYawErrorDegrees) == "number") and facingCfg.minYawErrorDegrees or 0
	if minYawDeg > 0 then
		local currentFlat = Vector3.new(HRP.CFrame.LookVector.X, 0, HRP.CFrame.LookVector.Z)
		if currentFlat.Magnitude > FLAT_LOOK_EPS then
			local dot = math.clamp(currentFlat.Unit:Dot(flat), -1, 1)
			local errDeg = math.deg(math.acos(dot))
			if errDeg < minYawDeg then
				return
			end
		end
	end

	local linVel = HRP.AssemblyLinearVelocity
	HRP.CFrame = targetCF
	HRP.AssemblyLinearVelocity = linVel
	-- 禁止绕 Y 的残余角速度把角色拧向 MoveDirection
	local ang = HRP.AssemblyAngularVelocity
	HRP.AssemblyAngularVelocity = Vector3.new(ang.X, 0, ang.Z)
end

-- ---------------------------------------------------------------------------
-- Humanoid 事件
-- ---------------------------------------------------------------------------
_trackConnection(Humanoid.Running:Connect(function(walkspeed: number)
	_playerNowRunSpeed = walkspeed
	if _isMountedMode() then
		return
	end
	groundLoco.onRunning(walkspeed)
end))

_trackConnection(Humanoid.Jumping:Connect(function(active: boolean)
	if _isMountedMode() then
		return
	end
	groundLoco.onJumping(active)
end))

_trackConnection(Humanoid.FreeFalling:Connect(function(active: boolean)
	if _isMountedMode() then
		return
	end
	groundLoco.onFreeFalling(active)
end))

_trackConnection(Humanoid.Climbing:Connect(function(active: boolean)
	if _isMountedMode() then
		return
	end
	groundLoco.onClimbing(active)
end))

_trackConnection(Humanoid.Swimming:Connect(function(active: boolean)
	if _isMountedMode() then
		return
	end
	groundLoco.onSwimming(active)
end))

_trackConnection(Humanoid.StateChanged:Connect(function(old, newState)
	if _isMountedMode() then
		return
	end
	groundLoco.onStateChanged(old, newState)
end))

-- ---------------------------------------------------------------------------
-- ShiftLock Attribute
-- ---------------------------------------------------------------------------
_applyShiftLockState(_readShiftLockState())

_trackConnection(LocalPlayer:GetAttributeChangedSignal("IsShiftLocked"):Connect(function()
	_applyShiftLockState(_readShiftLockState())
end))

_trackConnection(UserInputService:GetPropertyChangedSignal("MouseBehavior"):Connect(function()
	_applyShiftLockState(_readShiftLockState())
end))

_trackConnection(Character:GetAttributeChangedSignal(MOUNT_ACTIVE_ATTR):Connect(function()
	local mounted = _isMountedMode()
	if mounted and not _wasMountedMode then
		strafeBlend.shutdown()
		airLean.reset()
		groundLoco.abortDriver()
		groundLoco.clearLandTimingWindows()
	elseif not mounted and _wasMountedMode then
		Animate:invalidateBasePose()
		groundLoco.resyncAfterBaseUnpause()
	end
	_wasMountedMode = mounted
end))
_wasMountedMode = _isMountedMode()

-- ---------------------------------------------------------------------------
-- Heartbeat 主循环（只读锁定态 + loco；禁止写 HRP 偏航）
-- ---------------------------------------------------------------------------
_trackConnection(RunService.Heartbeat:Connect(function(dt)
	if Character.Parent == nil then
		return
	end
	-- 同步锁定态 / AutoRotate；偏航唯一写口在 RenderStep
	_applyShiftLockState(_readShiftLockState())
	-- 乘骑总闸：停更人型 loco / 攀爬接近 / Strafe（步态归 SystemMount）
	if _isMountedMode() then
		return
	end
	-- 先探测梯子，再走 loco（同帧消费 suppressRunLean）
	climbAssist.update(dt)
	groundLoco.update(dt)
	strafeBlend.update(dt)
end))

-- 空中 lean：Stepped 在动画写关节之后叠加 R6 RootJoint.C0
_trackConnection(RunService.Stepped:Connect(function(_, dt)
	if Character.Parent == nil then
		return
	end
	if _isMountedMode() then
		return
	end
	airLean.apply(dt)
end))

-- 唯一写偏航：高于默认 Character 控制，身体始终朝摄像机看向，不随 S 转 180°
RunService:BindToRenderStep(
	SHIFT_LOCK_FACE_STEP_NAME,
	Enum.RenderPriority.Character.Value + 1,
	function()
		if Character.Parent == nil then
			return
		end
		-- 写前再读锁定态，避免同帧切换时用过期 _isShiftLocked
		_applyShiftLockState(_readShiftLockState())
		_updateShiftLockFacing()
	end
)

-- ---------------------------------------------------------------------------
-- 生命周期清理
-- ---------------------------------------------------------------------------
--[[
	角色移除时断开所有连接并销毁子模块（Unbind RenderStep、Gate 订阅、LocoStyle/Arbiter/FOV）
]]
local function _cleanup()
	pcall(function()
		RunService:UnbindFromRenderStep(SHIFT_LOCK_FACE_STEP_NAME)
	end)
	if _unsubGate then
		_unsubGate()
		_unsubGate = nil
	end
	if locoStyle then
		locoStyle:destroy()
		locoStyle = nil
	end
	arbiter:destroy()
	_setAutoRotateForShiftLock(false)
	for _, conn in ipairs(_connections) do
		conn:Disconnect()
	end
	table.clear(_connections)
	airLean.destroy()
	strafeBlend.destroy()
	groundLoco.destroy()
	climbAssist.destroy()
	CameraImpulse.unbind(Character)
	fovController.destroy()
	Animate:destroy()
end

_trackConnection(Character.AncestryChanged:Connect(function(_, parent)
	if parent == nil then
		_cleanup()
	end
end))
