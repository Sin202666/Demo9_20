--[[
	Module: PartIcles.Graph
	Description: NumberSequence / ColorSequence 采样、积分、混合与静态判定
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-09-01

	功能：
	- GenerateSeed / QueryPointsWithTime / QueryColorPointWithTime：包络种子与采样
	- IntegrateUpTo：梯形积分（TextureSpeed）
	- IsStatic / GetStaticValue / InitialEffectiveElapsed / ScaleSequence
	- Lerp* / Blend* / PrecomputeMerged*：Beam GraphBlender 用
	- CollectGraphStates：从 Configuration 子节点收集状态

	种子形状：{[keypointIndex]=number}；单强度使相邻关键点同向漂移。
	加载：由 PartIcles 各 Mixin / Update 内部 require
]]

--[[
	把 x 钳到 [a, b]
	@param x number - 输入
	@param a number - 下限
	@param b number - 上限
	@return number - 钳制后的值
]]
local function _clamp(x, a, b) if x < a then return a end if x > b then return b end return x end

--[[
	线性插值
	@param a number - 起点
	@param b number - 终点
	@param t number - [0,1] 插值因子
	@return number - a + (b-a)*t
]]
local function _lerp(a, b, t) return a + (b - a) * t end

local Graph = {}

--[[
	生成包络种子；每个关键点得 ±intensity*Envelope（同一强度、同一符号）。
	@param graph NumberSequence? - 源图；缺或非 NumberSequence 返回空表
	@return { [number]: number } - {[keypointIndex]=偏移}；无包络点则为空
]]
function Graph.GenerateSeed(graph: NumberSequence?)
	local seed = {}
	-- Legacy items can lack newly-added graphs; empty seed → QueryPointsWithTime falls through.
	if not graph or typeof(graph) ~= "NumberSequence" then return seed end
	local kp = graph.Keypoints
	local intensity = math.random()
	local isPositive = math.random() >= 0.5
	for i = 1, #kp do
		if kp[i].Envelope > 0 then
			if isPositive then
				seed[i] = intensity * kp[i].Envelope
			else
				seed[i] = -intensity * kp[i].Envelope
			end
		end
	end
	return seed
end

--[[
	连续生成多份种子。
	@param graph NumberSequence - 源图
	@param NoOfSeeds number - 份数
	@return { { [number]: number } } - 种子数组
]]
function Graph.GenerateSeeds(graph: NumberSequence, NoOfSeeds: number)
	local seeds = {}
	for i = 1, NoOfSeeds do
		seeds[i] = Graph.GenerateSeed(graph)
	end
	return seeds
end

--[[
	在 t∈[0,1] 采样 NumberSequence，可选包络种子。
	@param t number - 归一化时间
	@param graph NumberSequence - 源图
	@param seed { [number]: number } - GenerateSeed 结果；缺槽按 0
	@return number - 采样值（含包络偏移）
]]
function Graph.QueryPointsWithTime(t: number, graph: NumberSequence, seed: {number})
	t = math.clamp(t, 0, 1)
	local keypoints = graph.Keypoints
	local n = #keypoints

	if n == 1 then return keypoints[1].Value + (seed[1] or 0) end

	local lo, hi = 1, n
	while lo < hi - 1 do
		local mid = (lo + hi) // 2
		if keypoints[mid].Time <= t then lo = mid else hi = mid end
	end
	local k1 = keypoints[lo]
	local k2 = keypoints[lo + 1]
	local span = k2.Time - k1.Time
	local point = span > 0 and (t - k1.Time) / span or 0
	local k1value = k1.Value + (seed[lo] or 0)
	local k2value = k2.Value + (seed[lo + 1] or 0)
	return k1value + ((k2value - k1value) * point)
end

--[[
	在 t∈[0,1] 采样 ColorSequence（无包络，无种子）。
	@param t number - 归一化时间
	@param graph ColorSequence - 源图
	@return Color3 - 采样色；空关键点返回白
]]
function Graph.QueryColorPointWithTime(t: number, graph: ColorSequence)
	t = math.clamp(t, 0, 1)
	local kp = graph.Keypoints
	local n = #kp
	if n == 0 then return Color3.new(1, 1, 1) end
	if n == 1 then return kp[1].Value end
	if t <= kp[1].Time then return kp[1].Value end

	local lo, hi = 1, n
	while lo < hi - 1 do
		local mid = (lo + hi) // 2
		if kp[mid].Time <= t then lo = mid else hi = mid end
	end
	local k1 = kp[lo]
	local k2 = kp[lo + 1]
	local span = k2.Time - k1.Time
	local point = span > 0 and (t - k1.Time) / span or 0
	return k1.Value:Lerp(k2.Value, point)
