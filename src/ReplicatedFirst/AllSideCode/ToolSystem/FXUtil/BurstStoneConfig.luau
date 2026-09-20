--[[
	Module: FXUtil/BurstStoneConfig
	Description: 石块冲击波/飞石/地裂特效配置表
	Author: LinAoyu
	Created: 2024-01-01
	Last Modified: 2026-07-02
]]

local BurstStoneConfig = {}

-- 单侧冲击波配置
local OneSideShockWaveInfo = {
	Temp = {
		MaxSize = Vector3.new(9, 9, 9),
		MinSize = Vector3.new(0.7, 0.7, 0.7),
		RiseStoneSizeRandomRange = Vector3.new(0, 0, 0), -- 升起石块尺寸随机范围，每轴 ± 该值
		ShockLenth = 30,
		StoneNum = 8,
		RiseTime = 0.2,
		WholeTime = 0.2,
		RiseStoneLifeTime = 2,
		RiseStoneDisapearTime = 1,
		RiseStoneDisapearStyle = Enum.EasingStyle.Linear,
		RiseStoneDisapearDir = Enum.EasingDirection.In,
		RiseStoneSpawnCFrameOffset = CFrame.new(0, 0, 0) * CFrame.Angles(0, 0, 0),
		-- RiseStonePoseOffsetRange: CFrame，位置和旋转的随机范围
		-- RiseStoneOrientationRange: Vector3?，基础朝向随机范围(度)，X/Z 为 ±值，Y 为 0~值，默认 (15, 360, 20)
		FlyMaxSize = Vector3.new(3, 3, 3),
		FlyMinSize = Vector3.new(2, 2, 2),
		FlyStoneLifeTime = 3,
		FlyStoneForce = 160,
		FlyStoneForceRandomRange = 60,
		FlyStoneProbability = 1, -- 飞石出现概率 0~1，默认 1 即 100%
	},
	["单条向左偏移石块"] = {
		MaxSize = Vector3.new(4, 4, 4),
		MinSize = Vector3.new(1.5, 1.5, 1.5),
		RiseStoneSizeRandomRange = Vector3.new(1, 1, 1),
		ShockLenth = 100,
		StoneNum = 28,
		RiseTime = 0.3,
		WholeTime = 2.8,
		RiseStoneLifeTime = 2.5,
		RiseStoneDisapearTime = 1,
		RiseStonePoseOffsetRange = CFrame.new(0.5,0.5,0.5),
		RiseStoneOrientationRange =  Vector3.new(360,360,360),
		RiseStoneDisapearStyle = Enum.EasingStyle.Sine,
		RiseStoneDisapearDir = Enum.EasingDirection.Out,
		RiseStoneSpawnCFrameOffset = CFrame.new(2, 0, 0) * CFrame.Angles(0, math.rad(-3), 0),
		FlyMaxSize = Vector3.new(3, 3, 3),
		FlyMinSize = Vector3.new(0.5, 0.5, 0.5),
		FlyStoneLifeTime = 2,
		FlyStoneForce = 250,
		FlyStoneForceRandomRange = 10,
		FlyStoneProbability = 0.5,
	},
	["单条向右偏移石块"] = {
		MaxSize = Vector3.new(4, 4, 4),
		MinSize = Vector3.new(1.5, 1.5, 1.5),
		RiseStoneSizeRandomRange = Vector3.new(1, 1, 1),
		ShockLenth = 100,
		StoneNum = 28,
		RiseTime = 0.3,
		WholeTime = 2.8,
		RiseStoneLifeTime = 2.5,
		RiseStoneDisapearTime = 1,
		RiseStonePoseOffsetRange = CFrame.new(0.5,0.5,0.5),
		RiseStoneOrientationRange =  Vector3.new(360,360,360),
		RiseStoneDisapearStyle = Enum.EasingStyle.Sine,
		RiseStoneDisapearDir = Enum.EasingDirection.Out,
		RiseStoneSpawnCFrameOffset = CFrame.new(-2, 0, 0) * CFrame.Angles(0, math.rad(3), 0),
		FlyMaxSize = Vector3.new(3, 3, 3),
		FlyMinSize = Vector3.new(0.5, 0.5, 0.5),
		FlyStoneLifeTime = 2,
		FlyStoneForce = 250,
		FlyStoneForceRandomRange = 10,
		FlyStoneProbability = 0.5,
	},
}

