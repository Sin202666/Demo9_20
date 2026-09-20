--[[
	Module: StaticPass
	Description: 在发射 / AnimateLoop 回放时检测常值 NumberSequence，写入静态字段并摘掉图
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-09-01

	功能：
	- apply：常量图写入 pData._static<Name> 并从 pData.Graphs 置 nil；动态图清掉陈旧静态字段
	- restoreFromFreshData：AnimateLoop 刷新前把被 apply 摘掉的键从 freshData 补回

	模块关系：
	- 逐帧 Update 读静态值，跳过 QueryPointsWithTime
	- 幂等：先清陈旧静态字段再重检，静态→动态中途切换会重新走逐帧采样
	- ColorSequence 不处理（Graph.IsStatic 仅 NumberSequence）；颜色图仍逐帧采样
	- Beam 属性在 BeamProps / AnimatedProps，静态检测仍内联在 Emit / EmitAnimate / Engine
	- AxisLinks.refreshLoopGraphsAndSeeds 只 pairs(pData.Graphs)，须先 restore 再 refresh 再 apply

	加载方式：
		local StaticPass = require(script.Parent.StaticPass)

	使用示例：
		StaticPass.restoreFromFreshData(pData, freshData)
		AxisLinks.refreshLoopGraphsAndSeeds(pData, freshData, GraphMod)
		StaticPass.apply(pData)
]]

local Graph = require(script.Parent.Graph)

local StaticPass = {}

-- Per-type list of { graphName, staticFieldName, default }.
-- Add a graph here, then add `pData._static<Name> or ` to the matching Update sample
-- site. Field name must match between the table entry and the Update read.
local FIELDS = {
	Part = {
		{ "Speed",         "_staticSpeed",         0 },
		{ "Brightness",    "_staticBrightness",    1 },
		{ "Transparency",  "_staticTransparency",  0 },
		{ "SizeX",         "_staticSizeX",         1 },
		{ "SizeY",         "_staticSizeY",         1 },
		{ "SizeZ",         "_staticSizeZ",         1 },
		{ "RotSpeedX",     "_staticRotSpeedX",     0 },
		{ "RotSpeedY",     "_staticRotSpeedY",     0 },
		{ "RotSpeedZ",     "_staticRotSpeedZ",     0 },
		{ "PosOffsetX",    "_staticPosOffsetX",    0 },
		{ "PosOffsetY",    "_staticPosOffsetY",    0 },
		{ "PosOffsetZ",    "_staticPosOffsetZ",    0 },
		{ "AccelStrength", "_staticAccelStrength", 0 },
	},
	Attachment = {
		{ "Speed",         "_staticSpeed",         0 },
		{ "RotSpeedX",     "_staticRotSpeedX",     0 },
		{ "RotSpeedY",     "_staticRotSpeedY",     0 },
		{ "RotSpeedZ",     "_staticRotSpeedZ",     0 },
		{ "PosOffsetX",    "_staticPosOffsetX",    0 },
		{ "PosOffsetY",    "_staticPosOffsetY",    0 },
		{ "PosOffsetZ",    "_staticPosOffsetZ",    0 },
	},
	Model = {
		{ "Speed",         "_staticSpeed",         0 },
		{ "Scale",         "_staticScale",         1 },
		{ "RotSpeedX",     "_staticRotSpeedX",     0 },
		{ "RotSpeedY",     "_staticRotSpeedY",     0 },
		{ "RotSpeedZ",     "_staticRotSpeedZ",     0 },
		{ "PosOffsetX",    "_staticPosOffsetX",    0 },
		{ "PosOffsetY",    "_staticPosOffsetY",    0 },
		{ "PosOffsetZ",    "_staticPosOffsetZ",    0 },
	},
	ImageLabel = {
		{ "ImageTransparency",      "_staticImageTransparency",      0 },
		{ "BackgroundTransparency", "_staticBackgroundTransparency", 0 },
		{ "ImgSpeed",               "_staticImgSpeed",               0 },
		{ "ImgRotSpeed",            "_staticImgRotSpeed",            0 },
		{ "SizeScaleX",             "_staticSizeScaleX",             1 },
		{ "SizeScaleY",             "_staticSizeScaleY",             1 },
	},
	-- Beam props live under pData.BeamProps / pData.AnimatedProps, not pData.Graphs.
	-- Beam keeps its inline static-pass in Emit.luau / EmitAnimate.luau / Engine.luau.
}

--[[
	按类型 FIELDS 检测常量 NumberSequence：命中则盖印静态字段并摘掉图，否则清陈旧静态字段。

	@param pData table? - 粒子运行时；须有 Type 与 Graphs；缺任一则早退
]]
function StaticPass.apply(pData)
	if not pData or not pData.Type then return end
	local list = FIELDS[pData.Type]
	if not list then return end
	local g = pData.Graphs
	if not g then return end
	for _, entry in ipairs(list) do
		local graphName, staticField, default = entry[1], entry[2], entry[3]
		local seq = g[graphName]
		if seq and Graph.IsStatic(seq) then
			pData[staticField] = Graph.GetStaticValue(seq, default)
			g[graphName] = nil
		else
			-- Graph absent or dynamic: clear stale static field from prior cycle.
			pData[staticField] = nil
		end
	end
end

--[[
	AnimateLoop 回放：上一轮 apply 已从 Graphs 摘掉常量图。
	须在 AxisLinks.refreshLoopGraphsAndSeeds 之前调用，把缺失键从 freshData 补回。

	@param pData table? - 当前循环粒子；须有 Type 与 Graphs
	@param freshData table? - 重新 GetData 的表；键为图名（Speed / SizeX 等），值为 NumberSequence
]]
function StaticPass.restoreFromFreshData(pData, freshData)
	if not pData or not freshData or not pData.Type then return end
	local list = FIELDS[pData.Type]
	if not list then return end
	local g = pData.Graphs
	if not g then return end
	for _, entry in ipairs(list) do
		local graphName = entry[1]
		if g[graphName] == nil and freshData[graphName] then
			g[graphName] = freshData[graphName]
		end
	end
end

return StaticPass