end

--[[
	NumberSequence 在 [0, t] 上的梯形积分（TextureSpeed 用）。
	@param t number - 积分上界，钳到 [0,1]
	@param sequence NumberSequence - 源图
	@param seed { [number]: number } - 包络种子
	@return number - 积分值
]]
function Graph.IntegrateUpTo(t: number, sequence: NumberSequence, seed: {number}): number
	t = math.clamp(t, 0, 1)
	local keypoints = sequence.Keypoints
	local n = #keypoints
	if n == 0 then return 0 end
	if n == 1 then return (keypoints[1].Value + (seed[1] or 0)) * t end

	local total = 0
	for i = 1, n - 1 do
		local k1 = keypoints[i]
		local k2 = keypoints[i + 1]
		if t <= k1.Time then break end

		local v1 = k1.Value + (seed[i] or 0)
		local v2 = k2.Value + (seed[i + 1] or 0)
		local segEnd = math.min(t, k2.Time)
		local segLength = segEnd - k1.Time
		local span = k2.Time - k1.Time
		local alpha = span > 0 and (segEnd - k1.Time) / span or 0
		local vEnd = v1 + (v2 - v1) * alpha

		total = total + (v1 + vEnd) / 2 * segLength
		if t <= k2.Time then break end
	end
	return total
end

--[[
	序列是否恒定（单关键点零包络，或全点等值且零包络）。
	@param sequence NumberSequence? - 源图；nil 视为静态
	@return boolean - 恒定为 true
]]
function Graph.IsStatic(sequence: NumberSequence): boolean
	if not sequence then return true end
	local kps = sequence.Keypoints
	-- Non-zero envelope → per-particle randomness, so not static.
	if #kps == 1 then return kps[1].Envelope == 0 end
	local val = kps[1].Value
	if kps[1].Envelope ~= 0 then return false end
	for i = 2, #kps do
		if kps[i].Value ~= val or kps[i].Envelope ~= 0 then return false end
	end
	return true
end

--[[
	取静态序列首关键点值；空序列返回 defaultValue。
	@param sequence NumberSequence? - 源图
	@param defaultValue number - 空图回退
	@return number - 首关键点 Value 或 defaultValue
]]
function Graph.GetStaticValue(sequence: NumberSequence, defaultValue: number): number
	if not sequence or #sequence.Keypoints == 0 then
		return defaultValue
	end
	return sequence.Keypoints[1].Value
end

--[[
	合并两条 NumberSequence/ColorSequence 的唯一排序时间轴。
	@param seqA NumberSequence | ColorSequence - 序列 A
	@param seqB NumberSequence | ColorSequence - 序列 B
	@return { number } - 升序唯一 Time
]]
local function _mergeSequenceTimes(seqA, seqB)
	local times = {}
	local seen = {}
	for _, seq in ipairs({seqA, seqB}) do
		for _, kp in ipairs(seq.Keypoints) do
			if not seen[kp.Time] then
				seen[kp.Time] = true
				table.insert(times, kp.Time)
			end
		end
	end
	table.sort(times)
	return times
end

--[[
	按 SpeedGraph(alpha) 混合两条 NumberSequence。
	@param GraphA NumberSequence - 起点图
	@param GraphB NumberSequence - 终点图
	@param SpeedGraph NumberSequence - 混合因子图
	@param alpha number - 在 SpeedGraph 上的采样时间，缺省 1，钳到 [0,1]
	@return NumberSequence - 新序列
]]
function Graph.BlendGraphWithTime(GraphA: NumberSequence, GraphB: NumberSequence, SpeedGraph: NumberSequence, alpha: number)
	alpha = _clamp(alpha or 1, 0, 1)
	local times = _mergeSequenceTimes(GraphA, GraphB)
	local blendFactor = Graph.QueryPointsWithTime(alpha, SpeedGraph, {})

	local newKps = {}
	for _, t in ipairs(times) do
		local valA = Graph.QueryPointsWithTime(t, GraphA, {})
		local valB = Graph.QueryPointsWithTime(t, GraphB, {})
		table.insert(newKps, NumberSequenceKeypoint.new(t, _lerp(valA, valB, blendFactor)))
	end
	return NumberSequence.new(newKps)
