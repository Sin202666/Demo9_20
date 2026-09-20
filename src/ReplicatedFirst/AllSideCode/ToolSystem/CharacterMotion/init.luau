--[[
	Module: CharacterMotion
	Description: OW 级可控速度电机（Drive 主动位移 + Impulse 击退/衔步）与 CharacterControl 锁编排
	Author: 林奥宇
	Created: 2026-08-05
	Last Modified: 2026-08-31

	================================================================================
	使用说明（电机产品契约）
	================================================================================

	【单写入者】角色平面速度唯一经本模块写入：
	- Drive：Begin Session — 短时接管平面速度曲线（闪避/突进；easing / speedKeys 可编）
	- Impulse：AddImpulse / ApplyKnockback — 衰减冲量叠加（击退/Interrupt 衔步）
	每 tick：Compose → 意图路程 → Blockcast 扫掠 → 仅 XZ 写 LinearVelocity（MaxAxesForce.Y=0）。
	PreserveY 真义：不约束竖直；禁止把 ALV.Y 写进 VectorVelocity（会锁死竖直速致空中失控）。
	Humanoid：Drive/Impulse 活跃期 PlatformStand=true；电机完全空闲时还原（抑贴地刹车）。
	禁止角色 BodyVelocity / 业务直写 AssemblyLinearVelocity（可破坏物碎片除外）。
	技能位移 Gate 唯一模板：DashStyleRoll；禁止再引入 DirectionalRoll / 裸 BV 翻滚。

	【源仲裁 motionTier】Knockback=100 / Drive=50 / Impulse=40。
	异 session Drive：新 tier≥旧 → 只拆旧 Drive（保留 Impulse，除非 clearImpulsesOnBegin）；
	新 tier<旧 → Begin 拒绝。Knockback 默认与 Drive 叠加（interruptDrive=true 才拆）。
	合成软主导（COMPOSE_SOFT_DOMINANCE）：多源并存时 w=tier/maxTier 后再 composeCap
	（例 Knockback+Drive → 击退全量 + 冲刺×0.5）；硬拆仍用 interruptDrive。

	【碰撞】默认 SlideAlong（Constants.DEFAULT_COLLISION_POLICY / DEFAULT_IMPULSE_COLLISION）；
	MaxForceClip / StopOnHit 须 recipe 或 opts 显式指定。

	【Interrupt 衔步】先读 |lastPlanar|，再 End；peak = clamp(残速*scale, MIN, MAX)
	（DEFAULT_INTERRUPT_BOOST_SCALE=0.55 / MIN=10 / MAX=70）；peakSpeed>0 可绝对覆写。
	默认 collision=SlideAlong。DashStyleRoll 取消用 deferImpulse：ForceCleanup 后再 AddImpulse。

	【ApplyKnockback vs AddImpulse】
	- AddImpulse：通用冲量（衔步 followMoveDirection、自定义 collision 等）
	- ApplyKnockback：击退产品入口；默认 SlideAlong + Linear + duration 0.15 + tier=100 + air×0.85；
	  可选 airMultiplier / interruptDrive（默认与 Drive 叠加，不拆 Session）

	【边界】
	- 不管 SkillActionLock；冻腿由技能 Gate（如 DashStyleRoll）占闸。
	- 不替代 LockMovement / CMS。
	- 服包络见 SystemCharacterMotion（能力窗观测；击退短窗可钳回；拒释 RejectRubberband）。

	【TravelEnd / 控制解锁】
	- ReleaseControlLock：仅放 Jump/Sprint，电机可继续
	- EndTravel ≡ End(preservePhysicsToken=true, releaseControlLock=true) — 结束 Drive→软收束 Impulse
	- soft-merge 预测交接：End(preservePhysicsToken=true, keepDriveActive=true) — 只摘 Session，Drive 继续供 Adopt
	- ForceCleanup：拒释/打断/全清（物理与 Session 表同步摘除，无孤儿 Session）

	【查询】
		CharacterMotion.GetActive(character) -- 含 driveTier / maxImpulseTier
		CharacterMotion.GetDriveRemaining(character)
		CharacterMotion.HasImpulse(character, id?)
		CharacterMotion.GetConstant("MOTION_TIER_DRIVE") -- 只读常量；共享表已 freeze

	【加载】
		local CharacterMotion = Utils.CharacterMotion

	【示例 — Drive】
		CharacterMotion.Begin(character, {
			sessionId = "Skill:NewRoll:" .. castId,
			recipe = CharacterMotion.GetRecipe("NewRoll", "Forward"),
			directionWorld = flatDir,
			controlMask = { Jump = true, Sprint = true },
		})

	【示例 — Knockback】
		CharacterMotion.ApplyKnockback(character, {
			id = "Knock:" .. castId,
			direction = flatAway,
			speed = 60,
			massScale = 1,
			-- durationSec / decay / collisionPolicy 可省略（用击退默认）
		})

	子模块：Constants / Types / Recipes / VelocityMotor / PlanarImpulse
]]

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local CharacterControl = Utils.CharacterControl
local Log = Utils.Log

