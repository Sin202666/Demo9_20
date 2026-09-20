--[[
	Module: Lifecycle
	Description: PartIcles Mixin：开关发射、Animate、Disable / SoftDisable 与粒子注册回收
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-09-01

	功能：
	- EnableEmit / Enable / EnableEmitAt / EmitAnimate：启动发射与持续循环
	- Disable / SoftDisable / AbsoluteEnable / AbsoluteDisable：硬停或软停
	- _registerEmit / _releaseOrDestroy / _killParticle：注册、回收、手动杀死
	- `_emitGen`：每次 EnableEmit 自增；延迟闭包发现属性已前进则退出；Disable 同样自增以取消挂起闭包

	由 PartIcles/init 作为 mixin 注入 Particle 实例，业务侧勿单独 require。
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Selection = Utils.Selection
local RunService = Utils.RunService
local ChangeHistoryService = Utils.ChangeHistoryService
local Log = Utils.Log
local IS_STUDIO = RunService:IsStudio()
-- Probe Plugin capability via Selection:Get; gates IsEdit + Selection sites below.
local IS_PLUGIN = pcall(function() return Selection:Get() end)
-- _loopBody emit yield: PreRender on client so the resumed emit lands after Roblox's
-- attachment-transform propagation completes for the frame; Trail's first sample then
-- reads the clean spawn pose. Server falls back to Heartbeat (PreRender client-only).
local LOOP_YIELD_EVENT = RunService:IsClient() and RunService.PreRender or RunService.Heartbeat
local TypeRegistry = require(script.Parent.TypeRegistry)
local ParticlesMod = require(script.Parent.Particles)
local Events = require(script.Parent.Events)
local Pool = require(script.Parent.Pool)
local EvenCycle = require(script.Parent.EvenCycle)

return function(Particle)
	--[[
		取消进行中的 Animate：还原位姿、清理并从 _activeEmits 移除。
		Beam 用快照还原 + Enabled=false（Beam pData 无 InitialAnchorCF）。

		@param self table - PartIcles 实例
		@param item Instance - Animate 源实例（_activeAnimates 的 key）
	]]
	local function _cancelAnimation(self, item)
		local existing = self._activeAnimates[item]
		if not existing then return end
		-- Snapshot-restore runs BEFORE the CFrame write below: with the inverse order,
		-- one Heartbeat frame could render the visual at initial-pose still carrying the
		-- final-cycle Width/Color/Transparency = visible 1-frame pop on cancel.
		if (existing.Type == "Beam" or existing.Type == "Highlight" or existing.Type == "TrailEmitter")
			and existing.VisualPart and existing.VisualPart.Parent then
			local snap = existing.BeamSnapshot or existing.HighlightSnapshot or existing.TrailEmitterSnapshot
			if snap then
				pcall(function()
					for name, value in pairs(snap) do existing.VisualPart[name] = value end
				end)
			end
			existing.VisualPart.Enabled = false
		end
		if existing.InitialAnchorCF and existing.VisualPart and existing.VisualPart.Parent then
			if existing.Type == "Model" then
				existing.VisualPart:PivotTo(existing.InitialAnchorCF)
				if existing.InitialScale then
					pcall(function() existing.VisualPart:ScaleTo(existing.InitialScale) end)
				end
			elseif existing.Type ~= "Beam" then
				existing.VisualPart.CFrame = existing.InitialAnchorCF
			end
		end
		-- Part/Attachment hide via Transparency=1 (mirrors finishAnimate in init.luau).
		if (existing.Type == "Part" or existing.Type == "Attachment") and existing.VisualPart and existing.VisualPart.Parent then
			pcall(function()
				existing.VisualPart.Transparency = 1
				if existing.HasDecal then
					local d = existing.VisualPart:FindFirstChildOfClass("Decal")
					if d then d.Transparency = 1 end
				end
			end)
		end
		if (existing.Type == "Screen" or existing.Type == "ImageLabel") and existing.VisualPart then
			pcall(function() existing.VisualPart:Destroy() end)
		end
		-- Native PE/Trail children clean themselves up via gen-token; no manual disable here.
		if existing._scaleMapKeys and self._parentScaleMap then
			for _, desc in ipairs(existing._scaleMapKeys) do
				self._parentScaleMap[desc] = nil
			end
		end
		for idx = #self._activeEmits, 1, -1 do
			if self._activeEmits[idx] == existing then
				local n = #self._activeEmits
				if idx < n then self._activeEmits[idx] = self._activeEmits[n] end
				self._activeEmits[n] = nil
				break
			end
		end
		self._activeAnimates[item] = nil
	end

	--[[
		_cancelAnimation 的公开包装，供 Deactivate 调用。

		@param item Instance - Animate 源实例
	]]
	function Particle:_cancelAnimation(item)
		_cancelAnimation(self, item)
	end

	--[[
		停止 `item` 上的新发射。hard=true 立即还原 Animate 并硬取消原生子孙；
		hard=false 只 Enabled=false，让在飞粒子走完寿命。顺序：_cancelAnimation 必须在改 cfg.Enabled 之前。

		@param self table - PartIcles 实例
		@param item Instance - 发射源
		@param hard boolean - true 硬停（立即回收 Animate）；false 软停
	]]
	local function _haltEmission(self, item, hard)
		if Particle._activeLoops[item] then
			task.cancel(Particle._activeLoops[item])
			Particle._activeLoops[item] = nil
		end
		local chainBucket = Particle._activeChainLoops[item]
		if chainBucket then
			for _, t in ipairs(chainBucket) do pcall(task.cancel, t) end
			Particle._activeChainLoops[item] = nil
		end
		item:SetAttribute("AnimateLoop", false)
		local gen = (item:GetAttribute("_emitGen") or 0) + 1
		pcall(function() item:SetAttribute("_emitGen", gen) end)
		if hard then _cancelAnimation(self, item) end
		local config = TypeRegistry.getConfig(item)
		if config then config:SetAttribute("Enabled", false) end
		pcall(function() item:SetAttribute("_PartIclePlaying", nil) end)
		-- Reset this emitter's rolling cycle so the next emission restarts at idx 1.
		-- Transformed descendants clear their own keys via the recursion below.
		EvenCycle.clear(self._evenCycleStore, item:GetAttribute("_EvenCycleId") or item)
		for _, desc in ipairs(item:GetDescendants()) do
			if desc:GetAttribute("Transformed") then
				if hard then self:Disable(desc) else self:SoftDisable(desc) end
			elseif desc:IsA("ParticleEmitter") or desc:IsA("Trail") then
				if hard then ParticlesMod.CancelNative(desc) else pcall(function() desc.Enabled = false end) end
			elseif desc:IsA("Beam") or desc:IsA("Highlight") then
				pcall(function() desc.Enabled = false end)
			end
		end
	end

	--[[
		硬停：停止新发射并立即回收在飞克隆（扫 _activeEmits + 结束 linger）。
		Studio 编辑态打一对 Undo 路点；独立运行时跳过。

		@param item Instance? - 发射源；nil 直接返回
	]]
	function Particle:Disable(item)
		if not item then return end
		local CHS = IS_PLUGIN and RunService:IsEdit() and ChangeHistoryService or nil
		if CHS then CHS:SetWaypoint("Part-Icles: Before Disable") end
		_haltEmission(self, item, true)
		-- Reclaim live one-shots (backward walk = swap-and-pop safe); _releaseOrDestroy pools
		-- eligible visuals instead of cold-destroying them.
		local active = self._activeEmits
		for idx = #active, 1, -1 do
			local pData = active[idx]
			if pData and pData._sourceItem == item then
				if pData.VisualPart and pData.VisualPart.Parent then
					self:_releaseOrDestroy(pData, pData.VisualPart)
				end
				if pData._scaleMapKeys and self._parentScaleMap then
					for _, desc in ipairs(pData._scaleMapKeys) do
						self._parentScaleMap[desc] = nil
					end
				end
				local n = #active
				if idx < n then active[idx] = active[n] end
				active[n] = nil
			end
		end
		-- Finish PartLife linger clones early; _lingerCounted guards a double-decrement.
		if self._lingerByItem and self._lingerByItem[item] then
			for _, visualPart in ipairs(self._lingerByItem[item]) do
				if visualPart then
					local counted = false
					pcall(function() counted = visualPart:GetAttribute("_lingerCounted") == true end)
					if counted then
						self._lingerVisualCount = math.max(0, (self._lingerVisualCount or 0) - 1)
						pcall(function() visualPart:SetAttribute("_lingerCounted", nil) end)
					end
					if visualPart.Parent then
						pcall(function() visualPart:Destroy() end)
					end
				end
			end
			self._lingerByItem[item] = nil
		end
		if CHS then CHS:SetWaypoint("Part-Icles: Disable") end
	end

	--[[
		判断 desc 是否挂在嵌套 Transformed 节点下（递归会单独走到那些节点，此处应跳过）。

		@param desc Instance - 待检查子孙
		@param root Instance - 本次遍历根
		@return boolean - 中间祖先带 Transformed 属性则为 true
	]]
	local function _hasTransformedAncestor(desc, root)
		local p = desc.Parent
		while p and p ~= root do
			if p:GetAttribute("Transformed") then return true end
			p = p.Parent
		end
		return false
	end

	--[[
		递归启用 `item` 及其子孙：
		- Transformed：先标 _PartIclePlaying 再 cfg.Enabled=true + :Enable(math.huge)，避免 EnabledLoop 双开导致 1 帧闪
		- 原生 PE / Trail / Beam：.Enabled=true
		- 容器：子孙扫一遍，再带 `_parentCovered` 递归，避免原生节点双切

		@param item Instance? - 根实例；nil 直接返回
		@param _parentCovered boolean? - 祖先已覆盖原生 Enabled 时为 true
	]]
	function Particle:AbsoluteEnable(item, _parentCovered)
		if not item then return end
		if item:GetAttribute("Transformed") then
			-- Set _PartIclePlaying BEFORE flipping cfg.Enabled so EnabledLoop.handleToggle
			-- bails on the attribute change (it gates on _PartIclePlaying). Otherwise the
			-- direct Enable below and the listener's handleToggle both spawn _loopBody,
			-- causing a cancel+restart pop on every AbsoluteEnable call (visible 1-frame
			-- artifact on Animate mode, off-by-one emit shift on Emit mode). Particle:Disable
			-- clears the attribute on the matching AbsoluteDisable.
			pcall(function() item:SetAttribute("_PartIclePlaying", true) end)
			local config = TypeRegistry.getConfig(item)
			if config then config:SetAttribute("Enabled", true) end
			-- Direct Enable call covers standalone-runtime (no listener to react to attribute).
			self:Enable(item, nil, math.huge)
			return
		end
		if item:IsA("ParticleEmitter") or item:IsA("Trail") or item:IsA("Beam") then
			if _parentCovered then return end
			pcall(function() item.Enabled = true end)
			return
		end
		local shouldCover = (item:IsA("BasePart") or item:IsA("Attachment") or item:IsA("Model")) and not _parentCovered
		if shouldCover then
			for _, desc in ipairs(item:GetDescendants()) do
				if (desc:IsA("ParticleEmitter") or desc:IsA("Trail") or desc:IsA("Beam"))
					and not desc:GetAttribute("Transformed")
					and not _hasTransformedAncestor(desc, item) then
					pcall(function() desc.Enabled = true end)
				end
			end
		end
		local covered = shouldCover or _parentCovered
		for _, child in item:GetChildren() do
			if item:IsA("BasePart") and child:IsA("BasePart") and not child:GetAttribute("Transformed") then
				continue
			end
			self:AbsoluteEnable(child, covered)
		end
	end

	--[[
		软停：只停新发射，在飞克隆交给 Heartbeat 老化（不扫 _activeEmits、不毁 linger、不 _cancelAnimation）。

		@param item Instance? - 发射源；nil 直接返回
	]]
	function Particle:SoftDisable(item)
		if not item then return end
		local CHS = IS_PLUGIN and RunService:IsEdit() and ChangeHistoryService or nil
		if CHS then CHS:SetWaypoint("Part-Icles: Before Soft Disable") end
		_haltEmission(self, item, false)
		if CHS then CHS:SetWaypoint("Part-Icles: Soft Disable") end
	end

	--[[
		递归软停 `item` 及其子孙：Transformed 走 SoftDisable；原生 PE/Trail/Beam 关 Enabled。
		要立刻清场回收克隆请对每项调 :Disable。

		@param item Instance? - 根实例；nil 直接返回
		@param _parentCovered boolean? - 祖先已覆盖原生 Enabled 时为 true
	]]
	function Particle:AbsoluteDisable(item, _parentCovered)
		if not item then return end
		if item:GetAttribute("Transformed") then
			self:SoftDisable(item)
			return
		end
		if item:IsA("ParticleEmitter") or item:IsA("Trail") or item:IsA("Beam") then
			if _parentCovered then return end
			pcall(function() item.Enabled = false end)
			return
		end
		local shouldCover = (item:IsA("BasePart") or item:IsA("Attachment") or item:IsA("Model")) and not _parentCovered
		if shouldCover then
			for _, desc in ipairs(item:GetDescendants()) do
				if (desc:IsA("ParticleEmitter") or desc:IsA("Trail") or desc:IsA("Beam"))
					and not desc:GetAttribute("Transformed")
					and not _hasTransformedAncestor(desc, item) then
					pcall(function() desc.Enabled = false end)
				end
			end
		end
		local covered = shouldCover or _parentCovered
		for _, child in item:GetChildren() do
			if item:IsA("BasePart") and child:IsA("BasePart") and not child:GetAttribute("Transformed") then
				continue
			end
			self:AbsoluteDisable(child, covered)
		end
	end

	--[[
		启动一轮 Animate。3D 就地动画源；Screen/ImageLabel 为单例克隆。

		@param item Instance - 源实例（按 Class 分发到各 EmitXAnimate）
		@param link Instance? - 链接目标
		@param emitCtx table? - 可选发射上下文，字段同 EmitPart
	]]
	function Particle:EmitAnimate(item, link, emitCtx)
		self:_warnIfNotActivated("EmitAnimate")
		local isCloneAnimate = item:IsA("BlurEffect")
			or item:IsA("BloomEffect")
			or item:IsA("ColorCorrectionEffect")
			or item:IsA("Atmosphere")
			or item:IsA("ImageLabel")
		if isCloneAnimate and self._activeAnimates[item] then return end
		_cancelAnimation(self, item)
		if item:IsA("Beam") then self:EmitBeamAnimate(item, link, emitCtx)
		elseif item:IsA("Trail") and item:FindFirstChild("PartIcleProperties") then self:EmitTrailAnimate(item, link, emitCtx)
		elseif item:IsA("Highlight") then self:EmitHighlightAnimate(item, link, emitCtx)
		elseif item:IsA("Attachment") then self:EmitAttachmentAnimate(item, link, emitCtx)
		elseif item:IsA("Model") then self:EmitModelAnimate(item, link, emitCtx)
		elseif item:IsA("BlurEffect") then self:EmitBlurAnimate(item, link, emitCtx)
		elseif item:IsA("BloomEffect") then self:EmitBloomAnimate(item, link, emitCtx)
		elseif item:IsA("ColorCorrectionEffect") then self:EmitColorCorrectionAnimate(item, link, emitCtx)
		elseif item:IsA("Atmosphere") then self:EmitAtmosphereAnimate(item, link, emitCtx)
		elseif item:IsA("ImageLabel") then self:EmitImageLabelAnimate(item, link, emitCtx)
		elseif item:IsA("BasePart") then self:EmitPartAnimate(item, link, emitCtx) end
	end

	--[[
		按 EmitCount / EmitDelay / EmitDuration 发射。Animate 模式下 EmitDuration 约束 AnimateLoop。

		@param item Instance - 发射源
		@param link Instance? - 链接目标
		@param emitCtx table? - 可选发射上下文；`_parentAlive` 表示嵌套驱动，`ChainCtx` 表示链驱动
	]]
	function Particle:EnableEmit(item, link, emitCtx)
		self:_warnIfNotActivated("EnableEmit")
		local emissionMode = item:GetAttribute('EmissionMode') or "Emit"
		-- Zero-as-zero: missing EmitCount → default 1; explicit 0 → no emission.
		local rawEmitCount = item:GetAttribute('EmitCount')
		local emitCount = rawEmitCount == nil and 1 or rawEmitCount
		local emitDelay = item:GetAttribute('EmitDelay') or 0
		-- EmitDuration: number or "min,max" range string.
		local emitDuration = ParticlesMod.parseDuration(item:GetAttribute('EmitDuration')) or 0
		-- Animate items with default 0/0 still reach EmitAnimate (AnimateLoop drives them).
		if emissionMode ~= "Animate" and emitCount <= 0 and emitDuration <= 0 then return end

		-- Skip _emitGen serialization for: chain-driven (N parallel chains), nested-driven
		-- (one chain per parent particle  -  multiple parents must coexist), and instant
		-- bursts. Nested-driven detected via emitCtx._parentAlive set by NestedEmit.walk.
		local isChainDriven = emitCtx and emitCtx.ChainCtx ~= nil
		local isNestedDriven = emitCtx and emitCtx._parentAlive ~= nil
		local skipGenSerialization = isChainDriven or isNestedDriven or emitDuration <= 0
		-- Top-level emit: backfill _EvenCycleId on this authored emitter + its nested
		-- emitters so clones inherit a shared rolling-cycle key (no-op once stamped).
		if not (isChainDriven or isNestedDriven) then EvenCycle.ensureIds(item) end
		local startGen
		if not skipGenSerialization then
			startGen = (item:GetAttribute("_emitGen") or 0) + 1
			pcall(function() item:SetAttribute("_emitGen", startGen) end)
		end
		-- Engine-session gen invalidates closures past Activate/Deactivate.
		local engineGen = self._engineGen or 0
		--[[
			判断本次 EnableEmit 捕获的 gen / 引擎会话是否仍有效。
			Connection 断开、_engineGen 漂移、item 卸载、_emitGen 前进或嵌套父级死亡则 false。

			@return boolean - 闭包仍可继续执行
		]]
		local function _genStillCurrent()
			if self._connection == nil then return false end
			if (self._engineGen or 0) ~= engineGen then return false end
			if not item.Parent then return false end
			if not skipGenSerialization and (item:GetAttribute("_emitGen") or 0) ~= startGen then
				return false
			end
			-- Nested-emit cancellation: parent's Engine cleanup flips _parentAlive[1].
			if emitCtx and emitCtx._parentAlive and not emitCtx._parentAlive[1] then return false end
			return true
		end

		if emissionMode == "Animate" then
			--[[
				延迟到期后启动一轮 Animate；EmitDuration>0 时打开 AnimateLoop 并到期关掉。
			]]
			local function _doAnimate()
				if not _genStillCurrent() then return end
				if emitDuration > 0 then
					item:SetAttribute("AnimateLoop", true)
					task.delay(emitDuration, function()
						if not _genStillCurrent() then return end
						if item:GetAttribute("AnimateLoop") then item:SetAttribute("AnimateLoop", false) end
					end)
				end
				self:EmitAnimate(item, link, emitCtx)
			end
			if emitDelay > 0 then task.delay(emitDelay, _doAnimate) else _doAnimate() end
			return
		end

		local config = TypeRegistry.getConfig(item)

		--[[
			延迟到期后按 EmitCount 发射；EmitDuration>0 时转 Enable 持续循环。
		]]
		local function _doEmit()
			if not _genStillCurrent() then return end
			-- Advance the rolling cycle ONCE per emission (this whole burst), then offset
			-- every particle's even spread by it. Keyed by _EvenCycleId so the next burst
			-- and nested re-emits keep rolling the same shared counter.
			local hasPosEven, hasRotEven = EvenCycle.evenFlags(config)
			local cyPI, cyPN, cyRI, cyRN = 1, 0, 1, 0
			if hasPosEven or hasRotEven then
				local cycleKey = item:GetAttribute("_EvenCycleId") or item
				local currentRate = (config and config:GetAttribute("Rate")) or 10
				cyPI, cyPN, cyRI, cyRN = EvenCycle.advance(self._evenCycleStore, cycleKey, config, currentRate, hasPosEven, hasRotEven)
			end
			for i = 1, emitCount do
				self:Emit(item, link, Events.withEvenOffset(emitCtx, i, emitCount, cyPI, cyPN, cyRI, cyRN))
			end
			if emitDuration > 0 then
				if isChainDriven or isNestedDriven then
					-- Chain-driven OR nested-driven: independent parallel loop. Don't flip
					-- cfg.Enabled  -  nested-driven must not touch the user's standalone
					-- Enabled state on the nested item, since each parent particle has its
					-- own _parentAlive lifetime; cfg.Enabled is reserved for user intent.
					self:Enable(item, link, emitDuration, emitCtx)
				else
					-- User-driven duration emit: flip cfg.Enabled so the engine listener
					-- treats this as the canonical Enable cycle, schedule shared cleanup.
					-- Claim the item so a separate Part module instance skips its auto-Enable.
					item:SetAttribute("_PartIclePlaying", true)
					if config then config:SetAttribute("Enabled", true) end
					self:Enable(item, link, emitDuration, emitCtx)
					task.delay(emitDuration, function()
						if not _genStillCurrent() then return end
						if config and config.Parent then config:SetAttribute("Enabled", false) end
						item:SetAttribute("_PartIclePlaying", nil)
					end)
				end
			end
		end

		if emitDelay > 0 then task.delay(emitDelay, _doEmit) else _doEmit() end
	end

	--[[
		持续发射直到 duration / cfg.Enabled / 父级 / 引擎 gen 失效。
		Animate 模式短路为 AnimateLoop=true + EmitAnimate。

		@param item Instance - 发射源
		@param link Instance? - 链接目标
		@param duration number? - 循环秒数；nil 视为 math.huge
		@param emitCtx table? - 可选发射上下文；ChainCtx / _parentAlive 走并行桶
	]]
	function Particle:Enable(item, link, duration, emitCtx)
		self:_warnIfNotActivated("Enable")
		local data = self:GetData(item)
		if not data then return end
		local emissionMode = item:GetAttribute('EmissionMode') or "Emit"
		if emissionMode == "Animate" then
			item:SetAttribute("AnimateLoop", true)
			self:EmitAnimate(item, link, emitCtx)
			return
		end
		local loopDuration = duration or math.huge
		local config = TypeRegistry.getConfig(item)
		-- Chain-driven AND nested-driven loops run parallel (own bucket); user-driven
		-- cancel-and-replace. Nested-driven means each parent particle gets its OWN
		-- independent task whose lifetime tracks _parentAlive[1].
		local isChainDriven = emitCtx and emitCtx.ChainCtx ~= nil
		local isNestedDriven = emitCtx and emitCtx._parentAlive ~= nil
		local isParallel = isChainDriven or isNestedDriven
		local engineGenAtStart = self._engineGen or 0
		--[[
			按 Rate 累积 dt 并 Emit；并行循环看 _engineGen / _parentAlive，用户循环看 CheckEnabled。
		]]
		local function _loopBody()
			local startTime = os.clock()
			local emitAccum = 0 -- sub-frame Rate carry
			-- Persistent rolling cycle, keyed by _EvenCycleId so this loop, discrete bursts,
			-- and nested re-emits share + advance one counter (resets on Disable, not on a
			-- bare cfg.Enabled re-toggle). Direction follows sign of N (+ forward, - reverse).
			local cycleKey = item:GetAttribute("_EvenCycleId") or item
			while true do
				if isParallel and (self._engineGen or 0) ~= engineGenAtStart then break end
				-- Nested-driven: bail when this parent particle dies. Sibling parents'
				-- loops are independent (different _parentAlive table per parent emit).
				if isNestedDriven and emitCtx._parentAlive and not emitCtx._parentAlive[1] then break end
				if not item or not item.Parent then
					if not isParallel then Particle._activeLoops[item] = nil end; break
				end
				if os.clock() - startTime >= loopDuration then
					if not isParallel then Particle._activeLoops[item] = nil end; break
				end
				if not isParallel and not data.CheckEnabled() then
					Particle._activeLoops[item] = nil; break
				end
				local dt = LOOP_YIELD_EVENT:Wait()
				-- Studio-unfocused pause; runtime always passes (Selection:Get is editor-only).
				if IS_STUDIO and IS_PLUGIN and not Particle._focused then
					local sel = Selection:Get()
					if #sel == 0 or (Particle._unfocusedAt > 0 and os.clock() - Particle._unfocusedAt > 600) then emitAccum = 0; continue end
				end
				local currentRate = config and config:GetAttribute("Rate") or 10
				if currentRate <= 0 then emitAccum = 0; continue end
				local interval = 1 / currentRate
				emitAccum = emitAccum + dt
				local hasPosEven = (data.PosXEven or data.PosYEven or data.PosZEven) == true
				local hasRotEven = (data.RotXEven or data.RotYEven or data.RotZEven) == true
				while emitAccum >= interval do
					emitAccum = emitAccum - interval
					if hasPosEven or hasRotEven then
						-- One particle per emission: i=1,count=1; the cycle is pure offset.
						local cyPI, cyPN, cyRI, cyRN = EvenCycle.advance(self._evenCycleStore, cycleKey, config, currentRate, hasPosEven, hasRotEven)
						self:Emit(item, link, Events.withEvenOffset(emitCtx, 1, 1, cyPI, cyPN, cyRI, cyRN))
					else
						self:Emit(item, link, emitCtx)
					end
				end
			end
		end
		if isParallel then
			-- Bucket per-item so Disable can cancel; task self-removes its entry on
			-- completion. Nested-driven and chain-driven share this bucket: both are
			-- independent parallel tasks that must coexist (one per parent particle
			-- for nested-driven; one per chain stagger for chain-driven).
			local chainTask = task.spawn(function()
				_loopBody()
				local selfThread = coroutine.running()
				local bucket = Particle._activeChainLoops[item]
				if not bucket then return end
				for i = #bucket, 1, -1 do
					if bucket[i] == selfThread then table.remove(bucket, i); break end
				end
				if #bucket == 0 then Particle._activeChainLoops[item] = nil end
			end)
			local bucket = Particle._activeChainLoops[item]
			if not bucket then bucket = {}; Particle._activeChainLoops[item] = bucket end
			table.insert(bucket, chainTask)
		else
			if Particle._activeLoops[item] then task.cancel(Particle._activeLoops[item]) end
			Particle._activeLoops[item] = task.spawn(_loopBody)
		end
	end

	--[[
		带原点覆盖的 EnableEmit。仅 BasePart / Attachment / Model；其它类型与 Animate 模式 warn 一次后跳过。

		@param item Instance? - 发射源
		@param originCF CFrame? - 覆盖原点
		@param options table? - 可选字段：
			Link Instance? - 调用 SetLink
			LinkMode string? - 默认 "Weld"
			EmitParent Instance? - 调用 SetEmitParent
			ChainCtx table? - 事件链
			OriginResolver (() -> CFrame?)? - 实时原点
			UseFullOrigin boolean? - 默认 true（AtCFrame）
			IgnoreLink boolean? - 默认 false
	]]
	function Particle:EnableEmitAt(item, originCF, options)
		if not item or not item.Parent or not originCF then return end
		if not (item:IsA("BasePart") or item:IsA("Attachment") or item:IsA("Model")) then
			local key = item.ClassName
			if not enableEmitAtUnsupported[key] then
				enableEmitAtUnsupported[key] = true
				Log.warn(("[Part-Icles] EnableEmitAt does not support %s targets (origin " ..
					"override is BasePart/Attachment/Model only). Emit skipped."):format(key))
			end
			return
		end
		-- Animate uses LIVE source RT; origin override would mutate authored position. Reject.
		if (item:GetAttribute("EmissionMode") or "Emit") == "Animate" then
			if not enableEmitAtAnimateWarned then
				enableEmitAtAnimateWarned = true
				Log.warn("[Part-Icles] EnableEmitAt does not support Animate-mode targets " ..
					"in v1; use EmitMode=AtTarget for Animate sources. Emit skipped.")
			end
			return
		end
		options = options or {}
		-- Link / EmitParent persist via SetLink / SetEmitParent. Both no-op on non-Transformed
		-- items (SetLink early-return); raw BasePart / Attachment / Model targets simply skip.
		if options.Link ~= nil then
			self:SetLink(item, options.Link, options.LinkMode or "Weld")
		end
		if options.EmitParent ~= nil then
			self:SetEmitParent(item, options.EmitParent)
		end
		local emitCtx = {
			ChainCtx            = options.ChainCtx,
			EventOriginCF       = originCF,
			EventOriginResolver = options.OriginResolver,
			UseFullOrigin       = options.UseFullOrigin ~= false,
			IgnoreLink          = options.IgnoreLink == true,
		}
		self:EnableEmit(item, nil, emitCtx)
	end

	--[[
		注册新 pData：盖链 id、插入 _activeEmits、种 OnHit 射线、触发 OnEmit。
		达 MAX_ACTIVE_PARTICLES 时回收视觉并返回。

		@param pData table - 刚构建的粒子状态（Type / VisualPart / Events / IsAnimate 等）
		@param emitCtx table? - 发射上下文；无则补新 ChainCtx
	]]
	function Particle:_registerEmit(pData, emitCtx)
		-- Active-particle cap (counts _activeEmits + linger visuals).
		local cap = self.MAX_ACTIVE_PARTICLES or 1000
		if #self._activeEmits + (self._lingerVisualCount or 0) >= cap then
			-- 3D Animate uses LIVE source RT; can't destroy. Clone-Animate (Screen/ImageLabel) destroys.
			local liveRTAnimate = pData.IsAnimate and (pData.Type == "Part" or pData.Type == "Attachment"
				or pData.Type == "Beam" or pData.Type == "Model")
			if pData.IsAnimate and pData._sourceItem then self._activeAnimates[pData._sourceItem] = nil end
			if not liveRTAnimate and pData.VisualPart and pData.VisualPart.Parent then
				-- Cap-reject: route through _releaseOrDestroy so the visual enters the pool.
				-- a warm pool helps most.
				self:_releaseOrDestroy(pData, pData.VisualPart)
			end
			return
		end
		-- Root emits with no incoming emitCtx still get a fresh ChainCtx so OnEmit /
		-- OnDeath / OnHit on the same particle share identity (otherwise OnDeath would fire
		-- under a NEW root chain and chain-tracking across lifetime would break).
		pData.EventChainCtx = (emitCtx and emitCtx.ChainCtx) or pData.EventChainCtx or Events.newChainCtx()
		table.insert(self._activeEmits, pData)
		if pData.Events and pData.Events.OnHit then
			pData.LastHitCheckPos = Events.getWorldPosition(pData)
			pData.HitParams = Events.makeHitParams(pData)
			pData._hitFired = false
		end
		if pData.Events and pData.Events.OnEmit then
			-- Build payload explicitly so EmitIndex (per-burst index) reaches user scripts.
			-- Events.fire's nil-payload fallback can't synthesize EmitIndex because it
			-- doesn't see emitCtx.
			local payload = Events.makePayload(self, pData, "OnEmit", emitCtx)
			Events.fire(self, pData, "OnEmit", pData.EventChainCtx, payload)
		end
	end

	--[[
		触发 OnDeath。手动 Kill 默认抑制，除非 fireOnDeath=true。

		@param pData table - 粒子状态（Events / EventChainCtx / _killedManually / _fireOnDeathOverride）
	]]
	function Particle:_fireOnDeath(pData)
		if pData.Events and pData.Events.OnDeath
			and (not pData._killedManually or pData._fireOnDeathOverride) then
			Events.fire(self, pData, "OnDeath", pData.EventChainCtx, nil)
		end
	end

	--[[
		Heartbeat 销毁路径与 finishAnimate 触发 OnDestruction。

		@param pData table - 粒子状态（Events / EventChainCtx）
		@param visualPart Instance? - 仍挂在树上的视觉；无 Parent 则不触发
	]]
	function Particle:_fireOnDestruction(pData, visualPart)
		if pData.Events and pData.Events.OnDestruction and visualPart and visualPart.Parent then
			Events.fire(self, pData, "OnDestruction", pData.EventChainCtx, nil)
		end
	end

	--[[
		可入池则还池，否则 Destroy。Animate 视觉永不入池。

		@param pData table - 粒子状态（IsAnimate / _sourceRT / _poolKind / _sourceItem）
		@param visualPart Instance? - 视觉实例；无 Parent 则返回
	]]
	function Particle:_releaseOrDestroy(pData, visualPart)
		if not visualPart then return end
		if not visualPart.Parent then return end
		if pData.IsAnimate or not pData._sourceRT or not pData._poolKind then
			pcall(function() visualPart:Destroy() end)
			return
		end
		-- Live Rate read so pool cap tracks emitter rate.
		local rate
		local source = pData._sourceItem
		if source and source.Parent then
			local cfg = TypeRegistry.getConfig(source)
			if cfg then rate = cfg:GetAttribute("Rate") end
		end
		Pool.release(visualPart, pData._sourceRT, pData._poolKind, rate)
	end

	--[[
		生成引擎会话谓词；ParticlesMod 延迟闭包在 _engineGen 漂移或 Connection 断开时退出。

		@return (() -> boolean) - 当前会话仍存活时返回 true
	]]
	function Particle:_makeAliveCheck()
		local engineGen = self._engineGen or 0
		return function()
			return self._connection ~= nil and (self._engineGen or 0) == engineGen
		end
	end

	--[[
		AnimateLoop 周期重启：重种 OnHit 并再打 OnEmit。重放时 EmitIndex 为 nil。

		@param pData table - 粒子状态（Events / EventChainCtx）
	]]
	function Particle:_fireAnimateCycleRestartEvents(pData)
		if pData.Events and pData.Events.OnHit then
			pData.LastHitCheckPos = Events.getWorldPosition(pData)
			pData.LastHitCheckTime = nil
		end
		if pData.Events and pData.Events.OnEmit then
			local payload = Events.makePayload(self, pData, "OnEmit", { ChainCtx = pData.EventChainCtx, EmitIndex = nil })
			Events.fire(self, pData, "OnEmit", pData.EventChainCtx, payload)
		end
	end

	--[[
		payload.Kill 只打标；真正销毁/还原在 Heartbeat 死亡分支。PartLife=0 强制立刻结束。
		Animate 同时关 AnimateLoop 与 cfg.Enabled，让死亡分支走 animate-finish。

		@param pData table - 粒子状态（会写 _killedManually / _forceDead / PartLife）
		@param opts table? - 可选字段：fireOnDeath boolean? - true 时仍触发 OnDeath
	]]
	function Particle:_killParticle(pData, opts)
		opts = opts or {}
		pData._killedManually = true
		pData._fireOnDeathOverride = opts.fireOnDeath == true
		pData._forceDead = true
		pData.PartLife = 0
		if pData.IsAnimate then
			local source = pData._sourceItem
			if source then
				pcall(function()
					source:SetAttribute("AnimateLoop", false)
					-- Enabled is on Configuration, not item; route through config.
					local cfg = TypeRegistry.getConfig(source)
					if cfg then cfg:SetAttribute("Enabled", false) end
				end)
			end
		end
	end
end