end

--[[
	按 SpeedGraph(alpha) 混合两条 ColorSequence。
	@param GraphA ColorSequence - 起点图
	@param GraphB ColorSequence - 终点图
	@param SpeedGraph NumberSequence - 混合因子图
	@param alpha number - 采样时间，缺省 1
	@return ColorSequence - 新序列
]]
function Graph.BlendColorGraphWithTime(GraphA: ColorSequence, GraphB: ColorSequence, SpeedGraph: NumberSequence, alpha: number)
	alpha = _clamp(alpha or 1, 0, 1)
	local times = _mergeSequenceTimes(GraphA, GraphB)
	local blendFactor = Graph.QueryPointsWithTime(alpha, SpeedGraph, {})

	local newKps = {}
	for _, t in ipairs(times) do
		local colorA = Graph.QueryColorPointWithTime(t, GraphA)
		local colorB = Graph.QueryColorPointWithTime(t, GraphB)
		table.insert(newKps, ColorSequenceKeypoint.new(t, colorA:Lerp(colorB, blendFactor)))
	end
	return ColorSequence.new(newKps)
end

--[[
	两条 NumberSequence 按 alpha 线性混合（无 Speed 图）。Beam blender 用。
	@param GraphA NumberSequence - 起点图
	@param GraphB NumberSequence - 终点图
	@param alpha number - [0,1]，缺省 0
	@return NumberSequence - 新序列
]]
function Graph.LerpGraph(GraphA: NumberSequence, GraphB: NumberSequence, alpha: number): NumberSequence
	alpha = _clamp(alpha or 0, 0, 1)
	local times = _mergeSequenceTimes(GraphA, GraphB)
	local newKps = {}
	for _, t in ipairs(times) do
		local valA = Graph.QueryPointsWithTime(t, GraphA, {})
		local valB = Graph.QueryPointsWithTime(t, GraphB, {})
		table.insert(newKps, NumberSequenceKeypoint.new(t, _lerp(valA, valB, alpha)))
	end
	return NumberSequence.new(newKps)
end

--[[
	两条 ColorSequence 按 alpha 线性混合。
	@param GraphA ColorSequence - 起点图
	@param GraphB ColorSequence - 终点图
	@param alpha number - [0,1]，缺省 0
	@return ColorSequence - 新序列
]]
function Graph.LerpColorGraph(GraphA: ColorSequence, GraphB: ColorSequence, alpha: number): ColorSequence
	alpha = _clamp(alpha or 0, 0, 1)
	local times = _mergeSequenceTimes(GraphA, GraphB)
	local newKps = {}
	for _, t in ipairs(times) do
		local colorA = Graph.QueryColorPointWithTime(t, GraphA)
		local colorB = Graph.QueryColorPointWithTime(t, GraphB)
		table.insert(newKps, ColorSequenceKeypoint.new(t, colorA:Lerp(colorB, alpha)))
	end
	return ColorSequence.new(newKps)
end

--[[
	发射时缓存合并时间轴，供每帧 LerpGraphFast 跳过合并。
	@param GraphA NumberSequence - 序列 A
	@param GraphB NumberSequence - 序列 B
	@return { number } - 升序唯一 Time
]]
function Graph.PrecomputeMergedTimes(GraphA: NumberSequence, GraphB: NumberSequence): {number}
	return _mergeSequenceTimes(GraphA, GraphB)
end

--[[
	ColorSequence 版合并时间轴缓存。
	@param GraphA ColorSequence - 序列 A
	@param GraphB ColorSequence - 序列 B
	@return { number } - 升序唯一 Time
]]
function Graph.PrecomputeMergedColorTimes(GraphA: ColorSequence, GraphB: ColorSequence): {number}
	return _mergeSequenceTimes(GraphA, GraphB)
end

