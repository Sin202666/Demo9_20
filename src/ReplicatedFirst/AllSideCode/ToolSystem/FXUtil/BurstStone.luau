--[[
	Module: FXUtil/BurstStone
	Description: 石块冲击波、飞石与地裂特效
	Author: LinAoyu
	Created: 2024-01-01
	Last Modified: 2026-07-30
]]

local module = {}

-- ============================================================================
-- 导入和依赖
-- ============================================================================

-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local RunService = game:GetService("RunService")

-- Modules
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local RayCast = Utils.RayCast


local BurstStoneConfig = require(script.Parent.BurstStoneConfig)

-- ============================================================================
-- 内部辅助函数
-- ============================================================================

--[[
	将射线命中材质应用到石块 Part
	@param Stone Part
	@param RayResult RaycastResult?
]]
local function _applyGroundMaterial(Stone: Part, RayResult: any)
	if not RayResult then
		return
	end
	
	if RayResult.Instance:IsA("BasePart") then
		Stone.Color = RayResult.Instance.Color
	end
	
	Stone.Material = RayResult.Material
	if Stone.Material == Enum.Material.Plastic then
		Stone.Material = Enum.Material.SmoothPlastic
	end
	
	if RayResult.Instance.MaterialVariant then
		Stone.MaterialVariant = RayResult.Instance.MaterialVariant
	end
	
	Stone.CastShadow = false
end

--[[
	创建石块 Part 基础实例
	@param Size Vector3
	@return Part
]]
local function _createBaseStone(Size: Vector3): Part
	local Stone = Instance.new("Part")
	Stone.Anchored = true
	Stone.CanTouch = false
	Stone.CanQuery = false
	Stone.CanCollide = false
	Stone.Material = Enum.Material.SmoothPlastic
	Stone.Size = Size
	return Stone
end

--[[
	单块石头升起-停留-下沉动画
	@param _SpawnPos Vector3
	@param _Size Vector3
	@param _RiseTime number
	@param _StayTime number
	@param _EasingStyle Enum.EasingStyle
	@param _EasingDir Enum.EasingDirection
]]
local function _stoneRise(
	_SpawnPos: Vector3,
	_Size: Vector3,
	_RiseTime: number,
	_StayTime: number,
	_EasingStyle: Enum.EasingStyle,
	_EasingDir: Enum.EasingDirection,
	_disapearTime: number?,
	_disapearStyle: Enum.EasingStyle?,
	_disapearDir: Enum.EasingDirection?,
	_PoseOffsetRange: CFrame?,
	_PoseOffsetScale: number?,
	_OrientationRange: Vector3?
)
	-- 默认值
	_disapearTime = _disapearTime or 0.1
	_disapearStyle = _disapearStyle or Enum.EasingStyle.Back
	_disapearDir = _disapearDir or Enum.EasingDirection.In
	_PoseOffsetScale = _PoseOffsetScale or 1
	_OrientationRange = _OrientationRange or Vector3.new(15, 360, 20)

	local Stone = _createBaseStone(_Size)

	-- 应用朝向位置偏移随机范围
	if _PoseOffsetRange then
		local posRange = _PoseOffsetRange.Position * _PoseOffsetScale
		_SpawnPos = _SpawnPos + Vector3.new(
			(1 - 2 * math.random()) * posRange.X,
			(1 - 2 * math.random()) * posRange.Y,
			(1 - 2 * math.random()) * posRange.Z
		)
	end

	-- 计算上升位置和旋转（使用可配置的朝向范围）
	local RiseCF = CFrame.new(_SpawnPos + Vector3.new(0, 10, 0)) * CFrame.Angles(
		math.rad(_OrientationRange.X * (1 - 2 * math.random())),
		math.rad(_OrientationRange.Y * math.random()),
		math.rad(_OrientationRange.Z * (1 - 2 * math.random()))
	)

	if _PoseOffsetRange then
		local rx, ry, rz = _PoseOffsetRange:ToEulerAnglesXYZ()
		local randRot = CFrame.Angles(
			(1 - 2 * math.random()) * rx,
			(1 - 2 * math.random()) * ry,
			(1 - 2 * math.random()) * rz
		)
		RiseCF = RiseCF * randRot
	end

	-- 应用地面材质
	local RayResult = RayCast.RayCastDirection(_SpawnPos + Vector3.new(0, 10, 0),Vector3.new(0, -1, 0),100,"Ground")
	if RayResult then
		_applyGroundMaterial(Stone, RayResult)
		RiseCF = RiseCF.Rotation + RayResult.Position
	end
	
	-- 计算生成位置
	local AvgSize = (2.5 + 0.5 * math.random()) * (_Size.X + _Size.Y + _Size.Z) / 3
	local SpawnCF = RiseCF - Vector3.new(0, AvgSize, 0)
	Stone:PivotTo(SpawnCF)
	Stone.Parent = workspace.Debris

	-- 使用 CFrame 而非 Position 进行 tween，以保留 RiseStonePoseOffsetRange 的朝向偏移
	local RiseTargetCF = RiseCF
	local DisapearTargetCF = RiseCF - Vector3.new(0, AvgSize, 0)

	-- 上升动画
	local RiseTween = TweenService:Create(
		Stone,
		TweenInfo.new(_RiseTime, _EasingStyle, _EasingDir),
		{CFrame = RiseTargetCF}
	)

	-- 消失动画
	local DisapearTween = TweenService:Create(
		Stone,
		TweenInfo.new(_disapearTime, _disapearStyle, _disapearDir),
		{CFrame = DisapearTargetCF}
	)
	
	DisapearTween.Completed:Once(function()
		Debris:AddItem(Stone, 0)
	end)
	
	RiseTween.Completed:Once(function()
		task.delay(_StayTime, function()
			DisapearTween:Play()
		end)
	end)
	
	RiseTween:Play()
