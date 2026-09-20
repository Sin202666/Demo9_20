--[[
	Module: AxisLinks
	Description: 图轴别名与 Range 轴均匀采样，供 EmitPart 与 AnimateLoop 刷新共用
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-09-01

	功能：
	- sanitize：把原始 {axisKey→属性串} 收成 {follower→primary}，拒绝跨组 / 自指 / 链式 / 环
	- applyGraphAxisAliases：跟随轴的 graph + seed 指向主轴
	- sampleRangeAxes：主轴采样一次，跟随轴复用；EvenDistribution 按 emitCtx 铺开
	- refreshLoopGraphsAndSeeds：AnimateLoop 从 freshData 重建 Graphs / Seeds 并重绑别名

	模块关系：
	- Emit / EmitAnimate / EmitModel / Engine / GetData / PartConstants 调用
	- EvenDistribution：`{axis}Even` + emitCtx → t = i/count（跳过 Min，避免 0/360 撞点）；count==1 → 中点
	- EvenOffsetIdx/N_Pos 或 _Rot 整次发射平移 (offIdx-1)/(N*count)

	加载方式：
		local AxisLinks = require(script.Parent.AxisLinks)

	使用示例：
		local resolved = AxisLinks.sanitize(rawLinks)
		AxisLinks.applyGraphAxisAliases(graphs, seeds, resolved)
		local sampled = AxisLinks.sampleRangeAxes(data, resolved, {"PosX","PosY","PosZ"}, RangeMod, emitCtx)
]]

local AxisLinks = {}

local GRAPH_FOLLOWERS = {"SizeX","SizeY","SizeZ","RotSpeedX","RotSpeedY","RotSpeedZ","PosOffsetX","PosOffsetY","PosOffsetZ"}

-- Same-group axis link metadata. Cross-group links rejected at sanitize.
local AXIS_GROUPS = {
	{"SizeX","SizeY","SizeZ"},
	{"RotSpeedX","RotSpeedY","RotSpeedZ"},
	{"PosOffsetX","PosOffsetY","PosOffsetZ"},
	{"RotX","RotY","RotZ"},
	{"PosX","PosY","PosZ"},
}
local AXIS_GROUP_OF = {}
for _, group in ipairs(AXIS_GROUPS) do
	local set = {}
	for _, a in ipairs(group) do set[a] = true end
	for _, a in ipairs(group) do AXIS_GROUP_OF[a] = set end
end

--[[
	解析跟随轴的链接目标。无链 / 自链 / 跨组 / 链式 / 环返回 nil。

	@param raw table? - 原始 { [axisKey: string]: string }；值为主轴名或空串
	@param follower string - 跟随轴键（如 SizeY / PosX）
	@return string? - 合法主轴名；非法或未链则为 nil
]]
local function _resolveAxisLink(raw, follower)
	local primary = raw and raw[follower] or nil
	if not primary or primary == "" or primary == follower then return nil end
	local group = AXIS_GROUP_OF[follower]
	if not group or not group[primary] then return nil end
	local primaryLink = raw[primary]
	if primaryLink and primaryLink ~= "" and primaryLink ~= primary and group[primaryLink] then return nil end
	return primary
end

--[[
	把原始轴链表收成已解析映射。sanitize 是过滤跨组 / 自指 / 链式 / 环的唯一关口。

	@param raw table? - 原始 { [axisKey: string]: string }；nil 时各轴均为 nil
	@return { [string]: string? } - follower → primary；未链为 nil
]]
function AxisLinks.sanitize(raw)
	local resolved = {}
	for _, group in ipairs(AXIS_GROUPS) do
		for _, a in ipairs(group) do resolved[a] = _resolveAxisLink(raw, a) end
	end
	return resolved
end

--[[
	两轴链接时，跟随轴的 graph 与 seed 指向主轴，保证逐 tick 同步。

	@param graphs table? - 图字典 { [name: string]: NumberSequence|ColorSequence }
	@param seeds table? - 种子字典 { [name: string]: {number} }
	@param axisLinks table? - sanitize 后的 { [follower: string]: string? }
]]
function AxisLinks.applyGraphAxisAliases(graphs, seeds, axisLinks)
	if not axisLinks or not graphs or not seeds then return end
	for _, follower in ipairs(GRAPH_FOLLOWERS) do
		local primary = axisLinks[follower]
		if primary and primary ~= follower and graphs[primary] and seeds[primary] then
			graphs[follower] = graphs[primary]
			seeds[follower] = seeds[primary]
		end
	end
