--[[
	Module: TraumaNoise
	Description: Trauma 相机震动噪声采样（位置/旋转六轴独立 Perlin），供 CameraModule 每帧驱动
	Author: 林奥宇
	Created: 2026-07-31
	Last Modified: 2026-08-31

	功能：
	- 按噪声时间种子与相位偏移，分别采样位置三轴与旋转三轴（约 -0.25~0.25）
	- 六轴使用不同噪声域，避免位姿同相位相关
	- 无状态纯函数，不持有 Trauma / Kick

	使用：
	local TraumaNoise = require(script.Parent.TraumaNoise)
	local posSample, rotSample = TraumaNoise.Sample(noiseTick, seed)
]]

local TraumaNoise = {}

local NOISE = math.noise

-- 各轴噪声域偏移（质数间隔，降低相关性）
local POS_SEED_Y = 17
local POS_SEED_Z = 31
local ROT_SEED_X = 47
local ROT_SEED_Y = 67
local ROT_SEED_Z = 89

--[[
	按噪声时间种子采样位置与旋转六轴偏移
	@param noiseTick number - 噪声时间种子（由调用方按 roughness * dt 推进）
	@param seed number - 层相位偏移（不同震动事件应不同，避免同步）
	@return Vector3 - 位置分轴噪声；math.noise≈±0.5 再 ×0.5，约 -0.25~0.25
	@return Vector3 - 旋转分轴噪声，约 -0.25~0.25
]]
function TraumaNoise.Sample(noiseTick: number, seed: number): (Vector3, Vector3)
	local t = noiseTick
	local s = seed
	local pos = Vector3.new(
		NOISE(t, s) * 0.5,
		NOISE(t, s + POS_SEED_Y) * 0.5,
		NOISE(t, s + POS_SEED_Z) * 0.5
	)
	local rot = Vector3.new(
		NOISE(t, s + ROT_SEED_X) * 0.5,
		NOISE(t, s + ROT_SEED_Y) * 0.5,
		NOISE(t, s + ROT_SEED_Z) * 0.5
	)
	return pos, rot
end

return TraumaNoise