end

--[[
	对 Model/Part 施加击退线速度
	@param _Model Model | BasePart
	@param _ForceDir Vector3
	@param _ForceTime Vector3
	@param _ForceAccelera number
]]
local function _kickModelBack(_Model:Model, _ForceDir:Vector3, _ForceTime:Vector3, _ForceAccelera:number, _AttachmentOffset,_IsRot)
	if not _Model then
		return
	end

	local Primary:BasePart = nil
	if _Model:IsA("Model") then
		Primary = _Model.PrimaryPart
	end

	if _Model:IsA("BasePart") then
		Primary = _Model
	end

	if not Primary then
		return
	end

	local connectVt = _Model:GetDescendants()
	table.insert(connectVt, Primary)
	local _ObjectMass = 0
	for k,v in pairs(connectVt) do
		if v:IsA("BasePart") then

			_ObjectMass += v:GetMass()

		end

	end

	_ObjectMass = Primary.AssemblyMass

	--ForceModule.ApplyForce(Primary, _ObjectMass, _ForceDir, _ForceTime, _ForceAccelera, _AttachmentOffset)

	local vec = 4.8 * _ForceDir * _ForceTime * _ForceAccelera
	
	Primary.AssemblyLinearVelocity = Primary.AssemblyLinearVelocity + vec
	Primary.AssemblyAngularVelocity = Primary.AssemblyAngularVelocity + Vector3.new(360, 0, 360) * math.random() * 0.15

end

--[[
	飞石物理：生成后延迟解除 Anchored 并施加力
	@param _SpawnPos Vector3
	@param _Size Vector3
	@param _StayTime number
	@param _Force number
]]
local function _stoneFly(_SpawnPos: Vector3, _Size: Vector3, _StayTime: number, _Force: number)
	local Stone = _createBaseStone(_Size)
	
	-- 应用地面材质
	local RayResult = RayCast.RayCastDirection(_SpawnPos + Vector3.new(0, 10, 0),Vector3.new(0, -1, 0),100,"Ground")
	if RayResult then
		_applyGroundMaterial(Stone, RayResult)
	end

	Stone.Parent = workspace.Debris
	Stone:PivotTo(CFrame.new(_SpawnPos) * CFrame.Angles(
		math.rad(360) * math.random(),
		0,
		math.rad(360) * math.random()
	))
	
	Stone.Anchored = false
	local dir = Vector3.new(1 - 2 * math.random(), 4, 1 - 2 * math.random()).Unit
	_kickModelBack(Stone, dir, 0.1, _Force, Vector3.new(1 - 2 * math.random(), 1 - 2 * math.random(), 0),true)
	
	task.delay(_StayTime, function()
		Debris:AddItem(Stone, 0)
	end)
end

-- ============================================================================
-- 公共 API
-- ============================================================================

-- ============================================================================
-- 公共API
-- ============================================================================

