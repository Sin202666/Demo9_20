--[[
	Module: Duration
	Description: 计算一次发射调度的真实墙钟时长（含 Delay / Duration / AnimateLoop / Timescale）
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-09-01

	功能：
	- computeTrueLifetime：按 Timescale 曲线数值积分粒子从出生到死亡的墙钟
	- computeItemLifecycle：单节点生命周期描述符（或不可发射时 nil）
	- computeMaxDuration：递归取本节点与可发射后代的最大结束时刻（任一支无限则 nil）

	模块关系：
	- Timescale 分段线性无闭式，用 INTEGRATION_STEPS=200 积分
	- 返回 nil 表示“实际无限”（AnimateLoop 无界、Timescale=0、或符号永远碰不到死亡边界）
	- 遍历对齐 EmitDispatch.descendantMaxEmitTime：Transformed 无发射则截断子树；
	  RenderTemplate 只递归 Transformed 后代

	加载方式：
		local Duration = require(script.Parent.Duration)

	使用示例：
		local wall = Duration.computeMaxDuration(rootItem, 0)
		if wall == nil then -- 无限
]]

local Graph = require(script.Parent.Graph)

local Duration = {}

local INTEGRATION_STEPS = 200

--[[
	把 EmitDuration 原始值收成秒。数字原样；逗号分隔串取两数中较大者。

	@param raw any - number、逗号分隔数字串、或其它；nil 视为 0
	@return number - 解析出的时长秒；无法解析为 0
]]
local function _resolveDuration(raw)
	if raw == nil then return 0 end
	if typeof(raw) == "number" then return raw end
	local vals = {}
	for v in tostring(raw):gmatch("[^,]+") do
		local n = tonumber(v:match("^%s*(.-)%s*$"))
		if n then table.insert(vals, n) end
	end
	if #vals == 0 then return 0 end
	if #vals == 1 then return vals[1] end
	return math.max(vals[1], vals[2])
end

--[[
	给定寿命与 Timescale 曲线，计算从出生到死亡的墙钟。
	两阶段：先对 real_i∈[0,1] 积分 ts(real_i)，未过边界则用终端 ts(1) 常值外推。

	@param lifetime number? - 粒子寿命秒；nil 或 <=0 返回 0
	@param timescaleGraph NumberSequence? - Timescale 图；nil 返回 lifetime 本身
	@param seed {number}? - Graph 采样种子；nil 视为空表
	@return number? - 墙钟秒；静态 0 或符号永远到不了死亡边界时 nil（无限）
]]
function Duration.computeTrueLifetime(lifetime, timescaleGraph, seed)
	if not lifetime or lifetime <= 0 then return 0 end
	if not timescaleGraph then return lifetime end

	if Graph.IsStatic(timescaleGraph) then
		local v = Graph.GetStaticValue(timescaleGraph, 1)
		if v == 1 then return lifetime end
		if v == 0 then return nil end
		if v > 0 then return lifetime / v end
		return lifetime / (-v)
	end

	local seed_ = seed or {}
	local ts0 = Graph.QueryPointsWithTime(0, timescaleGraph, seed_)
	local reverse = ts0 < 0
	local eff = reverse and lifetime or 0
	local realT = 0
	local dRealT = lifetime / INTEGRATION_STEPS

	for i = 1, INTEGRATION_STEPS do
		local real_i = i / INTEGRATION_STEPS
		local ts = Graph.QueryPointsWithTime(real_i, timescaleGraph, seed_)
		local prevEff = eff
		eff = eff + ts * dRealT
		if not reverse and eff >= lifetime then
			local frac = (lifetime - prevEff) / (eff - prevEff)
			return realT + frac * dRealT
		end
		if reverse and eff <= 0 then
			local frac = prevEff / (prevEff - eff)
			return realT + frac * dRealT
		end
		realT = realT + dRealT
	end

	-- Phase 2: real_i clamps at 1, ts stays constant at ts(1) per Update.luau math.
	local tsTerminal = Graph.QueryPointsWithTime(1, timescaleGraph, seed_)
	if reverse then
		if tsTerminal >= 0 then return nil end
		return realT + eff / (-tsTerminal)
	end
	if tsTerminal <= 0 then return nil end
	return realT + (lifetime - eff) / tsTerminal
end

