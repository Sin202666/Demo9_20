--[[
	Module: PartIcles.Highlight
	Description: Highlight 粒子 Mixin：Emit / Animate / 每帧 Fill/Outline 图采样
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-09-01

	功能：
	- UpdateHighlight：按 Lifetime 采样 FillColor / FillTransparency / OutlineColor / OutlineTransparency
	- EmitHighlight：克隆 RenderTemplate，解析 Adornee，登记 _activeEmits
	- EmitHighlightAnimate：直接改活源 RT，取消时用 HighlightSnapshot 还原

	非空间（无运动、无 Link）。Adornee：ObjectValue → source.Adornee → source.Parent（BasePart/Model）；
	解析失败返回 nil，避免误挂 Workspace。

	加载：由 PartIcles 引擎 mixin，业务勿直接 require
]]

local GraphMod = require(script.Parent.Graph)
local RangeMod = require(script.Parent.Range)
local Pool = require(script.Parent.Pool)

--[[
	把 Highlight 的 Emit / Update 挂到引擎单例。
	@param Particle table - PartIcles 引擎（GetData / _registerEmit / _activeAnimates / _seedTsOverride）
	@return () - 无返回值
]]
return function(Particle)

--[[
	Highlight 每帧更新：按有效寿命采样 Fill/Outline 色与透明度；SetTimescale 窗口覆盖时间轴。
	@param pData table - 发射态：VisualPart / StartTime / LifeTime / Graphs / Seeds / _effectiveElapsed / TotalKeyFrames 等
	@param dt number - 本帧真实 delta
	@param currentTime number - 引擎当前时间（os.clock 口径）
	@return boolean - true 表示本粒子已死亡，应被回收
]]
function Particle:UpdateHighlight(pData, dt, currentTime)
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
	if pData.TotalKeyFrames <= 0 then return true end
	local graphFinished = real_i >= 1
	local isDying = graphFinished and (atForwardEnd or atBackwardEnd)
	i = math.min(math.max(i, 0), 1)

	local targetStep = math.floor(i * pData.TotalKeyFrames)

	if targetStep ~= pData.CurrentStep then
		pData.CurrentStep = targetStep
		local steppedI = pData.CurrentStep / pData.TotalKeyFrames

		if pData.Graphs.HLFillColor and not pData.SkipColor then
			pData.VisualPart.FillColor = GraphMod.QueryColorPointWithTime(steppedI, pData.Graphs.HLFillColor)
		end
		if pData.Graphs.HLFillTransparency and not pData.SkipTransparency then
			pData.VisualPart.FillTransparency = GraphMod.QueryPointsWithTime(steppedI, pData.Graphs.HLFillTransparency, pData.Seeds.HLFillTransparency)
		end
		if pData.Graphs.HLOutlineColor and not pData.SkipColor then
			pData.VisualPart.OutlineColor = GraphMod.QueryColorPointWithTime(steppedI, pData.Graphs.HLOutlineColor)
		end
		if pData.Graphs.HLOutlineTransparency and not pData.SkipTransparency then
			pData.VisualPart.OutlineTransparency = GraphMod.QueryPointsWithTime(steppedI, pData.Graphs.HLOutlineTransparency, pData.Seeds.HLOutlineTransparency)
		end
	end

	return isDying
end

--[[
	解析 Highlight.Adornee：data.Adornee → source.Adornee → source.Parent（仅 BasePart/Model）。
	@param data table - GetData 结果；可含 Adornee
	@param source Highlight - 作者源 Highlight
	@return Instance? - 可高亮目标；无法解析时 nil（跳过渲染，避免挂 Workspace）
]]
local function _resolveAdornee(data, source)
	if data.Adornee then return data.Adornee end
	local cur = source.Adornee
	if cur then return cur end
	local p = source.Parent
	if p and (p:IsA("BasePart") or p:IsA("Model")) then return p end
	return nil
end

