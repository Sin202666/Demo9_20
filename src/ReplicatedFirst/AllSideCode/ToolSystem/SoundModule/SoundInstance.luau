--[[
	Module: SoundModule/SoundInstance
	Description: 声音实例生命周期管理（2D/3D 播放、标签索引、音效组控制）
	Author: 林奥宇
	Created: 2026-01-19
	Last Modified: 2026-09-01

	功能：
	- 按 SoundData 创建/复用声音实例（SoundTag 去重）
	- 2D 挂 ReplicatedStorage/Sound2D；3D 挂 workspace/Sound3D 透明 Part
	- 渐入渐出播放/停止；非循环音 Ended 后归还 Sound / 3D 宿主池（循环音仍 Destroy）
	- 按标签/名称查询；调节 SoundGroup 音量与播放速度倍率

	何时使用：
	- UI / 命中等一次性音效 → 优先 SoundModule:PlaySoundLocal / PlaySound（经 SoundManager）
	- 循环 BGM、需手动复播或精确停某个实例 → 本模块 :new + :playSound / :stopSound
	- 设置面板调 BGM/EFFECT 组音量 → SetSoundGroupVolume
	实例方法保持历史 camelCase（playSound / stopSound / destroy / setPlaySpeed），
	模块查询/组控为 PascalCase（GetSoundByTag 等），调用方勿混用。

	加载方式：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local SoundInstance = Utils.SoundInstance

	端侧约束：
	- 仅客户端可用（创建 Folder / Sound / Part）。服务端 require 或调用会 warn 并返回 nil。
	- IsClient 仅作运行时守卫，不含双端业务分支。
	- 3D 须 Is2D = false，并提供 PlayPosition 或 AttachPart 之一。

	使用示例：
		local bgm = SoundInstance:new({ SoundName = "BGM1", SoundTag = "MainBGM", Is2D = true })
		bgm:playSound(1)
		bgm:stopSound(1)
		SoundInstance:SetSoundGroupVolume("EFFECT", 0.5, 0.5)

	副作用：
	- 首次客户端就绪时创建 Sound2D / Sound3D / SoundPool 文件夹，并索引 SoundService 下 Sound 模板
	- 播放时优先从池取 Sound / 3D 宿主；池空再 Clone / Instance.new
	- 非循环 destroy：归还池（有上限）；循环音或池满仍 Destroy，并从标签表移除
]]

-- ============================================================================
-- 服务引用 / 模块引用
-- ============================================================================

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local RunService = Utils.RunService
local SoundService = Utils.SoundService
local TweenService = Utils.TweenService
local ReplicatedStorage = Utils.ReplicatedStorage
local ResRestore = Utils.ResRestore
local Log = Utils.Log

-- ============================================================================
-- 模块定义
-- ============================================================================

local SoundInstance = {}
SoundInstance.__index = SoundInstance

-- ============================================================================
-- 类型
-- ============================================================================

type SoundData = {
	SoundName: string,
	SoundTag: string?,
	Is2D: boolean?,
	Volume: number?,
	AttachPart: BasePart?,
	PlayPosition: Vector3?,
}

type SoundInstanceObject = {
	sound: Sound?,
	oriVolume: number,
	soundName: string,
	soundTag: string,
	oriPlaySpeed: number,
	playSpeed: number,
	is2D: boolean,
	playPosition: Vector3?,
	parentPart: BasePart?,
	_activeTween: Tween?,
}

-- ============================================================================
-- 常量
-- ============================================================================

local DEFAULT_FADE_TIME = 0.1
local DEFAULT_GROUP_FADE_TIME = 0
local DEFAULT_GROUP_PLAY_SPEED = 1
local DEFAULT_IS_2D = true
local FOLDER_NAME_2D = "Sound2D"
local FOLDER_NAME_3D = "Sound3D"
local FOLDER_NAME_POOL = "SoundPool"
local ATTR_SOUND_TAG = "SoundTag"
local ATTR_PLAY_SPEED = "PlaySpeed"
local HIDDEN_TRANSPARENCY = 1
local HOST_POOL_CAP = 32
local SOUND_POOL_CAP_PER_NAME = 8

-- ============================================================================
-- 私有变量
-- ============================================================================

