--[[
	Module: CharacterMotion.VelocityMotor
	Description: 可控速度电机：Compose(Drive+Impulse) → 意图路程 → 扫掠碰撞 → 仅 XZ 写 LinearVelocity
	Author: 林奥宇
	Created: 2026-08-05
	Last Modified: 2026-08-31

	【写入】
	- Drive：短时接管平面速度曲线（Begin Session；easing / speedKeys 可编）
	- Impulse：衰减冲量叠加（AddImpulse / ApplyKnockback / Interrupt 衔步）
	- DriveEndBlend：软结束残速 blendToWalk → WalkSpeed
	禁止业务旁路直写 AssemblyLinearVelocity 做能力位移/击退。

	【PreserveY 真义】LV 仅约束 XZ（ForceLimitMode=PerAxis，MaxAxesForce.Y=0）。
	禁止把 AssemblyLinearVelocity.Y 写进 VectorVelocity：Vector+高 MaxForce 会锁死竖直速，
	空中起跳残速→上飘、顶点飘移→水平距失控。
	XZ MaxAxesForce 用 math.huge：50000 级力压不过贴地摩擦，地面冲刺会远短于空中。

	【Humanoid】Drive/Impulse 活跃期 PlatformStand=true，避免贴地刹车与 LV 抢 XZ（地面/空中距差）。
	控制解锁不提前还原；电机完全空闲（无 Drive、无 Impulse）时还原。
	电机 tick 绑 PreSimulation（物理前写速）。

	【碰撞】StopOnHit / SlideAlong / MaxForceClip；按 motionTier + 严格度合成；Blockcast 扫掠。
	缺省 SlideAlong（Constants.DEFAULT_COLLISION_POLICY）；MaxForceClip 须显式指定。
	【路程】预算积意图位移 |vPlanar|*dt（碰撞裁切后），不吃 Rubberband 位置跳变。
	【合成】软主导 COMPOSE_SOFT_DOMINANCE：w=tier/maxTier 后再 composeCap；false 则裸加。
]]

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local RayCast = Utils.RayCast
local Log = Utils.Log

local Constants = require(script.Parent.Constants)

local VelocityMotor = {}

type SpeedKey = { t: number, factor: number }

type DriveState = {
	startPlanar: Vector3,
	goalPlanar: Vector3,
	lastPlanar: Vector3,
	dirUnit: Vector3,
	planeSpeed: number,
	vectorEndFactor: number,
	easingStyle: Enum.EasingStyle,
	easingDirection: Enum.EasingDirection,
	speedKeys: { SpeedKey }?,
	t0: number,
	dur: number,
	maxDistance: number?,
	traveled: number,
	collisionPolicy: string,
	enforceMaxDistance: boolean,
	ended: boolean,
	motionTier: number,
}

type ImpulseEntry = {
	id: string,
	basePlanar: Vector3,
	t0: number,
	duration: number,
	decay: string,
	maxSpeed: number?,
	maxDistance: number?,
	traveled: number,
	collisionPolicy: string?,
	followMoveDirection: boolean,
	blendToWalk: boolean,
	-- blendToWalk：锁速刚放时 WalkSpeed 可能仍为 0，有移向时用此下限
	walkSpeedFloor: number?,
	peakSpeed: number,
	massScale: number,
	motionTier: number,
	lastFollowDir: Vector3?,
}

type Motor = {
	character: Model,
	HRP: BasePart,
	attach: Attachment?,
	lv: LinearVelocity?,
	drive: DriveState?,
	impulses: { [string]: ImpulseEntry },
	lastPos: Vector3?,
	rayParams: RaycastParams?,
	conn: RBXScriptConnection?,
	composeCap: number?,
	-- Drive/Impulse 活跃期压制 Humanoid 贴地刹车
	humanoidSuppressActive: boolean,
	platformStandPrev: boolean?,
	humanoid: Humanoid?,
	-- DEBUG_PLANAR_MOTION / CM_DebugMotion
	debugP0: Vector3?,
	debugT0: number?,
	debugSumCmd: number?,
	debugSumAct: number?,
	debugSamples: number?,
	debugLastLog: number?,
}

local _motors: { [Model]: Motor } = setmetatable({}, { __mode = "k" })

-- ========================================
-- 私有函数
-- ========================================

--[[
	判断 Attachment 是否为本电机令牌（含 NewRoll 旧名）
	@param att Instance - HRP 子实例
	@return boolean - 是电机 Attachment 为 true
]]
local function _isAttachToken(att: Instance): boolean
	if not att:IsA("Attachment") then
		return false
	end
	if att.Name == Constants.ATTACH_NAME or att.Name == Constants.LEGACY_ATTACH_NAME then
		return true
	end
	local lv = att:FindFirstChild(Constants.LV_NAME) or att:FindFirstChild(Constants.LEGACY_LV_NAME)
	return lv ~= nil and lv:IsA("LinearVelocity")
end

--[[
	在令牌 Attachment 上查找 LinearVelocity（含旧名）
	@param att Attachment - 电机 Attachment
	@return LinearVelocity? - 约束实例；缺失为 nil
]]
local function _findLv(att: Attachment): LinearVelocity?
	local lv = att:FindFirstChild(Constants.LV_NAME)
	if lv and lv:IsA("LinearVelocity") then
		return lv
	end
	lv = att:FindFirstChild(Constants.LEGACY_LV_NAME)
	if lv and lv:IsA("LinearVelocity") then
		return lv
	end
	return nil
end

--[[
	销毁 HRP 上全部电机 Attachment 令牌（含旧名）
	@param HRP BasePart - 角色 HumanoidRootPart
]]
local function _destroyDriveTokensOnly(HRP: BasePart)
	local toDestroy = {}
	for _, child in HRP:GetChildren() do
		if _isAttachToken(child) then
			table.insert(toDestroy, child)
		end
	end
	for _, att in ipairs(toDestroy) do
		att:Destroy()
	end
end

--[[
	取得电机扫掠用 RaycastParams（Exclude 自身角色）
	@param motor Motor - 电机状态
	@return RaycastParams - 可复用参数
]]
local function _ensureRayParams(motor: Motor): RaycastParams
	if motor.rayParams then
		motor.rayParams.FilterDescendantsInstances = { motor.character }
		return motor.rayParams
	end
	local params = RayCast.GetRayCastParams("All", {
		filterType = Enum.RaycastFilterType.Exclude,
		instances = { motor.character },
		ignoreWater = true,
	})
	motor.rayParams = params
	return params
end