--[[
	创建冲击波效果
	@param _SpawnCF: CFrame - 初始位置
	@param _ShockLenth: number - 冲击波长度
	@param _SideOffset: number - 向两侧的位置偏移量
	@param _AngleOffset: number - 向两边的角度偏移量
	@param _StoneNum: number - 石头数量
	@param _WholeRiseTime: number - 生成时间
	@param _RiseTime: number? - 石头上升时间，默认 0.3
	@param _StayTime: number? - 石头停留时间，默认 2
	@param _DisapearTime: number? - 石头消失时间，默认 0.1
]]
function module.CreateShock(
	_SpawnCF: CFrame,
	_ShockLenth: number,
	_SideOffset: number,
	_AngleOffset: number,
	_StoneNum: number,
	_WholeRiseTime: number,
	_RiseTime: number?,
	_StayTime: number?,
	_DisapearTime: number?
)
	_RiseTime = _RiseTime or 0.3
	_StayTime = _StayTime or 2
	_DisapearTime = _DisapearTime or 0.1
	local event = nil
	local time = 0
	local overTime = 0
	local stoneIndex = 0
	local SizeMax = Vector3.new(7, 7, 7)
	local SizeMin = Vector3.new(0.7, 0.7, 0.7)
	
	event = RunService.RenderStepped:Connect(function(dt)
		local timeValue = math.clamp(time / _WholeRiseTime, 0, 1)
		local RiseCurveValue = TweenService:GetValue(timeValue, Enum.EasingStyle.Circular, Enum.EasingDirection.Out)

		if time >= _WholeRiseTime and overTime > 0 then
			event:Disconnect()
			event = nil
			return
		end

		if time >= _WholeRiseTime then
			overTime += 1
		end

		while RiseCurveValue >= stoneIndex / _StoneNum do
			stoneIndex += 1

			local SizeCurveValue = TweenService:GetValue(
				math.clamp(stoneIndex / _StoneNum, 0, 1),
				Enum.EasingStyle.Linear,
				Enum.EasingDirection.In
			)

			local leftCF = _SpawnCF:ToWorldSpace(CFrame.new(_SideOffset, 0, 0)) *
				CFrame.Angles(0, math.rad(_AngleOffset), 0):ToWorldSpace(
					CFrame.new(0, 0, -_ShockLenth * stoneIndex / _StoneNum)
				)
			local rightCF = _SpawnCF:ToWorldSpace(CFrame.new(-_SideOffset, 0, 0)) *
				CFrame.Angles(0, math.rad(-_AngleOffset), 0):ToWorldSpace(
					CFrame.new(0, 0, -_ShockLenth * stoneIndex / _StoneNum)
				)

			local sizeNow = SizeMin + (SizeMax - SizeMin) * SizeCurveValue
			local centerPos = (leftCF.Position + rightCF.Position) / 2
			local randomOffset = Vector3.new(1 - 2 * math.random(), 1 - 2 * math.random(), 1 - 2 * math.random())

			_stoneFly(centerPos + randomOffset, Vector3.new(2, 2, 2), 3, 160 + 100 * math.random())
			_stoneFly(centerPos + randomOffset, Vector3.new(2, 2, 2), 3, 160 + 100 * math.random())
			_stoneRise(leftCF.Position, sizeNow, _RiseTime, _StayTime, Enum.EasingStyle.Quart, Enum.EasingDirection.Out, _DisapearTime)
			_stoneRise(rightCF.Position, sizeNow, _RiseTime, _StayTime, Enum.EasingStyle.Quart, Enum.EasingDirection.Out, _DisapearTime)

			if stoneIndex == _StoneNum then
				for k = 1, 12 do
					_stoneFly(
						centerPos + randomOffset,
						Vector3.new(3, 3, 3) + Vector3.new(1, 1, 1) * math.random(),
						3,
						250 + 100 * math.random()
					)
				end
			end
		end

		time += dt
	end)
end