local Constants = require(script.Constants)
local Recipes = require(script.Recipes)
local VelocityMotor = require(script.VelocityMotor)
local PlanarImpulse = require(script.PlanarImpulse)

local CharacterMotion = {}

-- ========================================
-- 兼容挂载（Constants / Recipes 已 freeze；电机请走 Begin / AddImpulse）
-- ========================================
CharacterMotion.Constants = Constants
CharacterMotion.Recipes = Recipes
CharacterMotion.VelocityMotor = VelocityMotor
CharacterMotion.PlanarImpulse = PlanarImpulse

export type BeginOpts = {
	sessionId: string,
	recipe: any,
	directionWorld: Vector3,
	controlMask: any?,
	controlLockSource: string?,
	adoptIfPresent: boolean?,
	elapsedSec: number?,
	faceDirection: Vector3?,
	motionTier: number?,
}

export type EndOpts = {
	preservePhysicsToken: boolean?,
	releaseControlLock: boolean?,
	-- soft-merge 预测交接：只摘 Session/锁，勿杀 Drive（见 End）
	keepDriveActive: boolean?,
}

export type InterruptOpts = {
	earlyEndBoostDuration: number?,
	earlyEndBoostPeakSpeed: number?,
	earlyEndBoostScale: number?,
	earlyEndBoostMin: number?,
	earlyEndBoostMax: number?,
	earlyEndBoostEasingStyle: Enum.EasingStyle?,
	earlyEndBoostEasingDirection: Enum.EasingDirection?,
	deferImpulse: boolean?,
}

type Session = {
	sessionId: string,
	character: Model,
	attach: Attachment?,
	linearVel: LinearVelocity?,
	controlLockHeld: boolean,
	controlLockSource: string,
	cancelToken: { cancelled: boolean, gen: number },
	recipe: any,
	motionTier: number,
	_controlMask: { Jump: boolean?, Sprint: boolean?, Move: boolean? }?,
}

-- ========================================
-- 私有变量
-- ========================================
local _sessionsByCharacter: { [Model]: Session } = setmetatable({}, { __mode = "k" })
local _rubberbandConnByCharacter: { [Model]: RBXScriptConnection } = setmetatable({}, { __mode = "k" })
-- 电机只在拥有者客户端写 LV；服侧 Begin/Knockback/Rubberband 为 no-op
local _isClient = RunService:IsClient()

-- ========================================
-- 私有函数
-- ========================================

--[[
	解析角色 HumanoidRootPart
	@param character Model - 角色模型
	@return BasePart? - HRP；缺失为 nil
]]
local function _getHRP(character: Model): BasePart?
	if not character then
		return nil
	end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		return hrp
	end
	return nil
end

--[[
	为 Session 压入 CharacterControl 锁（幂等）
	@param session Session - 当前运动会话
	@return () - 无返回值
]]
local function _pushControlLock(session: Session)
	if session.controlLockHeld then
		return
	end
	local ctrl = CharacterControl and CharacterControl.GetForCharacter(session.character)
	if not ctrl then
		return
	end
	local mask = session._controlMask or { Jump = true, Sprint = true }
	ctrl:PushLock(session.controlLockSource, mask)
	session.controlLockHeld = true
