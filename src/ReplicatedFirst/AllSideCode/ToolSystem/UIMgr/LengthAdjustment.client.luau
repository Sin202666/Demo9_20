--[[
	Module: UIMgr/LengthAdjustment
	Description: 克隆到 TextLabel 上的本地脚本：按文本内容把 Size 收成单行包围盒
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-09-01

	由 UIMgr.AddTextLength Clone；勿单独 require。连接随实例销毁自动断开。
]]

local TextService = game:GetService("TextService")

local Text: TextLabel = script.Parent

Text.TextScaled = false
Text.TextWrapped = false

--[[
	按当前 Text 计算单行包围盒并写 Size
	@return () - 无返回值
]]
local function _setSize()
	local bounds: Vector2 = TextService:GetTextSize(Text.Text, Text.TextSize, Text.Font, Vector2.new(math.huge, 1))
	bounds = bounds + Vector2.new(1, 1)
	Text.Size = UDim2.new(0, bounds.X, 0, bounds.Y)
end

_setSize()

local textChangedConn = Text.Changed:Connect(function(property: string)
	if property == "Text" then
		_setSize()
	end
end)

Text.AncestryChanged:Connect(function(_, newParent)
	if newParent == nil then
		textChangedConn:Disconnect()
	end
end)
