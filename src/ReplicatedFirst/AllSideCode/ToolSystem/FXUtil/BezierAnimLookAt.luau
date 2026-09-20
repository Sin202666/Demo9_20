--[[
	Module: FXUtil/BezierAnimLookAt
	Description: 贝塞尔曲线 LookAt/缩放/旋转/跟随/相机朝向动画
	Author: LinAoyu
	Created: 2024-01-01
	Last Modified: 2026-07-02
]]

local Debris = game:GetService("Debris")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Random = Random

local BezierUtil = require(script.Parent.BezierUtil)

local BezierAnimLookAt = {}

-- ============================================
-- 带朝向的贝塞尔曲线动画 (Bezier Curves with LookAt)
-- ============================================

--[[
	线性贝塞尔曲线动画（带朝向控制）
	
	@param Frame number - 总帧数
	@param FPS number - 帧率
	@param Target BasePart - 目标对象
	@param Position1 Vector3|BasePart|Instance - 起始位置
	@param Position2 Vector3|BasePart|Instance - 结束位置
	@param CFrameOffset CFrame - CFrame偏移量
--]]
function BezierAnimLookAt.LinearBezierCurvesLookAt(Frame, FPS, Target, Position1, Position2, CFrameOffset)
	local vecValue = Instance.new("Vector3Value")
	vecValue.Parent = Target
	vecValue.Value = Vector3.new(0, 0, 0)

	if typeof(Position1) ~= "Vector3" then
		Position1 = Position1.Position
	end

	if typeof(Position2) ~= "Vector3" then
		Position2 = Position2.Position
	end

	local index = 0
	local dTime = 1 / FPS
	local totalTime = 0
	local event = nil

	event = RunService.Heartbeat:Connect(function(dt)
		totalTime += dt

		if totalTime < index * dTime then
			return
		end

		if totalTime >= index * dTime then
			index += 1
			local time = index / Frame

			vecValue.Value = BezierUtil.Lerp(Position1, Position2, time)

			Target.CFrame = CFrame.lookAt(Target.Position, vecValue.Value, Vector3.new(0, 1, 0)) * CFrameOffset
			Target.Position = vecValue.Value
		end

		if index >= Frame then
			event:Disconnect()
			event = nil
			Debris:AddItem(vecValue, task.wait())
		end
	end)
end

--[[
	二次贝塞尔曲线动画（带朝向控制和缓动效果）
	
	@param Frame number - 总帧数
	@param FPS number - 帧率
	@param Target BasePart - 目标对象
	@param Position1 Vector3|BasePart|Instance - 起始位置
	@param Position2 Vector3|BasePart|Instance - 控制点位置
	@param Position3 Vector3|BasePart|Instance - 结束位置
	@param CFrameOffset CFrame - CFrame偏移量
	@param callback function? - 完成回调函数（可选）
	@param easingStyle Enum.EasingStyle? - 缓动样式（可选，默认Linear）
	@param easingDir Enum.EasingDirection? - 缓动方向（可选，默认In）
--]]
function BezierAnimLookAt.QuadraticBezierCurvesLookAt(Frame, FPS, Target: BasePart, Position1, Position2, Position3, CFrameOffset, callback, easingStyle, easingDir)
	local vecValue = Instance.new("Vector3Value")
	vecValue.Parent = Target
	vecValue.Value = Vector3.new(0, 0, 0)

	if typeof(Position1) ~= "Vector3" then
		Position1 = Position1.Position
	end

	if typeof(Position2) ~= "Vector3" then
		Position2 = Position2.Position
	end

	if typeof(Position3) ~= "Vector3" then
		Position3 = Position3.Position
	end

	easingStyle = easingStyle or Enum.EasingStyle.Linear
	easingDir = easingDir or Enum.EasingDirection.In

	local index = 0
	local dTime = 1 / FPS
	local totalTime = 0
	local event = nil

	event = RunService.Heartbeat:Connect(function(dt)
		totalTime += dt

		if totalTime < index * dTime then
			return
		end

		if totalTime >= index * dTime then
			index += 1
			local nowTime = index / Frame
			local time = TweenService:GetValue(nowTime, easingStyle, easingDir)

			local lerp1 = BezierUtil.Lerp(Position1, Position2, time)
			local lerp2 = BezierUtil.Lerp(Position2, Position3, time)
			vecValue.Value = BezierUtil.Lerp(lerp1, lerp2, time)

			Target.CFrame = CFrame.lookAt(Target.CFrame.Position, vecValue.Value, Target.CFrame.UpVector) * CFrameOffset
			Target.CFrame = Target.CFrame.Rotation + vecValue.Value
		end

		if index > Frame then
			if callback then
				callback()
			end

			event:Disconnect()
			event = nil
			Debris:AddItem(vecValue, task.wait())
		end
	end)
