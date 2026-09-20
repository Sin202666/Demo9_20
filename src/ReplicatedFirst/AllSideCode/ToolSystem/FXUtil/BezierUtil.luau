--[[
	Module: FXUtil/BezierUtil
	Description: 贝塞尔曲线工具函数（插值、帧数、中间点计算）
	Author: LinAoyu
	Created: 2024-01-01
	Last Modified: 2026-07-02
]]

local BezierUtil = {}

-- ============================================
-- 工具函数 (Utility Functions)
-- ============================================

--[[
	线性插值函数
	
	@param Start Vector3|BasePart|Instance - 起始位置或包含Position的对象
	@param End Vector3|BasePart|Instance - 结束位置或包含Position的对象
	@param Time number - 插值时间（0-1）
	@return Vector3 - 插值后的位置
--]]
function BezierUtil.Lerp(Start, End, Time)
	if typeof(Start) ~= "Vector3" then
		Start = Start.Position
	end

	if typeof(End) ~= "Vector3" then
		End = End.Position
	end

	return Start + (End - Start) * Time
end

--[[
	根据距离计算帧数
	
	@param Start Vector3|BasePart|Instance - 起始位置
	@param End Vector3|BasePart|Instance - 结束位置
	@param Multiply number? - 倍数系数（可选，默认1）
	@return number - 计算出的帧数
--]]
function BezierUtil.GetFrameByDistance(Start, End, Multiply)
	if typeof(Start) ~= "Vector3" then
		Start = Start.Position
	end

	if typeof(End) ~= "Vector3" then
		End = End.Position
	end

	Multiply = Multiply and (1 + Multiply) or 1

	local distance = (Start - End).Magnitude
	local frame = math.round(distance * 2 / Multiply)

	return frame
end

--[[
	计算运动时间
	
	@param Frame number - 帧数
	@param FPS number - 帧率
	@return number - 总运动时间
--]]
function BezierUtil.GetMotionTime(Frame, FPS)
	local time = 0
	time += task.wait(1 / FPS) * Frame
	return time
end

--[[
	获取中间位置点（用于二次贝塞尔曲线的控制点）
	
	@param StartPosition Vector3|BasePart|Instance - 起始位置
	@param TargetPosition Vector3|BasePart|Instance - 目标位置
	@param Angle number? - 旋转角度（可选，默认0）
	@param Offset number? - 偏移系数（可选，默认1）
	@return Vector3 - 计算出的中间位置
--]]
function BezierUtil.GetMiddlePosition(StartPosition, TargetPosition, Angle, Offset)
	if typeof(StartPosition) ~= "Vector3" then
		StartPosition = StartPosition.Position
	end

	if typeof(TargetPosition) ~= "Vector3" then
		TargetPosition = TargetPosition.Position
	end

	Angle = Angle or 0
	Offset = Offset or 1

	-- 计算起始与目标之间一半长度的向量
	local halfVector = (StartPosition - TargetPosition) * 0.5
	local middlePosition = StartPosition - halfVector
	
	-- 从中间位置点指向目标的向量，用于旋转
	local rotateCFrame = CFrame.new(middlePosition, TargetPosition)
	
	-- 根据角度旋转此向量
	rotateCFrame = rotateCFrame * CFrame.Angles(0, 0, math.rad(Angle))
	
	-- 计算旋转半径
	local radius = halfVector.Magnitude * Offset
	
	-- 中间位置 + 旋转后的上朝向 * 半径
	local resultPosition = middlePosition + rotateCFrame.UpVector * radius

	return resultPosition
end

