--[[
	Module: LocoGraphSpike
	Description: Animation Graph P0 旁路试播。独立加载已发布 loco 图，Stepped SetParameter，不接现 Animate。
	Author: 林奥宇
	Created: 2026-09-02
	Last Modified: 2026-09-03

	功能：
	- LoadAnimation(rbxassetid://90774329769612) 后 Play，整图一条 Movement 轨
	- Stepped 喂四参数：LocoState / MoveYawRad / MoveMag / ClipSpeed（名称须与图内绿针逐字相同）
	- MoveYawRad：运行时 SetParameter 必须是弧度。getMoveYaw / FORCE_YAW_DEG 仍用角度（0 前、+90 右、-90 左）；图 Polar 左右与脚本相反，写入前取负再 math.rad
	- MoveMag 恒为 1；ClipSpeed 只一条（Walk=speed/15、Run=speed/21、Climb=speed/20，再除 RigScale）
	- 试播前 stopBaseAction 并关掉 sibling Animate，避免基轨叠播；不写 CFrame / WalkSpeed / RootJoint
	- 不接 init.client、不改 GroundLocomotion / StrafeBlend；恢复现网 loco 靠重生角色

	与相关模块：
	- 只读 require Animate/AnimateSetting、AnimateMotionHelpers（yaw / ClipSpeed）
	- stopBaseAction 只读 require AnimateModule 单例
	- 位移仍走 CharacterMotion / CharacterMoveSpeed；ShiftLock 偏航仍可能是 Animate 的 BindToRenderStep 残留，本脚本不 Unbind、不补写

	开关（改这一处即可试播）：
	- SPIKE_ENABLE 默认 false。true 才 Disable Animate 并播图。不要以 true 合进正式玩法
	- 与 AnimateSetting.GraphLoco.ENABLE 运行时互斥：同时真则本脚本拒绝并 Log
	- FORCE_LOCO_STATE / FORCE_YAW_DEG 非 nil 时覆盖自动喂参。FORCE_YAW_DEG 仍填角度 0/90/180/-90，脚本再转弧度
	- 自动路径不写 Start* / Stop* / Land / LightLand / StopWalk；可用 FORCE 手测 Select 针名

	加载方式：
		角色生成时由引擎启动；无需业务 require。
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

	示例：
		-- 1) SPIKE_ENABLE = true，FORCE_LOCO_STATE = "Walk"，FORCE_YAW_DEG 依次 0 / 90 / 180 / -90
		-- 2) FORCE_LOCO_STATE = "Run" 同测四向
		-- 3) FORCE 切 Idle / Jump / Fall / Land 看 Select
		-- 4) FORCE_*=nil，WASD 自动喂参
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Log = Utils.Log
local RunService = Utils.RunService

-- ========================================
-- 实验室开关（默认关，避免进正式包顶掉现 Animate）
-- ========================================
local SPIKE_ENABLE = false
local FORCE_LOCO_STATE: string? = nil
local FORCE_YAW_DEG: number? = nil

if not SPIKE_ENABLE then
	-- 试播曾把角色/模板上的 Animate 关掉；脚本 Disable 后不会自己再跑。关 Spike 时若仍 Disabled 则打开让现网启动
	local animateScript = script.Parent:FindFirstChild("Animate")
	if animateScript and animateScript:IsA("BaseScript") and animateScript.Enabled == false then
		warn("[LocoGraphSpike] SPIKE_ENABLE=false 但 Animate.Enabled=false，已强制打开")
		animateScript.Enabled = true
	end
	return
end

-- ========================================
-- 常量
-- ========================================
local GRAPH_ANIMATION_ID = "rbxassetid://90774329769612"
local MOUNT_ACTIVE_ATTR = "MountActive"
local PARAM_LOCO_STATE = "LocoState"
local PARAM_MOVE_YAW = "MoveYawRad"
local PARAM_MOVE_MAG = "MoveMag"
local PARAM_CLIP_SPEED = "ClipSpeed"
local MOVE_MAG_VALUE = 1
local STOPWALK_STATE = "StopWalk"
local IDLE_STATE = "Idle"