--[[
	创建单侧冲击波效果
	@param _SpawnCF: CFrame - 初始位置
	@param _ShockType: string - 冲击波类型
	@param _Scale: number? - 整体尺寸缩放，默认 1
]]
function module.CreateShockOneSide(_SpawnCF: CFrame, _ShockType: string, _Scale: number?)
	_Scale = _Scale or 1

	local event = nil
	local time = 0
	local overTime = 0
	local stoneIndex = 0

	local ShockInfo = BurstStoneConfig.OneSideShockWaveInfo[_ShockType]
	if not ShockInfo then
		return
	end

	local offset = ShockInfo["RiseStoneSpawnCFrameOffset"]
	local scaledOffset = CFrame.new(offset.Position * _Scale) * offset.Rotation
	_SpawnCF = _SpawnCF:ToWorldSpace(scaledOffset)

		local SizeMax = ShockInfo["MaxSize"]
		local SizeMin = ShockInfo["MinSize"]

	-- 预计算尺寸权重总和，使间隔与石块大小匹配（越大间隔越大）
	local minAvg = (SizeMin.X + SizeMin.Y + SizeMin.Z) / 3
	local maxAvg = (SizeMax.X + SizeMax.Y + SizeMax.Z) / 3
	local stoneNum = ShockInfo["StoneNum"]
	local totalSizeWeight = stoneNum * minAvg + (maxAvg - minAvg) * (stoneNum + 1) / 2

	event = RunService.RenderStepped:Connect(function(dt)
		local timeValue = math.clamp(time / ShockInfo["WholeTime"], 0, 1)
		local RiseCurveValue = TweenService:GetValue(timeValue, Enum.EasingStyle.Circular, Enum.EasingDirection.Out)

		if time >= ShockInfo["WholeTime"] and overTime > 0 then
			event:Disconnect()
			event = nil
			return
		end

		if time >= ShockInfo["WholeTime"] then
			overTime += 1
		end

		while RiseCurveValue >= stoneIndex / stoneNum do
			stoneIndex += 1

			local SizeCurveValue = TweenService:GetValue(
				math.clamp(stoneIndex / stoneNum, 0, 1),
				Enum.EasingStyle.Linear,
				Enum.EasingDirection.In
			)

			-- 根据石块尺寸累积权重计算位置，使大石块间隔更大（缩放不影响冲击波长度）
			local cumulativeSizeWeight = stoneIndex * minAvg + (maxAvg - minAvg) * stoneIndex * (stoneIndex + 1) / (2 * stoneNum)
			local distanceRatio = cumulativeSizeWeight / totalSizeWeight
			local SpawnCF = _SpawnCF:ToWorldSpace(
				CFrame.new(0, 0, -ShockInfo["ShockLenth"] * distanceRatio)
			)

			local baseSize = (SizeMin + (SizeMax - SizeMin) * SizeCurveValue) * _Scale
			local randomRange = ShockInfo["RiseStoneSizeRandomRange"] or Vector3.new(0, 0, 0)
			local sizeRandom = Vector3.new(
				(1 - 2 * math.random()) * randomRange.X,
				(1 - 2 * math.random()) * randomRange.Y,
				(1 - 2 * math.random()) * randomRange.Z
			) * _Scale
			local sizeNow = baseSize + sizeRandom
			local flyStoneSize = (ShockInfo["FlyMinSize"] +
				(ShockInfo["FlyMaxSize"] - ShockInfo["FlyMinSize"]) * math.random()) * _Scale

			local flyProb = ShockInfo["FlyStoneProbability"]
			if flyProb == nil or flyProb >= 1 or math.random() < flyProb then
				_stoneFly(
					SpawnCF.Position + Vector3.new(1 - 2 * math.random(), 1 - 2 * math.random(), 1 - 2 * math.random()) * _Scale,
					flyStoneSize,
					ShockInfo["FlyStoneLifeTime"],
					(ShockInfo["FlyStoneForce"] + ShockInfo["FlyStoneForceRandomRange"] * math.random()) * _Scale
				)
			end

			local spawnPos = SpawnCF.Position
			local poseOffsetRange = ShockInfo["RiseStonePoseOffsetRange"]
			if poseOffsetRange then
				local posRange = poseOffsetRange.Position * _Scale
				spawnPos = spawnPos + SpawnCF:VectorToWorldSpace(Vector3.new(
					(1 - 2 * math.random()) * posRange.X,
					(1 - 2 * math.random()) * posRange.Y,
					(1 - 2 * math.random()) * posRange.Z
				))
			end

			-- 仅传递旋转范围给 StoneRise（位置偏移已在 spawnPos 中应用）
			local rotOffsetRange = poseOffsetRange and (CFrame.new(0, 0, 0) * poseOffsetRange.Rotation) or nil
			_stoneRise(
				spawnPos,
				sizeNow,
				ShockInfo["RiseTime"],
				ShockInfo["RiseStoneLifeTime"],
				Enum.EasingStyle.Quart,
				Enum.EasingDirection.Out,
				ShockInfo["RiseStoneDisapearTime"],
				ShockInfo["RiseStoneDisapearStyle"],
				ShockInfo["RiseStoneDisapearDir"],
				rotOffsetRange,
				1,
				ShockInfo["RiseStoneOrientationRange"]
			)
		end

		time += dt
	end)