local _allSoundList: { [string]: SoundInstanceObject } = {}
local _soundDefaultTag = 0
local _soundTemplateCache: { [string]: Sound } = {}
local _soundFolder2D: Folder = nil :: any
local _soundFolder3D: Folder = nil :: any
local _soundFolderPool: Folder = nil :: any
local _idle3DHosts: { BasePart } = {}
local _idleSounds: { [string]: { Sound } } = {}
local _groupVolumeTweens: { [string]: Tween } = {}
local _isClientReady = false

-- ============================================================================
-- 私有函数
-- ============================================================================

--[[
	把 SoundService 下所有 Sound 写入名称缓存，并把直接挂在 SoundGroup 下的模板绑到该组
	@return nil
]]
local function _indexSoundTemplates()
	table.clear(_soundTemplateCache)
	for _, inst in SoundService:GetDescendants() do
		if inst:IsA("Sound") then
			_soundTemplateCache[inst.Name] = inst
		end
	end
	for _, soundGroup in SoundService:GetChildren() do
		if soundGroup:IsA("SoundGroup") then
			for _, sound in soundGroup:GetChildren() do
				if sound:IsA("Sound") then
					sound.SoundGroup = soundGroup
				end
			end
		end
	end
end

--[[
	确保仅在客户端初始化运行时环境（Folder + 模板索引）；重复调用直接返回 true
	@return boolean - true 表示已在客户端且目录就绪；服务端 false
]]
local function _ensureClientReady(): boolean
	if not RunService:IsClient() then
		Log.warn("SoundInstance 仅客户端可用")
		return false
	end

	if _isClientReady then
		return true
	end

	_soundFolder2D = Instance.new("Folder")
	_soundFolder2D.Name = FOLDER_NAME_2D
	_soundFolder2D.Parent = ReplicatedStorage

	_soundFolder3D = Instance.new("Folder")
	_soundFolder3D.Name = FOLDER_NAME_3D
	_soundFolder3D.Parent = workspace

	_soundFolderPool = Instance.new("Folder")
	_soundFolderPool.Name = FOLDER_NAME_POOL
	_soundFolderPool.Parent = ReplicatedStorage

	_indexSoundTemplates()

	_isClientReady = true
	return true
end

--[[
	从 SoundService 克隆指定名称的 Sound 模板（带缓存；模板被销毁时重扫）
	@param soundName string - 模板 Instance.Name，须与 SoundService 内 Sound 一致
	@return Sound? - 已 Restore 的克隆；找不到模板时 nil
]]
local function _cloneSound(soundName: string): Sound?
	local template = _soundTemplateCache[soundName]
	if not template or not template.Parent then
		template = nil
		_soundTemplateCache[soundName] = nil
		for _, sound in SoundService:GetDescendants() do
			if sound:IsA("Sound") and sound.Name == soundName then
				template = sound
				_soundTemplateCache[soundName] = template
				break
			end
		end
	end

	if not template then
		return nil
	end

	ResRestore.Restore(template)
	return template:Clone()
end

--[[
	从空闲池取出仍挂在树上的 Sound；已销毁引用会被丢掉
	@param soundName string - 模板 Name
	@return Sound? - 可复用实例；池空时 nil
]]
local function _takeIdleSound(soundName: string): Sound?
	local list = _idleSounds[soundName]
	if not list then
		return nil
	end
	while #list > 0 do
		local sound = table.remove(list) :: Sound
		if sound and sound.Parent then
			return sound
		end
	end
	return nil
end

--[[
	借出 Sound：优先空闲池，否则 Clone 模板
	@param soundName string - 模板 Name
	@return Sound? - 已 Stop、TimePosition=0；无模板时 nil
]]
local function _acquireSound(soundName: string): Sound?
	local sound = _takeIdleSound(soundName)
	if sound then
		sound:Stop()
		sound.TimePosition = 0
		sound:SetAttribute(ATTR_SOUND_TAG, nil)
		return sound
	end
	return _cloneSound(soundName)
end

--[[
	归还非循环 Sound 到池；同名超过上限则 Destroy
	@param sound Sound - 已 Stop 的实例
	@param soundName string - 池键
	@return nil
]]
local function _releaseSound(sound: Sound, soundName: string)
	sound:Stop()
	sound.TimePosition = 0
	sound:SetAttribute(ATTR_SOUND_TAG, nil)
	sound.Parent = _soundFolderPool

	local list = _idleSounds[soundName]
	if not list then
		list = {}
		_idleSounds[soundName] = list
	end
	if #list >= SOUND_POOL_CAP_PER_NAME then
		sound:Destroy()
		return
	end
	table.insert(list, sound)