--[[
	带预合并时间轴的 NumberSequence 线性混合；alpha 0/1 直接返回源图避免每帧分配。
	@param GraphA NumberSequence - 起点图
	@param GraphB NumberSequence - 终点图
	@param alpha number - [0,1]
	@param mergedTimes { number } - PrecomputeMergedTimes 结果
	@return NumberSequence - 混合结果或源引用
]]
function Graph.LerpGraphFast(GraphA: NumberSequence, GraphB: NumberSequence, alpha: number, mergedTimes: {number}): NumberSequence
	alpha = _clamp(alpha or 0, 0, 1)
	if alpha == 0 then return GraphA end
	if alpha == 1 then return GraphB end
	local newKps = {}
	for _, t in ipairs(mergedTimes) do
		local valA = Graph.QueryPointsWithTime(t, GraphA, {})
		local valB = Graph.QueryPointsWithTime(t, GraphB, {})
		table.insert(newKps, NumberSequenceKeypoint.new(t, _lerp(valA, valB, alpha)))
	end
	return NumberSequence.new(newKps)
end

--[[
	带预合并时间轴的 ColorSequence 线性混合；alpha 0/1 返回源图。
	@param GraphA ColorSequence - 起点图
	@param GraphB ColorSequence - 终点图
	@param alpha number - [0,1]
	@param mergedTimes { number } - PrecomputeMergedColorTimes 结果
	@return ColorSequence - 混合结果或源引用
]]
function Graph.LerpColorGraphFast(GraphA: ColorSequence, GraphB: ColorSequence, alpha: number, mergedTimes: {number}): ColorSequence
	alpha = _clamp(alpha or 0, 0, 1)
	if alpha == 0 then return GraphA end
	if alpha == 1 then return GraphB end
	local newKps = {}
	for _, t in ipairs(mergedTimes) do
		local colorA = Graph.QueryColorPointWithTime(t, GraphA)
		local colorB = Graph.QueryColorPointWithTime(t, GraphB)
		table.insert(newKps, ColorSequenceKeypoint.new(t, colorA:Lerp(colorB, alpha)))
	end
	return ColorSequence.new(newKps)
end

--[[
	从 GraphBlender 的 Configuration 子节点收集 Time/Transparency/Color 状态。
	@param graphBlender Instance? - Configuration 容器；nil 返回两个空表
	@return { {Time: number, Graph: NumberSequence} } - 透明度状态（按 Time 升序，必要时归一到 0-1）
	@return { {Time: number, Graph: ColorSequence} } - 颜色状态
]]
function Graph.CollectGraphStates(graphBlender)
	local transStates, colorStates = {}, {}
	if not graphBlender then return transStates, colorStates end

	for _, child in pairs(graphBlender:GetChildren()) do
		if not child:IsA("Configuration") then continue end
		local time = child:GetAttribute("Time")
		if time == nil then
			local num = tonumber(string.match(child.Name, "%d+"))
			time = num and (num - 1) or 0
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

	table.sort(transStates, function(a, b) return a.Time < b.Time end)
	table.sort(colorStates, function(a, b) return a.Time < b.Time end)
	-- Normalize fallback values into 0-1 range.
	for _, states in ipairs({transStates, colorStates}) do
		if #states > 1 and states[#states].Time > 1 then
			local maxTime = states[#states].Time
			if maxTime > 0 then for _, s in ipairs(states) do s.Time = s.Time / maxTime end end
		end
	end

	return transStates, colorStates
end

--[[
	Timescale 起步为负时的初始 _effectiveElapsed。ts(0)<0 则从寿命末尾回绕，否则从 0。
	@param graph NumberSequence? - Timescale 图
	@param seed { [number]: number }? - 包络种子；nil 当空表
	@param lifeTime number - 粒子寿命秒
	@return number - 0 或 lifeTime
]]
function Graph.InitialEffectiveElapsed(graph, seed, lifeTime)
	if not graph or typeof(graph) ~= "NumberSequence" then return 0 end
	-- Empty seed fallback: i=0 is deterministic on the first keypoint regardless of envelope.
	local ts0 = Graph.QueryPointsWithTime(0, graph, seed or {})
	return (ts0 < 0) and lifeTime or 0
end

--[[
	缩放 NumberSequence：Value*=factor，Envelope*=abs(factor)。
	@param seq NumberSequence? - 源图；非 NumberSequence 原样返回
	@param factor number - 缩放因子
	@return NumberSequence? - 新序列或原引用
]]
function Graph.ScaleSequence(seq, factor)
	if not seq or typeof(seq) ~= "NumberSequence" then return seq end
	local kps = seq.Keypoints
	local new = {}
	local absFactor = math.abs(factor)
	for _, kp in ipairs(kps) do
		table.insert(new, NumberSequenceKeypoint.new(kp.Time, kp.Value * factor, kp.Envelope * absFactor))
	end
	return NumberSequence.new(new)
end

return Graph