end

--[[
	创建石头飞行效果
	@param _SpawnCF CFrame - 初始位置
	@param _StoneFlyType string? - 石头飞行类型（见 BurstStoneConfig.stoneFlyInfo）
	@param _Scale number? - 整体尺寸缩放，默认 1
]]
function module.CreateStoneFly(_SpawnCF: CFrame, _StoneFlyType: string?, _Scale: number?)
	if not _StoneFlyType then
		_StoneFlyType = "Temp"
	end
	_Scale = _Scale or 1

	local lenth = #BurstStoneConfig.stoneFlyInfo[_StoneFlyType]
	if lenth == 0 then
		return
	end

	task.spawn(function()
		for i = 1, lenth do
			local StoneInfo = BurstStoneConfig.stoneFlyInfo[_StoneFlyType][i]
			
			for k = 1, StoneInfo["StoneNum"] do
				-- 计算随机尺寸（应用缩放）
				local randomSize = Vector3.new(
					StoneInfo["MinSize"].X + math.random() * (StoneInfo["MaxSize"].X - StoneInfo["MinSize"].X),
					StoneInfo["MinSize"].Y + math.random() * (StoneInfo["MaxSize"].Y - StoneInfo["MinSize"].Y),
					StoneInfo["MinSize"].Z + math.random() * (StoneInfo["MaxSize"].Z - StoneInfo["MinSize"].Z)
				)
				local stoneSize = (StoneInfo["MinSize"] + randomSize) * _Scale
				local Stone = _createBaseStone(stoneSize)
				Stone.Parent = workspace.Debris

				if StoneInfo["CanCollide"] then
					Stone.CanCollide = true
					Stone.CollisionGroup = "Player"
				end

				local spawnOffset = Vector3.new(
					StoneInfo["SpawnOffset"].X * (1 - 2 * math.random()),
					StoneInfo["SpawnOffset"].Y * (1 - 2 * math.random()),
					StoneInfo["SpawnOffset"].Z * (1 - 2 * math.random())
				) * _Scale
				local goal = CFrame.new(_SpawnCF.Position):ToWorldSpace(CFrame.new(spawnOffset))

				-- 应用初始朝向范围偏移
				local orientRange = StoneInfo["OrientationOffsetRange"]
				if orientRange then
					local rx, ry, rz = orientRange:ToEulerAnglesXYZ()
					local randRot = CFrame.Angles(
						(1 - 2 * math.random()) * rx,
						(1 - 2 * math.random()) * ry,
						(1 - 2 * math.random()) * rz
					)
					goal = goal * randRot
				end

				local RayResult = RayCast.RayCastDirection(goal.Position + Vector3.new(0, 3, 0),Vector3.new(0, -1, 0),100,"Ground")
				if RayResult then
					_applyGroundMaterial(Stone, RayResult)
				end

				Stone:PivotTo(goal)

				local dir: Vector3
				local dirOffset = StoneInfo["DirectionOffset"]
				if dirOffset then
					local randOffset = Vector3.new(
						(1 - 2 * math.random()) * dirOffset.X,
						(1 - 2 * math.random()) * dirOffset.Y,
						(1 - 2 * math.random()) * dirOffset.Z
					)
					local dirVec = Vector3.new(0, 1, 0) + randOffset
					dir = dirVec.Magnitude > 0.001 and dirVec.Unit or Vector3.new(0, 1, 0)
				else
					dir = ((goal.Position - _SpawnCF.Position).Unit + Vector3.new(0, 10, 0)).Unit
				end
				local force = (StoneInfo["Force"] + (1 - 2 * math.random()) * StoneInfo["ForceOffset"]) * _Scale

				Stone.Anchored = false
				_kickModelBack(Stone, dir, 0.1, force, Vector3.new((1 - 2 * math.random()), (1 - 2 * math.random()), 0) * _Scale)
				
				task.delay(StoneInfo["StayTime"], function()
					local FadeTween = TweenService:Create(Stone, TweenInfo.new(0.1), {Transparency = 1})
					FadeTween.Completed:Once(function()
						Debris:AddItem(Stone, 0)
					end)
					FadeTween:Play()
				end)
			end
		end
	end)
end

