--[[
	Module: Update
	Description: PartIcles Mixin：Part / Attachment 逐帧更新（寿命到期返回 true）
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-09-01

	功能：
	- UpdatePart / UpdateAttachment：位置、旋转、尺寸、颜色
	- 到期返回 true，由 Engine 做 swap-and-pop 或 AnimateLoop 复位
	- 热路径约定：步进循环内不新建 CFrame / Vector3 / table（既有分配保持不变）

	Beam 更新在 UpdateBeam.luau。由 PartIcles/init 作为 mixin 注入，业务侧勿单独 require。
]]

local GraphMod = require(script.Parent.Graph)
local Constants = require(script.Parent.PartConstants)
local EventsCollision = require(script.Parent.EventsCollision)
local DirectionVectors = Constants.DirectionVectors

--[[
	取本帧链接粒子的父级 CFrame。Weld 用完整 Link CFrame；Follow/Pivot 去掉旋转。
	RigidLocal 读发射时快照 pData._rigidLocalParentCF，忽略 Link 实时运动。

	@param pData table - 粒子状态；用 Link / LinkMode / _rigidLocalParentCF
	@return CFrame - 父级 CFrame（无 Link 时为单位）
	@return boolean - 是否应对位移做 VectorToObjectSpace（Weld/RigidLocal 为 true）
]]
local function _getLinkCF(pData)
	local lk = pData.Link
	if not (lk and lk.Parent) then return CFrame.new(), false end
	local worldCF
	if pData.LinkMode == "RigidLocal" then
		worldCF = pData._rigidLocalParentCF or CFrame.new()
	else
		worldCF = Constants.resolveLinkCFrame(lk)
	end
	if pData.LinkMode == "Follow" or pData.LinkMode == "Pivot" then
		return CFrame.new(worldCF.Position), false
	end
	return worldCF, true
end

--[[
	Attachment 链接：把 Link 世界 CFrame 转到视觉父级局部空间。
	RigidLocal 读世界快照，每帧仍转到 visualParent 局部，父级移动时仍正确。

	@param pData table - 粒子状态；用 Link / LinkMode / VisualPart / _rigidLocalParentCF
	@return CFrame - 父级局部 CFrame
	@return boolean - 是否应对位移做 VectorToObjectSpace
	@return boolean - Link 是否有效（无 Link/父级时为 false）
]]
local function _getAttachmentLinkCF(pData)
	local lk = pData.Link
	if not (lk and lk.Parent) then return CFrame.new(), false, false end
	local visualParent = pData.VisualPart and pData.VisualPart.Parent
	if not visualParent then return CFrame.new(), false, false end
	local linkWorldCF
	if pData.LinkMode == "RigidLocal" then
		linkWorldCF = pData._rigidLocalParentCF or CFrame.new()
	else
		linkWorldCF = Constants.resolveLinkCFrame(lk)
	end
	local convCF = visualParent:IsA("BasePart") and visualParent.CFrame or CFrame.new()
	local linkLocalCF = convCF:ToObjectSpace(linkWorldCF)
	if pData.LinkMode == "Follow" or pData.LinkMode == "Pivot" then
		return CFrame.new(linkLocalCF.Position), false, true
	end
	return linkLocalCF, true, true
end

--[[
	取目标加速度用的世界坐标。已销毁或无 Position 的类型返回 nil。
	Bone 必须先于 BasePart 判断（Bone IS-A BasePart，但 .Position 是绑定姿态不是实时位置）。

	@param target Instance? - AccelTarget（Bone / BasePart / Attachment / Camera / Model）
	@return Vector3? - 世界坐标；无效时 nil
]]
local function _getTargetPosition(target)
	if not target or not target.Parent then return nil end
	if target:IsA("Bone") then return target.TransformedWorldCFrame.Position end
	if target:IsA("BasePart") then return target.Position end
	if target:IsA("Attachment") then return target.WorldPosition end
	if target:IsA("Camera") then return target.CFrame.Position end
	if target:IsA("Model") then local ok, cf = pcall(target.GetPivot, target); if ok and cf then return cf.Position end end
	return nil
end

--[[
	PosOffsetX/Y/Z 寿命曲线 → 本帧位移增量。
	差分：在 DisplacementMode 坐标系采样绝对偏移再减 _prevWorldOff，LocalCF 累加器才能积对。
	三套坐标系对齐 DirMode：Global=世界轴；Local=SpawnRotation（RotXYZ 后）；RigidLocal=发射器帧（RotXYZ 前）。
	isLinkLocal=true 表示偏移已在 Link 局部（Local + useVOS），_composeLocalDelta 不可再 VOS。

	@param pData table - 粒子状态；用 HasPosOffsetGraphs / Graphs / Seeds / DisplacementMode / _prevWorldOff
	@param steppedI number - 归一化时间 [0,1]，对应当前 keyframe
	@param useVOS boolean - 当前 Link 是否把世界位移转到 Link 局部
	@return Vector3 - 本帧偏移增量
	@return boolean - 增量是否已在 Link 局部（勿再 VOS）
]]
local function _posOffsetFrameDelta(pData, steppedI, useVOS)
	if not pData.HasPosOffsetGraphs then return Vector3.zero, false end
	local oX = pData._staticPosOffsetX or (pData.Graphs.PosOffsetX and GraphMod.QueryPointsWithTime(steppedI, pData.Graphs.PosOffsetX, pData.Seeds.PosOffsetX)) or 0
	local oY = pData._staticPosOffsetY or (pData.Graphs.PosOffsetY and GraphMod.QueryPointsWithTime(steppedI, pData.Graphs.PosOffsetY, pData.Seeds.PosOffsetY)) or 0
	local oZ = pData._staticPosOffsetZ or (pData.Graphs.PosOffsetZ and GraphMod.QueryPointsWithTime(steppedI, pData.Graphs.PosOffsetZ, pData.Seeds.PosOffsetZ)) or 0
	local worldOff = Constants.resolveDisplacement(Vector3.new(oX, oY, oZ),
		pData.DisplacementMode or "Global", pData.SpawnRotation, pData.SpawnEmitterRotation,
		pData._displacementMirrorX, pData._displacementMirrorY, pData._displacementMirrorZ)
	local delta = worldOff - pData._prevWorldOff
	pData._prevWorldOff = worldOff
	-- Local mode's SpawnRotation is captured link-local under a link, so the delta is
	-- already link-local. Flag it so the apply site skips the second VOS that would
	-- precess it around a spinning Weld instead of letting the radius shrink.
	local isLinkLocal = useVOS and (pData.DisplacementMode or "Global") == "Local"
	return delta, isLinkLocal
