local module = {}

--[[
	局部位姿变换到世界
	@param anchorCF CFrame - 施法锚点（世界）
	@param localCF CFrame - 相对锚点的局部位姿
	@return CFrame - 世界位姿
]]
function module.ToWorld(anchorCF: CFrame, localCF: CFrame): CFrame
end

--[[
	世界位姿变换到相对锚点的 local
	@param anchorCF CFrame - 施法锚点（世界）
	@param worldCF CFrame - 世界位姿
	@return CFrame - 相对锚点的局部位姿
]]
function module.ToLocal(anchorCF: CFrame, worldCF: CFrame): CFrame
end

return module