local Character: Model = script.Parent
local Humanoid: Humanoid = Character:WaitForChild("Humanoid") :: Humanoid
local Animator: Animator = Humanoid:WaitForChild("Animator") :: Animator
local HRP: BasePart = Character:WaitForChild("HumanoidRootPart") :: BasePart

local animateScript = Character:WaitForChild("Animate")
local Setting = require(animateScript:WaitForChild("AnimateSetting"))
local AnimateMotionHelpers = require(animateScript:WaitForChild("AnimateMotionHelpers"))

-- 与 GraphLoco 运行时互斥：同时真会双 Load 同 AssetId
local _graphLocoCfg = Setting.GraphLoco
if type(_graphLocoCfg) == "table" and _graphLocoCfg.ENABLE == true then
	Log.warn("[LocoGraphSpike] GraphLoco.ENABLE=true，拒绝试播以免双 Load 同 AssetId")
	return
end
script:SetAttribute("SpikeActive", true)

-- ========================================
-- 私有变量
-- ========================================
local _connections: { RBXScriptConnection } = {}
local _graphAnimation: Animation? = nil
local _graphTrack: AnimationTrack? = nil
local _motionHelpers: any = nil
local _mutexApplied = false
local _destroyed = false
local _paramErrorLogged = false
local _playing = false

-- ========================================
-- 私有函数
-- ========================================

--[[
	登记连接，角色销毁时统一 Disconnect
	@param conn RBXScriptConnection - 待追踪连接
]]
local function _trackConnection(conn: RBXScriptConnection)
	table.insert(_connections, conn)
end

--[[
	是否处于乘骑总闸（步态归 SystemMount）
	@return boolean - Character.MountActive == true
]]
local function _isMounted(): boolean
	return Character:GetAttribute(MOUNT_ACTIVE_ATTR) == true
end

--[[
	读取 UserAnimateScaleRun；失败则不当缩放
	@return boolean - 是否按 Character:GetScale 除 ClipSpeed
]]
local function _readUserAnimateScaleRun(): boolean
	local ok, value = pcall(function()
		return UserSettings():IsUserFeatureEnabled("UserAnimateScaleRun")
	end)
	return ok == true and value == true
end

--[[
	StopWalk 现网关闭，自动与 FORCE 都不写入该 Select 针
	@param state string - 候选 LocoState
	@return string - 若为 StopWalk 则 Idle，否则原值
]]
local function _sanitizeLocoState(state: string): string
	if state == STOPWALK_STATE then
		return IDLE_STATE
	end
	return state
end

--[[
	简化 Humanoid 态 → 图 Select 针名（不是完整 GroundLocomotion）
	@return string - Idle/Walk/Run/Jump/Fall/Climb/Swim/SwimIdle 等
]]
local function _resolveLocoState(): string
	if FORCE_LOCO_STATE ~= nil and FORCE_LOCO_STATE ~= "" then
		return _sanitizeLocoState(FORCE_LOCO_STATE)
	end

	local humState = Humanoid:GetState()
	if humState == Enum.HumanoidStateType.Swimming then
		local swimThreshold = Setting.SWIM_MOVE_DIRECTION_THRESHOLD
		if type(swimThreshold) ~= "number" or swimThreshold ~= swimThreshold then
			swimThreshold = 0.01
		end
		if Humanoid.MoveDirection.Magnitude > swimThreshold then
			return "Swim"
		end
		return "SwimIdle"
	end
	if humState == Enum.HumanoidStateType.Climbing then
		return "Climb"
	end
	if humState == Enum.HumanoidStateType.Jumping then
		return "Jump"
	end
	if humState == Enum.HumanoidStateType.Freefall then
		return "Fall"
	end

	local intentThreshold = Setting.MOVE_INTENT_FOR_LOCO
	if type(intentThreshold) ~= "number" or intentThreshold ~= intentThreshold then
		intentThreshold = 0.01
	end
	local moveFlat = Vector3.new(Humanoid.MoveDirection.X, 0, Humanoid.MoveDirection.Z)
	if moveFlat.Magnitude >= intentThreshold then
		local runThreshold = Setting.RUN_LOCOMOTION_WALKSPEED_THRESHOLD
		if type(runThreshold) ~= "number" or runThreshold ~= runThreshold then
			runThreshold = 16
		end
		if Humanoid.WalkSpeed > runThreshold then
			return "Run"
		end
		return "Walk"
	end
	return IDLE_STATE