end

--[[
	整体缩放函数（内部辅助函数）
	
	@param changePart BasePart - 需要改变大小的部件
	@param reference BasePart - 参考部件
	@param beishu number - 缩放倍数
	@param start Vector3 - 起始位置
	@param goal Vector3 - 目标位置
--]]
local function _entiretyScale(changePart: BasePart, reference: BasePart, beishu: number, start: Vector3, goal: Vector3)
	-- 计算缩放程度
	local scaleValue = (1 - (goal - reference.Position).Magnitude / (goal - start).Magnitude) * beishu

	-- 进行大小调整
	local oriSize = changePart:FindFirstChild("OriSize")
	if not oriSize then
		oriSize = Instance.new("Vector3Value", changePart)
		oriSize.Name = "OriSize"
		oriSize.Value = changePart.Size
	end
	changePart.Size = oriSize.Value * scaleValue
end

--[[
	二次贝塞尔曲线动画（带缩放变化和朝向控制）
	
	@param Frame number - 总帧数
	@param FPS number - 帧率
	@param Target BasePart - 目标对象
	@param Position1 Vector3|BasePart|Instance - 起始位置
	@param Position2 Vector3|BasePart|Instance - 控制点位置
	@param Position3 Vector3|BasePart|Instance - 结束位置
	@param CFrameOffset CFrame - CFrame偏移量
	@param callback function? - 完成回调函数（可选）
	@param beishu number? - 缩放倍数（可选）
--]]
function BezierAnimLookAt.QuadraticBezierCurvesScaleChangeLookAt(Frame, FPS, Target: BasePart, Position1, Position2, Position3, CFrameOffset, callback, beishu)
	local vecValue = Instance.new("Vector3Value")
	vecValue.Parent = Target
	vecValue.Value = Vector3.new(0, 0, 0)

	if typeof(Position1) ~= "Vector3" then
		Position1 = Position1.Position
	end

	if typeof(Position2) ~= "Vector3" then
		Position2 = Position2.Position
	end

	if typeof(Position3) ~= "Vector3" then
		Position3 = Position3.Position
	end

	local index = 0
	local dTime = 1 / FPS
	local totalTime = 0
	local event = nil

	event = RunService.Heartbeat:Connect(function(dt)
		totalTime += dt

		if totalTime < index * dTime then
			return
		end

		if totalTime >= index * dTime then
			index += 1
			local time = index / Frame

			local lerp1 = BezierUtil.Lerp(Position1, Position2, time)
			local lerp2 = BezierUtil.Lerp(Position2, Position3, time)
			vecValue.Value = BezierUtil.Lerp(lerp1, lerp2, time)

			-- 调整缩放（遍历子对象，对带有Scale属性的BasePart进行缩放）
			for _, descendant in pairs(Target:GetDescendants()) do
				if descendant:IsA("BasePart") then
					local scaleAttr = descendant:GetAttribute("Scale")
					if scaleAttr then
						_entiretyScale(descendant, Target, scaleAttr, Position1, Position3)
					end
				end
			end

			-- 变换位置
			Target.CFrame = CFrame.lookAt(Target.CFrame.Position, vecValue.Value, Target.CFrame.UpVector) * CFrameOffset
			Target.CFrame = Target.CFrame.Rotation + vecValue.Value
		end

		if index > Frame then
			if callback then
				callback()
			end

			event:Disconnect()
			event = nil
			Debris:AddItem(vecValue, task.wait())
		end
	end)
