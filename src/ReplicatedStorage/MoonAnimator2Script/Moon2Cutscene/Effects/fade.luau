--[[
	淡入淡出效果模块
	创建屏幕淡入淡出效果
	@param fadeInTime: number? - 淡入时间（秒）
	@param stayTime: number? - 停留时间（秒）
	@param fadeOutTime: number? - 淡出时间（秒）
	@param Color: Color3? - 淡入淡出颜色（默认为黑色）
	@return function, ScreenGui - 执行函数和 ScreenGui 实例
]]
return function(fadeInTime: number?, stayTime: number?, fadeOutTime: number?, Color: Color3?): (() -> nil, ScreenGui)
	local fade = Instance.new("ScreenGui")
	fade.Name = "fade_Moon2Cutscene"
	fade.IgnoreGuiInset = true

	local frame = Instance.new("Frame", fade)
	frame.Name = "FadeFrame"
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundTransparency = 1
	frame.BackgroundColor3 = Color or Color3.new(0, 0, 0)

	fade.Parent = game:GetService("Players").LocalPlayer.PlayerGui

	return function()
		-- 淡入
		if fadeInTime then
			game:GetService("TweenService"):Create(frame, TweenInfo.new(fadeInTime), {BackgroundTransparency = 0}):Play()
			task.wait(fadeInTime)
		else
			frame.BackgroundTransparency = 0
		end

		-- 停留
		task.wait(stayTime)

		-- 淡出
		if fadeOutTime then
			game:GetService("TweenService"):Create(frame, TweenInfo.new(fadeOutTime), {BackgroundTransparency = 1}):Play()
		else
			frame.BackgroundTransparency = 1
		end
	end, fade
end