end

--[[
	弹出 Session 持有的 CharacterControl 锁（幂等）
	@param session Session - 当前运动会话
	@return () - 无返回值
]]
local function _popControlLock(session: Session)
	if not session.controlLockHeld then
		return
	end
	session.controlLockHeld = false
	local ctrl = CharacterControl and CharacterControl.GetForCharacter(session.character)
	if ctrl then
		ctrl:PopLock(session.controlLockSource)
	end
end

--[[
	将 Interrupt easing 映射为 ImpulseDecay（电机仅支持 Linear / QuadOut）
	@param style Enum.EasingStyle? - 缓动样式
	@param direction Enum.EasingDirection? - 缓动方向
	@return string - "Linear" | "QuadOut"
]]
local function _impulseDecayFromEasing(style: Enum.EasingStyle?, direction: Enum.EasingDirection?): string
	if style == Enum.EasingStyle.Linear then
		return "Linear"
	end
	if style == Enum.EasingStyle.Quad and (direction == nil or direction == Enum.EasingDirection.Out) then
		return "QuadOut"
	end
	-- 未识别样式：保持历史默认衔步曲线
	return "QuadOut"
end

--[[
	目标是否处于空中（击退 airMultiplier 用）
	@param character Model - 角色
	@return boolean - 是否处于 Jumping / Freefall
]]
local function _isAirborne(character: Model): boolean
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return false
	end
	local st = humanoid:GetState()
	return st == Enum.HumanoidStateType.Jumping or st == Enum.HumanoidStateType.Freefall
end

--[[
	异 session 且新 tier 不低于旧时摘旧 Drive Session
	@param character Model - 角色
	@param newSessionId string - 新会话 id
	@param newTier number - 新 Drive motionTier
	@param adoptIfPresent boolean? - true 时不拆既有物理（供 Adopt）
	@return boolean - false 表示被更高 tier 拒绝，Begin 应失败
]]
local function _preemptExistingSession(character: Model, newSessionId: string, newTier: number, adoptIfPresent: boolean?): boolean
	local existing = _sessionsByCharacter[character]
	if not existing or existing.sessionId == newSessionId then
		return true
	end
	local oldTier = existing.motionTier or Constants.MOTION_TIER_DRIVE
	if newTier < oldTier then
		return false
	end
	existing.cancelToken.cancelled = true
	existing.cancelToken.gen += 1
	_popControlLock(existing)
	_sessionsByCharacter[character] = nil
	if not adoptIfPresent then
		VelocityMotor.EndDriveKeepImpulses(character)
	end
	return true
end

--[[
	soft-merge 收养既有 Drive 令牌
	@param session Session - 刚写入的新 Session
	@param HRP BasePart - HumanoidRootPart
	@param recipe table - PlanarRecipe 字段表
	@param opts BeginOpts - Begin 选项（须含 sessionId）
	@param newTier number - Drive motionTier
	@param elapsed number - 已推进秒数
	@param tweenDur number - 曲线总时长（秒）
	@return boolean? - true 收养成功；false 应拒绝 Begin；nil 继续 StartDrive
]]
local function _tryAdoptDrive(
	session: Session,
	HRP: BasePart,
	recipe: any,
	opts: BeginOpts,
	newTier: number,
	elapsed: number,
	tweenDur: number
): boolean?
	if not opts.adoptIfPresent then
		return nil
	end
	if elapsed >= tweenDur then
		_sessionsByCharacter[session.character] = nil
		return false
	end
	local existingAttach, existingLv = VelocityMotor.FindToken(HRP)
	if existingAttach and existingLv then
		local still = VelocityMotor.AdoptDrive(session.character, existingAttach, existingLv, tweenDur, elapsed, recipe, newTier)
		if still then
			session.attach = existingAttach
			session.linearVel = existingLv
			session.cancelToken.gen += 1
			local remain = math.max(0, tweenDur - elapsed)
			local startClock = existingAttach:GetAttribute(Constants.DASH_START_CLOCK_ATTR)
			if type(startClock) == "number" then
				remain = math.max(0, tweenDur - (os.clock() - startClock))
			end
			VelocityMotor.ScheduleDriveEnd(existingAttach, remain, session.cancelToken, session.cancelToken.gen)
			_pushControlLock(session)
			return true
		end
	end
	local skipElapsed = Constants.ADOPT_SKIP_ELAPSED_SEC
	if elapsed > skipElapsed then
		_sessionsByCharacter[session.character] = nil
		return false
	end
	return nil
