--[[
	Module: TrailGraphBlender
	Description: Trail 发射器 Width / Transparency / Color 三轨图状态收集与插值复用
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-09-01

	功能：
	- CollectStates：从 GraphBlender 文件夹收集三条按 Time 排序的状态列表
	- PrecomputeMergedTimes / PrecomputeMergedColorTimes / LerpGraphFast / LerpColorGraphFast：直接复用 Graph

	模块关系：
	- 结构对齐 Graph.CollectGraphStates，额外增加 Width 轨
	- GraphBlender 下 Configuration 子级携带 Time + Width + Transparency + Color
	- 逐帧插值仍走 Graph 的 PrecomputeMergedTimes + LerpGraphFast / LerpColorGraphFast
	- TrailEmitter 在发射时调用 CollectStates

	加载方式：
		local TrailGraphBlender = require(script.Parent.TrailGraphBlender)

	使用示例：
		local w, t, c = TrailGraphBlender.CollectStates(graphBlenderFolder)
]]

local Graph = require(script.Parent.Graph)

local TrailGraphBlender = {}

--[[
	从 GraphBlender 文件夹收集三条按 Time 排序的状态列表（width / transparency / color）。
	返回列表供 Graph.PrecomputeMergedTimes + LerpGraphFast 在运行时插值。
	Time 缺失时从子级名称中的数字推导（num-1，否则 0）；末态 Time>1 时归一化到 0-1。

	@param graphBlender Instance? - 含 Configuration 子级的文件夹；nil 返回三个空表
	@return { {Time: number, Graph: NumberSequence} } - Width 轨状态
	@return { {Time: number, Graph: NumberSequence} } - Transparency 轨状态
	@return { {Time: number, Graph: ColorSequence} } - Color 轨状态
]]
function TrailGraphBlender.CollectStates(graphBlender)
	local widthStates, transStates, colorStates = {}, {}, {}
	if not graphBlender then return widthStates, transStates, colorStates end

	for _, child in pairs(graphBlender:GetChildren()) do
		if not child:IsA("Configuration") then continue end
		local time = child:GetAttribute("Time")
		if time == nil then
			local num = tonumber(string.match(child.Name, "%d+"))
			time = num and (num - 1) or 0
		end
		local width = child:GetAttribute("Width")
		if width and typeof(width) == "NumberSequence" then
			table.insert(widthStates, {Time = time, Graph = width})
		end
		local trans = child:GetAttribute("Transparency")
		if trans and typeof(trans) == "NumberSequence" then
			table.insert(transStates, {Time = time, Graph = trans})
		end
		local color = child:GetAttribute("Color")
		if color and typeof(color) == "ColorSequence" then
			table.insert(colorStates, {Time = time, Graph = color})
		end
	end

	-- Sort each list by Time + normalize fallback values into 0-1 range.
	for _, states in ipairs({widthStates, transStates, colorStates}) do
		table.sort(states, function(a, b) return a.Time < b.Time end)
		if #states > 1 and states[#states].Time > 1 then
			local maxTime = states[#states].Time
			if maxTime > 0 then for _, s in ipairs(states) do s.Time = s.Time / maxTime end end
		end
	end

	return widthStates, transStates, colorStates
end

-- Reuse Graph's existing math; Trail blender doesn't need new sequence-merge primitives.
TrailGraphBlender.PrecomputeMergedTimes = Graph.PrecomputeMergedTimes
TrailGraphBlender.PrecomputeMergedColorTimes = Graph.PrecomputeMergedColorTimes
TrailGraphBlender.LerpGraphFast = Graph.LerpGraphFast
TrailGraphBlender.LerpColorGraphFast = Graph.LerpColorGraphFast

return TrailGraphBlender