end

--[[
	相对前方的移动角（度）。FORCE_YAW_DEG 优先；否则 getMoveYaw（无输入 hold 上一角）
	@return number - 角度，不是弧度
]]
local function _resolveMoveYawDeg(): number
	if FORCE_YAW_DEG ~= nil then
		return FORCE_YAW_DEG
	end
	if _motionHelpers == nil then
		return 0
	end
	local yawDeg = _motionHelpers.getMoveYaw()
	if type(yawDeg) ~= "number" or yawDeg ~= yawDeg then
		return 0
	end
	return yawDeg
end

--[[
	按当前 LocoState 取 ClipSpeed；Idle/空中等为 1。只读 WalkSpeed，不写
	@param locoState string - 当前 Select 针名
	@return number - Speed 节点倍率
]]
local function _resolveClipSpeed(locoState: string): number
	if _motionHelpers == nil then
		return 1
	end
	local gait: string? = nil
	if locoState == "Walk" or locoState == "StartWalk" then
		gait = "Walk"
	elseif locoState == "Run" or locoState == "StartRun" or locoState == "StopRun" then
		gait = "Run"
	elseif locoState == "Climb" then
		gait = "Climb"
	end
	if gait == nil then
		return 1
	end
	return _motionHelpers.getRunAnimationSpeed(Humanoid.WalkSpeed, gait)
end

--[[
	向图轨写四参数。MoveYawRad 取负后转弧度（对齐 Polar 左右）；MoveMag 恒 1
	@param track AnimationTrack - 已 Play 的图轨
]]
local function _applyParameters(track: AnimationTrack)
	local locoState = _resolveLocoState()
	local yawDeg = _resolveMoveYawDeg()
	local yawRad = math.rad(-yawDeg)
	local clipSpeed = _resolveClipSpeed(locoState)
	local graphAny = track :: any
	local ok, err = pcall(function()
		graphAny:SetParameter(PARAM_LOCO_STATE, locoState)
		graphAny:SetParameter(PARAM_MOVE_YAW, yawRad)
		graphAny:SetParameter(PARAM_MOVE_MAG, MOVE_MAG_VALUE)
		graphAny:SetParameter(PARAM_CLIP_SPEED, clipSpeed)
	end)
	if not ok and not _paramErrorLogged then
		_paramErrorLogged = true
		Log.warn("[LocoGraphSpike] SetParameter failed:", err)
	end
end

--[[
	停掉非本图、且档位不超过 Movement 的残留轨（勿停 Action+ 技能 Overlay）
	@param graphTrack AnimationTrack - 本图轨（即使尚未 Play 也排除）
]]
local function _stopLeftoverBaseTracks(graphTrack: AnimationTrack)
	local movementValue = Enum.AnimationPriority.Movement.Value
	local playing = Animator:GetPlayingAnimationTracks()
	for _, track in ipairs(playing) do
		if track ~= graphTrack and track.Priority.Value <= movementValue then
			pcall(function()
				track:Stop(0.1)
			end)
		end
	end
end

