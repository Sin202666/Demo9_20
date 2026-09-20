--[[
	Module: FXUtil/BezierAnimMulti
	Description: 多阶贝塞尔控制点生成与轨迹动画
	Author: LinAoyu
	Created: 2024-01-01
	Last Modified: 2026-07-02
]]

local Debris = game:GetService("Debris")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Random = Random

local BezierUtil = require(script.Parent.BezierUtil)

local BezierAnimMulti = {}

-- ============================================
-- 多阶贝塞尔曲线辅助函数 (Multi-Order Bezier Curve Helper Functions)
-- ============================================

--[[
	根据起点、终点、中间点数量和偏移生成贝塞尔曲线控制点数组
	
	@param startPosition Vector3|BasePart|Instance - 起点位置
	@param endPosition Vector3|BasePart|Instance - 终点位置
	@param middlePointCount number - 中间点数量（不包括起点和终点）
	@param offsetConfig table? - 偏移配置（可选）
		{
			HeightOffset: number?,      -- 高度偏移（Y轴偏移，可选，默认0）
			HeightOffsetRandom: number?, -- 高度偏移随机范围（可选，默认0，会在HeightOffset基础上±随机值）
			SideOffset: number?,        -- 侧向偏移（垂直于路径方向的偏移，可选，默认0）
			SideOffsetRandom: number?,  -- 侧向偏移随机范围（可选，默认0，会在SideOffset基础上±随机值）
			OffsetDirection: Vector3?, -- 自定义偏移方向（可选，如果不提供则自动计算）
			EasingStyle: Enum.EasingStyle?,  -- 偏移曲线样式（可选，默认Quad）
			EasingDirection: Enum.EasingDirection?,  -- 偏移曲线方向（可选，默认In）
			RandomOffset: number?,      -- 全局随机偏移量（可选，默认0，在所有方向上随机偏移）
			RandomSeed: number?,        -- 随机数种子（可选，如果提供相同的种子会生成相同的点数组）
		}
	@return {Vector3} - 控制点数组（包括起点、中间点和终点）
--]]
function BezierAnimMulti.GenerateBezierPoints(startPosition, endPosition, middlePointCount: number, offsetConfig: {
	HeightOffset: number?,
	HeightOffsetRandom: number?,
	SideOffset: number?,
	SideOffsetRandom: number?,
	OffsetDirection: Vector3?,
	EasingStyle: Enum.EasingStyle?,
	EasingDirection: Enum.EasingDirection?,
	RandomOffset: number?,
	RandomSeed: number?,
}?): {Vector3}
	-- 转换起点和终点为Vector3
	if typeof(startPosition) ~= "Vector3" then
		if typeof(startPosition) == "Instance" then
			local instance = startPosition :: Instance
			if instance:IsA("BasePart") or instance:IsA("Model") then
				startPosition = instance:GetPivot().Position
			else
				local success, pos = pcall(function()
					return (instance :: any).Position
				end)
				if success and typeof(pos) == "Vector3" then
					startPosition = pos
				else
					warn("BezierCurve.GenerateBezierPoints: 无法从起点对象获取位置")
					return {}
				end
			end
		else
			warn("BezierCurve.GenerateBezierPoints: 不支持的起点类型")
			return {}
		end
	end
	
	if typeof(endPosition) ~= "Vector3" then
		if typeof(endPosition) == "Instance" then
			local instance = endPosition :: Instance
			if instance:IsA("BasePart") or instance:IsA("Model") then
				endPosition = instance:GetPivot().Position
			else
				local success, pos = pcall(function()
					return (instance :: any).Position
				end)
				if success and typeof(pos) == "Vector3" then
					endPosition = pos
				else
					warn("BezierCurve.GenerateBezierPoints: 无法从终点对象获取位置")
					return {}
				end
			end
		else
			warn("BezierCurve.GenerateBezierPoints: 不支持的终点类型")
			return {}
		end
	end
	
	-- 参数验证
	if middlePointCount < 0 then
		middlePointCount = 0
	end
	
	-- 设置默认偏移配置
	local config = offsetConfig or {}
	local heightOffset = config.HeightOffset or 0
	local heightOffsetRandom = config.HeightOffsetRandom or 0
	local sideOffset = config.SideOffset or 0
	local sideOffsetRandom = config.SideOffsetRandom or 0
	local offsetDirection = config.OffsetDirection
	local easingStyle = config.EasingStyle or Enum.EasingStyle.Quad
	local easingDirection = config.EasingDirection or Enum.EasingDirection.In
	local randomOffset = config.RandomOffset or 0
	local randomSeed = config.RandomSeed
	
	-- 创建随机数生成器（如果提供了种子，使用种子；否则使用默认随机数生成器）
	local randomGenerator = nil
	if randomSeed then
		randomGenerator = Random.new(randomSeed)
	else
		randomGenerator = Random.new()  -- 使用系统时间作为种子
	end
	
	-- 计算基础向量
	local direction = (endPosition - startPosition)
	local distance = direction.Magnitude
	local directionUnit = distance > 0.001 and direction.Unit or Vector3.new(0, 1, 0)
	
	-- 计算垂直方向（用于侧向偏移）
	local upVector = Vector3.new(0, 1, 0)
	local rightVector = directionUnit:Cross(upVector)
	if rightVector.Magnitude < 0.001 then
		-- 如果方向与Y轴平行，使用X轴作为参考
		rightVector = directionUnit:Cross(Vector3.new(1, 0, 0))
	end
	rightVector = rightVector.Unit
	
	-- 如果没有提供自定义偏移方向，使用计算出的垂直方向
	if not offsetDirection then
		offsetDirection = rightVector
	else
		offsetDirection = offsetDirection.Unit
	end
	
	-- 生成点数组
	local points: {Vector3} = {}
	
	-- 添加起点
	table.insert(points, startPosition)
	
	-- 生成中间点
	if middlePointCount > 0 then
		for i = 1, middlePointCount do
			-- 计算在路径上的位置比例（0到1之间）
			local t = i / (middlePointCount + 1)
			
			-- 计算基础位置（在起点和终点的直线上）
			local basePosition = startPosition + direction * t
			
			-- 计算偏移曲线值（用于控制偏移的强度变化）
			-- 使用 TweenService 的 GetValue 方法应用官方缓动曲线
			local curveValue = TweenService:GetValue(t, easingStyle, easingDirection)
			
			-- 计算高度偏移（Y轴），包含随机性
			local heightOffsetValue = heightOffset * curveValue
			if heightOffsetRandom > 0 then
				-- 在基础高度偏移上添加随机值（±heightOffsetRandom）
				-- 使用 NextNumber(-1, 1) 生成 -1 到 1 之间的随机数
				local randomHeight = randomGenerator:NextNumber(-1, 1) * heightOffsetRandom * curveValue
				heightOffsetValue = heightOffsetValue + randomHeight
			end
			local heightOffsetVector = Vector3.new(0, heightOffsetValue, 0)
			
			-- 计算侧向偏移（垂直于路径方向），包含随机性
			local sideOffsetValue = sideOffset * curveValue
			if sideOffsetRandom > 0 then
				-- 在基础侧向偏移上添加随机值（±sideOffsetRandom）
				local randomSide = randomGenerator:NextNumber(-1, 1) * sideOffsetRandom * curveValue
				sideOffsetValue = sideOffsetValue + randomSide
			end
			local sideOffsetVector = offsetDirection * sideOffsetValue
			
			-- 应用全局随机偏移（在所有方向上）
			local randomOffsetVector = Vector3.new(0, 0, 0)
			if randomOffset > 0 then
				local randomX = randomGenerator:NextNumber(-1, 1) * randomOffset
				local randomY = randomGenerator:NextNumber(-1, 1) * randomOffset
				local randomZ = randomGenerator:NextNumber(-1, 1) * randomOffset
				randomOffsetVector = Vector3.new(randomX, randomY, randomZ)
			end
			
			-- 计算最终位置
			local finalPosition = basePosition + heightOffsetVector + sideOffsetVector + randomOffsetVector
			table.insert(points, finalPosition)
		end
	end
	
	-- 添加终点
	table.insert(points, endPosition)
	
	return points
