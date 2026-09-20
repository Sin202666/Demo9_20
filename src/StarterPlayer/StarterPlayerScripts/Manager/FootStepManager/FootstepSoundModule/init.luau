--[[
	Module: FootstepSoundModule
	Description: 脚步声音播放器（速度检测 + 材质射线 + Sound 对象池）
	Author: 林奥宇
	Created: 2026-07-03
	Last Modified: 2026-09-01

	功能：
	- new(character)：绑定角色 Humanoid / HRP，静音默认 Running / Landing，启动 Heartbeat 计步
	- destroy：断开 StateChanged / Heartbeat / Sound.Ended，销毁池内与在播 Sound
	- Raycast 检测地面材质，按 FootstepSoundsConfig 随机选取间隔式音效
	- FreeFall → Landed 时播放落地音与可选落地特效
	- GameConfig.FootStep.动画Marker驱动 为 true 时：本地角色近期有 AnimFootStepAt 则跳过速度计步（防双踩；无 Marker 仍兜底）

	与相关模块：
	- FootStepManager：只编排玩家进出与 CharacterAdded，本模块负责单角色播放
	- FootLand：本地动画 Marker 写 AnimFootStepAt；落地镜头反馈不在本模块
	- ToolSystem/FootstepSound：简单 Running SoundId 替换，角色编排不要用它
	- 材质表：Utils.FootstepSoundsConfig；落地特效：Utils.FXUtil（缺失则跳过）

	加载方式：
		local FootstepSoundModule = require(script.FootstepSoundModule)
		local player = FootstepSoundModule.new(character)
		if player then
			player:destroy()
		end
]]

-- ============================================================================
-- 服务 / 模块引用
-- ============================================================================

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local RunService = Utils.RunService
local SoundService = Utils.SoundService
local FXUtil = Utils.FXUtil
local SystemGameConfig = Utils.SystemGameConfig
local FootstepSoundsConfig = Utils.FootstepSoundsConfig
local RayCast = Utils.RayCast
local Log = Utils.Log
local LocalPlayer = Utils.LocalPlayer

local Workspace = game:GetService("Workspace")

assert(FootstepSoundsConfig, "FootstepSoundsConfig 未注册")

-- ============================================================================
-- 模块定义
-- ============================================================================

local FootstepSoundModule = {}
FootstepSoundModule.__index = FootstepSoundModule

-- ============================================================================
-- 常量
-- ============================================================================

-- 本地角色 Marker 优先：抑制窗内跳过速度计步（无 Marker 时仍兜底）
local LOCAL_FOOTSTEP_BY_ANIM_MARKER = SystemGameConfig.GetValue({ "FootStep", "动画Marker驱动" }) ~= false
local ANIM_FOOTSTEP_ATTR = "AnimFootStepAt"
local ANIM_FOOTSTEP_SUPPRESS_SEC = 0.32

local RUN_SPEED = 32
local MIN_SPEED = 4
local WALK_INTERVAL_MULTIPLIER = 0.5
local RUN_INTERVAL_MULTIPLIER = 0.33
local WALK_STEP_DISTANCE = 15
local RUN_STEP_DISTANCE = 36
local FOOTSTEP_VOLUME = 0.1
local LANDED_VOLUME = 0.2
local DEFAULT_VOLUME_MULTIPLIER = 1.0
local DEFAULT_PLAYBACK_SPEED = 1.0
local SPEED_CHECK_INTERVAL = 0.03
local RAYCAST_DISTANCE = 7
local MAX_DISTANCE = 200
local ROLLOFF_MAX_DISTANCE = 150
local ROLLOFF_MIN_DISTANCE = 5
local RIG_WAIT_TIMEOUT = 10
local SOUND_WAIT_TIMEOUT = 5
local CHARACTERS_FOLDER_NAME = "Characters"
local FOOTSTEP_SOUND_GROUP_NAME = "FootStep"
local DEFAULT_RUNNING_SOUND_NAME = "Running"
local DEFAULT_LANDING_SOUND_NAME = "Landing"
local LANDING_EFFECT_NAME = "LandingEffect"
local LANDING_EFFECT_EMIT_TIME = 3
local LANDING_EFFECT_TYPE = 3
local LANDING_EFFECT_ROTATION = CFrame.Angles(0, 0, math.rad(90))
-- 0：任意 FreeFall 都播落地特效；提高后按下落高度过滤
local MIN_LANDING_EFFECT_HEIGHT = 0

