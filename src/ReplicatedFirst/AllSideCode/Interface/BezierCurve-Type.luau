local module = {}

-- ============================================
-- 基础工具函数 (Basic Utility Functions)
-- ============================================

--[[
	线性插值函数
	@param Start: Vector3 | BasePart | Instance - 起始位置或包含Position的对象
	@param End: Vector3 | BasePart | Instance - 结束位置或包含Position的对象
	@param Time: number - 插值时间（0-1）
	@return Vector3 - 插值后的位置
]]
function module.Lerp(Start: Vector3 | BasePart | Instance, End: Vector3 | BasePart | Instance, Time: number): Vector3
end

--[[
	根据距离计算帧数
	@param Start: Vector3 | BasePart | Instance - 起始位置
	@param End: Vector3 | BasePart | Instance - 结束位置
	@param Multiply: number? - 倍数系数（可选，默认1）
	@return number - 帧数
]]
function module.GetFrameByDistance(Start: Vector3 | BasePart | Instance, End: Vector3 | BasePart | Instance, Multiply: number?): number
end

--[[
	获取运动时间
	@param Frame: number - 帧数
	@param FPS: number - 帧率
	@return number - 时间（秒）
]]
function module.GetMotionTime(Frame: number, FPS: number): number
end

--[[
	获取中间位置
	@param StartPosition: Vector3 | BasePart | Instance - 起始位置
	@param TargetPosition: Vector3 | BasePart | Instance - 目标位置
	@param Angle: number - 角度
	@param Offset: number - 偏移量
	@return Vector3 - 中间位置
]]
function module.GetMiddlePosition(StartPosition: Vector3 | BasePart | Instance, TargetPosition: Vector3 | BasePart | Instance, Angle: number, Offset: number): Vector3
end

--[[
	获取两个中间位置点（用于三次贝塞尔曲线，可自定义长度比例）
	@param StartPosition: Vector3 | BasePart | Instance - 起始位置
	@param TargetPosition: Vector3 | BasePart | Instance - 目标位置
	@param Angle1: number? - 第一个控制点的旋转角度（可选，默认0）
	@param Offset1: number? - 第一个控制点的偏移系数（可选，默认1）
	@param Length1: number? - 第一个控制点的长度比例（可选，默认0.5）
	@param Angle2: number? - 第二个控制点的旋转角度（可选，默认0）
	@param Offset2: number? - 第二个控制点的偏移系数（可选，默认1）
	@param Length2: number? - 第二个控制点的长度比例（可选，默认0.5）
	@return Vector3, Vector3 - 两个控制点位置
]]
function module.Get2MiddlePosition(StartPosition: Vector3 | BasePart | Instance, TargetPosition: Vector3 | BasePart | Instance, Angle1: number?, Offset1: number?, Length1: number?, Angle2: number?, Offset2: number?, Length2: number?): (Vector3, Vector3)
end

--[[
	获取两个方形位置点（用于三次贝塞尔曲线，使用固定长度比例）
	@param StartPosition: Vector3 | BasePart | Instance - 起始位置
	@param TargetPosition: Vector3 | BasePart | Instance - 目标位置
	@param Angle1: number? - 第一个控制点的旋转角度（可选，默认0）
	@param Offset1: number? - 第一个控制点的偏移系数（可选，默认1）
	@param Angle2: number? - 第二个控制点的旋转角度（可选，默认0）
	@param Offset2: number? - 第二个控制点的偏移系数（可选，默认1）
	@return Vector3, Vector3 - 两个控制点位置
]]
function module.Get2SquarePosition(StartPosition: Vector3 | BasePart | Instance, TargetPosition: Vector3 | BasePart | Instance, Angle1: number?, Offset1: number?, Angle2: number?, Offset2: number?): (Vector3, Vector3)
end

-- ============================================
-- 基础贝塞尔曲线动画 (Basic Bezier Curve Animations)
-- ============================================

--[[
	线性贝塞尔曲线动画（两点直线运动）
	@param Frame: number - 总帧数
	@param FPS: number - 帧率
	@param Target: Model | BasePart - 目标对象
	@param Position1: Vector3 | BasePart | Instance - 起始位置
	@param Position2: Vector3 | BasePart | Instance - 结束位置
]]
function module.LinearBezierCurves(Frame: number, FPS: number, Target: Model | BasePart, Position1: Vector3 | BasePart | Instance, Position2: Vector3 | BasePart | Instance)
end

