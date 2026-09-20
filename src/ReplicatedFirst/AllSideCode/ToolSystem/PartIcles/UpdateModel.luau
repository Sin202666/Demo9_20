--[[
	Module: PartIcles.UpdateModel
	Description: Model 粒子每帧 Mixin：与 UpdatePart 相同运动分支，PivotTo 定位、ScaleTo 缩放
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-09-01

	功能：
	- UpdateModel：推进有效寿命，按 Invert / FullIteration / RotAccum / Fast 写 Pivot 与 Scale
	- 碰撞反转、PosOffset、Link、父 Model 缩放与 UpdatePart 对齐

	加载：由 PartIcles 引擎 mixin，业务勿直接 require
]]

local GraphMod = require(script.Parent.Graph)
local Constants = require(script.Parent.PartConstants)
local EventsCollision = require(script.Parent.EventsCollision)
local DirectionVectors = Constants.DirectionVectors

--[[
	PosOffsetX/Y/Z 寿命图 → 本帧位移增量。
	经 Constants.resolveDisplacement，使 DisplacementMode（Global/Local/RigidLocal）
	与 OnHit 镜像轴与 Update.luau:_posOffsetFrameDelta 的 Part/Attachment 路径一致。
	@param pData table - 发射态：Graphs / Seeds / DisplacementMode / SpawnRotation / _prevWorldOff 等
	@param steppedI number - 当前步进归一化时间 [0,1]
	@return Vector3 - 相对上一帧的世界位移增量
]]
local function _posOffsetFrameDelta(pData, steppedI)
	if not pData.HasPosOffsetGraphs then return Vector3.zero end
	local oX = pData._staticPosOffsetX or (pData.Graphs.PosOffsetX and GraphMod.QueryPointsWithTime(steppedI, pData.Graphs.PosOffsetX, pData.Seeds.PosOffsetX)) or 0
	local oY = pData._staticPosOffsetY or (pData.Graphs.PosOffsetY and GraphMod.QueryPointsWithTime(steppedI, pData.Graphs.PosOffsetY, pData.Seeds.PosOffsetY)) or 0
	local oZ = pData._staticPosOffsetZ or (pData.Graphs.PosOffsetZ and GraphMod.QueryPointsWithTime(steppedI, pData.Graphs.PosOffsetZ, pData.Seeds.PosOffsetZ)) or 0
	local worldOff = Constants.resolveDisplacement(Vector3.new(oX, oY, oZ),
		pData.DisplacementMode or "Global", pData.SpawnRotation, pData.SpawnEmitterRotation,
		pData._displacementMirrorX, pData._displacementMirrorY, pData._displacementMirrorZ)
	local delta = worldOff - pData._prevWorldOff
	pData._prevWorldOff = worldOff
	return delta
end

--[[
	解析链接父 CFrame（Model/Bone 走 Constants.resolveLinkCFrame）。
	RigidLocal 读发射时快照 pData._rigidLocalParentCF。
	@param pData table - 发射态：Link / LinkMode / _rigidLocalParentCF
	@return CFrame - 父世界 CFrame；Follow/Pivot 仅位置
	@return boolean - 是否应用 VectorToObjectSpace（Weld 类为 true）
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
	把 UpdateModel 挂到引擎单例。
	@param Particle table - PartIcles 引擎
	@return () - 无返回值
]]
return function(Particle)

