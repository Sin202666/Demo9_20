--[[
	Module: FXUtil/ParticleScale
	Description: 粒子缩放与数字筛选
	Author: LinAoyu
	Created: 2024-01-01
	Last Modified: 2026-07-02
]]

return function(FXUtil)

-- ============================================
-- 粒子发射器相关函数 (Particle Emitter Functions)
-- ============================================

--[[
	数字筛选器（检查数字是否能被间隔整除）
	
	@param num number - 要检查的数字
	@param interval number - 间隔值
	@return boolean, number - 是否整除，下一个数字
--]]
function FXUtil.Number_Filtrate(num: number, interval: number)
	if num % interval == 0 then
		return true, num + 1
	end
	return false, num + 1
end

--[[
	缩放粒子发射器（缩放所有相关属性）
	
	@param particleEmitter ParticleEmitter|table - 粒子发射器或发射器数组
	@param scale number - 缩放系数
--]]
function FXUtil.Scale_Particle(particleEmitter: ParticleEmitter | {ParticleEmitter}, scale: number)
	if math.abs(scale - 1) < 0.01 then
		return
	end

	-- 转换为数组格式
	if type(particleEmitter) ~= "table" then
		particleEmitter = {particleEmitter}
	end

	for _, particle: ParticleEmitter in pairs(particleEmitter) do
		-- 缩放大小序列
		local newSize = {}
		for _, keypoint in pairs(particle.Size.Keypoints) do
			table.insert(newSize, NumberSequenceKeypoint.new(keypoint.Time, keypoint.Value * scale, keypoint.Envelope * scale))
		end
		particle.Size = NumberSequence.new(newSize)

		-- 缩放其他属性
		particle.Drag = particle.Drag * scale
		particle.VelocityInheritance = particle.VelocityInheritance * scale
		particle.Speed = NumberRange.new(particle.Speed.Min * scale, particle.Speed.Max * scale)
		particle.Acceleration = Vector3.new(
			particle.Acceleration.X * scale,
			particle.Acceleration.Y * scale,
			particle.Acceleration.Z * scale
		)
	end
end

--[[
	仅缩放粒子发射器的大小
	
	@param particleEmitter ParticleEmitter|table - 粒子发射器或发射器数组
	@param scale number - 缩放系数
--]]
function FXUtil.Scale_Particle_Size(particleEmitter: ParticleEmitter | {ParticleEmitter}, scale: number)
	if math.abs(scale - 1) < 0.01 then
		return
	end

	-- 转换为数组格式
	local particleArray: {ParticleEmitter} = {}
	if type(particleEmitter) == "table" then
		particleArray = particleEmitter
	else
		particleArray = {particleEmitter}
	end

	for _, particle: ParticleEmitter in pairs(particleArray) do
		local newSize: {NumberSequenceKeypoint} = {}
		for _, keypoint in pairs(particle.Size.Keypoints) do
			table.insert(newSize, NumberSequenceKeypoint.new(keypoint.Time, keypoint.Value * scale, keypoint.Envelope * scale))
		end
		particle.Size = NumberSequence.new(newSize)
	end
end

end