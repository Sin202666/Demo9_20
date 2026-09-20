--[[
	Module: EventsCollision
	Description: Part-Icles OnHit 碰撞模式（Off / Kill / Stop / Bounce），仅 Part / Attachment / Model
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-09-01

	Bounce 按 hit.Normal 拆法向/切向：Bounciness 回弹、Friction 切向阻尼、Spin 由 nrm×v_t 踢角速度。
	Update / UpdateModel 每帧需积分 SpeedMultiplier 与 _spinRate。本文件不结算伤害/掉落。
]]

local Constants = require(script.Parent.PartConstants)
local GraphMod = require(script.Parent.Graph)

local EventsCollision = {}

-- Pre-bounce vMag (studs/sec) gate. Below this engages _settleEngaged + scales
-- bounce-spin damping toward zero (rolling-friction proxy).
local REST_VELOCITY_THRESHOLD = 1.0

-- Restitution clamp (Jolt mMinVelocityForRestitution / Box2D b2_velocityThreshold).
-- Below this, e := 0  -  inelastic. Breaks Zeno micro-bouncing.
local MIN_REST_VELOCITY = 0.5

-- Point-velocity (linear + |spinRate|·radius) below this advances _restTimer.
-- Jolt mPointVelocitySleepThreshold = 0.03 m/s, scaled to stud units.
local SLEEP_VELOCITY_THRESHOLD = 0.1

-- Rest-timer threshold for permanent freeze. Matches Box2D + Jolt 0.5s default.
local TIME_BEFORE_SLEEP = 0.5

-- Angular damping (1/sec) on _spinRate while settling. Half-life ≈ 0.116s.
local ANGULAR_REST_DRAG = 6.0

-- Damp authored RotSpeedX/Y/Z graph contribution to zero during settle. Without
-- this, settled body keeps rotating from RotMode=OverLife / RotMode=Speed grids.
local ROT_GRAPH_DAMP = 6.0

-- Per-particle ±range jitter (width fraction; 0.4 = ±20%) on bounce + settle
-- params. Decorrelates same-burst particles so bounce count + settle time
-- vary naturally instead of all particles converging in lockstep.
local BOUNCINESS_JITTER_RANGE = 0.4
local FRICTION_JITTER_RANGE = 0.4
local REST_CLAMP_JITTER_RANGE = 0.4
local SLEEP_TIME_JITTER_RANGE = 0.4

-- Gravity-torque gain: τ = sin(tilt)·|g|·GAIN. 0.5 → ~70 deg/sec² at 45° + default gravity.
local TIPPING_GAIN = 0.5

-- Permanent-freeze thresholds (both must hold): spin deg/sec, tilt radians.
local SPIN_FREEZE_EPSILON = 0.5
local ANGLE_FREEZE_EPSILON = 0.02

-- Body-local axes scanned for face-down orientation (the six box faces).
local _BODY_AXES = {
	Vector3.new(1, 0, 0), Vector3.new(-1, 0, 0),
	Vector3.new(0, 1, 0), Vector3.new(0, -1, 0),
	Vector3.new(0, 0, 1), Vector3.new(0, 0, -1),
}

-- Hit history for negative-Timescale reverse. Newest-keep ring: reverse playback
-- always crosses recent hits first, so dropping the oldest preserves rewind
-- fidelity for the most recent HIT_HISTORY_CAP collisions.
local HIT_HISTORY_CAP = 16

