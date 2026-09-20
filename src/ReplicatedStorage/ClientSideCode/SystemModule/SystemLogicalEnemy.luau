--[[
	Module: SystemLogicalEnemy
	Description: 客户端逻辑怪表现（LocalMonster 克隆 + 时间轴插值/短外推跟随 + 位移动作；CanQuery=false；CollisionGroup=Enemy）
	Author: 林奥宇
	Created: 2026-08-12
	Last Modified: 2026-09-01

	功能：
	- Init：确保 workspace.LocalMonster（GameConfig「怪物系统.启用」= false 时 no-op）
	- OnSpawn：克隆 ModelRes/Enemy；仅 HRP 锚固；全 Part CollisionGroup=Enemy；按 enemyConf 播 idle；写入首包快照与 Humanoid HP
	- OnTransform：推进 prev/latest 快照（服务端 t）；按 moveState 切 idle/walk/run；受击位移期间忽略
	- OnState：同步 hp/maxHp/CombatReady 到 LocalMonster.Humanoid（引擎通用血条）
	- OnDisplace：受击位移轨迹（与权威同 start/end/duration）；期间优先于 Transform 跟随
	- 跟随：渲染时刻 = GetServerTimeNow() - interpDelay；双快照插值，超出 latest 后短外推，超时指数追赶
	- OnDeath：播死亡动作后 Destroy
	- 不承载伤害权威（权威 Hit 仍服 OBB；CanQuery 保持 false）

	跟随策略（对齐服 20Hz TRANSFORM / RP18 Hot）：
	- interpDelay ≈ 包间隔×0.9，夹到 [0.05, 0.09]（约 1–2 包；过厚缓冲追击会「肉+顿」）
	- 仅一包时钉 latest，不做外推
	- 时间轴位置硬写入；朝向角速度限幅；大误差才 snap/追赶
	- 每帧只写根部件 CFrame（勿 PivotTo，以免冲掉 Motor6D 动作）
	- Follow / Displace / Spawn 留在本文件：同一 RenderStepped 热路径，拆目录不改写口

	加载：
		local SystemLogicalEnemy = Utils.SystemLogicalEnemy
		SystemLogicalEnemy.Init()
]]

local Workspace = game:GetService("Workspace")

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local ResourceUtil = Utils.ResourceUtil
local CfgFind = Utils.CfgFind
local Log = Utils.Log
local EnemyLogicalTypes = Utils.EnemyLogicalTypes
local AnimationModule = Utils.AnimationModule
local TweenService = Utils.TweenService
local SystemGameConfig = Utils.SystemGameConfig
local RunService = Utils.RunService

local SystemLogicalEnemy = {}

--============================================================================--
-- 常量
--============================================================================--

-- 与 Hitbox TARGET_GROUPS / RP18 LocalMonster 准备一致；不改变 CanQuery=false 权威禁令
local COLLISION_GROUP_ENEMY = "Enemy"

-- 插值 / 外推（对齐 RP18：20Hz + 短缓冲）
local INTERP_DELAY_DEFAULT = 0.09
local INTERP_DELAY_MIN = 0.05
local INTERP_DELAY_MAX = 0.09
local INTERP_DELAY_SPAN_MUL = 0.9
local VEL_LOWPASS = 0.35
local CATCHUP_SPEED = 18
local HARD_CATCHUP_SPEED = 30
local SNAP_DIST = 10
local HARD_CATCHUP_DIST = 6
local MAX_YAW_RATE = 10
local MIN_DIR_EPSILON = 1e-4
local SETTLED_POS_EPS = 0.02
local SETTLED_VEL_EPS = 0.02
local SETTLED_LOOK_DOT = 0.999

local LOCO_FADE = 0.15
local DEATH_FADE = 0.05
local DEATH_FALLBACK_SEC = 1.2

type AnimNames = {
	idle: string?,
	walk: string?,
	run: string?,
	hit: string?,
	die: string?,
	stun: string?,
}

