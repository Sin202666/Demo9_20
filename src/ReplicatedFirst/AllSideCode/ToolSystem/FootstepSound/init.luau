--[[
	Module: FootstepSound
	Description: 按地面材质替换 Running / Landed 的 SoundId
	Author: 林奥宇
	Created: 2026-07-03
	Last Modified: 2026-08-31

	功能：
	- new：绑定 Humanoid / Root / Running / Landed
	- UpdateSoundByMaterial / UpdateLandedSoundByMaterial：按 FloorMaterial 换 id
	- destroy：断开引用

	与相关模块的关系：
	- 材质 id 表在同目录 FootstepSoundsConfig
	- 角色脚步编排走 FootStepManager / FootstepSoundModule，本模块是简单 Running 替换方案

	加载方式：
		local FootstepSound = require(script)
		local inst = FootstepSound.new(humanoid, rootPart, runningSound, landedSound)
		inst:destroy()
]]

local FootstepSoundsConfig = require(script.FootstepSoundsConfig)

local FootstepSound = {}
FootstepSound.__index = FootstepSound

--[[
	创建脚步声音播放器
	@param humanoid Humanoid - 角色的 Humanoid 对象
	@param rootPart BasePart - 角色根部位，用于声音位置
	@param runningSound Sound - Running 声音对象
	@param landedSound Sound? - Landed 声音对象，可空
	@return FootstepSound - 播放器实例
]]
function FootstepSound.new(humanoid, rootPart, runningSound, landedSound)
	local self = setmetatable({}, FootstepSound)

	self.humanoid = humanoid
	self.rootPart = rootPart
	self.runningSound = runningSound
	self.landedSound = landedSound
	self.lastMaterial = nil

	return self
end

--[[
	根据材质替换 Running 声音的 SoundId（用于走路时）
	@return boolean - 是否成功替换
]]
function FootstepSound:UpdateSoundByMaterial()
	if not self.runningSound then
		return false
	end

	local currentMaterial = self.humanoid.FloorMaterial

	if currentMaterial == Enum.Material.Air then
		return false
	end

	if currentMaterial == self.lastMaterial then
		return false
	end

	local soundIds = FootstepSoundsConfig.IntervalSounds[currentMaterial]

	if not soundIds or #soundIds == 0 then
		return false
	end

	local randomSoundId = soundIds[math.random(1, #soundIds)]

	self.runningSound.SoundId = randomSoundId

	if self.runningSound.IsPlaying then
		self.runningSound:Stop()
	end

	self.runningSound:Play()

	self.lastMaterial = currentMaterial

	return true
end

--[[
	根据材质替换 Landed 声音的 SoundId（用于落地时）
	@return boolean - 是否成功替换
]]
function FootstepSound:UpdateLandedSoundByMaterial()
	if not self.landedSound then
		return false
	end

	local currentMaterial = self.humanoid.FloorMaterial

	if currentMaterial == Enum.Material.Air then
		return false
	end

	local soundIds = FootstepSoundsConfig.IntervalSounds[currentMaterial]

	if not soundIds or #soundIds == 0 then
		return false
	end

	local randomSoundId = soundIds[math.random(1, #soundIds)]

	self.landedSound.SoundId = randomSoundId

	return true
end

--[[
	清理引用，便于 GC
]]
function FootstepSound:destroy()
	self.humanoid = nil
	self.rootPart = nil
	self.runningSound = nil
	self.landedSound = nil
end

return FootstepSound