--[[
	快照粒子运动/碰撞态，供 Timescale 倒放越过命中点时还原
	@param pData table - 运行时粒子态（BaseDirection / SpeedMultiplier / LocalCF / 结算字段等）
	@param kind string - 快照类型（"Bounce" / "Stop"）
	@return table - 可压入 _hitHistory 的快照
]]
local function _snapshotPData(pData, kind)
	return {
		time = pData._effectiveElapsed or 0,
		kind = kind,
		BaseDirection = pData.BaseDirection,
		SpeedMultiplier = pData.SpeedMultiplier,
		_accelVel = pData._accelVel,
		TargetVel = pData.TargetVel,
		_spinRate = pData._spinRate,
		_spinAccumX = pData._spinAccumX,
		_spinAccumY = pData._spinAccumY,
		_spinAccumZ = pData._spinAccumZ,
		AccRotX = pData.AccRotX,
		AccRotY = pData.AccRotY,
		AccRotZ = pData.AccRotZ,
		LocalCF = pData.LocalCF,
		_localWorldCF = pData._localWorldCF,
		CurrentPosition = pData.CurrentPosition,
		_hitFired = pData._hitFired,
		LastHitCheckPos = pData.LastHitCheckPos,
		_collisionStopped = pData._collisionStopped,
		CurrentStep = pData.CurrentStep,
		AccumulatedDT = pData.AccumulatedDT,
		-- PosOffset bounce reflection: mirror axes (nil pre-first-bounce) + the
		-- delta-accumulation baseline _prevWorldOff. Both flip on Bounce; both must
		-- restore on reverse-Timescale rewind across the hit boundary.
		_displacementMirrorX = pData._displacementMirrorX,
		_displacementMirrorY = pData._displacementMirrorY,
		_displacementMirrorZ = pData._displacementMirrorZ,
		_prevWorldOff = pData._prevWorldOff,
		-- Settle state flag + rest-timer accumulator (Box2D/Jolt sleep pattern).
		-- Both restore on reverse-Timescale rewind so the body un-settles cleanly.
		_settleEngaged = pData._settleEngaged,
		_restTimer = pData._restTimer,
		_settleRotDamp = pData._settleRotDamp,
		_settleContactPos = pData._settleContactPos,
		_settleSpawnHalf = pData._settleSpawnHalf,
		-- Last surface normal  -  gravity-torque target reference for tip math.
		_lastHitNormal = pData._lastHitNormal,
	}
end

--[[
	把命中快照压入环形历史；满员时丢最旧（倒放优先最近碰撞）
	@param pData table - 运行时粒子态（将写 _hitHistory）
	@param snap table - _snapshotPData 产物
]]
local function _pushHit(pData, snap)
	pData._hitHistory = pData._hitHistory or {}
	-- Drop oldest when full so the newest hit is always recorded.
	if #pData._hitHistory >= HIT_HISTORY_CAP then
		table.remove(pData._hitHistory, 1)
	end
	table.insert(pData._hitHistory, snap)
end

--[[
	Timescale 倒放（dt<0）时还原越过的命中态；由新到旧扫描，最早越过的命中生效
	@param pData table - 运行时粒子态（读 _hitHistory 并写回字段）
	@param priorEff number - 本帧积分前的有效经过时间
	@param newEff number - 本帧积分后的有效经过时间
]]
function EventsCollision.restoreHitsOnReverse(pData, priorEff, newEff)
	local history = pData._hitHistory
	if not history then return end
	for i = #history, 1, -1 do
		local h = history[i]
		if h.time > newEff and h.time <= priorEff then
			pData.BaseDirection = h.BaseDirection
			pData.SpeedMultiplier = h.SpeedMultiplier
			pData._accelVel = h._accelVel
			pData.TargetVel = h.TargetVel
			pData._spinRate = h._spinRate
			pData._spinAccumX = h._spinAccumX
			pData._spinAccumY = h._spinAccumY
			pData._spinAccumZ = h._spinAccumZ
			pData.AccRotX = h.AccRotX
			pData.AccRotY = h.AccRotY
			pData.AccRotZ = h.AccRotZ
			pData.LocalCF = h.LocalCF
			pData._localWorldCF = h._localWorldCF
			pData.CurrentPosition = h.CurrentPosition
			pData._hitFired = h._hitFired
			pData.LastHitCheckPos = h.LastHitCheckPos
			pData._collisionStopped = h._collisionStopped
			pData.CurrentStep = h.CurrentStep
			pData.AccumulatedDT = h.AccumulatedDT
			pData._displacementMirrorX = h._displacementMirrorX
			pData._displacementMirrorY = h._displacementMirrorY
			pData._displacementMirrorZ = h._displacementMirrorZ
			pData._prevWorldOff = h._prevWorldOff
			pData._settleEngaged = h._settleEngaged
			pData._restTimer = h._restTimer
			pData._settleRotDamp = h._settleRotDamp
			pData._settleContactPos = h._settleContactPos
			pData._settleSpawnHalf = h._settleSpawnHalf
			pData._lastHitNormal = h._lastHitNormal
			table.remove(history, i)
		end
	end