--[[
	创建地裂效果
	@param _SpawnCF: CFrame - 初始位置
	@param _LandBreakType: string? - 地裂类型
	@param _Scale: number? - 整体尺寸缩放，默认 1
]]
function module.CreateLandBreak(_SpawnCF: CFrame, _LandBreakType: string?, _Scale: number?)
	if not _SpawnCF then
		return
	end
	
	if not _LandBreakType then
		_LandBreakType = "Temp"
	end
	_Scale = _Scale or 1

	local lenth = #BurstStoneConfig.landBreakInfo[_LandBreakType]
	if lenth == 0 then
		return
	end

	for i = 1, lenth do
		local StoneInf = BurstStoneConfig.landBreakInfo[_LandBreakType][i]
		
		task.delay(StoneInf["Delay"], function()
			for k = 1, StoneInf["StoneNum"] do
				-- 计算随机尺寸（应用缩放）
				local randomSize = Vector3.new(
					StoneInf["MinSize"].X + math.random() * (StoneInf["MaxSize"].X - StoneInf["MinSize"].X),
					StoneInf["MinSize"].Y + math.random() * (StoneInf["MaxSize"].Y - StoneInf["MinSize"].Y),
					StoneInf["MinSize"].Z + math.random() * (StoneInf["MaxSize"].Z - StoneInf["MinSize"].Z)
				)
				local stoneSize = (StoneInf["MinSize"] + randomSize) * _Scale
				local Stone = _createBaseStone(stoneSize)
				Stone.Parent = workspace

				local angle = 360 / StoneInf["StoneNum"]
				local randomAngleOffset = Vector3.new(
					(1 - 2 * math.random()) * StoneInf["AngleRandomOffset"].X,
					(1 - 2 * math.random()) * StoneInf["AngleRandomOffset"].Y,
					(1 - 2 * math.random()) * StoneInf["AngleRandomOffset"].Z
				)
				local randomPositionOffset = Vector3.new(
					(1 - 2 * math.random()) * StoneInf["PositionRamdomOffset"].X,
					(1 - 2 * math.random()) * StoneInf["PositionRamdomOffset"].Y,
					(1 - 2 * math.random()) * StoneInf["PositionRamdomOffset"].Z
				)
				local scaledPositionOffset = (StoneInf["PositionOffset"] + randomPositionOffset) * _Scale
				
				local goal = (CFrame.new(_SpawnCF.Position) * CFrame.Angles(0, math.rad(StoneInf["OriAngle"] + angle * k), 0)):ToWorldSpace(
					CFrame.new(scaledPositionOffset) *
					CFrame.Angles(
						StoneInf["AngleOffset"].X + randomAngleOffset.X,
						StoneInf["AngleOffset"].Y + randomAngleOffset.Y,
						StoneInf["AngleOffset"].Z + randomAngleOffset.Z
					)
				)

				local SpawnCFrameOffset = CFrame.new(
					(1 - 2 * math.random()) * _Scale,
					-4 * _Scale,
					(1 - 2 * math.random()) * _Scale
				) * CFrame.Angles(
					math.rad((1 - 2 * math.random()) * 45),
					math.rad((1 - 2 * math.random()) * 45),
					math.rad((1 - 2 * math.random()) * 45)
				)
				Stone:PivotTo(goal:ToWorldSpace(SpawnCFrameOffset))

				local RayResult = RayCast.RayCastDirection(goal.Position + Vector3.new(0, 10, 0),Vector3.new(0, -1, 0),100,"Ground")
				if RayResult then
					_applyGroundMaterial(Stone, RayResult)
				end

				local SpawnTween = TweenService:Create(
					Stone,
					TweenInfo.new(0.1, Enum.EasingStyle.Circular, Enum.EasingDirection.Out),
					{CFrame = goal}
				)
				SpawnTween:Play()

				task.delay(StoneInf["LifeTime"], function()
					local StoneSize = Stone.Size
					local Disapear = TweenService:Create(
						Stone,
						TweenInfo.new(0.5, Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
						{CFrame = goal + Vector3.new(0, -math.max(StoneSize.X, StoneSize.Y, StoneSize.Z), 0), Transparency = 1}
					)
					
					if StoneInf["ScaleOutTime"] then
						local ScaleOut = TweenService:Create(
							Stone,
							TweenInfo.new(StoneInf["ScaleOutTime"]),
							{Size = Vector3.new(0.1, 0.1, 0.1) * _Scale}
						)
						ScaleOut:Play()
					end
					
					Disapear.Completed:Connect(function()
						Debris:AddItem(Stone, 0)
					end)

					Disapear:Play()
				end)
			end
		end)
	end
end

-- 兼容旧名（历史 Create_stoneFly）
module.Create_stoneFly = module.CreateStoneFly

return module