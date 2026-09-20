--[[
	Module: DashStyleRoll
	Description: NewRoll 控制相位 Gate（Travel 单钟）
	Author: Dev-Framework
	Created: 2026-07-30
	Last Modified: 2026-08-11

	================================================================================
	使用说明
	================================================================================

	【双层时钟】
	- 控制相位：Drive + 兄弟 LockMovement + Jump/Sprint PushLock + ActionLock
	- controlUnlockTime（可 < tweenDuration）：仅按时间解锁（勿用 driveActive 推断）
	- 解锁时不立刻 FadeOut / 不降 Priority / 不放 ActionLock（pauseBaseTracks 继续压 3C）
	  有移向 / Action 收尾：放 ActionLock + StopAnim(FadeTime) 接 3C 走/跑
	  Jumping 硬切尾段（不含 Freefall）
	- tweenDuration：电机结束 EndTravel（NewRoll Forward 长冲 0.4；unlock 可略早）
	- Action overTime：仅 PostTravel 表现后摇，不再驱动控制闸
	- 技能状态机（Rolling/Recovery）独立，本 Gate 不改

	【Cancel】上界夹到 controlUnlockTime；须有意转向（侧/后），沿冲刺方向按住不取消
	【衔步】Interrupt deferImpulse → ForceCleanup 后再 AddImpulse；collision=SlideAlong

	【soft-merge】
	- 预测 Over：End(preservePhysicsToken, keepDriveActive) + 放 ActionLock（勿杀 Drive）
	- 正式 Begin(adoptIfPresent)；无令牌且 elapsed>0.05 禁二次起冲
	- elapsed >= controlUnlock：跳过 Begin 误锁，走控制解锁；elapsed >= Travel 再收电机 Session

	【锁速】兄弟 LockMovement 为控制解锁从属；勿在本文件直写 WalkSpeed / ALV / BodyVelocity
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local AnimationModule = Utils.AnimationModule
local CameraImpulse = Utils.CameraImpulse
local SpeedLineFX = Utils.SpeedLineFX
local CharacterMotion = Utils.CharacterMotion
local SkillActionControl = require(script.Parent.Parent.SkillActionControl)
local SkillActionLock = require(script.Parent.Parent.SkillActionLock)
local SkillAnimationTrackOwner = require(script.Parent.SkillAnimationTrackOwner)
local GetSkillData = require(script.Parent.Parent.GetSkillData)
local Players = game:GetService("Players")

local DEFAULT_ROLL_ANGLE = { Forward = 0, Backward = 180, Left = 90, Right = -90 }
local DEFAULT_ANIM_SPEED = 1.3
local DEFAULT_ANIM_FADE = 0.05
local DEFAULT_ANGLE = { Forward = 0, Backward = 180, Left = 90, Right = -90 }

local SPEED_LINE_INTENSITY = 0.75
local SPEED_LINE_FADE_IN_SEC = 0.1
local SPEED_LINE_FADE_OUT_SEC = 0.22

local RollDir = {
	Forward = "Forward",
	Backward = "Backward",
	Left = "Left",
	Right = "Right",
}

local module = {}
module.isReleasePlayerOnly = true

local function tryPlayDashFovImpulse(character: Model, directionStr: string, preferAdopt: boolean)
	if directionStr ~= "Forward" then
		return
	end
	if Players:GetPlayerFromCharacter(character) ~= Players.LocalPlayer then
		return
	end
	CameraImpulse.emit(character, {
		kind = "FovPulse",
		id = "Dash:Forward",
		adoptIfActive = preferAdopt == true,
	})
end

local function cancelDashFovImpulse(character: Model?)
	if not character then
		return
	end
	CameraImpulse.cancel(character)
end

local function tryShowSpeedLine(character: Model, directionStr: string)
	if directionStr ~= "Forward" then
		return
	end
	if Players:GetPlayerFromCharacter(character) ~= Players.LocalPlayer then
		return
	end
	SpeedLineFX.Show(SPEED_LINE_INTENSITY, SPEED_LINE_FADE_IN_SEC)
end

local function tryHideSpeedLine(character: Model?)
	if character and Players:GetPlayerFromCharacter(character) ~= Players.LocalPlayer then
		return
	end
	SpeedLineFX.Hide(SPEED_LINE_FADE_OUT_SEC)
end

local function acquireOrAdoptActionLock(self: any, character: Model, preferAdopt: boolean)
	if self._actionLockHeld then
		return
	end
	if preferAdopt and SkillActionLock.isHeld(character) then
		self._actionLockHeld = true
		self._actionLockAdopted = true
		self._lockHolderId = nil
		return
	end
	local holderId = SkillActionLock.turn_On_Action_Lock(character, "Override")
	self._actionLockHeld = true
	self._actionLockAdopted = false
	self._lockHolderId = holderId
end

--[[
	释放 ActionLock。
	@param self any
	@param preservePresentationFx boolean? - true 时保留 FOV（TravelEnd 用；加速线另收）
]]
local function releaseActionLock(self: any, preservePresentationFx: boolean?)
	if not self._actionLockHeld then
		return
	end
	self._actionLockHeld = false
	local holderId = self._lockHolderId
	self._lockHolderId = nil
	self._actionLockAdopted = false
	local character = self.baseSkill and self.baseSkill.character
	if character then
		SkillActionLock.turn_Off_Action_Lock(character, holderId)
		if type(holderId) ~= "number" and SkillActionLock.isHeld(character) then
			SkillActionLock.forceRelease(character)
		end
		if not preservePresentationFx then
			cancelDashFovImpulse(character)
			tryHideSpeedLine(character)
		end
	end
end

local function clearAnimGateBind(self: any, animationName: string?)
	local name = animationName or self.currentAnimationName
	if self.animator and type(name) == "string" and name ~= "" then
		AnimationModule.BindEndFunc(self.animator, name, nil)
	end
end

--[[
	软合并仍在 Travel：接管 ActionLock，不绑「动画结束放闸」（放闸只走 OnTravelEnd）。
]]
local function ensureTravelActionLock(self: any, character: Model, animationName: string, preferAdopt: boolean)
	local playing = AnimationModule.IsAnimPlaying and AnimationModule.IsAnimPlaying(self.animator, animationName)
	if playing then
		if self.animator and animationName then
			SkillAnimationTrackOwner.claim(self.animator, animationName, self)
		end
		acquireOrAdoptActionLock(self, character, preferAdopt)
		return
	end
	if SkillActionLock.isHeld(character) then
		SkillActionLock.forceRelease(character)
	end
	self._actionLockHeld = false
	self._actionLockAdopted = false
	self._lockHolderId = nil
end

local function shouldPreserveForPredictHandoff(self): boolean
	local bs = self.baseSkill
	if not bs then
		return false
	end
	if self._forceFullCleanupOnOver then
		return false
	end
	return bs._presentationPredictAnimHandoff == true or bs._presentationPredictActive == true
end

local function getDirectionParams(self, direction: string)
	local shared = CharacterMotion.GetRecipe("NewRoll", direction) or {}
	local defaults = {
		overTime = self.actionInfo.overTime,
		tweenDuration = shared.tweenDuration or 0.7,
		planeSpeed = shared.planeSpeed or 102.4,
		vectorEndFactor = shared.vectorEndFactor or 0,
		maxDistance = shared.maxDistance,
		collisionPolicy = shared.collisionPolicy or "MaxForceClip",
		clearImpulsesOnBegin = if shared.clearImpulsesOnBegin ~= nil then shared.clearImpulsesOnBegin else true,
		enforceMaxDistance = shared.enforceMaxDistance,
		composeCap = shared.composeCap,
		easingStyle = shared.easingStyle,
		easingDirection = shared.easingDirection,
		speedKeys = shared.speedKeys,
		angle = DEFAULT_ROLL_ANGLE[direction] or 0,
		animationSpeed = self.actionInfo.animationSpeed or DEFAULT_ANIM_SPEED,
		animationFadeTime = self.actionInfo.animationFadeTime or DEFAULT_ANIM_FADE,
		animationFadeInTime = self.actionInfo.animationFadeInTime,
		animationStopFadeTime = self.actionInfo.animationStopFadeTime,
		animationPriority = self.actionInfo.animationPriority or Enum.AnimationPriority.Action3,
		animationName = self.animationMap[direction],
		controlUnlockTime = nil,
		earlyEndBoostDuration = self.actionInfo.earlyEndBoostDuration,
		earlyEndBoostPeakSpeed = self.actionInfo.earlyEndBoostPeakSpeed,
		earlyEndBoostScale = self.actionInfo.earlyEndBoostScale,
		earlyEndBoostMin = self.actionInfo.earlyEndBoostMin,
		earlyEndBoostMax = self.actionInfo.earlyEndBoostMax,
		earlyEndBoostEasingStyle = self.actionInfo.earlyEndBoostEasingStyle,
		earlyEndBoostEasingDirection = self.actionInfo.earlyEndBoostEasingDirection,
	}
	local dirCfg = self.directionConfig[direction]
	if dirCfg then
		for k, v in pairs(dirCfg) do
			if v ~= nil then
				defaults[k] = v
			end
		end
	end
	if defaults.animationFadeInTime == nil then
		defaults.animationFadeInTime = defaults.animationFadeTime
	end
	-- 控制解锁默认 = 电机结束；Forward 可早于 tweenDuration
	if type(defaults.controlUnlockTime) ~= "number" then
		defaults.controlUnlockTime = defaults.tweenDuration
	end
	return defaults
end

local function overSiblingLockMovementAt(actionSelf, cumulativeTime: number)
	local skillAction = actionSelf.baseSkill.skillAction
	if not skillAction or not skillAction.allActions then
		return
	end
	for _, act in ipairs(skillAction.allActions) do
		if
			act ~= actionSelf
			and act.actionInfo
			and act.actionInfo.action == "LockMovement"
			and act.state == SkillActionControl.StateEnum.Play
		then
			act:Over(cumulativeTime)
		end
	end
end

local function _motionSessionId(self): string
	local bs = self.baseSkill
	local skillName = if bs and type(bs.skillName) == "string" then bs.skillName else "NewRoll"
	local castId = bs and (bs.skillCastId or bs.clientPredictCastId or bs._castId)
	if type(castId) ~= "string" or castId == "" then
		castId = tostring(self)
	end
	return string.format("Skill:%s:%s", skillName, castId)
end

--[[
	控制解锁：不立刻 Stop / 不降 Priority。
	保持 Action3 压住 3C，避免解锁瞬间 Idle/Walk 抢轨抽搐；有移向 / Jumping / Action 收尾再淡出。
	@param self any - DashStyleRoll 实例
]]
local function _prepareRollAnimForControlUnlock(self: any)
	clearAnimGateBind(self, self.currentAnimationName)
	if not self.animator or not self.currentAnimationName then
		self._heldRollAnimName = nil
		self._rollAnimPendingFade = false
		return
	end
	local animName = self.currentAnimationName
	-- 仍占 Owner + 保持 Action3，直至真正 Fade / 硬切
	self._heldRollAnimName = animName
	self._rollAnimPendingFade = true
	self.currentAnimationName = nil
end

--[[
	放 ActionLock（解冻 3C base tracks）。控制解锁时延后调用，避免无操作时 Idle 抢轨。
	@param self any - DashStyleRoll 实例
]]
local function _releaseActionLockForLoco(self: any)
	releaseActionLock(self, true)
	local character = self.baseSkill and self.baseSkill.character
	if character and SkillActionLock.isHeld(character) then
		SkillActionLock.forceRelease(character)
	end
end

--[[
	开始与 loco 交接的淡出（有移向 / Action 收尾）：StopAnim FadeTime 交接 Walk/Run。
	@param self any - DashStyleRoll 实例
	@param animName string? - 轨道名；缺省用 _heldRollAnimName
]]
local function _beginRollAnimLocoFade(self: any, animName: string?)
	local name = animName or self._heldRollAnimName
	if not self.animator or type(name) ~= "string" or name == "" then
		self._heldRollAnimName = nil
		self._rollAnimPendingFade = false
		_releaseActionLockForLoco(self)
		return
	end
	_releaseActionLockForLoco(self)
	SkillAnimationTrackOwner.release(self.animator, name, self)
	local fade = self.currentAnimationStopFadeTime
		or (self.actionInfo and self.actionInfo.animationStopFadeTime)
		or (self.actionInfo and self.actionInfo.animationFadeTime)
		or DEFAULT_ANIM_FADE
	AnimationModule.StopAnim(self.animator, name, fade)
	self._fadingAnimName = name
	self._fadingAnimUntil = os.clock() + fade
	self._heldRollAnimName = nil
	self._rollAnimPendingFade = false
end

local function _hardStopFadingRollAnim(self: any)
	local name = self._fadingAnimName or self._heldRollAnimName
	_releaseActionLockForLoco(self)
	if not name or not self.animator then
		self._fadingAnimName = nil
		self._fadingAnimUntil = nil
		self._heldRollAnimName = nil
		self._rollAnimPendingFade = false
		return
	end
	SkillAnimationTrackOwner.release(self.animator, name, self)
	AnimationModule.StopAnimHard(self.animator, name)
	self._fadingAnimName = nil
	self._fadingAnimUntil = nil
	self._heldRollAnimName = nil
	self._rollAnimPendingFade = false
end

local function _clearFadingRollIfExpired(self: any)
	local untilT = self._fadingAnimUntil
	if type(untilT) ~= "number" then
		return
	end
	if os.clock() >= untilT then
		self._fadingAnimName = nil
		self._fadingAnimUntil = nil
	end
end

--[[
	控制解锁（一次闩）：放 Jump/Sprint / CMS；ActionLock 延后到有移向/跳/收尾再放。
	@param cumulativeTime number
	@param opts { skipMotionEnd: boolean?, endMotor: boolean? }?
]]
function module:_onControlUnlock(cumulativeTime: number, opts: any?)
	if self._controlUnlocked then
		return
	end
	self._controlUnlocked = true
	self._travelEnded = true
	opts = opts or {}

	local character = self.baseSkill and self.baseSkill.character
	if character and self._motionSessionId then
		CharacterMotion.ReleaseControlLock(character, self._motionSessionId)
		if opts.endMotor and not opts.skipMotionEnd then
			CharacterMotion.EndTravel(character, self._motionSessionId)
			self._motorEnded = true
		end
	end

	overSiblingLockMovementAt(self, cumulativeTime)
	-- 故意不在此处放 ActionLock：pauseBaseTracks 继续压 3C，翻滚可播完
	_prepareRollAnimForControlUnlock(self)
	tryHideSpeedLine(character)
end

--[[
	电机窗结束：EndTravel 清 Session。
]]
function module:_onMotorEnd(_cumulativeTime: number)
	if self._motorEnded then
		return
	end
	self._motorEnded = true
	local character = self.baseSkill and self.baseSkill.character
	if character and self._motionSessionId then
		CharacterMotion.EndTravel(character, self._motionSessionId)
	end
end

--[[
	打断 / 全清：控制解锁 + 视情况结束电机。
]]
function module:_onTravelEnd(cumulativeTime: number, opts: any?)
	opts = opts or {}
	if not self._controlUnlocked then
		self:_onControlUnlock(cumulativeTime, {
			skipMotionEnd = opts.skipMotionEnd,
			endMotor = not opts.skipMotionEnd,
		})
	elseif not self._motorEnded and not opts.skipMotionEnd then
		self:_onMotorEnd(cumulativeTime)
	end
	if opts.skipMotionEnd then
		self._motorEnded = true
	end
end

local function _elapsedInTravel(self: any, cumulativeTime: number): number
	local actionT0 = self._travelActionT0 or 0
	return math.max(0, (type(cumulativeTime) == "number" and cumulativeTime or 0) - actionT0)
end

local function _isControlUnlockDue(self: any, cumulativeTime: number): boolean
	-- 只按时间解锁。禁止用 driveActive 推断：Begin 后 / 空中态易误判，导致立刻 FadeOut + 跳过翻滚。
	local unlockAt = self._controlUnlockTime
	if type(unlockAt) ~= "number" then
		unlockAt = self._travelDuration
	end
	if type(unlockAt) ~= "number" or unlockAt <= 0 then
		return false
	end
	return _elapsedInTravel(self, cumulativeTime) >= unlockAt
end

local function _isMotorComplete(self: any, cumulativeTime: number): boolean
	local travelDur = self._travelDuration
	if type(travelDur) ~= "number" or travelDur <= 0 then
		return false
	end
	return _elapsedInTravel(self, cumulativeTime) >= travelDur
end

function module:Create(actionInfo: any)
	self.actionInfo = actionInfo
	self.state = SkillActionControl.StateEnum.NoStart
	self.startTime = self.actionInfo.startTime
	self.overTime = self.actionInfo.overTime

	local character = self.baseSkill.character
	if not character then
		return
	end

	local humanoid = character:WaitForChild("Humanoid")
	local animator = humanoid:WaitForChild("Animator")
	self.animator = animator

	self.animationMap = {
		[RollDir.Forward] = self.actionInfo.animationNameForward or "RollForward",
		[RollDir.Backward] = self.actionInfo.animationNameBackward or "RollBackward",
		[RollDir.Left] = self.actionInfo.animationNameLeft or "RollLeft",
		[RollDir.Right] = self.actionInfo.animationNameRight or "RollRight",
	}

	self.directionConfig = self.actionInfo.directionConfig or {}
end

function module:Init()
	if self._actionLockHeld then
		local holderId = self._lockHolderId
		local character = self.baseSkill and self.baseSkill.character
		self._actionLockHeld = false
		self._actionLockAdopted = false
		self._lockHolderId = nil
		if character then
			SkillActionLock.turn_Off_Action_Lock(character, holderId)
			if type(holderId) ~= "number" and SkillActionLock.isHeld(character) then
				SkillActionLock.forceRelease(character)
			end
		end
	else
		self._lockHolderId = nil
		self._actionLockAdopted = false
	end
	local character = self.baseSkill and self.baseSkill.character
	if character and self._motionSessionId then
		CharacterMotion.ForceCleanup(character, self._motionSessionId)
	end
	self.state = SkillActionControl.StateEnum.NoStart
	self.currentAnimationName = nil
	self.currentAnimationFadeTime = nil
	self.currentAnimationStopFadeTime = nil
	self._moveInterruptWindowStartSkillTime = nil
	self._moveInterruptWindowEndSkillTime = nil
	self._moveEarlyInterruptDone = false
	self._forceFullCleanupOnOver = false
	self._actionLockHeld = false
	self._motionSessionId = nil
	self._rollDirKey = nil
	self._travelEnded = false
	self._controlUnlocked = false
	self._motorEnded = false
	self._travelDuration = nil
	self._controlUnlockTime = nil
	self._travelActionT0 = nil
	self._travelAwaitingEnd = false
	self._fadingAnimName = nil
	self._fadingAnimUntil = nil
	self._heldRollAnimName = nil
	self._rollAnimPendingFade = false
	self._sawDriveActive = false
	self._dashPlanarDir = nil
end

local MOVE_INTERRUPT_MIN_MAG = 0.35
-- 与冲刺方向点积高于此：视为仍按住冲刺方向，不取消
local MOVE_INTERRUPT_ALIGN_DOT = 0.55

--[[
	是否视为「有意取消」移向：需足够大，且相对冲刺方向明显转向（侧/后）。
	沿冲刺方向按住 WASD 不取消（前冲最常见误触）。
]]
local function _shouldMoveInterrupt(self: any, humanoid: Humanoid): boolean
	local md = humanoid.MoveDirection
	if md.Magnitude < MOVE_INTERRUPT_MIN_MAG then
		return false
	end
	local flat = Vector3.new(md.X, 0, md.Z)
	if flat.Magnitude < MOVE_INTERRUPT_MIN_MAG then
		return false
	end
	flat = flat.Unit
	local dashDir = self._dashPlanarDir
	if dashDir and dashDir.Magnitude > 1e-4 then
		if flat:Dot(dashDir.Unit) >= MOVE_INTERRUPT_ALIGN_DOT then
			return false
		end
	end
	return true
end

function module:_applyEarlyMoveInterrupt(cumulativeTime: number)
	if self._moveEarlyInterruptDone or self.state ~= SkillActionControl.StateEnum.Play then
		return
	end
	self._moveEarlyInterruptDone = true
	local character = self.baseSkill.character
	local boostParams = self._rollDirKey and getDirectionParams(self, self._rollDirKey) or nil
	local boostPeak: number? = nil
	local boostDuration: number? = nil
	if character and self._motionSessionId and not self._travelEnded then
		-- 先读残速并拆 Drive；Impulse 须在 Over/ForceCleanup 之后再加（deferImpulse）
		boostDuration = boostParams and boostParams.earlyEndBoostDuration
		boostPeak = CharacterMotion.Interrupt(character, self._motionSessionId, {
			earlyEndBoostDuration = boostDuration,
			earlyEndBoostScale = boostParams and boostParams.earlyEndBoostScale,
			earlyEndBoostMin = boostParams and boostParams.earlyEndBoostMin,
			earlyEndBoostMax = boostParams and boostParams.earlyEndBoostMax,
			earlyEndBoostPeakSpeed = boostParams and boostParams.earlyEndBoostPeakSpeed,
			earlyEndBoostEasingStyle = boostParams and boostParams.earlyEndBoostEasingStyle,
			earlyEndBoostEasingDirection = boostParams and boostParams.earlyEndBoostEasingDirection,
			deferImpulse = true,
		})
	end
	self:_onTravelEnd(cumulativeTime, { skipMotionEnd = true })
	self._forceFullCleanupOnOver = true
	self:Over(cumulativeTime)
	if
		character
		and type(boostPeak) == "number"
		and boostPeak > 0
		and type(boostDuration) == "number"
		and boostDuration > 0
	then
		local decay = "QuadOut"
		local style = boostParams and boostParams.earlyEndBoostEasingStyle
		local dir = boostParams and boostParams.earlyEndBoostEasingDirection
		if style == Enum.EasingStyle.Linear then
			decay = "Linear"
		elseif style == Enum.EasingStyle.Quad and (dir == nil or dir == Enum.EasingDirection.Out) then
			decay = "QuadOut"
		end
		CharacterMotion.AddImpulse(character, {
			id = "InterruptBoost:" .. tostring(self._motionSessionId or character),
			followMoveDirection = true,
			peakSpeed = boostPeak,
			durationSec = boostDuration,
			decay = decay,
			collisionPolicy = "SlideAlong",
		})
	end
end

function module:Run(cumulativeTime: number)
	if self.state ~= SkillActionControl.StateEnum.Play then
		return
	end

	if self._travelAwaitingEnd then
		if not self._controlUnlocked and _isControlUnlockDue(self, cumulativeTime) then
			self:_onControlUnlock(cumulativeTime)
		end
		if self._controlUnlocked and not self._motorEnded and _isMotorComplete(self, cumulativeTime) then
			self:_onMotorEnd(cumulativeTime)
		end
	end

	-- 解锁后：Jumping 硬切；有意移向再 FadeOut；无操作保留翻滚轨至 Action 收尾
	if self._controlUnlocked then
		local character = self.baseSkill and self.baseSkill.character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if self._rollAnimPendingFade and humanoid then
			if humanoid:GetState() == Enum.HumanoidStateType.Jumping then
				_hardStopFadingRollAnim(self)
			elseif humanoid.MoveDirection.Magnitude >= MOVE_INTERRUPT_MIN_MAG then
				_beginRollAnimLocoFade(self)
			end
		elseif self._fadingAnimName then
			if humanoid and humanoid:GetState() == Enum.HumanoidStateType.Jumping then
				_hardStopFadingRollAnim(self)
			else
				_clearFadingRollIfExpired(self)
			end
		end
	end

	local ws = self._moveInterruptWindowStartSkillTime
	local we = self._moveInterruptWindowEndSkillTime
	if
		type(ws) == "number"
		and type(we) == "number"
		and cumulativeTime >= ws
		and cumulativeTime <= we
		and not self._moveEarlyInterruptDone
		and not self._controlUnlocked
	then
		local character = self.baseSkill.character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid and _shouldMoveInterrupt(self, humanoid) then
			self:_applyEarlyMoveInterrupt(cumulativeTime)
			return
		end
	end
end

function module:Start(cumulativeTime: number)
	local character: Model = self.baseSkill.character
	if not character then
		return
	end
	local humanoid = character:FindFirstChild("Humanoid")
	local HRP = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not HRP then
		return
	end

	local directionStr, moveDir2D = GetSkillData.getCharacterDirectionStr(character)
	local dirKey = directionStr
	if type(dirKey) ~= "string" or not self.animationMap[dirKey] then
		dirKey = RollDir.Forward
	end
	self._rollDirKey = dirKey

	local params = getDirectionParams(self, dirKey)
	self.overTime = params.overTime
	self.currentAnimationName = params.animationName
	self.currentAnimationStopFadeTime = params.animationStopFadeTime or params.animationFadeTime

	local actionT0 = self.actionInfo.startTime or 0
	local actionT1 = self.overTime
	local travelDur = params.tweenDuration or 0.4
	local controlUnlock = params.controlUnlockTime or travelDur
	if type(controlUnlock) ~= "number" or controlUnlock <= 0 then
		controlUnlock = travelDur
	end
	controlUnlock = math.min(controlUnlock, travelDur)
	self._travelDuration = travelDur
	self._controlUnlockTime = controlUnlock
	self._travelActionT0 = actionT0
	self._travelEnded = false
	self._controlUnlocked = false
	self._motorEnded = false
	self._sawDriveActive = false
	self._travelAwaitingEnd = false
	self._heldRollAnimName = nil
	self._rollAnimPendingFade = false
	self._fadingAnimName = nil
	self._fadingAnimUntil = nil

	-- Cancel ⊆ 控制解锁窗
	local winDur = params.moveInterruptWindowTime
	local winOff = params.moveInterruptWindowOffset or 0
	local unlockSkillTime = actionT0 + controlUnlock
	if type(winDur) == "number" and winDur > 0 and actionT1 > actionT0 then
		local winStart = actionT0 + winOff
		local winEnd = winStart + winDur
		winStart = math.max(winStart, actionT0)
		winEnd = math.min(winEnd, unlockSkillTime, actionT1)
		if winEnd > winStart then
			self._moveInterruptWindowStartSkillTime = winStart
			self._moveInterruptWindowEndSkillTime = winEnd
		else
			self._moveInterruptWindowStartSkillTime = nil
			self._moveInterruptWindowEndSkillTime = nil
		end
		self._moveEarlyInterruptDone = false
	else
		self._moveInterruptWindowStartSkillTime = nil
		self._moveInterruptWindowEndSkillTime = nil
		self._moveEarlyInterruptDone = false
	end

	local isSoftMergeHandoff = self.baseSkill and self.baseSkill._softMergeSkipEnterHandlers == true
	local elapsedInAction = math.max(0, (type(cumulativeTime) == "number" and cumulativeTime or 0) - actionT0)
	local sessionId = _motionSessionId(self)
	self._motionSessionId = sessionId

	-- soft-merge 已过控制解锁：禁 Begin 误 PushLock
	if isSoftMergeHandoff and elapsedInAction >= controlUnlock then
		self._travelAwaitingEnd = true
		self:_onControlUnlock(cumulativeTime, {
			endMotor = elapsedInAction >= travelDur,
		})
		if elapsedInAction >= travelDur and not self._motorEnded then
			self:_onMotorEnd(cumulativeTime)
		end
		local dirForFxPast = self._rollDirKey or directionStr
		tryPlayDashFovImpulse(character, dirForFxPast, true)
		return
	end

	-- 与旧 DashStyleRoll 一致：先对齐 face，再按朝向+angle 采样冲量方向
	local faceFlat: Vector3? = nil
	if moveDir2D and moveDir2D.Magnitude > 1e-4 then
		faceFlat = Vector3.new(moveDir2D.X, 0, moveDir2D.Z)
		if faceFlat.Magnitude > 1e-4 then
			faceFlat = faceFlat.Unit
			HRP.CFrame = CFrame.lookAt(HRP.Position, HRP.Position + faceFlat)
		else
			faceFlat = nil
		end
	end

	local lookVector = HRP:GetPivot():ToWorldSpace(CFrame.Angles(0, math.rad(DEFAULT_ANGLE[dirKey] or 0), 0)).LookVector
	local moveDirection = Vector3.new(lookVector.X, 0, lookVector.Z)
	if moveDirection.Magnitude < 1e-4 and faceFlat then
		moveDirection = faceFlat
	end
	if humanoid.Sit then
		local md = humanoid.MoveDirection
		if md.Magnitude > 1e-4 then
			moveDirection = Vector3.new(md.X, 0, md.Z)
		end
	end
	if moveDirection.Magnitude > 1e-4 then
		self._dashPlanarDir = Vector3.new(moveDirection.X, 0, moveDirection.Z).Unit
	else
		self._dashPlanarDir = nil
	end

	local sharedRecipe = CharacterMotion.GetRecipe("NewRoll", dirKey) or {}
	local recipe = {
		planeSpeed = params.planeSpeed,
		tweenDuration = params.tweenDuration,
		vectorEndFactor = params.vectorEndFactor,
		maxDistance = params.maxDistance or sharedRecipe.maxDistance,
		verticalMode = "PreserveY",
		collisionPolicy = params.collisionPolicy or sharedRecipe.collisionPolicy or "MaxForceClip",
		clearImpulsesOnBegin = if params.clearImpulsesOnBegin ~= nil
			then params.clearImpulsesOnBegin
			else (if sharedRecipe.clearImpulsesOnBegin ~= nil then sharedRecipe.clearImpulsesOnBegin else true),
		enforceMaxDistance = if params.enforceMaxDistance ~= nil
			then params.enforceMaxDistance
			else sharedRecipe.enforceMaxDistance,
		composeCap = params.composeCap or sharedRecipe.composeCap,
		easingStyle = params.easingStyle or sharedRecipe.easingStyle,
		easingDirection = params.easingDirection or sharedRecipe.easingDirection,
		speedKeys = params.speedKeys or sharedRecipe.speedKeys,
	}

	local started = CharacterMotion.Begin(character, {
		sessionId = sessionId,
		recipe = recipe,
		directionWorld = moveDirection,
		controlMask = { Jump = true, Sprint = true },
		adoptIfPresent = isSoftMergeHandoff == true,
		elapsedSec = elapsedInAction,
	})

	self._travelAwaitingEnd = true
	-- 禁止在 PlayAnim 前按「电机未 Active」解锁：Begin 首帧易误判，会跳过翻滚动画
	if started then
		self._sawDriveActive = true
	end

	local dirForFx = self._rollDirKey or directionStr
	tryPlayDashFovImpulse(character, dirForFx, isSoftMergeHandoff == true)
	tryShowSpeedLine(character, dirForFx)

	if isSoftMergeHandoff and started then
		ensureTravelActionLock(self, character, params.animationName, true)
		return
	end

	if isSoftMergeHandoff and elapsedInAction > 0.05 and not started then
		warn("[DashStyleRoll] soft-merge 无既有物理且预测已推进，跳过起冲", self.baseSkill and self.baseSkill.skillName)
		self.currentAnimationName = params.animationName
		ensureTravelActionLock(self, character, params.animationName, true)
		return
	end

	if not started and not isSoftMergeHandoff then
		warn("[DashStyleRoll] CharacterMotion.Begin 失败", self.baseSkill and self.baseSkill.skillName)
	end

	AnimationModule.PlayAnimByModel(
		character,
		params.animationName,
		params.animationSpeed,
		self.actionInfo.animationKeyframeNames,
		self.actionInfo.animationKeyframeFunctions,
		params.animationPriority,
		params.animationFadeInTime
	)
	if self.animator and params.animationName then
		SkillAnimationTrackOwner.claim(self.animator, params.animationName, self)
	end
	acquireOrAdoptActionLock(self, character, isSoftMergeHandoff == true)
	-- 不绑动画结束放闸：控制闸寿命 = Travel（OnTravelEnd）
end

function module:softMergeCatchUpPastOver(_cumulativeTime: number)
	local character = self.baseSkill and self.baseSkill.character
	if character then
		CharacterMotion.ForceCleanup(character, self._motionSessionId)
	end
	self._controlUnlocked = true
	self._motorEnded = true
	self._travelEnded = true
	self._forceFullCleanupOnOver = true
	self:_forceCleanupPhysicsAndAnim()
	if character and SkillActionLock.isHeld(character) then
		SkillActionLock.forceRelease(character)
	end
end

function module:OnOver(_cumulativeTime: number)
	if shouldPreserveForPredictHandoff(self) then
		clearAnimGateBind(self, self.currentAnimationName)
		releaseActionLock(self, true)
		local character = self.baseSkill and self.baseSkill.character
		if character and SkillActionLock.isHeld(character) then
			SkillActionLock.forceRelease(character)
		end
		if character and self._motionSessionId then
			CharacterMotion.End(character, self._motionSessionId, {
				preservePhysicsToken = true,
				keepDriveActive = true,
				releaseControlLock = true,
			})
		end
		self.currentAnimationName = nil
		self.currentAnimationFadeTime = nil
		self.currentAnimationStopFadeTime = nil
		self._moveInterruptWindowStartSkillTime = nil
		self._moveInterruptWindowEndSkillTime = nil
		self._forceFullCleanupOnOver = false
		self._travelEnded = true
		self._controlUnlocked = true
		self._motorEnded = true
		return
	end

	if self._controlUnlocked and not self._forceFullCleanupOnOver then
		if not self._motorEnded then
			self:_onMotorEnd(_cumulativeTime)
		end
		self:_postTravelActionCleanup()
		return
	end

	self:_forceCleanupPhysicsAndAnim()
end

function module:Destroy()
	if self._destroyed then
		return
	end
	local preserve = shouldPreserveForPredictHandoff(self)
	self._destroyed = true
	local character = self.baseSkill and self.baseSkill.character
	if preserve then
		if self.state ~= SkillActionControl.StateEnum.Over then
			self:Over(0)
		else
			if character and SkillActionLock.isHeld(character) then
				SkillActionLock.forceRelease(character)
			end
			if character and self._motionSessionId then
				CharacterMotion.End(character, self._motionSessionId, {
					preservePhysicsToken = true,
					keepDriveActive = true,
					releaseControlLock = true,
				})
			end
		end
		cancelDashFovImpulse(character)
		tryHideSpeedLine(character)
		self._rollDirKey = nil
		return
	end
	-- 已控制解锁且非取消打断：走软收尾，避免技能结束硬切翻滚尾段（无操作也像被打断）
	local softEnd = self._controlUnlocked and not self._moveEarlyInterruptDone
	self._forceFullCleanupOnOver = not softEnd
	if self.state ~= SkillActionControl.StateEnum.Over then
		self:Over(0)
	else
		if softEnd then
			if not self._motorEnded then
				self:_onMotorEnd(0)
			end
			self:_postTravelActionCleanup()
		else
			self:_forceCleanupPhysicsAndAnim()
		end
	end
end

--[[
	Travel 已结束后的 Action Over：只清 FOV/线/孤儿令牌，避免 ForceCleanup 误感硬刹。
]]
function module:_postTravelActionCleanup()
	-- 勿硬切：无操作尾段可能仍在 pending / 淡出中
	if self._rollAnimPendingFade then
		_beginRollAnimLocoFade(self)
	end
	local character = self.baseSkill and self.baseSkill.character
	cancelDashFovImpulse(character)
	tryHideSpeedLine(character)
	if character then
		-- 软收尾：保留 DriveEndBlend，勿 DestroyAll 急刹
		CharacterMotion.ForceCleanup(character, self._motionSessionId, { preserveDriveEndBlend = true })
	end
	if character and SkillActionLock.isHeld(character) then
		SkillActionLock.forceRelease(character)
	end
	self._motionSessionId = nil
	self._rollDirKey = nil
	self._moveInterruptWindowStartSkillTime = nil
	self._moveInterruptWindowEndSkillTime = nil
	self.currentAnimationName = nil
	self.currentAnimationFadeTime = nil
	self.currentAnimationStopFadeTime = nil
end

function module:_forceCleanupPhysicsAndAnim()
	self._forceFullCleanupOnOver = false
	self._travelEnded = true
	self._controlUnlocked = true
	self._motorEnded = true
	_hardStopFadingRollAnim(self)

	local character = self.baseSkill and self.baseSkill.character
	if character then
		CharacterMotion.ForceCleanup(character, self._motionSessionId)
	end

	clearAnimGateBind(self, self.currentAnimationName)
	releaseActionLock(self)
	if character and SkillActionLock.isHeld(character) then
		SkillActionLock.forceRelease(character)
	end
	cancelDashFovImpulse(character)
	tryHideSpeedLine(character)

	if self.animator and self.currentAnimationName then
		local animName = self.currentAnimationName
		local stillOwner = SkillAnimationTrackOwner.isOwner(self.animator, animName, self)
		SkillAnimationTrackOwner.release(self.animator, animName, self)
		if stillOwner then
			local fade = self.currentAnimationStopFadeTime or self.actionInfo.animationStopFadeTime or self.actionInfo.animationFadeTime or 0
			AnimationModule.StopAnim(self.animator, animName, fade)
		end
	elseif self.animator and self.animationMap then
		for _, animName in pairs(self.animationMap) do
			if animName and SkillAnimationTrackOwner.isOwner(self.animator, animName, self) then
				SkillAnimationTrackOwner.release(self.animator, animName, self)
				if AnimationModule.IsAnimPlaying and AnimationModule.IsAnimPlaying(self.animator, animName) then
					AnimationModule.StopAnim(self.animator, animName, self.actionInfo.animationFadeTime or 0)
				end
			elseif animName then
				SkillAnimationTrackOwner.release(self.animator, animName, self)
			end
		end
	end
	self.currentAnimationName = nil
	self.currentAnimationFadeTime = nil
	self.currentAnimationStopFadeTime = nil
	self._moveInterruptWindowStartSkillTime = nil
	self._moveInterruptWindowEndSkillTime = nil
	self._motionSessionId = nil
	self._rollDirKey = nil
end

return module