end

--[[
	按类型写视觉位姿：BasePart.CFrame / Model:PivotTo / Attachment 世界→父局部
	@param pData table - 含 VisualPart / Type 的粒子态
	@param snapCF CFrame - 目标世界 CFrame
]]
local function _applySnapCFrame(pData, snapCF)
	local v = pData.VisualPart
	if not v or not v.Parent then return end
	if pData.Type == "Model" then v:PivotTo(snapCF); return end
	if pData.Type == "Attachment" then
		local parent = v.Parent
		v.CFrame = (parent and parent:IsA("BasePart")) and parent.CFrame:ToObjectSpace(snapCF) or snapCF
		return
	end
	v.CFrame = snapCF
end

--[[
	读视觉世界 CFrame：Model 用 pivot，Attachment 用 parent*local
	@param pData table - 含 VisualPart / Type 的粒子态
	@return CFrame - 世界 CFrame；视觉缺失时为单位 CFrame
]]
local function _readWorldCF(pData)
	local v = pData.VisualPart
	if not v or not v.Parent then return CFrame.new() end
	if pData.Type == "Model" then return v:GetPivot() end
	if pData.Type == "Attachment" then
		local p = v.Parent
		return (p and p:IsA("BasePart")) and (p.CFrame * v.CFrame) or v.CFrame
	end
	return v.CFrame
end

--[[
	Part/Model 反弹重建 LocalCF 用的父 Link 世界 CFrame；RigidLocal 读发射时快照
	@param pData table - 含 Link / LinkMode / _rigidLocalParentCF 的粒子态
	@return CFrame - 父空间 CFrame；无 Link 为单位 CFrame
]]
local function _bounceParentCF(pData)
	local link = pData.Link
	if not link or not link.Parent then return CFrame.new() end
	local lCF
	if pData.LinkMode == "RigidLocal" then
		lCF = pData._rigidLocalParentCF or CFrame.new()
	else
		lCF = Constants.resolveLinkCFrame(link)
	end
	if not lCF then return CFrame.new() end
	if pData.LinkMode == "Follow" or pData.LinkMode == "Pivot" then
		return CFrame.new(lCF.Position)
	end
	return lCF
end

--[[
	把世界吸附点换到 Attachment 的 LocalCF 空间（先经 actualParent，再经 Link）
	@param pData table - 含 VisualPart / Link / LinkMode 的粒子态
	@param snapPos Vector3 - 世界吸附位置
	@return Vector3 - Attachment 局部位置
]]
local function _attachmentBounceLocalPos(pData, snapPos)
	local visualAtt = pData.VisualPart
	local actualParent = visualAtt and visualAtt.Parent
	local convCF = (actualParent and actualParent:IsA("BasePart")) and actualParent.CFrame or CFrame.new()
	local link = pData.Link
	local parentCF_now
	if link and link.Parent then
		local linkWorldCF
		if pData.LinkMode == "RigidLocal" then
			linkWorldCF = pData._rigidLocalParentCF or CFrame.new()
		else
			linkWorldCF = Constants.resolveLinkCFrame(link)
		end
		local linkLocalCF = convCF:ToObjectSpace(linkWorldCF)
		if pData.LinkMode == "Follow" or pData.LinkMode == "Pivot" then
			parentCF_now = CFrame.new(linkLocalCF.Position)
		else
			parentCF_now = linkLocalCF
		end
	else
		parentCF_now = CFrame.new()
	end
	local snapInActualParent = convCF:PointToObjectSpace(snapPos)
	return parentCF_now:PointToObjectSpace(snapInActualParent)