type Snapshot = {
	cf: CFrame,
	t: number,
}

type DisplaceState = {
	gen: number,
	startPos: Vector3,
	endPos: Vector3,
	look: Vector3,
	t0: number,
	duration: number,
	easingStyle: Enum.EasingStyle,
	easingDirection: Enum.EasingDirection,
}

type LocalEntry = {
	id: number,
	model: Model,
	root: BasePart?,
	prev: Snapshot?,
	latest: Snapshot?,
	vel: Vector3,
	displayLook: Vector3?,
	interpDelay: number,
	extrapMax: number,
	animNames: AnimNames,
	locoKind: string?,
	dying: boolean?,
	displace: DisplaceState?,
	displaceGen: number?,
}

local byId: { [number]: LocalEntry } = {}
local _renderConn: RBXScriptConnection? = nil
local _inited = false

--============================================================================--
-- 私有：克隆 / 几何
--============================================================================--

--[[
	确保 LocalMonster Folder
	@return Folder - workspace 下表现父级（已存在则复用）
]]
local function _getFolder(): Folder
	local name = EnemyLogicalTypes.LOCAL_MONSTER_FOLDER_NAME
	local folder = Workspace:FindFirstChild(name)
	if folder and folder:IsA("Folder") then
		return folder
	end
	local created = Instance.new("Folder")
	created.Name = name
	created.Parent = Workspace
	return created
end

--[[
	取表现根部件
	@param model Model - 本地表现模
	@return BasePart? - PrimaryPart 或 HumanoidRootPart
]]
local function _getRoot(model: Model): BasePart?
	local root = model.PrimaryPart
	if not root then
		local hrp = model:FindFirstChild("HumanoidRootPart")
		if hrp and hrp:IsA("BasePart") then
			root = hrp
		end
	end
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

--[[
	缓存/刷新条目根部件
	@param entry LocalEntry - 本地条目
	@return BasePart? - 仍挂在树上的根部件
]]
local function _ensureRoot(entry: LocalEntry): BasePart?
	local root = entry.root
	if root and root.Parent then
		return root
	end
	root = _getRoot(entry.model)
	entry.root = root
	return root
end

--[[
	水平单位 Look；过短回退 -Z
	@param v Vector3 - 原始朝向
	@return Vector3 - 平面单位向量
]]
local function _horizontalUnit(v: Vector3): Vector3
	local flat = Vector3.new(v.X, 0, v.Z)
	if flat.Magnitude < MIN_DIR_EPSILON then
		return Vector3.new(0, 0, -1)
	end
	return flat.Unit
end

--[[
	水平距离（忽略 Y）
	@param a Vector3 - 点 A
	@param b Vector3 - 点 B
	@return number - 平面距
]]
local function _flatDist(a: Vector3, b: Vector3): number
	local dx = a.X - b.X
	local dz = a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

--[[
	payload → CFrame
	@param payload any - 含 posX/Y/Z、lookX/Y/Z（缺省 lookZ=-1）
	@return CFrame - 重建位姿
]]
local function _payloadCFrame(payload: any): CFrame
	return EnemyLogicalTypes.unpackCFrame(
		tonumber(payload.posX) or 0,
		tonumber(payload.posY) or 0,
		tonumber(payload.posZ) or 0,
		tonumber(payload.lookX) or 0,
		tonumber(payload.lookY) or 0,
		tonumber(payload.lookZ) or -1
	)
end

--[[
	取载荷服务端时间戳；缺省用接收时刻
	@param payload any - 可含 t（服务端秒）
	@return number - 服务端时间
]]
local function _payloadServerTime(payload: any): number
	local t = tonumber(payload.t)
	if t then
		return t
	end
	return Workspace:GetServerTimeNow()
end

