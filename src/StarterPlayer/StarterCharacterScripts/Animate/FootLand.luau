--[[
	Module: FootLand
	Description: 动画 FootStep Marker 触发的脚步声，以及落地镜头微反馈。
	Author: 林奥宇
	Created: 2026-07-03
	Last Modified: 2026-08-31

	使用：
	- FootLand.FootLand(character, footDir)：由 Animate BaseAnimation MarkerEvents 调用
	- FootLand.OnLanded(character, isHeavyLand)：由 GroundLocomotion 落地时调用

	协作：
	- 本地角色脚步优先由动画 Marker 驱动；FootLand 写入 AnimFootStepAt
	- FootStepManager：Marker 近期已播则跳过速度计步（防双踩）；无 Marker 时仍用速度兜底
	- 落地材质音效仍由 FootStepManager 负责；本模块补镜头微反馈
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local SystemGameConfig = Utils.SystemGameConfig
local FootstepSoundsConfig = Utils.FootstepSoundsConfig
local CameraModule = Utils.CameraModule
local EnumMgr = Utils.EnumMgr
local LocalPlayer = Utils.LocalPlayer
local SoundService = Utils.SoundService

local Setting = require(script.Parent.AnimateSetting)

local FootLand = {}

local FOOTSTEP_VOLUME = 0.1
-- 供 FootStepManager 去重：Marker 刚播过则跳过同帧附近的速度计步
local ANIM_FOOTSTEP_ATTR = "AnimFootStepAt"
local _footSoundPool: { [Model]: { [string]: Sound } } = {}

--[[
	取角色 Humanoid / HRP；缺失则返回 nil
	@param character Model - 角色模型
	@return Humanoid?, BasePart? - 均有效时返回；缺失则双 nil
]]
local function _getHumanoidAndRoot(character: Model): (Humanoid?, BasePart?)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if humanoid and hrp and hrp:IsA("BasePart") then
		return humanoid, hrp
	end
	return nil, nil
end

--[[
	按材质随机取脚步 SoundId；无配置时回退 Concrete / Plastic
	@param material Enum.Material - 地面材质
	@return string? - rbxassetid
]]
local function _pickFootstepSoundId(material: Enum.Material): string?
	local interval = FootstepSoundsConfig and FootstepSoundsConfig.IntervalSounds
	if not interval then
		return nil
	end
	local list = interval[material]
	if (not list or #list == 0) and interval[Enum.Material.Concrete] then
		list = interval[Enum.Material.Concrete]
	end
	if (not list or #list == 0) and interval[Enum.Material.Plastic] then
		list = interval[Enum.Material.Plastic]
	end
	if not list or #list == 0 then
		return nil
	end
	return list[math.random(1, #list)]
end

--[[
	获取或创建挂在 HRP 上的复用 Sound
	@param character Model - 角色
	@param hrp BasePart - 根部件
	@param key string - 池键（foot / land）
	@return Sound - 挂在 HRP 上的复用实例
]]
local function _getOrCreateSound(character: Model, hrp: BasePart, key: string): Sound
	local byChar = _footSoundPool[character]
	if not byChar then
		byChar = {}
		_footSoundPool[character] = byChar
		character.Destroying:Once(function()
			_footSoundPool[character] = nil
		end)
	end
	local sound = byChar[key]
	if sound and sound.Parent then
		return sound
	end
	sound = Instance.new("Sound")
	sound.Name = "AnimateFoot_" .. key
	sound.RollOffMaxDistance = 150
	sound.RollOffMinDistance = 5
	sound.RollOffMode = Enum.RollOffMode.Inverse
	sound.Looped = false
	local footGroup = SoundService:FindFirstChild("FootStep")
	if footGroup and footGroup:IsA("SoundGroup") then
		sound.SoundGroup = footGroup
	end
	sound.Parent = hrp
	byChar[key] = sound
	return sound
end

--[[
	脚步落地 Marker 回调（与动画相位同步）
	@param character Model - 当前角色模型
	@param _footDir string - 动画 Marker 携带的方向/脚别参数字符串
]]
function FootLand.FootLand(character: Model, _footDir: string)
	if SystemGameConfig.GetValue({ "FootStep", "启用" }) == false then
		return
	end
	if not FootstepSoundsConfig then
		return
	end

	local humanoid, hrp = _getHumanoidAndRoot(character)
	if not humanoid or not hrp then
		return
	end
	if humanoid.FloorMaterial == Enum.Material.Air then
		return
	end

	local material = humanoid.FloorMaterial
	local soundId = _pickFootstepSoundId(material)
	if not soundId then
		return
	end

	local volumeMul = 1
	if FootstepSoundsConfig.VolumeMultipliers then
		volumeMul = FootstepSoundsConfig.VolumeMultipliers[material] or 1
	end

	local sound = _getOrCreateSound(character, hrp, "foot")
	if sound.IsPlaying then
		sound:Stop()
	end
	sound.SoundId = soundId
	sound.Volume = FOOTSTEP_VOLUME * volumeMul
	character:SetAttribute(ANIM_FOOTSTEP_ATTR, time())
	sound:Play()
end

--[[
	落地镜头微反馈（重落地可震；轻落地默认关闭以免小落差吵）
	@param character Model - 角色
	@param isHeavyLand boolean - true 为 Land，false 为 LightLand
]]
function FootLand.OnLanded(character: Model, isHeavyLand: boolean)
	local cfg = Setting.LandFeedback
	if not cfg then
		return
	end

	local enabled = if isHeavyLand then cfg.heavyShakeEnabled else cfg.lightShakeEnabled
	if not enabled then
		return
	end

	local shakeType = if isHeavyLand then cfg.heavyShakeType else cfg.lightShakeType
	if type(shakeType) ~= "number" then
		shakeType = EnumMgr.CameraShakeType.Land
	end

	-- 仅本地角色震镜头，避免远端落地误震
	if not LocalPlayer or LocalPlayer.Character ~= character then
		return
	end

	CameraModule.CameraShakeOnce(shakeType)
end

return FootLand