end

--[[
	按 faceDirection 只转 HRP 水平朝向（不写速度）
	@param HRP BasePart - HumanoidRootPart
	@param faceDirection Vector3? - 世界朝向；模长过小则忽略
]]
local function _faceHRP(HRP: BasePart, faceDirection: Vector3?)
	if not faceDirection or faceDirection.Magnitude <= Constants.PLANAR_EPS then
		return
	end
	local face = Vector3.new(faceDirection.X, 0, faceDirection.Z)
	if face.Magnitude > Constants.PLANAR_EPS then
		HRP.CFrame = CFrame.lookAt(HRP.Position, HRP.Position + face.Unit)
	end
end

-- ========================================
-- 公共函数
-- ========================================

--[[
	取共享配方深拷贝（调用方改写不影响共享表）
	@param skillKey string - 如 NewRoll
	@param direction string - Forward|Backward|Left|Right
	@return table? - PlanarRecipe 深拷贝（planeSpeed / tweenDuration / speedKeys 等）；缺失为 nil
]]
function CharacterMotion.GetRecipe(skillKey: string, direction: string): any?
	return Recipes.Get(skillKey, direction)
end

--[[
	读取电机常量（共享表已 freeze，返回值请当只读）
	@param name string - Constants 字段名，如 "MOTION_TIER_DRIVE" / "DEFAULT_KNOCKBACK_DURATION"
	@return any? - number/string/boolean 或已冻结表；未知名为 nil
]]
function CharacterMotion.GetConstant(name: string): any?
	if type(name) ~= "string" then
		return nil
	end
	return Constants[name]
end

--[[
	查询角色当前 Drive 会话与电机快照
	@param character Model - 角色
	@return table? - SessionInfo（sessionId / driveActive / driveTier / impulseCount 等）；无 Session 且电机空闲为 nil
]]
function CharacterMotion.GetActive(character: Model): any?
	if not character then
		return nil
	end
	local s = _sessionsByCharacter[character]
	local impulseCount = VelocityMotor.CountImpulses(character)
	local driveActive = false
	if s and s.attach and s.linearVel then
		driveActive = VelocityMotor.IsDriveActive(s.attach, s.linearVel)
	elseif VelocityMotor.GetDriveRemaining(character) ~= nil then
		driveActive = true
	end
	local driveTier = VelocityMotor.GetDriveTier(character)
	local maxImpulseTier = VelocityMotor.GetMaxImpulseTier(character)
	if not s then
		if impulseCount <= 0 and not driveActive then
			return nil
		end
		return {
			sessionId = nil,
			character = character,
			attach = nil,
			impulseActive = driveActive, -- deprecated：历史兼容，同 driveActive
			driveActive = driveActive,
			controlLockHeld = false,
			impulseCount = impulseCount,
			driveTier = driveTier,
			maxImpulseTier = maxImpulseTier,
		}
	end
	return {
		sessionId = s.sessionId,
		character = s.character,
		attach = s.attach,
		impulseActive = driveActive, -- deprecated：历史误导名，请用 driveActive
		driveActive = driveActive,
		controlLockHeld = s.controlLockHeld,
		impulseCount = impulseCount,
		driveTier = driveTier or s.motionTier,
		maxImpulseTier = maxImpulseTier,
	}
end