--[[
	从配表解析动作名
	@param cfg table? - enemyConf 行；读 animIdleName / animWalkName / animRunName / animHitName / animDieName / animStunName
	@return AnimNames - 各态动作名（缺则 nil）
]]
local function _resolveAnimNames(cfg: any?): AnimNames
	local function pick(key: string): string?
		if type(cfg) ~= "table" then
			return nil
		end
		local v = cfg[key]
		if type(v) == "string" and v ~= "" then
			return v
		end
		return nil
	end
	return {
		idle = pick("animIdleName"),
		walk = pick("animWalkName"),
		run = pick("animRunName"),
		hit = pick("animHitName"),
		die = pick("animDieName"),
		stun = pick("animStunName"),
	}
end

--[[
	确保 Humanoid/AnimationController 下有 Animator
	@param model Model - 本地表现模
	@return Animator? - 已有或新建的 Animator
]]
local function _ensureAnimator(model: Model): Animator?
	local host: Instance? = model:FindFirstChildOfClass("Humanoid")
	if not host then
		host = model:FindFirstChildOfClass("AnimationController")
		if not host then
			local ac = Instance.new("AnimationController")
			ac.Parent = model
			host = ac
		end
	end
	if not host then
		return nil
	end
	local animator = host:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = host
	end
	return animator
end

--[[
	将已加载轨设为循环（位移轨）
	@param model Model - 本地表现模
	@param animationName string - Animation 表名
]]
local function _setTrackLooped(model: Model, animationName: string)
	local animator = _ensureAnimator(model)
	if not animator then
		return
	end
	local track = AnimationModule.GetCachedTrack(animator, animationName)
	if track then
		track.Looped = true
	end
end

--[[
	切换位移动作（idle/walk/run；air_* 等扩展态 A3 前回退 idle）
	@param entry LocalEntry - 本地条目
	@param kind string - "idle" | "walk" | "run" | "air_launch" | "air_float" | "air_fall" | …
]]
local function _setLocomotion(entry: LocalEntry, kind: string)
	if entry.dying then
		return
	end
	if kind ~= "idle" and kind ~= "walk" and kind ~= "run" then
		kind = "idle"
	end
	if entry.locoKind == kind then
		return
	end

	local names = entry.animNames
	local nextName = names[kind]
	-- 无对应轨时 walk/run 回退 idle
	if (not nextName or nextName == "") and kind ~= "idle" then
		kind = "idle"
		nextName = names.idle
	end
	if not nextName or nextName == "" then
		return
	end

	local prevKind = entry.locoKind
	if prevKind and names[prevKind] and names[prevKind] ~= nextName then
		AnimationModule.StopAnimByModel(entry.model, names[prevKind] :: string, LOCO_FADE)
	end

	AnimationModule.PlayAnimByModel(
		entry.model,
		nextName,
		1,
		nil,
		nil,
		Enum.AnimationPriority.Movement,
		LOCO_FADE
	)
	_setTrackLooped(entry.model, nextName)
	entry.locoKind = kind
end

--[[
	推入权威快照：乱序丢弃；更新速度低通与动态缓冲
	@param entry LocalEntry - 本地条目
	@param cf CFrame - 本包权威位姿
	@param serverT number - 服务端时间戳
]]
local function _pushSnapshot(entry: LocalEntry, cf: CFrame, serverT: number)
	local latest = entry.latest
	if latest then
		if serverT <= latest.t + 1e-4 then
			return
		end
		entry.prev = latest
		local dt = serverT - latest.t
		if dt > 1e-4 then
			local sampleVel = (cf.Position - latest.cf.Position) / dt
			if entry.vel.Magnitude < SETTLED_VEL_EPS then
				entry.vel = sampleVel
			else
				entry.vel = entry.vel:Lerp(sampleVel, VEL_LOWPASS)
			end
			entry.interpDelay = math.clamp(dt * INTERP_DELAY_SPAN_MUL, INTERP_DELAY_MIN, INTERP_DELAY_MAX)
			entry.extrapMax = entry.interpDelay * 2
		end
	end
	entry.latest = {
		cf = cf,
		t = serverT,
	}
end

