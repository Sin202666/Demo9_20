--[[
	Module: FXUtil/BezierAnimBasic
	Description: 贝塞尔曲线基础动画（线性/二次/三次）
	Author: LinAoyu
	Created: 2024-01-01
	Last Modified: 2026-07-02
]]

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local BezierUtil = require(script.Parent.BezierUtil)

local BezierAnimBasic = {}

--[[
	线性贝塞尔曲线动画（两点直线运动）
	
	@param Frame number - 总帧数
	@param FPS number - 帧率
	@param Target BasePart|Instance - 目标对象（需要有Position属性）
	@param Position1 Vector3|BasePart|Instance - 起始位置
	@param Position2 Vector3|BasePart|Instance - 结束位置
--]]
function BezierAnimBasic.LinearBezierCurves(Frame, FPS, Target, Position1, Position2)
	if typeof(Position1) ~= "Vector3" then
		Position1 = Position1.Position
	end

	if typeof(Position2) ~= "Vector3" then
		Position2 = Position2.Position
	end

	local index = 0  -- 帧次序
	local dTime = 1 / FPS  -- FPS帧率下每帧时间
	local totalTime = 0  -- 累计时间
	local event = nil

	event = RunService.Heartbeat:Connect(function(dt)
		totalTime += dt

		if totalTime < index * dTime then
			return
		end

		if totalTime >= index * dTime then
			index += 1
			local time = index / Frame
			local lerpPosition = BezierUtil.Lerp(Position1, Position2, time)
			Target.Position = lerpPosition
		end

		if index >= Frame then
			event:Disconnect()
			event = nil
		end
	end)
end

--[[
	二次贝塞尔曲线动画（三点曲线运动）
	
	@param Frame number - 总帧数
	@param FPS number - 帧率
	@param Target Model - 目标模型
	@param Position1 Vector3|BasePart|Instance - 起始位置
	@param Position2 Vector3|BasePart|Instance - 控制点位置
	@param Position3 Vector3|BasePart|Instance - 结束位置
	@param callback function? - 完成回调函数（可选）
--]]
function BezierAnimBasic.QuadraticBezierCurves(Frame, FPS, Target: Model, Position1, Position2, Position3, callback)
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
			index = totalTime / dTime
			local time = index / Frame

			local lerp1 = BezierUtil.Lerp(Position1, Position2, time)
			local lerp2 = BezierUtil.Lerp(Position2, Position3, time)
			local finalPosition = BezierUtil.Lerp(lerp1, lerp2, time)

			Target:PivotTo(Target:GetPivot().Rotation + finalPosition)
		end

		if index >= Frame then
			event:Disconnect()
			event = nil
			if callback then
				callback()
			end
		end
	end)
	
	return event
end

--[[
	三次贝塞尔曲线动画（四点曲线运动）
	
	@param Frame number - 总帧数
	@param FPS number - 帧率
	@param Target BasePart|Instance - 目标对象（需要有Position属性）
	@param Position1 Vector3|BasePart|Instance - 起始位置
	@param Position2 Vector3|BasePart|Instance - 第一个控制点
	@param Position3 Vector3|BasePart|Instance - 第二个控制点
	@param Position4 Vector3|BasePart|Instance - 结束位置
--]]
function BezierAnimBasic.CubicBezierCurves(Frame, FPS, Target, Position1: Vector3, Position2, Position3, Position4)
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
			local lerp3 = BezierUtil.Lerp(Position3, Position4, time)

			local inLerp1 = BezierUtil.Lerp(lerp1, lerp2, time)
			local inLerp2 = BezierUtil.Lerp(lerp2, lerp3, time)

			Target.Position = BezierUtil.Lerp(inLerp1, inLerp2, time)
		end

		if index >= Frame then
			event:Disconnect()
			event = nil
		end
	end)
end

return BezierAnimBasic