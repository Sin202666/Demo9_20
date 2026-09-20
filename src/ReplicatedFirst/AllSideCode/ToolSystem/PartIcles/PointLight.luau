--[[
	Module: PointLight
	Description: Mixin：PointLight 粒子的 Emit + Update（只动画 Range / Brightness / Color，无空间运动）
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-09-01

	功能：
	- UpdatePointLight：按 Timescale / 步进采样 PLRange / PLBrightness / PLColor
	- EmitPointLight：从池取得视觉灯、写初值再 Parent，注册 pData

	模块关系：
	- 时间轴与 Update.luau UpdatePart 相同（signed reverse + SetTimescale 窗口覆盖）
	- PoolHide 释放时 Enabled=false，本处 acquire 后翻回 true
	- 父级优先 EmitParent，否则 link，否则 light.Parent
	- 不写权威伤害/掉落

	加载方式：
		require(script.Parent.PointLight)(Particle)

	使用示例：
		Particle:EmitPointLight(light, link, emitCtx)
		local dying = Particle:UpdatePointLight(pData, dt, os.clock())
]]

local GraphMod = require(script.Parent.Graph)
local RangeMod = require(script.Parent.Range)
local Pool = require(script.Parent.Pool)

return function(Particle)

--[[
	逐帧更新 PointLight 属性。Timescale 覆盖窗口优先于 Graphs.Timescale。

	@param pData table - 粒子运行时；字段 StartTime / LifeTime / Graphs / Seeds / VisualPart / TotalKeyFrames / CurrentStep / _tsOverride / _effectiveElapsed
	@param dt number - 本帧真实 delta（秒）
	@param currentTime number - 当前 os.clock 墙钟
	@return boolean - true 表示寿命结束，Heartbeat 应剔除
]]
function Particle:UpdatePointLight(pData, dt, currentTime)
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

		if pData.Graphs.PLRange then
			pData.VisualPart.Range = GraphMod.QueryPointsWithTime(steppedI, pData.Graphs.PLRange, pData.Seeds.PLRange)
		end
		if pData.Graphs.PLBrightness and not pData.SkipTransparency then
			pData.VisualPart.Brightness = GraphMod.QueryPointsWithTime(steppedI, pData.Graphs.PLBrightness, pData.Seeds.PLBrightness)
		end
		if pData.Graphs.PLColor and not pData.SkipColor then
			pData.VisualPart.Color = GraphMod.QueryColorPointWithTime(steppedI, pData.Graphs.PLColor)
		end
	end

	return isDying
end

--[[
	发射一盏 PointLight：池化 clone、写初值再 Parent，并登记到 _activeEmits。

	@param light Instance - 源 Transformed 灯节点
	@param link Instance? - 可选挂载覆盖；优先于 light.Parent，次于 data.EmitParent
	@param emitCtx table? - 可选发射上下文，转给 _registerEmit（ChainCtx / EmitIndex / EmitCount 等）
]]
function Particle:EmitPointLight(light, link, emitCtx)
	if not light or not light.Parent then return end
	local data = self:GetData(light)
	if not data or not data.RenderTemplate then return end

	-- PoolHide flipped Enabled=false on release; flip back here.
	local visualLight = Pool.acquireOrClone(data.RenderTemplate, "PointLight", data.Pool)
	visualLight.Archivable = false
	visualLight.Enabled = true
	if data.Shadows ~= nil then visualLight.Shadows = data.Shadows end
	local parentPart = data.EmitParent or link or light.Parent

	local safeLifeTime = RangeMod.RandomValueFromRange(data.Lifetime)
	if safeLifeTime <= 0 then safeLifeTime = 0.001 end

	local seedRange = data.PLRange and GraphMod.GenerateSeed(data.PLRange) or {}
	local seedBright = data.PLBrightness and GraphMod.GenerateSeed(data.PLBrightness) or {}
	local seedTimescale = GraphMod.GenerateSeed(data.PLTimescale)

	-- Apply initial values before parenting (1-frame pop prevention).
	if data.PLRange then
		visualLight.Range = GraphMod.QueryPointsWithTime(0, data.PLRange, seedRange)
	end
	if data.PLBrightness then
		visualLight.Brightness = GraphMod.QueryPointsWithTime(0, data.PLBrightness, seedBright)
	end
	if data.PLColor then
		visualLight.Color = GraphMod.QueryColorPointWithTime(0, data.PLColor)
	end

	visualLight.Parent = parentPart

	local pData = {
		Type = "PointLight",
		VisualPart = visualLight,
		Events = data.Events,
		StartTime = os.clock(),
		TotalKeyFrames = math.max(1, data.TotalKeyFrames),
		CurrentStep = 0,
		LifeTime = safeLifeTime,
		PartLife = data.PartLife or 0,

		Graphs = {
			PLRange = data.PLRange,
			PLBrightness = data.PLBrightness,
			PLColor = data.PLColor,
			Timescale = data.PLTimescale,
		},
		Seeds = {
			PLRange = seedRange,
			PLBrightness = seedBright,
			Timescale = seedTimescale,
		},
		_effectiveElapsed = GraphMod.InitialEffectiveElapsed(data.PLTimescale, seedTimescale, safeLifeTime),
	}

	pData._sourceItem = light
	Particle._seedTsOverride(pData, light)
	if data.Pool ~= false then pData._sourceRT, pData._poolKind = data.RenderTemplate, "PointLight" end
	self:_registerEmit(pData, emitCtx)
end

end
