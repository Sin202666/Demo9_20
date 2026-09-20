--[[
	Module: FXUtil/ModelFade
	Description: 模型与 Beam/Trail 淡入淡出
	Author: LinAoyu
	Created: 2024-01-01
	Last Modified: 2026-07-02
]]

return function(FXUtil)

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local VisibleMgr = Utils.VisibleMgr
-- ============================================
-- 淡入淡出函数 (Fade Functions)
-- ============================================

--[[
	模型逐渐消失（淡出）
	
	@param instance Model - 目标模型
	@param fadeTime number? - 淡出时间（可选，默认0.1）
--]]
function FXUtil.Model_Fade(instance: Model, fadeTime: number?)
	fadeTime = fadeTime or 0.1

	local insVt = instance:GetDescendants()
	table.insert(insVt, instance)

	for _, descendant in pairs(insVt) do
		if descendant:IsA("BasePart") then
			local tween = TweenService:Create(descendant, TweenInfo.new(fadeTime), {Transparency = 1})
			tween:Play()
		end
	end
end

--[[
	模型逐渐显示（淡入）
	
	@param instance Model - 目标模型
	@param fadeTime number? - 淡入时间（可选，默认0.1）
	@param easingStyle Enum.EasingStyle? - 缓动样式（可选，默认Linear）
	@param easingDir Enum.EasingDirection? - 缓动方向（可选，默认In）
	@param transValue number? - 目标透明度（可选，默认0）
--]]
function FXUtil.Model_Fade_In(instance: Model, fadeTime: number?, easingStyle: Enum.EasingStyle?, easingDir: Enum.EasingDirection?, transValue: number?)
	fadeTime = fadeTime or 0.1
	easingStyle = easingStyle or Enum.EasingStyle.Linear
	easingDir = easingDir or Enum.EasingDirection.In

	local instanceVt = instance:GetDescendants()
	table.insert(instanceVt, instance)

	for _, descendant in pairs(instanceVt) do
		if descendant:IsA("BasePart") then
			local newTransparency = transValue or 0
			local tween = TweenService:Create(descendant, TweenInfo.new(fadeTime, easingStyle, easingDir), {Transparency = newTransparency})
			tween:Play()
		end
	end
end

--[[
	Beam/Trail对象渐隐动画
	
	@param beam Beam|Trail - 目标Beam或Trail对象
	@param tweenTime number? - 动画时间（可选，默认0.1）
	@param transparency NumberSequence - 目标透明度序列
	@param easingStyle Enum.EasingStyle? - 缓动样式（可选）
	@param easingDir Enum.EasingDirection? - 缓动方向（可选）
--]]
function FXUtil.Beam_Object_Fade(beam: Beam | Trail, tweenTime: number?, transparency: NumberSequence, easingStyle: Enum.EasingStyle?, easingDir: Enum.EasingDirection?)
	task.spawn(function()
		tweenTime = tweenTime or 0.1

		local oriTrans = beam.Transparency.Keypoints
		local timeline = 0
		local _lastTweenPoint = 0

		while timeline < 1 do
			timeline = math.min(timeline + RunService.Heartbeat:Wait() / tweenTime, 1)
			local tweenPoint = TweenService:GetValue(timeline, easingStyle, easingDir)

			local newTemp: {NumberSequenceKeypoint} = {}
			for index, keypoint in pairs(transparency.Keypoints) do
				local oriValue
				if oriTrans[index] then
					oriValue = oriTrans[index].Value
					local newValue = oriValue + (keypoint.Value - oriValue) * timeline
					local newKeypoint = NumberSequenceKeypoint.new(keypoint.Time, newValue, keypoint.Envelope)
					table.insert(newTemp, newKeypoint)
				end
			end

			if #newTemp > 0 then
				(beam :: any).Transparency = NumberSequence.new(newTemp)
			end
			_lastTweenPoint = tweenPoint
		end
	end)
end
end