-- ============================================================================
-- 私有函数
-- ============================================================================

--[[
	从 SoundService 取脚步 SoundGroup；缺失时不绑定（避免索引报错）

	@return SoundGroup? - FootStep 组；不存在或类型不符时 nil
]]
local function _getFootStepSoundGroup(): SoundGroup?
	local group = SoundService:FindFirstChild(FOOTSTEP_SOUND_GROUP_NAME)
	if group and group:IsA("SoundGroup") then
		return group
	end
	return nil
end

--[[
	静音角色默认位移音效，避免与自定义脚步叠播

	@param rootPart BasePart - 角色 HumanoidRootPart
	@param soundName string - 默认音效名（Running / Landing）
]]
local function _muteDefaultLocomotionSound(rootPart: BasePart, soundName: string)
	local sound = rootPart:FindFirstChild(soundName)
	if not sound then
		sound = rootPart:WaitForChild(soundName, SOUND_WAIT_TIMEOUT)
	end
	if sound and sound:IsA("Sound") then
		sound.SoundId = ""
		sound.Volume = 0
		return
	end
	Log.warn("FootstepSoundModule: 未找到默认位移音效，跳过静音", soundName)
end

--[[
	从播放列表移除指定 Sound

	@param self table - 播放器实例
	@param sound Sound - 要移除的实例
]]
local function _removePlaying(self, sound: Sound)
	for i, playingSound in ipairs(self._playingSounds) do
		if playingSound == sound then
			table.remove(self._playingSounds, i)
			return
		end
	end
end

--[[
	Sound.Ended：从播放列表摘下并归还对象池

	@param self table - 播放器实例
	@param sound Sound - 刚结束的实例
	@param pool { Sound } - 对应材质/soundId 的池
]]
local function _onPooledSoundEnded(self, sound: Sound, pool: { Sound })
	if self._destroyed then
		return
	end
	_removePlaying(self, sound)
	if sound.Parent then
		if sound.IsPlaying then
			sound:Stop()
		end
		table.insert(pool, sound)
	end
end

--[[
	从池中取出未在播放的 Sound；无可用则返回 nil

	@param pool { Sound } - 材质/soundId 池
	@return Sound? - 可复用实例
]]
local function _takeIdleSound(pool: { Sound }): Sound?
	for i, pooledSound in ipairs(pool) do
		if pooledSound and pooledSound.Parent and not pooledSound.IsPlaying then
			table.remove(pool, i)
			return pooledSound
		end
	end
	return nil
end

--[[
	销毁一层「材质 → soundId → Sound[]」池

	@param pools table - materialSoundPools 或 landedSoundPools
]]
local function _destroySoundPools(pools)
	for _, soundIdPools in pairs(pools) do
		for _, pool in pairs(soundIdPools) do
			for _, sound in ipairs(pool) do
				if sound and sound.Parent then
					sound:Destroy()
				end
			end
		end
	end
end

--[[
	获取或创建挂在 HRP 上的池化 Sound

	@param self table - 播放器实例
	@param pools table - 脚步或落地池（[Material][soundId] = { Sound }）
	@param namePrefix string - 新建实例 Name 前缀
	@param material Enum.Material - 地面材质
	@param soundId string - rbxassetid
	@param volumeBase number - 基础音量（再乘材质倍率）
	@return Sound? - 可用实例；Air / 无 HRP 时 nil
]]
local function _getOrCreatePooledSound(self, pools, namePrefix: string, material: Enum.Material, soundId: string, volumeBase: number): Sound?
	if material == Enum.Material.Air then
		return nil
	end
	local rootPart = self._rootPart
	if not rootPart then
		return nil
	end

	if not pools[material] then
		pools[material] = {}
	end
	if not pools[material][soundId] then
		pools[material][soundId] = {}
	end

	local pool = pools[material][soundId]
	local sound = _takeIdleSound(pool)
	if not sound then
		local newSound = Instance.new("Sound")
		newSound.Name = namePrefix .. tostring(material)
		newSound.Parent = rootPart
		local volumeMultiplier = FootstepSoundsConfig.VolumeMultipliers[material] or DEFAULT_VOLUME_MULTIPLIER
		newSound.Volume = volumeBase * volumeMultiplier
		newSound.SoundGroup = self._footStepGroup
		newSound.RollOffMaxDistance = ROLLOFF_MAX_DISTANCE
		newSound.RollOffMinDistance = ROLLOFF_MIN_DISTANCE
		newSound.RollOffMode = Enum.RollOffMode.Inverse
		newSound.Looped = false
		newSound.SoundId = soundId
		newSound.PlaybackSpeed = DEFAULT_PLAYBACK_SPEED

		local endedConn = newSound.Ended:Connect(function()
			_onPooledSoundEnded(self, newSound, pool)
		end)
		table.insert(self._soundConnections, endedConn)
		sound = newSound
	end

	sound.PlaybackSpeed = DEFAULT_PLAYBACK_SPEED
	table.insert(self._playingSounds, sound)
	return sound