--[[
	Model 每帧更新：推进有效寿命，PivotTo 写位姿，ScaleTo 写缩放。
	死亡由 Engine.luau swap-and-pop 消费。
	@param pData table - 发射态：VisualPart / Graphs / Seeds / LocalCF / SimLocalCFrames / Link 等
	@param dt number - 本帧真实 delta（函数内会乘 Timescale 再按边界钳制）
	@param currentTime number - 引擎当前时间
	@return boolean - true 表示已死亡
]]
function Particle:UpdateModel(pData, dt, currentTime)
	-- Signed-reverse Timescale: see Update.luau UpdatePart. SetTimescale override wins for its window.
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
	local isDying = graphFinished and (atForwardEnd or atBackwardEnd)
	i = math.min(math.max(i, 0), 1)

	pData.AccumulatedDT += dt
	local targetStep = math.floor(i * pData.TotalKeyFrames)

	if targetStep ~= pData.CurrentStep then
		local prevStep = pData.CurrentStep
		local stepDir = (targetStep > prevStep) and 1 or -1
		local stepsToProcess = math.abs(targetStep - prevStep)
		local frameDT = pData.AccumulatedDT
		local perStepDT = frameDT / stepsToProcess
		pData.AccumulatedDT = 0

		-- Collision spin: angular velocity (deg/sec) into per-axis accumulators.
		local spinRate = pData._spinRate
		if spinRate and (spinRate.X ~= 0 or spinRate.Y ~= 0 or spinRate.Z ~= 0) then
			pData._spinAccumX = (pData._spinAccumX or 0) + spinRate.X * frameDT
			pData._spinAccumY = (pData._spinAccumY or 0) + spinRate.Y * frameDT
			pData._spinAccumZ = (pData._spinAccumZ or 0) + spinRate.Z * frameDT
		end
		local speedMult = pData.SpeedMultiplier or 1
		local spinAddX = pData._spinAccumX or 0
		local spinAddY = pData._spinAccumY or 0
		local spinAddZ = pData._spinAccumZ or 0
		local rotOrder = pData.RotOrder or "Global"

		-- POSITION: Inverted
		if pData.InvertMotion then
			pData.CurrentStep = targetStep
			local reverseStep = pData.TotalKeyFrames - targetStep
			local localCF = pData.SimLocalCFrames[reverseStep] or pData.SimLocalCFrames[0]
			local parentCF_now = _getLinkCF(pData)
			pData.VisualPart:PivotTo(parentCF_now * localCF)
			pData._localWorldCF = localCF
			pData.CurrentPosition = pData.VisualPart:GetPivot().Position

		-- POSITION: Forward, FULL iteration (VelocityVectored)
		elseif pData.NeedsFullIteration then
			local hasDrag = pData.HasDrag
			local hasAccel = pData.HasAccel
			local accelVel = pData._accelVel or Vector3.zero
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

				-- PosOffset per-step delta. Telescoping integration across loop iterations.
				displacement = displacement + _posOffsetFrameDelta(pData, si)

				local parentCF_now, useVOS = _getLinkCF(pData)
				local parentLocalDelta = useVOS and parentCF_now:VectorToObjectSpace(displacement) or displacement
				pData.LocalCF = CFrame.new(parentLocalDelta) * pData.LocalCF

				local rotDamp = pData._settleRotDamp or 1
				local rotSpeedX = (pData._staticRotSpeedX or GraphMod.QueryPointsWithTime(si, pData.Graphs.RotSpeedX, pData.Seeds.RotSpeedX)) * rotDamp
				local rotSpeedY = (pData._staticRotSpeedY or GraphMod.QueryPointsWithTime(si, pData.Graphs.RotSpeedY, pData.Seeds.RotSpeedY)) * rotDamp
				local rotSpeedZ = (pData._staticRotSpeedZ or GraphMod.QueryPointsWithTime(si, pData.Graphs.RotSpeedZ, pData.Seeds.RotSpeedZ)) * rotDamp

				local rotationCFrame
				if pData.RotMode == "Speed" then
					pData.AccRotX = pData.AccRotX + rotSpeedX * perStepDT
					pData.AccRotY = pData.AccRotY + rotSpeedY * perStepDT
					pData.AccRotZ = pData.AccRotZ + rotSpeedZ * perStepDT
					rotationCFrame = Constants.composeRotation(rotOrder, pData.AccRotX + spinAddX, pData.AccRotY + spinAddY, pData.AccRotZ + spinAddZ)
				else
					rotationCFrame = Constants.composeRotation(rotOrder, rotSpeedX + spinAddX, rotSpeedY + spinAddY, rotSpeedZ + spinAddZ)
				end

				pData.VisualPart:PivotTo((parentCF_now * pData.LocalCF) * rotationCFrame)
				pData._localWorldCF = pData.LocalCF * rotationCFrame
				pData.CurrentPosition = pData.VisualPart:GetPivot().Position

				local rotatedCF = pData.VisualPart:GetPivot() * pData.SpreadRotation
				local dirInfo = DirectionVectors[pData.EmissionDirection] or DirectionVectors[Enum.NormalId.Top]
				pData.BaseDirection = rotatedCF[dirInfo.vector] * dirInfo.multiplier
			end
			pData._accelVel = accelVel
			pData.CurrentStep = targetStep

		-- POSITION: Forward, SPEED ROTATION (accumulated rotation)
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

				local rotDamp = pData._settleRotDamp or 1
				local rotSpeedX = (pData._staticRotSpeedX or GraphMod.QueryPointsWithTime(si, pData.Graphs.RotSpeedX, pData.Seeds.RotSpeedX)) * rotDamp
				local rotSpeedY = (pData._staticRotSpeedY or GraphMod.QueryPointsWithTime(si, pData.Graphs.RotSpeedY, pData.Seeds.RotSpeedY)) * rotDamp
				local rotSpeedZ = (pData._staticRotSpeedZ or GraphMod.QueryPointsWithTime(si, pData.Graphs.RotSpeedZ, pData.Seeds.RotSpeedZ)) * rotDamp
				pData.AccRotX = pData.AccRotX + rotSpeedX * perStepDT
				pData.AccRotY = pData.AccRotY + rotSpeedY * perStepDT
				pData.AccRotZ = pData.AccRotZ + rotSpeedZ * perStepDT
			end
			pData._accelVel = accelVel

			local totalDisplacement = pData.BaseDirection * totalScalarDisp + totalAccelDisp
			totalDisplacement = totalDisplacement + _posOffsetFrameDelta(pData, targetStep / pData.TotalKeyFrames)

			local parentCF_now, useVOS = _getLinkCF(pData)
			local parentLocalDelta = useVOS and parentCF_now:VectorToObjectSpace(totalDisplacement) or totalDisplacement
			pData.LocalCF = CFrame.new(parentLocalDelta) * pData.LocalCF
			local rotationCFrame = Constants.composeRotation(rotOrder, pData.AccRotX + spinAddX, pData.AccRotY + spinAddY, pData.AccRotZ + spinAddZ)

			pData.VisualPart:PivotTo((parentCF_now * pData.LocalCF) * rotationCFrame)
			pData._localWorldCF = pData.LocalCF * rotationCFrame
			pData.CurrentPosition = pData.VisualPart:GetPivot().Position
			pData.CurrentStep = targetStep

		-- POSITION: Forward, FAST (absolute rotation)
		else
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
			end
			pData._accelVel = accelVel

			local totalDisplacement = pData.BaseDirection * totalScalarDisp + totalAccelDisp
			totalDisplacement = totalDisplacement + _posOffsetFrameDelta(pData, targetStep / pData.TotalKeyFrames)

			local parentCF_now, useVOS = _getLinkCF(pData)
			local parentLocalDelta = useVOS and parentCF_now:VectorToObjectSpace(totalDisplacement) or totalDisplacement
			pData.LocalCF = CFrame.new(parentLocalDelta) * pData.LocalCF

			local steppedI = targetStep / pData.TotalKeyFrames
			local rotDamp = pData._settleRotDamp or 1
			local rotX = (pData._staticRotSpeedX or GraphMod.QueryPointsWithTime(steppedI, pData.Graphs.RotSpeedX, pData.Seeds.RotSpeedX)) * rotDamp
			local rotY = (pData._staticRotSpeedY or GraphMod.QueryPointsWithTime(steppedI, pData.Graphs.RotSpeedY, pData.Seeds.RotSpeedY)) * rotDamp
			local rotZ = (pData._staticRotSpeedZ or GraphMod.QueryPointsWithTime(steppedI, pData.Graphs.RotSpeedZ, pData.Seeds.RotSpeedZ)) * rotDamp
			local rotationCFrame = Constants.composeRotation(rotOrder, rotX + spinAddX, rotY + spinAddY, rotZ + spinAddZ)

			pData.VisualPart:PivotTo((parentCF_now * pData.LocalCF) * rotationCFrame)
			pData._localWorldCF = pData.LocalCF * rotationCFrame
			pData.CurrentPosition = pData.VisualPart:GetPivot().Position
			pData.CurrentStep = targetStep
		end

		-- SCALE: ScaleTo cascades to BaseParts, Meshes, PEs, Beams, Trails.
		local steppedI = targetStep / pData.TotalKeyFrames
		local scale = math.max(0.001, pData._staticScale or GraphMod.QueryPointsWithTime(steppedI, pData.Graphs.Scale, pData.Seeds.Scale))
		-- Nested Model: compound with the inherited parent-Model scale chain (1 if top-level).
		scale = scale * Constants.getParentScaleFactor(pData.ParentScale, currentTime, GraphMod)
		pData.VisualPart:ScaleTo(scale)
		-- ScaleTo can drop descendant Beam.Segments below 20; re-clamp.
		if pData._visualBeams then
			for _, beam in ipairs(pData._visualBeams) do
				if beam.Parent and beam.Segments < 20 then beam.Segments = 20 end
			end
		end
	end

	return isDying
end

end