end

--[[
	把本帧位移叠进 Link 局部 LocalCF 累加器。
	世界速度在 Weld 时 VOS 到 Link 局部；已是 Link 局部的 PosOffset 原样相加。
	motionFactor 按父 Model 缩放整段空间增量（Speed+Accel+PosOffset）；非嵌套为 1。

	@param parentCF CFrame - 本帧 Link 父级 CFrame
	@param useVOS boolean - 是否把世界位移转到 Link 局部
	@param velWorld Vector3 - 世界空间速度位移
	@param posDelta Vector3 - PosOffset 增量
	@param posIsLinkLocal boolean - posDelta 是否已在 Link 局部
	@param motionFactor number - 父 Model 运动缩放（默认 1）
	@return Vector3 - 应写入 LocalCF 的合成增量
]]
local function _composeLocalDelta(parentCF, useVOS, velWorld, posDelta, posIsLinkLocal, motionFactor)
	if not useVOS then return (velWorld + posDelta) * motionFactor end
	local velLocal = parentCF:VectorToObjectSpace(velWorld)
	local posLocal = posIsLinkLocal and posDelta or parentCF:VectorToObjectSpace(posDelta)
	return (velLocal + posLocal) * motionFactor
end

return function(Particle)

--[[
	Part 逐帧更新：位置（4 分支）、旋转、尺寸、颜色/透明度。
	InvertMotion 读预计算 CFrame；VelocityVectored 逐步迭代；无加速/阻力走快路径。
	寿命到期或视觉已销毁返回 true。

	@param pData table - 运行时粒子状态（Type=Part；VisualPart / Graphs / Seeds / LocalCF 等）
	@param dt number - Heartbeat 增量秒
	@param currentTime number - os.clock 当前时间
	@return boolean - true 表示应结束（swap-and-pop 或 AnimateLoop 复位）
]]
function Particle:UpdatePart(pData, dt, currentTime)
	-- Signed-reverse Timescale: ts sampled at real_i (not effective i) so it progresses
	-- monotonically through keypoints regardless of effective-time direction. ts(0)<0 →
	-- particle starts at end of life and rewinds; ts(0)>=0 → starts forward.
	-- SetTimescale override (Lifecycle.luau) wins over the graph for its window.
	local real_i = math.min(math.max((currentTime - pData.StartTime) / pData.LifeTime, 0), 1)
	local ts
	if pData._tsOverride ~= nil and currentTime < (pData._tsOverrideUntil or 0) then
		ts = pData._tsOverride
	else
		ts = pData.Graphs.Timescale and GraphMod.QueryPointsWithTime(real_i, pData.Graphs.Timescale, pData.Seeds.Timescale) or 1
	end
	dt = dt * ts
	local lifeTime = pData.LifeTime
	local priorEff = pData._effectiveElapsed or 0
	local newEff = priorEff + (pData._timeFrozen and 0 or dt)
	if dt < 0 and pData._hitHistory and #pData._hitHistory > 0 then
		EventsCollision.restoreHitsOnReverse(pData, priorEff, newEff)
	end
	if newEff < 0 then newEff = 0 end
	if newEff > lifeTime then newEff = lifeTime end
	pData._effectiveElapsed = newEff
	-- After-clamp dt: boundary frames see partial step instead of overshooting.
	dt = newEff - priorEff
	pData._lastEffectiveDt = dt
	-- Particle dies when effective sits at a boundary AND the graph has finished playing.
	local atForwardEnd = newEff >= lifeTime
	local atBackwardEnd = newEff <= 0
	local elapsedTime = newEff
	local i = elapsedTime / lifeTime

	if not pData.VisualPart or not pData.VisualPart.Parent then return true end
	if pData.TotalKeyFrames <= 0 then return true end
	local graphFinished = real_i >= 1
	-- OnHit Collision=Stop (or auto-settle freeze): skip motion/step work, age normally.
	if pData._collisionStopped then return graphFinished and (atForwardEnd or atBackwardEnd) end

	-- Nested-Model scale: fold the parent Model's current scale into nested-particle motion.
	-- motionFactor scales the spatial delta (Speed/Accel/PosOffset) when ScaleMotion; rotFactor
	-- scales RotSpeed (via rotDamp) when ScaleRotation; sizeFactor scales Size. 1 when not nested.
	local sizeFactor, motionFactor, rotFactor = 1, 1, 1
	if pData.ParentScale then
		sizeFactor = Constants.getParentScaleFactor(pData.ParentScale, currentTime, GraphMod)
		motionFactor = Constants.getParentScaleFactor(pData.ParentScale, currentTime, GraphMod, "motion")
		rotFactor = Constants.getParentScaleFactor(pData.ParentScale, currentTime, GraphMod, "rotation")
	end
	local isDying = graphFinished and (atForwardEnd or atBackwardEnd)
	i = math.min(math.max(i, 0), 1)

	pData.AccumulatedDT += dt
	local targetStep = math.floor(i * pData.TotalKeyFrames)

	if targetStep ~= pData.CurrentStep then
		local prevStep = pData.CurrentStep
		local stepDir = (targetStep > prevStep) and 1 or -1
		local stepsToProcess = math.abs(targetStep - prevStep)
		local perStepDT = pData.AccumulatedDT / stepsToProcess
		local frameDT = pData.AccumulatedDT
		pData.AccumulatedDT = 0

		-- Collision spin (deg/sec) into _spinAccum (degrees); composes with both rotation modes.
		local spinRate = pData._spinRate
		if spinRate and (spinRate.X ~= 0 or spinRate.Y ~= 0 or spinRate.Z ~= 0) then
			pData._spinAccumX = (pData._spinAccumX or 0) + spinRate.X * frameDT
			pData._spinAccumY = (pData._spinAccumY or 0) + spinRate.Y * frameDT
			pData._spinAccumZ = (pData._spinAccumZ or 0) + spinRate.Z * frameDT
		end
		local speedMult = pData.SpeedMultiplier or 1

		-- POSITION: Inverted
		if pData.InvertMotion then
			pData.CurrentStep = targetStep
			local reverseStep = pData.TotalKeyFrames - targetStep
			local localCF = pData.SimLocalCFrames[reverseStep] or pData.SimLocalCFrames[0]
			local parentCF_now = _getLinkCF(pData)
			pData.VisualPart.CFrame = parentCF_now * localCF
			pData._localWorldCF = localCF
			pData.CurrentPosition = pData.VisualPart.Position

		-- POSITION: Forward, FULL iteration (VelocityVectored)
		elseif pData.NeedsFullIteration then
			-- parentCF_now / dirInfo hoisted outside the loop; final CFrame written once at batch end.
			local hasDrag = pData.HasDrag
			local hasAccel = pData.HasAccel
			local parentCF_now, useVOS = _getLinkCF(pData)
			local dirInfo = DirectionVectors[pData.EmissionDirection] or DirectionVectors[Enum.NormalId.Top]
			local localCF = pData.LocalCF
			local accRotX, accRotY, accRotZ = pData.AccRotX, pData.AccRotY, pData.AccRotZ
			local baseDir = pData.BaseDirection
			local accelVel = pData._accelVel or Vector3.zero
			local targetVel = pData.TargetVel
			-- Seed simPos from live VisualPart.Position (overlays moved CFrame since CurrentPosition write).
			local simPos = pData.VisualPart.Position
			local rotMode = pData.RotMode
			local rotOrder = pData.RotOrder or "Global"
			local lastWorldCF, lastLocalWorldCF
			for step = prevStep + stepDir, targetStep, stepDir do
				local si = step / pData.TotalKeyFrames
				local elapsedSec = si * pData.LifeTime

				local speed = pData._speedOverride or ((pData._staticSpeed or GraphMod.QueryPointsWithTime(si, pData.Graphs.Speed, pData.Seeds.Speed)) * speedMult)
				local draggedSpeed = hasDrag and (speed * math.exp(-pData.Drag * elapsedSec)) or speed

				local displacement
				if hasAccel then
					local effA = Constants.applyContactAccel(pData.Acceleration, pData, perStepDT)
					accelVel = accelVel + effA * perStepDT
					displacement = (baseDir * draggedSpeed + accelVel) * perStepDT
				else
					displacement = baseDir * (draggedSpeed * perStepDT)
				end

				-- Target accel: Euler integration; reads simPos for mid-substep tracking.
				if pData.HasTargetAccel then
					local tPos = _getTargetPosition(pData.AccelTarget)
					if tPos then
						local toTarget = tPos - simPos
						local dist = toTarget.Magnitude
						if dist > 1e-4 then
							local mag = pData._staticAccelStrength or GraphMod.QueryPointsWithTime(si, pData.Graphs.AccelStrength, pData.Seeds.AccelStrength)
							if mag and mag ~= 0 then
								targetVel = targetVel + toTarget * (mag * perStepDT / dist)
								displacement = displacement + targetVel * perStepDT
							end
						end
					end
				end

				-- PosOffset per-step delta. Telescoping sums integrate to the absolute-offset
				-- change. _composeLocalDelta VOS's only the velocity; a Local-mode offset is
				-- already link-local and added as-is (else a spinning Weld precesses it).
				local posDelta, posIsLL = _posOffsetFrameDelta(pData, si, useVOS)
				local parentLocalDelta = _composeLocalDelta(parentCF_now, useVOS, displacement, posDelta, posIsLL, motionFactor)
				localCF = CFrame.new(parentLocalDelta) * localCF

				local rotDamp = (pData._settleRotDamp or 1) * rotFactor
				local rotSpeedX = (pData._staticRotSpeedX or GraphMod.QueryPointsWithTime(si, pData.Graphs.RotSpeedX, pData.Seeds.RotSpeedX)) * rotDamp
				local rotSpeedY = (pData._staticRotSpeedY or GraphMod.QueryPointsWithTime(si, pData.Graphs.RotSpeedY, pData.Seeds.RotSpeedY)) * rotDamp
				local rotSpeedZ = (pData._staticRotSpeedZ or GraphMod.QueryPointsWithTime(si, pData.Graphs.RotSpeedZ, pData.Seeds.RotSpeedZ)) * rotDamp

				local rotationCFrame
				local sx = pData._spinAccumX or 0
				local sy = pData._spinAccumY or 0
				local sz = pData._spinAccumZ or 0
				if rotMode == "Speed" then
					accRotX = accRotX + rotSpeedX * perStepDT
					accRotY = accRotY + rotSpeedY * perStepDT
					accRotZ = accRotZ + rotSpeedZ * perStepDT
					rotationCFrame = Constants.composeRotation(rotOrder, accRotX + sx, accRotY + sy, accRotZ + sz)
				else
					rotationCFrame = Constants.composeRotation(rotOrder, rotSpeedX + sx, rotSpeedY + sy, rotSpeedZ + sz)
				end

				lastWorldCF = (parentCF_now * localCF) * rotationCFrame
				lastLocalWorldCF = localCF * rotationCFrame
				simPos = lastWorldCF.Position

				local rotatedCF = lastWorldCF * pData.SpreadRotation
				baseDir = rotatedCF[dirInfo.vector] * dirInfo.multiplier
			end
			pData.LocalCF = localCF
			pData.AccRotX, pData.AccRotY, pData.AccRotZ = accRotX, accRotY, accRotZ
			pData.BaseDirection = baseDir
			pData._accelVel = accelVel
			pData.TargetVel = targetVel
			pData.CurrentPosition = simPos
			pData.CurrentStep = targetStep
			if lastWorldCF then
				pData.VisualPart.CFrame = lastWorldCF
				pData._localWorldCF = lastLocalWorldCF
			end

		-- POSITION: Forward, SPEED ROTATION
		elseif pData.NeedsRotAccum then
			local hasDrag = pData.HasDrag
			local hasAccel = pData.HasAccel
			local totalScalarDisp = 0
			local totalAccelDisp = Vector3.zero
			local accelVel = pData._accelVel or Vector3.zero

			for step = prevStep + stepDir, targetStep, stepDir do
				local si = step / pData.TotalKeyFrames
				local elapsedSec = si * pData.LifeTime
				local speed = pData._speedOverride or ((pData._staticSpeed or GraphMod.QueryPointsWithTime(si, pData.Graphs.Speed, pData.Seeds.Speed)) * speedMult)
				if hasDrag then speed = speed * math.exp(-pData.Drag * elapsedSec) end
				totalScalarDisp = totalScalarDisp + speed * perStepDT
				if hasAccel then
					local effA = Constants.applyContactAccel(pData.Acceleration, pData, perStepDT)
					accelVel = accelVel + effA * perStepDT
					totalAccelDisp = totalAccelDisp + accelVel * perStepDT
				end

				local rotDamp = (pData._settleRotDamp or 1) * rotFactor
				local rotSpeedX = (pData._staticRotSpeedX or GraphMod.QueryPointsWithTime(si, pData.Graphs.RotSpeedX, pData.Seeds.RotSpeedX)) * rotDamp
				local rotSpeedY = (pData._staticRotSpeedY or GraphMod.QueryPointsWithTime(si, pData.Graphs.RotSpeedY, pData.Seeds.RotSpeedY)) * rotDamp
				local rotSpeedZ = (pData._staticRotSpeedZ or GraphMod.QueryPointsWithTime(si, pData.Graphs.RotSpeedZ, pData.Seeds.RotSpeedZ)) * rotDamp
				pData.AccRotX = pData.AccRotX + rotSpeedX * perStepDT
				pData.AccRotY = pData.AccRotY + rotSpeedY * perStepDT
				pData.AccRotZ = pData.AccRotZ + rotSpeedZ * perStepDT
			end
			pData._accelVel = accelVel

			local totalDisplacement = pData.BaseDirection * totalScalarDisp + totalAccelDisp

			-- Target accel: frame-granularity (mid-frame si).
			if pData.HasTargetAccel then
				local tPos = _getTargetPosition(pData.AccelTarget)
				if tPos then
					local toTarget = tPos - pData.VisualPart.Position
					local dist = toTarget.Magnitude
					if dist > 1e-4 then
						local frameDT2 = perStepDT * (targetStep - prevStep)
						local midSI = ((prevStep + 1 + targetStep) * 0.5) / pData.TotalKeyFrames
						local mag = pData._staticAccelStrength or GraphMod.QueryPointsWithTime(midSI, pData.Graphs.AccelStrength, pData.Seeds.AccelStrength)
						if mag and mag ~= 0 then
							pData.TargetVel = pData.TargetVel + toTarget * (mag * frameDT2 / dist)
							totalDisplacement = totalDisplacement + pData.TargetVel * frameDT2
						end
					end
				end
			end

			-- PosOffsetX/Y/Z over-life position graphs. _composeLocalDelta VOS's only the
			-- world velocity; a Local-mode offset is already link-local and added as-is so a
			-- spinning Weld lets the radius shrink instead of precessing the offset.
			local parentCF_now, useVOS = _getLinkCF(pData)
			local posDelta, posIsLL = _posOffsetFrameDelta(pData, targetStep / pData.TotalKeyFrames, useVOS)
			local parentLocalDelta = _composeLocalDelta(parentCF_now, useVOS, totalDisplacement, posDelta, posIsLL, motionFactor)
			pData.LocalCF = CFrame.new(parentLocalDelta) * pData.LocalCF
			local sx = pData._spinAccumX or 0
			local sy = pData._spinAccumY or 0
			local sz = pData._spinAccumZ or 0
			local rotationCFrame = Constants.composeRotation(pData.RotOrder or "Global", pData.AccRotX + sx, pData.AccRotY + sy, pData.AccRotZ + sz)

			pData.VisualPart.CFrame = (parentCF_now * pData.LocalCF) * rotationCFrame
			pData._localWorldCF = pData.LocalCF * rotationCFrame
			pData.CurrentPosition = pData.VisualPart.Position
			pData.CurrentStep = targetStep

		-- POSITION: Forward, FAST
		else
			local hasDrag = pData.HasDrag
			local hasAccel = pData.HasAccel
			local totalScalarDisp = 0
			local totalAccelDisp = Vector3.zero
			local accelVel = pData._accelVel or Vector3.zero

			-- Drag-free closed form: speed integral + (accelVel*Δt + 0.5*accel*Δt²).
			if not hasDrag then
				local invTKF = 1 / pData.TotalKeyFrames
				local prevT = prevStep * invTKF
				local targetT = targetStep * invTKF
				local override = pData._speedOverride
				if override then
					totalScalarDisp = override * (targetT - prevT) * pData.LifeTime
				elseif pData._staticSpeed then
					-- Constant Speed integrates to value × duration.
					totalScalarDisp = pData._staticSpeed * speedMult * (targetT - prevT) * pData.LifeTime
				else
					totalScalarDisp = pData.LifeTime * speedMult * (GraphMod.IntegrateUpTo(targetT, pData.Graphs.Speed, pData.Seeds.Speed) - GraphMod.IntegrateUpTo(prevT, pData.Graphs.Speed, pData.Seeds.Speed))
				end
				if hasAccel then
					local deltaSec = (targetT - prevT) * pData.LifeTime
					local effA = Constants.applyContactAccel(pData.Acceleration, pData, deltaSec)
					totalAccelDisp = accelVel * deltaSec + effA * (deltaSec * deltaSec * 0.5)
					accelVel = accelVel + effA * deltaSec
				end
			else
				-- Drag fallback: per-step loop.
				for step = prevStep + stepDir, targetStep, stepDir do
					local si = step / pData.TotalKeyFrames
					local elapsedSec = si * pData.LifeTime
					local speed = pData._speedOverride or ((pData._staticSpeed or GraphMod.QueryPointsWithTime(si, pData.Graphs.Speed, pData.Seeds.Speed)) * speedMult)
					speed = speed * math.exp(-pData.Drag * elapsedSec)
					totalScalarDisp = totalScalarDisp + speed * perStepDT
					if hasAccel then
						local effA = Constants.applyContactAccel(pData.Acceleration, pData, perStepDT)
						accelVel = accelVel + effA * perStepDT
						totalAccelDisp = totalAccelDisp + accelVel * perStepDT
					end
				end
			end
			pData._accelVel = accelVel

			local totalDisplacement = pData.BaseDirection * totalScalarDisp + totalAccelDisp

			-- Target accel: frame-granularity sample.
			if pData.HasTargetAccel then
				local tPos = _getTargetPosition(pData.AccelTarget)
				if tPos then
					local toTarget = tPos - pData.VisualPart.Position
					local dist = toTarget.Magnitude
					if dist > 1e-4 then
						local frameDT = perStepDT * (targetStep - prevStep)
						local midSI = ((prevStep + 1 + targetStep) * 0.5) / pData.TotalKeyFrames
						local mag = pData._staticAccelStrength or GraphMod.QueryPointsWithTime(midSI, pData.Graphs.AccelStrength, pData.Seeds.AccelStrength)
						if mag and mag ~= 0 then
							pData.TargetVel = pData.TargetVel + toTarget * (mag * frameDT / dist)
							totalDisplacement = totalDisplacement + pData.TargetVel * frameDT
						end
					end
				end
			end

			-- PosOffset over-life graphs. _composeLocalDelta VOS's only the velocity; a Local-mode
			-- offset is link-local and added as-is (no precession on a spinning Weld).
			local parentCF_now, useVOS = _getLinkCF(pData)
			local posDelta, posIsLL = _posOffsetFrameDelta(pData, targetStep / pData.TotalKeyFrames, useVOS)
			local parentLocalDelta = _composeLocalDelta(parentCF_now, useVOS, totalDisplacement, posDelta, posIsLL, motionFactor)
			pData.LocalCF = CFrame.new(parentLocalDelta) * pData.LocalCF

			local steppedI = targetStep / pData.TotalKeyFrames
			local rotDamp = (pData._settleRotDamp or 1) * rotFactor
			local rotX = (pData._staticRotSpeedX or GraphMod.QueryPointsWithTime(steppedI, pData.Graphs.RotSpeedX, pData.Seeds.RotSpeedX)) * rotDamp + (pData._spinAccumX or 0)
			local rotY = (pData._staticRotSpeedY or GraphMod.QueryPointsWithTime(steppedI, pData.Graphs.RotSpeedY, pData.Seeds.RotSpeedY)) * rotDamp + (pData._spinAccumY or 0)
			local rotZ = (pData._staticRotSpeedZ or GraphMod.QueryPointsWithTime(steppedI, pData.Graphs.RotSpeedZ, pData.Seeds.RotSpeedZ)) * rotDamp + (pData._spinAccumZ or 0)
			local rotationCFrame = Constants.composeRotation(pData.RotOrder or "Global", rotX, rotY, rotZ)

			pData.VisualPart.CFrame = (parentCF_now * pData.LocalCF) * rotationCFrame
			pData._localWorldCF = pData.LocalCF * rotationCFrame
			pData.CurrentPosition = pData.VisualPart.Position
			pData.CurrentStep = targetStep
		end

		-- SIZE  -  gated by pData.SkipSize (set via payload.SetSkipSize).
		local steppedI = targetStep / pData.TotalKeyFrames
		if not pData.SkipSize then
			local sizex = pData._staticSizeX or GraphMod.QueryPointsWithTime(steppedI, pData.Graphs.SizeX, pData.Seeds.SizeX)
			local sizey = pData._staticSizeY or GraphMod.QueryPointsWithTime(steppedI, pData.Graphs.SizeY, pData.Seeds.SizeY)
			local sizez = pData._staticSizeZ or GraphMod.QueryPointsWithTime(steppedI, pData.Graphs.SizeZ, pData.Seeds.SizeZ)

			-- Nested-Model scale on Size (always-on; independent of ScaleMotion). sizeFactor
			-- hoisted once at function top via Constants.getParentScaleFactor.
			if sizeFactor ~= 1 then
				sizex = sizex * sizeFactor
				sizey = sizey * sizeFactor
				sizez = sizez * sizeFactor
			end

			if pData.SpecialMesh then
				pData.SpecialMesh.Scale = Vector3.new(sizex, sizey, sizez)
			else
				pData.VisualPart.Size = Vector3.new(sizex, sizey, sizez)
			end
		end

		-- VISUAL
		local transparency = pData._staticTransparency or GraphMod.QueryPointsWithTime(steppedI, pData.Graphs.Transparency, pData.Seeds.Transparency)

		if pData.SurfaceAppearance then
			-- Color graph tints SA.Color raw; Brightness graph drives SA.EmissiveTint only.
			-- EmissiveTint write pcall-guarded for older Studio builds without the property.
			local brightness = pData._staticBrightness or GraphMod.QueryPointsWithTime(steppedI, pData.Graphs.Brightness, pData.Seeds.Brightness)
			local color = GraphMod.QueryColorPointWithTime(steppedI, pData.Graphs.Color)
			if not pData.SkipTransparency then pData.VisualPart.Transparency = transparency end
			if not pData.SkipColor then
				pData.VisualPart.Color = Color3.fromRGB(color.R * 255, color.G * 255, color.B * 255)
				pData.SurfaceAppearance.Color = Color3.fromRGB(color.R * 255, color.G * 255, color.B * 255)
				pcall(function() pData.SurfaceAppearance.EmissiveTint = Color3.new(color.R * brightness, color.G * brightness, color.B * brightness) end)
			end
		elseif pData.HasDecal then
			local brightness = pData._staticBrightness or GraphMod.QueryPointsWithTime(steppedI, pData.Graphs.Brightness, pData.Seeds.Brightness)
			local color = GraphMod.QueryColorPointWithTime(steppedI, pData.Graphs.Color)
			if not pData.SkipTransparency then pData.Decal.Transparency = transparency end
			if not pData.SkipColor then pData.Decal.Color3 = Color3.fromRGB(color.R * 255 * brightness, color.G * 255 * brightness, color.B * 255 * brightness) end
		else
			-- Plain MeshPart: Brightness multiplies SA/Decal only, not mesh Color.
			local color = GraphMod.QueryColorPointWithTime(steppedI, pData.Graphs.Color)
			if not pData.SkipTransparency then pData.VisualPart.Transparency = transparency end
			if not pData.SkipColor then pData.VisualPart.Color = Color3.fromRGB(color.R * 255, color.G * 255, color.B * 255) end
		end
	end

	return isDying
