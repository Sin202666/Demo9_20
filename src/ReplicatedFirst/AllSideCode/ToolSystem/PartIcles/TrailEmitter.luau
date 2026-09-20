--[[
	Module: PartIcles.TrailEmitter
	Description: Trail 粒子 Mixin（Emitter 模式）：Emit / Animate / 每帧 Width/Color/标量图
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-09-01

	功能：
	- UpdateTrail：Width/Transparency/Color 走 TrailGraphBlender；其余标量按步进采样
	- EmitTrail：克隆 RT，继承 Attachment0/1，登记 _activeEmits
	- EmitTrailAnimate：改活源 RT；cancelAnimation 用 TrailEmitterSnapshot 还原

	空间位置静态（焊在已有 Attachment0/1）；动画全靠图。
	跨文件约定：
	  - pData.Type = "TrailEmitter" → Heartbeat 分发到 UpdateTrail
	  - Lifecycle.cancelAnimation 读 TrailEmitterSnapshot
	  - PoolHide kind "TrailEmitter"：归还 Enabled=false / 取出 true
	  - data.RenderTemplate 即被克隆的 Trail；克隆共享 Attachment 引用

	加载：由 PartIcles 引擎 mixin，业务勿直接 require
]]

local GraphMod = require(script.Parent.Graph)
local RangeMod = require(script.Parent.Range)
local TrailGraphBlender = require(script.Parent.TrailGraphBlender)
local Pool = require(script.Parent.Pool)
local MeshFlipbook = require(script.Parent.Flipbook)

--[[
	把 TrailEmitter 的 Emit / Update 挂到引擎单例。
	@param Particle table - PartIcles 引擎（GetData / _registerEmit / _activeAnimates / GetFolder / _seedTsOverride）
	@return () - 无返回值
]]
return function(Particle)

-- Per-particle scalar graphs sampled at each step. Keep aligned with TrailEmitterProperties.
local SCALAR_GRAPHS = {"Brightness", "LightEmission", "LightInfluence", "TextureLength", "MinLength", "MaxLength"}

