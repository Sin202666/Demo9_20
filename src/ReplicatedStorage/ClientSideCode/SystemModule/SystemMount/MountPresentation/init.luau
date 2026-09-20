--[[
	Module: MountPresentation
	Description: 坐骑表现层：A 马焊人 / B 人上鞍；步态与 Jump Takeoff；压制角色 loco
	Author: 林奥宇
	Created: 2026-08-27
	Last Modified: 2026-09-01

	能力：
	- attach（A）：马焊角色；HipHeightDelta + AutoGroundAlign
	- attachRoot（B）：物理根 + 视觉；优先 VehicleSeat/Seat 落座（禁引擎载具推力），否则焊鞍；乘骑期关角色 CanCollide
	- getGroundYError：查询 Hull 相对射线地面的 ΔY（Driver 用速度跟，禁每帧 CFrame）
	- updateGait / requestJump / detach 两模式共用（Walk/Gallop 用 Run 槽变速）
	- 与 Driver 控制核解耦；不写 WalkSpeed / yaw

	加载：
		local MountPresentation = require(script.Parent.Parent.MountPresentation)
		local pres = MountPresentation.new()
		pres:attach(character, cfg)
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local ActionArbiter = Utils.ActionArbiter
local AnimationModule = Utils.AnimationModule
local HttpService = Utils.HttpService
local Players = Utils.Players
local ResourceUtil = Utils.ResourceUtil
local Workspace = workspace

local MountAnimSets = require(script.Parent.MountAnimSets)

local MountPresentation = {}
MountPresentation.__index = MountPresentation

local MOUNT_PRESENTATION_OWNER_ID = "Mount:Presentation"
local DEFAULT_ATTACH_OFFSET = CFrame.new(0, 0, 0)
local GAIT_IDLE_SPEED = 2.5
local GAIT_FADE = 0.12
local GAIT_WALK_SPEED = 0.72
local GAIT_GALLOP_SPEED = 1.12
local HOOF_SNAP_EPS = 0.04
local DEFAULT_MODEL_SCALE = 1
-- 体高约 5 的陆地坐骑：抬 HRP，避免鞍座对齐后马身埋地、人脚仍贴地
local DEFAULT_HIP_HEIGHT_DELTA = 2.8
local DEFAULT_TAKEOFF_MARKER = "Takeoff"
local DEFAULT_TAKEOFF_FALLBACK_SEC = 0.15
local DEFAULT_GROUND_CLEARANCE = 0.05
local DEFAULT_AUTO_GROUND_ALIGN = true
local DEFAULT_HULL_SIZE = Vector3.new(2.4, 2.8, 5.2)
local DEFAULT_RIDER_OFFSET = CFrame.new(0, 0, 0)
local MOUNT_ROOT_FOLDER_NAME = "MountRoots"

export type GaitContext = {
	airborne: boolean,
	flatSpeed: number,
	gait: string?,
	speed01: number?,
}

export type PresentationParams = {
	modelScale: number,
	attachOffset: CFrame,
	hipHeightDelta: number,
	takeoffMarker: string,
	takeoffFallbackSec: number,
	autoGroundAlign: boolean,
	groundClearance: number,
	hullSize: Vector3,
	riderOffset: CFrame,
}

export type MountPresentation = typeof(setmetatable({} :: {
	_character: Model?,
	_mountModel: Model?,
	_weld: WeldConstraint?,
	_animSet: string?,
	_currentSlot: string?,
	_locoToken: string?,
	_params: PresentationParams?,
	_savedHipHeight: number?,
	_jumpPending: boolean,
	_jumpCommitted: boolean,
	_jumpCommitCb: (() -> ())?,
	_jumpFallbackThread: thread?,
	_jumpLockSlot: boolean,
	_gaitPlaySpeed: number,
	_driveMode: string,
	_physicsRoot: BasePart?,
	_container: Model?,
	_riderWeld: WeldConstraint?,
	_visualWeld: WeldConstraint?,
	_savedPlatformStand: boolean?,
	_savedAutoRotate: boolean?,
	_mountSeat: (VehicleSeat | Seat)?,
	_savedJumpingEnabled: boolean?,
	_savedRiderCollide: { { part: BasePart, canCollide: boolean } }?,
}, MountPresentation))

--[[
	构造表现实例
	@return MountPresentation - 实例
]]
function MountPresentation.new(): MountPresentation
	local self = setmetatable({
		_character = nil,
		_mountModel = nil,
		_weld = nil,
		_animSet = nil,
		_currentSlot = nil,
		_locoToken = nil,
		_params = nil,
		_savedHipHeight = nil,
		_jumpPending = false,
		_jumpCommitted = false,
		_jumpCommitCb = nil,
		_jumpFallbackThread = nil,
		_jumpLockSlot = false,
		_gaitPlaySpeed = 1,
		_driveMode = "HumanoidHost",
		_physicsRoot = nil,
		_container = nil,
		_riderWeld = nil,
		_visualWeld = nil,
		_savedPlatformStand = nil,
		_savedAutoRotate = nil,
		_mountSeat = nil,
		_savedJumpingEnabled = nil,
		_savedRiderCollide = nil,
	}, MountPresentation)
	return self
end

--[[
	解析 ExtJson / 表字段为表现参数
	@param cfg table - MountCfg 深拷贝行
	@return PresentationParams - 表现参数
]]
local function _parsePresentationParams(cfg: { [string]: any }): PresentationParams
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
		if type(v) == "number" and v == v then
			return v
		end
		return default
	end

	local scale = _num("ModelScale", DEFAULT_MODEL_SCALE)
	if scale <= 0.05 then
		scale = DEFAULT_MODEL_SCALE
	end
	scale = math.clamp(scale, 0.2, 4)

	local hipDelta = _num("HipHeightDelta", DEFAULT_HIP_HEIGHT_DELTA)
	hipDelta = math.clamp(hipDelta, -4, 8)

	local attachOffset = CFrame.new()
	local offsetRaw = ext.AttachOffset
	if offsetRaw == nil then
		offsetRaw = cfg.AttachOffset
	end
	if typeof(offsetRaw) == "Vector3" then
		attachOffset = CFrame.new(offsetRaw)
	elseif typeof(offsetRaw) == "CFrame" then
		attachOffset = offsetRaw
	elseif type(offsetRaw) == "table" then
		local x = tonumber(offsetRaw[1] or offsetRaw.X or offsetRaw.x) or 0
		local y = tonumber(offsetRaw[2] or offsetRaw.Y or offsetRaw.y) or 0
		local z = tonumber(offsetRaw[3] or offsetRaw.Z or offsetRaw.z) or 0
		attachOffset = CFrame.new(x, y, z)
	end

	local marker = ext.JumpTakeoffMarker or cfg.JumpTakeoffMarker
	if type(marker) ~= "string" or marker == "" then
		marker = DEFAULT_TAKEOFF_MARKER
	end

	local fallback = _num("JumpTakeoffFallbackSec", DEFAULT_TAKEOFF_FALLBACK_SEC)
	fallback = math.clamp(fallback, 0.02, 0.5)

	local autoAlign = DEFAULT_AUTO_GROUND_ALIGN
	local autoRaw = ext.AutoGroundAlign
	if autoRaw == nil then
		autoRaw = cfg.AutoGroundAlign
	end
	if autoRaw == false or autoRaw == 0 or autoRaw == "0" then
		autoAlign = false
	elseif autoRaw == true or autoRaw == 1 or autoRaw == "1" then
		autoAlign = true
	end

	local clearance = _num("GroundClearance", DEFAULT_GROUND_CLEARANCE)
	-- 允许更大下压：B 模式蹄底浮空常靠负 Clearance 微调
	clearance = math.clamp(clearance, -4, 2)

	local hullSize = DEFAULT_HULL_SIZE
	local hullRaw = ext.HullSize or cfg.HullSize
	if typeof(hullRaw) == "Vector3" then
		hullSize = hullRaw
	elseif type(hullRaw) == "table" then
		local hx = tonumber(hullRaw[1] or hullRaw.X or hullRaw.x) or DEFAULT_HULL_SIZE.X
		local hy = tonumber(hullRaw[2] or hullRaw.Y or hullRaw.y) or DEFAULT_HULL_SIZE.Y
		local hz = tonumber(hullRaw[3] or hullRaw.Z or hullRaw.z) or DEFAULT_HULL_SIZE.Z
		hullSize = Vector3.new(math.max(0.5, hx), math.max(0.5, hy), math.max(0.5, hz))
	end

	local riderOffset = DEFAULT_RIDER_OFFSET
	local riderRaw = ext.RiderOffset or cfg.RiderOffset
	if typeof(riderRaw) == "CFrame" then
		riderOffset = riderRaw
	elseif typeof(riderRaw) == "Vector3" then
		riderOffset = CFrame.new(riderRaw)
	elseif type(riderRaw) == "table" then
		local rx = tonumber(riderRaw[1] or riderRaw.X or riderRaw.x) or 0
		local ry = tonumber(riderRaw[2] or riderRaw.Y or riderRaw.y) or 0
		local rz = tonumber(riderRaw[3] or riderRaw.Z or riderRaw.z) or 0
		riderOffset = CFrame.new(rx, ry, rz)
	end

	return {
		modelScale = scale,
		attachOffset = attachOffset,
		hipHeightDelta = hipDelta,
		takeoffMarker = marker,
		takeoffFallbackSec = fallback,
		autoGroundAlign = autoAlign,
		groundClearance = clearance,
		hullSize = hullSize,
		riderOffset = riderOffset,
	}
end

--[[
	确保模型可播轨（Humanoid 或 AnimationController + Animator）
	@param model Model - 坐骑模型
	@return Animator? - 动画器
]]
local function _ensureAnimator(model: Model): Animator?
	local host = model:FindFirstChildOfClass("Humanoid")
	if not host then
		host = model:FindFirstChildOfClass("AnimationController")
	end
	if not host then
		local ac = Instance.new("AnimationController")
		ac.Name = "AnimationController"
		ac.Parent = model
		host = ac
	end
	local animator = host:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Name = "Animator"
		animator.Parent = host
	end
	return animator
end

--[[
	选取焊接用根 Part
	@param model Model - 坐骑模型
	@return BasePart? - 根部件
]]
local function _resolveMountRoot(model: Model): BasePart?
	if model.PrimaryPart and model.PrimaryPart:IsA("BasePart") then
		return model.PrimaryPart
	end
	local named = model:FindFirstChild("HumanoidRootPart")
	if named and named:IsA("BasePart") then
		model.PrimaryPart = named
		return named
	end
	for _, child in ipairs(model:GetDescendants()) do
		if child:IsA("BasePart") then
			model.PrimaryPart = child
			return child
		end
	end
	return nil
end

--[[
	查找模型内 VehicleSeat / Seat（优先 AttachName 命中座位，否则首个座位）
	@param model Model - 坐骑视觉模型
	@param attachName string - 配置挂点名
	@return VehicleSeat|Seat? - 座位
]]
local function _findMountSeat(model: Model, attachName: string): (VehicleSeat | Seat)?
	if attachName ~= "" then
		local named = model:FindFirstChild(attachName, true)
		if named and (named:IsA("VehicleSeat") or named:IsA("Seat")) then
			return named :: any
		end
	end
	local vehicleSeat = model:FindFirstChildWhichIsA("VehicleSeat", true)
	if vehicleSeat then
		return vehicleSeat
	end
	local seat = model:FindFirstChildWhichIsA("Seat", true)
	if seat then
		return seat
	end
	return nil
end

--[[
	配置座位：只作落座，不启用引擎载具推力（位移由 MountRootDriver 写马根）
	@param seat VehicleSeat|Seat - 座位
]]
local function _configureMountSeat(seat: VehicleSeat | Seat)
	seat.Disabled = false
	seat.CanCollide = false
	seat.Massless = true
	seat.Anchored = false
	if seat:IsA("VehicleSeat") then
		seat.HeadsUpDisplay = false
		seat.MaxSpeed = 0
		seat.Torque = 0
		seat.TurnSpeed = 0
		seat.Throttle = 0
		seat.Steer = 0
		seat.ThrottleFloat = 0
		seat.SteerFloat = 0
	end
end

--[[
	查找挂点 BasePart 或 Attachment
	@param model Model - 坐骑模型
	@param attachName string - AttachName
	@return (BasePart?, Attachment?) - 挂点部件或附件
]]
local function _findAttach(model: Model, attachName: string): (BasePart?, Attachment?)
	if attachName == "" then
		return nil, nil
	end
	local node = model:FindFirstChild(attachName, true)
	if not node then
		return nil, nil
	end
	if node:IsA("BasePart") then
		return node, nil
	end
	if node:IsA("Attachment") then
		local parent = node.Parent
		if parent and parent:IsA("BasePart") then
			return parent, node
		end
	end
	return nil, nil
end

--[[
	将坐骑焊到角色 HRP（挂点对齐 + AttachOffset；可选把模型底对齐地面）
	@param model Model - 坐骑模型
	@param hrp BasePart - 角色 HRP
	@param hum Humanoid - 角色 Humanoid（读 HipHeight 估地面）
	@param attachName string - 可选挂点名
	@param attachOffset CFrame - 额外偏移（相对 HRP）
	@param autoGroundAlign boolean - 是否按包围盒底贴地
	@param groundClearance number - 贴地后再抬的间隙（stud）
	@return WeldConstraint? - 焊点
]]
local function _weldToCharacter(
	model: Model,
	hrp: BasePart,
	hum: Humanoid,
	attachName: string,
	attachOffset: CFrame,
	autoGroundAlign: boolean,
	groundClearance: number
): WeldConstraint?
	local root = _resolveMountRoot(model)
	if not root then
		return nil
	end

	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			d.CanCollide = false
			d.Massless = true
			d.Anchored = false
		end
	end

	local attachPart, attachment = _findAttach(model, attachName)
	if attachment and attachPart then
		local attachCf = attachPart.CFrame * attachment.CFrame
		local offset = root.CFrame:ToObjectSpace(attachCf)
		model:PivotTo(hrp.CFrame * attachOffset * offset:Inverse())
	elseif attachPart then
		local offset = root.CFrame:ToObjectSpace(attachPart.CFrame)
		model:PivotTo(hrp.CFrame * attachOffset * offset:Inverse())
	else
		model:PivotTo(hrp.CFrame * DEFAULT_ATTACH_OFFSET * attachOffset)
	end

	-- 鞍座对齐 HRP 后马身常埋地：按包围盒底抬到 HipHeight 地面，保留相对 HRP 的抬升再焊死
	if autoGroundAlign then
		local bbCf, bbSize = model:GetBoundingBox()
		local mountBottom = bbCf.Position.Y - bbSize.Y * 0.5
		local groundY = hrp.Position.Y - hum.HipHeight
		local lift = (groundY - mountBottom) + groundClearance
		if math.abs(lift) > 1e-3 then
			model:PivotTo(model:GetPivot() + Vector3.new(0, lift, 0))
		end
	end

	local weld = Instance.new("WeldConstraint")
	weld.Name = "MountModelWeld"
	weld.Part0 = hrp
	weld.Part1 = root
	weld.Parent = root
	return weld
end

--[[
	压制角色腿部 loco
	@param self MountPresentation - 表现
	@param character Model - 角色
]]
local function _acquireLocoSuppress(self: MountPresentation, character: Model)
	local arbiter = ActionArbiter.GetForCharacter(character)
	if not arbiter or type(arbiter.Acquire) ~= "function" then
		return
	end
	self._locoToken = arbiter:Acquire({
		ownerId = MOUNT_PRESENTATION_OWNER_ID,
		priority = ActionArbiter.Priority.FacingBridge,
		blendPolicy = ActionArbiter.BlendPolicy.Override,
		suppressLoco = true,
		pauseBaseTracks = true,
		reason = "MountPresentation",
	})
end

--[[
	释放 loco 压制
	@param self MountPresentation - 表现
	@param character Model? - 角色
]]
local function _releaseLocoSuppress(self: MountPresentation, character: Model?)
	if self._locoToken and character then
		local arbiter = ActionArbiter.GetForCharacter(character)
		if arbiter and type(arbiter.Release) == "function" then
			arbiter:Release(self._locoToken)
		end
	elseif character then
		local arbiter = ActionArbiter.GetForCharacter(character)
		if arbiter and type(arbiter.ReleaseByOwner) == "function" then
			arbiter:ReleaseByOwner(MOUNT_PRESENTATION_OWNER_ID)
		end
	end
	self._locoToken = nil
end

--[[
	应用 / 恢复 HipHeight
	@param self MountPresentation - 表现
	@param character Model - 角色
	@param delta number - HipHeight 增量
]]
local function _applyHipHeight(self: MountPresentation, character: Model, delta: number)
	local hum = character:FindFirstChildWhichIsA("Humanoid")
	if not hum then
		return
	end
	if self._savedHipHeight == nil then
		self._savedHipHeight = hum.HipHeight
	end
	hum.HipHeight = (self._savedHipHeight :: number) + delta
end

--[[
	恢复 HipHeight
	@param self MountPresentation - 表现
	@param character Model? - 角色
]]
local function _restoreHipHeight(self: MountPresentation, character: Model?)
	if self._savedHipHeight == nil then
		return
	end
	if character then
		local hum = character:FindFirstChildWhichIsA("Humanoid")
		if hum then
			hum.HipHeight = self._savedHipHeight
		end
	end
	self._savedHipHeight = nil
end

--[[
	乘骑期关闭角色碰撞（避免与 Hull/地面双碰撞把整装配体顶高 ~HipHeight）
	@param self MountPresentation - 表现
	@param character Model - 角色
]]
local function _disableRiderCollision(self: MountPresentation, character: Model)
	local saved: { { part: BasePart, canCollide: boolean } } = {}
	for _, d in ipairs(character:GetDescendants()) do
		if d:IsA("BasePart") then
			table.insert(saved, { part = d, canCollide = d.CanCollide })
			d.CanCollide = false
		end
	end
	self._savedRiderCollide = saved
end

--[[
	恢复角色碰撞
	@param self MountPresentation - 表现
]]
local function _restoreRiderCollision(self: MountPresentation)
	local saved = self._savedRiderCollide
	if not saved then
		return
	end
	for _, entry in ipairs(saved) do
		local part = entry.part
		if part and part.Parent then
			part.CanCollide = entry.canCollide
		end
	end
	self._savedRiderCollide = nil
end

--[[
	切换步态槽（同槽不重复 Play；可带 Marker）
	@param self MountPresentation - 表现
	@param slot string - Idle / Run / Jump
	@param keyframeNames {string}? - Marker 名
	@param keyframeFunctions {() -> ()}? - Marker 回调
]]
local function _playSlot(
	self: MountPresentation,
	slot: string,
	keyframeNames: { string }?,
	keyframeFunctions: { () -> () }?
)
	local forceReplay = keyframeNames ~= nil and #keyframeNames > 0
	if self._currentSlot == slot and not forceReplay then
		return
	end
	local model = self._mountModel
	local animSet = self._animSet
	if not model or not animSet then
		return
	end
	local animName = MountAnimSets.ResolveAnimName(animSet, slot)
	if not animName then
		return
	end

	local prevSlot = self._currentSlot
	if prevSlot and prevSlot ~= slot then
		local prevName = MountAnimSets.ResolveAnimName(animSet, prevSlot)
		if prevName then
			AnimationModule.StopAnimByModel(model, prevName, GAIT_FADE)
		end
	elseif prevSlot == slot and forceReplay then
		AnimationModule.StopAnimByModel(model, animName, 0)
	end

	local priority = Enum.AnimationPriority.Movement
	AnimationModule.PlayAnimByModel(
		model,
		animName,
		1,
		keyframeNames,
		keyframeFunctions,
		priority,
		GAIT_FADE
	)
	self._currentSlot = slot
	self._gaitPlaySpeed = 1
end

--[[
	取消未完成的起跳承诺
	@param self MountPresentation - 表现
]]
local function _cancelJumpRequestInternal(self: MountPresentation)
	self._jumpPending = false
	self._jumpCommitCb = nil
	self._jumpLockSlot = false
	if self._jumpFallbackThread then
		local th = self._jumpFallbackThread
		self._jumpFallbackThread = nil
		task.cancel(th)
	end
end

--[[
	触发一次起跳点火（Marker / Fallback 共用；只执行一次）
	@param self MountPresentation - 表现
]]
local function _fireJumpCommit(self: MountPresentation)
	if not self._jumpPending then
		return
	end
	local cb = self._jumpCommitCb
	self._jumpPending = false
	self._jumpCommitCb = nil
	self._jumpCommitted = true
	self._jumpLockSlot = true
	if self._jumpFallbackThread then
		local th = self._jumpFallbackThread
		self._jumpFallbackThread = nil
		task.cancel(th)
	end
	if type(cb) == "function" then
		cb()
	end
end

--[[
	附着坐骑模型并开步态
	@param self MountPresentation - 表现
	@param character Model - 玩家角色
	@param cfg table - MountCfg 深拷贝行
	@return boolean - 是否成功（失败则 Driver 应用 Part 占位）
]]
function MountPresentation.attach(self: MountPresentation, character: Model, cfg: { [string]: any }): boolean
	self:detach()

	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp or not hrp:IsA("BasePart") then
		return false
	end

	local modelName = cfg.Model
	if type(modelName) ~= "string" or modelName == "" then
		return false
	end

	local animSet = cfg.AnimSet
	if type(animSet) ~= "string" or animSet == "" or not MountAnimSets.HasSet(animSet) then
		return false
	end

	local params = _parsePresentationParams(cfg)

	local cloned = ResourceUtil.GetModel(ResourceUtil.ModelCategory.Mount, modelName, {
		clone = true,
	})
	if not cloned or not cloned:IsA("Model") then
		return false
	end

	cloned.Name = "MountModel_" .. modelName
	if not _ensureAnimator(cloned) then
		cloned:Destroy()
		return false
	end

	-- Scale 须在焊前，挂点随模型缩放
	if math.abs(params.modelScale - 1) > 1e-3 and type(cloned.ScaleTo) == "function" then
		cloned:ScaleTo(params.modelScale)
	end

	local hum = character:FindFirstChildWhichIsA("Humanoid")
	if not hum then
		cloned:Destroy()
		return false
	end

	-- 先抬 HipHeight，再按新地面贴马蹄，避免「人脚贴地、马身埋地」
	_applyHipHeight(self, character, params.hipHeightDelta)

	local attachName = if type(cfg.AttachName) == "string" then cfg.AttachName else ""
	cloned.Parent = character
	local weld = _weldToCharacter(
		cloned,
		hrp,
		hum,
		attachName,
		params.attachOffset,
		params.autoGroundAlign,
		params.groundClearance
	)
	if not weld then
		_restoreHipHeight(self, character)
		cloned:Destroy()
		return false
	end

	self._character = character
	self._mountModel = cloned
	self._weld = weld
	self._animSet = animSet
	self._params = params
	self._driveMode = "HumanoidHost"
	self._currentSlot = nil
	self._jumpPending = false
	self._jumpCommitted = false
	self._jumpLockSlot = false

	_acquireLocoSuppress(self, character)
	_playSlot(self, "Idle")
	return true
end

--[[
	解析坐骑模型 Animator
	@param model Model - 坐骑模型
	@return Animator? - 动画器
]]
local function _resolveAnimator(model: Model): Animator?
	local host = model:FindFirstChildOfClass("Humanoid")
	if not host then
		host = model:FindFirstChildOfClass("AnimationController")
	end
	if not host then
		return nil
	end
	return host:FindFirstChildOfClass("Animator")
end

--[[
	调整当前步态槽播放倍率（同槽不重播）
	@param self MountPresentation - 表现
	@param playSpeed number - AdjustSpeed
]]
local function _adjustCurrentSpeed(self: MountPresentation, playSpeed: number)
	if math.abs((self._gaitPlaySpeed or 1) - playSpeed) < 0.04 then
		return
	end
	local model = self._mountModel
	local animSet = self._animSet
	local slot = self._currentSlot
	if not model or not animSet or not slot then
		return
	end
	local animName = MountAnimSets.ResolveAnimName(animSet, slot)
	if not animName then
		return
	end
	local animator = _resolveAnimator(model)
	if not animator then
		return
	end
	AnimationModule.ChangeAnimSpeed(animator, animName, playSpeed)
	self._gaitPlaySpeed = playSpeed
end

--[[
	查询 Hull 相对射线地面的高度误差（desired - current；正=应抬）
	@param self MountPresentation - 表现
	@return number? - ΔY；未命中为 nil
]]
local function _queryHullGroundDelta(self: MountPresentation): number?
	local hull = self._physicsRoot
	local params = self._params
	if not hull or not hull.Parent or not params then
		return nil
	end
	local half = hull.Size.Y * 0.5
	local origin = hull.Position + Vector3.new(0, half * 0.35, 0)
	local dist = half + math.max(params.groundClearance, 0) + 2.4
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	local filter: { Instance } = {}
	if self._container then
		table.insert(filter, self._container)
	end
	if self._character then
		table.insert(filter, self._character)
	end
	rayParams.FilterDescendantsInstances = filter
	local result = Workspace:Raycast(origin, Vector3.new(0, -dist, 0), rayParams)
	if not result then
		return nil
	end
	local desiredY = result.Position.Y + half + params.groundClearance
	return desiredY - hull.Position.Y
end

--[[
	射线贴地：仅上鞍一次性纠正（运行时勿每帧 CFrame，会与碰撞双写抖）
	@param self MountPresentation - 表现
	@param maxStep number - 本帧最大 |ΔY|
	@return boolean - 是否命中地面
]]
local function _snapHullToGround(self: MountPresentation, maxStep: number): boolean
	local hull = self._physicsRoot
	local dy = _queryHullGroundDelta(self)
	if not hull or dy == nil then
		return false
	end
	if math.abs(dy) < HOOF_SNAP_EPS then
		return true
	end
	local step = math.clamp(dy, -maxStep, maxStep)
	hull.CFrame = hull.CFrame + Vector3.new(0, step, 0)
	return true
end

--[[
	取得 MountRoot 物理根（仅 DriveMode=MountRoot）
	@param self MountPresentation - 表现
	@return BasePart? - 物理根
]]
function MountPresentation.getPhysicsRoot(self: MountPresentation): BasePart?
	return self._physicsRoot
end

--[[
	是否 MountRoot 模式
	@param self MountPresentation - 表现
	@return boolean - MountRoot
]]
function MountPresentation.isRootMode(self: MountPresentation): boolean
	return self._driveMode == "MountRoot"
end

--[[
	查询相对射线地面的 ΔY（正=应抬；未命中 nil）
	@param self MountPresentation - 表现
	@return number? - desiredY - currentY
]]
function MountPresentation.getGroundYError(self: MountPresentation): number?
	return _queryHullGroundDelta(self)
end

--[[
	B：仅上鞍一次性贴地。运行时请用 getGroundYError + 速度跟，勿每帧 CFrame
	@param self MountPresentation - 表现
	@param maxStep number? - 本帧最大 |ΔY|，默认 0.5
	@return boolean - 是否命中地面
]]
function MountPresentation.snapRootToGround(self: MountPresentation, maxStep: number?): boolean
	local cap = if type(maxStep) == "number" and maxStep > 0 then maxStep else 0.5
	return _snapHullToGround(self, cap)
end

--[[
	B 方案：马为物理根，玩家焊到鞍点（托雷特主从）
	@param self MountPresentation - 表现
	@param character Model - 玩家角色
	@param cfg table - MountCfg 深拷贝行
	@return boolean - 是否成功
]]
function MountPresentation.attachRoot(self: MountPresentation, character: Model, cfg: { [string]: any }): boolean
	self:detach()

	local hrp = character:FindFirstChild("HumanoidRootPart")
	local hum = character:FindFirstChildWhichIsA("Humanoid")
	if not hrp or not hrp:IsA("BasePart") or not hum then
		return false
	end

	local modelName = cfg.Model
	if type(modelName) ~= "string" or modelName == "" then
		return false
	end

	local animSet = cfg.AnimSet
	if type(animSet) ~= "string" or animSet == "" or not MountAnimSets.HasSet(animSet) then
		return false
	end

	local params = _parsePresentationParams(cfg)
	local look = Vector3.new(hrp.CFrame.LookVector.X, 0, hrp.CFrame.LookVector.Z)
	if look.Magnitude < 1e-3 then
		look = Vector3.new(0, 0, -1)
	else
		look = look.Unit
	end
	local yaw = math.atan2(-look.X, -look.Z)
	local groundY = hrp.Position.Y - hum.HipHeight

	local hull = Instance.new("Part")
	hull.Name = "MountPhysicsRoot"
	hull.Size = params.hullSize
	hull.Transparency = 1
	hull.CanCollide = true
	hull.CanQuery = false
	hull.CanTouch = false
	hull.Massless = false
	hull.Anchored = false
	-- elasticity=0 + 高 elasticityWeight：压掉落地恢复系数弹跳（脚本写速与接触求解叠弹）
	hull.CustomPhysicalProperties = PhysicalProperties.new(0.9, 0.4, 0, 1, 100)
	hull.CFrame = CFrame.new(hrp.Position.X, groundY + params.hullSize.Y * 0.5, hrp.Position.Z)
		* CFrame.Angles(0, yaw, 0)

	local container = Instance.new("Model")
	container.Name = "MountRoot_" .. modelName
	hull.Parent = container
	container.PrimaryPart = hull

	local cloned = ResourceUtil.GetModel(ResourceUtil.ModelCategory.Mount, modelName, {
		clone = true,
	})
	if not cloned or not cloned:IsA("Model") then
		container:Destroy()
		return false
	end

	cloned.Name = "MountVisual_" .. modelName
	if not _ensureAnimator(cloned) then
		cloned:Destroy()
		container:Destroy()
		return false
	end

	if math.abs(params.modelScale - 1) > 1e-3 and type(cloned.ScaleTo) == "function" then
		cloned:ScaleTo(params.modelScale)
	end

	local visualRoot = _resolveMountRoot(cloned)
	if not visualRoot then
		cloned:Destroy()
		container:Destroy()
		return false
	end

	for _, d in ipairs(cloned:GetDescendants()) do
		if d:IsA("BasePart") then
			d.CanCollide = false
			d.Massless = true
			d.Anchored = false
		end
	end

	cloned.Parent = container
	local attachName = if type(cfg.AttachName) == "string" then cfg.AttachName else ""
	local mountSeat = _findMountSeat(cloned, attachName)
	if mountSeat then
		_configureMountSeat(mountSeat)
	end

	local attachPart, attachment = _findAttach(cloned, attachName)
	-- 有 VehicleSeat/Seat 时，以座位为对齐锚点（比 MountSaddle 更准）
	if mountSeat then
		attachPart = mountSeat
		attachment = nil
	end

	if attachment and attachPart then
		local attachCf = attachPart.CFrame * attachment.CFrame
		local offset = visualRoot.CFrame:ToObjectSpace(attachCf)
		local saddleTarget = hull.CFrame * CFrame.new(0, params.hullSize.Y * 0.35, 0)
		cloned:PivotTo(saddleTarget * params.attachOffset * offset:Inverse())
	elseif attachPart then
		local offset = visualRoot.CFrame:ToObjectSpace(attachPart.CFrame)
		local saddleTarget = hull.CFrame * CFrame.new(0, params.hullSize.Y * 0.35, 0)
		cloned:PivotTo(saddleTarget * params.attachOffset * offset:Inverse())
	else
		cloned:PivotTo(hull.CFrame * params.attachOffset)
	end

	if params.autoGroundAlign then
		local bbCf, bbSize = cloned:GetBoundingBox()
		local mountBottom = bbCf.Position.Y - bbSize.Y * 0.5
		local hullBottom = hull.Position.Y - params.hullSize.Y * 0.5
		local lift = hullBottom - mountBottom
		if math.abs(lift) > 1e-3 then
			cloned:PivotTo(cloned:GetPivot() + Vector3.new(0, lift, 0))
		end
	end

	local visualWeld = Instance.new("WeldConstraint")
	visualWeld.Name = "MountVisualWeld"
	visualWeld.Part0 = hull
	visualWeld.Part1 = visualRoot
	visualWeld.Parent = hull

	-- 座位必须焊到物理根（我们每帧推动的 Part）；只焊视觉根时 Sit 后装配体可能分裂，人留原地
	if mountSeat then
		local seatWeld = Instance.new("WeldConstraint")
		seatWeld.Name = "MountSeatWeld"
		seatWeld.Part0 = hull
		seatWeld.Part1 = mountSeat
		seatWeld.Parent = hull
	end

	local folder = Workspace:FindFirstChild(MOUNT_ROOT_FOLDER_NAME)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = MOUNT_ROOT_FOLDER_NAME
		folder.Parent = Workspace
	end
	container.Parent = folder

	local localPlayer = Players.LocalPlayer
	if localPlayer then
		pcall(function()
			hull:SetNetworkOwner(localPlayer)
		end)
	end

	-- 骑手：始终 Weld 到物理根，保证跟人走；Seat 只作姿态锚点（Sit 不可靠时也不掉队）
	local riderWeld: WeldConstraint? = nil
	self._savedAutoRotate = hum.AutoRotate
	hum.AutoRotate = false
	hrp.AssemblyLinearVelocity = Vector3.zero

	local riderTargetCf: CFrame
	if mountSeat then
		riderTargetCf = mountSeat.CFrame * params.riderOffset
	elseif attachment and attachPart then
		riderTargetCf = attachPart.CFrame * attachment.CFrame * params.riderOffset
	elseif attachPart then
		riderTargetCf = attachPart.CFrame * params.riderOffset
	else
		riderTargetCf = hull.CFrame * CFrame.new(0, params.hullSize.Y * 0.5, 0) * params.riderOffset
	end

	self._savedPlatformStand = hum.PlatformStand
	hum.PlatformStand = true
	-- 先关角色碰撞再焊：否则四肢/HRP 与 Hull 双撑地，装配体常被顶高约 2~3 stud
	_disableRiderCollision(self, character)
	hrp.CFrame = riderTargetCf

	riderWeld = Instance.new("WeldConstraint")
	riderWeld.Name = "MountRiderWeld"
	riderWeld.Part0 = hull
	riderWeld.Part1 = hrp
	riderWeld.Parent = hull

	self._mountSeat = mountSeat
	if mountSeat then
		self._savedJumpingEnabled = hum:GetStateEnabled(Enum.HumanoidStateType.Jumping)
		hum:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
		-- 不用 Seat:Sit：Sit 会改装配体根/拆掉自定义焊，导致马走人不走；座位仅作锚点
	end

	-- 网络所有权覆盖到角色，避免装配体以人根为主时不同步
	if localPlayer then
		pcall(function()
			hrp:SetNetworkOwner(localPlayer)
			hull:SetNetworkOwner(localPlayer)
		end)
	end

	self._character = character
	self._mountModel = cloned
	self._container = container
	self._physicsRoot = hull
	self._visualWeld = visualWeld
	self._riderWeld = riderWeld
	self._weld = nil
	self._animSet = animSet
	self._params = params
	self._driveMode = "MountRoot"
	self._currentSlot = nil
	self._jumpPending = false
	self._jumpCommitted = false
	self._jumpLockSlot = false
	self._gaitPlaySpeed = 1

	_acquireLocoSuppress(self, character)
	_playSlot(self, "Idle")
	-- 上鞍后按地形纠正 Hull 高度；视觉已焊在 Hull 上
	_snapHullToGround(self, 12)
	return true
end

--[[
	每帧清零 VehicleSeat 油门/转向，避免引擎载具力与马根驱动叠力
	@param self MountPresentation - 表现
]]
function MountPresentation.tickSeatControls(self: MountPresentation)
	local seat = self._mountSeat
	if seat and seat:IsA("VehicleSeat") and seat.Parent then
		seat.Throttle = 0
		seat.Steer = 0
		seat.ThrottleFloat = 0
		seat.SteerFloat = 0
	end
end

--[[
	请求首跳：播 Jump，等 Takeoff Marker 或 Fallback 后回调
	@param self MountPresentation - 表现
	@param onCommit (() -> ()) - 物理点火回调（只调一次）
	@return boolean - 是否已受理（已在起跳窗则 false）
]]
function MountPresentation.requestJump(self: MountPresentation, onCommit: () -> ()): boolean
	if not self._mountModel or not self._animSet or not self._params then
		return false
	end
	if self._jumpPending then
		return false
	end
	if type(onCommit) ~= "function" then
		return false
	end

	_cancelJumpRequestInternal(self)
	self._jumpPending = true
	self._jumpCommitted = false
	self._jumpCommitCb = onCommit
	self._jumpLockSlot = true

	local marker = self._params.takeoffMarker
	local fallbackSec = self._params.takeoffFallbackSec
	_playSlot(self, "Jump", { marker }, {
		function()
			_fireJumpCommit(self)
		end,
	})

	self._jumpFallbackThread = task.delay(fallbackSec, function()
		self._jumpFallbackThread = nil
		_fireJumpCommit(self)
	end)
	return true
end

--[[
	取消未完成的起跳（收骑 / ForceExit）
	@param self MountPresentation - 表现
]]
function MountPresentation.cancelJumpRequest(self: MountPresentation)
	_cancelJumpRequestInternal(self)
	self._jumpCommitted = false
end

--[[
	落地通知：解除 Jump 槽锁定，允许回到 Idle/Run
	@param self MountPresentation - 表现
]]
function MountPresentation.onLanded(self: MountPresentation)
	_cancelJumpRequestInternal(self)
	self._jumpCommitted = false
	self._jumpLockSlot = false
end

--[[
	是否处于起跳窗（已播 Jump、尚未点火或刚点火尚未落地）
	@param self MountPresentation - 表现
	@return boolean - 起跳窗中
]]
function MountPresentation.isJumpLocked(self: MountPresentation): boolean
	return self._jumpPending or self._jumpLockSlot
end

--[[
	按空中/水平速更新步态
	@param self MountPresentation - 表现
	@param ctx GaitContext - 步态上下文（gait=Walk|Gallop 时 Run 槽变速）
]]
function MountPresentation.updateGait(self: MountPresentation, ctx: GaitContext)
	if not self._mountModel or not self._animSet then
		return
	end
	-- 起跳窗：保持 Jump，勿被地面 Idle/Run 打断
	if self._jumpPending or self._jumpLockSlot then
		if ctx.airborne then
			self._jumpLockSlot = true
		end
		_playSlot(self, "Jump")
		return
	end
	if ctx.airborne then
		_playSlot(self, "Jump")
		return
	end
	local speed = ctx.flatSpeed
	if type(speed) ~= "number" or speed ~= speed then
		speed = 0
	end
	if speed < GAIT_IDLE_SPEED then
		_playSlot(self, "Idle")
		return
	end
	local speed01 = ctx.speed01
	if type(speed01) ~= "number" or speed01 ~= speed01 then
		speed01 = 0
	end
	local gait = ctx.gait
	local isWalk = gait == "Walk" or (gait ~= "Gallop" and speed01 < 0.5)
	local playSpeed: number
	if isWalk then
		playSpeed = GAIT_WALK_SPEED * (0.85 + 0.25 * math.clamp(speed01 / 0.45, 0, 1))
	else
		playSpeed = GAIT_GALLOP_SPEED * (0.85 + 0.2 * math.clamp(speed01, 0, 1))
	end
	_playSlot(self, "Run")
	_adjustCurrentSpeed(self, playSpeed)
end

--[[
	拆除模型与闸
	@param self MountPresentation - 表现
]]
function MountPresentation.detach(self: MountPresentation)
	local character = self._character
	local model = self._mountModel
	local animSet = self._animSet
	local container = self._container

	_cancelJumpRequestInternal(self)
	self._jumpCommitted = false

	if model and animSet then
		for _, slot in ipairs(MountAnimSets.SLOT_ORDER) do
			local animName = MountAnimSets.ResolveAnimName(animSet, slot)
			if animName then
				AnimationModule.StopAnimByModel(model, animName, 0)
			end
		end
	end

	_releaseLocoSuppress(self, character)
	_restoreHipHeight(self, character)
	_restoreRiderCollision(self)

	if self._riderWeld then
		self._riderWeld:Destroy()
		self._riderWeld = nil
	end
	if self._visualWeld then
		self._visualWeld:Destroy()
		self._visualWeld = nil
	end
	if self._weld then
		self._weld:Destroy()
		self._weld = nil
	end

	if character then
		local hum = character:FindFirstChildWhichIsA("Humanoid")
		local hrp = character:FindFirstChild("HumanoidRootPart")
		if hum then
			-- 先离座，再销毁座位模型
			if hum.SeatPart ~= nil or hum.Sit then
				hum.Sit = false
			end
			if self._savedJumpingEnabled ~= nil then
				hum:SetStateEnabled(Enum.HumanoidStateType.Jumping, self._savedJumpingEnabled)
			end
			if self._savedPlatformStand ~= nil then
				hum.PlatformStand = self._savedPlatformStand
			end
			if self._savedAutoRotate ~= nil then
				hum.AutoRotate = self._savedAutoRotate
			end
		end
		-- 下马：放到物理根旁侧，避免卡进马身
		if hrp and hrp:IsA("BasePart") and self._physicsRoot then
			local root = self._physicsRoot
			local side = root.CFrame.RightVector * 3
			local drop = root.Position + side
			hrp.CFrame = CFrame.new(drop.X, drop.Y + 2, drop.Z)
				* CFrame.Angles(0, math.atan2(-root.CFrame.LookVector.X, -root.CFrame.LookVector.Z), 0)
			hrp.AssemblyLinearVelocity = Vector3.zero
		end
	end
	self._savedPlatformStand = nil
	self._savedAutoRotate = nil
	self._savedJumpingEnabled = nil
	self._mountSeat = nil

	if container then
		container:Destroy()
	elseif model then
		model:Destroy()
	end

	self._mountModel = nil
	self._container = nil
	self._physicsRoot = nil
	self._character = nil
	self._animSet = nil
	self._params = nil
	self._currentSlot = nil
	self._driveMode = "HumanoidHost"
end

--[[
	是否已附着真模型
	@param self MountPresentation - 表现
	@return boolean - 已附着
]]
function MountPresentation.isAttached(self: MountPresentation): boolean
	return self._mountModel ~= nil
end

return MountPresentation
