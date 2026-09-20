--[[
	调试工具模块
	用于在场景中创建调试用的可视化对象
]]

local module = {}
local folder = Instance.new("Model", workspace)

--[[
	清除所有调试部件
]]
function module.clearParts()
	folder:ClearAllChildren()
end

--[[
	创建调试用的部件
	@param color: Color3 - 高亮颜色
	@param ...: CFrame - 部件的位置（CFrame）
]]
function module.createPart(color: Color3, ...)
	for _, v in {...} do
		local part = Instance.new("Part")
		part.CFrame = v
		part.Anchored = true
		part.Size = Vector3.one
		part.Material = Enum.Material.Metal
		
		-- 添加高亮效果
		Instance.new("Highlight", part).FillColor = color

		-- 添加表面 GUI 显示文本
		local s = Instance.new("SurfaceGui")
		local l = Instance.new("TextLabel", s)
		l.Size = UDim2.fromScale(1, 1)
		l.Text = "Front"
		l.TextScaled = true
		s.Face = Enum.NormalId.Front
		s.Parent = part
		
		part.Parent = folder
	end
end

return module