end

--[[
	Attachment 逐帧更新：父级局部运动。无 Size 曲线（Attachment 只驱动子实例）。
	寿命到期或视觉已销毁返回 true。

	@param pData table - 运行时粒子状态（Type=Attachment；VisualPart / Graphs / Seeds / LocalCF 等）
	@param dt number - Heartbeat 增量秒
	@param currentTime number - os.clock 当前时间
	@return boolean - true 表示应结束
]]
function Particle:UpdateAttachment(pData, dt, currentTime)
	-- Signed-reverse Timescale: see UpdatePart. SetTimescale override wins for its window.
	local real_i = math.min(math.max((currentTime - pData.StartTime) / pData.LifeTime, 0), 1)
	local ts
	if pData._tsOverride ~= nil and currentTime < (pData._tsOverrideUntil or 0) then
		ts = pData._tsOverride
	else
		ts = pData.Graphs.Timescale and GraphMod.QueryPointsWithTime(real_i, pData.Graphs.Timescale, pData.Seeds.Timescale) or 1
	end
	dt = dt * ts
	local lifeTime = pData.LifeTime
	local priorEff = pData._effectiveElapsed or 0
	local newEff = priorEff + (pData._timeFrozen and 0 or dt)
	if dt < 0 and pData._hitHistory and #pData._hitHistory > 0 then
		EventsCollision.restoreHitsOnReverse(pData, priorEff, newEff)
	end
	if newEff < 0 then newEff = 0 end
	if newEff > lifeTime then newEff = lifeTime end
	pData._effectiveElapsed = newEff
	-- After-clamp dt: boundary frames see partial step instead of overshooting.
	dt = newEff - priorEff
	pData._lastEffectiveDt = dt
	local atForwardEnd = newEff >= lifeTime
	local atBackwardEnd = newEff <= 0
	local elapsedTime = newEff
	local i = elapsedTime / lifeTime
	if not pData.VisualPart or not pData.VisualPart.Parent then return true end
	if pData.TotalKeyFrames <= 0 then return true end
	local graphFinished = real_i >= 1
	if pData._collisionStopped then return graphFinished and (atForwardEnd or atBackwardEnd) end

	-- Nested-Model scale (see UpdatePart): motionFactor scales the spatial delta, rotFactor
	-- scales RotSpeed via rotDamp, sizeFactor scales Size. 1 when not nested.
	local sizeFactor, motionFactor, rotFactor = 1, 1, 1
	if pData.ParentScale then
		sizeFactor = Constants.getParentScaleFactor(pData.ParentScale, currentTime, GraphMod)
		motionFactor = Constants.getParentScaleFactor(pData.ParentScale, currentTime, GraphMod, "motion")
		rotFactor = Constants.getParentScaleFactor(pData.ParentScale, currentTime, GraphMod, "rotation")
	end
	local isDying = graphFinished and (atForwardEnd or atBackwardEnd)
	i = math.min(math.max(i, 0), 1)
	pData.AccumulatedDT += dt
	local targetStep = math.floor(i * pData.TotalKeyFrames)

	if targetStep ~= pData.CurrentStep then
		local prevStep = pData.CurrentStep
		local stepDir = (targetStep > prevStep) and 1 or -1
		local stepsToProcess = math.abs(targetStep - prevStep)
		local perStepDT = pData.AccumulatedDT / stepsToProcess
		local frameDT = pData.AccumulatedDT
		pData.AccumulatedDT = 0
		local spinRate = pData._spinRate
		if spinRate and (spinRate.X ~= 0 or spinRate.Y ~= 0 or spinRate.Z ~= 0) then
			pData._spinAccumX = (pData._spinAccumX or 0) + spinRate.X * frameDT
			pData._spinAccumY = (pData._spinAccumY or 0) + spinRate.Y * frameDT
			pData._spinAccumZ = (pData._spinAccumZ or 0) + spinRate.Z * frameDT
		end
		local speedMult = pData.SpeedMultiplier or 1

		-- actualParent-local link CFrame; identity when no link.
		local parentCF_now, useVOS = _getAttachmentLinkCF(pData)

		if pData.InvertMotion then
			pData.CurrentStep = targetStep
			local reverseStep = pData.TotalKeyFrames - targetStep
			local localCF = pData.SimLocalCFrames[reverseStep] or pData.SimLocalCFrames[0]
			pData.VisualPart.CFrame = parentCF_now * localCF
			pData.LocalCF = localCF
			pData._localWorldCF = localCF

		-- POSITION: Forward, FULL iteration (VelocityVectored)
		elseif pData.NeedsFullIteration then
			local hasDrag = pData.HasDrag
			local hasAccel = pData.HasAccel
			local accelVel = pData._accelVel or Vector3.zero
			local sx = pData._spinAccumX or 0
			local sy = pData._spinAccumY or 0
			local sz = pData._spinAccumZ or 0
			local rotOrder = pData.RotOrder or "Global"
			for step = prevStep + stepDir, targetStep, stepDir do
				local si = step / pData.TotalKeyFrames
				local elapsedSec = si * pData.LifeTime

				local speed = pData._speedOverride or ((pData._staticSpeed or GraphMod.QueryPointsWithTime(si, pData.Graphs.Speed, pData.Seeds.Speed)) * speedMult)
				local draggedSpeed = hasDrag and (speed * math.exp(-pData.Drag * elapsedSec)) or speed

				local displacement
				if hasAccel then
					local effA = Constants.applyContactAccel(pData.Acceleration, pData, perStepDT)
					accelVel = accelVel + effA * perStepDT
					displacement = (pData.BaseDirection * draggedSpeed + accelVel) * perStepDT
				else
					displacement = pData.BaseDirection * (draggedSpeed * perStepDT)
				end

				-- PosOffset per-step delta. _composeLocalDelta VOS's only the world velocity into
				-- link-local; a Local-mode offset is already link-local and added as-is.
				local posDelta, posIsLL = _posOffsetFrameDelta(pData, si, useVOS)
				local stepDelta = _composeLocalDelta(parentCF_now, useVOS, displacement, posDelta, posIsLL, motionFactor)
				pData.LocalCF = CFrame.new(stepDelta) * pData.LocalCF

				-- Rotation
				local rotDamp = (pData._settleRotDamp or 1) * rotFactor
				local rotSpeedX = (pData._staticRotSpeedX or GraphMod.QueryPointsWithTime(si, pData.Graphs.RotSpeedX, pData.Seeds.RotSpeedX)) * rotDamp
				local rotSpeedY = (pData._staticRotSpeedY or GraphMod.QueryPointsWithTime(si, pData.Graphs.RotSpeedY, pData.Seeds.RotSpeedY)) * rotDamp
				local rotSpeedZ = (pData._staticRotSpeedZ or GraphMod.QueryPointsWithTime(si, pData.Graphs.RotSpeedZ, pData.Seeds.RotSpeedZ)) * rotDamp

				local rotationCFrame
				if pData.RotMode == "Speed" then
					pData.AccRotX = pData.AccRotX + rotSpeedX * perStepDT
					pData.AccRotY = pData.AccRotY + rotSpeedY * perStepDT
					pData.AccRotZ = pData.AccRotZ + rotSpeedZ * perStepDT
					rotationCFrame = Constants.composeRotation(rotOrder, pData.AccRotX + sx, pData.AccRotY + sy, pData.AccRotZ + sz)
				else
					rotationCFrame = Constants.composeRotation(rotOrder, rotSpeedX + sx, rotSpeedY + sy, rotSpeedZ + sz)
				end

				pData.VisualPart.CFrame = parentCF_now * pData.LocalCF * rotationCFrame
				pData._localWorldCF = pData.LocalCF * rotationCFrame

				local rotatedCF = pData.VisualPart.CFrame * pData.SpreadRotation
				local dirInfo = DirectionVectors[pData.EmissionDirection] or DirectionVectors[Enum.NormalId.Top]
				pData.BaseDirection = rotatedCF[dirInfo.vector] * dirInfo.multiplier
			end
			pData._accelVel = accelVel
			pData.CurrentStep = targetStep

		-- POSITION: Forward, SPEED ROTATION
		elseif pData.NeedsRotAccum then
			local hasDrag = pData.HasDrag
			local hasAccel = pData.HasAccel
			local totalScalarDisp = 0
			local totalAccelDisp = Vector3.zero
			local accelVel = pData._accelVel or Vector3.zero

			for step = prevStep + stepDir, targetStep, stepDir do
				local si = step / pData.TotalKeyFrames
				local elapsedSec = si * pData.LifeTime
				local speed = pData._speedOverride or ((pData._staticSpeed or GraphMod.QueryPointsWithTime(si, pData.Graphs.Speed, pData.Seeds.Speed)) * speedMult)
				if hasDrag then speed = speed * math.exp(-pData.Drag * elapsedSec) end
				totalScalarDisp = totalScalarDisp + speed * perStepDT
				if hasAccel then
					local effA = Constants.applyContactAccel(pData.Acceleration, pData, perStepDT)
					accelVel = accelVel + effA * perStepDT
					totalAccelDisp = totalAccelDisp + accelVel * perStepDT
				end

				local rotDamp = (pData._settleRotDamp or 1) * rotFactor
				local rotSpeedX = (pData._staticRotSpeedX or GraphMod.QueryPointsWithTime(si, pData.Graphs.RotSpeedX, pData.Seeds.RotSpeedX)) * rotDamp
				local rotSpeedY = (pData._staticRotSpeedY or GraphMod.QueryPointsWithTime(si, pData.Graphs.RotSpeedY, pData.Seeds.RotSpeedY)) * rotDamp
				local rotSpeedZ = (pData._staticRotSpeedZ or GraphMod.QueryPointsWithTime(si, pData.Graphs.RotSpeedZ, pData.Seeds.RotSpeedZ)) * rotDamp
				pData.AccRotX = pData.AccRotX + rotSpeedX * perStepDT
				pData.AccRotY = pData.AccRotY + rotSpeedY * perStepDT
				pData.AccRotZ = pData.AccRotZ + rotSpeedZ * perStepDT
			end
			pData._accelVel = accelVel

			local totalDisplacement = pData.BaseDirection * totalScalarDisp + totalAccelDisp
			local posDelta, posIsLL = _posOffsetFrameDelta(pData, targetStep / pData.TotalKeyFrames, useVOS)
			local stepDelta = _composeLocalDelta(parentCF_now, useVOS, totalDisplacement, posDelta, posIsLL, motionFactor)
			pData.LocalCF = CFrame.new(stepDelta) * pData.LocalCF
			local sx = pData._spinAccumX or 0
			local sy = pData._spinAccumY or 0
			local sz = pData._spinAccumZ or 0
			local rotationCFrame = Constants.composeRotation(pData.RotOrder or "Global", pData.AccRotX + sx, pData.AccRotY + sy, pData.AccRotZ + sz)

			pData.VisualPart.CFrame = parentCF_now * pData.LocalCF * rotationCFrame
			pData._localWorldCF = pData.LocalCF * rotationCFrame
			pData.CurrentStep = targetStep

		-- POSITION: Forward, FAST
		else
			local hasDrag = pData.HasDrag
			local hasAccel = pData.HasAccel
			local totalScalarDisp = 0
			local totalAccelDisp = Vector3.zero
			local accelVel = pData._accelVel or Vector3.zero

			-- Drag-free closed form: speed integral + (accelVel*Δt + 0.5*accel*Δt²).
			if not hasDrag then
				local invTKF = 1 / pData.TotalKeyFrames
				local prevT = prevStep * invTKF
				local targetT = targetStep * invTKF
				local override = pData._speedOverride
				if override then
					totalScalarDisp = override * (targetT - prevT) * pData.LifeTime
				elseif pData._staticSpeed then
					-- Constant Speed integrates to value × duration.
					totalScalarDisp = pData._staticSpeed * speedMult * (targetT - prevT) * pData.LifeTime
				else
					totalScalarDisp = pData.LifeTime * speedMult * (GraphMod.IntegrateUpTo(targetT, pData.Graphs.Speed, pData.Seeds.Speed) - GraphMod.IntegrateUpTo(prevT, pData.Graphs.Speed, pData.Seeds.Speed))
				end
				if hasAccel then
					local deltaSec = (targetT - prevT) * pData.LifeTime
					local effA = Constants.applyContactAccel(pData.Acceleration, pData, deltaSec)
					totalAccelDisp = accelVel * deltaSec + effA * (deltaSec * deltaSec * 0.5)
					accelVel = accelVel + effA * deltaSec
				end
			else
				for step = prevStep + stepDir, targetStep, stepDir do
					local si = step / pData.TotalKeyFrames
					local elapsedSec = si * pData.LifeTime
					local speed = pData._speedOverride or ((pData._staticSpeed or GraphMod.QueryPointsWithTime(si, pData.Graphs.Speed, pData.Seeds.Speed)) * speedMult)
					speed = speed * math.exp(-pData.Drag * elapsedSec)
					totalScalarDisp = totalScalarDisp + speed * perStepDT
					if hasAccel then
						local effA = Constants.applyContactAccel(pData.Acceleration, pData, perStepDT)
						accelVel = accelVel + effA * perStepDT
						totalAccelDisp = totalAccelDisp + accelVel * perStepDT
					end
				end
			end
			pData._accelVel = accelVel

			local totalDisplacement = pData.BaseDirection * totalScalarDisp + totalAccelDisp
			local posDelta, posIsLL = _posOffsetFrameDelta(pData, targetStep / pData.TotalKeyFrames, useVOS)
			local stepDelta = _composeLocalDelta(parentCF_now, useVOS, totalDisplacement, posDelta, posIsLL, motionFactor)
			pData.LocalCF = CFrame.new(stepDelta) * pData.LocalCF

			local steppedI = targetStep / pData.TotalKeyFrames
			local rotDamp = (pData._settleRotDamp or 1) * rotFactor
			local rotX = (pData._staticRotSpeedX or GraphMod.QueryPointsWithTime(steppedI, pData.Graphs.RotSpeedX, pData.Seeds.RotSpeedX)) * rotDamp + (pData._spinAccumX or 0)
			local rotY = (pData._staticRotSpeedY or GraphMod.QueryPointsWithTime(steppedI, pData.Graphs.RotSpeedY, pData.Seeds.RotSpeedY)) * rotDamp + (pData._spinAccumY or 0)
			local rotZ = (pData._staticRotSpeedZ or GraphMod.QueryPointsWithTime(steppedI, pData.Graphs.RotSpeedZ, pData.Seeds.RotSpeedZ)) * rotDamp + (pData._spinAccumZ or 0)
			local rotationCFrame = Constants.composeRotation(pData.RotOrder or "Global", rotX, rotY, rotZ)

			pData.VisualPart.CFrame = parentCF_now * pData.LocalCF * rotationCFrame
			pData._localWorldCF = pData.LocalCF * rotationCFrame
			pData.CurrentStep = targetStep
		end
	end

	return isDying
end

end