end

--[[
	向下射线取地面材质

	@param self table - 播放器实例
	@return Enum.Material? - 命中材质；未命中时 nil
]]
local function _getGroundMaterial(self): Enum.Material?
	if not self._rootPart then
		return nil
	end
	local raycastResult = Workspace:Raycast(
		self._rootPart.Position,
		Vector3.new(0, -RAYCAST_DISTANCE, 0),
		self._raycastParams
	)
	if raycastResult and raycastResult.Material then
		return raycastResult.Material
	end
	return nil
end

--[[
	按水平速度计算脚步间隔

	@param moveSpeed number - 水平速度（studs/s），调用方保证 > 0
	@return number - 播放间隔（秒）
]]
local function _calculateStepInterval(moveSpeed: number): number
	local isRunning = moveSpeed >= RUN_SPEED
	local intervalMultiplier = if isRunning then RUN_INTERVAL_MULTIPLIER else WALK_INTERVAL_MULTIPLIER
	local stepDistance = if isRunning then RUN_STEP_DISTANCE else WALK_STEP_DISTANCE
	return intervalMultiplier * (stepDistance / moveSpeed)
end

--[[
	按当前地面材质播放一步脚步声

	@param self table - 播放器实例
	@return boolean - 是否成功开始播放
]]
local function _playFootstepSound(self): boolean
	local currentMaterial = _getGroundMaterial(self)
	if not currentMaterial or currentMaterial == Enum.Material.Air then
		return false
	end

	local soundIds = FootstepSoundsConfig.IntervalSounds[currentMaterial]
	if not soundIds or #soundIds == 0 then
		return false
	end

	local randomSoundId = soundIds[math.random(1, #soundIds)]
	local sound = _getOrCreatePooledSound(self, self._materialSoundPools, "Footstep_", currentMaterial, randomSoundId, FOOTSTEP_VOLUME)
	if not sound then
		return false
	end
	sound:Play()
	return true
end

--[[
	本地角色刚被动画 Marker 踩过则抑制速度计步，并与 Marker 时钟对齐

	@param self table - 播放器实例
	@return boolean - true 表示本帧应跳过速度计步
]]
local function _shouldSuppressByAnimMarker(self): boolean
	if not LOCAL_FOOTSTEP_BY_ANIM_MARKER or not LocalPlayer then
		return false
	end
	local character = LocalPlayer.Character
	if not character or not self._rootPart:IsDescendantOf(character) then
		return false
	end
	local lastAnim = character:GetAttribute(ANIM_FOOTSTEP_ATTR)
	if type(lastAnim) == "number" and (time() - lastAnim) < ANIM_FOOTSTEP_SUPPRESS_SEC then
		self._lastPlayTime = lastAnim
		return true
	end
	return false
end

--[[
	摄像机过远则跳过计步（无摄像机时不拦截，保持原行为）

	@param self table - 播放器实例
	@return boolean - 超过 MAX_DISTANCE 为 true
]]
local function _isTooFarFromCamera(self): boolean
	if not LocalPlayer then
		return false
	end
	local camera = Workspace.CurrentCamera
	if not camera then
		return false
	end
	return (camera.CFrame.Position - self._rootPart.Position).Magnitude > MAX_DISTANCE
end

--[[
	Heartbeat 降频计步：Running 且水平速度达标时按间隔播放

	@param self table - 播放器实例
	@param deltaTime number - 帧间隔（秒）
]]
local function _updateMoveVectorDetection(self, deltaTime: number)
	if self._destroyed or not self._humanoid or not self._rootPart then
		return
	end
	if _shouldSuppressByAnimMarker(self) then
		return
	end

	self._accumulatedDeltaTime += deltaTime
	if self._accumulatedDeltaTime < SPEED_CHECK_INTERVAL then
		return
	end
	self._accumulatedDeltaTime = 0

	if _isTooFarFromCamera(self) then
		return
	end

	local state = self._humanoid:GetState()
	if state ~= Enum.HumanoidStateType.Running then
		self._lastPlayTime = 0
		return
	end

	local velocity = self._rootPart.AssemblyLinearVelocity
	local moveSpeed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
	if moveSpeed < MIN_SPEED then
		self._lastPlayTime = 0
		return
	end

	self._currentInterval = _calculateStepInterval(moveSpeed)
	local currentTime = time()
	if (currentTime - self._lastPlayTime) >= self._currentInterval then
		_playFootstepSound(self)
		self._lastPlayTime = currentTime
	end
end

--[[
	启动 Heartbeat 计步；已启动则幂等返回

	@param self table - 播放器实例
]]
local function _startMoveVectorDetection(self)
	if self._heartbeatConnection then
		return
	end
	self._lastPlayTime = 0
	self._currentInterval = 0
	self._accumulatedDeltaTime = 0
	self._heartbeatConnection = RunService.Heartbeat:Connect(function(deltaTime)
		_updateMoveVectorDetection(self, deltaTime)
	end)
end

--[[
	断开 Heartbeat

	@param self table - 播放器实例
]]
local function _stopMoveVectorDetection(self)
	if self._heartbeatConnection then
		self._heartbeatConnection:Disconnect()
		self._heartbeatConnection = nil
	end
end

--[[
	记录 FreeFall 起点高度，供落地特效高度差判定

	@param self table - 播放器实例
]]
local function _recordFreefallStart(self)
	if not self._rootPart then
		return
	end
	self._isInFreefall = true
	self._freefallStartHeight = self._rootPart.Position.Y
end

--[[
	清空 FreeFall 记录

	@param self table - 播放器实例
]]
local function _resetFreefall(self)
	self._isInFreefall = false
	self._freefallStartHeight = nil
end

--[[
	是否应播落地特效（高度差 >= MIN_LANDING_EFFECT_HEIGHT）

	@param self table - 播放器实例
	@return boolean - 应播放为 true
]]
local function _shouldPlayLandingEffect(self): boolean
	if not self._isInFreefall or not self._freefallStartHeight or not self._rootPart then
		return false
	end
	return (self._freefallStartHeight - self._rootPart.Position.Y) >= MIN_LANDING_EFFECT_HEIGHT
end

--[[
	在脚底射线命中点播放落地特效

	@param self table - 播放器实例
	@return boolean - 是否成功触发
]]
local function _playLandingEffect(self): boolean
	if not self._rootPart or not FXUtil then
		return false
	end
	local raycastResult = Workspace:Raycast(
		self._rootPart.Position,
		Vector3.new(0, -RAYCAST_DISTANCE, 0),
		self._raycastParams
	)
	if not raycastResult then
		return false
	end
	local ok, err = pcall(function()
		FXUtil.PlayEffect(LANDING_EFFECT_NAME, LANDING_EFFECT_ROTATION + raycastResult.Position, LANDING_EFFECT_EMIT_TIME, LANDING_EFFECT_TYPE)
	end)
	if not ok then
		Log.warn("FootstepSoundModule: 落地特效失败", err)
		return false
	end
	return true
end

--[[
	落地：按材质播 Landed 音，并尝试落地特效

	@param self table - 播放器实例
	@return boolean - 是否成功开始播放落地音
]]
local function _updateLandedSoundByMaterial(self): boolean
	local currentMaterial = _getGroundMaterial(self)
	if not currentMaterial or currentMaterial == Enum.Material.Air then
		_resetFreefall(self)
		return false
	end

	if _shouldPlayLandingEffect(self) then
		_playLandingEffect(self)
	end

	local soundIds = FootstepSoundsConfig.IntervalSounds[currentMaterial]
	if not soundIds or #soundIds == 0 then
		_resetFreefall(self)
		return false
	end

	local randomSoundId = soundIds[math.random(1, #soundIds)]
	local sound = _getOrCreatePooledSound(self, self._landedSoundPools, "Landed_", currentMaterial, randomSoundId, LANDED_VOLUME)
	if not sound then
		_resetFreefall(self)
		return false
	end
	sound:Play()
	_resetFreefall(self)
	return true
end

--[[
	Humanoid 状态：记录 Freefall，落地时播音

	@param self table - 播放器实例
	@param oldState Enum.HumanoidStateType - 旧状态
	@param newState Enum.HumanoidStateType - 新状态
]]
local function _onHumanoidStateChanged(self, oldState, newState)
	if newState == Enum.HumanoidStateType.Freefall then
		_recordFreefallStart(self)
	end
	if oldState == Enum.HumanoidStateType.Freefall and newState == Enum.HumanoidStateType.Landed then
		_updateLandedSoundByMaterial(self)
	end
end

-- ============================================================================
-- 公共函数
-- ============================================================================

--[[
	为角色创建脚步播放器；Rig 超时则返回 nil

	@param character Model - 玩家角色模型
	@return table? - 播放器实例；Humanoid / HRP 等待超时或类型不符时 nil
]]
function FootstepSoundModule.new(character)
	if typeof(character) ~= "Instance" or not character:IsA("Model") then
		return nil
	end

	local humanoid = character:WaitForChild("Humanoid", RIG_WAIT_TIMEOUT)
	if not character.Parent or not humanoid or not humanoid:IsA("Humanoid") then
		Log.warn("FootstepSoundModule: 等待 Humanoid 超时或角色已移除", character.Name)
		return nil
	end

	local rootPart = character:WaitForChild("HumanoidRootPart", RIG_WAIT_TIMEOUT)
	if not character.Parent or not rootPart or not rootPart:IsA("BasePart") then
		Log.warn("FootstepSoundModule: 等待 HumanoidRootPart 超时或角色已移除", character.Name)
		return nil
	end

	_muteDefaultLocomotionSound(rootPart, DEFAULT_RUNNING_SOUND_NAME)
	_muteDefaultLocomotionSound(rootPart, DEFAULT_LANDING_SOUND_NAME)

	local filterInstances = {}
	local living = Workspace:FindFirstChild(CHARACTERS_FOLDER_NAME)
	if living then
		table.insert(filterInstances, living)
	end

	local self = setmetatable({}, FootstepSoundModule)
	self._destroyed = false
	self._humanoid = humanoid
	self._rootPart = rootPart
	self._footStepGroup = _getFootStepSoundGroup()
	self._raycastParams = RayCast.GetRayCastParams("All", {
		filterType = Enum.RaycastFilterType.Exclude,
		instances = filterInstances,
	})
	self._materialSoundPools = {}
	self._landedSoundPools = {}
	self._playingSounds = {}
	self._soundConnections = {}
	self._heartbeatConnection = nil
	self._stateConnection = nil
	self._currentInterval = 0
	self._lastPlayTime = 0
	self._accumulatedDeltaTime = 0
	self._freefallStartHeight = nil
	self._isInFreefall = false

	self._stateConnection = humanoid.StateChanged:Connect(function(oldState, newState)
		_onHumanoidStateChanged(self, oldState, newState)
	end)
	_startMoveVectorDetection(self)

	return self
end

--[[
	销毁播放器：断连接、停播并销毁全部 Sound（幂等）
]]
function FootstepSoundModule:destroy()
	if self._destroyed then
		return
	end
	self._destroyed = true

	_stopMoveVectorDetection(self)
	if self._stateConnection then
		self._stateConnection:Disconnect()
		self._stateConnection = nil
	end
	for _, conn in ipairs(self._soundConnections) do
		conn:Disconnect()
	end
	table.clear(self._soundConnections)

	for _, sound in ipairs(self._playingSounds) do
		if sound and sound.Parent then
			sound:Destroy()
		end
	end
	_destroySoundPools(self._materialSoundPools)
	_destroySoundPools(self._landedSoundPools)

	self._humanoid = nil
	self._rootPart = nil
	self._footStepGroup = nil
	self._raycastParams = nil
	self._materialSoundPools = {}
	self._landedSoundPools = {}
	self._playingSounds = {}
	self._freefallStartHeight = nil
	self._isInFreefall = false
end

return FootstepSoundModule