end

--[[
	吸附到 hit.Position 并保持当前旋转；Kill 销毁，Stop 冻结后自然老化
	Stop 会先快照供 Timescale 倒放还原；Kill 不快照
	@param particle table - PartIcles 主表（调用 :_killParticle）
	@param pData table - 运行时粒子态
	@param hit table - 射线命中 { Position: Vector3, Normal: Vector3, ... }
	@param mode string - "Kill" 或 "Stop"
]]
local function _handleKillOrStop(particle, pData, hit, mode)
	local stopSnap = (mode ~= "Kill") and _snapshotPData(pData, "Stop") or nil
	local existing = _readWorldCF(pData)
	local snapCF = CFrame.new(hit.Position) * (existing - existing.Position)
	_applySnapCFrame(pData, snapCF)
	pData.CurrentPosition = hit.Position
	if mode == "Kill" then
		if particle._killParticle then
			particle:_killParticle(pData, { fireOnDeath = true })
		end
	else
		-- Sync companion CFrame caches with the snap so next Heartbeat's ReapplyLink (LinkTrack)
		-- and ApplyOrientation (Orientation) reads don't pull the particle back to pre-stop pos.
		if pData.LocalCF then
			local localPos
			if pData.Type == "Attachment" then
				localPos = _attachmentBounceLocalPos(pData, hit.Position)
			else
				localPos = _bounceParentCF(pData):PointToObjectSpace(hit.Position)
			end
			pData.LocalCF = CFrame.new(localPos) * (pData.LocalCF - pData.LocalCF.Position)
			pData._localWorldCF = pData.LocalCF
		end
		pData._postUpdateCF = snapCF
		pData._collisionStopped = true
		pData.LastHitCheckPos = hit.Position
		pData._hitFired = true
		if stopSnap then _pushHit(pData, stopSnap) end
	end
end