end

--[[
	二次贝塞尔曲线动画（前置朝向控制，使用PivotTo）
	
	@param Frame number - 总帧数
	@param FPS number - 帧率
	@param Target BasePart - 目标对象
	@param Position1 Vector3|BasePart|Instance - 起始位置
	@param Position2 Vector3|BasePart|Instance - 控制点位置
	@param Position3 Vector3|BasePart|Instance - 结束位置
	@param CFrameOffset CFrame - CFrame偏移量
	@param callback function? - 完成回调函数（可选）
--]]
function BezierAnimLookAt.QuadraticBezierCurvesFrontLookAt(Frame, FPS, Target: BasePart, Position1, Position2, Position3, CFrameOffset, callback)

	local VecValue = Instance.new("Vector3Value")
	VecValue.Parent = Target
	VecValue.Value = Vector3.new(0,0,0)

	if typeof(Position1) ~= "Vector3" then
		Position1 = Position1.Position
	end

	if typeof(Position2) ~= "Vector3" then
		Position2 = Position2.Position
	end

	if typeof(Position3) ~= "Vector3" then
		Position3 = Position3.Position
	end

	local Index = 0	--帧次序
	local dTime = 1/FPS  --FPS帧率下 每帧时间
	local ttTime = 0  --累计时间
	local event = nil
	event = RunService.Heartbeat:Connect(function(dt)
		ttTime+=dt

		if ttTime < Index*dTime then
			return
		end

		if ttTime >= Index*dTime then

			Index += 1

			local Time = Index / Frame

			local Lerp1 = BezierUtil.Lerp(Position1 , Position2 , Time)
			local Lerp2 = BezierUtil.Lerp(Position2 , Position3 , Time)

			VecValue.Value = BezierUtil.Lerp(Lerp1 , Lerp2 , Time)

			Target:PivotTo(CFrame.lookAt(Target:GetPivot().Position , VecValue.Value , Vector3.new(0,1,0)) * CFrameOffset) 
			Target:PivotTo(Target:GetPivot().Rotation + VecValue.Value)

		end	

		if Index > Frame then

			if callback then
				callback()
			end

			event:Disconnect()
			event = nil
			Debris:AddItem(VecValue, task.wait())

		end
	end)
end

--[[
	二次贝塞尔曲线动画（带旋转效果）
	
	@param Frame number - 总帧数
	@param FPS number - 帧率
	@param Target Model|BasePart - 目标对象
	@param Position1 Vector3|BasePart|Instance - 起始位置
	@param Position2 Vector3|BasePart|Instance - 控制点位置
	@param Position3 Vector3|BasePart|Instance - 结束位置
	@param CFrameOffset CFrame - CFrame偏移量
	@param callback function? - 完成回调函数（可选）
	@param rotateSpeed number? - 旋转速度（度/秒，可选，默认3600）
--]]
function BezierAnimLookAt.QuadraticBezierCurvesRotate(Frame, FPS, Target, Position1, Position2, Position3, CFrameOffset, callback, rotateSpeed)
	local vecValue = Instance.new("Vector3Value")
	vecValue.Parent = Target
	vecValue.Value = Vector3.new(0, 0, 0)

	if typeof(Position1) ~= "Vector3" then
		Position1 = Position1.Position
	end

	if typeof(Position2) ~= "Vector3" then
		Position2 = Position2.Position
	end

	if typeof(Position3) ~= "Vector3" then
		Position3 = Position3.Position
	end

	rotateSpeed = rotateSpeed or 3600

	local index = 0
	local dTime = 1 / FPS
	local totalTime = 0
	local event = nil

	event = RunService.Heartbeat:Connect(function(dt)
		totalTime += dt

		if totalTime < index * dTime then
			return
		end

		if totalTime >= index * dTime then
			index += 1
			local time = index / Frame

			local lerp1 = BezierUtil.Lerp(Position1, Position2, time)
			local lerp2 = BezierUtil.Lerp(Position2, Position3, time)
			vecValue.Value = BezierUtil.Lerp(lerp1, lerp2, time)

			-- 根据目标类型应用旋转
			if Target:IsA("Model") then
				Target:PivotTo(Target:GetPivot().Rotation + vecValue.Value)
				Target:PivotTo(Target:GetPivot() * CFrame.Angles(math.rad(rotateSpeed * dt), 0, 0))
			elseif Target:IsA("BasePart") then
				Target.CFrame = Target.CFrame.Rotation + vecValue.Value
				Target.CFrame = Target.CFrame * CFrame.Angles(math.rad(rotateSpeed * dt), 0, 0)
			end
		end

		if index > Frame then
			event:Disconnect()
			event = nil
			Debris:AddItem(vecValue, task.wait())
			if callback then
				callback()
			end
		end
	end)