--[[
	发射 Highlight：克隆 RT、解析 Adornee、登记 _activeEmits。
	@param highlight Highlight - 作者源
	@param link Instance? - 未使用（签名与其它 Emit 对齐）
	@param emitCtx table? - 可选发射上下文（EmitCount / EmitIndex / ChainCtx 等）
	@return () - 无返回值
]]
function Particle:EmitHighlight(highlight, link, emitCtx)
	if not highlight or not highlight.Parent then return end
	local data = self:GetData(highlight)
	if not data or not data.RenderTemplate then return end

	-- PoolHide flipped Enabled=false on release; flip back here.
	local visual = Pool.acquireOrClone(data.RenderTemplate, "Highlight", data.Pool)
	visual.Archivable = false
	visual.Enabled = true
	if data.HLDepthMode then visual.DepthMode = data.HLDepthMode end
	visual.Adornee = _resolveAdornee(data, highlight)
	local parentInstance = data.EmitParent or highlight.Parent

	local safeLifeTime = RangeMod.RandomValueFromRange(data.Lifetime)
	if safeLifeTime <= 0 then safeLifeTime = 0.001 end

	local seedFillTrans = data.HLFillTransparency and GraphMod.GenerateSeed(data.HLFillTransparency) or {}
	local seedOutlineTrans = data.HLOutlineTransparency and GraphMod.GenerateSeed(data.HLOutlineTransparency) or {}
	local seedTimescale = GraphMod.GenerateSeed(data.HLTimescale)

	-- Apply initial values before parenting (1-frame pop prevention).
	if data.HLFillColor then
		visual.FillColor = GraphMod.QueryColorPointWithTime(0, data.HLFillColor)
	end
	if data.HLFillTransparency then
		visual.FillTransparency = GraphMod.QueryPointsWithTime(0, data.HLFillTransparency, seedFillTrans)
	end
	if data.HLOutlineColor then
		visual.OutlineColor = GraphMod.QueryColorPointWithTime(0, data.HLOutlineColor)
	end
	if data.HLOutlineTransparency then
		visual.OutlineTransparency = GraphMod.QueryPointsWithTime(0, data.HLOutlineTransparency, seedOutlineTrans)
	end

	visual.Parent = parentInstance

	local pData = {
		Type = "Highlight",
		VisualPart = visual,
		Events = data.Events,
		StartTime = os.clock(),
		TotalKeyFrames = math.max(1, data.TotalKeyFrames),
		CurrentStep = 0,
		LifeTime = safeLifeTime,
		PartLife = data.PartLife or 0,

		Graphs = {
			HLFillColor = data.HLFillColor,
			HLFillTransparency = data.HLFillTransparency,
			HLOutlineColor = data.HLOutlineColor,
			HLOutlineTransparency = data.HLOutlineTransparency,
			Timescale = data.HLTimescale,
		},
		Seeds = {
			HLFillTransparency = seedFillTrans,
			HLOutlineTransparency = seedOutlineTrans,
			Timescale = seedTimescale,
		},
		_effectiveElapsed = GraphMod.InitialEffectiveElapsed(data.HLTimescale, seedTimescale, safeLifeTime),
	}

	pData._sourceItem = highlight
	Particle._seedTsOverride(pData, highlight)
	if data.Pool ~= false then pData._sourceRT, pData._poolKind = data.RenderTemplate, "Highlight" end
	self:_registerEmit(pData, emitCtx)
end

--[[
	Animate 模式：直接改活源 RT（不克隆）。Lifecycle.cancelAnimation 用 HighlightSnapshot 还原。
	@param highlight Highlight - 作者源
	@param link Instance? - 未使用（签名对齐）
	@param emitCtx table? - 可选发射上下文
	@return () - 无返回值
]]
function Particle:EmitHighlightAnimate(highlight, link, emitCtx)
	if not highlight or not highlight.Parent then return end
	if self._activeAnimates[highlight] then return end
	local data = self:GetData(highlight)
	if not data or not data.RenderTemplate then return end

	local visual = data.RenderTemplate -- LIVE source, not a clone

	-- Snapshot BEFORE mutating so cancelAnimation restores authored values (mirrors Beam pattern).
	local snapshot = {
		FillColor = visual.FillColor,
		FillTransparency = visual.FillTransparency,
		OutlineColor = visual.OutlineColor,
		OutlineTransparency = visual.OutlineTransparency,
		DepthMode = visual.DepthMode,
		Adornee = visual.Adornee,
		Enabled = visual.Enabled,
	}

	visual.Enabled = true
	if data.HLDepthMode then visual.DepthMode = data.HLDepthMode end
	visual.Adornee = _resolveAdornee(data, highlight)

	local safeLifeTime = RangeMod.RandomValueFromRange(data.Lifetime)
	if safeLifeTime <= 0 then safeLifeTime = 0.001 end

	local seedFillTrans = data.HLFillTransparency and GraphMod.GenerateSeed(data.HLFillTransparency) or {}
	local seedOutlineTrans = data.HLOutlineTransparency and GraphMod.GenerateSeed(data.HLOutlineTransparency) or {}
	local seedTimescale = GraphMod.GenerateSeed(data.HLTimescale)

	local pData = {
		Type = "Highlight",
		VisualPart = visual,
		Events = data.Events,
		StartTime = os.clock(),
		TotalKeyFrames = math.max(1, data.TotalKeyFrames),
		CurrentStep = 0,
		LifeTime = safeLifeTime,
		PartLife = data.PartLife or 0,
		IsAnimate = true,
		AnimateItem = highlight,
		HighlightSnapshot = snapshot,

		Graphs = {
			HLFillColor = data.HLFillColor,
			HLFillTransparency = data.HLFillTransparency,
			HLOutlineColor = data.HLOutlineColor,
			HLOutlineTransparency = data.HLOutlineTransparency,
			Timescale = data.HLTimescale,
		},
		Seeds = {
			HLFillTransparency = seedFillTrans,
			HLOutlineTransparency = seedOutlineTrans,
			Timescale = seedTimescale,
		},
		_effectiveElapsed = GraphMod.InitialEffectiveElapsed(data.HLTimescale, seedTimescale, safeLifeTime),
	}

	pData._sourceItem = highlight
	Particle._seedTsOverride(pData, highlight)
	self._activeAnimates[highlight] = pData
	self:_registerEmit(pData, emitCtx)
end

end