--[[
	获取两个中间位置点（用于三次贝塞尔曲线的控制点）
	
	@param StartPosition Vector3|BasePart|Instance - 起始位置
	@param TargetPosition Vector3|BasePart|Instance - 目标位置
	@param Angle1 number? - 第一个控制点的旋转角度（可选，默认0）
	@param Offset1 number? - 第一个控制点的偏移系数（可选，默认1）
	@param Length1 number? - 第一个控制点的长度比例（可选，默认0.5）
	@param Angle2 number? - 第二个控制点的旋转角度（可选，默认0）
	@param Offset2 number? - 第二个控制点的偏移系数（可选，默认1）
	@param Length2 number? - 第二个控制点的长度比例（可选，默认0.5）
	@return Vector3, Vector3 - 两个控制点位置
--]]
function BezierUtil.Get2MiddlePosition(StartPosition, TargetPosition, Angle1, Offset1, Length1, Angle2, Offset2, Length2)
	if typeof(StartPosition) ~= "Vector3" then
		StartPosition = StartPosition.Position
	end

	if typeof(TargetPosition) ~= "Vector3" then
		TargetPosition = TargetPosition.Position
	end

	Angle1 = Angle1 or 0
	Angle2 = Angle2 or 0
	Offset1 = Offset1 or 1
	Offset2 = Offset2 or 1
	Length1 = Length1 or 0.5
	Length2 = Length2 or 0.5

	-- 内部函数：计算单个结果位置
	local function GetResultPosition(startPos, targetPos, angle, offset, length)
		local halfVector = (startPos - targetPos) * length
		local middlePosition = startPos - halfVector
		local rotateCFrame = CFrame.new(middlePosition, targetPos)
		rotateCFrame = rotateCFrame * CFrame.Angles(0, 0, math.rad(angle))
		local radius = offset
		local resultPosition = middlePosition + rotateCFrame.UpVector * radius
		return resultPosition
	end

	local resultPosition1 = GetResultPosition(StartPosition, TargetPosition, Angle1, Offset1, Length1)
	local resultPosition2 = GetResultPosition(StartPosition, TargetPosition, Angle2, Offset2, Length2)

	return resultPosition1, resultPosition2
end


--[[
	获取两个方形位置点（用于三次贝塞尔曲线，使用固定长度比例）
	
	@param StartPosition Vector3|BasePart|Instance - 起始位置
	@param TargetPosition Vector3|BasePart|Instance - 目标位置
	@param Angle1 number? - 第一个控制点的旋转角度（可选，默认0）
	@param Offset1 number? - 第一个控制点的偏移系数（可选，默认1）
	@param Angle2 number? - 第二个控制点的旋转角度（可选，默认0）
	@param Offset2 number? - 第二个控制点的偏移系数（可选，默认1）
	@return Vector3, Vector3 - 两个控制点位置
--]]
function BezierUtil.Get2SquarePosition(StartPosition, TargetPosition, Angle1, Offset1, Angle2, Offset2)
	if typeof(StartPosition) ~= "Vector3" then
		StartPosition = StartPosition.Position
	end

	if typeof(TargetPosition) ~= "Vector3" then
		TargetPosition = TargetPosition.Position
	end

	Angle1 = Angle1 or 0
	Angle2 = Angle2 or 0
	Offset1 = Offset1 and (1 + Offset1) or 1
	Offset2 = Offset2 and (1 + Offset2) or 1

	-- 内部函数：计算单个结果位置
	local function GetResultPosition(startPos, targetPos, angle, offset, length)
		local halfVector = (startPos - targetPos) * length
		local middlePosition = startPos - halfVector
		local rotateCFrame = CFrame.new(middlePosition, targetPos)
		rotateCFrame = rotateCFrame * CFrame.Angles(0, 0, math.rad(angle))
		local radius = halfVector.Magnitude * offset
		local resultPosition = middlePosition + rotateCFrame.UpVector * radius
		return resultPosition
	end

	local resultPosition1 = GetResultPosition(StartPosition, TargetPosition, Angle1, Offset1, 0.2)
	local resultPosition2 = GetResultPosition(StartPosition, TargetPosition, Angle2, Offset2, 0.8)

	return resultPosition1, resultPosition2
end

return BezierUtil