end

function BezierAnimLookAt.QuadraticBezierCurvesFollow(Frame , FPS , Target , Position1, Position2 , Position3, Position4 , OriPos , RootObject:BasePart)

	local VecValue = Instance.new("Vector3Value")
	VecValue.Parent = Target
	VecValue.Value = Vector3.new(0,0,0)

	if typeof(Position1) ~= "Vector3" then
		Position1 = Position1.Position
	end

	if typeof(Position2) ~= "Vector3" then
		Position2 = Position2.Position
	end

	if typeof(Position3) ~= "Vector3" then
		Position3 = Position3.Position
	end
	
	if typeof(Position4) ~= "Vector3" then
		Position4 = Position4.Position
	end
	

	local Index = 0	--帧次序
	local dTime = 1/FPS  --FPS帧率下 每帧时间
	local ttTime = 0  --累计时间
	local event = nil
	event = RunService.Heartbeat:Connect(function(dt)
		ttTime+=dt
		
		if Index >= Frame or not RootObject then

			event:Disconnect()
			event = nil
			Debris:AddItem(VecValue, task.wait())

		end
		
		if ttTime < Index*dTime then
			return
		end

		if ttTime >= Index*dTime then

			Index += 1

			local Time = Index / Frame

			local Lerp1 = BezierUtil.Lerp(Position1 , Position2 , Time)
			local Lerp2 = BezierUtil.Lerp(Position2 , Position3 , Time)
			local Lerp3 = BezierUtil.Lerp(Position3 , Position4 , Time)
			
			local InLerp1 = BezierUtil.Lerp(Lerp1, Lerp2, Time)
			local InLerp2 = BezierUtil.Lerp(Lerp2, Lerp3, Time)

			VecValue.Value = BezierUtil.Lerp(InLerp1 , InLerp2 , Time)
			
			Target.CFrame = CFrame.lookAt(VecValue.Value + RootObject.Position - OriPos , VecValue.Value , Vector3.new(0,1,0))
			
			
		end	

		
	end)
end