--[[
	Drive 剩余秒数
	@param character Model - 角色
	@return number? - 无活跃 Drive 为 nil
]]
function CharacterMotion.GetDriveRemaining(character: Model): number?
	return VelocityMotor.GetDriveRemaining(character)
end

--[[
	是否存在 Impulse
	@param character Model - 角色
	@param id string? - 指定冲量 id；nil 表示任意
	@return boolean - 存在指定 id（或任意）Impulse 为 true
]]
function CharacterMotion.HasImpulse(character: Model, id: string?): boolean
	return VelocityMotor.HasImpulse(character, id)
end

--[[
	开始或收养 Drive 会话（仅客户端；服务端 no-op）
	@param character Model - 角色
	@param opts BeginOpts - 会话选项（须含 sessionId、recipe、directionWorld；可选 adoptIfPresent / motionTier 等）
	@return boolean - 是否成功建立/收养
]]
function CharacterMotion.Begin(character: Model, opts: BeginOpts): boolean
	if not _isClient then
		return false
	end
	if not character or type(opts) ~= "table" or type(opts.sessionId) ~= "string" then
		return false
	end
	local HRP = _getHRP(character)
	if not HRP then
		return false
	end
	local recipe = opts.recipe
	if type(recipe) ~= "table" or type(recipe.planeSpeed) ~= "number" then
		Log.warn("[CharacterMotion] Begin 需要有效 recipe")
		return false
	end

	local newTier = if type(opts.motionTier) == "number" then opts.motionTier else Constants.MOTION_TIER_DRIVE
	if not _preemptExistingSession(character, opts.sessionId, newTier, opts.adoptIfPresent) then
		return false
	end

	-- soft-merge 收养活跃 Drive 时勿清 Impulse：clear 会在 Drive 已死后打出假「短寿 END」
	local willAdopt = opts.adoptIfPresent == true and VelocityMotor.HasActive(character)
	if recipe.clearImpulsesOnBegin == true and not willAdopt then
		VelocityMotor.ClearImpulses(character)
	end

	local lockSource = opts.controlLockSource or (Constants.DEFAULT_CONTROL_LOCK_SOURCE .. ":" .. opts.sessionId)
	local session: Session = {
		sessionId = opts.sessionId,
		character = character,
		attach = nil,
		linearVel = nil,
		controlLockHeld = false,
		controlLockSource = lockSource,
		cancelToken = { cancelled = false, gen = 0 },
		recipe = recipe,
		motionTier = newTier,
	}
	session._controlMask = opts.controlMask or { Jump = true, Sprint = true }
	_sessionsByCharacter[character] = session

	local elapsed = opts.elapsedSec or 0
	local tweenDur = recipe.tweenDuration or Constants.DEFAULT_TWEEN_DURATION
	local adopted = _tryAdoptDrive(session, HRP, recipe, opts, newTier, elapsed, tweenDur)
	if adopted == true then
		return true
	end
	if adopted == false then
		return false
	end

	_faceHRP(HRP, opts.faceDirection)

	local attach, lv = VelocityMotor.StartDrive(character, HRP, opts.directionWorld, recipe, opts.sessionId, newTier)
	session.attach = attach
	session.linearVel = lv
	if attach then
		session.cancelToken.gen += 1
		VelocityMotor.ScheduleDriveEnd(attach, tweenDur, session.cancelToken, session.cancelToken.gen)
	end
	_pushControlLock(session)
	return attach ~= nil
end