--[[
	把速度拆法向/切向后回弹（-e*V_n）并切向阻尼（(1-μ)*V_t）；模长折进 SpeedMultiplier
	@param pData table - 运行时粒子态（改 BaseDirection / SpeedMultiplier / _accelVel / 自旋等）
	@param hit table - 射线命中 { Position, Normal, ... }
	@param dir Vector3 - 本段位移向量
	@param segmentDT number - 本段时间（秒）；<=0 时按 1/60
]]
local function _handleBounce(pData, hit, dir, segmentDT)
	local nrm = hit.Normal
	local oh = pData.Events.OnHit
	-- Lazy-init per-particle jitter on first bounce. Decorrelates same-burst particles
	-- so bounce count + settle time spread naturally instead of converging in lockstep.
	pData._bouncinessJitter = pData._bouncinessJitter or (1 + (math.random() - 0.5) * BOUNCINESS_JITTER_RANGE)
	pData._frictionJitter = pData._frictionJitter or (1 + (math.random() - 0.5) * FRICTION_JITTER_RANGE)
	pData._restClampJitter = pData._restClampJitter or (1 + (math.random() - 0.5) * REST_CLAMP_JITTER_RANGE)
	pData._sleepTimeJitter = pData._sleepTimeJitter or (1 + (math.random() - 0.5) * SLEEP_TIME_JITTER_RANGE)
	local e = (oh.Bounciness or 0.7) * pData._bouncinessJitter
	local mu = (oh.Friction or 0.2) * pData._frictionJitter
	local spinCoef = oh.Spin or 0.5
	if not segmentDT or segmentDT <= 0 then segmentDT = 1/60 end

	-- Snapshot pre-mutation for reverse-Timescale; pushed at function exit.
	local hitSnap = _snapshotPData(pData, "Bounce")

	-- Surface normal for applySettle's gravity-torque tip target. Most-recent wins.
	pData._lastHitNormal = nrm

	-- Restitution clamp (Jolt/Box2D pattern): below threshold, force inelastic
	-- (e=0) so low-velocity contacts can't trigger infinite micro-bounces.
	local v_normal_speed = math.abs((dir / segmentDT):Dot(nrm))
	local e_eff = e
	if v_normal_speed < MIN_REST_VELOCITY * (pData._restClampJitter or 1) then e_eff = 0 end

	local bd = pData.BaseDirection
	if bd then
		local bdN = bd:Dot(nrm) * nrm
		local bdT = bd - bdN
		local bdPost = -e_eff * bdN + (1 - mu) * bdT
		local mag = bdPost.Magnitude
		if mag > 1e-4 then
			pData.BaseDirection = bdPost.Unit
			pData.SpeedMultiplier = (pData.SpeedMultiplier or 1) * mag
		else
			-- bdPost ≈ 0 (e=0 perpendicular hit): stall linear motion; accel can still lift.
			pData.SpeedMultiplier = 0
		end
	end

	local av = pData._accelVel
	if av then
		local aN = av:Dot(nrm) * nrm
		local aT = av - aN
		pData._accelVel = -e_eff * aN + (1 - mu) * aT
	end

	local tv = pData.TargetVel
	if tv then
		local tN = tv:Dot(nrm) * nrm
		local tT = tv - tN
		pData.TargetVel = -e_eff * tN + (1 - mu) * tT
	end

	-- Angular kick from tangent velocity. Cross order nrm × v_t produces forward-roll
	-- (e.g. +X over +Y floor → -Z spin). restFactor scales damping toward 0 as
	-- pre-bounce speed approaches zero  -  rolling-friction proxy at rest.
	local existingSpin = pData._spinRate or Vector3.zero
	local v_t = (dir - dir:Dot(nrm) * nrm) / segmentDT
	local vMag = (dir / segmentDT).Magnitude
	local kick = Vector3.zero
	if v_t.Magnitude > 1e-4 then
		kick = nrm:Cross(v_t) * (spinCoef * 3.33)
	end
	local restFactor = math.min(1, vMag / REST_VELOCITY_THRESHOLD)
	pData._spinRate = existingSpin * (1 - mu) * restFactor + kick

	-- _settleEngaged sticks on first low-velocity bounce. Enables Coulomb contact
	-- constraint in PartConstants.applyContactAccel + gravity-torque tipping in
	-- applySettle. Cleared only by _clearSettleState (external mutator wake).
	if vMag < REST_VELOCITY_THRESHOLD then
		if not pData._settleEngaged then
			-- Cache surface contact point + initial half-extent so applySettle can
			-- keep the body's bottom face flush with the surface as Size shrinks
			-- (prevents floating-vanish when Size graph fades to 0).
			local visual = pData.VisualPart
			if visual and visual:IsA("BasePart") then
				local halfExtent = visual.Size.Magnitude * 0.5
				pData._settleSpawnHalf = halfExtent
				pData._settleContactPos = visual.Position - nrm * halfExtent
			end
		end
		pData._settleEngaged = true
	end

	-- PosOffset trajectory reflection: mirror each cached axis vector about hit.Normal
	-- so PosOffset-driven motion bounces off surfaces just like Speed-driven motion.
	-- Lazy-init at first bounce; nil mirror axes elsewhere skip the matrix-apply
	-- fast-path inside Constants.resolveDisplacement.
	if pData.HasPosOffsetGraphs then
		--[[
			绕 hit.Normal 反射向量（PosOffset 镜像轴）
			@param v Vector3 - 待反射轴
			@return Vector3 - 反射后的轴
		]]
		local function _reflect(v) return v - 2 * v:Dot(nrm) * nrm end
		local mx = pData._displacementMirrorX or Vector3.xAxis
		local my = pData._displacementMirrorY or Vector3.yAxis
		local mz = pData._displacementMirrorZ or Vector3.zAxis
		pData._displacementMirrorX = _reflect(mx)
		pData._displacementMirrorY = _reflect(my)
		pData._displacementMirrorZ = _reflect(mz)
		-- Re-baseline _prevWorldOff under the new mirror so the next per-frame delta
		-- (newWorldOff - _prevWorldOff) doesn't snap. Sample current PosOffset graphs
		-- and apply the freshly-updated mirror.
		local steppedI = (pData.CurrentStep or 0) / math.max(pData.TotalKeyFrames, 1)
		local oX = pData.Graphs.PosOffsetX and GraphMod.QueryPointsWithTime(steppedI, pData.Graphs.PosOffsetX, pData.Seeds.PosOffsetX) or 0
		local oY = pData.Graphs.PosOffsetY and GraphMod.QueryPointsWithTime(steppedI, pData.Graphs.PosOffsetY, pData.Seeds.PosOffsetY) or 0
		local oZ = pData.Graphs.PosOffsetZ and GraphMod.QueryPointsWithTime(steppedI, pData.Graphs.PosOffsetZ, pData.Seeds.PosOffsetZ) or 0
		pData._prevWorldOff = Constants.resolveDisplacement(Vector3.new(oX, oY, oZ),
			pData.DisplacementMode or "Global", pData.SpawnRotation, pData.SpawnEmitterRotation,
			pData._displacementMirrorX, pData._displacementMirrorY, pData._displacementMirrorZ)
	end

	-- Offset along normal so next ray doesn't re-hit the same face.
	local snapPos = hit.Position + nrm * 0.05
	-- LocalCF position only; rotation gets re-composed on top by UpdatePart.
	if pData.LocalCF then
		local localPos
		if pData.Type == "Attachment" then
			localPos = _attachmentBounceLocalPos(pData, snapPos)
		else
			localPos = _bounceParentCF(pData):PointToObjectSpace(snapPos)
		end
		pData.LocalCF = CFrame.new(localPos) * (pData.LocalCF - pData.LocalCF.Position)
		pData._localWorldCF = pData.LocalCF
	end
	local existing = _readWorldCF(pData)
	local snapCF = CFrame.new(snapPos) * (existing - existing.Position)
	_applySnapCFrame(pData, snapCF)
	-- Mirror of _handleKillOrStop: keep _postUpdateCF in sync so unlinked-particle Orientation
	-- pass doesn't snap the visual back to its pre-bounce CFrame next Heartbeat.
	pData._postUpdateCF = snapCF
	pData.CurrentPosition = snapPos
	pData.LastHitCheckPos = snapPos
	pData._hitFired = false

	_pushHit(pData, hitSnap)