--[[
	按时间在相邻 Graph 状态间插值写入 Trail 属性；单状态直接赋 Graph。
	@param visual Trail - 目标 Trail
	@param propName string - "WidthScale" | "Color" | "Transparency"
	@param states { {Time: number, Graph: NumberSequence|ColorSequence} }? - 关键帧状态
	@param mergedTimesList { {number} }? - 每对预合并时间轴
	@param lastIdxField string - pData 上缓存对索引的字段名
	@param pData table - 发射态（读写 lastIdxField）
	@param t number - 归一化寿命 [0,1]
	@return () - 无返回值
]]
local function _writeBlenderState(visual, propName, states, mergedTimesList, lastIdxField, pData, t)
	if not states or #states == 0 then return end
	if #states == 1 then
		visual[propName] = states[1].Graph
		return
	end
	local lastIdx = pData[lastIdxField] or 1
	if t < states[lastIdx].Time then lastIdx = 1 end
	local pairIdx = #states - 1
	for idx = lastIdx, #states - 1 do
		if t >= states[idx].Time and t <= states[idx + 1].Time then
			pairIdx = idx; break
		end
	end
	pData[lastIdxField] = pairIdx
	local lower = states[pairIdx]
	local upper = states[pairIdx + 1] or states[#states]
	local range = upper.Time - lower.Time
	local segmentAlpha = range > 0 and ((t - lower.Time) / range) or 0
	local mergedTimes = mergedTimesList and mergedTimesList[pairIdx]
	if mergedTimes then
		if propName == "Color" then
			visual[propName] = GraphMod.LerpColorGraphFast(lower.Graph, upper.Graph, segmentAlpha, mergedTimes)
		else
			visual[propName] = GraphMod.LerpGraphFast(lower.Graph, upper.Graph, segmentAlpha, mergedTimes)
		end
	end
end

--[[
	TrailEmitter 每帧更新。Width/Transparency/Color 走 blender；标量图按步进采样。
	@param pData table - 发射态：VisualPart / Graphs / Seeds / WidthStates / TransStates / ColorStates 等
	@param dt number - 本帧真实 delta
	@param currentTime number - 引擎当前时间
	@return boolean - true 表示已死亡
]]
function Particle:UpdateTrail(pData, dt, currentTime)
	-- Signed-reverse timescale support: see Update.luau UpdatePart. SetTimescale override wins for its window.
	local real_i = math.min(math.max((currentTime - pData.StartTime) / pData.LifeTime, 0), 1)
	local ts
	if pData._tsOverride ~= nil and currentTime < (pData._tsOverrideUntil or 0) then
		ts = pData._tsOverride
	else
		ts = pData.Graphs.Timescale and GraphMod.QueryPointsWithTime(real_i, pData.Graphs.Timescale, pData.Seeds.Timescale) or 1
	end
	local dtTs = dt * ts
	local lifeTime = pData.LifeTime
	local priorEff = pData._effectiveElapsed or 0
	local newEff = priorEff + (pData._timeFrozen and 0 or dtTs)
	if newEff < 0 then newEff = 0 end
	if newEff > lifeTime then newEff = lifeTime end
	pData._effectiveElapsed = newEff
	local atForwardEnd = newEff >= lifeTime
	local atBackwardEnd = newEff <= 0
	local elapsedTime = newEff
	local i = elapsedTime / lifeTime

	if not pData.VisualPart or not pData.VisualPart.Parent then return true end
	local graphFinished = real_i >= 1
	local isDying = graphFinished and (atForwardEnd or atBackwardEnd)
	i = math.min(math.max(i, 0), 1)

	-- Width / Transparency / Color blender (continuous-time, FPS-independent).
	local t = i
	if not pData.SkipColor then
		_writeBlenderState(pData.VisualPart, "WidthScale",   pData.WidthStates, pData.WidthMergedTimes, "_lastWidthIdx", pData, t)
		_writeBlenderState(pData.VisualPart, "Color",        pData.ColorStates, pData.ColorMergedTimes, "_lastColorIdx", pData, t)
	end
	if not pData.SkipTransparency then
		_writeBlenderState(pData.VisualPart, "Transparency", pData.TransStates, pData.TransMergedTimes, "_lastTransIdx", pData, t)
	end

	-- Step-quantized scalar graphs (Brightness / LightEmission / LightInfluence / TextureLength / MinLength / MaxLength).
	if pData.TotalKeyFrames > 0 then
		local targetStep = math.floor(i * pData.TotalKeyFrames)
		if targetStep ~= pData.CurrentStep then
			pData.CurrentStep = targetStep
			local steppedI = pData.CurrentStep / pData.TotalKeyFrames
			for _, key in ipairs(SCALAR_GRAPHS) do
				local graph = pData.Graphs[key]
				if graph then
					pData.VisualPart[key] = GraphMod.QueryPointsWithTime(steppedI, graph, pData.Seeds[key])
				end
			end
		end
	end

	return isDying
end

--[[
	从 GraphBlender 收集 Width/Trans/Color 状态并预计算相邻对时间轴。
	@param graphBlender Instance? - Trail GraphBlender Configuration
	@return table - widthStates
	@return table - transStates
	@return table - colorStates
	@return table - widthMergedTimes
	@return table - transMergedTimes
	@return table - colorMergedTimes
]]
local function _collectStatesAndMergedTimes(graphBlender)
	local widthStates, transStates, colorStates = TrailGraphBlender.CollectStates(graphBlender)
	local widthMergedTimes, transMergedTimes, colorMergedTimes = {}, {}, {}
	for idx = 1, #widthStates - 1 do widthMergedTimes[idx] = TrailGraphBlender.PrecomputeMergedTimes(widthStates[idx].Graph, widthStates[idx + 1].Graph) end
	for idx = 1, #transStates - 1 do transMergedTimes[idx] = TrailGraphBlender.PrecomputeMergedTimes(transStates[idx].Graph, transStates[idx + 1].Graph) end
	for idx = 1, #colorStates - 1 do colorMergedTimes[idx] = TrailGraphBlender.PrecomputeMergedColorTimes(colorStates[idx].Graph, colorStates[idx + 1].Graph) end
	return widthStates, transStates, colorStates, widthMergedTimes, transMergedTimes, colorMergedTimes
end

--[[
	组装标量图与种子（Timescale + SCALAR_GRAPHS）。
	@param data table - GetData 结果；TEmit* / 同名回退字段
	@return table - graphs：{[name]=NumberSequence}
	@return table - seeds：{[name]={[keypointIndex]=number}}
]]
local function _buildScalarGraphs(data)
	local graphs = { Timescale = data.TEmitTimescale }
	local seeds = { Timescale = GraphMod.GenerateSeed(data.TEmitTimescale) }
	for _, key in ipairs(SCALAR_GRAPHS) do
		local g = data["TEmit" .. key] or data[key]
		if g then
			graphs[key] = g
			seeds[key] = GraphMod.GenerateSeed(g)
		end
	end
	return graphs, seeds
end

--[[
	发射 TrailEmitter：克隆 RT，写入作者 Width/Color，登记 _activeEmits。
	Trail 继承克隆源的 Attachment0/1。
	@param trail Trail - 作者源
	@param link Instance? - 链接目标（写入 pData.Link）
	@param emitCtx table? - 可含 _parentCloneMap 以重绑父作用域 Attachment
	@return () - 无返回值
]]
function Particle:EmitTrail(trail, link, emitCtx)
	if not trail or not trail.Parent then return end
	local data = self:GetData(trail)
	if not data or not data.RenderTemplate then return end

	local visual = Pool.acquireOrClone(data.RenderTemplate, "TrailEmitter", data.Pool)
	visual.Archivable = false
	visual.Enabled = true
	-- Static props (Texture/TextureMode/FaceCamera) come from the cloned RT directly; no
	-- attribute-side mirror, so no override needed here.

	-- Rebind parent-scope Attachment0/1 refs via parent's clone map (nested-emit path).
	if emitCtx and emitCtx._parentCloneMap then
		local map = emitCtx._parentCloneMap
		if visual.Attachment0 and map[visual.Attachment0] then visual.Attachment0 = map[visual.Attachment0] end
		if visual.Attachment1 and map[visual.Attachment1] then visual.Attachment1 = map[visual.Attachment1] end
	end

	local safeLifeTime = RangeMod.RandomValueFromRange(data.Lifetime)
	if safeLifeTime <= 0 then safeLifeTime = 0.001 end
	-- visual.Lifetime is the Trail's segment fade duration, separate from particle Lifetime.
	local trailLifeRange = data.TrailLife or data.Lifetime
	local trailLifeVal = RangeMod.RandomValueFromRange(trailLifeRange)
	if trailLifeVal <= 0 then trailLifeVal = 0.001 end
	visual.Lifetime = trailLifeVal

	local widthStates, transStates, colorStates,
		widthMergedTimes, transMergedTimes, colorMergedTimes = _collectStatesAndMergedTimes(data.GraphBlender)

	if #widthStates > 0 then visual.WidthScale = widthStates[1].Graph end
	if #transStates > 0 then visual.Transparency = transStates[1].Graph end
	if #colorStates > 0 then visual.Color = colorStates[1].Graph end

	local graphs, seeds = _buildScalarGraphs(data)
	for _, key in ipairs(SCALAR_GRAPHS) do
		if graphs[key] then
			visual[key] = GraphMod.QueryPointsWithTime(0, graphs[key], seeds[key])
		end
	end

	visual.Parent = data.EmitParent or self:GetFolder()

	local pData = {
		Type = "TrailEmitter",
		VisualPart = visual,
		Link = link,
		Events = data.Events,
		StartTime = os.clock(),
		TotalKeyFrames = math.max(1, data.TotalKeyFrames),
		CurrentStep = 0,
		LifeTime = safeLifeTime,
		PartLife = data.PartLife or 0,
		WidthStates = widthStates, TransStates = transStates, ColorStates = colorStates,
		WidthMergedTimes = widthMergedTimes, TransMergedTimes = transMergedTimes, ColorMergedTimes = colorMergedTimes,
		Graphs = graphs,
		Seeds = seeds,
		_effectiveElapsed = GraphMod.InitialEffectiveElapsed(data.TEmitTimescale, seeds.Timescale, safeLifeTime),
	}

	pData._sourceItem = trail
	Particle._seedTsOverride(pData, trail)
	if data.Pool ~= false then pData._sourceRT, pData._poolKind = data.RenderTemplate, "TrailEmitter" end
	self:_registerEmit(pData, emitCtx)

	-- Flipbook: cycle visual.Texture through TrailFlipbooks/Decals. FlipBeam is generic over any
	-- target with a Texture property (Trail qualifies); reuse rather than fork a TrailFlipbook
	-- runtime. Mode/framerate/etc. live in the TEmitFlipbook* attrs read by GetData.
	if data.TrailFlipbookMode and data.TrailFlipbooks then
		local decals = MeshFlipbook.GetSortedBeamTextures(data.TrailFlipbooks)
		if #decals > 0 then
			local spec = {
				FlipbookMode = data.TrailFlipbookMode,
				FlipbookFramerate = data.TrailFlipbookFramerate,
				FlipbookStartRandom = data.TrailFlipbookStartRandom,
				FlipbookReverse = data.TrailFlipbookReverse,
			}
			MeshFlipbook.FlipBeam(pData, spec, decals, visual, safeLifeTime)
		end
	end
end

--[[
	Animate 模式：改活源 RT。cancelAnimation/finishAnimate 还原快照并在周期结束禁用 Trail。
	@param trail Trail - 作者源
	@param link Instance? - 链接目标
	@param emitCtx table? - 可选发射上下文
	@return () - 无返回值
]]
function Particle:EmitTrailAnimate(trail, link, emitCtx)
	if not trail or not trail.Parent then return end
	if self._activeAnimates[trail] then return end
	local data = self:GetData(trail)
	if not data or not data.RenderTemplate then return end

	local visual = data.RenderTemplate -- LIVE source, not a clone

	-- Snapshot BEFORE mutating so cancelAnimation restores authored values (mirrors Beam pattern).
	local snapshot = {
		Lifetime = visual.Lifetime,
		Brightness = visual.Brightness,
		LightEmission = visual.LightEmission,
		LightInfluence = visual.LightInfluence,
		TextureLength = visual.TextureLength,
		MinLength = visual.MinLength,
		MaxLength = visual.MaxLength,
		Texture = visual.Texture,
		TextureMode = visual.TextureMode,
		FaceCamera = visual.FaceCamera,
		WidthScale = visual.WidthScale,
		Transparency = visual.Transparency,
		Color = visual.Color,
		Enabled = visual.Enabled,
	}

	visual.Enabled = true
	-- Static props (Texture/TextureMode/FaceCamera) come from the live source directly (no clone).

	local safeLifeTime = RangeMod.RandomValueFromRange(data.Lifetime)
	if safeLifeTime <= 0 then safeLifeTime = 0.001 end
	local trailLifeRange = data.TrailLife or data.Lifetime
	local trailLifeVal = RangeMod.RandomValueFromRange(trailLifeRange)
	if trailLifeVal <= 0 then trailLifeVal = 0.001 end
	visual.Lifetime = trailLifeVal

	local widthStates, transStates, colorStates,
		widthMergedTimes, transMergedTimes, colorMergedTimes = _collectStatesAndMergedTimes(data.GraphBlender)

	if #widthStates > 0 then visual.WidthScale = widthStates[1].Graph end
	if #transStates > 0 then visual.Transparency = transStates[1].Graph end
	if #colorStates > 0 then visual.Color = colorStates[1].Graph end

	local graphs, seeds = _buildScalarGraphs(data)
	for _, key in ipairs(SCALAR_GRAPHS) do
		if graphs[key] then
			visual[key] = GraphMod.QueryPointsWithTime(0, graphs[key], seeds[key])
		end
	end

	local pData = {
		Type = "TrailEmitter",
		VisualPart = visual,
		Link = link,
		Events = data.Events,
		StartTime = os.clock(),
		TotalKeyFrames = math.max(1, data.TotalKeyFrames),
		CurrentStep = 0,
		LifeTime = safeLifeTime,
		PartLife = data.PartLife or 0,
		IsAnimate = true, AnimateItem = trail,
		TrailEmitterSnapshot = snapshot,
		WidthStates = widthStates, TransStates = transStates, ColorStates = colorStates,
		WidthMergedTimes = widthMergedTimes, TransMergedTimes = transMergedTimes, ColorMergedTimes = colorMergedTimes,
		Graphs = graphs,
		Seeds = seeds,
		_effectiveElapsed = GraphMod.InitialEffectiveElapsed(data.TEmitTimescale, seeds.Timescale, safeLifeTime),
	}

	pData._sourceItem = trail
	Particle._seedTsOverride(pData, trail)
	self._activeAnimates[trail] = pData
	self:_registerEmit(pData, emitCtx)

	if data.TrailFlipbookMode and data.TrailFlipbooks then
		local decals = MeshFlipbook.GetSortedBeamTextures(data.TrailFlipbooks)
		if #decals > 0 then
			local spec = {
				FlipbookMode = data.TrailFlipbookMode,
				FlipbookFramerate = data.TrailFlipbookFramerate,
				FlipbookStartRandom = data.TrailFlipbookStartRandom,
				FlipbookReverse = data.TrailFlipbookReverse,
			}
			MeshFlipbook.FlipBeam(pData, spec, decals, visual, safeLifeTime)
		end
	end
end

end