--[[
	结束 Drive 会话
	@param character Model - 角色
	@param sessionId string? - Begin 时的 sessionId
	@param opts EndOpts? - preserve / releaseLock
]]
function CharacterMotion.End(character: Model, sessionId: string?, opts: EndOpts?)
	local session = character and _sessionsByCharacter[character]
	if not session then
		return
	end
	if type(sessionId) == "string" and session.sessionId ~= sessionId then
		return
	end
	opts = opts or {}
	local releaseLock = opts.releaseControlLock ~= false
	local preserve = opts.preservePhysicsToken == true
	local keepDrive = opts.keepDriveActive == true

	session.cancelToken.cancelled = true
	session.cancelToken.gen += 1

	if releaseLock then
		_popControlLock(session)
	end

	if preserve then
		if keepDrive then
			-- soft-merge 预测交接：只摘 Session；Drive/LV 继续跑，供正式 Begin Adopt
			session.attach = nil
			session.linearVel = nil
			_sessionsByCharacter[character] = nil
			return
		end
		-- TravelEnd：结束 Drive→软收束 Impulse，保留 Attach 令牌
		if session.attach then
			VelocityMotor.EndDriveKeepMarker(session.attach)
		end
		session.attach = nil
		session.linearVel = nil
		_sessionsByCharacter[character] = nil
		return
	end

	-- 非 preserve：拆 Drive 令牌（DestroyAll 亦清 Impulse；Interrupt 随后可再 AddImpulse）
	VelocityMotor.DestroyAll(character)
	_sessionsByCharacter[character] = nil
end

--[[
	自然 Travel 结束：放 Jump/Sprint PushLock，不 DestroyAll（保留软收束残速 / 令牌）。
	等价 End(preservePhysicsToken=true, releaseControlLock=true)。
	@param character Model - 角色
	@param sessionId string? - Begin 时的 sessionId
]]
function CharacterMotion.EndTravel(character: Model, sessionId: string?)
	CharacterMotion.End(character, sessionId, {
		preservePhysicsToken = true,
		releaseControlLock = true,
	})
end

--[[
	仅释放 Jump/Sprint PushLock，不结束 Drive（控制解锁可早于电机结束）。
	@param character Model - 角色
	@param sessionId string? - Begin 时的 sessionId
]]
function CharacterMotion.ReleaseControlLock(character: Model, sessionId: string?)
	local session = character and _sessionsByCharacter[character]
	if not session then
		return
	end
	if type(sessionId) == "string" and session.sessionId ~= sessionId then
		return
	end
	_popControlLock(session)
end

--[[
	强制全清 Drive 令牌 + Impulse + 控制锁。
	无论 sessionId 是否匹配，只要清物理就必须同步摘 Session（防孤儿表项）。
	@param character Model - 角色
	@param sessionId string? - 可选；不匹配时仍清物理与 Session
	@param opts { preserveDriveEndBlend: boolean? }? - 软收尾时保留 DriveEndBlend，避免急刹
]]
function CharacterMotion.ForceCleanup(character: Model, sessionId: string?, opts: any?)
	-- sessionId 保留为公开签名；清物理时一律摘 Session（不匹配亦清，防孤儿）
	local _ = sessionId
	local session = character and _sessionsByCharacter[character]
	if session then
		session.cancelToken.cancelled = true
		session.cancelToken.gen += 1
		_popControlLock(session)
		_sessionsByCharacter[character] = nil
	end
	local preserveBlend = type(opts) == "table" and opts.preserveDriveEndBlend == true
	local blendId = Constants.DRIVE_END_BLEND_ID or "DriveEndBlend"
	if preserveBlend then
		VelocityMotor.ClearImpulses(character, nil, blendId)
		if VelocityMotor.HasActive(character) then
			return
		end
	else
		VelocityMotor.ClearImpulses(character)
	end
	VelocityMotor.DestroyAll(character)
end

--[[
	按打断瞬间 Drive 残速推导衔步峰值（不定死绝对值）。
	@param character Model - 角色
	@param opts InterruptOpts? - scale/min/max 或绝对 peakSpeed
	@return number? - 可用峰值；无残速/过小为 nil
]]
function CharacterMotion.ResolveInterruptBoostPeak(character: Model, opts: InterruptOpts?): number?
	opts = opts or {}
	if type(opts.earlyEndBoostPeakSpeed) == "number" and opts.earlyEndBoostPeakSpeed > 0 then
		return opts.earlyEndBoostPeakSpeed
	end
	local residual = VelocityMotor.GetDriveLastPlanar(character)
	local residualMag = if residual then residual.Magnitude else 0
	if residualMag <= 1e-3 then
		return nil
	end
	local scale = if type(opts.earlyEndBoostScale) == "number"
		then opts.earlyEndBoostScale
		else Constants.DEFAULT_INTERRUPT_BOOST_SCALE
	local minP = if type(opts.earlyEndBoostMin) == "number" then opts.earlyEndBoostMin else Constants.INTERRUPT_BOOST_MIN
	local maxP = if type(opts.earlyEndBoostMax) == "number" then opts.earlyEndBoostMax else Constants.INTERRUPT_BOOST_MAX
	return math.clamp(residualMag * scale, minP, maxP)