--[[
	单节点生命周期描述符；不可发射（无 count、无 duration、非识别类型）返回 nil。
	描述符字段：
	  emitDelay - 开始发射前的调度延迟
	  emitDur   - burst 窗口或连续 Enable 秒数
	  lifecycle - 发射结束后到最后一颗粒子死亡的尾迹墙钟
	  infinite  - 无界（AnimateLoop 无 EmitDuration，或 Timescale 碰不到死亡边界）

	@param item Instance - 源节点（Transformed / ParticleEmitter / Trail / Beam）
	@return table? - { emitDelay: number, emitDur: number, lifecycle: number, infinite: boolean }；不可发射为 nil
]]
function Duration.computeItemLifecycle(item)
	if item:GetAttribute("Transformed") then
		local config = item:FindFirstChild("PartIcleProperties")
		local emitDelay = item:GetAttribute("EmitDelay") or 0
		local emitDur = _resolveDuration(item:GetAttribute("EmitDuration"))
		local rawCount = item:GetAttribute("EmitCount")
		local count = rawCount == nil and 1 or rawCount
		local emissionMode = item:GetAttribute("EmissionMode") or "Emit"
		local animateLoop = item:GetAttribute("AnimateLoop") == true

		if emissionMode == "Animate" and animateLoop and emitDur <= 0 then
			return { emitDelay = emitDelay, emitDur = 0, lifecycle = 0, infinite = true }
		end
		local fires = (count > 0) or (emitDur > 0) or (emissionMode == "Animate")
		if not fires then return nil end

		local lifetime = config and config:GetAttribute("Lifetime")
		local lifetimeMax = 0
		if typeof(lifetime) == "NumberRange" then lifetimeMax = lifetime.Max
		elseif type(lifetime) == "number" then lifetimeMax = lifetime end

		local timescale = config and config:GetAttribute("Timescale")
		local trueLife = Duration.computeTrueLifetime(lifetimeMax, timescale, nil)
		if trueLife == nil then
			return { emitDelay = emitDelay, emitDur = emitDur, lifecycle = 0, infinite = true }
		end

		local partLife = (config and config:GetAttribute("PartLife")) or 0
		-- Animate mode runs at minimum one full lifecycle even with EmitDuration=0.
		if emissionMode == "Animate" and trueLife > emitDur then emitDur = trueLife end

		return { emitDelay = emitDelay, emitDur = emitDur, lifecycle = trueLife + partLife, infinite = false }
	end

	if item:IsA("ParticleEmitter") then
		local rawCount = item:GetAttribute("EmitCount")
		local count = rawCount == nil and 1 or rawCount
		local emitDelay = tonumber(item:GetAttribute("EmitDelay")) or 0
		local emitDur = tonumber(item:GetAttribute("EmitDuration")) or 0
		if count <= 0 and emitDur <= 0 then return nil end
		local life = item.Lifetime
		local lifeMax = (typeof(life) == "NumberRange" and life.Max) or 0
		return { emitDelay = emitDelay, emitDur = emitDur, lifecycle = lifeMax, infinite = false }
	end

	if item:IsA("Trail") then
		local tDelay = item:GetAttribute("EmitDelay") or 0
		local tDur = _resolveDuration(item:GetAttribute("EmitDuration"))
		if tDur <= 0 then return nil end
		return { emitDelay = tDelay, emitDur = tDur, lifecycle = item.Lifetime or 0, infinite = false }
	end

	if item:IsA("Beam") then
		local bDelay = tonumber(item:GetAttribute("EmitDelay")) or 0
		local bDur = tonumber(item:GetAttribute("EmitDuration")) or 0
		if bDur <= 0 then return nil end
		return { emitDelay = bDelay, emitDur = bDur, lifecycle = 0, infinite = false }
	end

	return nil
end

--[[
	递归取本节点与可发射后代的最大结束时刻；任一支无限则返回 nil。
	对齐 EmitDispatch.descendantMaxEmitTime：Transformed 无发射截断子树；
	RenderTemplate 只递归 Transformed 后代（嵌套 per-clone 发射器）。

	@param item Instance? - 树根；nil 返回 0
	@param accumDelay number? - 祖先累积延迟秒；nil 视为 0
	@return number? - 最大结束墙钟；无限分支为 nil
]]
function Duration.computeMaxDuration(item, accumDelay)
	if not item then return 0 end
	accumDelay = accumDelay or 0

	local info = Duration.computeItemLifecycle(item)
	local myFinish = 0
	local childAccum = accumDelay
	local skipChildren = false

	if info then
		if info.infinite then return nil end
		myFinish = accumDelay + info.emitDelay + info.emitDur + info.lifecycle
		childAccum = accumDelay + info.emitDelay
		if item:GetAttribute("Transformed") then
			-- Transformed-but-no-fire would have returned nil above; non-fire descendants
			-- inside a transformed item don't run as their own AbsoluteEmit.
		end
	else
		if item:GetAttribute("Transformed") then
			skipChildren = true
		end
	end

	if not skipChildren then
		for _, child in ipairs(item:GetChildren()) do
			if child.Name == "RenderTemplate" then
				for _, desc in ipairs(child:GetDescendants()) do
					if desc:GetAttribute("Transformed") then
						local sub = Duration.computeMaxDuration(desc, childAccum)
						if sub == nil then return nil end
						if sub > myFinish then myFinish = sub end
					end
				end
			else
				local sub = Duration.computeMaxDuration(child, childAccum)
				if sub == nil then return nil end
				if sub > myFinish then myFinish = sub end
			end
		end
	end

	return myFinish
end

return Duration