end

--[[
	从空闲池取出仍挂在 Sound3D 下的宿主 Part
	@return BasePart? - 可复用宿主；池空时 nil
]]
local function _takeIdle3DHost(): BasePart?
	while #_idle3DHosts > 0 do
		local part = table.remove(_idle3DHosts) :: BasePart
		if part and part.Parent then
			return part
		end
	end
	return nil
end

--[[
	复位 3D 宿主：清 Weld、设隐身物理、可选焊到 AttachPart
	@param soundPart BasePart - 宿主
	@param soundName string - Part.Name
	@param playPosition Vector3? - 无跟随时的世界坐标
	@param attachPart BasePart? - 若提供则 Weld 跟随
	@return nil
]]
local function _reset3DHostPart(soundPart: BasePart, soundName: string, playPosition: Vector3?, attachPart: BasePart?)
	for _, child in soundPart:GetChildren() do
		if child:IsA("WeldConstraint") then
			child:Destroy()
		end
	end

	soundPart.Name = soundName
	soundPart.Transparency = HIDDEN_TRANSPARENCY
	soundPart.CanCollide = false
	soundPart.CanQuery = false
	soundPart.CanTouch = false
	soundPart.Massless = true
	soundPart.AssemblyLinearVelocity = Vector3.zero
	soundPart.AssemblyAngularVelocity = Vector3.zero
	if playPosition then
		soundPart.CFrame = CFrame.new(playPosition)
	end
	soundPart.Parent = _soundFolder3D

	if attachPart then
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = soundPart
		weld.Part1 = attachPart
		weld.Parent = soundPart
		soundPart.Anchored = false
	else
		soundPart.Anchored = true
	end
end

--[[
	归还 3D 宿主；池满则 Destroy
	@param soundPart BasePart - 宿主 Part
	@return nil
]]
local function _release3DHost(soundPart: BasePart)
	for _, child in soundPart:GetChildren() do
		if child:IsA("WeldConstraint") then
			child:Destroy()
		end
	end
	soundPart.Anchored = true
	soundPart.AssemblyLinearVelocity = Vector3.zero
	soundPart.AssemblyAngularVelocity = Vector3.zero
	soundPart.Parent = _soundFolder3D
	if #_idle3DHosts >= HOST_POOL_CAP then
		soundPart:Destroy()
		return
	end
	table.insert(_idle3DHosts, soundPart)
end

--[[
	取消实例上正在进行的音量 Tween（Cancel 会触发 Completed，调用方须按 PlaybackState 忽略）
	@param instance SoundInstanceObject - 声音实例；无 _activeTween 时无操作
	@return nil
]]
local function _cancelActiveTween(instance: SoundInstanceObject)
	if instance._activeTween then
		instance._activeTween:Cancel()
		instance._activeTween = nil
	end
end

--[[
	借出 3D 透明宿主 Part（池优先），可选 Weld 到 AttachPart
	@param soundName string - 用作 Part.Name，便于调试
	@param playPosition Vector3? - 无跟随部件时的世界坐标；nil 则保持默认位置
	@param attachPart BasePart? - 若提供则 Weld 跟随，并取消 Anchored
	@return BasePart - 已挂到 Sound3D 文件夹的宿主 Part
]]
local function _acquire3DHostPart(soundName: string, playPosition: Vector3?, attachPart: BasePart?): BasePart
	local soundPart = _takeIdle3DHost()
	if not soundPart then
		soundPart = Instance.new("Part")
		soundPart.Anchored = true
	end
	_reset3DHostPart(soundPart, soundName, playPosition, attachPart)
	return soundPart
end

--[[
	取消指定音效组上一次未完成的音量 Tween，避免重叠插值抢写 Volume
	@param soundGroupName string - SoundService 下 SoundGroup.Name
	@return nil
]]
local function _cancelGroupVolumeTween(soundGroupName: string)
	local prev = _groupVolumeTweens[soundGroupName]
	if prev then
		prev:Cancel()
		_groupVolumeTweens[soundGroupName] = nil
	end
end

-- ============================================================================
-- 实例方法 — 生命周期
-- ============================================================================