end

--[[
	提前打断 Drive；可选 earlyEndBoost → Impulse 衔步（禁止 ALV 旁路）。
	峰值：earlyEndBoostPeakSpeed>0 绝对覆写；否则 peak = clamp(|lastPlanar|*scale, min, max)。
	opts.deferImpulse=true：只拆 Drive 并返回 peak，由调用方在 ForceCleanup 之后再 AddImpulse（DashStyleRoll 取消路径）。
	@param character Model - 角色
	@param sessionId string? - Begin 时的 sessionId
	@param opts InterruptOpts? - 衔步时长/比例/缓动
	@return number? - 实际/推导峰值；未写入 Impulse 时也可能返回（defer）
]]
function CharacterMotion.Interrupt(character: Model, sessionId: string?, opts: InterruptOpts?): number?
	local peak = CharacterMotion.ResolveInterruptBoostPeak(character, opts)
	CharacterMotion.End(character, sessionId, {
		preservePhysicsToken = false,
		releaseControlLock = true,
	})
	if type(opts) ~= "table" then
		return peak
	end
	local duration = opts.earlyEndBoostDuration
	if type(duration) ~= "number" or duration <= 0 then
		return peak
	end
	if type(peak) ~= "number" or peak <= 0 then
		return nil
	end
	if opts.deferImpulse == true then
		return peak
	end
	local decay = _impulseDecayFromEasing(opts.earlyEndBoostEasingStyle, opts.earlyEndBoostEasingDirection)
	CharacterMotion.AddImpulse(character, {
		id = "InterruptBoost:" .. (sessionId or tostring(character)),
		followMoveDirection = true,
		peakSpeed = peak,
		durationSec = duration,
		decay = decay,
		collisionPolicy = Constants.DEFAULT_INTERRUPT_BOOST_COLLISION,
		motionTier = Constants.MOTION_TIER_IMPULSE,
	})
	return peak
end

--[[
	叠加平面冲量（通用：衔步 / 自定义衰减等）
	@param character Model - 角色
	@param opts ImpulseOpts - 冲量选项
	@return boolean - 是否写入成功
]]
function CharacterMotion.AddImpulse(character: Model, opts: any): boolean
	return VelocityMotor.AddImpulse(character, opts)
end