--[[
	按缓冲/外推解析本帧期望位姿（位置与朝向分离）
	@param entry LocalEntry - 本地条目
	@param renderT number - 已减 delay 的服务端时间
	@return CFrame? - 期望位姿
	@return boolean - 是否外推超时追赶（需指数靠近）
]]
local function _resolveDesiredCf(entry: LocalEntry, renderT: number): (CFrame?, boolean)
	local latest = entry.latest
	if not latest then
		return nil, false
	end

	local prev = entry.prev
	if prev and renderT <= latest.t then
		local span = latest.t - prev.t
		if span <= 1e-4 then
			return latest.cf, false
		end
		local alpha = math.clamp((renderT - prev.t) / span, 0, 1)
		local pos = prev.cf.Position:Lerp(latest.cf.Position, alpha)
		local look0 = _horizontalUnit(prev.cf.LookVector)
		local look1 = _horizontalUnit(latest.cf.LookVector)
		local look = _horizontalUnit(look0:Lerp(look1, alpha))
		return CFrame.lookAt(pos, pos + look), false
	end

	-- 仅一包：钉 latest，不做外推
	if not prev then
		return latest.cf, false
	end

	local ahead = renderT - latest.t
	if ahead <= 0 then
		return latest.cf, false
	end
	local extrapMax = entry.extrapMax
	if extrapMax <= 1e-4 then
		extrapMax = INTERP_DELAY_DEFAULT * 2
	end
	if ahead <= extrapMax then
		local damp = 1 - ahead / extrapMax
		local pos = latest.cf.Position + entry.vel * ahead * damp
		local look = _horizontalUnit(latest.cf.LookVector)
		return CFrame.lookAt(pos, pos + look), false
	end

	return latest.cf, true
end

--[[
	朝向角速度限幅（平滑拧身）
	@param entry LocalEntry - 本地条目（读写 displayLook）
	@param targetLook Vector3 - 目标朝向
	@param dt number - 帧间隔秒
	@param bypass boolean - true 时本帧贴齐
	@return Vector3 - 本帧展示朝向
]]
local function _smoothLook(entry: LocalEntry, targetLook: Vector3, dt: number, bypass: boolean): Vector3
	local target = _horizontalUnit(targetLook)
	if bypass or dt <= 0 then
		entry.displayLook = target
		return target
	end
	local current = entry.displayLook
	if not current then
		entry.displayLook = target
		return target
	end
	current = _horizontalUnit(current)
	local dot = math.clamp(current:Dot(target), -1, 1)
	local angle = math.acos(dot)
	if angle < 1e-4 then
		entry.displayLook = target
		return target
	end
	-- 大角本帧贴齐，避免背对开怪慢拧
	if angle >= math.rad(120) then
		entry.displayLook = target
		return target
	end
	local alpha = math.clamp((MAX_YAW_RATE * dt) / angle, 0, 1)
	local mixed = _horizontalUnit(current:Lerp(target, alpha))
	entry.displayLook = mixed
	return mixed
end

--[[
	期望是否已对齐（可跳过重复写）
	@param entry LocalEntry - 本地条目
	@param root BasePart - 表现根
	@param desired CFrame - 期望位姿
	@return boolean - true 表示位置/朝向已贴齐
]]
local function _isSettled(entry: LocalEntry, root: BasePart, desired: CFrame): boolean
	if entry.vel.Magnitude >= SETTLED_VEL_EPS then
		return false
	end
	if _flatDist(root.Position, desired.Position) >= SETTLED_POS_EPS then
		return false
	end
	local lookDot = root.CFrame.LookVector:Dot(desired.LookVector)
	return lookDot >= SETTLED_LOOK_DOT
end