-- 石头飞行配置
local stoneFlyInfo = {
	Temp = {
		[1] = {
			MinSize = Vector3.new(3, 3, 3),
			MaxSize = Vector3.new(4, 4, 4),
			SpawnOffset = Vector3.new(8, 1, 8),
			Force = 480,
			ForceOffset = 40,
			StoneNum = 10,
			StayTime = 3,
			CanCollide = true,
			-- OrientationOffsetRange: CFrame，旋转部分定义各轴随机范围(弧度)
			-- DirectionOffset: Vector3，目标方向偏移范围，每轴在 ± 该值内随机，速度方向 = (正上方 + 随机偏移).Unit
		},
		[2] = {
			MinSize = Vector3.new(2, 2, 2),
			MaxSize = Vector3.new(3, 3, 3),
			SpawnOffset = Vector3.new(16, 1, 16),
			Force = 420,
			ForceOffset = 40,
			StoneNum = 10,
			StayTime = 2.5,
			CanCollide = true,
		},
		[3] = {
			MinSize = Vector3.new(1, 1, 1),
			MaxSize = Vector3.new(2, 2, 2),
			SpawnOffset = Vector3.new(25, 1, 25),
			Force = 340,
			ForceOffset = 30,
			StoneNum = 20,
			StayTime = 2,
			CanCollide = true,
		},
	},
	["Meteor"] = {
		[1] = {
			MinSize = Vector3.new(1, 1, 1),
			MaxSize = Vector3.new(5, 5, 5),
			SpawnOffset = Vector3.new(1, 1, 1),
			DirectionOffset = Vector3.new(0.5,0,0.5),
			Force = 200,
			ForceOffset = 40,
			StoneNum = 7,
			StayTime = 3,
			CanCollide = false,
			OrientationOffsetRange = CFrame.Angles(math.rad(180),math.rad(180),math.rad(180)),--旋转部分定义各轴随机范围(弧度)，如 CFrame.Angles(0, math.rad(180), 0) 表示 Y 轴 ±180°
		},
	},
	["两圈石头飞起"] = {
		[1] = {
			MinSize = Vector3.new(2.5, 2.5, 2.5),
			MaxSize = Vector3.new(3.3, 3.3, 3.3),
			SpawnOffset = Vector3.new(5, 1, 5),
			Force = 250,
			ForceOffset = 40,
			StoneNum = 2,
			StayTime = 3,
			CanCollide = true,
		},
		[2] = {
			MinSize = Vector3.new(1, 1, 1),
			MaxSize = Vector3.new(2.5, 2.5, 2.5),
			SpawnOffset = Vector3.new(9, 1, 9),
			Force = 350,
			ForceOffset = 40,
			StoneNum = 7,
			StayTime = 2.5,
			CanCollide = true,
		},
	},
}

-- 地裂配置
local landBreakInfo = {
	Temp = {
		[1] = {
			MinSize = Vector3.new(5, 2, 5),
			MaxSize = Vector3.new(7, 3, 7),
			PositionOffset = Vector3.new(0, -0.8, -9),
			PositionRamdomOffset = Vector3.new(0.5, 0, 0.5),
			AngleOffset = Vector3.new(math.rad(6), math.rad(0), math.rad(0)),
			AngleRandomOffset = Vector3.new(math.rad(2), math.rad(5), math.rad(5)),
			OriAngle = 0,
			StoneNum = 5,
			Delay = 0,
			LifeTime = 2,
		},
		[2] = {
			MinSize = Vector3.new(6, 2, 6),
			MaxSize = Vector3.new(7, 3, 7),
			PositionOffset = Vector3.new(0, -1.5, -18),
			PositionRamdomOffset = Vector3.new(1, 0, 1.5),
			AngleOffset = Vector3.new(math.rad(15), math.rad(0), math.rad(0)),
			AngleRandomOffset = Vector3.new(math.rad(3), math.rad(5), math.rad(5)),
			OriAngle = 0,
			StoneNum = 9,
			Delay = 0.03,
			LifeTime = 2,
		},
		[3] = {
			MinSize = Vector3.new(7, 1.5, 6),
			MaxSize = Vector3.new(9, 2.5, 9),
			PositionOffset = Vector3.new(0, -1.5, -28),
			PositionRamdomOffset = Vector3.new(3, 0.5, 3),
			AngleOffset = Vector3.new(math.rad(20), math.rad(0), math.rad(0)),
			AngleRandomOffset = Vector3.new(math.rad(3), math.rad(5), math.rad(5)),
			OriAngle = 0,
			StoneNum = 12,
			Delay = 0.05,
			LifeTime = 2,
		},
	},
	Meteor = {
		[1] = {
			MinSize = Vector3.new(2, 2, 2),
			MaxSize = Vector3.new(3, 3, 3),
			PositionOffset = Vector3.new(0, -0.8, -18),
			PositionRamdomOffset = Vector3.new(2, 2, 2),
			AngleOffset = Vector3.new(math.rad(0), math.rad(0), math.rad(0)),
			AngleRandomOffset = Vector3.new(math.rad(180), math.rad(180), math.rad(180)),
			OriAngle = 0,
			StoneNum = 24,
			Delay = 0,
			LifeTime = 2,
		},
	},
}

BurstStoneConfig.OneSideShockWaveInfo = OneSideShockWaveInfo
BurstStoneConfig.stoneFlyInfo = stoneFlyInfo
BurstStoneConfig.landBreakInfo = landBreakInfo

return BurstStoneConfig