--[[
	按衰减类型把归一化时间映射为剩余倍率（1→0）
	@param alpha number - 已过时长比例，钳制到 [0,1]
	@param decay string - "Linear" | "QuadOut" | "QuadIn"
	@return number - 剩余包络 [0,1]
]]
local function _decayEnvelope(alpha: number, decay: string): number
	alpha = math.clamp(alpha, 0, 1)
	if decay == "QuadOut" then
		local eased = TweenService:GetValue(alpha, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		return 1 - eased
	elseif decay == "QuadIn" then
		local eased = TweenService:GetValue(alpha, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		return 1 - eased
	end
	return 1 - alpha
end

--[[
	去掉 Y 后按上限钳制平面速度
	@param v Vector3 - 任意速度
	@param cap number? - 平面速上限；nil 或不大于 0 表示不钳
	@return Vector3 - Y=0 的平面速度
]]
local function _clampPlanar(v: Vector3, cap: number?): Vector3
	local flat = Vector3.new(v.X, 0, v.Z)
	if type(cap) == "number" and cap > 0 and flat.Magnitude > cap then
		return flat.Unit * cap
	end
	return flat
end

--[[
	配置仅约束水平面的 LinearVelocity（Y 力=0，重力/跳跃归物理）。
	@param lv LinearVelocity - 要配置的约束
	@param maxForce number? - 标量 MaxForce 回退；XZ 轴向力优先用 DEFAULT_MAX_AXES_FORCE
]]
local function _configurePlanarLv(lv: LinearVelocity, maxForce: number?)
	local f = if type(maxForce) == "number" and maxForce > 0 then maxForce else Constants.DEFAULT_MAX_FORCE
	-- XZ 用 DEFAULT_MAX_AXES_FORCE（math.huge）压过贴地摩擦；Y=0 不抢重力
	local axes = Constants.DEFAULT_MAX_AXES_FORCE
	if type(axes) ~= "number" or axes <= 0 then
		axes = f
	end
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	lv.ForceLimitsEnabled = true
	lv.ForceLimitMode = Enum.ForceLimitMode.PerAxis
	lv.MaxAxesForce = Vector3.new(axes, 0, axes)
	lv.MaxForce = f
end

--[[
	只写平面目标速；Y 分量恒 0（由 MaxAxesForce.Y=0 保证不控竖直）。
	@param lv LinearVelocity - 要写入的约束
	@param planar Vector3 - 合速度（Y 忽略，写入时钳为 0）
]]
local function _writePlanarVelocity(lv: LinearVelocity, planar: Vector3)
	lv.VectorVelocity = Vector3.new(planar.X, 0, planar.Z)
end

--[[
	是否仍有未到期 Impulse
	@param motor Motor - 电机状态
	@return boolean - impulses 表非空为 true
]]
local function _hasActiveImpulse(motor: Motor): boolean
	return next(motor.impulses) ~= nil
end

--[[
	Drive 曲线是否仍在驱动
	@param motor Motor - 电机状态
	@return boolean - 有未 ended 的 Drive 为 true
]]
local function _driveActive(motor: Motor): boolean
	return motor.drive ~= nil and not motor.drive.ended
end

--[[
	取角色 Humanoid（缓存；Parent 丢失时重查）
	@param motor Motor - 电机状态
	@return Humanoid? - 缺失为 nil
]]
local function _getHumanoid(motor: Motor): Humanoid?
	local humanoid = motor.humanoid
	if humanoid and humanoid.Parent then
		return humanoid
	end
	humanoid = motor.character:FindFirstChildOfClass("Humanoid")
	motor.humanoid = humanoid
	return humanoid
end

--[[
	压制 Humanoid 平面控制（PlatformStand），避免 WalkSpeed=0 时贴地刹车与 LV 对打。
	幂等：已压制则不改 prev。
	@param motor Motor - 电机状态
]]
local function _pushHumanoidSuppress(motor: Motor)
	if motor.humanoidSuppressActive then
		return
	end
	local humanoid = _getHumanoid(motor)
	if not humanoid then
		return
	end
	motor.platformStandPrev = humanoid.PlatformStand
	humanoid.PlatformStand = true
	motor.humanoidSuppressActive = true
end

--[[
	还原 PlatformStand（仅本电机曾 push 时）。
	@param motor Motor - 电机状态
]]
local function _popHumanoidSuppress(motor: Motor)
	if not motor.humanoidSuppressActive then
		return
	end
	local humanoid = _getHumanoid(motor)
	if humanoid then
		humanoid.PlatformStand = motor.platformStandPrev == true
	end
	motor.humanoidSuppressActive = false
	motor.platformStandPrev = nil
end

--[[
	无 Drive 且无 Impulse 时还原 Humanoid 压制。
	@param motor Motor - 电机状态
]]
local function _maybeReleaseHumanoidSuppress(motor: Motor)
	if _driveActive(motor) or _hasActiveImpulse(motor) then
		return
	end
	_popHumanoidSuppress(motor)
end

--[[
	是否开启平面位移诊断（Output [CM_Debug]）
	@return boolean - 常量或 LocalPlayer Attribute 打开时为 true
]]
local function _debugEnabled(): boolean
	if Constants.DEBUG_PLANAR_MOTION == true then
		return true
	end
	local lp = Players.LocalPlayer
	if lp and lp:GetAttribute("CM_DebugMotion") == true then
		return true
	end
	return false
end

--[[
	Begin 时记录起点与约束状态
	@param motor Motor - 电机状态
	@param tag string - 来源标签（StartDrive / AdoptDrive）
]]
local function _debugBegin(motor: Motor, tag: string)
	if not _debugEnabled() then
		return
	end
	motor.debugP0 = motor.HRP.Position
	motor.debugT0 = os.clock()
	motor.debugSumCmd = 0
	motor.debugSumAct = 0
	motor.debugSamples = 0
	motor.debugLastLog = 0
	local hum = _getHumanoid(motor)
	local lv = motor.lv
	local maf = if lv then lv.MaxAxesForce else Vector3.zero
	Log.print(
		string.format(
			"[CM_Debug] BEGIN(%s) PS=%s state=%s MaxAxesForce=(%.0f,%.0f,%.0f) ForceLimitMode=%s",
			tag,
			tostring(hum and hum.PlatformStand),
			tostring(hum and hum:GetState().Name),
			maf.X,
			maf.Y,
			maf.Z,
			tostring(lv and lv.ForceLimitMode)
		)
	)
end

--[[
	采样指令平面速 vs 实际 ALV.xz
	@param motor Motor - 电机状态
	@param vPlanar Vector3 - 本帧指令平面速
]]
local function _debugSample(motor: Motor, vPlanar: Vector3)
	if not _debugEnabled() or type(motor.debugT0) ~= "number" then
		return
	end
	local alv = motor.HRP.AssemblyLinearVelocity
	local act = Vector3.new(alv.X, 0, alv.Z).Magnitude
	local cmd = vPlanar.Magnitude
	motor.debugSumCmd = (motor.debugSumCmd or 0) + cmd
	motor.debugSumAct = (motor.debugSumAct or 0) + act
	motor.debugSamples = (motor.debugSamples or 0) + 1
	local now = os.clock()
	if now - (motor.debugLastLog or 0) < 0.15 then
		return
	end
	motor.debugLastLog = now
	local hum = _getHumanoid(motor)
	local ratio = if cmd > 1e-3 then act / cmd else 0
	Log.print(
		string.format(
			"[CM_Debug] t=%.2f cmd=%.1f act=%.1f ratio=%.2f PS=%s state=%s",
			now - motor.debugT0,
			cmd,
			act,
			ratio,
			tostring(hum and hum.PlatformStand),
			tostring(hum and hum:GetState().Name)
		)
	)
end

--[[
	电机空闲时汇总水平弦长与平均速比
	@param motor Motor - 电机状态
	@param reason string - 结束原因标签
]]
local function _debugEnd(motor: Motor, reason: string)
	if not _debugEnabled() or not motor.debugP0 or type(motor.debugT0) ~= "number" then
		return
	end
	local p1 = motor.HRP.Position
	local dxz = Vector3.new(p1.X - motor.debugP0.X, 0, p1.Z - motor.debugP0.Z).Magnitude
	local elapsed = os.clock() - motor.debugT0
	local n = math.max(motor.debugSamples or 0, 1)
	local avgCmd = (motor.debugSumCmd or 0) / n
	local avgAct = (motor.debugSumAct or 0) / n
	local ratio = if avgCmd > 1e-3 then avgAct / avgCmd else 0
	local alv = motor.HRP.AssemblyLinearVelocity
	local residual = Vector3.new(alv.X, 0, alv.Z).Magnitude
	Log.print(
		string.format(
			"[CM_Debug] END(%s) dt=%.2f |dXZ|=%.1f avgCmd=%.1f avgAct=%.1f act/cmd=%.2f residualXZ=%.1f",
			reason,
			elapsed,
			dxz,
			avgCmd,
			avgAct,
			ratio,
			residual
		)
	)
	motor.debugP0 = nil
	motor.debugT0 = nil
end

--[[
	blendToWalk 目标走速：优先 Humanoid.WalkSpeed；仍为 0 时用 ExpectedWalkSpeed / 常量兜底。
	@param humanoid Humanoid? - 角色 Humanoid；缺失时走 Attribute / 常量兜底
	@return number - 可用走速（≥0）
]]
local function _resolveBlendWalkSpeed(humanoid: Humanoid?): number
	local ws = if humanoid then humanoid.WalkSpeed else 0
	if type(ws) == "number" and ws > 1e-3 then
		return ws
	end
	local lp = Players.LocalPlayer
	if lp then
		local attrName = Constants.EXPECTED_WALKSPEED_ATTR or "ExpectedWalkSpeed"
		local expected = lp:GetAttribute(attrName)
		if type(expected) == "number" and expected > 1e-3 then
			return expected
		end
	end
	local fallback = Constants.BLEND_WALK_SPEED_FALLBACK
	if type(fallback) == "number" and fallback > 1e-3 then
		return fallback
	end
	return Constants.BLEND_WALK_SPEED_FALLBACK
end

--[[
	碰撞策略严格度（数字越大越严）
	@param policy string - StopOnHit / SlideAlong / MaxForceClip
	@return number - 严格度；未知策略为 0
]]
local function _policyStrictness(policy: string): number
	local tableRef = Constants.POLICY_STRICTNESS
	local n = tableRef and tableRef[policy]
	if type(n) == "number" then
		return n
	end
	return 0
end

--[[
	从 recipe 解析 easing；缺省 Quad/Out（历史行为）
	@param recipe any? - PlanarRecipe 或空；缺省 Quad / Out
	@return Enum.EasingStyle - 缓动样式
	@return Enum.EasingDirection - 缓动方向
]]
local function _recipeEasing(recipe: any?): (Enum.EasingStyle, Enum.EasingDirection)
	local style = Enum.EasingStyle.Quad
	local dir = Enum.EasingDirection.Out
	if type(recipe) == "table" then
		if typeof(recipe.easingStyle) == "EnumItem" then
			style = recipe.easingStyle
		end
		if typeof(recipe.easingDirection) == "EnumItem" then
			dir = recipe.easingDirection
		end
	end
	return style, dir
end

--[[
	拷贝并排序 speedKeys
	@param keys any? - recipe.speedKeys；非法项丢弃
	@return { SpeedKey }? - 已按 t 排序的拷贝；无有效项为 nil
]]
local function _copySpeedKeys(keys: any?): { SpeedKey }?
	if type(keys) ~= "table" or #keys == 0 then
		return nil
	end
	local out: { SpeedKey } = {}
	for _, k in ipairs(keys) do
		if type(k) == "table" and type(k.t) == "number" and type(k.factor) == "number" then
			table.insert(out, { t = k.t, factor = k.factor })
		end
	end
	if #out == 0 then
		return nil
	end
	table.sort(out, function(a, b)
		return a.t < b.t
	end)
	return out
end

--[[
	分段线性采样 speedKeys 得到速率倍率
	@param keys { SpeedKey } - 已排序关键帧
	@param alpha number - 归一化时间 [0,1]
	@return number - 采样得到的速率倍率
]]
local function _sampleSpeedKeys(keys: { SpeedKey }, alpha: number): number
	alpha = math.clamp(alpha, 0, 1)
	if #keys == 1 then
		return keys[1].factor
	end
	if alpha <= keys[1].t then
		return keys[1].factor
	end
	if alpha >= keys[#keys].t then
		return keys[#keys].factor
	end
	for i = 1, #keys - 1 do
		local a = keys[i]
		local b = keys[i + 1]
		if alpha >= a.t and alpha <= b.t then
			local span = b.t - a.t
			if span < 1e-8 then
				return b.factor
			end
			local u = (alpha - a.t) / span
			return a.factor + (b.factor - a.factor) * u
		end
	end
	return keys[#keys].factor
end

--[[
	按 DriveState 包络求当前平面速度（不写 ended）
	@param drive DriveState - Drive 曲线快照
	@param now number - os.clock 当前时间
	@return Vector3 - 当前平面速度（Y=0）
	@return number - 归一化进度 alpha∈[0,1]
]]
local function _evalDrivePlanar(drive: DriveState, now: number): (Vector3, number)
	local alpha = math.clamp((now - drive.t0) / math.max(drive.dur, 1e-4), 0, 1)
	if drive.speedKeys and #drive.speedKeys > 0 then
		local factor = _sampleSpeedKeys(drive.speedKeys, alpha)
		local planar = drive.dirUnit * (drive.planeSpeed * factor)
		return Vector3.new(planar.X, 0, planar.Z), alpha
	end
	local eased = TweenService:GetValue(alpha, drive.easingStyle, drive.easingDirection)
	local lerped = drive.startPlanar:Lerp(drive.goalPlanar, eased)
	return Vector3.new(lerped.X, 0, lerped.Z), alpha
end

--[[
	断开电机 PreSimulation 连接
	@param motor Motor - 电机状态
]]
local function _stopHeartbeat(motor: Motor)
	if motor.conn then
		motor.conn:Disconnect()
		motor.conn = nil
	end
end

-- 前向声明：软结束转 Impulse 时可能需保活 Heartbeat
local _ensureHeartbeat: (Motor) -> ()

--[[
	结束 Drive 曲线并保留 Attach 令牌；软结束可转 DriveEndBlend Impulse
	@param motor Motor - 电机状态
	@param hardStop boolean? - true 时不转 blend、立即停 LV
]]
local function _endDriveKeepMarker(motor: Motor, hardStop: boolean?)
	local residual = Vector3.zero
	local drive = motor.drive
	if drive then
		if not hardStop then
			local last = drive.lastPlanar
			if last and last.Magnitude > Constants.PLANAR_EPS then
				residual = Vector3.new(last.X, 0, last.Z)
			else
				residual = Vector3.new(drive.goalPlanar.X, 0, drive.goalPlanar.Z)
			end
		end
		drive.ended = true
	end
	motor.drive = nil
	local attach = motor.attach
	local lv = motor.lv
	if attach then
		attach:SetAttribute(Constants.IMPULSE_ENDED_ATTR, true)
	end

	-- 软结束且无其它 Impulse：残速转短寿 Impulse，避免倒 ALV 后脱电机
	local humanoidForBlend = _getHumanoid(motor)
	local md0 = if humanoidForBlend then humanoidForBlend.MoveDirection else Vector3.zero
	local hasMoveIntent = Vector3.new(md0.X, 0, md0.Z).Magnitude > Constants.MOVE_INTENT_MAG_MIN
	local blendSec = if hasMoveIntent
		then Constants.DRIVE_END_BLEND_SEC
		else (Constants.DRIVE_END_BLEND_IDLE_SEC or Constants.DRIVE_END_BLEND_SEC)
	if
		not hardStop
		and residual.Magnitude > 1e-3
		and not _hasActiveImpulse(motor)
		and type(blendSec) == "number"
		and blendSec > 0
	then
		local blendId = Constants.DRIVE_END_BLEND_ID or "DriveEndBlend"
		local walkFloor = _resolveBlendWalkSpeed(humanoidForBlend)
		motor.impulses[blendId] = {
			id = blendId,
			basePlanar = residual,
			t0 = os.clock(),
			duration = blendSec,
			-- QuadOut：前段多掉速，收束更干脆、少滑
			decay = "QuadOut",
			maxSpeed = nil,
			maxDistance = nil,
			traveled = 0,
			collisionPolicy = "SlideAlong",
			followMoveDirection = false,
			blendToWalk = true,
			walkSpeedFloor = walkFloor,
			peakSpeed = 0,
			massScale = 1,
			motionTier = Constants.MOTION_TIER_IMPULSE,
			lastFollowDir = nil,
		}
		if lv then
			lv.Enabled = true
			_writePlanarVelocity(lv, residual)
		end
		_ensureHeartbeat(motor)
		return
	end

	if not _hasActiveImpulse(motor) then
		if lv then
			if hardStop then
				lv.VectorVelocity = Vector3.zero
				lv.Enabled = false
			else
				lv.Enabled = false
				lv.VectorVelocity = Vector3.zero
			end
		end
		_stopHeartbeat(motor)
		_debugEnd(motor, "endDriveNoBlend")
		_maybeReleaseHumanoidSuppress(motor)
	end
end

--[[
	合成全部 Impulse 平面贡献，并摘除到期条目
	@param motor Motor - 电机状态
	@param now number - os.clock 当前时间
	@return Vector3 - Impulse 合速度（Y=0）
]]
local function _composeImpulse(motor: Motor, now: number): Vector3
	local sum = Vector3.zero
	local toRemove = {}
	local humanoid = _getHumanoid(motor)
	for id, entry in pairs(motor.impulses) do
		local elapsed = now - entry.t0
		if elapsed >= entry.duration then
			table.insert(toRemove, id)
		else
			local alpha = if entry.duration > 1e-6 then elapsed / entry.duration else 1
			local env = _decayEnvelope(alpha, entry.decay)
			local contrib: Vector3
			if entry.blendToWalk then
				-- env: 1→0；u: 0→1，残速 lerp 到当前走速意图
				local u = 1 - env
				local md = if humanoid then humanoid.MoveDirection else Vector3.zero
				local flatMd = Vector3.new(md.X, 0, md.Z)
				local target = Vector3.zero
				if flatMd.Magnitude > 1e-3 then
					local live = if humanoid then humanoid.WalkSpeed else 0
					local floor = entry.walkSpeedFloor
					local walkSpeed = if type(live) == "number" and live > 1e-3 then live else 0
					if walkSpeed <= 1e-3 and type(floor) == "number" and floor > 1e-3 then
						walkSpeed = floor
					elseif walkSpeed <= 1e-3 then
						walkSpeed = _resolveBlendWalkSpeed(humanoid)
					end
					if walkSpeed > 1e-3 then
						target = flatMd.Unit * walkSpeed
					end
				end
				local start = Vector3.new(entry.basePlanar.X, 0, entry.basePlanar.Z)
				contrib = start:Lerp(target, u)
			elseif entry.followMoveDirection then
				local md = if humanoid then humanoid.MoveDirection else Vector3.zero
				local flat = Vector3.new(md.X, 0, md.Z)
				if flat.Magnitude > 1e-3 then
					entry.lastFollowDir = flat.Unit
				end
				local dir = entry.lastFollowDir
				if dir and dir.Magnitude > Constants.PLANAR_EPS then
					contrib = dir * (entry.peakSpeed * env * entry.massScale)
				else
					contrib = Vector3.zero
				end
			else
				contrib = entry.basePlanar * env
			end
			if type(entry.maxSpeed) == "number" and entry.maxSpeed > 0 then
				contrib = _clampPlanar(contrib, entry.maxSpeed)
			end
			sum += contrib
		end
	end
	for _, id in ipairs(toRemove) do
		motor.impulses[id] = nil
	end
	return Vector3.new(sum.X, 0, sum.Z)
end

--[[
	求当前 Drive 平面速；alpha 满时走软结束
	@param motor Motor - 电机状态
	@param now number - os.clock 当前时间
	@return Vector3 - Drive 平面速；无活跃 Drive 为零
]]
local function _composeDrive(motor: Motor, now: number): Vector3
	local drive = motor.drive
	if not drive or drive.ended then
		return Vector3.zero
	end
	local planar, alpha = _evalDrivePlanar(drive, now)
	drive.lastPlanar = planar
	if alpha >= 1 then
		_endDriveKeepMarker(motor, false)
		return planar
	end
	return planar
end

--[[
	按 HRP 尺寸计算水平扫掠盒子
	@param HRP BasePart - HumanoidRootPart
	@return Vector3 - Blockcast 尺寸
]]
local function _blockcastSize(HRP: BasePart): Vector3
	local s = HRP.Size
	local y = math.min(s.Y * Constants.BLOCKCAST_Y_SCALE, Constants.BLOCKCAST_Y_MAX)
	return Vector3.new(s.X * Constants.BLOCKCAST_XZ_SCALE, math.max(y, 0.5), s.Z * Constants.BLOCKCAST_XZ_SCALE)
end

--[[
	按策略对平面速做 Blockcast 扫掠（Stop / Slide / Clip）
	@param motor Motor - 电机状态
	@param vPlanar Vector3 - 合成后的指令平面速
	@param dt number - 本帧 dt
	@param policy string - StopOnHit | SlideAlong | MaxForceClip
	@return Vector3 - 裁切后的平面速
]]
local function _applyCollision(motor: Motor, vPlanar: Vector3, dt: number, policy: string): Vector3
	if policy == "MaxForceClip" or policy == nil then
		return vPlanar
	end
	local speed = vPlanar.Magnitude
	if speed < 1e-3 then
		return vPlanar
	end
	local probe = speed * math.max(dt, 1e-4) + Constants.COLLISION_PROBE_SKIN
	local params = _ensureRayParams(motor)
	local dir = vPlanar.Unit
	local size = _blockcastSize(motor.HRP)
	local hit = workspace:Blockcast(CFrame.new(motor.HRP.Position), size, dir * probe, params)
	if not hit then
		return vPlanar
	end
	local n = hit.Normal
	if math.abs(n.Y) > Constants.WALL_NORMAL_Y_MAX then
		return vPlanar
	end
	local nFlat = Vector3.new(n.X, 0, n.Z)
	if nFlat.Magnitude < Constants.PLANAR_EPS then
		return vPlanar
	end
	nFlat = nFlat.Unit

	if motor.attach then
		motor.attach:SetAttribute(Constants.COLLISION_HIT_ATTR, true)
	end

	if policy == "StopOnHit" then
		if _driveActive(motor) then
			_endDriveKeepMarker(motor, true)
		end
		for _, entry in pairs(motor.impulses) do
			local flat = Vector3.new(entry.basePlanar.X, 0, entry.basePlanar.Z)
			local along = nFlat * flat:Dot(nFlat)
			entry.basePlanar = flat - along
			if entry.followMoveDirection then
				entry.peakSpeed = 0
			end
		end
		return Vector3.zero
	end

	if policy == "SlideAlong" then
		local slid = vPlanar - nFlat * vPlanar:Dot(nFlat)
		slid = Vector3.new(slid.X, 0, slid.Z)
		if motor.drive and not motor.drive.ended then
			local d = motor.drive
			d.startPlanar = d.startPlanar - nFlat * d.startPlanar:Dot(nFlat)
			d.goalPlanar = d.goalPlanar - nFlat * d.goalPlanar:Dot(nFlat)
			d.startPlanar = Vector3.new(d.startPlanar.X, 0, d.startPlanar.Z)
			d.goalPlanar = Vector3.new(d.goalPlanar.X, 0, d.goalPlanar.Z)
			local flatDir = Vector3.new(d.dirUnit.X, 0, d.dirUnit.Z) - nFlat * d.dirUnit:Dot(nFlat)
			if flatDir.Magnitude > Constants.PLANAR_EPS then
				d.dirUnit = flatDir.Unit
			end
		end
		for _, entry in pairs(motor.impulses) do
			if not entry.followMoveDirection then
				local flat = Vector3.new(entry.basePlanar.X, 0, entry.basePlanar.Z)
				entry.basePlanar = flat - nFlat * flat:Dot(nFlat)
			end
		end
		return slid
	end

	return vPlanar
end

--[[
	碰撞策略：活跃源中最高 motionTier 的 policy；同 tier 取更严。
	缺省 policy 用 DEFAULT_COLLISION_POLICY / DEFAULT_IMPULSE_COLLISION，勿回落 StopOnHit。
	@param motor Motor - 电机状态
	@return string - 最终碰撞策略名
]]
local function _resolvePolicy(motor: Motor): string
	local bestTier = -1
	local bestStrict = -1
	local bestPolicy: string? = nil

	local function consider(tier: number, policy: string?)
		if type(policy) ~= "string" then
			return
		end
		local strict = _policyStrictness(policy)
		if tier > bestTier or (tier == bestTier and strict > bestStrict) then
			bestTier = tier
			bestStrict = strict
			bestPolicy = policy
		end
	end

	if motor.drive and not motor.drive.ended then
		local drivePolicy = motor.drive.collisionPolicy or Constants.DEFAULT_COLLISION_POLICY
		consider(motor.drive.motionTier or Constants.MOTION_TIER_DRIVE, drivePolicy)
	end
	local impulseDefault = Constants.DEFAULT_IMPULSE_COLLISION or Constants.DEFAULT_COLLISION_POLICY
	for _, entry in pairs(motor.impulses) do
		local policy = entry.collisionPolicy or impulseDefault
		consider(entry.motionTier or Constants.MOTION_TIER_IMPULSE, policy)
	end

	if bestPolicy then
		return bestPolicy
	end
	return Constants.DEFAULT_COLLISION_POLICY
end

--[[
	按 motionTier 软主导加权后合成平面速，再套 composeCap。
	w = tier/maxTier；仅单侧活跃或 COMPOSE_SOFT_DOMINANCE=false 时权重为 1（裸加）。
	@param vDrive Vector3 - Drive 平面速
	@param vImpulse Vector3 - Impulse 合平面速
	@param driveTier number - 无活跃 Drive 为 0
	@param impulseTier number - 无 Impulse 为 0
	@param composeCap number? - 合成后平面速上限；nil 不钳
	@return Vector3 - 加权并钳制后的平面合速
]]
local function _composePlanarWeighted(
	vDrive: Vector3,
	vImpulse: Vector3,
	driveTier: number,
	impulseTier: number,
	composeCap: number?
): Vector3
	local wDrive = 1
	local wImp = 1
	if Constants.COMPOSE_SOFT_DOMINANCE == true then
		local maxTier = math.max(driveTier, impulseTier)
		if maxTier > 0 and driveTier > 0 and impulseTier > 0 then
			wDrive = driveTier / maxTier
			wImp = impulseTier / maxTier
		end
	end
	return _clampPlanar(vDrive * wDrive + vImpulse * wImp, composeCap)
end

--[[
	PreSimulation：Compose → 碰撞 → 意图路程 → 仅 XZ 写 LV（本模块唯一速度写口）
	@param motor Motor - 电机状态
	@param dt number - 自上一物理步以来的秒数
]]
local function _tick(motor: Motor, dt: number)
	if not motor.HRP.Parent or not motor.character.Parent then
		VelocityMotor.DestroyAll(motor.character)
		return
	end

	local now = os.clock()
	local vDrive = _composeDrive(motor, now)
	local vImpulse = _composeImpulse(motor, now)
	local driveTier = if _driveActive(motor) then (motor.drive.motionTier or Constants.MOTION_TIER_DRIVE) else 0
	local impulseTier = 0
	for _, entry in pairs(motor.impulses) do
		local t = entry.motionTier or Constants.MOTION_TIER_IMPULSE
		if t > impulseTier then
			impulseTier = t
		end
	end
	local vPlanar = _composePlanarWeighted(vDrive, vImpulse, driveTier, impulseTier, motor.composeCap)

	local policy = _resolvePolicy(motor)
	vPlanar = _applyCollision(motor, vPlanar, dt, policy)

	-- 意图路程：碰撞裁切后的合速 × dt（不吃外力位置跳变）
	local step = vPlanar.Magnitude * math.max(dt, 0)
	if motor.drive and not motor.drive.ended then
		motor.drive.traveled += step
		if motor.attach then
			motor.attach:SetAttribute(Constants.TRAVELED_ATTR, motor.drive.traveled)
		end
		local budget = motor.drive.maxDistance
		if
			motor.drive.enforceMaxDistance
			and type(budget) == "number"
			and budget > 0
			and motor.drive.traveled >= budget
		then
			_endDriveKeepMarker(motor, false)
			vDrive = Vector3.zero
			driveTier = 0
			vPlanar = _composePlanarWeighted(vDrive, vImpulse, driveTier, impulseTier, motor.composeCap)
		end
	end
	for id, entry in pairs(motor.impulses) do
		entry.traveled += step
		if type(entry.maxDistance) == "number" and entry.maxDistance > 0 and entry.traveled >= entry.maxDistance then
			motor.impulses[id] = nil
		end
	end
	motor.lastPos = motor.HRP.Position

	local lv = motor.lv
	local attach = motor.attach
	if not lv or not attach or not attach.Parent then
		_stopHeartbeat(motor)
		_maybeReleaseHumanoidSuppress(motor)
		return
	end

	local stillDrive = _driveActive(motor)
	local stillImp = _hasActiveImpulse(motor)
	if not stillDrive and not stillImp then
		lv.VectorVelocity = Vector3.zero
		lv.Enabled = false
		if attach then
			attach:SetAttribute(Constants.IMPULSE_ENDED_ATTR, true)
		end
		_stopHeartbeat(motor)
		_debugEnd(motor, "tickIdle")
		_maybeReleaseHumanoidSuppress(motor)
		return
	end

	lv.Enabled = true
	if stillDrive and attach:GetAttribute(Constants.IMPULSE_ENDED_ATTR) == true then
		attach:SetAttribute(Constants.IMPULSE_ENDED_ATTR, false)
	end
	-- 仅写 XZ；Y 由重力/跳跃物理，勿读 ALV.Y 回灌（会锁死竖直速）
	_writePlanarVelocity(lv, vPlanar)
	_debugSample(motor, vPlanar)
end

--[[
	绑定 PreSimulation：物理步进前写入目标速，减少地面摩擦/控制器滞后造成的短距
	@param motor Motor - 电机状态
]]
_ensureHeartbeat = function(motor: Motor)
	if motor.conn then
		return
	end
	-- PreSimulation：物理步进前写入目标速，减少地面摩擦/控制器滞后造成的短距
	motor.conn = RunService.PreSimulation:Connect(function(dt)
		local m = _motors[motor.character]
		if not m then
			return
		end
		_tick(m, dt)
	end)
end

--[[
	取得或创建角色电机状态（HRP 更换时重建）
	@param character Model - 角色
	@param HRP BasePart - HumanoidRootPart
	@return Motor - 电机状态
]]
local function _getOrCreateMotor(character: Model, HRP: BasePart): Motor
	local motor = _motors[character]
	if motor and motor.HRP == HRP then
		return motor
	end
	if motor then
		_popHumanoidSuppress(motor)
		_stopHeartbeat(motor)
	end
	motor = {
		character = character,
		HRP = HRP,
		attach = nil,
		lv = nil,
		drive = nil,
		impulses = {},
		lastPos = HRP.Position,
		rayParams = nil,
		conn = nil,
		composeCap = Constants.DEFAULT_COMPOSE_CAP,
		humanoidSuppressActive = false,
		platformStandPrev = nil,
		humanoid = nil,
	}
	_motors[character] = motor
	return motor
end

--[[
	确保 HRP 上有可用 Attach+LV 令牌（旧令牌纠回仅 XZ）
	@param motor Motor - 电机状态
	@param maxForce number? - 新建/纠回时的 MaxForce
	@return Attachment - 电机 Attachment
	@return LinearVelocity - 平面速度约束
]]
local function _ensureToken(motor: Motor, maxForce: number?): (Attachment, LinearVelocity)
	local HRP = motor.HRP
	local attach, lv = VelocityMotor.FindToken(HRP)
	if attach and lv then
		motor.attach = attach
		motor.lv = lv
		-- 热更/旧令牌：强制纠回「仅 XZ」，避免仍锁 Y
		attach.Orientation = Vector3.zero
		_configurePlanarLv(lv, maxForce or lv.MaxForce or Constants.DEFAULT_MAX_FORCE)
		return attach, lv
	end
	_destroyDriveTokensOnly(HRP)

	attach = Instance.new("Attachment")
	attach.Name = Constants.ATTACH_NAME
	-- World Vector + PerAxis：Orientation 不参与轴；置 0 避免历史 -90 误导 Plane 模式
	attach.Orientation = Vector3.zero
	attach.Parent = HRP

	local genAttr = Constants.PHYS_GEN_ATTR
	local gen = (HRP:GetAttribute(genAttr) or HRP:GetAttribute(Constants.LEGACY_PHYS_GEN_ATTR) or 0) + 1
	HRP:SetAttribute(genAttr, gen)
	attach:SetAttribute(genAttr, gen)
	attach:SetAttribute(Constants.IMPULSE_ENDED_ATTR, false)
	attach:SetAttribute(Constants.COLLISION_HIT_ATTR, false)

	lv = Instance.new("LinearVelocity")
	lv.Name = Constants.LV_NAME
	lv.Attachment0 = attach
	_configurePlanarLv(lv, maxForce or Constants.DEFAULT_MAX_FORCE)
	lv.Parent = attach
	lv.Enabled = true

	motor.attach = attach
	motor.lv = lv
	return attach, lv
end

--[[
	从 recipe + 方向构建 DriveState 曲线快照
	@param flatUnit Vector3 - 已归一化的水平方向
	@param recipe any - PlanarRecipe 字段表
	@param t0 number - 曲线起始 os.clock
	@param dur number - 曲线时长（秒）
	@param traveled number - 已消耗意图路程
	@param motionTier number - Drive 源仲裁 tier
	@return DriveState - Drive 曲线快照
]]
local function _buildDriveState(
	flatUnit: Vector3,
	recipe: any,
	t0: number,
	dur: number,
	traveled: number,
	motionTier: number
): DriveState
	local planeSpeed = recipe.planeSpeed or 0
	local endFactor = recipe.vectorEndFactor or 0
	local startPlanar = flatUnit * planeSpeed
	local goalPlanar = startPlanar * endFactor
	local easingStyle, easingDirection = _recipeEasing(recipe)
	local maxDist = recipe.maxDistance
	return {
		startPlanar = startPlanar,
		goalPlanar = goalPlanar,
		lastPlanar = startPlanar,
		dirUnit = flatUnit,
		planeSpeed = planeSpeed,
		vectorEndFactor = endFactor,
		easingStyle = easingStyle,
		easingDirection = easingDirection,
		speedKeys = _copySpeedKeys(recipe.speedKeys),
		t0 = t0,
		dur = math.max(1e-4, dur),
		maxDistance = if type(maxDist) == "number" then maxDist else nil,
		traveled = traveled,
		collisionPolicy = recipe.collisionPolicy or Constants.DEFAULT_COLLISION_POLICY,
		enforceMaxDistance = recipe.enforceMaxDistance == true,
		ended = false,
		motionTier = motionTier,
	}
end

-- ========================================
-- 公共函数
-- ========================================

--[[
	查找 HRP 上既有电机令牌（含旧 NewRoll 名）
	@param HRP BasePart - 角色 HumanoidRootPart
	@return Attachment? - 电机 Attachment；缺失为 nil
	@return LinearVelocity? - 平面速度约束；缺失为 nil
]]
function VelocityMotor.FindToken(HRP: BasePart): (Attachment?, LinearVelocity?)
	if not HRP then
		return nil, nil
	end
	local att = HRP:FindFirstChild(Constants.ATTACH_NAME)
	if not (att and att:IsA("Attachment")) then
		att = HRP:FindFirstChild(Constants.LEGACY_ATTACH_NAME)
	end
	if not (att and att:IsA("Attachment")) then
		att = nil
		for _, child in HRP:GetChildren() do
			if _isAttachToken(child) then
				att = child
				break
			end
		end
	end
	if not att then
		return nil, nil
	end
	local lv = _findLv(att :: Attachment)
	if lv then
		return att :: Attachment, lv
	end
	return nil, nil
end

--[[
	Drive 是否仍在驱动平面曲线
	@param attach Attachment - 电机 Attachment
	@param lv LinearVelocity - 平面速度约束
	@return boolean - Drive 曲线仍活跃为 true
]]
function VelocityMotor.IsDriveActive(attach: Attachment, lv: LinearVelocity): boolean
	if attach:GetAttribute(Constants.IMPULSE_ENDED_ATTR) == true then
		return false
	end
	if not lv.Enabled then
		return false
	end
	local character = attach.Parent and attach.Parent.Parent
	if character and character:IsA("Model") then
		local motor = _motors[character]
		if motor then
			return _driveActive(motor)
		end
	end
	return true
end

VelocityMotor.IsImpulseActive = VelocityMotor.IsDriveActive

--[[
	结束 Drive 但保留 Attach 令牌（soft-merge）；Impulse 层可继续
	@param attach Instance - 电机 Attachment（允许非 Attachment 以兼容旧调用）
]]
function VelocityMotor.EndDriveKeepMarker(attach: Instance)
	local hrp = attach.Parent
	local character = hrp and hrp.Parent
	if character and character:IsA("Model") then
		local motor = _motors[character]
		if motor then
			_endDriveKeepMarker(motor)
			return
		end
	end
	local lv = attach:FindFirstChild(Constants.LV_NAME) or attach:FindFirstChild(Constants.LEGACY_LV_NAME)
	if lv and lv:IsA("LinearVelocity") then
		lv.VectorVelocity = Vector3.zero
		lv.Enabled = false
	end
	attach:SetAttribute(Constants.IMPULSE_ENDED_ATTR, true)
end

VelocityMotor.EndImpulseKeepMarker = VelocityMotor.EndDriveKeepMarker

--[[
	销毁令牌并停电机（Drive + Impulse）
	@param characterOrHRP Model|BasePart - 角色或 HRP
]]
function VelocityMotor.DestroyAll(characterOrHRP: Instance)
	local character: Model? = nil
	local HRP: BasePart? = nil
	if characterOrHRP:IsA("Model") then
		character = characterOrHRP
		local h = character:FindFirstChild("HumanoidRootPart")
		if h and h:IsA("BasePart") then
			HRP = h
		end
	elseif characterOrHRP:IsA("BasePart") then
		HRP = characterOrHRP
		local p = HRP.Parent
		if p and p:IsA("Model") then
			character = p
		end
	end
	if character then
		local motor = _motors[character]
		if motor then
			_debugEnd(motor, "DestroyAll")
			_popHumanoidSuppress(motor)
			_stopHeartbeat(motor)
			table.clear(motor.impulses)
			motor.drive = nil
			motor.attach = nil
			motor.lv = nil
			_motors[character] = nil
		end
	end
	if HRP then
		_destroyDriveTokensOnly(HRP)
	end
end

--[[
	仅结束 Drive 曲线并拆令牌，保留 Impulse 表（异 session 替换用）
	@param character Model - 角色
]]
function VelocityMotor.EndDriveKeepImpulses(character: Model)
	local motor = character and _motors[character]
	if not motor then
		return
	end
	motor.drive = nil
	local HRP = motor.HRP
	if HRP then
		_destroyDriveTokensOnly(HRP)
	end
	motor.attach = nil
	motor.lv = nil
	if not _hasActiveImpulse(motor) then
		_stopHeartbeat(motor)
		_maybeReleaseHumanoidSuppress(motor)
	else
		_ensureToken(motor, Constants.DEFAULT_MAX_FORCE)
		_pushHumanoidSuppress(motor)
		_ensureHeartbeat(motor)
	end
end

--[[
	启动 Drive 曲线（不无条件清 Impulse；由调用方 clearImpulsesOnBegin）
	@param character Model - 角色
	@param HRP BasePart - HumanoidRootPart
	@param directionWorld Vector3 - 世界空间方向（电机会压平并归一化）
	@param recipe table - PlanarRecipe（须含 planeSpeed；tweenDuration 缺省 DEFAULT_TWEEN_DURATION）
	@param sessionId string? - 会话 id，写入 Attribute 供调试
	@param motionTier number? - 源仲裁 tier；缺省 MOTION_TIER_DRIVE
	@return Attachment? - 电机 Attachment；失败为 nil
	@return LinearVelocity? - 平面速度约束；失败为 nil
]]
function VelocityMotor.StartDrive(
	character: Model,
	HRP: BasePart,
	directionWorld: Vector3,
	recipe: any,
	sessionId: string?,
	motionTier: number?
): (Attachment?, LinearVelocity?)
	if not character or not HRP or not directionWorld then
		return nil, nil
	end
	local flat = Vector3.new(directionWorld.X, 0, directionWorld.Z)
	if flat.Magnitude < Constants.PLANAR_EPS then
		return nil, nil
	end
	flat = flat.Unit

	local motor = _getOrCreateMotor(character, HRP)
	_stopHeartbeat(motor)
	_destroyDriveTokensOnly(HRP)
	motor.attach = nil
	motor.lv = nil

	local maxForce = recipe.maxForce or Constants.DEFAULT_MAX_FORCE
	local attach, lv = _ensureToken(motor, maxForce)
	attach:SetAttribute(Constants.DASH_START_CLOCK_ATTR, os.clock())
	attach:SetAttribute(Constants.IMPULSE_ENDED_ATTR, false)
	attach:SetAttribute(Constants.COLLISION_HIT_ATTR, false)
	if type(sessionId) == "string" then
		attach:SetAttribute(Constants.SESSION_ID_ATTR, sessionId)
	end

	local tweenDur = math.max(Constants.PLANAR_EPS, recipe.tweenDuration or Constants.DEFAULT_TWEEN_DURATION)
	local tier = if type(motionTier) == "number" then motionTier else Constants.MOTION_TIER_DRIVE
	local maxDist = recipe.maxDistance
	if type(maxDist) == "number" and maxDist > 0 then
		attach:SetAttribute(Constants.TRAVEL_BUDGET_ATTR, maxDist)
		attach:SetAttribute(Constants.TRAVELED_ATTR, 0)
	end

	motor.drive = _buildDriveState(flat, recipe, os.clock(), tweenDur, 0, tier)
	if type(recipe.composeCap) == "number" and recipe.composeCap > 0 then
		motor.composeCap = recipe.composeCap
	elseif type(Constants.DEFAULT_COMPOSE_CAP) == "number" then
		motor.composeCap = Constants.DEFAULT_COMPOSE_CAP
	end

	motor.lastPos = HRP.Position
	local startPlanar = motor.drive.startPlanar
	if motor.drive.speedKeys then
		startPlanar = select(1, _evalDrivePlanar(motor.drive, motor.drive.t0))
		motor.drive.lastPlanar = startPlanar
	end
	lv.Enabled = true
	_writePlanarVelocity(lv, startPlanar)
	_pushHumanoidSuppress(motor)
	_debugBegin(motor, "StartDrive")
	_ensureHeartbeat(motor)
	return attach, lv
end

--[[
	收养既有 Drive 令牌：按原包络续算（不把 goal 强制收 0）
	@param character Model - 角色
	@param attach Attachment - 既有电机 Attachment
	@param lv LinearVelocity - 既有平面速度约束
	@param tweenDur number - 曲线总时长（秒）
	@param elapsedSec number - 调用方估计的已推进秒数；有 MotionStartClock 时以时钟为准
	@param recipe any? - PlanarRecipe 覆盖；缺省空表
	@param motionTier number? - 源仲裁 tier；缺省 MOTION_TIER_DRIVE
	@return boolean - Drive 是否仍活跃
]]
function VelocityMotor.AdoptDrive(
	character: Model,
	attach: Attachment,
	lv: LinearVelocity,
	tweenDur: number,
	elapsedSec: number,
	recipe: any?,
	motionTier: number?
): boolean
	local HRP = attach.Parent
	if not (HRP and HRP:IsA("BasePart")) then
		return false
	end
	local motor = _getOrCreateMotor(character, HRP)
	motor.attach = attach
	motor.lv = lv

	local startClock = attach:GetAttribute(Constants.DASH_START_CLOCK_ATTR)
	local elapsed = math.max(0, elapsedSec)
	if type(startClock) == "number" then
		elapsed = math.max(0, os.clock() - startClock)
	end
	local remain = math.max(0, tweenDur - elapsed)

	if attach:GetAttribute(Constants.IMPULSE_ENDED_ATTR) == true or not lv.Enabled or remain <= 1e-3 then
		VelocityMotor.EndDriveKeepMarker(attach)
		return false
	end

	if motor.drive and not motor.drive.ended and motor.conn then
		_pushHumanoidSuppress(motor)
		return true
	end

	local recipeSafe = recipe or {}
	local cur = lv.VectorVelocity
	local flat = Vector3.new(cur.X, 0, cur.Z)
	if flat.Magnitude < Constants.PLANAR_EPS then
		flat = Vector3.new(0, 0, -1)
	else
		flat = flat.Unit
	end

	local traveled = 0
	local traveledAttr = attach:GetAttribute(Constants.TRAVELED_ATTR)
	if type(traveledAttr) == "number" then
		traveled = traveledAttr
	elseif type(recipeSafe.maxDistance) == "number" and tweenDur > 1e-4 then
		traveled = recipeSafe.maxDistance * math.clamp(elapsed / tweenDur, 0, 1)
	end

	local tier = if type(motionTier) == "number" then motionTier else Constants.MOTION_TIER_DRIVE
	local t0 = if type(startClock) == "number" then startClock else (os.clock() - elapsed)
	motor.drive = _buildDriveState(flat, recipeSafe, t0, tweenDur, traveled, tier)
	-- 对齐当前帧速度到包络采样，避免收养瞬间跳速
	local planarNow = select(1, _evalDrivePlanar(motor.drive, os.clock()))
	motor.drive.lastPlanar = planarNow
	_configurePlanarLv(lv, lv.MaxForce or Constants.DEFAULT_MAX_FORCE)
	_writePlanarVelocity(lv, planarNow)

	motor.lastPos = HRP.Position
	attach:SetAttribute(Constants.IMPULSE_ENDED_ATTR, false)
	lv.Enabled = true
	_pushHumanoidSuppress(motor)
	_debugBegin(motor, "AdoptDrive")
	_ensureHeartbeat(motor)
	return true
end

--[[
	安排 Drive 到期（保留令牌）；电机 tick 亦会按 alpha 结束，此为兜底
	@param attach Instance - 电机 Attachment
	@param remainSec number - 剩余秒数；负值按 0
	@param cancelToken any - { cancelled: boolean, gen: number }；取消或代次变化则不执行
	@param expectedGen number - 调度时的 cancelToken.gen
]]
function VelocityMotor.ScheduleDriveEnd(attach: Instance, remainSec: number, cancelToken: any, expectedGen: number)
	task.delay(math.max(0, remainSec), function()
		if cancelToken and (cancelToken.cancelled or cancelToken.gen ~= expectedGen) then
			return
		end
		if not attach.Parent then
			return
		end
		VelocityMotor.EndDriveKeepMarker(attach)
	end)
end

VelocityMotor.ScheduleEnd = VelocityMotor.ScheduleDriveEnd

--[[
	叠加 Impulse 写入
	@param character Model - 角色（仅客户端写入）
	@param opts table - ImpulseOpts：须含 id；另须 planarVelocity 或 direction+speed，或 followMoveDirection+peakSpeed
	@return boolean - 是否写入成功
]]
function VelocityMotor.AddImpulse(character: Model, opts: any): boolean
	if not RunService:IsClient() then
		return false
	end
	if not character or type(opts) ~= "table" or type(opts.id) ~= "string" then
		return false
	end
	local HRP = character:FindFirstChild("HumanoidRootPart")
	if not (HRP and HRP:IsA("BasePart")) then
		return false
	end

	local massScale = if type(opts.massScale) == "number" then opts.massScale else 1
	local follow = opts.followMoveDirection == true
	local peak = if type(opts.peakSpeed) == "number" then opts.peakSpeed else 0
	local base = Vector3.zero
	local lastFollow: Vector3? = nil
	if not follow then
		if typeof(opts.planarVelocity) == "Vector3" then
			base = Vector3.new(opts.planarVelocity.X, 0, opts.planarVelocity.Z) * massScale
		elseif typeof(opts.direction) == "Vector3" and type(opts.speed) == "number" then
			local d = Vector3.new(opts.direction.X, 0, opts.direction.Z)
			if d.Magnitude > Constants.PLANAR_EPS then
				base = d.Unit * (opts.speed * massScale)
			end
		else
			return false
		end
	elseif peak <= 0 then
		return false
	else
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		local md = if humanoid then humanoid.MoveDirection else Vector3.zero
		local flat = Vector3.new(md.X, 0, md.Z)
		if flat.Magnitude > 1e-3 then
			lastFollow = flat.Unit
		end
	end

	local motor = _getOrCreateMotor(character, HRP)
	_ensureToken(motor, Constants.DEFAULT_MAX_FORCE)
	local duration = opts.durationSec or Constants.DEFAULT_IMPULSE_DURATION
	if type(duration) ~= "number" or duration <= 0 then
		return false
	end

	if type(opts.composeCap) == "number" and opts.composeCap > 0 then
		motor.composeCap = opts.composeCap
	end

	local tier = if type(opts.motionTier) == "number" then opts.motionTier else Constants.MOTION_TIER_IMPULSE
	motor.impulses[opts.id] = {
		id = opts.id,
		basePlanar = base,
		t0 = os.clock(),
		duration = duration,
		decay = opts.decay or Constants.DEFAULT_IMPULSE_DECAY,
		maxSpeed = opts.maxSpeed,
		maxDistance = opts.maxDistance,
		traveled = 0,
		collisionPolicy = opts.collisionPolicy or Constants.DEFAULT_IMPULSE_COLLISION,
		followMoveDirection = follow,
		blendToWalk = opts.blendToWalk == true,
		walkSpeedFloor = if type(opts.walkSpeedFloor) == "number" then opts.walkSpeedFloor else nil,
		peakSpeed = peak,
		massScale = massScale,
		motionTier = tier,
		lastFollowDir = lastFollow,
	}
	if motor.attach then
		motor.attach:SetAttribute(Constants.IMPULSE_ENDED_ATTR, false)
	end
	if motor.lv then
		motor.lv.Enabled = true
	end
	motor.lastPos = HRP.Position
	_pushHumanoidSuppress(motor)
	_ensureHeartbeat(motor)
	return true
end

--[[
	清除 Impulse（全部或按 id）
	@param character Model - 角色
	@param id string? - 指定冲量 id；nil 表示按 preserveId 或全清
	@param preserveId string? - 全清时保留的 Impulse id（如 DriveEndBlend）
]]
function VelocityMotor.ClearImpulses(character: Model, id: string?, preserveId: string?)
	local motor = character and _motors[character]
	if not motor then
		return
	end
	if type(id) == "string" then
		motor.impulses[id] = nil
	elseif type(preserveId) == "string" and preserveId ~= "" then
		local keep = motor.impulses[preserveId]
		table.clear(motor.impulses)
		if keep then
			motor.impulses[preserveId] = keep
		end
	else
		table.clear(motor.impulses)
	end
	if not _driveActive(motor) and not _hasActiveImpulse(motor) then
		if motor.lv then
			motor.lv.VectorVelocity = Vector3.zero
			motor.lv.Enabled = false
		end
		if motor.attach then
			motor.attach:SetAttribute(Constants.IMPULSE_ENDED_ATTR, true)
		end
		_stopHeartbeat(motor)
		_debugEnd(motor, "ClearImpulsesIdle")
		_maybeReleaseHumanoidSuppress(motor)
	end
end

--[[
	查询电机是否有活跃写入
	@param character Model - 角色
	@return boolean - Drive 或 Impulse 仍活跃
]]
function VelocityMotor.HasActive(character: Model): boolean
	local motor = character and _motors[character]
	if not motor then
		return false
	end
	return _driveActive(motor) or _hasActiveImpulse(motor)
end

--[[
	设置合成平面速上限
	@param character Model - 角色
	@param cap number? - stud/s；nil 或 <=0 表示不钳
]]
function VelocityMotor.SetComposeCap(character: Model, cap: number?)
	local motor = character and _motors[character]
	if not motor then
		return
	end
	if type(cap) == "number" and cap > 0 then
		motor.composeCap = cap
	else
		motor.composeCap = nil
	end
end

--[[
	Drive 剩余秒数
	@param character Model - 角色
	@return number? - 剩余时长；无活跃 Drive 为 nil
]]
function VelocityMotor.GetDriveRemaining(character: Model): number?
	local motor = character and _motors[character]
	if not motor or not motor.drive or motor.drive.ended then
		return nil
	end
	local remain = motor.drive.dur - (os.clock() - motor.drive.t0)
	if remain <= 0 then
		return nil
	end
	return remain
end

--[[
	当前 Drive 平面残速（lastPlanar）；无活跃 Drive 为 nil
	@param character Model - 角色
	@return Vector3? - 当前 Drive lastPlanar（Y=0）；无活跃 Drive 为 nil
]]
function VelocityMotor.GetDriveLastPlanar(character: Model): Vector3?
	local motor = character and _motors[character]
	if not motor or not motor.drive or motor.drive.ended then
		return nil
	end
	local last = motor.drive.lastPlanar
	if not last then
		return nil
	end
	return Vector3.new(last.X, 0, last.Z)
end

--[[
	当前 Drive motionTier
	@param character Model - 角色
	@return number? - 无活跃 Drive 为 nil
]]
function VelocityMotor.GetDriveTier(character: Model): number?
	local motor = character and _motors[character]
	if not motor or not motor.drive or motor.drive.ended then
		return nil
	end
	return motor.drive.motionTier
end

--[[
	活跃 Impulse 中最高 motionTier
	@param character Model - 角色
	@return number? - 无 Impulse 为 nil
]]
function VelocityMotor.GetMaxImpulseTier(character: Model): number?
	local motor = character and _motors[character]
	if not motor then
		return nil
	end
	local best: number? = nil
	for _, entry in pairs(motor.impulses) do
		local t = entry.motionTier or Constants.MOTION_TIER_IMPULSE
		if best == nil or t > best then
			best = t
		end
	end
	return best
end

--[[
	是否存在 Impulse（全部或指定 id）
	@param character Model - 角色
	@param id string? - 冲量 id；nil 表示任意活跃 Impulse
	@return boolean - 存在指定 id（或任意）Impulse 为 true
]]
function VelocityMotor.HasImpulse(character: Model, id: string?): boolean
	local motor = character and _motors[character]
	if not motor then
		return false
	end
	if type(id) == "string" then
		return motor.impulses[id] ~= nil
	end
	return _hasActiveImpulse(motor)
end

--[[
	活跃 Impulse 条目数
	@param character Model - 角色
	@return number - 活跃 Impulse 条目数
]]
function VelocityMotor.CountImpulses(character: Model): number
	local motor = character and _motors[character]
	if not motor then
		return 0
	end
	local n = 0
	for _ in pairs(motor.impulses) do
		n += 1
	end
	return n
end

return VelocityMotor