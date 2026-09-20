--[[
	Module: GraphLocoDriver
	Description: 已发布 loco 图的只读喂参驱动。不改 Animate 方法、不停现网基轨；图只 SetParameter。
	Author: 林奥宇
	Created: 2026-09-03
	Last Modified: 2026-09-03

	功能：
	- ENABLE=false：立即 inert，现网 Animate 完全不变。
	- ENABLE=true：须在 LocoStyle.Create 之后调用。先 Load+Play 图；失败不影响现网。
	- 成功：Stepped 读 Animate.BasePos / getMoveYaw，写 LocoState / MoveYawRad / MoveMag / ClipSpeed。
	- 不替换 bindBaseAction / setBasePos / playTransition。现网继续播腿，避免图未出姿时 T-pose。
	- Walk_Left 等扇区针名消毒为 Walk/Run；StopWalk 尊重 TransitionEnable。
	- MoveYawRad = math.rad(-yawDeg)。非 ShiftLock 写 0。MoveMag 恒 1。
	- Gate pause（BaseActionEnabled=false）或 MountActive：Stop 图轨；恢复后 Play。
	- FootStep：图轨 Marker → FootLand；对不齐则现网速度计步兜底。
	- 与 LocoGraphSpike.SPIKE_ENABLE 运行时互斥。

	与相关模块：
	- 不改 GroundLocomotion FSM；不写 CFrame / WalkSpeed / RootJoint；不 Unbind 偏航。
	- 不进 Utils。仅 Animate/init.client require。
	- 本切片先保证现网可见；图与基轨可能短暂双开（图未出姿时仍有腿）。确认图出姿后再收独写。

	标准加载：
		-- 先 LocoStyle.Create，再：
		local handle = GraphLocoDriver.tryAttach({
			animate = Animate,
			character = Character,
			humanoid = Humanoid,
			setting = Setting,
			getMoveYaw = motionHelpers.getMoveYaw,
			getRunAnimationSpeed = motionHelpers.getRunAnimationSpeed,
			isShiftLocked = function()
				return _isShiftLocked
			end,
			isMounted = _isMountedMode,
			onFootStep = function(param)
				FootLand.FootLand(Character, param)
			end,
		})

	示例：
		-- ENABLE=false：inert
		-- ENABLE=true 且 Load 失败：现网照常
		-- ENABLE=true 且 Load 成功：现网有腿；Output 有 [GraphLocoDriver] 图轨已播放
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Log = Utils.Log
local RunService = Utils.RunService

local GraphLocoDriver = {}

-- ========================================
-- 常量
-- ========================================

local DEFAULT_GRAPH_ANIMATION_ID = "rbxassetid://90774329769612"
local MOUNT_ACTIVE_ATTR = "MountActive"
local SPIKE_SCRIPT_NAME = "LocoGraphSpike"
local SPIKE_ACTIVE_ATTR = "SpikeActive"

local PARAM_LOCO_STATE = "LocoState"
local PARAM_MOVE_YAW = "MoveYawRad"
local PARAM_MOVE_MAG = "MoveMag"
local PARAM_CLIP_SPEED = "ClipSpeed"
local MOVE_MAG_VALUE = 1
local FOOTSTEP_MARKER = "FootStep"
local WORKSPACE_WAIT_SEC = 10
local GRAPH_STOP_FADE = 0.1

local SELECT_PINS: { [string]: boolean } = {
	Idle = true,
	StartWalk = true,
	Walk = true,
	StartRun = true,
	Run = true,
	StopRun = true,
	StopWalk = true,
	Jump = true,
	Fall = true,
	Land = true,
	LightLand = true,
	Climb = true,
	Swim = true,
	SwimIdle = true,
}

local SECTOR_TO_GAIT: { [string]: string } = {
	Walk_Left = "Walk",
	Walk_Right = "Walk",
	Walk_Back = "Walk",
	Run_Left = "Run",
	Run_Right = "Run",
	Run_Back = "Run",
}

export type GraphLocoDeps = {
	animate: any,
	character: Model,
	humanoid: Humanoid,
	setting: any,
	getMoveYaw: () -> (number, number),
	getRunAnimationSpeed: (walkspeed: number, posName: string) -> number,
	isShiftLocked: () -> boolean,
	isMounted: () -> boolean,
	onFootStep: ((param: string) -> ())?,
	resyncAfterAttach: (() -> ())?,
}

export type GraphLocoHandle = {
	isActive: () -> boolean,
	destroy: () -> (),
}

-- ========================================
-- 私有函数
-- ========================================

--[[
	Studio / 正式服都能看到的警告（不走 Log 门面，避免非开发服被静默）
	@param ... any - 与 warn 相同
]]
local function _emitWarn(...)
	warn(...)
	pcall(function()
		Log.warn(...)
	end)
end

--[[
	构造 inert 句柄
	@return GraphLocoHandle - isActive 恒 false
]]
local function _inertHandle(): GraphLocoHandle
	return {
		isActive = function()
			return false
		end,
		destroy = function() end,
	}
end

--[[
	读 GraphLoco 开关与 AssetId
	@param setting any - AnimateSetting
	@return boolean - ENABLE==true
	@return string - AnimationId
]]
local function _readGraphCfg(setting: any): (boolean, string)
	local cfg = setting and setting.GraphLoco
	if type(cfg) ~= "table" then
		return false, DEFAULT_GRAPH_ANIMATION_ID
	end
	local assetId = cfg.GRAPH_ANIMATION_ID
	if type(assetId) ~= "string" or assetId == "" then
		assetId = DEFAULT_GRAPH_ANIMATION_ID
	end
	return cfg.ENABLE == true, assetId
end

--[[
	兄弟 Spike 是否已激活
	@param character Model - 当前角色
	@return boolean - SpikeActive
]]
local function _isSpikeActive(character: Model): boolean
	local spike = character:FindFirstChild(SPIKE_SCRIPT_NAME)
	if spike == nil then
		return false
	end
	return spike:GetAttribute(SPIKE_ACTIVE_ATTR) == true
end

--[[
	扇区 / StopWalk → 合法 Select 针
	@param poseName string - Animate.BasePos
	@param setting any - AnimateSetting
	@return string - LocoState
]]
local function _sanitizeSelectPin(poseName: string, setting: any): string
	local gait = SECTOR_TO_GAIT[poseName]
	if gait then
		return gait
	end
	if poseName == "StopWalk" then
		local enable = setting and setting.TransitionEnable
		if not (enable and enable.StopWalk == true) then
			return "Idle"
		end
	end
	if SELECT_PINS[poseName] then
		return poseName
	end
	if poseName == "" then
		return "Idle"
	end
	return "Idle"
end

--[[
	LocoState → ClipSpeed 步态
	@param locoState string - Select 针
	@return string? - Walk | Run | Climb
]]
local function _clipGaitForState(locoState: string): string?
	if locoState == "Walk" or locoState == "StartWalk" then
		return "Walk"
	end
	if locoState == "Run" or locoState == "StartRun" or locoState == "StopRun" then
		return "Run"
	end
	if locoState == "Climb" then
		return "Climb"
	end
	return nil
end

--[[
	等待 Character 进入 Workspace
	@param character Model - 当前角色
	@return boolean - 已在 Workspace
]]
local function _waitForWorkspace(character: Model): boolean
	if character:IsDescendantOf(workspace) then
		return true
	end
	local deadline = os.clock() + WORKSPACE_WAIT_SEC
	while character:IsDescendantOf(workspace) == false and os.clock() < deadline do
		task.wait()
	end
	return character:IsDescendantOf(workspace)
end

-- ========================================
-- 公共函数
-- ========================================

--[[
	加载图轨并开始 Stepped 喂参。不包装 Animate，不停现网基轨。
	@param deps GraphLocoDeps - animate 单例、角色、Setting、yaw/速度/乘骑/脚步
	@return GraphLocoHandle - isActive / destroy
]]
function GraphLocoDriver.tryAttach(deps: GraphLocoDeps): GraphLocoHandle
	if type(deps) ~= "table" or deps.animate == nil or deps.character == nil then
		return _inertHandle()
	end

	local enabled, assetId = _readGraphCfg(deps.setting)
	if not enabled then
		return _inertHandle()
	end

	if _isSpikeActive(deps.character) then
		_emitWarn("[GraphLocoDriver] LocoGraphSpike 已激活，拒绝接管以免双 Load")
		return _inertHandle()
	end

	if not _waitForWorkspace(deps.character) then
		_emitWarn("[GraphLocoDriver] Character 未进 Workspace，走现网")
		return _inertHandle()
	end

	local animate = deps.animate
	local humanoid = deps.humanoid
	local animator = animate.Animator
	if animator == nil or typeof(animator) ~= "Instance" or animator:IsA("Animator") == false then
		animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	end
	if animator == nil then
		_emitWarn("[GraphLocoDriver] 无 Animator，走现网")
		return _inertHandle()
	end

	local graphAnimation: Animation? = Instance.new("Animation")
	graphAnimation.Name = "LocoDefaultGraph"
	graphAnimation.AnimationId = assetId
	local animateScript = script.Parent
	graphAnimation.Parent = if animateScript then animateScript else script

	local loadOk, loadResult = pcall(function()
		return animator:LoadAnimation(graphAnimation)
	end)
	if not loadOk or loadResult == nil then
		_emitWarn("[GraphLocoDriver] LoadAnimation 失败，走现网:", loadResult)
		graphAnimation:Destroy()
		return _inertHandle()
	end

	local graphTrack: AnimationTrack? = loadResult :: AnimationTrack
	local character = deps.character
	local setting = deps.setting
	local connections: { RBXScriptConnection } = {}
	local destroyed = false
	local paramErrorLogged = false

	--[[
		登记连接
		@param conn RBXScriptConnection - 待追踪连接
	]]
	local function trackConnection(conn: RBXScriptConnection)
		table.insert(connections, conn)
	end

	--[[
		是否乘骑
		@return boolean - Mounted
	]]
	local function isMountedNow(): boolean
		if deps.isMounted then
			return deps.isMounted() == true
		end
		return character:GetAttribute(MOUNT_ACTIVE_ATTR) == true
	end

	--[[
		是否应播图（未乘骑且基轨使能）
		@return boolean - 可 Play
	]]
	local function canPlayGraph(): boolean
		if isMountedNow() then
			return false
		end
		return animate.BaseActionEnabled ~= false
	end

	--[[
		向图写四参数。LocoState 来自现网 BasePos（只读）
	]]
	local function applyParameters()
		if graphTrack == nil or destroyed then
			return
		end
		local locoState = _sanitizeSelectPin(tostring(animate.BasePos or "Idle"), setting)
		local yawDeg = 0
		if deps.isShiftLocked() == true then
			local yaw, _mag = deps.getMoveYaw()
			if type(yaw) == "number" and yaw == yaw then
				yawDeg = yaw
			end
		end
		local clipSpeed = 1
		local gait = _clipGaitForState(locoState)
		if gait ~= nil then
			clipSpeed = deps.getRunAnimationSpeed(humanoid.WalkSpeed, gait)
		end
		local graphAny = graphTrack :: any
		local ok, err = pcall(function()
			graphAny:SetParameter(PARAM_LOCO_STATE, locoState)
			graphAny:SetParameter(PARAM_MOVE_YAW, math.rad(-yawDeg))
			graphAny:SetParameter(PARAM_MOVE_MAG, MOVE_MAG_VALUE)
			graphAny:SetParameter(PARAM_CLIP_SPEED, clipSpeed)
		end)
		if not ok and not paramErrorLogged then
			paramErrorLogged = true
			_emitWarn("[GraphLocoDriver] SetParameter 失败:", err)
		end
	end

	--[[
		Play 图轨。不停现网基轨。
	]]
	local function playGraph()
		if destroyed or graphTrack == nil or not canPlayGraph() then
			return
		end
		if not graphTrack.IsPlaying then
			pcall(function()
				graphTrack:Play()
			end)
		end
		applyParameters()
	end

	--[[
		Stop 图轨。不改 BaseActionEnabled，不动现网轨。
	]]
	local function stopGraph()
		if graphTrack ~= nil and graphTrack.IsPlaying then
			pcall(function()
				graphTrack:Stop(GRAPH_STOP_FADE)
			end)
		end
	end

	--[[
		断开连接并停图。不改 Animate 方法。
	]]
	local function cleanup()
		if destroyed then
			return
		end
		destroyed = true
		stopGraph()
		for _, conn in ipairs(connections) do
			conn:Disconnect()
		end
		table.clear(connections)
		if graphTrack ~= nil then
			pcall(function()
				graphTrack:Destroy()
			end)
			graphTrack = nil
		end
		if graphAnimation ~= nil then
			graphAnimation:Destroy()
			graphAnimation = nil
		end
	end

	local playOk, playErr = pcall(function()
		(graphTrack :: AnimationTrack):Play()
	end)
	if not playOk then
		_emitWarn("[GraphLocoDriver] 图轨 Play 失败，走现网:", playErr)
		cleanup()
		return _inertHandle()
	end
	applyParameters()

	trackConnection(RunService.Stepped:Connect(function()
		if destroyed or graphTrack == nil then
			return
		end
		if not canPlayGraph() then
			stopGraph()
			return
		end
		if not graphTrack.IsPlaying then
			playGraph()
			return
		end
		applyParameters()
	end))

	trackConnection(character:GetAttributeChangedSignal(MOUNT_ACTIVE_ATTR):Connect(function()
		if destroyed then
			return
		end
		if isMountedNow() then
			stopGraph()
		else
			playGraph()
		end
	end))

	local onFootStep = deps.onFootStep
	if onFootStep and graphTrack ~= nil then
		local markerTrack = graphTrack
		local markerOk, markerSignal = pcall(function()
			return markerTrack:GetMarkerReachedSignal(FOOTSTEP_MARKER)
		end)
		if markerOk and markerSignal then
			trackConnection(markerSignal:Connect(function(param: string)
				if destroyed or not canPlayGraph() then
					return
				end
				onFootStep(param)
			end))
		end
	end

	_emitWarn("[GraphLocoDriver] 图轨已播放 isPlaying=", graphTrack ~= nil and graphTrack.IsPlaying, "现网基轨保持")

	return {
		isActive = function()
			return not destroyed
		end,
		destroy = cleanup,
	}
end

--[[
	兼容旧 init：本版不再包装方法，调用无效果
	@param _animate any - Animate 单例
]]
function GraphLocoDriver.forceUnwrap(_animate: any)
	return
end

return GraphLocoDriver