--[[
	将期望位姿写入根部件（时间轴位置硬写 + 朝向平滑；大误差才纠偏）
	@param entry LocalEntry - 本地条目
	@param root BasePart - 表现根
	@param desired CFrame - 期望位姿
	@param needCatchup boolean - true 时指数靠近而非硬写
	@param dt number - 帧间隔秒
]]
local function _applyDesired(entry: LocalEntry, root: BasePart, desired: CFrame, needCatchup: boolean, dt: number)
	local dist = _flatDist(root.Position, desired.Position)
	if dist >= SNAP_DIST then
		root.CFrame = desired
		entry.displayLook = _horizontalUnit(desired.LookVector)
		return
	end
	if dist >= HARD_CATCHUP_DIST then
		local alpha = math.clamp(dt * HARD_CATCHUP_SPEED, 0, 1)
		local pos = root.Position:Lerp(desired.Position, alpha)
		local look = _smoothLook(entry, desired.LookVector, dt, true)
		root.CFrame = CFrame.lookAt(pos, pos + look)
		return
	end
	if needCatchup then
		local alpha = math.clamp(dt * CATCHUP_SPEED, 0, 1)
		local pos = root.Position:Lerp(desired.Position, alpha)
		local look = _smoothLook(entry, desired.LookVector, dt, false)
		root.CFrame = CFrame.lookAt(pos, pos + look)
		return
	end
	local look = _smoothLook(entry, desired.LookVector, dt, false)
	local pos = desired.Position
	root.CFrame = CFrame.lookAt(pos, pos + look)
end

--[[
	无怪时断开 RenderStepped
]]
local function _unbindRenderIfEmpty()
	if next(byId) ~= nil then
		return
	end
	if _renderConn then
		_renderConn:Disconnect()
		_renderConn = nil
	end
end

