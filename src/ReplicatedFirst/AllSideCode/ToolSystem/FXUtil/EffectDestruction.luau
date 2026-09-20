--[[
	Module: FXUtil/EffectDestruction
	Description: 特效缓慢销毁与消失
	Author: LinAoyu
	Created: 2024-01-01
	Last Modified: 2026-07-02
]]

return function(FXUtil)

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
-- ============================================
-- 特效销毁函数 (Effect Destruction Functions)
-- ============================================

--[[
	缓慢删除特效组件（带淡出动画，最后销毁）
	
	@param instance Instance|Model - 要删除的实例
	@param slowTime number? - 淡出时间（可选，默认0.25，如果未指定会自动计算）
--]]
function FXUtil.Slow_Destroy_Instance(instance, slowTime: number?)
	FXUtil.Stop_All_Emit(instance)

	local instanceVt = instance:GetDescendants()
	table.insert(instanceVt, instance)
	local slowTimeValue = slowTime or 0.25

	-- 如果未指定时间，自动计算所需时间
	if not slowTime then
		for _, descendant in pairs(instanceVt) do
			if descendant:IsA("ParticleEmitter") then
				descendant.Enabled = false
				slowTimeValue = math.max(slowTimeValue, descendant.Lifetime.Max)
			elseif descendant:IsA("Trail") then
				descendant.Enabled = false
				slowTimeValue = math.max(slowTimeValue, descendant.Lifetime)
			end
		end
	end

	-- 对各个组件应用淡出动画
	for _, descendant in pairs(instanceVt) do
		if descendant:IsA("Light") then
			TweenService:Create(descendant, TweenInfo.new(slowTimeValue), {
				Brightness = 0
			}):Play()
		elseif descendant:IsA("Sound") then
			TweenService:Create(descendant, TweenInfo.new(slowTimeValue), {
				Volume = 0
			}):Play()
		elseif descendant:IsA("Beam") then
			TweenService:Create(descendant, TweenInfo.new(slowTimeValue), {
				Width0 = 0,
				Width1 = 0
			}):Play()
		elseif descendant:IsA("ImageLabel") then
			TweenService:Create(descendant, TweenInfo.new(slowTimeValue), {
				ImageTransparency = 1
			}):Play()
		elseif descendant:IsA("Decal") then
			TweenService:Create(descendant, TweenInfo.new(slowTimeValue), {
				Transparency = 1
			}):Play()
		elseif descendant:IsA("ParticleEmitter") then
			descendant.Enabled = false
		elseif descendant:IsA("Trail") then
			descendant.Enabled = false

			-- 创建完全透明的透明度序列
			local trans: {NumberSequenceKeypoint} = {}
			for _, keypoint in pairs(descendant.Transparency.Keypoints) do
				table.insert(trans, NumberSequenceKeypoint.new(keypoint.Time, 1, 0))
			end
			local transSequence = NumberSequence.new(trans)

			FXUtil.Beam_Object_Fade(descendant, slowTimeValue, transSequence, Enum.EasingStyle.Linear, Enum.EasingDirection.In)
		end
	end

	-- 如果是BasePart，淡出透明度
	if instance:IsA("BasePart") then
		TweenService:Create(instance, TweenInfo.new(slowTimeValue), {
			Transparency = 1
		}):Play()
	end

	-- 延迟销毁
	Debris:AddItem(instance, slowTimeValue + 0.5)
end

--[[
	缓慢消失特效组件（带淡出动画，但不销毁）
	
	@param instance Instance|Model - 要消失的实例
	@param slowTime number? - 淡出时间（可选，默认0.25，如果未指定会自动计算）
--]]
function FXUtil.Slow_Disapear_Instance(instance, slowTime: number?)
	FXUtil.Stop_All_Emit(instance)

	local instanceVt = instance:GetDescendants()
	table.insert(instanceVt, instance)
	local slowTimeValue = slowTime or 0.25

	-- 如果未指定时间，自动计算所需时间
	if not slowTime then
		for _, descendant in pairs(instanceVt) do
			if descendant:IsA("ParticleEmitter") then
				descendant.Enabled = false
				slowTimeValue = math.max(slowTimeValue, descendant.Lifetime.Max)
			elseif descendant:IsA("Trail") then
				descendant.Enabled = false
				slowTimeValue = math.max(slowTimeValue, descendant.Lifetime)
			end
		end
	end

	-- 对各个组件应用淡出动画
	for _, descendant in pairs(instanceVt) do
		if descendant:IsA("Light") then
			TweenService:Create(descendant, TweenInfo.new(slowTimeValue), {
				Brightness = 0
			}):Play()
		elseif descendant:IsA("Sound") then
			TweenService:Create(descendant, TweenInfo.new(slowTimeValue), {
				Volume = 0
			}):Play()
		elseif descendant:IsA("Beam") then
			TweenService:Create(descendant, TweenInfo.new(slowTimeValue), {
				Width0 = 0,
				Width1 = 0
			}):Play()
		elseif descendant:IsA("ImageLabel") then
			TweenService:Create(descendant, TweenInfo.new(slowTimeValue), {
				ImageTransparency = 1
			}):Play()
		elseif descendant:IsA("Decal") then
			TweenService:Create(descendant, TweenInfo.new(slowTimeValue), {
				Transparency = 1
			}):Play()
		elseif descendant:IsA("ParticleEmitter") then
			descendant.Enabled = false
		elseif descendant:IsA("Trail") then
			-- 创建完全透明的透明度序列
			local trans: {NumberSequenceKeypoint} = {}
			for _, keypoint in pairs(descendant.Transparency.Keypoints) do
				table.insert(trans, NumberSequenceKeypoint.new(keypoint.Time, 1, 0))
			end
			local transSequence = NumberSequence.new(trans)

			FXUtil.Beam_Object_Fade(descendant, slowTimeValue, transSequence, Enum.EasingStyle.Linear, Enum.EasingDirection.In)
		end
	end

	-- 如果是BasePart，淡出透明度
	if instance:IsA("BasePart") then
		TweenService:Create(instance, TweenInfo.new(slowTimeValue), {
			Transparency = 1
		}):Play()
	end
end
end