function BezierAnimLookAt.CubicBezierCurvesLookAt(Frame , FPS , Target , Position1 , Position2 , Position3 , Position4 , CFrameOffset)


	local VecValue = Instance.new("Vector3Value")
	VecValue.Parent = Target
	VecValue.Value = Vector3.new(0,0,0)

	if typeof(Position1) ~= "Vector3" then
		Position1 = Position1.Position
	end

	if typeof(Position2) ~= "Vector3" then
		Position2 = Position2.Position
	end

	if typeof(Position3) ~= "Vector3" then
		Position3 = Position3.Position
	end

	if typeof(Position4) ~= "Vector3" then
		Position4 = Position4.Position
	end
	
	
	local Index = 0	--帧次序
	local dTime = 1/FPS  --FPS帧率下 每帧时间
	local ttTime = 0  --累计时间
	local event = nil
	event = RunService.Heartbeat:Connect(function(dt)
		ttTime+=dt

		if ttTime < Index*dTime then
			return
		end

		if ttTime >= Index*dTime then

			Index += 1

			local Time = Index / Frame

			local Lerp1 = BezierUtil.Lerp(Position1 , Position2 , Time)
			local Lerp2 = BezierUtil.Lerp(Position2 , Position3 , Time)
			local Lerp3 = BezierUtil.Lerp(Position3 , Position4 , Time)
			
			local InLerp1 = BezierUtil.Lerp(Lerp1 , Lerp2 , Time)
			local InLerp2 = BezierUtil.Lerp(Lerp2 , Lerp3 , Time)
			
			VecValue.Value = BezierUtil.Lerp(InLerp1 , InLerp2 , Time)

			Target.CFrame = CFrame.lookAt(Target.Position , VecValue.Value , Vector3.new(0,1,0)) * CFrameOffset
			Target.Position = VecValue.Value

		end	

		if Index > Frame then

			event:Disconnect()
			event = nil
			Debris:AddItem(VecValue, task.wait())

		end
	end)
	
	
	--for Index = 0 , Frame , 1 do

	--	local Time = Index / Frame

	--	local Lerp1 = BezierUtil.Lerp(Position1 , Position2 , Time)
	--	local Lerp2 = BezierUtil.Lerp(Position2 , Position3 , Time)
	--	local Lerp3 = BezierUtil.Lerp(Position3 , Position4 , Time)

	--	local InLerp1 = BezierUtil.Lerp(Lerp1 , Lerp2 , Time)
	--	local InLerp2 = BezierUtil.Lerp(Lerp2 , Lerp3 , Time)

	--	CFramePart.Position = BezierUtil.Lerp(InLerp1 , InLerp2 , Time)

	--	if Index == 0 then
	--		continue
	--	else

	--		Target.CFrame = CFrame.lookAt(Target.Position , CFramePart.Position , Vector3.new(0,1,0)) * CFrameOffset
	--		Target.Position = CFramePart.Position

	--	end

	--	task.wait(1 / FPS)

	--end

	--Debris:AddItem(CFramePart , task.wait())

end

function BezierAnimLookAt.QuadraticBezierCurvesCameraLookAt(Frame , FPS , Target:BasePart , Position1, Position2 , Position3  , CFrameOffset, LookAtTarget:BasePart,callback)

	local VecValue = Instance.new("Vector3Value")
	VecValue.Parent = Target
	VecValue.Value = Vector3.new(0,0,0)

	if typeof(Position1) ~= "Vector3" then
		Position1 = Position1.Position
	end

	if typeof(Position2) ~= "Vector3" then
		Position2 = Position2.Position
	end

	if typeof(Position3) ~= "Vector3" then
		Position3 = Position3.Position
	end

	local Index = 0	--帧次序
	local dTime = 1/FPS  --FPS帧率下 每帧时间
	local ttTime = 0  --累计时间
	local event = nil
	event = RunService.Heartbeat:Connect(function(dt)
		ttTime+=dt

		if ttTime < Index*dTime then
			return
		end

		if ttTime >= Index*dTime and LookAtTarget then

			Index += 1

			local Time = Index / Frame

			local Lerp1 = BezierUtil.Lerp(Position1 , Position2 , Time)
			local Lerp2 = BezierUtil.Lerp(Position2 , Position3 , Time)

			VecValue.Value = BezierUtil.Lerp(Lerp1 , Lerp2 , Time)

			Target.CFrame = CFrame.lookAt(Target.CFrame.Position , LookAtTarget.Position ,Vector3.new(0,1,0)) * CFrameOffset
			Target.CFrame = Target.CFrame.Rotation + VecValue.Value

		end	

		if Index > Frame or not LookAtTarget then

			if callback then
				callback()
			end

			event:Disconnect()
			event = nil
			Debris:AddItem(VecValue, task.wait())

		end
	end)
end

return BezierAnimLookAt