end

--[[
	Range 轴采样。主轴采一次，跟随轴复用主轴标量。
	EvenDistribution：`{axis}Even` + emitCtx → 基数铺开 t = i/count（跳过 Min）；
	count==1 且无 offset 时取中点。滚动周期 OFFSET 按 (offIdx-1)/(N*count) 平移整段铺开。

	@param data table - GetData 结果；含各轴 NumberRange 与 `{axis}Even` 布尔
	@param axisLinks table? - sanitize 后的轴链；nil 则每轴独立采样
	@param axes {string} - 要采样的轴键列表（如 {"PosX","PosY","PosZ"}）
	@param RangeMod table - Range 模块，须有 RandomValueFromRange(NumberRange)
	@param emitCtx table? - 可选；字段 EmitIndex / EmitCount / EvenOffsetIdx_Pos / EvenOffsetN_Pos / EvenOffsetIdx_Rot / EvenOffsetN_Rot
	@return { [string]: number } - 各轴采样标量
]]
function AxisLinks.sampleRangeAxes(data, axisLinks, axes, RangeMod, emitCtx)
	local emitIndex = emitCtx and emitCtx.EmitIndex
	local emitCount = emitCtx and emitCtx.EmitCount
	local first = axes[1] or ""
	local prefix = first:sub(1, 3)
	local offIdx, offN
	if prefix == "Pos" then
		offIdx = emitCtx and emitCtx.EvenOffsetIdx_Pos
		offN = emitCtx and emitCtx.EvenOffsetN_Pos
	elseif prefix == "Rot" then
		offIdx = emitCtx and emitCtx.EvenOffsetIdx_Rot
		offN = emitCtx and emitCtx.EvenOffsetN_Rot
	end
	local hasEvenCtx = emitIndex and emitCount and emitCount > 0
	local sampled = {}
	for _, k in ipairs(axes) do
		local primary = axisLinks and axisLinks[k]
		if not primary then
			local even = data[k .. "Even"] == true
			if even and hasEvenCtx then
				local r = data[k]
				local t
				local off = (offN and offN > 0) and ((offIdx - 1) / (offN * emitCount)) or 0
				if emitCount == 1 and off == 0 then
					t = 0.5
				else
					t = emitIndex / emitCount + off
					if t > 1 then t = t - 1 end -- t < 2 guaranteed; single wrap to [0,1)
				end
				sampled[k] = r.Min + (r.Max - r.Min) * t
			else
				sampled[k] = RangeMod.RandomValueFromRange(data[k])
			end
		end
	end
	for _, k in ipairs(axes) do
		if sampled[k] == nil then
			local primary = axisLinks and axisLinks[k]
			sampled[k] = (primary and sampled[primary]) or RangeMod.RandomValueFromRange(data[k])
		end
	end
	return sampled
end

--[[
	AnimateLoop 刷新：用 freshData 重建 Graphs、重掷 seeds、再套轴别名。

	@param pData table - 当前循环粒子；须有 Graphs，可选 Seeds
	@param freshData table - 重新 GetData 的表；含各图与 AxisLinks
	@param GraphMod table - Graph 模块，须有 GenerateSeed(NumberSequence)
]]
function AxisLinks.refreshLoopGraphsAndSeeds(pData, freshData, GraphMod)
	if not pData.Graphs then return end
	for k, _ in pairs(pData.Graphs) do
		if freshData[k] ~= nil then pData.Graphs[k] = freshData[k] end
	end
	if pData.Seeds then for k, _ in pairs(pData.Seeds) do
		if pData.Graphs[k] then pData.Seeds[k] = GraphMod.GenerateSeed(pData.Graphs[k]) end
	end end
	AxisLinks.applyGraphAxisAliases(pData.Graphs, pData.Seeds, freshData.AxisLinks)
end

return AxisLinks