end

-- ============================================
-- 多阶贝塞尔曲线动画 (Multi-Order Bezier Curve Animation)
-- ============================================

--[[
	计算多阶贝塞尔曲线上的点（递归实现）
	
	@param points {Vector3} - 控制点数组
	@param t number - 时间参数（0-1）
	@return Vector3 - 曲线上的点
--]]
local function _calculateBezierPoint(points: {Vector3}, t: number): Vector3
	if #points == 1 then
		return points[1]
	end
	
	-- 递归计算：对相邻点进行线性插值
	local newPoints = {}
	for i = 1, #points - 1 do
		local lerped = BezierUtil.Lerp(points[i], points[i + 1], t)
		table.insert(newPoints, lerped)
	end
	
	return _calculateBezierPoint(newPoints, t)
end

--[[
	多阶贝塞尔曲线动画（支持任意数量的控制点）
	
	@param config table - 配置表
		{
			Frame: number,              -- 总帧数
			FPS: number,                -- 帧率
			Target: BasePart|Model,     -- 目标对象
			Points: {Vector3|BasePart|Instance},  -- 按顺序的控制点数组（至少2个点）
			EasingStyle: Enum.EasingStyle?,  -- 曲线变化样式（可选，默认Linear）
			EasingDirection: Enum.EasingDirection?,  -- 曲线变化方向（可选，默认In）
			CFrameOffset: CFrame?,      -- CFrame偏移量（可选）
			UseLookAt: boolean?,        -- 是否使用朝向控制（可选，默认false）
			LookAtTarget: BasePart|Vector3?,  -- LookAt目标（可选，当UseLookAt为true时使用）
		}
	@param callback function? - 完成回调函数（可选）
	@return RBXScriptConnection - 事件连接（可用于提前取消）
--]]
function BezierAnimMulti.MultiOrderBezierCurves(config: {
	Frame: number,
	FPS: number,
	Target: BasePart | Model,
	Points: {Vector3 | BasePart | Instance},
	EasingStyle: Enum.EasingStyle?,
	EasingDirection: Enum.EasingDirection?,
	CFrameOffset: CFrame?,
	UseLookAt: boolean?,
	LookAtTarget: BasePart | Vector3?,
}, callback: (() -> ())?): RBXScriptConnection?
	
	-- 参数验证
	if not config or not config.Frame or not config.FPS or not config.Target or not config.Points then
		warn("BezierCurve.MultiOrderBezierCurves: 缺少必需参数")
		return nil
	end
	
	if #config.Points < 2 then
		warn("BezierCurve.MultiOrderBezierCurves: 至少需要2个控制点")
		return nil
	end
	
	-- 转换所有点为Vector3
	local points: {Vector3} = {}
	for i, point in ipairs(config.Points) do
		if typeof(point) == "Vector3" then
			points[i] = point
		elseif typeof(point) == "Instance" then
			local instance = point :: Instance
			if instance:IsA("BasePart") or instance:IsA("Model") then
				points[i] = instance:GetPivot().Position
			else
				-- 尝试获取Position属性（可能是Vector3Value等）
				local positionValue = instance:GetAttribute("Position")
				if positionValue and typeof(positionValue) == "Vector3" then
					points[i] = positionValue
				else
					-- 尝试直接访问Position属性（如果存在）
					local success, position = pcall(function()
						return (instance :: any).Position
					end)
					if success and typeof(position) == "Vector3" then
						points[i] = position
					else
						warn("BezierCurve.MultiOrderBezierCurves: 无法从对象获取位置，索引:", i, "类型:", instance.ClassName)
						return nil
					end
				end
			end
		else
			warn("BezierCurve.MultiOrderBezierCurves: 不支持的点类型，索引:", i, "类型:", typeof(point))
			return nil
		end
	end
	
	-- 设置默认值
	local easingStyle = config.EasingStyle or Enum.EasingStyle.Linear
	local easingDir = config.EasingDirection or Enum.EasingDirection.In
	local useLookAt = config.UseLookAt or false
	local cFrameOffset = config.CFrameOffset or CFrame.new()
	
	-- 创建临时Vector3Value用于存储中间值（如果需要LookAt）
	local vecValue = nil
	if useLookAt then
		vecValue = Instance.new("Vector3Value")
		vecValue.Parent = config.Target
		vecValue.Value = Vector3.new(0, 0, 0)
	end
	
	local index = 0
	local dTime = 1 / config.FPS
	local totalTime = 0
	local event: RBXScriptConnection? = nil
	
	event = RunService.Heartbeat:Connect(function(dt)
		totalTime += dt
		
		if totalTime < index * dTime then
			return
		end
		
		if totalTime >= index * dTime then
			-- 使用连续计算，确保每一帧都更新（与 QuadraticBezierCurves 保持一致）
			index = totalTime / dTime
			local nowTime = index / config.Frame
			
			-- 限制 nowTime 不超过 1，防止超出范围
			if nowTime > 1 then
				nowTime = 1
			end
			
			-- 应用缓动效果
			local time = TweenService:GetValue(nowTime, easingStyle, easingDir)
			
			-- 计算贝塞尔曲线上的点
			local bezierPoint = _calculateBezierPoint(points, time)
			
			-- 根据目标类型和配置应用变换
			if useLookAt then
				-- 使用LookAt模式
				vecValue.Value = bezierPoint
				
				local lookAtTarget = config.LookAtTarget
				local lookAtPosition: Vector3
				
				if typeof(lookAtTarget) == "Vector3" then
					lookAtPosition = lookAtTarget
				elseif typeof(lookAtTarget) == "Instance" then
					local instance = lookAtTarget :: Instance
					if instance:IsA("BasePart") or instance:IsA("Model") then
						lookAtPosition = instance:GetPivot().Position
					else
						-- 尝试获取Position属性
						local success, position = pcall(function()
							return (instance :: any).Position
						end)
						if success and typeof(position) == "Vector3" then
							lookAtPosition = position
						else
							lookAtPosition = bezierPoint
						end
					end
				else
					lookAtPosition = bezierPoint
				end
				
				if config.Target:IsA("Model") then
					config.Target:PivotTo(CFrame.lookAt(config.Target:GetPivot().Position, lookAtPosition, Vector3.new(0, 1, 0)) * cFrameOffset)
					config.Target:PivotTo(config.Target:GetPivot().Rotation + bezierPoint)
				elseif config.Target:IsA("BasePart") then
					config.Target.CFrame = CFrame.lookAt(config.Target.CFrame.Position, lookAtPosition, config.Target.CFrame.UpVector) * cFrameOffset
					config.Target.CFrame = config.Target.CFrame.Rotation + bezierPoint
				end
			else
				-- 不使用LookAt，直接设置位置
				if config.Target:IsA("Model") then
					config.Target:PivotTo(config.Target:GetPivot().Rotation * cFrameOffset + bezierPoint)
				elseif config.Target:IsA("BasePart") then
					config.Target.CFrame = config.Target.CFrame.Rotation * cFrameOffset + bezierPoint
				end
			end
		end
		
		-- 检查是否完成（使用 >= 确保在达到或超过总帧数时结束）
		if index >= config.Frame then
			if callback then
				callback()
			end
			
			if event then
				event:Disconnect()
				event = nil
			end
			
			if vecValue then
				Debris:AddItem(vecValue, task.wait())
			end
		end
	end)
	
	return event
end

return BezierAnimMulti