--[[
	击退产品入口（规范化默认后走 AddImpulse）。
	默认：decay=Linear、collisionPolicy=SlideAlong、durationSec=0.15、tier=KNOCKBACK、air×0.85；与 Drive 叠加。
	@param character Model - 角色
	@param opts KnockbackOpts - 击退选项（须含 id，以及 direction+speed 或 planarVelocity）
	@return boolean - 是否写入成功
]]
function CharacterMotion.ApplyKnockback(character: Model, opts: any): boolean
	if not _isClient then
		return false
	end
	if not character or type(opts) ~= "table" or type(opts.id) ~= "string" then
		return false
	end

	if opts.interruptDrive == true then
		local session = _sessionsByCharacter[character]
		if session then
			-- 只拆 Drive，保留其它 Impulse；随后写入本条击退
			session.cancelToken.cancelled = true
			session.cancelToken.gen += 1
			_popControlLock(session)
			_sessionsByCharacter[character] = nil
			VelocityMotor.EndDriveKeepImpulses(character)
		else
			local HRP = _getHRP(character)
			if HRP then
				local attach = select(1, VelocityMotor.FindToken(HRP))
				if attach then
					VelocityMotor.EndDriveKeepMarker(attach)
				end
			end
		end
	end

	local airMul = Constants.DEFAULT_KNOCKBACK_AIR_MULTIPLIER
	if type(opts.airMultiplier) == "number" then
		airMul = opts.airMultiplier
	end
	if _isAirborne(character) and airMul ~= 1 then
		-- 拷贝后再改，避免改坏调用方表
		local scaled = table.clone(opts)
		if type(scaled.speed) == "number" then
			scaled.speed = scaled.speed * airMul
		end
		if typeof(scaled.planarVelocity) == "Vector3" then
			scaled.planarVelocity = scaled.planarVelocity * airMul
		end
		opts = scaled
	end

	local normalized = {
		id = opts.id,
		planarVelocity = opts.planarVelocity,
		direction = opts.direction,
		speed = opts.speed,
		durationSec = if type(opts.durationSec) == "number" then opts.durationSec else Constants.DEFAULT_KNOCKBACK_DURATION,
		decay = opts.decay or Constants.DEFAULT_KNOCKBACK_DECAY,
		maxSpeed = opts.maxSpeed,
		maxDistance = opts.maxDistance,
		massScale = if type(opts.massScale) == "number" then opts.massScale else 1,
		collisionPolicy = opts.collisionPolicy or Constants.DEFAULT_KNOCKBACK_COLLISION,
		composeCap = opts.composeCap,
		followMoveDirection = false,
		motionTier = if type(opts.motionTier) == "number" then opts.motionTier else Constants.MOTION_TIER_KNOCKBACK,
	}
	return VelocityMotor.AddImpulse(character, normalized)
end

--[[
	清除 Impulse 层
	@param character Model - 角色
	@param id string? - 指定 id；nil 全清
]]
function CharacterMotion.ClearImpulses(character: Model, id: string?)
	VelocityMotor.ClearImpulses(character, id)
end

--[[
	客户端位置 rubberband（服 SynPlayerCFrame）；同角色再入会先断开旧 Heartbeat
	@param character Model - 角色
	@param targetPos Vector3 - 目标世界坐标
	@param durationSec number? - 插值时长；缺省 Constants.RUBBERBAND_DEFAULT_SEC
	@return () - 无返回值
]]
function CharacterMotion.RubberbandTo(character: Model, targetPos: Vector3, durationSec: number?)
	if not _isClient or not character or typeof(targetPos) ~= "Vector3" then
		return
	end
	local HRP = _getHRP(character)
	if not HRP then
		return
	end
	-- 纠偏前清电机，避免与 Rubberband 抢写
	local session = _sessionsByCharacter[character]
	if session then
		session.cancelToken.cancelled = true
		session.cancelToken.gen += 1
		_popControlLock(session)
		_sessionsByCharacter[character] = nil
	end
	VelocityMotor.ClearImpulses(character)
	VelocityMotor.DestroyAll(character)
	local prevConn = _rubberbandConnByCharacter[character]
	if prevConn then
		prevConn:Disconnect()
		_rubberbandConnByCharacter[character] = nil
	end
	local dur = durationSec or Constants.RUBBERBAND_DEFAULT_SEC
	if dur <= 1e-3 then
		HRP.CFrame = CFrame.new(targetPos) * (HRP.CFrame - HRP.CFrame.Position)
		return
	end
	local startCF = HRP.CFrame
	local goalCF = CFrame.new(targetPos) * (startCF - startCF.Position)
	local t0 = os.clock()
	local conn
	conn = RunService.Heartbeat:Connect(function()
		if not HRP.Parent then
			conn:Disconnect()
			if _rubberbandConnByCharacter[character] == conn then
				_rubberbandConnByCharacter[character] = nil
			end
			return
		end
		local a = math.clamp((os.clock() - t0) / dur, 0, 1)
		local eased = TweenService:GetValue(a, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		HRP.CFrame = startCF:Lerp(goalCF, eased)
		if a >= 1 then
			conn:Disconnect()
			if _rubberbandConnByCharacter[character] == conn then
				_rubberbandConnByCharacter[character] = nil
			end
		end
	end)
	_rubberbandConnByCharacter[character] = conn
end

return CharacterMotion