end

--[[
	每帧沉降：自旋衰减、重力力矩倾倒、尺寸下沉、静止计时冻结
	@param pData table - 已 _settleEngaged 的粒子态
	@param dt number? - 帧时间（秒）；正值才衰减自旋
]]
function EventsCollision.applySettle(pData, dt)
	if not pData or pData._collisionStopped then return end
	if not pData._settleEngaged then return end
	if pData.NeedsFullIteration then return end
	if dt and dt > 0 then
		local decay = math.exp(-ANGULAR_REST_DRAG * dt)
		pData._spinRate = (pData._spinRate or Vector3.zero) * decay
		-- Authored RotSpeed graph contribution decays to zero in parallel.
		-- Update.luau reads pData._settleRotDamp at every RotSpeed sample site.
		pData._settleRotDamp = (pData._settleRotDamp or 1) * math.exp(-ROT_GRAPH_DAMP * dt)
	end
	local nrm = pData._lastHitNormal
	if not nrm or nrm.Magnitude < 1e-4 then return end
	local visual = pData.VisualPart
	if not visual or not visual.Parent then return end

	local currentCF = _readWorldCF(pData)
	local down = -nrm
	local bestAxis = _BODY_AXES[1]
	local bestDot = -math.huge
	for _, ax in ipairs(_BODY_AXES) do
		local worldAx = currentCF:VectorToWorldSpace(ax)
		local d = worldAx:Dot(down)
		if d > bestDot then
			bestDot = d
			bestAxis = ax
		end
	end
	local worldDownAxis = currentCF:VectorToWorldSpace(bestAxis)
	local tiltAngle = math.acos(math.clamp(worldDownAxis:Dot(down), -1, 1))
	local torqueAxisRaw = worldDownAxis:Cross(down)
	if torqueAxisRaw.Magnitude > 1e-4 and tiltAngle > 1e-4 and dt and dt > 0 then
		-- Authored Acceleration is the gravity source. Zero-gravity emitters skip tipping
		-- (no torque), matching physical intuition.
		local accelVec = pData.Acceleration or Vector3.zero
		local gravityMag = accelVec.Magnitude
		if gravityMag > 1 then
			local torqueMag = math.sin(tiltAngle) * gravityMag * TIPPING_GAIN
			local torqueVec = torqueAxisRaw.Unit * torqueMag
			pData._spinRate = (pData._spinRate or Vector3.zero) + torqueVec * dt
		end
	end

	-- Size-sink: re-anchor CFrame.Position so the bottom face stays flush with
	-- the surface as Size shrinks (Roblox centers Part rendering on .Position).
	if pData._settleContactPos and pData._settleSpawnHalf and visual:IsA("BasePart") then
		local currentHalf = visual.Size.Magnitude * 0.5
		local newPos = pData._settleContactPos + nrm * currentHalf
		_applySnapCFrame(pData, CFrame.new(newPos) * (currentCF - currentCF.Position))
	end

	-- Rest-timer accumulator (Box2D/Jolt sleep pattern). Point-velocity samples the
	-- bbox edge so rotation-induced motion blocks sleep, not just CoM stillness.
	local r = pData._sleepRadius or 1.0
	local spinMag = (pData._spinRate or Vector3.zero).Magnitude
	local angularPointVel = spinMag * r * (math.pi / 180)
	local linMag = math.abs(pData.SpeedMultiplier or 0) + (pData._accelVel or Vector3.zero).Magnitude
	local v_eff = linMag + angularPointVel
	if v_eff < SLEEP_VELOCITY_THRESHOLD then
		pData._restTimer = (pData._restTimer or 0) + dt
	else
		pData._restTimer = 0
	end
	if (pData._restTimer or 0) >= TIME_BEFORE_SLEEP * (pData._sleepTimeJitter or 1)
		and tiltAngle < ANGLE_FREEZE_EPSILON then
		pData._collisionStopped = true
		pData._spinRate = Vector3.zero
		pData._accelVel = Vector3.zero
		pData.SpeedMultiplier = 0
		pData.TargetVel = Vector3.zero
	end
end

--[[
	OnHit 分发：返回 "snap" 则调用方立刻返回，"off" 则只更新 LastHitCheckPos
	Bounce+InvertMotion 降为 Kill；Animate 模式的 Kill/Stop/Bounce 降为 Off（避免改活源）
	@param particle table - PartIcles 主表
	@param pData table - 运行时粒子态（读 Events.OnHit.Collision）
	@param hit table - 射线命中 { Position, Normal, ... }
	@param dir Vector3 - 本段位移
	@param segmentDT number - 本段时间（秒）
	@return string - "snap" 或 "off"
]]
function EventsCollision.handle(particle, pData, hit, dir, segmentDT)
	local mode = pData.Events.OnHit.Collision or "Off"
	if mode == "Bounce" and pData.InvertMotion then mode = "Kill" end
	if pData.IsAnimate and (mode == "Kill" or mode == "Stop" or mode == "Bounce") then
		mode = "Off"
	end

	if mode == "Kill" or mode == "Stop" then
		_handleKillOrStop(particle, pData, hit, mode)
		return "snap"
	elseif mode == "Bounce" then
		_handleBounce(pData, hit, dir, segmentDT)
		return "snap"
	end

	pData._hitFired = true
	return "off"
end

return EventsCollision