--[[
	创建新声音实例；同一 SoundTag 已存在则返回该实例，不重复借出
	@param soundData SoundData - 须含非空 SoundName；SoundTag 缺省时按名称+序号生成
	@return SoundInstanceObject? - 新实例或已有实例；客户端未就绪 / 缺名 / 无模板时 nil
]]
function SoundInstance:new(soundData: SoundData): SoundInstanceObject?
	if not _ensureClientReady() then
		return nil
	end

	if type(soundData) ~= "table" then
		Log.warn("SoundInstance.new: soundData 无效")
		return nil
	end

	local soundName = soundData.SoundName
	if type(soundName) ~= "string" or soundName == "" then
		Log.warn("SoundInstance.new: SoundName 无效")
		return nil
	end

	local soundTag = soundData.SoundTag
	if type(soundTag) ~= "string" or soundTag == "" then
		soundTag = soundName .. tostring(_soundDefaultTag)
		_soundDefaultTag += 1
	end

	local existing = SoundInstance:GetSoundByTag(soundTag)
	if existing then
		return existing
	end

	local sound = _acquireSound(soundName)
	if not sound then
		Log.warn(soundName, "Sound 文件未找到，无法播放音效")
		return nil
	end

	local is2D: boolean = if soundData.Is2D == nil then DEFAULT_IS_2D else soundData.Is2D
	local attachPart: BasePart? = soundData.AttachPart
	local playPosition: Vector3? = soundData.PlayPosition

	local self = setmetatable({}, SoundInstance) :: SoundInstanceObject
	self.sound = sound
	self.oriVolume = if soundData.Volume then soundData.Volume else sound.Volume
	self.sound.Volume = self.oriVolume
	self.soundName = soundName
	self.soundTag = soundTag
	self.oriPlaySpeed = sound.PlaybackSpeed
	self.playSpeed = self.oriPlaySpeed
	self.is2D = is2D
	self.playPosition = playPosition
	self.parentPart = nil
	self._activeTween = nil

	if is2D then
		sound.Parent = _soundFolder2D
	else
		local soundPart = _acquire3DHostPart(soundName, playPosition, attachPart)
		sound.Parent = soundPart
		self.parentPart = soundPart
	end

	sound:SetAttribute(ATTR_SOUND_TAG, soundTag)
	_allSoundList[soundTag] = self
	return self
end

--[[
	播放声音：从 0 渐入到 oriVolume；非循环音 Ended 后自动 destroy
	@param fadeInTime number? - 渐入秒数；nil 时用 DEFAULT_FADE_TIME（0.1）
	@return nil
]]
function SoundInstance:playSound(fadeInTime: number?)
	if not self.sound then
		return
	end

	fadeInTime = fadeInTime or DEFAULT_FADE_TIME
	_cancelActiveTween(self)

	self.sound.Volume = 0
	self.sound:Play()

	local tween = TweenService:Create(
		self.sound,
		TweenInfo.new(fadeInTime),
		{ Volume = self.oriVolume }
	)
	self._activeTween = tween
	tween:Play()

	if not self.sound.Looped then
		self.sound.Ended:Once(function()
			self:destroy()
		end)
	end
end

--[[
	停止声音：渐隐到 0 后 Stop；仅当 Tween 完整结束才销毁/停播（Cancel 不处理）
	@param fadeTime number? - 渐出秒数；nil 时用 DEFAULT_FADE_TIME（0.1）
	@param destroyAfter boolean? - nil 时非循环 true、循环 false；true 强制销毁
	@return nil
]]
function SoundInstance:stopSound(fadeTime: number?, destroyAfter: boolean?)
	if not self.sound then
		return
	end

	fadeTime = fadeTime or DEFAULT_FADE_TIME
	if destroyAfter == nil then
		destroyAfter = not self.sound.Looped
	end

	_cancelActiveTween(self)

	local tween = TweenService:Create(
		self.sound,
		TweenInfo.new(fadeTime),
		{ Volume = 0 }
	)
	self._activeTween = tween
	tween.Completed:Once(function(playbackState)
		if self._activeTween == tween then
			self._activeTween = nil
		end
		if playbackState ~= Enum.PlaybackState.Completed then
			return
		end
		if self.sound then
			self.sound:Stop()
		end
		if destroyAfter then
			self:destroy()
		end
	end)
	tween:Play()
end

