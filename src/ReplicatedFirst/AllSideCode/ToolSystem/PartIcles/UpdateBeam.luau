--[[
	Module: PartIcles.UpdateBeam
	Description: Beam 粒子每帧 Mixin：GraphBlender 插值 Transparency/Color，积分 TextureSpeed
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-09-01

	功能：
	- UpdateBeam：推进有效寿命，写 Width0/1、Color、Transparency、TextureSpeed
	- Animate 循环复位须清 _lastTransIdx/_lastColorIdx（init.luau 处理）
	- TextureSpeed 用积分偏移（引擎速率累加器跟 FPS）
	- ParentScale 把 Width/CurveSize/TextureLength/Segments 乘嵌套 Model 缩放

	加载：由 PartIcles 引擎 mixin，业务勿直接 require
]]

local GraphMod = require(script.Parent.Graph)
local Constants = require(script.Parent.PartConstants)

--[[
	把 UpdateBeam 挂到引擎单例。
	@param Particle table - PartIcles 引擎
	@return () - 无返回值
]]
return function(Particle)

--[[
	Beam 每帧更新。从作者图 + GraphBlender 状态写 Width/Color/Transparency。
	@param pData table - 发射态：VisualPart / Graphs / Seeds / TransStates / ColorStates / AnimatedProps / ParentScale 等
	@param dt number - 本帧真实 delta
	@param currentTime number - 引擎当前时间
	@return boolean - true 表示已死亡
]]
function Particle:UpdateBeam(pData, dt, currentTime)
	-- Signed-reverse Timescale: see Update.luau UpdatePart. SetTimescale override wins for its window.
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

	-- Continuous-time, FPS-independent.
	local t = i

	local transStates = pData.TransStates
	local colorStates = pData.ColorStates

	-- Transparency blender
	if not pData.SkipTransparency then
		if transStates and #transStates >= 2 then
			local lastTrans = pData._lastTransIdx or 1
			-- Reverse-Timescale support: rescan from start when t dropped below cached pair's lower bound.
			if t < transStates[lastTrans].Time then lastTrans = 1 end
			local pairIdx = #transStates - 1
			for idx = lastTrans, #transStates - 1 do
				if t >= transStates[idx].Time and t <= transStates[idx + 1].Time then
					pairIdx = idx; break
				end
			end
			pData._lastTransIdx = pairIdx
			local lower = transStates[pairIdx]
			local upper = transStates[pairIdx + 1] or transStates[#transStates]
			local range = upper.Time - lower.Time
			local segmentAlpha = range > 0 and ((t - lower.Time) / range) or 0
			local mergedTimes = pData.TransMergedTimes[pairIdx]
			if mergedTimes then
				pData.VisualPart.Transparency = GraphMod.LerpGraphFast(lower.Graph, upper.Graph, segmentAlpha, mergedTimes)
			else
				pData.VisualPart.Transparency = GraphMod.LerpGraph(lower.Graph, upper.Graph, segmentAlpha)
			end
		elseif transStates and #transStates == 1 then
			pData.VisualPart.Transparency = transStates[1].Graph
		end
	end

	-- Color blender
	if not pData.SkipColor then
		if colorStates and #colorStates >= 2 then
			local lastColor = pData._lastColorIdx or 1
			if t < colorStates[lastColor].Time then lastColor = 1 end
			local pairIdx = #colorStates - 1
			for idx = lastColor, #colorStates - 1 do
				if t >= colorStates[idx].Time and t <= colorStates[idx + 1].Time then
					pairIdx = idx; break
				end
			end
			pData._lastColorIdx = pairIdx
			local lower = colorStates[pairIdx]
			local upper = colorStates[pairIdx + 1] or colorStates[#colorStates]
			local range = upper.Time - lower.Time
			local segmentAlpha = range > 0 and ((t - lower.Time) / range) or 0
			local mergedTimes = pData.ColorMergedTimes[pairIdx]
			if mergedTimes then
				pData.VisualPart.Color = GraphMod.LerpColorGraphFast(lower.Graph, upper.Graph, segmentAlpha, mergedTimes)
			else
				pData.VisualPart.Color = GraphMod.LerpColorGraph(lower.Graph, upper.Graph, segmentAlpha)
			end
		elseif colorStates and #colorStates == 1 then
			pData.VisualPart.Color = colorStates[1].Graph
		end
	end

	-- TextureSpeed: integral-based offset for FPS independence.
	local tsAnim = pData.AnimatedProps.TextureSpeed
	if tsAnim then
		local integral = GraphMod.IntegrateUpTo(t, tsAnim.Sequence, tsAnim.Seed)
		pData.VisualPart:SetTextureOffset((-integral * pData.LifeTime) % 1)
	end

	-- Other animated beam properties (Width0, Width1, CurveSize, etc.)
	for name, animData in pairs(pData.AnimatedProps) do
		if name ~= "TextureSpeed" then
			local val = GraphMod.QueryPointsWithTime(t, animData.Sequence, animData.Seed)
			if name == "Segments" then val = math.max(20, math.round(val)) end
			pData.VisualPart[name] = val
		end
	end

	-- Parent model scale (nested beams). StaticValue path skips per-frame Query when the
	-- parent Model's Scale graph is constant (StaticPass nilled ps.Graph; constant value
	-- lives on ps.StaticValue). Avoids the nil-graph crash post-Fix on default Scale=1.
	if pData.ParentScale then
		local ps = pData.ParentScale
		local pFactor = Constants.getParentScaleFactor(ps, currentTime, GraphMod)
		local vb = pData.VisualPart
		local ap = pData.AnimatedProps
		vb.Width0 = (ap.Width0 and vb.Width0 or pData._baseWidth0) * pFactor
		vb.Width1 = (ap.Width1 and vb.Width1 or pData._baseWidth1) * pFactor
		vb.CurveSize0 = (ap.CurveSize0 and vb.CurveSize0 or pData._baseCurveSize0) * pFactor
		vb.CurveSize1 = (ap.CurveSize1 and vb.CurveSize1 or pData._baseCurveSize1) * pFactor
		-- TextureLength multiplies (preserves tile count as beam scales) when Model's
		-- ScaleTextureLength attribute is true (default). False leaves authored value
		-- so tiles repeat more densely as beam grows.
		if ps.ScaleTextureLength ~= false then
			vb.TextureLength = (ap.TextureLength and vb.TextureLength or pData._baseTextureLength) * pFactor
		end
		vb.Segments = math.max(20, math.round((ap.Segments and vb.Segments or pData._baseSegments) * pFactor))
	end

	return isDying
end

end
