--[[
	Module: ScreenEmit
	Description: Mixin：Blur / Bloom / ColorCorrection / Atmosphere 的 Emit / Animate / Update
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-09-01

	功能：
	- 仅属性动画，每次 Emit clone 一份；Animate 为单例（已激活再发则丢弃）
	- EmitBlur / EmitBloom / EmitColorCorrection / EmitAtmosphere 及对应 Animate
	- UpdateScreen：步进采样图并在寿命结束时返回 true

	模块关系：
	- 默认父级 Lighting；data.EmitParent 覆盖。不用源节点位置当默认父级
	- Atmosphere 用 AtmTimescale，在 buildGraphs 里归一到 Graphs.Timescale
	- 时间轴与 UpdatePart 相同（signed reverse + SetTimescale 窗口）
	- 不写权威数据

	加载方式：
		require(script.Parent.ScreenEmit)(Particle)

	使用示例：
		Particle:EmitBlur(item, link, emitCtx)
		local dying = Particle:UpdateScreen(pData, dt, os.clock())
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Lighting = Utils.Lighting
local GraphMod = require(script.Parent.Graph)
local RangeMod = require(script.Parent.Range)

return function(Particle)

--[[
	解析屏幕效果父级：EmitParent 优先，否则 Lighting。源节点位置不用作默认。

	@param data table - GetData 结果；可选字段 EmitParent
	@param _kind string - 效果种类（未使用，保留签名）
	@return Instance - 父级实例
]]
local function _resolveScreenParent(data, _kind)
	if data.EmitParent then return data.EmitParent end
	return Lighting
end

--[[
	按 kind 组装 Graphs 字典。Atmosphere 把 AtmTimescale 映射为 Timescale。

	@param kind string - "Blur" | "Bloom" | "CC" | "Atmosphere"
	@param data table - GetData 结果；含各 NumberSequence / ColorSequence 字段
	@return table - { [graphName: string]: NumberSequence|ColorSequence|nil }
]]
local function _buildGraphs(kind, data)
	if kind == "Blur" then
		return { BlurSize = data.BlurSize, Timescale = data.Timescale }
	elseif kind == "Bloom" then
		return { BloomIntensity = data.BloomIntensity, BloomSize = data.BloomSize, BloomThreshold = data.BloomThreshold, Timescale = data.Timescale }
	elseif kind == "CC" then
		return { CCBrightness = data.CCBrightness, CCContrast = data.CCContrast, CCSaturation = data.CCSaturation, CCTintColor = data.CCTintColor, Timescale = data.Timescale }
	elseif kind == "Atmosphere" then
		return { AtmDensity = data.AtmDensity, AtmOffset = data.AtmOffset, AtmGlare = data.AtmGlare, AtmHaze = data.AtmHaze, AtmColor = data.AtmColor, AtmDecay = data.AtmDecay, Timescale = data.AtmTimescale }
	end
	return {}
end

--[[
	为 NumberSequence 图生成种子；ColorSequence 跳过。

	@param graphs table - { [name: string]: NumberSequence|ColorSequence }
	@return table - { [name: string]: {number} } 仅 NumberSequence 有种子
]]
local function _buildSeeds(graphs)
	local seeds = {}
	for k, g in pairs(graphs) do
		if typeof(g) == "NumberSequence" then seeds[k] = GraphMod.GenerateSeed(g) end
	end
	return seeds
end

--[[
	把图/颜色采样写到视觉件；kind 决定属性名。
	skipColor / skipTransparency 由 payload.SetSkipColor / SetSkipTransparency 写入 pData。

	@param kind string - "Blur" | "Bloom" | "CC" | "Atmosphere"
	@param visual Instance - 已 clone 的后处理或 Atmosphere
	@param graphs table - 图字典
	@param seeds table - 种子字典
	@param t number - 归一化寿命 [0,1]
	@param skipColor boolean? - true 时跳过颜色通道
	@param skipTransparency boolean? - true 时跳过亮度/透明通道
]]
local function _writeSample(kind, visual, graphs, seeds, t, skipColor, skipTransparency)
	if kind == "Blur" and graphs.BlurSize then
		visual.Size = GraphMod.QueryPointsWithTime(t, graphs.BlurSize, seeds.BlurSize)
	elseif kind == "Bloom" then
		if graphs.BloomIntensity then visual.Intensity = GraphMod.QueryPointsWithTime(t, graphs.BloomIntensity, seeds.BloomIntensity) end
		if graphs.BloomSize then visual.Size = GraphMod.QueryPointsWithTime(t, graphs.BloomSize, seeds.BloomSize) end
		if graphs.BloomThreshold then visual.Threshold = GraphMod.QueryPointsWithTime(t, graphs.BloomThreshold, seeds.BloomThreshold) end
	elseif kind == "CC" then
		if graphs.CCBrightness and not skipTransparency then visual.Brightness = GraphMod.QueryPointsWithTime(t, graphs.CCBrightness, seeds.CCBrightness) end
		if graphs.CCContrast then visual.Contrast = GraphMod.QueryPointsWithTime(t, graphs.CCContrast, seeds.CCContrast) end
		if graphs.CCSaturation then visual.Saturation = GraphMod.QueryPointsWithTime(t, graphs.CCSaturation, seeds.CCSaturation) end
		if graphs.CCTintColor and not skipColor then visual.TintColor = GraphMod.QueryColorPointWithTime(t, graphs.CCTintColor) end
	elseif kind == "Atmosphere" then
		if graphs.AtmDensity then visual.Density = GraphMod.QueryPointsWithTime(t, graphs.AtmDensity, seeds.AtmDensity) end
		if graphs.AtmOffset then visual.Offset = GraphMod.QueryPointsWithTime(t, graphs.AtmOffset, seeds.AtmOffset) end
		if graphs.AtmGlare then visual.Glare = GraphMod.QueryPointsWithTime(t, graphs.AtmGlare, seeds.AtmGlare) end
		if graphs.AtmHaze then visual.Haze = GraphMod.QueryPointsWithTime(t, graphs.AtmHaze, seeds.AtmHaze) end
		if graphs.AtmColor and not skipColor then visual.Color = GraphMod.QueryColorPointWithTime(t, graphs.AtmColor) end
		if graphs.AtmDecay and not skipColor then visual.Decay = GraphMod.QueryColorPointWithTime(t, graphs.AtmDecay) end
	end
end

--[[
	该 kind 是否有 Enabled 属性。Atmosphere 没有，PostProcessEffect 有。

	@param kind string - 效果种类
	@return boolean - Atmosphere 为 false，其余 true
]]
local function _kindHasEnabled(kind)
	return kind ~= "Atmosphere"
end

--[[
	Emit 模式：clone RT，Parent 前写初值（避免 1 帧闪），再登记 pData。

	@param self table - Particle 实例
	@param kind string - "Blur" | "Bloom" | "CC" | "Atmosphere"
	@param item Instance - 源 Transformed 节点
	@param link Instance? - 未使用（签名与其它 Emit 对齐）
	@param emitCtx table? - 转给 _registerEmit 的发射上下文
]]
local function _emitClone(self, kind, item, link, emitCtx)
	local data = self:GetData(item)
	if not data or not data.RenderTemplate then return end

	local visual = data.RenderTemplate:Clone()
	visual.Archivable = false
	if _kindHasEnabled(kind) then visual.Enabled = true end
	visual:SetAttribute("_PartIcleEmit", true)

	local safeLife = RangeMod.RandomValueFromRange(data.Lifetime)
	if safeLife <= 0 then safeLife = 0.001 end

	local graphs = _buildGraphs(kind, data)
	local seeds = _buildSeeds(graphs)
	_writeSample(kind, visual, graphs, seeds, 0)

	visual.Parent = _resolveScreenParent(data, kind)

	local pData = {
		Type = "Screen", Kind = kind,
		VisualPart = visual,
		Events = data.Events,
		StartTime = os.clock(),
		TotalKeyFrames = math.max(1, data.TotalKeyFrames or 100), CurrentStep = 0,
		LifeTime = safeLife, PartLife = data.PartLife or 0,
		Graphs = graphs, Seeds = seeds,
		_effectiveElapsed = GraphMod.InitialEffectiveElapsed(graphs.Timescale, seeds.Timescale, safeLife),
		_sourceItem = item,
	}
	Particle._seedTsOverride(pData, item)
	self:_registerEmit(pData, emitCtx)
end

--[[
	单例 Animate：clone、播放、结束销毁。已激活再发为 no-op。

	@param self table - Particle 实例（读 _activeAnimates）
	@param kind string - 效果种类
	@param item Instance - 源节点，作 _activeAnimates 键
	@param link Instance? - 未使用
	@param emitCtx table? - 发射上下文
]]
local function _emitAnimateInternal(self, kind, item, link, emitCtx)
	if self._activeAnimates[item] then return end

	local data = self:GetData(item)
	if not data or not data.RenderTemplate then return end

	local visual = data.RenderTemplate:Clone()
	visual.Archivable = false
	if _kindHasEnabled(kind) then visual.Enabled = true end
	visual:SetAttribute("_PartIcleEmit", true)

	local safeLife = RangeMod.RandomValueFromRange(data.Lifetime)
	if safeLife <= 0 then safeLife = 0.001 end

	local graphs = _buildGraphs(kind, data)
	local seeds = _buildSeeds(graphs)
	_writeSample(kind, visual, graphs, seeds, 0)

	visual.Parent = _resolveScreenParent(data, kind)

	local pData = {
		Type = "Screen", Kind = kind,
		VisualPart = visual,
		Events = data.Events,
		StartTime = os.clock(),
		TotalKeyFrames = math.max(1, data.TotalKeyFrames or 100), CurrentStep = 0,
		LifeTime = safeLife, PartLife = data.PartLife or 0,
		Graphs = graphs, Seeds = seeds,
		_effectiveElapsed = GraphMod.InitialEffectiveElapsed(graphs.Timescale, seeds.Timescale, safeLife),
		IsAnimate = true, AnimateItem = item,
	}
	pData._sourceItem = item
	Particle._seedTsOverride(pData, item)
	self._activeAnimates[item] = pData
	self:_registerEmit(pData, emitCtx)
end

--[[
	发射 Blur（Emit 模式，每次 clone）。

	@param item Instance - 源 Transformed 节点
	@param link Instance? - 未使用
	@param emitCtx table? - 发射上下文
]]
function Particle:EmitBlur(item, link, emitCtx) _emitClone(self, "Blur", item, link, emitCtx) end

--[[
	发射 Bloom（Emit 模式）。

	@param item Instance - 源节点
	@param link Instance? - 未使用
	@param emitCtx table? - 发射上下文
]]
function Particle:EmitBloom(item, link, emitCtx) _emitClone(self, "Bloom", item, link, emitCtx) end

--[[
	发射 ColorCorrection（Emit 模式）。

	@param item Instance - 源节点
	@param link Instance? - 未使用
	@param emitCtx table? - 发射上下文
]]
function Particle:EmitColorCorrection(item, link, emitCtx) _emitClone(self, "CC", item, link, emitCtx) end

--[[
	发射 Atmosphere（Emit 模式）。

	@param item Instance - 源节点
	@param link Instance? - 未使用
	@param emitCtx table? - 发射上下文
]]
function Particle:EmitAtmosphere(item, link, emitCtx) _emitClone(self, "Atmosphere", item, link, emitCtx) end

--[[
	单例 Animate Blur；已激活则丢弃。

	@param item Instance - 源节点
	@param link Instance? - 未使用
	@param emitCtx table? - 发射上下文
]]
function Particle:EmitBlurAnimate(item, link, emitCtx) _emitAnimateInternal(self, "Blur", item, link, emitCtx) end

--[[
	单例 Animate Bloom。

	@param item Instance - 源节点
	@param link Instance? - 未使用
	@param emitCtx table? - 发射上下文
]]
function Particle:EmitBloomAnimate(item, link, emitCtx) _emitAnimateInternal(self, "Bloom", item, link, emitCtx) end

--[[
	单例 Animate ColorCorrection。

	@param item Instance - 源节点
	@param link Instance? - 未使用
	@param emitCtx table? - 发射上下文
]]
function Particle:EmitColorCorrectionAnimate(item, link, emitCtx) _emitAnimateInternal(self, "CC", item, link, emitCtx) end

--[[
	单例 Animate Atmosphere。

	@param item Instance - 源节点
	@param link Instance? - 未使用
	@param emitCtx table? - 发射上下文
]]
function Particle:EmitAtmosphereAnimate(item, link, emitCtx) _emitAnimateInternal(self, "Atmosphere", item, link, emitCtx) end

--[[
	逐帧更新屏幕效果；寿命结束返回 true（Heartbeat swap-and-pop 剔除）。

	@param pData table - 粒子运行时；字段 VisualPart / Kind / Graphs / Seeds / LifeTime / TotalKeyFrames / CurrentStep / SkipColor / SkipTransparency
	@param dt number - 本帧真实 delta（秒）
	@param currentTime number - 当前 os.clock
	@return boolean - true 表示应剔除
]]
function Particle:UpdateScreen(pData, dt, currentTime)
	if not pData.VisualPart or not pData.VisualPart.Parent then return true end
	if pData.TotalKeyFrames <= 0 then return true end

	-- Timescale v2 (signed reverse): see Update.luau UpdatePart. SetTimescale override wins for its window.
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
	local elapsed = newEff
	local i = elapsed / lifeTime
	local graphFinished = real_i >= 1
	local isDying = graphFinished and (atForwardEnd or atBackwardEnd)
	if i > 1 then i = 1 end
	if i < 0 then i = 0 end

	local targetStep = math.floor(i * pData.TotalKeyFrames)
	if targetStep ~= pData.CurrentStep then
		pData.CurrentStep = targetStep
		local t = pData.CurrentStep / pData.TotalKeyFrames
		_writeSample(pData.Kind, pData.VisualPart, pData.Graphs, pData.Seeds, t, pData.SkipColor, pData.SkipTransparency)
	end

	return isDying
end

end