--[[
	二次贝塞尔曲线动画（三点曲线运动）
	@param Frame: number - 总帧数
	@param FPS: number - 帧率
	@param Target: Model - 目标对象
	@param Position1: Vector3 | BasePart | Instance - 起始位置
	@param Position2: Vector3 | BasePart | Instance - 控制点
	@param Position3: Vector3 | BasePart | Instance - 结束位置
	@param callback: (() -> ())? - 回调函数（可选）
]]
function module.QuadraticBezierCurves(Frame: number, FPS: number, Target: Model, Position1: Vector3 | BasePart | Instance, Position2: Vector3 | BasePart | Instance, Position3: Vector3 | BasePart | Instance, callback: (() -> ())?)
end

--[[
	二次贝塞尔曲线动画（目标对象动态移动）
	@param Frame: number - 总帧数
	@param FPS: number - 帧率
	@param Target: Model - 目标对象
	@param Position1: Vector3 | BasePart | Instance - 起始位置
	@param Position2: Vector3 | BasePart | Instance - 控制点
	@param ObjectGoal: Model | BasePart - 目标对象（动态跟踪）
	@param offset: Vector3 - 偏移量
	@param callback: (() -> ())? - 回调函数（可选）
]]
function module.QuadraticBezierCurvesObjectGoal(Frame: number, FPS: number, Target: Model, Position1: Vector3 | BasePart | Instance, Position2: Vector3 | BasePart | Instance, ObjectGoal: Model | BasePart, offset: Vector3, callback: (() -> ())?)
end

--[[
	三次贝塞尔曲线动画（四点曲线运动）
	@param Frame: number - 总帧数
	@param FPS: number - 帧率
	@param Target: Model | BasePart - 目标对象
	@param Position1: Vector3 | BasePart | Instance - 起始位置
	@param Position2: Vector3 | BasePart | Instance - 第一个控制点
	@param Position3: Vector3 | BasePart | Instance - 第二个控制点
	@param Position4: Vector3 | BasePart | Instance - 结束位置
]]
function module.CubicBezierCurves(Frame: number, FPS: number, Target: Model | BasePart, Position1: Vector3 | BasePart | Instance, Position2: Vector3 | BasePart | Instance, Position3: Vector3 | BasePart | Instance, Position4: Vector3 | BasePart | Instance)
end

-- ============================================
-- 带朝向的贝塞尔曲线动画 (Bezier Curves with LookAt)
-- ============================================

--[[
	带朝向的线性贝塞尔曲线动画
	@param Frame: number - 总帧数
	@param FPS: number - 帧率
	@param Target: Model | BasePart - 目标对象
	@param Position1: Vector3 | BasePart | Instance - 起始位置
	@param Position2: Vector3 | BasePart | Instance - 结束位置
	@param CFrameOffset: CFrame? - CFrame偏移（可选）
]]
function module.LinearBezierCurvesLookAt(Frame: number, FPS: number, Target: Model | BasePart, Position1: Vector3 | BasePart | Instance, Position2: Vector3 | BasePart | Instance, CFrameOffset: CFrame?)
end

--[[
	带朝向的二次贝塞尔曲线动画
	@param Frame: number - 总帧数
	@param FPS: number - 帧率
	@param Target: BasePart - 目标对象
	@param Position1: Vector3 | BasePart | Instance - 起始位置
	@param Position2: Vector3 | BasePart | Instance - 控制点
	@param Position3: Vector3 | BasePart | Instance - 结束位置
	@param CFrameOffset: CFrame? - CFrame偏移（可选）
	@param callback: (() -> ())? - 回调函数（可选）
	@param easingStyle: Enum.EasingStyle? - 缓动样式（可选）
	@param easingDir: Enum.EasingDirection? - 缓动方向（可选）
]]
function module.QuadraticBezierCurvesLookAt(Frame: number, FPS: number, Target: BasePart, Position1: Vector3 | BasePart | Instance, Position2: Vector3 | BasePart | Instance, Position3: Vector3 | BasePart | Instance, CFrameOffset: CFrame?, callback: (() -> ())?, easingStyle: Enum.EasingStyle?, easingDir: Enum.EasingDirection?)
end

--[[
	带缩放变化和朝向的二次贝塞尔曲线动画
	@param Frame: number - 总帧数
	@param FPS: number - 帧率
	@param Target: BasePart - 目标对象
	@param Position1: Vector3 | BasePart | Instance - 起始位置
	@param Position2: Vector3 | BasePart | Instance - 控制点
	@param Position3: Vector3 | BasePart | Instance - 结束位置
	@param CFrameOffset: CFrame - CFrame偏移量
	@param callback: (() -> ())? - 回调函数（可选）
	@param beishu: number? - 缩放倍数（可选）
]]
function module.QuadraticBezierCurvesScaleChangeLookAt(Frame: number, FPS: number, Target: BasePart, Position1: Vector3 | BasePart | Instance, Position2: Vector3 | BasePart | Instance, Position3: Vector3 | BasePart | Instance, CFrameOffset: CFrame, callback: (() -> ())?, beishu: number?)
end

