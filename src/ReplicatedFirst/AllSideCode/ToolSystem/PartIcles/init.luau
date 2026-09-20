--[[
	Module: PartIcles
	Description: Part-Icles 特效运行时引擎（Emit / AbsoluteEmit / Timescale / Pool / Link）
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-09-01

	加载：local PartIcles = Utils.PartIcles  （或 FXUtil.PartIcles 门面）
	须先 :Activate() 再 Emit； teardown 调 :Deactivate()。

	Part-Icles Core  -  runtime engine.

	Call :Activate() once at script start to connect the Heartbeat loop.
	Call :Deactivate() at teardown to disconnect + clean up active emits.

	---- Emit (one item, no recursion) ----
	:Emit(item, link?, emitCtx?)
	   Fires one immediate emit on `item` (BasePart / Attachment / Model / Beam / etc.).
	   Use :AbsoluteEmit when you want children to fire too.

	:EmitAnimate(item, link?, emitCtx?)
	   Starts one Animate cycle on `item`. Visual animates in place (3D types) or
	   spawns a singleton clone (Screen / ImageLabel).

	:EnableEmit(item, link?, emitCtx?)
	   Honors authored EmitCount + EmitDelay + EmitDuration attributes. Fires the
	   burst then runs the loopBody for EmitDuration seconds.

	:EnableEmitAt(item, originCF, options?)
	   Like :EnableEmit but spawns from `originCF` instead of `item`'s authored CFrame.
	   Supports BasePart / Attachment / Model only. options = { ChainCtx, OriginResolver,
	   UseFullOrigin, IgnoreLink, Link, LinkMode, EmitParent }. Link / EmitParent persist
	   to source via SetLink / SetEmitParent (LinkMode defaults to "Weld" when Link set).

	---- Recursive emit (item + all descendants) ----
	:AbsoluteEmit(item, _parentFiredPE?, emitCtx?) -> duration: number?
	   Fires every emitter under `item` (transformed items via :EnableEmit, raw PE / Trail
	   / Beam via native APIs). Walks the descendant tree, deduping via _parentFiredPE.
	   Returns total real-time duration in seconds (or nil for infinite  -  AnimateLoop
	   unbounded, Timescale stuck at 0). Pair with .await(n) for an emit-and-wait pattern.

	:AbsoluteEmitAt(item, originCF, options?) -> duration: number?
	   Recursive form of :EnableEmitAt. Same emitCtx threading as :AbsoluteEmit; transformed
	   descendants spawn from `originCF` instead of their authored CFrame. Raw types in the
	   tree emit from their authored position (origin override is BasePart/Attachment/Model
	   only). Returns total duration (or nil for infinite).

	---- Enable / Disable (no emit  -  just on/off state) ----
	:Enable(item, link?, duration?, emitCtx?)
	   Starts the continuous-emit loopBody for `duration` seconds (defaults to math.huge).
	   Animate-mode short-circuits to AnimateLoop=true + :EmitAnimate.

	:Disable(item)
	   Hard stop on `item`: cancels loops, sets cfg.Enabled=false, cancels PE/Trail native
	   gens, AND reclaims every live clone now (sweeps _activeEmits + finishes linger).

	:SoftDisable(item)
	   Soft stop on `item`: halt new emission but leave live clones to age out their Lifetime
	   on the Heartbeat (no _activeEmits sweep, no linger destroy, no cancelAnimation).

	:AbsoluteEnable(item)
	   Recursive enable. Transformed item → cfg.Enabled=true + :Enable(math.huge), sets
	   _PartIclePlaying gate so the EnabledLoop listener doesn't double-fire. Raw PE / Trail
	   / Beam / Highlight descendants get Enabled=true. Containers (Folder, Model, BasePart)
	   walk children with the covered flag so descendants aren't double-toggled.

	:AbsoluteDisable(item)
	   Recursive SOFT disable. Transformed descendants → :SoftDisable (new emission stops,
	   live particles finish their Lifetime). Raw PE / Trail / Beam / Highlight descendants
	   get Enabled=false (native soft stop). For instant reclaim, call :Disable per item.

	---- Timescale (per-particle time distortion) ----
	:SetTimescale(item, scale, duration?, permanent?)
	   Override Timescale to `scale` for `duration` seconds (or until next ClearTimescale
	   if `permanent`). Wins over authored Timescale graph during its window.

	:ClearTimescale(item)
	   Remove the override; authored Timescale graph (or 1) resumes.

	:AbsoluteSetTimescale / :AbsoluteClearTimescale
	   Recursive variants over `item` + transformed descendants.

	---- Authoring / texture / state ----
	:Transform(part)                                  -  convert into a Part-Icle emitter
	:TransformModel(model, typeDef)                   -  Model variant
	:Preload(root, force?)                            -  pin textures for upcoming emit
	:Deload(root, force?)                             -  release texture pins
	:GetData(item)                                    -  flat data table read from config
	:GetFolder() / :GetPoolFolder()                   -  runtime folder accessors
	:ReapplyLink(pData)                               -  per-frame link CFrame writer

	---- Statics + sub-services ----
	.await(n)                                         -  yields task for n seconds; nil = no-op
	.parseDuration(raw)                               -  parse "min,max" range string to number
	.LinkService                                      -  standalone link-tracking service
	.TransformCompleted                               -  BindableEvent fired post-:Transform

	---- emitCtx ----
	emitCtx (optional table threaded through every emit path):
	  ChainCtx            = { ChainId, Depth } event-chain context
	  EmitIndex           = burst-index (set by EnableEmit's count loop)
	  EmitCount           = burst-count
	  EventOriginCF       = origin override (set by EnableEmitAt / AbsoluteEmitAt)
	  EventOriginResolver = live-resolver function fired at spawn time
	  UseFullOrigin       = bool; AtCFrame includes rotation
	  IgnoreLink          = bool; bypass authored Link weld
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local UserInputService = Utils.UserInputService
local RunService = Utils.RunService
local Log = Utils.Log

local ParticlesMod = require(script.Particles)
local DurationMod = require(script.Duration)
local TexturePinMod = require(script.TexturePin)
local LinkServiceMod = require(script.LinkService)

local CAP_WARN_INTERVAL = 1
local INFINITE_CLONE_DESTROY_DELAY = 60
local EMIT_VISUAL_DT = 1 / 60
local DEFAULT_MAX_ACTIVE_PARTICLES = 1000

local Particle = {}
Particle.Beam = {}
-- Focus tracking; connections stored so Deactivate can release them. Client-only.
Particle._focused = true
Particle._unfocusedAt = 0
if RunService:IsClient() then
	Particle._focusConn = UserInputService.WindowFocused:Connect(function() Particle._focused = true; Particle._unfocusedAt = 0 end)
	Particle._blurConn = UserInputService.WindowFocusReleased:Connect(function() Particle._focused = false; Particle._unfocusedAt = os.clock() end)
end

-- Engine state.
Particle._activeEmits = {}    -- pData array for live clones; Heartbeat walks this
Particle._activeLoops = {}    -- item → Enable-loop task thread
Particle._activeAnimates = {} -- item → pData (max 1 cycle per source)
-- Chain-driven duration loops run detached so parallel chain fires don't cancel each other.
Particle._activeChainLoops = {}
-- EvenDistribution rolling-cycle state, keyed by _EvenCycleId so all clones of one
-- authored emitter share + advance one counter across discrete + nested emissions.
Particle._evenCycleStore = {}
Particle._connection = nil
Particle._CachedFolder = nil
Particle._engineGen = 0
-- Hard cap on concurrent particles; user Module code still runs at cap.
Particle.MAX_ACTIVE_PARTICLES = DEFAULT_MAX_ACTIVE_PARTICLES
Particle._capWarnLastAt = 0
-- PartLife linger visuals (post-pData) count toward the cap.
Particle._lingerVisualCount = 0
-- First-emit-per-RT preload memo (ImageEmit). Weak-keyed so destroyed RT GCs cleanly.
Particle._preloadedAssets = setmetatable({}, {__mode = "k"})

-- Mixin pattern: sub-modules attach methods to Particle.
require(script.GetData)(Particle)
require(script.Transform)(Particle)
require(script.Update)(Particle)
require(script.UpdateBeam)(Particle)
-- Timescale loaded before Emit mixins so Particle._seedTsOverride is attached when those emit-site seed calls run.
require(script.Timescale)(Particle)
require(script.Emit)(Particle)
require(script.EmitAnimate)(Particle)
require(script.EmitModel)(Particle)
require(script.UpdateModel)(Particle)
require(script.PointLight)(Particle)
require(script.Highlight)(Particle)
require(script.TrailEmitter)(Particle)
require(script.ScreenEmit)(Particle)
require(script.ImageEmit)(Particle)
require(script.LinkTrack)(Particle)
require(script.Orientation)(Particle)
require(script.ZOffset)(Particle)
-- Engine mixin owns Activate / Deactivate / GetFolder / GetPoolFolder (big Heartbeat
-- callback split out to keep init.luau under the 500-line code cap).
require(script.Engine)(Particle)
-- Lifecycle loaded last (touches earlier mixins).
require(script.Lifecycle)(Particle)

--[[
	未 Activate 时对公开发射 API 打一次警告。粒子会被创建但 Heartbeat 未接，看起来像“看不见”。

	@param methodName string - 调用方方法名，写入警告文案
]]
function Particle:_warnIfNotActivated(methodName)
	if self._connection then return end
	if self._notActivatedWarned then return end
	self._notActivatedWarned = true
	Log.warn(string.format(
		"[Part-Icles] :%s() called before :Activate()  -  particles will not update until the engine is activated. Call Particle:Activate() once at startup.",
		methodName
	))
end

--[[
	发射当帧补 Orientation / ZOffset，避免等下一 Heartbeat 才转向导致 1 帧闪切。

	@param pData table - 活动粒子数据，须含 Type / VisualPart / Orientation / ZOffset
]]
function Particle:_applyEmitVisualPasses(pData)
	local t = pData.Type
	if t ~= "Part" and t ~= "Model" and t ~= "Attachment" then return end
	local cam = workspace.CurrentCamera
	local camPos = cam and cam.CFrame.Position
	-- Seed _postUpdateCF from spawn pose so frame-1 overlays don't compound on themselves.
	local hasO = pData.Orientation and pData.Orientation ~= "None"
	local hasZ = pData.ZOffset and pData.ZOffset ~= 0
	if hasO or hasZ then pData._postUpdateCF = (t == "Model") and pData.VisualPart:GetPivot() or pData.VisualPart.CFrame end
	if hasO then self:ApplyOrientation(pData, EMIT_VISUAL_DT, camPos) end
	if hasZ then self:ApplyZOffset(pData, camPos) end
end

-- Activate / Deactivate / GetFolder / GetPoolFolder live in Modules/Part/Engine.luau (mixin).

--[[
	一次性发射，按类型分发到 EmitX。未知类型静默 no-op。

	@param item Instance - 发射源（BasePart / Attachment / Model / Beam / Trail / 屏幕类等）
	@param link Instance? - 可选链接目标；仅 Part / Attachment / Model 消费
	@param emitCtx table? - 事件链与原点覆盖：
		ChainCtx table? - {ChainId, Depth}
		EmitIndex number? - burst 1-based 序号
		EventOriginCF CFrame? - 原点快照
		IgnoreLink boolean? - true 时忽略 authored Link
]]
function Particle:Emit(item, link, emitCtx)
	if not item or not item.Parent then return end
	self:_warnIfNotActivated("Emit")
	-- Hard cap on concurrent particles. Skip the visual emit but let Events.fire's
	-- user-Module spawn continue (Module is spawned separately, not from this dispatch).
	-- Once-per-second warn so a sustained overflow doesn't flood Output with one warn
	-- per dropped emit.
	-- Lingering visuals (PartLife > 0 path in Lifecycle) outlive their _activeEmits entry
	-- but still consume world resources, so they count against the cap. _lingerVisualCount
	-- is incremented when a visual enters linger, decremented on destroy (or via
	-- _lingerCounted attribute idempotency).
	local cap = self.MAX_ACTIVE_PARTICLES or DEFAULT_MAX_ACTIVE_PARTICLES
	if #self._activeEmits + (self._lingerVisualCount or 0) >= cap then
		local now = os.clock()
		if now - (self._capWarnLastAt or 0) >= CAP_WARN_INTERVAL then
			self._capWarnLastAt = now
			Log.warn(("[Part-Icles] active particle cap (%d) reached  -  new emits skipped (user Module code still runs)."):format(cap))
		end
		return
	end
	if item:IsA("Beam") and item:FindFirstChild("PartIcleProperties") then
		self:EmitBeam(item, link, emitCtx)
	elseif item:IsA("Beam") or (item:IsA("Trail") and not item:FindFirstChild("PartIcleProperties")) then
		-- directAccess Beam (BeamNative) or directAccess Trail: no emit pipeline. Schedule the
		-- enable-for-Duration toggle that doEmitOnce uses so API-level Particle:Emit has parity.
		-- Trail's EmitDuration is sometimes a "min,max" string  -  take max for the schedule.
		local raw, d = item:GetAttribute("EmitDuration"), 0
		if typeof(raw) == "number" then d = raw
		elseif raw ~= nil then local m1, m2 = tostring(raw):match("([%-%.%d]+)%s*,%s*([%-%.%d]+)")
			d = (m1 and m2) and math.max(tonumber(m1) or 0, tonumber(m2) or 0) or (tonumber(tostring(raw)) or 0)
		end
		if d > 0 then
			task.delay(item:GetAttribute("EmitDelay") or 0, function()
				if not (item and item.Parent) then return end
				item.Enabled = true
				task.delay(d, function() if item and item.Parent then item.Enabled = false end end)
			end)
		end
	elseif item:IsA("Trail") then
		self:EmitTrail(item, link, emitCtx)
	elseif item:IsA("PointLight") then
		self:EmitPointLight(item, link, emitCtx)
	elseif item:IsA("Highlight") then
		self:EmitHighlight(item, link, emitCtx)
	elseif item:IsA("Attachment") then
		self:EmitAttachment(item, link, emitCtx)
	elseif item:IsA("Model") then
		self:EmitModel(item, link, emitCtx)
	elseif item:IsA("BlurEffect") then
		self:EmitBlur(item, link, emitCtx)
	elseif item:IsA("BloomEffect") then
		self:EmitBloom(item, link, emitCtx)
	elseif item:IsA("ColorCorrectionEffect") then
		self:EmitColorCorrection(item, link, emitCtx)
	elseif item:IsA("Atmosphere") then
		self:EmitAtmosphere(item, link, emitCtx)
	elseif item:IsA("ImageLabel") then
		self:EmitImageLabel(item, link, emitCtx)
	elseif item:IsA("BasePart") then
		self:EmitPart(item, link, emitCtx)
	end
	-- Unknown / unwired types silently no-op.
end

-- Particle:Enable, Particle:Disable, Particle:EmitAnimate, Particle:EnableEmit, and the
-- local cancelAnimation helper live in Modules/Part/Lifecycle.luau (loaded as a mixin above).

-- Recursive fire-everything-under-root. For a transformed item, runs EnableEmit (full emit timing).
-- For a raw ParticleEmitter / Trail, fires its native API directly. Walks descendants so one call
-- on a Folder/Model containing many emitters fires them all. `_parentFiredPE` is an internal flag
-- that prevents double-firing when an ancestor already covered a subtree's native PEs via
-- ParticlesMod.EnableEmit (which internally uses GetDescendants).
--[[
	配合 AbsoluteEmit 返回值的让步等待。点调用。nil / 非正数不让步，无限周期发射器可安全链式调用。

	@param n number? - 秒；nil 或 <=0 立即返回
]]
function Particle.await(n)
	if n == nil then return end
	if type(n) ~= "number" then return end
	if n <= 0 then return end
	task.wait(n)
end

--[[
	递归发射实现。AbsoluteEmit 包一层以只警告一次 Activate，并在外层算墙钟时长。

	@param item Instance - 当前节点
	@param _parentFiredPE boolean? - 祖先已对原生 PE/Trail 做 GetDescendants 覆盖
	@param emitCtx table? - 透传到 EnableEmit 的发射上下文
]]
function Particle:_absoluteEmitFire(item, _parentFiredPE, emitCtx)
	if item:GetAttribute("Transformed") then
		self:EnableEmit(item, nil, emitCtx)
		return
	end

	-- Engine-session predicate threaded into native PE/Trail helpers so a delayed
	-- :Emit / :Enable doesn't fire after Particle:Deactivate.
	local alive = self:_makeAliveCheck()

	-- Raw ParticleEmitter: fire directly. EmitCount defaults to 1 when the attribute is absent,
	-- matching the Studio Emit button's inline behavior. tonumber coerces string-typed attrs
	-- (e.g. EmitCount="5" set via Studio's attribute UI) so the `<= 0` comparison can't error.
	if item:IsA("ParticleEmitter") then
		if _parentFiredPE then return end
		local count = tonumber(item:GetAttribute("EmitCount")) or 1
		local emitDelay = tonumber(item:GetAttribute("EmitDelay")) or 0
		local emitDuration = tonumber(item:GetAttribute("EmitDuration")) or 0
		-- Zero-as-zero  -  see Modules/Part/Particles.luau.
		if count <= 0 and emitDuration <= 0 then return end
		-- Capture the native gen at schedule time so an AbsoluteDisable during EmitDelay
		-- invalidates this delayed start instead of resurrecting the emitter past the delay.
		local scheduledGen = ParticlesMod.ReadNativeGen(item)
		--[[
			延迟或立即触发原生 PE 的 Emit + Duration 窗口；gen 过期则作废。
		]]
		local function _doEmit()
			if not alive() or not ParticlesMod.IsNativeGenCurrent(item, scheduledGen) then return end
			if count > 0 then item:Emit(count) end
			-- SetEnabledForDuration schedules a native-gen-tokened delayed-off so the
			-- cleanup still runs even after engine death, while a newer emit session
			-- bumping the gen prevents this closure from clobbering its window.
			if emitDuration > 0 then ParticlesMod.SetEnabledForDuration(item, emitDuration) end
		end
		if emitDelay > 0 then task.delay(emitDelay, _doEmit) else _doEmit() end
		return
	end

	-- Raw Trail: delegate to existing single-instance helper (parses EmitDuration range).
	if item:IsA("Trail") then
		if _parentFiredPE then return end
		ParticlesMod.EnableEmitSingle(item, alive)
		return
	end

	-- Raw Beam: continuous-streak rendering between authored Attachment0 / Attachment1.
	-- EmitDuration attribute gates a timed Enable-for-duration window; absent / zero leaves
	-- the authored Enabled state alone. No EmitCount semantic (Beams stream, not burst).
	if item:IsA("Beam") then
		if _parentFiredPE then return end
		local emitDuration = tonumber(item:GetAttribute("EmitDuration")) or 0
		local emitDelay = tonumber(item:GetAttribute("EmitDelay")) or 0
		if emitDuration > 0 then
			local scheduledGen = ParticlesMod.ReadNativeGen(item)
			--[[
				延迟或立即打开 Beam 的 Duration 窗口；gen 过期则作废。
			]]
			local function _doEmit()
				if not alive() or not ParticlesMod.IsNativeGenCurrent(item, scheduledGen) then return end
				ParticlesMod.SetEnabledForDuration(item, emitDuration)
			end
			if emitDelay > 0 then task.delay(emitDelay, _doEmit) else _doEmit() end
		end
		return
	end

	-- Fire native PEs for BaseParts and Attachments.
	-- Skip if a parent already called EnableEmit (which uses GetDescendants, so our PEs are already covered).
	local shouldFirePE = (item:IsA("BasePart") or item:IsA("Attachment") or item:IsA("Model")) and not _parentFiredPE
	if shouldFirePE then ParticlesMod.EnableEmit(item, alive) end

	-- Propagate the "covered" state: if we fired here OR an ancestor fired, children are already
	-- covered. The `or _parentFiredPE` term keeps a suppressed intermediate (e.g. an Attachment
	-- inside an already-fired Part) from clearing the flag  -  descendant PEs would double-fire.
	local firedCovered = shouldFirePE or _parentFiredPE
	for _, child in item:GetChildren() do
		if item:IsA("BasePart") and child:IsA("BasePart") and not child:GetAttribute("Transformed") then
			continue
		end
		self:_absoluteEmitFire(child, firedCovered, emitCtx)
	end
end

--[[
	递归发射 item 及其后代。Transformed → EnableEmit；原生 PE/Trail/Beam → 原生 API。
	返回墙钟总时长（秒）；任一分支无限（AnimateLoop / Timescale=0）则返回 nil。

	@param item Instance - 根节点
	@param _parentFiredPE boolean? - 内部去重；业务勿传
	@param emitCtx table? - 透传到 EnableEmit，字段同 :Emit
	@return number? - 总秒数；无限为 nil
]]
function Particle:AbsoluteEmit(item, _parentFiredPE, emitCtx)
	self:_warnIfNotActivated("AbsoluteEmit")
	if not item then return 0 end
	self:_absoluteEmitFire(item, _parentFiredPE, emitCtx)
	return DurationMod.computeMaxDuration(item, 0)
end

--[[
	带原点覆盖的递归发射。Transformed 根走引擎；普通 3D 容器两遍：Pass1 引擎覆盖原点，
	Pass2 克隆并剥掉 Transformed 后代后对原生 PE/Trail/Beam 就地发射。

	@param item Instance - 根节点
	@param originCF CFrame - 覆盖原点（LinkOverride+Link 时忽略，改跟实时 Link）
	@param options table? - 可选：
		ChainCtx table? - 事件链
		OriginResolver (() -> CFrame)? - 发射时求活原点
		UseFullOrigin boolean? - 默认 true，含旋转
		IgnoreLink boolean? - 默认 false
		Link Instance? - 持久写入 SetLink
		LinkMode string? - Follow/Pivot/Weld/WeldWithoutRotation/RigidLocal；有 Link 时默认 Weld
		EmitParent Instance? - 持久写入 SetEmitParent
		ApplyToAll boolean? - 容器目标把 Link/EmitParent 写到每个 Transformed 后代
		LinkOverride boolean? - 有 Link 时用实时 Link CFrame，忽略 originCF
		SkipClone boolean? - 调用方自管克隆生命周期，跳过 Pass2
	@return number? - 墙钟总秒数；无限为 nil
]]
function Particle:AbsoluteEmitAt(item, originCF, options)
	self:_warnIfNotActivated("AbsoluteEmitAt")
	if not item or not originCF then return 0 end
	options = options or {}
	local totalDur = DurationMod.computeMaxDuration(item, 0)
	-- LinkOverride: with a Link set, spawn at the LIVE link CFrame (central) and ignore the
	-- frozen originCF — so a delayed / moving-link emit follows the link instead of trailing
	-- at the call-time origin. Drops EventOriginCF so Emit's link branch resolves live at spawn.
	local linkWins = options.LinkOverride == true and options.Link ~= nil

	-- (A) Transformed root: SetLink / SetEmitParent persist to source, then fire engine.
	if item:GetAttribute("Transformed") then
		if options.Link ~= nil then
			self:SetLink(item, options.Link, options.LinkMode or "Weld")
		end
		if options.EmitParent ~= nil then
			self:SetEmitParent(item, options.EmitParent)
		end
		local emitCtx = {
			ChainCtx            = options.ChainCtx,
			UseFullOrigin       = options.UseFullOrigin ~= false,
			IgnoreLink          = options.IgnoreLink == true,
		}
		-- linkWins drops the origin so Emit's link branch spawns at the live link.
		if not linkWins then
			emitCtx.EventOriginCF = originCF
			emitCtx.EventOriginResolver = options.OriginResolver
		end
		self:EnableEmit(item, nil, emitCtx)
		return totalDur
	end

	-- (B) Non-transformed 3D container: hybrid two-pass.
	if not (item:IsA("BasePart") or item:IsA("Model") or item:IsA("Attachment")) then
		return 0
	end

	-- Snapshot anchorCF so per-node origin (Pass 1) + clone reposition (Pass 2) both
	-- reference the same authored pivot baseline.
	local anchorCF
	if item:IsA("Model") then
		local ok, p = pcall(item.GetPivot, item); if ok then anchorCF = p end
	elseif item:IsA("BasePart") then anchorCF = item.CFrame
	elseif item:IsA("Attachment") then anchorCF = item.WorldCFrame end

	--[[
		读取实例世界 CFrame；Model 走 GetPivot。

		@param it Instance - Model / Attachment / BasePart
		@return CFrame? - 世界位姿；类型不匹配或 GetPivot 失败为 nil
	]]
	local function _readWorldCF(it)
		if it:IsA("Model") then local ok, cf = pcall(it.GetPivot, it); return ok and cf or nil end
		if it:IsA("Attachment") then return it.WorldCFrame end
		if it:IsA("BasePart") then return it.CFrame end
		return nil
	end

	--[[
		按节点相对 anchor 的偏移，把 originCF 映射到该节点应处的世界原点。

		@param node Instance - Transformed 叶子
		@return CFrame - 覆盖原点
	]]
	local function _originFor(node)
		if not anchorCF then return originCF end
		local nodeCF = _readWorldCF(node)
		if not nodeCF then return originCF end
		return originCF * anchorCF:ToObjectSpace(nodeCF)
	end

	--[[
		为单个 Transformed 节点组装 EnableEmit 上下文（含或不含 EventOriginCF）。

		@param node Instance - Transformed 叶子
		@return table - emitCtx
	]]
	local function _ctxFor(node)
		local c = {
			ChainCtx            = options.ChainCtx,
			UseFullOrigin       = options.UseFullOrigin ~= false,
			IgnoreLink          = options.IgnoreLink == true,
		}
		-- linkWins drops the origin so Emit's link branch spawns at the live link.
		if not linkWins then
			c.EventOriginCF = _originFor(node)
			c.EventOriginResolver = options.OriginResolver
		end
		return c
	end

	-- ApplyToAll: persist Link / EmitParent to every Transformed descendant before Pass 1
	-- so each leaf's GetData read picks up the freshly-written authoring.
	if (options.ApplyToAll or linkWins) and (options.Link ~= nil or options.EmitParent ~= nil) then
		--[[
			把 options.Link / EmitParent 写到每个 Transformed 后代。

			@param node Instance - 当前遍历节点
		]]
		local function _applyAuthoring(node)
			if node:GetAttribute("Transformed") then
				if options.Link ~= nil then
					self:SetLink(node, options.Link, options.LinkMode or "Weld")
				end
				if options.EmitParent ~= nil then
					self:SetEmitParent(node, options.EmitParent)
				end
			end
			for _, child in node:GetChildren() do _applyAuthoring(child) end
		end
		_applyAuthoring(item)
	end

	-- Pass 1: per-node origin override for transformed Part-Icles on the ORIGINAL.
	-- Walks down stopping at each transformed leaf (engine pipeline recurses inside
	-- the leaf's RenderTemplate during emit, so we don't recurse past it ourselves).
	--[[
		只对 Transformed 叶子 EnableEmit；不进入其 RenderTemplate（引擎内部会递归）。

		@param node Instance - 当前遍历节点
	]]
	local function _walkTransformed(node)
		if node:GetAttribute("Transformed") then
			self:EnableEmit(node, nil, _ctxFor(node))
			return
		end
		for _, child in node:GetChildren() do
			_walkTransformed(child)
		end
	end
	_walkTransformed(item)

	-- Internal SkipClone path: caller owns the cloneRoot lifecycle (pool acquire +
	-- positioning + release). Skip Pass 2's clone+anchor+pivot+destroy block; fire
	-- raw native PE/Trail/Beam descendants in-place on the caller's pre-positioned
	-- subtree. Events.luau uses this so its pool reuse + Folder/PE wrappers stay
	-- intact while still picking up Pass 1's per-node origin override semantics.
	if options.SkipClone then
		ParticlesMod.EnableEmit(item, self:_makeAliveCheck())
		return totalDur
	end

	-- Pass 2: detect raw native emitters not covered by Pass 1. Skip Pass 2 entirely
	-- when nothing raw exists (saves the clone cost for pure Part-Icle containers).
	--[[
		desc 到 item 之间是否存在 Transformed 祖先（已被 Pass1 覆盖）。

		@param desc Instance - 原生发射器
		@return boolean - 有 Transformed 祖先为 true
	]]
	local function _underTransformedAncestor(desc)
		local cur = desc.Parent
		while cur and cur ~= item do
			if cur:GetAttribute("Transformed") then return true end
			cur = cur.Parent
		end
		return false
	end
	local hasRawEmitter = false
	for _, desc in ipairs(item:GetDescendants()) do
		if (desc:IsA("ParticleEmitter") or desc:IsA("Trail") or desc:IsA("Beam"))
			and not desc:GetAttribute("Transformed")
			and not _underTransformedAncestor(desc) then
			hasRawEmitter = true; break
		end
	end
	if not hasRawEmitter then return totalDur end

	local ok, clone = pcall(item.Clone, item)
	if not ok or not clone then return totalDur end
	pcall(function() clone.Archivable = false end)

	-- Strip transformed descendants from the clone (Pass 1 fired them on the
	-- original; keeping them in the clone would double-fire + waste the clone of
	-- their 60+ attributes).
	for _, desc in ipairs(clone:GetDescendants()) do
		if desc:GetAttribute("Transformed") then pcall(function() desc:Destroy() end) end
	end

	-- Anchor every remaining BasePart in the clone so PivotTo holds.
	if clone:IsA("BasePart") then pcall(function() clone.Anchored = true end) end
	for _, desc in ipairs(clone:GetDescendants()) do
		if desc:IsA("BasePart") then pcall(function() desc.Anchored = true end) end
	end

	-- Compute target CFrame. UseFullOrigin=true → originCF as-is. UseFullOrigin=false
	-- → use originCF's position with the container's authored rotation.
	local targetCF = originCF
	if not (options.UseFullOrigin ~= false) and anchorCF then
		targetCF = CFrame.new(originCF.Position) * anchorCF.Rotation
	end
	if clone:IsA("Model") then
		pcall(function() clone:PivotTo(targetCF) end)
	elseif clone:IsA("BasePart") then
		pcall(function() clone.CFrame = targetCF end)
	elseif clone:IsA("Attachment") then
		pcall(function() clone:Destroy() end)
		return totalDur
	end

	clone.Parent = self:GetFolder()
	-- Fire raw dispatch on the stripped clone. Transformed branch in _absoluteEmitFire
	-- is unreachable post-strip; only the raw PE / Trail / Beam / native-walk branches fire.
	self:_absoluteEmitFire(clone, nil, nil)

	-- Destroy clone after full emit window. Cap at 60s for infinite-duration emitters
	-- so the clone doesn't leak when totalDur is nil.
	local destroyDelay = totalDur or INFINITE_CLONE_DESTROY_DELAY
	task.delay(destroyDelay, function()
		if clone and clone.Parent then pcall(function() clone:Destroy() end) end
	end)

	return totalDur
end

-- Particle:EnableEmitAt lives in Lifecycle.luau alongside EnableEmit / EmitAnimate /
-- Disable so the emission-control public APIs share a file. Same module-mixin pattern.

-- AbsoluteEnable / AbsoluteDisable live in Lifecycle.luau alongside Particle:Disable so the
-- single-item and recursive-state APIs share a file. Same recursion shape as AbsoluteEmit
-- (Transformed → engine path; raw PE/Trail → native .Enabled; container → walk descendants
-- skipping transformed sub-emitter RTs).

--[[
	是否可作为纹理预加载目标（Transformed 或原生 PE/Trail）。

	@param i Instance - 待判断实例
	@return boolean - 可预加载为 true
]]
local function _isPreloadable(i) return i:GetAttribute("Transformed") or i:IsA("ParticleEmitter") or i:IsA("Trail") end

--[[
	遍历 root 子树，对符合 PreloadTexture / force 的节点执行 action。

	@param root Instance? - 根；nil 直接返回
	@param force boolean? - true 时忽略 PreloadTexture 开关
	@param action (Instance) -> () - pin 或 unpin
]]
local function _walk(root, force, action)
	if not root then return end
	--[[
		递归访问单个实例及其子节点。

		@param inst Instance - 当前节点
	]]
	local function _visit(inst)
		if _isPreloadable(inst) and (force or inst:GetAttribute("PreloadTexture") == true) then action(inst) end
		for _, c in inst:GetChildren() do _visit(c) end
	end
	_visit(root)
end

--[[
	钉住 root 下 PreloadTexture=true（或 force）的纹理，避免首次发射解码卡顿。

	@param root Instance - 扫描根
	@param force boolean? - true 时钉住所有 Transformed / 原生 PE / Trail
]]
function Particle:Preload(root, force) _walk(root, force, TexturePinMod.pinSubtree) end

--[[
	释放 Preload 钉住的纹理，便于退役技能后回收 GPU。

	@param root Instance - 扫描根
	@param force boolean? - 与 Preload 同一选择规则
]]
function Particle:Deload(root, force) _walk(root, force, TexturePinMod.unpinSubtree) end

Particle.LinkService = LinkServiceMod

--[[
	把源 item 的 authored Link 写成 Object / Camera / None。EnableEmitAt 的 Link 选项是一次性的。

	@param item Instance - 须已 Transformed
	@param target (Instance | string)? - Instance 写 Object；"camera" 写 Camera；nil 写 None
	@param mode string? - Follow / Pivot / Weld / WeldWithoutRotation
]]
function Particle:SetLink(item, target, mode)
	if not item or not item:GetAttribute("Transformed") then return end
	if target == "camera" then
		pcall(function() item:SetAttribute("LinkSource", "Camera") end)
	elseif target == nil then
		pcall(function() item:SetAttribute("LinkSource", "None") end)
		local lk = item:FindFirstChild("Link")
		if lk and lk:IsA("ObjectValue") then lk.Value = nil end
	elseif typeof(target) == "Instance" then
		local lk = item:FindFirstChild("Link")
		if not lk then
			lk = Instance.new("ObjectValue")
			lk.Name = "Link"
			lk.Parent = item
		end
		lk.Value = target
		pcall(function() item:SetAttribute("LinkSource", "Object") end)
	end
	if mode then pcall(function() item:SetAttribute("LinkMode", mode) end) end
end

--[[
	设置克隆视觉的父级。nil 删除 EmitParent，回落到引擎默认发射 Folder。

	@param item Instance - 须已 Transformed
	@param parent Instance? - 目标父级；nil 清除
]]
function Particle:SetEmitParent(item, parent)
	if not item or not item:GetAttribute("Transformed") then return end
	if parent == nil then
		local ep = item:FindFirstChild("EmitParent")
		if ep then pcall(function() ep:Destroy() end) end
		return
	end
	if typeof(parent) ~= "Instance" then return end
	local ep = item:FindFirstChild("EmitParent")
	if not ep then
		ep = Instance.new("ObjectValue")
		ep.Name = "EmitParent"
		ep.Parent = item
	end
	ep.Value = parent
end

-- Luau autocomplete + IntelliSense: the mixin pattern `require(script.X)(Particle)`
-- attaches methods at runtime, which Luau's static analyzer cannot follow. The cast
-- below tells the analyzer the public shape so users typing `Part:` see every API.
-- Field types are conservative (Instance + any) since most accept multiple authoring
-- types via internal dispatch (BasePart / Attachment / Model / Beam / etc.).
export type ParticleAPI = {
	-- Lifecycle
	Activate: (self: ParticleAPI) -> (),
	Deactivate: (self: ParticleAPI) -> (),
	Enable: (self: ParticleAPI, item: Instance, link: Instance?, duration: number?, emitCtx: any?) -> (),
	Disable: (self: ParticleAPI, item: Instance) -> (),
	SoftDisable: (self: ParticleAPI, item: Instance) -> (),
	AbsoluteEnable: (self: ParticleAPI, item: Instance) -> (),
	AbsoluteDisable: (self: ParticleAPI, item: Instance) -> (),

	-- Emit
	Emit: (self: ParticleAPI, item: Instance, link: Instance?, emitCtx: any?) -> (),
	EmitAnimate: (self: ParticleAPI, item: Instance, link: Instance?, emitCtx: any?) -> (),
	EnableEmit: (self: ParticleAPI, item: Instance, link: Instance?, emitCtx: any?) -> (),
	EnableEmitAt: (self: ParticleAPI, item: Instance, originCF: CFrame, options: {[string]: any}?) -> (),
	AbsoluteEmit: (self: ParticleAPI, item: Instance, _parentFiredPE: boolean?, emitCtx: any?) -> number?,
	AbsoluteEmitAt: (self: ParticleAPI, item: Instance, originCF: CFrame, options: {[string]: any}?) -> number?,

	-- Timescale
	SetTimescale: (self: ParticleAPI, item: Instance, scale: number, duration: number?, permanent: boolean?) -> (),
	ClearTimescale: (self: ParticleAPI, item: Instance) -> (),
	AbsoluteSetTimescale: (self: ParticleAPI, item: Instance, scale: number, duration: number?, permanent: boolean?) -> (),
	AbsoluteClearTimescale: (self: ParticleAPI, item: Instance) -> (),

	-- Authoring + utilities
	Transform: (self: ParticleAPI, part: Instance) -> (),
	TransformModel: (self: ParticleAPI, model: Model, typeDef: any) -> (),
	Preload: (self: ParticleAPI, root: Instance, force: boolean?) -> (),
	Deload: (self: ParticleAPI, root: Instance, force: boolean?) -> (),
	SetLink: (self: ParticleAPI, item: Instance, target: (Instance | string)?, mode: string?) -> (),
	SetEmitParent: (self: ParticleAPI, item: Instance, parent: Instance?) -> (),
	GetData: (self: ParticleAPI, item: Instance) -> any,
	GetFolder: (self: ParticleAPI) -> Folder,
	GetPoolFolder: (self: ParticleAPI) -> Folder,
	ReapplyLink: (self: ParticleAPI, pData: any) -> (),

	-- Statics
	await: (n: number?) -> (),
	parseDuration: (raw: any) -> number?,
	LinkService: typeof(require(script.LinkService)),
	TransformCompleted: BindableEvent,
	Beam: {[string]: any},
	MAX_ACTIVE_PARTICLES: number,
}

return Particle :: ParticleAPI
