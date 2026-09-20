--[[
	Module: PartIcles.Engine
	Description: Heartbeat 主循环与 Activate / Deactivate / GetFolder / GetPoolFolder
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-09-01

	mixin：return function(Particle) 挂到 PartIcles 实例。
	Activate 连接逐帧更新；Deactivate 对称拆解（池、ScreenHost、Events、LinkService）。
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local RunService = Utils.RunService
local UIS = Utils.UserInputService
local Lighting = Utils.Lighting
local ReplicatedStorage = Utils.ReplicatedStorage
local StarterGui = Utils.StarterGui
local StarterPack = Utils.StarterPack
local ReplicatedFirst = Utils.ReplicatedFirst

local GraphMod = require(script.Parent.Graph)
local RangeMod = require(script.Parent.Range)
local ParticlesMod = require(script.Parent.Particles)
local AxisLinksMod = require(script.Parent.AxisLinks)
local EventsMod = require(script.Parent.Events)
local EventsCollision = require(script.Parent.EventsCollision)
local Pool = require(script.Parent.Pool)
local Constants = require(script.Parent.PartConstants)
local StaticPass = require(script.Parent.StaticPass)
local ScreenHost = require(script.Parent.ScreenHost)
local TexturePin = require(script.Parent.TexturePin)

return function(Particle)

--[[
	启动 Heartbeat 主循环。每帧遍历 _activeEmits 调 UpdateX；AnimateLoop 重放，死亡 swap-and-pop。
	已激活则直接返回。同时重连焦点监听并 Preload 场景纹理。
]]
function Particle:Activate()
	if self._connection then return end

	-- Bump engine-session gen so pending closures from prior sessions bail.
	self._engineGen = (self._engineGen or 0) + 1

	-- Reset the not-activated warning latch so a Deactivate → Emit cycle re-warns
	-- on each new Activate session.
	self._notActivatedWarned = false

	-- Reconnect focus listeners (disconnected in Deactivate). Client-only.
	if RunService:IsClient() then
		if not self._focusConn then
			self._focusConn = UIS.WindowFocused:Connect(function()
				self._focused = true
				self._unfocusedAt = 0
			end)
		end
		if not self._blurConn then
			self._blurConn = UIS.WindowFocusReleased:Connect(function()
				self._focused = false
				self._unfocusedAt = os.clock()
			end)
		end
	end

	-- Pin textures for PreloadTexture=true items already in scene.
	for _, service in ipairs({
		workspace,
		Lighting,
		ReplicatedStorage,
		StarterGui,
		StarterPack,
		ReplicatedFirst,
	}) do
		pcall(function() self:Preload(service, false) end)
	end

	self._connection = RunService.Heartbeat:Connect(function(dt)
		EventsMod.tickFrame()
		-- Pool tick before the empty-emits early-return so idle pools still TTL-evict.
		local currentTime = os.clock()
		Pool.tick(currentTime)
		local emits = self._activeEmits
		if #emits == 0 then return end
		local camPos; do local cam = workspace.CurrentCamera; if cam then camPos = cam.CFrame.Position end end
		local i = 1

		while i <= #emits do
			local pData = emits[i]
			-- _forceDead (payload.Kill) short-circuits the per-type Update for immediate death.
			local isDead = pData._forceDead == true
			-- Capture step pre-Update so the post-Update cache refresh detects step advance for unlinked particles.
			local prevStep = pData.CurrentStep

			if not isDead then
				if pData.Type == "Part" then
					isDead = self:UpdatePart(pData, dt, currentTime)
				elseif pData.Type == "Beam" then
					isDead = self:UpdateBeam(pData, dt, currentTime)
				elseif pData.Type == "PointLight" then
					isDead = self:UpdatePointLight(pData, dt, currentTime)
				elseif pData.Type == "Highlight" then
					isDead = self:UpdateHighlight(pData, dt, currentTime)
				elseif pData.Type == "TrailEmitter" then
					isDead = self:UpdateTrail(pData, dt, currentTime)
				elseif pData.Type == "Attachment" then
					isDead = self:UpdateAttachment(pData, dt, currentTime)
				elseif pData.Type == "Model" then
					isDead = self:UpdateModel(pData, dt, currentTime)
				elseif pData.Type == "Screen" then
					isDead = self:UpdateScreen(pData, dt, currentTime)
				elseif pData.Type == "ImageLabel" then
					isDead = self:UpdateImageLabel(pData, dt, currentTime)
				end
			end

			-- Per-frame passes run outside the step gate for smooth tracking between keyframes.
			-- Skip on dead particles to avoid one extra wasted frame + last-frame flicker.
			-- `_postUpdateCF` caches the pre-overlay base CFrame so Orientation and ZOffset
			-- can apply as ABSOLUTE overlays. Refresh whenever Update wrote a fresh CFrame
			-- this frame (CurrentStep advanced) or ReapplyLink writes one (every frame for
			-- linked particles). Unlinked between-step frames retain the last step's cache
			-- as the correct overlay base.
			if not isDead then
				if pData.Link then self:ReapplyLink(pData) end
				-- Settle pass post-Update so gravity-torque composes after step rotation.
				local t = pData.Type
				if pData._settleEngaged and not pData._collisionStopped
					and (t == "Part" or t == "Model" or t == "Attachment") then
					EventsCollision.applySettle(pData, dt)
				end
				-- Only Part / Model / Attachment consume `_postUpdateCF` via overlays. Beam,
				-- PointLight, Screen, ImageLabel have no `.CFrame` property  -  gate the cache
				-- write to the consumer types so a Beam with Link doesn't error every Heartbeat.
				if (t == "Part" or t == "Model" or t == "Attachment") and (pData.Link or pData.CurrentStep ~= prevStep) then pData._postUpdateCF = (t == "Model") and pData.VisualPart:GetPivot() or pData.VisualPart.CFrame end
				if pData.Orientation and pData.Orientation ~= "None" then self:ApplyOrientation(pData, dt, camPos) end
				if pData.ZOffset and pData.ZOffset ~= 0 then self:ApplyZOffset(pData, camPos) end
			end

			-- OnHit raycast: AFTER all visual-pass CFrame writes (ReapplyLink + Orientation
			-- + ZOffset), so the segment matches the rendered position rather than the
			-- mid-pass intermediate. Internal pData.Events.OnHit gate makes this a cheap
			-- no-op when not configured. Runs even on death frame so fast particles don't
			-- have a blind segment between last-update and removal.
			EventsMod.afterUpdate(self, pData, isDead, currentTime)

			if isDead then
				-- OnDeath fires before any swap-and-pop / animate restart. AnimateLoop
				-- replay also fires OnDeath every cycle boundary; replay branch resets
				-- _killedManually after this fire so the new cycle starts clean.
				self:_fireOnDeath(pData)
				if pData.IsAnimate then
					if pData.AnimateItem and pData.AnimateItem.Parent and pData.AnimateItem:GetAttribute("AnimateLoop") then
						-- Reset and replay  -  re-read properties so live edits take effect.
						pData.StartTime = currentTime
						pData.CurrentStep = 0
						if pData.AccumulatedDT then pData.AccumulatedDT = 0 end
						if pData.InitialLocalCF then pData.LocalCF = pData.InitialLocalCF end
						if pData.AccRotX then pData.AccRotX = 0; pData.AccRotY = 0; pData.AccRotZ = 0 end
						-- Reset accumulated target-acceleration velocity so each loop iteration
						-- starts fresh from the base trajectory.
						if pData.TargetVel then pData.TargetVel = Vector3.zero end
						-- Reset OnHit Collision-mode state so each cycle replays from a clean
						-- slate (otherwise _collisionStopped / spin / SpeedMultiplier / reflected
						-- _accelVel compound across cycles). BaseDirection restored from the
						-- emit-time snapshot.
						pData._collisionStopped = false
						pData._spinRate = Vector3.zero
						pData._spinAccumX = 0
						pData._spinAccumY = 0
						pData._spinAccumZ = 0
						pData.SpeedMultiplier = 1
						if pData._accelVel then pData._accelVel = Vector3.zero end
						if pData._prevWorldOff then
							pData._prevWorldOff = Vector3.zero
							-- Drop OnHit-bounce mirror axes so each AnimateLoop cycle starts
							-- with un-mirrored trajectory state matching emit-time baseline.
							pData._displacementMirrorX = nil
							pData._displacementMirrorY = nil
							pData._displacementMirrorZ = nil
							-- Apply PosOffset(0) so cycle restart matches emit-time spawn pose
							-- (front-loaded curves would otherwise pop on the first step).
							if pData.HasPosOffsetGraphs and pData.Graphs and pData.SpawnRotation then
								local oX = pData.Graphs.PosOffsetX and GraphMod.QueryPointsWithTime(0, pData.Graphs.PosOffsetX, pData.Seeds.PosOffsetX) or 0
								local oY = pData.Graphs.PosOffsetY and GraphMod.QueryPointsWithTime(0, pData.Graphs.PosOffsetY, pData.Seeds.PosOffsetY) or 0
								local oZ = pData.Graphs.PosOffsetZ and GraphMod.QueryPointsWithTime(0, pData.Graphs.PosOffsetZ, pData.Seeds.PosOffsetZ) or 0
								if oX ~= 0 or oY ~= 0 or oZ ~= 0 then
									local worldOff = Constants.resolveDisplacement(Vector3.new(oX, oY, oZ),
										pData.DisplacementMode or "Global", pData.SpawnRotation, pData.SpawnEmitterRotation)
									pData._prevWorldOff = worldOff
									pData.LocalCF = pData.LocalCF + worldOff
									if pData.VisualPart and pData.VisualPart.Parent then
										if pData.Type == "Model" then
											pcall(function() pData.VisualPart:PivotTo(pData.VisualPart:GetPivot() + worldOff) end)
										else
											pData.VisualPart.CFrame = pData.VisualPart.CFrame + worldOff
										end
									end
								end
							end
						end
						if pData._initialBaseDirection then pData.BaseDirection = pData._initialBaseDirection end
						pData._lastOrientPos = nil
						-- Reset LinkTrack base (`_localWorldCF`) and overlay base (`_postUpdateCF`)
						-- so that on the first no-step frames of the new cycle, ApplyOrientation /
						-- ApplyZOffset compose against the replay's initial pose, not the last
						-- cycle's terminal pose.
						pData._localWorldCF, pData._postUpdateCF = pData.InitialLocalCF, pData.InitialLocalCF
						-- Clear GraphBlender state-search caches so next frame's monotonic-t search
						-- restarts from index 1. Otherwise the cached lastIdx points past the new
						-- t≈0, the search no-ops, and LerpGraph extrapolates with a negative alpha.
						pData._lastTransIdx = nil; pData._lastColorIdx = nil
						-- Stale-data fallback if freshData is nil. Fresh-data path overrides
						-- this AFTER the per-cycle refresh so the new Timescale + LifeTime apply.
						pData._effectiveElapsed = GraphMod.InitialEffectiveElapsed(pData.Graphs and pData.Graphs.Timescale, pData.Seeds and pData.Seeds.Timescale, pData.LifeTime)
						pData._hitHistory = nil
						if pData.Type == "ImageLabel" then pData.PosX = 0; pData.PosY = 0; pData.EnvVelX = 0; pData.EnvVelY = 0; pData.AccRot = 0 end
						local freshData = self:GetData(pData.AnimateItem)
						if freshData then
							pData.Events = freshData.Events
							pData._killedManually = false
							pData._fireOnDeathOverride = false
							pData._hitFired = false
							pData.LifeTime = RangeMod.RandomValueFromRange(freshData.Lifetime)
							if pData.LifeTime <= 0 then pData.LifeTime = 0.001 end
							pData.TotalKeyFrames = math.max(1, freshData.TotalKeyFrames)
							if freshData.ParticleData then
								pData.Acceleration = freshData.ParticleData.Acceleration
								pData.Drag = freshData.ParticleData.Drag
								pData.HasDrag = freshData.ParticleData.Drag ~= 0
								pData.HasAccel = freshData.ParticleData.Acceleration.Magnitude > 0
							end
							-- Refresh cached flags that affect simulation behavior. Loop-restart honors
							-- live edits to AccelerationTowardsInstance / AccelTarget / InvertMotion.
							-- Target-accel is frame-granularity in branches 3/4 (one sample per
							-- Heartbeat) so it doesn't force NeedsFullIteration; only VelocityVectored
							-- does, because direction feedback requires per-step CFrame writes.
							pData.InvertMotion = freshData.InvertMotion or false
							pData.AccelTarget = freshData.AccelTarget
							pData.HasTargetAccel = freshData.AccelerationTowardsInstance == true and freshData.AccelTarget ~= nil and freshData.AccelStrength ~= nil and not pData.InvertMotion
							pData.TargetVel = Vector3.zero
							if freshData.VelocityVectored ~= nil then pData.VelocityVectored = freshData.VelocityVectored end
							pData.NeedsFullIteration = pData.VelocityVectored or false
							if freshData.RotMode then pData.RotMode = freshData.RotMode; pData.NeedsRotAccum = (freshData.RotMode == "Speed") and not (pData.VelocityVectored or false) end
							-- Refresh Link + LinkMode so a mid-loop LinkSource flip (None → Camera)
							-- takes effect on the next animate cycle. ReapplyLink reads pData.Link
							-- per frame, so updating it here is enough.
							pData.Link = freshData.Link
							pData.LinkMode = freshData.LinkMode
							-- RigidLocal: re-snapshot the link's current pose so each new cycle
							-- locks to where the emitter is NOW, not where it was at first emit.
							if pData.LinkMode == "RigidLocal" and pData.Link and pData.Link.Parent then
								pData._rigidLocalParentCF = Constants.resolveLinkCFrame(pData.Link)
							end
							-- Refresh non-spatial setup fields via the per-type helpers. Spatial
							-- LocalCF rebuild (3D) and image-display refresh (2D) live in those helpers.
							if pData.Type == "ImageLabel" then
								self:_refreshImageLabelAnimateNonSpatial(pData, freshData)
							else
								self:_refreshAnimateNonSpatial(pData, freshData)
							end
							-- Restore any graphs the prior cycle's StaticPass nil'd so refreshLoopGraphsAndSeeds'
							-- pairs(pData.Graphs) iteration picks them up. Static-pass at end of block
							-- re-detects + re-nils as appropriate.
							StaticPass.restoreFromFreshData(pData, freshData)
							AxisLinksMod.refreshLoopGraphsAndSeeds(pData, freshData, GraphMod)
							-- Re-detect static graphs from fresh pData.Graphs. Idempotent: clears
							-- stale _static<Name> fields so a graph switched from static→dynamic mid-
							-- cycle re-arms the per-frame sample path. ImageLabel SizeScale both-axes-
							-- static collapse mirrored from buildImageLabelPData so the per-frame Size
							-- block short-circuits (frame-0 wrote the constant Size).
							StaticPass.apply(pData)
							if pData.Type == "ImageLabel"
								and pData._staticSizeScaleX and pData._staticSizeScaleY then
								pData._staticSizeScaleX = nil
								pData._staticSizeScaleY = nil
							end
							-- Must run after fresh Timescale graph + LifeTime are in place.
							pData._effectiveElapsed = GraphMod.InitialEffectiveElapsed(pData.Graphs and pData.Graphs.Timescale, pData.Seeds and pData.Seeds.Timescale, pData.LifeTime)
							-- ImageLabel InvertMotion: re-seed end-state for next cycle (mirrors the
							-- emit-time setup in buildImageLabelPData) so each cycle integrates from
							-- the inverted end-pose with negative dt.
							if pData.Type == "ImageLabel" then
								-- ImgInvertMotion lives under its raw attribute name (GetData reads it
								-- directly, no TypeRegistry attrName mapping into freshData.InvertMotion).
								pData.InvertMotion = freshData.ImgInvertMotion or false
								if pData.InvertMotion then
									local endX, endY, endVelX, endVelY = self:_computeImageLabelEndState(freshData, pData.DirX or 0, pData.DirY or 0, pData.LifeTime, pData.Seeds)
									pData.PosX, pData.PosY = endX, endY
									pData.EnvVelX, pData.EnvVelY = endVelX, endVelY
									pData._effectiveElapsed = pData.LifeTime
									pData._invertDtSign = -1
								else
									pData._invertDtSign = nil
								end
							end
							-- Rebuild SimLocalCFrames whenever InvertMotion is true. Loop restart
							-- can land on a different InvertMotion / TotalKeyFrames than the last
							-- cycle, and inverted UpdatePart indexes the cache by step. Drop the
							-- cache on InvertMotion=false so a later flip-on triggers a fresh build.
							if pData.InvertMotion and pData.AnimateItem and pData.AnimateItem.Parent then
								local restartCF
								local isAttachment = pData.Type == "Attachment"
								if pData.Type == "Model" then
									local ok, cf = pcall(function() return pData.AnimateItem:GetPivot() end)
									if ok then restartCF = cf end
								elseif isAttachment then
									-- Parent-local; matches EmitAnimate's `localCF = attachment.CFrame`.
									restartCF = pData.AnimateItem.CFrame
								elseif pData.AnimateItem:IsA("BasePart") then
									restartCF = pData.AnimateItem.CFrame
								end
								if restartCF then
									local ok2, sim, effTKF = pcall(function()
										if isAttachment then
											return self:PreSimulateAttachmentForward(freshData, pData.Seeds, restartCF, pData.BaseDirection, pData.SpreadRotation, pData.LifeTime, nil, pData.SpawnEmitterRotation)
										else
											return self:PreSimulateForward(freshData, pData.Seeds, restartCF, pData.BaseDirection, pData.SpreadRotation, pData.Link, pData.LifeTime, nil, pData.SpawnEmitterRotation)
										end
									end)
									if ok2 then
										pData.SimLocalCFrames = sim
										if effTKF then pData.TotalKeyFrames = effTKF end
									end
								end
							elseif not pData.InvertMotion then
								pData.SimLocalCFrames = nil
							end
							-- Beam: rebuild AnimatedProps + GraphBlender states from fresh data. Also
							-- refresh cached _baseWidth0/Width1/CurveSize0/CurveSize1/TextureLength/
							-- Segments from the source's CURRENT values so live edits to non-animated
							-- graph props propagate into the next animate-loop iteration.
							if pData.Type == "Beam" and freshData.BeamProps then
								local vb = pData.VisualPart
								local ap = {}
								for name, sequence in pairs(freshData.BeamProps) do
									if sequence then
										if GraphMod.IsStatic(sequence) then
											if vb then vb[name] = GraphMod.GetStaticValue(sequence, vb[name]) end
										else ap[name] = { Sequence = sequence, Seed = GraphMod.GenerateSeed(sequence) } end
									end
								end
								pData.AnimatedProps = ap
								if vb then
									pData._baseWidth0 = vb.Width0
									pData._baseWidth1 = vb.Width1
									pData._baseCurveSize0 = vb.CurveSize0
									pData._baseCurveSize1 = vb.CurveSize1
									pData._baseTextureLength = vb.TextureLength
									pData._baseSegments = vb.Segments
								end
								if ap.TextureSpeed and vb then vb.TextureSpeed = 0 end
								if freshData.GraphBlender then
									local ts, cs = GraphMod.CollectGraphStates(freshData.GraphBlender)
									pData.TransStates = ts; pData.ColorStates = cs
									local tmt = {}; for idx = 1, #ts - 1 do tmt[idx] = GraphMod.PrecomputeMergedTimes(ts[idx].Graph, ts[idx+1].Graph) end
									local cmt = {}; for idx = 1, #cs - 1 do cmt[idx] = GraphMod.PrecomputeMergedColorTimes(cs[idx].Graph, cs[idx+1].Graph) end
									pData.TransMergedTimes = tmt; pData.ColorMergedTimes = cmt
									if #ts > 0 and vb then vb.Transparency = ts[1].Graph end
									if #cs > 0 and vb then vb.Color = cs[1].Graph end
								end
							end
							if freshData.PLRange then pData.PLRange = freshData.PLRange end
							if freshData.PLBrightness then pData.PLBrightness = freshData.PLBrightness end
							if freshData.PLColor then pData.PLColor = freshData.PLColor end
						end
						-- Animate-loop replay reset target: read source's CURRENT CFrame each cycle so
						-- parent moves carry through (cached InitialAnchorCF would freeze at emit-time pose).
						if pData.AnimateItem and pData.AnimateItem.Parent and pData.VisualPart and pData.VisualPart.Parent then
							if pData.Type == "Model" then
								local ok, sourceCF = pcall(function() return pData.AnimateItem:GetPivot() end)
								if ok and sourceCF then pData.VisualPart:PivotTo(sourceCF) end
							elseif pData.AnimateItem:IsA("BasePart") then
								pData.VisualPart.CFrame = pData.AnimateItem.CFrame
							elseif pData.AnimateItem:IsA("Attachment") then
								-- RT is a CHILD of the source Attachment; identity preserves the
								-- parent-local invariant established by Transform.luau:96. Writing
								-- source.CFrame here bakes the source's own offset INTO the RT.
								pData.VisualPart.CFrame = CFrame.new()
							end
						end
						-- Nested re-emit on AnimateLoop cycle restart. Mirrors the descendant
						-- walk done at first EmitAnimate (EmitAnimate.luau:278-282). Per-iteration
						-- re-fire is required because nested children's emit cycle is finite
						-- (EmissionMode=Emit) or replaces its pData (EmissionMode=Animate);
						-- without this, nested children go silent after the first parent cycle.
						-- _emitGen is bypassed for nested-driven EnableEmit (see Lifecycle.luau)
						-- so prior cycle's still-flying nested closures aren't killed.
						if pData.AnimateItem and pData.VisualPart and pData.VisualPart.Parent then
							for _, desc in pData.VisualPart:GetDescendants() do
								if desc:GetAttribute("Transformed") then
									self:EnableEmit(desc, desc.Parent)
								end
							end
						end
						self:_fireAnimateCycleRestartEvents(pData)
						i += 1
					else
						-- One-shot animate finish. PartLife keeps the visual at its last frame for N
						-- seconds before position reset + hide.
						local visualPart = pData.VisualPart
						local pType = pData.Type
						local initialAnchorCF = pData.InitialAnchorCF
						local initialScale = pData.InitialScale
						local hasDecal = pData.HasDecal
						local animateItem = pData.AnimateItem
						local partLife = pData.PartLife or 0
						local isSharedRT = (pType == "Part" or pType == "Attachment" or pType == "Model" or pType == "Beam")
						-- Per-cycle finish token. Each Animate cycle bumps `_animateFinishGen`
						-- on the source item; this finish closure captures the value at schedule
						-- time and bails if a newer cycle has armed its own finish since.
						local finishGen
						if animateItem then
							finishGen = (animateItem:GetAttribute("_animateFinishGen") or 0) + 1
							pcall(function() animateItem:SetAttribute("_animateFinishGen", finishGen) end)
						end
						--[[
							单次 Animate 收尾：还原锚点/缩放/快照，隐藏或销毁视觉。
							共享 RT 上若已有新 _activeAnimates，或 `_animateFinishGen` 已前进，则退出。
						]]
						local function _finishAnimate()
							if not visualPart or not visualPart.Parent then return end
							if isSharedRT and animateItem and self._activeAnimates[animateItem] then return end
							if animateItem and animateItem.Parent and finishGen and animateItem:GetAttribute("_animateFinishGen") ~= finishGen then return end
							-- OnDestruction fires JUST BEFORE the visual is restored/destroyed/hidden.
							-- AnimateLoop replay doesn't reach here (death-handler restarts cycle
							-- without calling _finishAnimate), so this is genuinely terminal.
							self:_fireOnDestruction(pData, visualPart)
							if initialAnchorCF then
								if pType == "Model" then
									pcall(function() visualPart:PivotTo(initialAnchorCF) end)
									if initialScale then pcall(function() visualPart:ScaleTo(initialScale) end) end
								else pcall(function() visualPart.CFrame = initialAnchorCF end) end
							end
							if pType == "Screen" or pType == "ImageLabel" then
								pcall(function() visualPart:Destroy() end)
							elseif pType == "Beam" or pType == "Highlight" or pType == "TrailEmitter" then
								local snap = pData.BeamSnapshot or pData.HighlightSnapshot or pData.TrailEmitterSnapshot
								if snap then
									pcall(function() for k, v in pairs(snap) do visualPart[k] = v end end)
								end
								pcall(function() visualPart.Enabled = false end)
							else
								pcall(function()
									visualPart.Transparency = 1
									if hasDecal then local d = visualPart:FindFirstChildOfClass("Decal"); if d then d.Transparency = 1 end end
									local sa = pData._initialSAColor and visualPart:FindFirstChildOfClass("SurfaceAppearance")
									if sa then sa.Color = pData._initialSAColor end
									if pData._initialPartColor and visualPart:IsA("BasePart") then visualPart.Color = pData._initialPartColor end
								end)
							end
						end
						-- Clear _activeAnimates BEFORE running _finishAnimate (see prior comment block).
						self._activeAnimates[animateItem] = nil
						if partLife > 0 then task.delay(partLife, _finishAnimate) else _finishAnimate() end
						if pData._scaleMapKeys and self._parentScaleMap then
							for _, desc in ipairs(pData._scaleMapKeys) do
								self._parentScaleMap[desc] = nil
							end
						end
						if pData._nestedAlive then pData._nestedAlive[1] = false end
						local n = #emits
						if i < n then emits[i] = emits[n] end
						emits[n] = nil
					end
				else
					-- Normal emit: destroy visual, swap-and-pop. OnDestruction fires JUST
					-- BEFORE destroy (immediate path) or inside the deferred closure (linger
					-- path) so user scripts read the final pose pre-destroy.
					local visualPart = pData.VisualPart
					if pData.PartLife and pData.PartLife > 0 then
						-- Track this visualPart in self._lingerByItem so Particle:Disable
						-- can destroy linger clones early when Stop fires. Also bump the
						-- linger visual counter so MAX_ACTIVE_PARTICLES reflects rendered
						-- linger clones; flag the visual so each path that destroys it
						-- decrements at most once.
						local source = pData._sourceItem
						if source and visualPart then
							self._lingerByItem = self._lingerByItem or {}
							local list = self._lingerByItem[source] or {}
							table.insert(list, visualPart)
							self._lingerByItem[source] = list
							pcall(function() visualPart:SetAttribute("_lingerCounted", true) end)
							self._lingerVisualCount += 1
						end
						-- Stamp linger start so OnDestruction's payload.LingerElapsed
						-- can report actual time-in-linger when fired (early-Disable
						-- destroys mid-linger; full PartLife when delay completes).
						pData._lingerStartTime = os.clock()
						task.delay(pData.PartLife, function()
							self:_fireOnDestruction(pData, visualPart)
							if visualPart then
								local counted = false
								pcall(function() counted = visualPart:GetAttribute("_lingerCounted") == true end)
								if counted then
									self._lingerVisualCount = math.max(0, (self._lingerVisualCount or 0) - 1)
									pcall(function() visualPart:SetAttribute("_lingerCounted", nil) end)
								end
								-- Pool-eligible if non-animate and pData has source RT stamps
								-- (Emit.luau / EmitModel.luau / PointLight.luau set them).
								self:_releaseOrDestroy(pData, visualPart)
							end
							if source and self._lingerByItem and self._lingerByItem[source] then
								local list = self._lingerByItem[source]
								for k = #list, 1, -1 do
									if list[k] == visualPart then
										local n = #list
										if k < n then list[k] = list[n] end
										list[n] = nil
									end
								end
								if #list == 0 then self._lingerByItem[source] = nil end
							end
						end)
					else
						-- PartLife=0: OnDestruction same-frame as OnDeath, then release/destroy.
						self:_fireOnDestruction(pData, visualPart)
						self:_releaseOrDestroy(pData, visualPart)
					end
					if pData._scaleMapKeys and self._parentScaleMap then
						for _, desc in ipairs(pData._scaleMapKeys) do
							self._parentScaleMap[desc] = nil
						end
					end
					if pData._nestedAlive then pData._nestedAlive[1] = false end
					local n = #emits
					if i < n then emits[i] = emits[n] end
					emits[n] = nil
				end
			else
				i += 1
			end
		end
	end)
end

--[[
	关闭引擎：断开 Heartbeat、销毁在飞克隆、取消循环、还原 Animate 源、清纹理钉。
	可重复调用。先抬 _engineGen，让挂起的 EnableEmit / Enable 闭包自行退出。
]]
function Particle:Deactivate()
	-- Bump engine-session generation FIRST. Any pending EnableEmit / Enable
	-- task.delay closure that captured the prior gen will now bail via
	-- genStillCurrent's `self._engineGen == engineGen` check, instead of
	-- spawning particles after teardown disconnected the Heartbeat.
	self._engineGen = (self._engineGen or 0) + 1
	if self._connection then
		self._connection:Disconnect()
		self._connection = nil
	end
	-- Disconnect UIS focus tracking  -  module reload would otherwise leak the two
	-- WindowFocused/WindowFocusReleased connections firing on dead-module closures.
	if self._focusConn then self._focusConn:Disconnect(); self._focusConn = nil end
	if self._blurConn then self._blurConn:Disconnect(); self._blurConn = nil end
	if self._parentScaleMap then table.clear(self._parentScaleMap) end
	if self._lingerByItem then table.clear(self._lingerByItem) end
	if self._evenCycleStore then table.clear(self._evenCycleStore) end
	-- Pending PartLife linger closures hold no engineGen guard, so they continue
	-- decrementing past Deactivate. Zero the counter here so a quick Off→On toggle
	-- doesn't see an inflated _lingerVisualCount restricting fresh emits via the cap
	-- check. The math.max(0, ... - 1) guard in the closure tolerates the reset.
	self._lingerVisualCount = 0
	-- Clean up all active particles. Skip 3D animate-mode pData: their VisualPart IS the source's
	-- live RenderTemplate child (not a clone)  -  destroying it would orphan the source instance.
	-- Flush pool BEFORE iterating _activeEmits  -  pool entries are non-active clones we
	-- own; their Destroy is bookkeeping-light and short-circuits the workspace _sweep
	-- below from finding them (the _sweep matches on _PartIcleEmit attribute, which
	-- pooled entries still carry).
	Pool.flushAll()
	for i = #self._activeEmits, 1, -1 do
		local pData = self._activeEmits[i]
		local skip = pData.IsAnimate and (pData.Type == "Part" or pData.Type == "Attachment"
			or pData.Type == "Beam" or pData.Type == "Model")
		if not skip and pData.VisualPart then
			pcall(function() pData.VisualPart:Destroy() end)
		end
		if pData._nestedAlive then pData._nestedAlive[1] = false end
		self._activeEmits[i] = nil
	end
	-- Reset animate items via cancelAnimation (restores source RT to authored state).
	local animateKeys = {}
	for item in pairs(self._activeAnimates) do table.insert(animateKeys, item) end
	for _, item in ipairs(animateKeys) do
		pcall(function() self:_cancelAnimation(item) end)
	end
	table.clear(self._activeAnimates)
	for item, thread in pairs(self._activeLoops) do
		pcall(function() task.cancel(thread) end)
		self._activeLoops[item] = nil
	end
	-- Cancel chain-driven duration loops + clear buckets so the map doesn't sit
	-- pinned until module reload. `_engineGen` drift above also makes the threads
	-- self-terminate; this just frees the table refs.
	if self._activeChainLoops then for _, bucket in pairs(self._activeChainLoops) do for _, t in ipairs(bucket) do pcall(task.cancel, t) end end; table.clear(self._activeChainLoops) end
	if self._CachedFolder and self._CachedFolder.Parent then
		self._CachedFolder:Destroy()
	end
	self._CachedFolder = nil
	if self._CachedPoolFolder and self._CachedPoolFolder.Parent then
		self._CachedPoolFolder:Destroy()
	end
	self._CachedPoolFolder = nil
	-- Sweep workspace + Lighting + the auto-managed CoreGui ScreenGui for any emitted items that
	-- escaped normal tracking (PointLights parent to original part; PartLife-delayed items removed
	-- from _activeEmits early; screen effects live in Lighting; ImageLabels live in our ScreenHost).
	--[[
		扫 root 下带 `_PartIcleEmit` 的逃逸克隆并 Destroy。

		@param root Instance - 扫描根（workspace / Lighting / ScreenHost）
	]]
	local function _sweep(root) for _, desc in root:GetDescendants() do if desc:GetAttribute("_PartIcleEmit") then pcall(desc.Destroy, desc) end end end
	_sweep(workspace); _sweep(Lighting)
	if ScreenHost.exists() then _sweep(ScreenHost.get()); ScreenHost.destroy() end
	TexturePin.clear()
	-- Tear down Events compile cache: disconnects every Source/AncestryChanged signal +
	-- destroys every `_CompiledEventModule` clone so toggle-off-on cycles don't leak
	-- signal connections firing on dead-module closures.
	EventsMod.cleanup()
	-- LinkService owns an independent per-frame PreRender / Heartbeat connection +
	-- Anchored snapshot table. Deactivate disconnects + restores so toggle cycles
	-- don't leak link tracking or strand parts in Anchored=true state.
	if self.LinkService and self.LinkService.Deactivate then
		pcall(function() self.LinkService:Deactivate() end)
	end
end

--[[
	懒创建并缓存「正在发射」的克隆桶（EmittedPartsUsingPart_icle）。
	空闲池条目在 Pool.release 时改挂到独立的 Part_IclesPooled。
	两文件夹都挂 workspace.Terrain，Archivable=false 以免进 Undo / 存盘。

	@return Folder - 活动发射桶
]]
function Particle:GetFolder()
	if self._CachedFolder and self._CachedFolder.Parent then
		return self._CachedFolder
	end
	local folder = workspace.Terrain:FindFirstChild('EmittedPartsUsingPart_icle')
	if not folder then
		folder = Instance.new('Folder')
		folder.Name = "EmittedPartsUsingPart_icle"
		folder.Archivable = false
		folder.Parent = workspace.Terrain
	end
	self._CachedFolder = folder
	return folder
end

--[[
	空闲池桶。Pool.release 把回收视觉挂到这里，便于区分可复用与正在发射。

	@return Folder - 池文件夹 Part_IclesPooled
]]
function Particle:GetPoolFolder()
	if self._CachedPoolFolder and self._CachedPoolFolder.Parent then
		return self._CachedPoolFolder
	end
	local folder = workspace.Terrain:FindFirstChild('Part_IclesPooled')
	if not folder then
		folder = Instance.new('Folder')
		folder.Name = "Part_IclesPooled"
		folder.Archivable = false
		folder.Parent = workspace.Terrain
	end
	self._CachedPoolFolder = folder
	return folder
end

end