--[[
	带前向朝向的二次贝塞尔曲线动画
	@param Frame: number - 总帧数
	@param FPS: number - 帧率
	@param Target: BasePart - 目标对象
	@param Position1: Vector3 | BasePart | Instance - 起始位置
	@param Position2: Vector3 | BasePart | Instance - 控制点
	@param Position3: Vector3 | BasePart | Instance - 结束位置
	@param CFrameOffset: CFrame? - CFrame偏移（可选）
	@param callback: (() -> ())? - 回调函数（可选）
]]
function module.QuadraticBezierCurvesFrontLookAt(Frame: number, FPS: number, Target: BasePart, Position1: Vector3 | BasePart | Instance, Position2: Vector3 | BasePart | Instance, Position3: Vector3 | BasePart | Instance, CFrameOffset: CFrame?, callback: (() -> ())?)
end

--[[
	带旋转的二次贝塞尔曲线动画
	@param Frame: number - 总帧数
	@param FPS: number - 帧率
	@param Target: BasePart - 目标对象
	@param Position1: Vector3 | BasePart | Instance - 起始位置
	@param Position2: Vector3 | BasePart | Instance - 控制点
	@param Position3: Vector3 | BasePart | Instance - 结束位置
	@param CFrameOffset: CFrame? - CFrame偏移（可选）
	@param callback: (() -> ())? - 回调函数（可选）
	@param rotateSpeed: number? - 旋转速度（可选）
]]
function module.QuadraticBezierCurvesRotate(Frame: number, FPS: number, Target: BasePart, Position1: Vector3 | BasePart | Instance, Position2: Vector3 | BasePart | Instance, Position3: Vector3 | BasePart | Instance, CFrameOffset: CFrame?, callback: (() -> ())?, rotateSpeed: number?)
end

--[[
	跟随对象的二次贝塞尔曲线动画
	@param Frame: number - 总帧数
	@param FPS: number - 帧率
	@param Target: BasePart - 目标对象
	@param Position1: Vector3 | BasePart | Instance - 起始位置
	@param Position2: Vector3 | BasePart | Instance - 第一个控制点
	@param Position3: Vector3 | BasePart | Instance - 第二个控制点
	@param Position4: Vector3 | BasePart | Instance - 结束位置
	@param OriPos: Vector3 - 原始位置
	@param RootObject: BasePart - 根对象（用于跟随）
]]
function module.QuadraticBezierCurvesFollow(Frame: number, FPS: number, Target: BasePart, Position1: Vector3 | BasePart | Instance, Position2: Vector3 | BasePart | Instance, Position3: Vector3 | BasePart | Instance, Position4: Vector3 | BasePart | Instance, OriPos: Vector3, RootObject: BasePart)
end

--[[
	带朝向的三次贝塞尔曲线动画
	@param Frame: number - 总帧数
	@param FPS: number - 帧率
	@param Target: Model | BasePart - 目标对象
	@param Position1: Vector3 | BasePart | Instance - 起始位置
	@param Position2: Vector3 | BasePart | Instance - 第一个控制点
	@param Position3: Vector3 | BasePart | Instance - 第二个控制点
	@param Position4: Vector3 | BasePart | Instance - 结束位置
	@param CFrameOffset: CFrame? - CFrame偏移（可选）
]]
function module.CubicBezierCurvesLookAt(Frame: number, FPS: number, Target: Model | BasePart, Position1: Vector3 | BasePart | Instance, Position2: Vector3 | BasePart | Instance, Position3: Vector3 | BasePart | Instance, Position4: Vector3 | BasePart | Instance, CFrameOffset: CFrame?)
end

--[[
	相机朝向的二次贝塞尔曲线动画
	@param Frame: number - 总帧数
	@param FPS: number - 帧率
	@param Target: BasePart - 目标对象
	@param Position1: Vector3 | BasePart | Instance - 起始位置
	@param Position2: Vector3 | BasePart | Instance - 控制点
	@param Position3: Vector3 | BasePart | Instance - 结束位置
	@param CFrameOffset: CFrame? - CFrame偏移（可选）
	@param LookAtTarget: BasePart - 朝向目标
	@param callback: (() -> ())? - 回调函数（可选）
]]
function module.QuadraticBezierCurvesCameraLookAt(Frame: number, FPS: number, Target: BasePart, Position1: Vector3 | BasePart | Instance, Position2: Vector3 | BasePart | Instance, Position3: Vector3 | BasePart | Instance, CFrameOffset: CFrame?, LookAtTarget: BasePart, callback: (() -> ())?)
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
function module.MultiOrderBezierCurves(config: {
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
end

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
function module.GenerateBezierPoints(startPosition, endPosition, middlePointCount: number, offsetConfig: {
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
end

return module