--[[
	解析 EasingStyle
	@param name string? - 枚举名；非法则 Quad
	@return Enum.EasingStyle - 缓动曲线
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
	return Enum.EasingStyle.Quad
end

--[[
	解析 EasingDirection
	@param name string? - 枚举名；非法则 Out
	@return Enum.EasingDirection - 缓动方向
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
	return Enum.EasingDirection.Out
end

--[[
	结束位移轨迹：终态写入 snapshot，恢复普通跟随
	@param entry LocalEntry - 本地条目
	@param gen number - 本条轨迹代数；不匹配则忽略
]]
local function _finishDisplace(entry: LocalEntry, gen: number)
	local d = entry.displace
	if not d or d.gen ~= gen then
		return
	end
	entry.displace = nil
	local root = _ensureRoot(entry)
	local endPos = d.endPos
	local look = _horizontalUnit(d.look)
	local cf = CFrame.lookAt(endPos, endPos + look)
	if root then
		root.CFrame = cf
	end
	entry.displayLook = look
	local now = Workspace:GetServerTimeNow()
	local delay = entry.interpDelay
	if delay <= 0 then
		delay = INTERP_DELAY_DEFAULT
	end
	entry.prev = { cf = cf, t = now - delay }
	entry.latest = { cf = cf, t = now }
	entry.vel = Vector3.zero
end

--[[
	按位移状态写根 CFrame；结束则收尾
	@param entry LocalEntry - 本地条目
	@param nowServer number - 当前服务端时间
	@return boolean - true 表示本帧已由位移驱动
]]
local function _applyDisplace(entry: LocalEntry, nowServer: number): boolean
	local d = entry.displace
	if not d then
		return false
	end
	local root = _ensureRoot(entry)
	if not root then
		return true
	end
	local duration = d.duration
	if duration <= 0 then
		_finishDisplace(entry, d.gen)
		return false
	end
	local alpha = math.clamp((nowServer - d.t0) / duration, 0, 1)
	local eased = TweenService:GetValue(alpha, d.easingStyle, d.easingDirection)
	local pos = d.startPos:Lerp(d.endPos, eased)
	local look = _horizontalUnit(d.look)
	entry.displayLook = look
	root.CFrame = CFrame.lookAt(pos, pos + look)
	if alpha >= 1 then
		_finishDisplace(entry, d.gen)
	end
	return true
end

--============================================================================--
-- 私有：渲染跟随
--============================================================================--

--[[
	绑定 RenderStepped（幂等）：受击位移优先；否则时间轴插值 / 短外推 / 纠偏
]]
local function _bindRender()
	if _renderConn then
		return
	end
	_renderConn = RunService.RenderStepped:Connect(function(dt: number)
		local nowServer = Workspace:GetServerTimeNow()
		for _, entry in pairs(byId) do
			local model = entry.model
			if not model or not model.Parent or entry.dying then
				continue
			end

			if _applyDisplace(entry, nowServer) then
				continue
			end

			local root = _ensureRoot(entry)
			if not root then
				continue
			end

			local delay = entry.interpDelay
			if delay <= 0 then
				delay = INTERP_DELAY_DEFAULT
			end
			local renderT = nowServer - delay
			local desired, needCatchup = _resolveDesiredCf(entry, renderT)
			if not desired then
				continue
			end

			local flatErr = _flatDist(root.Position, desired.Position)
			local forceFull = needCatchup or flatErr >= HARD_CATCHUP_DIST
			if not forceFull and _isSettled(entry, root, desired) then
				continue
			end

			_applyDesired(entry, root, desired, needCatchup, dt)
		end
	end)
end

--[[
	销毁本地条目
	@param id number - 运行时 id
]]
local function _destroyEntry(id: number)
	local entry = byId[id]
	if not entry then
		return
	end
	byId[id] = nil
	if entry.model then
		entry.model:Destroy()
	end
	_unbindRenderIfEmpty()
end

--[[
	应用纯表现物理（禁权威 Query）
	仅锚固 HRP/PrimaryPart；其余部件 Unanchored，靠 Weld/Motor6D 跟随。
	全 BasePart 写入 CollisionGroup=Enemy（对照 RP18 _prepareLogicalCloneModel）。
	@param model Model - 本地表现模
]]
local function _applyPresentationPhysics(model: Model)
	local root = _getRoot(model)
	if root and not model.PrimaryPart then
		model.PrimaryPart = root
	end

	for _, desc in model:GetDescendants() do
		if desc:IsA("BasePart") then
			local isRoot = root ~= nil and desc == root
			desc.Anchored = isRoot
			desc.CanCollide = false
			desc.CanQuery = false
			desc.CanTouch = false
			desc.Massless = true
			desc.CollisionGroup = COLLISION_GROUP_ENEMY
		end
	end

	local hum = model:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.WalkSpeed = 0
		hum.JumpPower = 0
		hum.AutoRotate = false
		hum.BreakJointsOnDeath = false
		-- 引擎通用血条（非自定义 Billboard）；AlwaysOn 便于开战前可见
		hum.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOn
		hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.Viewer
		hum.NameDisplayDistance = 0
		pcall(function()
			(hum :: any).EvaluateStateMachine = false
		end)
		hum:ChangeState(Enum.HumanoidStateType.Physics)
	end
	_ensureAnimator(model)
end

--[[
	把 SPAWN/STATE 载荷写入 LocalMonster.Humanoid（驱动通用血条）
	@param model Model - 本地表现模
	@param payload any - 可含 hp number / maxHp number
]]
local function _applyHumanoidHp(model: Model, payload: any)
	local hum = model:FindFirstChildOfClass("Humanoid")
	if not hum then
		return
	end
	if typeof(payload.maxHp) == "number" and payload.maxHp > 0 then
		hum.MaxHealth = payload.maxHp
	end
	if typeof(payload.hp) == "number" then
		hum.Health = math.clamp(payload.hp, 0, hum.MaxHealth)
	elseif typeof(payload.maxHp) == "number" and payload.maxHp > 0 then
		hum.Health = payload.maxHp
	end
	hum.WalkSpeed = 0
end

--============================================================================--
-- 公共 API
--============================================================================--

--[[
	初始化（Manager 调用；幂等）
	@return nil - 怪物系统未启用时不建 LocalMonster 文件夹
]]
function SystemLogicalEnemy.Init()
	if SystemGameConfig.GetValue({ "怪物系统", "启用" }) == false then
		return
	end
	if _inited then
		return
	end
	_inited = true
	_getFolder()
end

--[[
	SPAWN：克隆 LocalMonster 并写入首包快照
	@param payload any - SpawnPayload：id number, cfgId number, posX/Y/Z, lookX/Y/Z, t?, moveState?, hp?, maxHp?, combatReady?
]]
function SystemLogicalEnemy.OnSpawn(payload: any)
	if type(payload) ~= "table" or typeof(payload.id) ~= "number" then
		return
	end
	local id = payload.id
	_destroyEntry(id)

	local cfgId = tonumber(payload.cfgId)
	if not cfgId then
		Log.warn("[SystemLogicalEnemy.OnSpawn] cfgId 无效")
		return
	end
	local cfg = CfgFind.GetCfgByNameAndID("enemyConf", cfgId)
	local modelName = cfg and cfg.model
	if type(modelName) ~= "string" or modelName == "" then
		Log.warn("[SystemLogicalEnemy.OnSpawn] model 无效", cfgId)
		return
	end

	local clone = ResourceUtil.GetModel(ResourceUtil.ModelCategory.Enemy, modelName, {
		scope = ResourceUtil.Scope.Shared,
	})
	if not clone or not clone:IsA("Model") then
		Log.warn("[SystemLogicalEnemy.OnSpawn] 克隆失败", modelName)
		return
	end

	local cf = _payloadCFrame(payload)
	local serverT = _payloadServerTime(payload)
	clone.Name = tostring(id)
	_applyPresentationPhysics(clone)
	local root = _getRoot(clone)
	-- 首帧：PivotTo 对齐整模，再写根 CFrame，与后续跟随写入一致
	clone:PivotTo(cf)
	if root then
		root.CFrame = cf
	end
	clone:SetAttribute(EnemyLogicalTypes.ATTR_IS_LOGICAL, true)
	clone:SetAttribute("ID", cfgId)
	if payload.combatReady == false then
		clone:SetAttribute("CombatReady", false)
	else
		clone:SetAttribute("CombatReady", true)
	end
	_applyHumanoidHp(clone, payload)

	clone.Parent = _getFolder()
	local entry: LocalEntry = {
		id = id,
		model = clone,
		root = root,
		prev = nil,
		latest = {
			cf = cf,
			t = serverT,
		},
		vel = Vector3.zero,
		displayLook = _horizontalUnit(cf.LookVector),
		interpDelay = INTERP_DELAY_DEFAULT,
		extrapMax = INTERP_DELAY_DEFAULT * 2,
		animNames = _resolveAnimNames(cfg),
		locoKind = nil,
		dying = false,
		displace = nil,
		displaceGen = 0,
	}
	byId[id] = entry
	_bindRender()

	local moveState = if type(payload.moveState) == "string" then payload.moveState else "idle"
	_setLocomotion(entry, moveState)
end

--[[
	TRANSFORM：推进快照队列与位移动作
	@param payload any - TransformPayload：id number, posX/Y/Z, lookX/Y/Z, t?, moveState?
]]
function SystemLogicalEnemy.OnTransform(payload: any)
	if type(payload) ~= "table" or typeof(payload.id) ~= "number" then
		return
	end
	local entry = byId[payload.id]
	if not entry or entry.dying then
		return
	end
	-- 受击位移期间忽略 Transform，避免与轨迹抢写
	if entry.displace then
		return
	end
	_pushSnapshot(entry, _payloadCFrame(payload), _payloadServerTime(payload))
	if type(payload.moveState) == "string" and payload.moveState ~= "" then
		_setLocomotion(entry, payload.moveState)
	end
end

--[[
	STATE：同步 HP / CombatReady 到 LocalMonster（Humanoid 通用血条）
	@param payload any - { id: number, hp: number?, maxHp: number?, combatReady: boolean? }
]]
function SystemLogicalEnemy.OnState(payload: any)
	if type(payload) ~= "table" or typeof(payload.id) ~= "number" then
		return
	end
	local entry = byId[payload.id]
	local model = entry and entry.model
	if not model then
		return
	end
	if payload.combatReady == false or payload.combatReady == true then
		model:SetAttribute("CombatReady", payload.combatReady == true)
	end
	_applyHumanoidHp(model, payload)
end

--[[
	受击位移轨迹（与服务端 LogicalDisplace 同 start/end/duration）
	@param payload any - { id: number, startX/Y/Z: number, endX/Y/Z: number, duration: number, easingStyle: string?, easingDirection: string?, t0: number? }
]]
function SystemLogicalEnemy.OnDisplace(payload: any)
	if type(payload) ~= "table" or typeof(payload.id) ~= "number" then
		return
	end
	local entry = byId[payload.id]
	if not entry or entry.dying then
		return
	end

	local duration = tonumber(payload.duration)
	if not duration or duration <= 0 then
		return
	end
	local t0 = tonumber(payload.t0)
	if not t0 then
		t0 = Workspace:GetServerTimeNow()
	end

	local startPos = Vector3.new(
		tonumber(payload.startX) or 0,
		tonumber(payload.startY) or 0,
		tonumber(payload.startZ) or 0
	)
	local endPos = Vector3.new(
		tonumber(payload.endX) or startPos.X,
		tonumber(payload.endY) or startPos.Y,
		tonumber(payload.endZ) or startPos.Z
	)

	local root = _ensureRoot(entry)
	local look = Vector3.new(0, 0, -1)
	if root then
		local flat = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
		if flat.Magnitude >= MIN_DIR_EPSILON then
			look = flat.Unit
		end
	end

	entry.displaceGen = (entry.displaceGen or 0) + 1
	local gen = entry.displaceGen
	entry.displace = {
		gen = gen,
		startPos = startPos,
		endPos = endPos,
		look = look,
		t0 = t0,
		duration = duration,
		easingStyle = _parseEasingStyle(payload.easingStyle),
		easingDirection = _parseEasingDirection(payload.easingDirection),
	}
end

--[[
	DEATH：播死亡动作后 Destroy
	@param payload any - { id: number }
]]
function SystemLogicalEnemy.OnDeath(payload: any)
	if type(payload) ~= "table" or typeof(payload.id) ~= "number" then
		return
	end
	local id = payload.id
	local entry = byId[id]
	if not entry then
		return
	end
	if entry.dying then
		return
	end
	entry.dying = true
	entry.displace = nil

	local hum = entry.model and entry.model:FindFirstChildOfClass("Humanoid")
	if hum and hum.Health > 0 then
		hum.Health = 0
	end

	local dieName = entry.animNames.die
	local delaySec = DEATH_FALLBACK_SEC
	if type(dieName) == "string" and dieName ~= "" then
		if entry.locoKind and entry.animNames[entry.locoKind] then
			AnimationModule.StopAnimByModel(entry.model, entry.animNames[entry.locoKind] :: string, DEATH_FADE)
		end
		local len = AnimationModule.PlayAnimByModel(
			entry.model,
			dieName,
			1,
			nil,
			nil,
			Enum.AnimationPriority.Action,
			DEATH_FADE
		)
		if typeof(len) == "number" and len > 0 then
			delaySec = math.clamp(len, 0.4, 3)
		end
	end

	task.delay(delaySec, function()
		_destroyEntry(id)
	end)
end

--[[
	按 id 取本地表现模（非伤害权威）
	@param id number | string - 运行时 id
	@return Model? - LocalMonster；无则 nil
]]
function SystemLogicalEnemy.GetModel(id: number | string): Model?
	local n = tonumber(id)
	if not n then
		return nil
	end
	local entry = byId[n]
	return entry and entry.model or nil
end

--[[
	清空全部（测试 / 传送）
]]
function SystemLogicalEnemy.ClearAll()
	local ids = {}
	for id in pairs(byId) do
		table.insert(ids, id)
	end
	for _, id in ipairs(ids) do
		_destroyEntry(id)
	end
end

return SystemLogicalEnemy
