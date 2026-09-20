--[[
	上下黑边（Letterbox）效果模块
	创建电影风格的上下黑边效果
	@return Frame - 下黑边 Frame 对象（用于控制透明度等属性）
]]
return function(): Frame
	local gui = Instance.new("ScreenGui")
	gui.Name = "letterbox_Moon2Cutscene"
	gui.IgnoreGuiInset = true

	--[[
		创建黑边 Frame
		@return Frame
	]]
	local function createFrame(): Frame
		local frame = Instance.new("Frame")
		frame.Name = "Letterbox"
		frame.Size = UDim2.fromScale(1, .122) -- 高度为屏幕的 12.2%
		frame.BackgroundTransparency = 1
		frame.ZIndex = -499
		frame.Selectable = false
		frame.BackgroundColor3 = Color3.new(0, 0, 0)
		frame.Parent = gui
		
		return frame
	end
	
	-- 创建上下两个黑边
	local upperFrame = createFrame()
	local lowerFrame = createFrame()
	
	-- 设置下黑边位置
	lowerFrame.Position = UDim2.fromScale(0, 1)
	lowerFrame.AnchorPoint = Vector2.new(0, 1)
	
	-- 同步上下黑边的属性（透明度等）
	lowerFrame.Changed:Connect(function(prop)
		pcall(function()
			upperFrame[prop] = lowerFrame[prop]
		end)
	end)
	
	---- 清理：当下黑边被销毁时，同时销毁整个 GUI
	--lowerFrame.Destroying:Connect(function()
	--	gui:Destroy()
	--end)

	gui.Parent = game:GetService("Players").LocalPlayer.PlayerGui
	
	return lowerFrame
end