--[[
	停现 Animate 基轨并关掉脚本。不 Unbind ShiftLock 偏航 RenderStep
]]
local function _applyMutex()
	if _mutexApplied then
		return
	end
	_mutexApplied = true

	local moduleOk, animateMod = pcall(function()
		return require(animateScript:WaitForChild("AnimateModule"))
	end)
	if moduleOk and animateMod ~= nil and type(animateMod.stopBaseAction) == "function" then
		pcall(function()
			animateMod:stopBaseAction()
		end)
	end

	if animateScript:IsA("BaseScript") then
		animateScript.Enabled = false
	end
end

--[[
	Play 图轨（已互斥）。乘骑中不播
]]
local function _playGraph()
	if _destroyed or _graphTrack == nil then
		return
	end
	if _isMounted() then
		return
	end
	_applyMutex()
	_stopLeftoverBaseTracks(_graphTrack)
	if not _graphTrack.IsPlaying then
		_graphTrack:Play()
	end
	_playing = true
	_applyParameters(_graphTrack)
end

--[[
	Stop 图轨。不重开 Animate（Disable 后本角色无法靠 Enabled=true 重跑）
]]
local function _stopGraph()
	_playing = false
	if _graphTrack ~= nil and _graphTrack.IsPlaying then
		pcall(function()
			_graphTrack:Stop(0.1)
		end)
	end
end

--[[
	断开连接、停图轨。不写位移，不恢复 Animate
]]
local function _cleanup()
	if _destroyed then
		return
	end
	_destroyed = true
	_stopGraph()
	for _, conn in ipairs(_connections) do
		conn:Disconnect()
	end
	table.clear(_connections)
	if _graphAnimation ~= nil then
		_graphAnimation:Destroy()
		_graphAnimation = nil
	end
	_graphTrack = nil
end

--[[
	加载已发布图。失败不 Disable Animate
	@return AnimationTrack? - 成功的图轨；失败 nil
]]
local function _loadGraphTrack(): AnimationTrack?
	if Character:IsDescendantOf(workspace) == false then
		local deadline = os.clock() + 10
		while Character:IsDescendantOf(workspace) == false and os.clock() < deadline do
			task.wait()
		end
	end
	if Character:IsDescendantOf(workspace) == false then
		Log.warn("[LocoGraphSpike] Character not in Workspace, skip LoadAnimation")
		return nil
	end

	local animation = Instance.new("Animation")
	animation.Name = "LocoDefaultGraph"
	animation.AnimationId = GRAPH_ANIMATION_ID
	animation.Parent = script
	_graphAnimation = animation

	local ok, result = pcall(function()
		return Animator:LoadAnimation(animation)
	end)
	if not ok or result == nil then
		Log.warn("[LocoGraphSpike] LoadAnimation failed:", result)
		animation:Destroy()
		_graphAnimation = nil
		return nil
	end
	return result
end

-- ========================================
-- 启动
-- ========================================

task.wait()

_motionHelpers = AnimateMotionHelpers.create({
	character = Character,
	hrp = HRP,
	humanoid = Humanoid,
	setting = Setting,
	userAnimateScaleRun = _readUserAnimateScaleRun(),
})

local loadedTrack = _loadGraphTrack()
if loadedTrack == nil then
	return
end
_graphTrack = loadedTrack

_trackConnection(RunService.Stepped:Connect(function()
	if _destroyed or _graphTrack == nil or not _playing then
		return
	end
	if _isMounted() then
		return
	end
	if _graphTrack.IsPlaying then
		_applyParameters(_graphTrack)
	end
end))

_trackConnection(Character:GetAttributeChangedSignal(MOUNT_ACTIVE_ATTR):Connect(function()
	if _destroyed then
		return
	end
	if _isMounted() then
		_stopGraph()
	else
		_playGraph()
	end
end))

_trackConnection(Character.AncestryChanged:Connect(function(_, parent)
	if parent == nil then
		_cleanup()
	end
end))

_trackConnection(script.Destroying:Connect(function()
	_cleanup()
end))

if _isMounted() then
	Log.warn("[LocoGraphSpike] MountActive=true, hold graph until dismount")
else
	_playGraph()
end