--[[
	结束声音实例：停播并从标签表移除。非循环音归还 Sound / 3D 宿主池；循环音 Destroy
	@return nil
]]
function SoundInstance:destroy()
	_cancelActiveTween(self)

	local sound = self.sound
	local parentPart = self.parentPart
	local shouldPool = sound ~= nil and not sound.Looped

	if sound then
		sound:Stop()
		if shouldPool then
			_releaseSound(sound, self.soundName)
		else
			sound:Destroy()
		end
		self.sound = nil
	end
	if parentPart then
		if shouldPool then
			_release3DHost(parentPart)
		else
			parentPart:Destroy()
		end
		self.parentPart = nil
	end
	if self.soundTag then
		_allSoundList[self.soundTag] = nil
	end
end

--[[
	兼容旧 API：等价于 destroy()
	@return nil
]]
function SoundInstance:destroySound()
	self:destroy()
end

--[[
	设置当前实例播放速度（同时写入 PlaybackSpeed）
	@param playSpeed number - 绝对播放速度，1 为模板原速
	@return nil
]]
function SoundInstance:setPlaySpeed(playSpeed: number)
	if not self.sound then
		return
	end
	self.playSpeed = playSpeed
	self.sound.PlaybackSpeed = playSpeed
end

-- ============================================================================
-- 模块方法 — 查询与音效组
-- ============================================================================

--[[
	根据标签查找声音实例（返回运行时实例，供 stop/play 控制，不是配置表）
	@param soundTag string - 创建时指定或自动生成的 SoundTag
	@return SoundInstanceObject? - 活跃实例；无标签或未找到时 nil
]]
function SoundInstance:GetSoundByTag(soundTag: string): SoundInstanceObject?
	if type(soundTag) ~= "string" or soundTag == "" then
		return nil
	end
	return _allSoundList[soundTag]
end

--[[
	根据声音名称收集所有活跃实例（新表，元素仍是运行时实例）
	@param soundName string - 与 SoundData.SoundName 一致
	@return { SoundInstanceObject } - 匹配列表；无名时空表
]]
function SoundInstance:GetSoundByName(soundName: string): { SoundInstanceObject }
	local soundList = {}
	if type(soundName) ~= "string" or soundName == "" then
		return soundList
	end

	for _, instance in _allSoundList do
		if instance.soundName == soundName then
			table.insert(soundList, instance)
		end
	end
	return soundList
end

--[[
	设置音效组音量；同组未完成的渐变会被取消（后写覆盖）
	@param soundGroupName string - SoundService 下 SoundGroup.Name（如 BGM / EFFECT）
	@param volume number - 目标音量
	@param fadeTime number? - 渐变秒数；nil 或 <=0 时立即设置
	@return nil
]]
function SoundInstance:SetSoundGroupVolume(soundGroupName: string, volume: number, fadeTime: number?)
	fadeTime = fadeTime or DEFAULT_GROUP_FADE_TIME
	local soundGroup = SoundService:FindFirstChild(soundGroupName)
	if not soundGroup or not soundGroup:IsA("SoundGroup") then
		return
	end

	_cancelGroupVolumeTween(soundGroupName)

	if fadeTime <= 0 then
		soundGroup.Volume = volume
		return
	end

	local tween = TweenService:Create(
		soundGroup,
		TweenInfo.new(fadeTime),
		{ Volume = volume }
	)
	_groupVolumeTweens[soundGroupName] = tween
	tween.Completed:Once(function()
		if _groupVolumeTweens[soundGroupName] == tween then
			_groupVolumeTweens[soundGroupName] = nil
		end
	end)
	tween:Play()
end

--[[
	按各实例原始速度设置音效组内活跃实例的播放倍率，避免累乘
	@param soundGroupName string - SoundService 下 SoundGroup.Name
	@param playSpeed number? - 倍率；nil 时视为 1
	@return nil
]]
function SoundInstance:SetSoundGroupPlaySpeed(soundGroupName: string, playSpeed: number?)
	if not playSpeed then
		playSpeed = DEFAULT_GROUP_PLAY_SPEED
	end

	local soundGroup = SoundService:FindFirstChild(soundGroupName)
	if not soundGroup or not soundGroup:IsA("SoundGroup") then
		return
	end

	for _, instance in _allSoundList do
		if instance.sound and instance.sound.SoundGroup == soundGroup then
			instance:setPlaySpeed(instance.oriPlaySpeed * playSpeed)
		end
	end

	soundGroup:SetAttribute(ATTR_PLAY_SPEED, playSpeed)
end

return SoundInstance
