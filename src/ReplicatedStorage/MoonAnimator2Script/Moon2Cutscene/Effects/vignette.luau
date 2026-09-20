--[[
	暗角（Vignette）效果模块
	创建屏幕边缘暗角效果
	@param image: string? - 暗角图片 ID（默认为内置图片）
	@return function, ScreenGui, ImageLabel - 销毁函数、ScreenGui 实例和 ImageLabel 实例
]]
return function(image: string?): (() -> nil, ScreenGui, ImageLabel)
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "vignette_Moon2Cutscene"
	screenGui.ClipToDeviceSafeArea = false
	screenGui.IgnoreGuiInset = true

	local label = Instance.new("ImageLabel")
	label.BackgroundTransparency = 1
	label.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	label.ImageTransparency = .5
	label.Size = UDim2.fromScale(1, 1)
	label.Image = image or "rbxassetid://12175750943"

	label.Parent = screenGui
	screenGui.Parent = game:GetService("Players").LocalPlayer.PlayerGui

	return function()
		screenGui:Destroy()
	end, screenGui, label
end