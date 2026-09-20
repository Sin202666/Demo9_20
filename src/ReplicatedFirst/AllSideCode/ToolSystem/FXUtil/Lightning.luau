--[[
	Module: FXUtil/Lightning
	Description: 分段随机闪电链效果
	Author: LinAoyu
	Created: 2024-01-01
	Last Modified: 2026-07-02
]]

local module = {}

-- ============================================================================
-- 导入和依赖
-- ============================================================================

-- Services
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

-- ============================================================================
-- 内部辅助函数
-- ============================================================================

--[[
	创建单段闪电 Part（圆柱 Neon）
	@param _color Color3
	@return Part
]]
local function _createLightningPart(_color: Color3): Part
	local Light: Part = Instance.new("Part")
	Light.Shape = Enum.PartType.Cylinder
	Light.Color = _color
	Light.Material = Enum.Material.Neon
	Light.CanTouch = false
	Light.CanCollide = false
	Light.CanQuery = false
	Light.Anchored = true
	Light.Transparency = 1
	Light.CastShadow = false
	Light.Parent = workspace
	
	return Light
end

--[[
	更新单段闪电的位置与尺寸
	@param _lightning Part
	@param _StartPos Vector3
	@param _GoalPos Vector3
	@param _LightSize Vector3
]]
local function _oneLightning(_lightning: Part, _StartPos: Vector3, _GoalPos: Vector3, _LightSize: Vector3)
	local centerPos = (_StartPos + _GoalPos) / 2
	local LightCF = CFrame.lookAt(centerPos, _GoalPos)
	local distance = (_StartPos - _GoalPos).Magnitude
	local LightSize = Vector3.new(distance, _LightSize.Y, _LightSize.Z)
	
	_lightning.Size = LightSize
	_lightning:PivotTo(LightCF:ToWorldSpace(CFrame.Angles(0, math.rad(90), 0)))
end

-- ============================================================================
-- 配置数据
-- ============================================================================

-- 闪电类型配置
local LightningType = {
	["Temp"] = {
		LightNum = 6, -- 闪电结点的数量
		LightColor = Color3.new(0.835294, 0.835294, 0), -- 闪电颜色
		LightRandomLength = 10, -- 每个闪电结点位置随机范围
		LightSizeRangeMax = Vector3.new(4, 4, 4), -- 光柱最大尺寸
		LightSizeRangeMin = Vector3.new(0.1, 0.1, 0.1), -- 光柱最小尺寸
		LightTime = 0.5, -- 闪电正常状态持续时间
		LightFadeTime = 0.2, -- 闪电渐隐时间
		ShowDtTime = 0.05, -- 闪电结点出现间隔
	},
	["Solo一技能"] = {
		LightNum = 4,
		LightColor = Color3.new(0.360784, 0.701961, 1),
		LightRandomLength = 5,
		LightSizeRangeMax = Vector3.new(4, 4, 4),
		LightSizeRangeMin = Vector3.new(0.1, 0.1, 0.1),
		LightTime = 0.2,
		LightFadeTime = 0.2,
		ShowDtTime = 0.05,
	},
	["Solo二技能"] = {
		LightNum = 4,
		LightColor = Color3.new(0.360784, 0.701961, 1),
		LightRandomLength = 5,
		LightSizeRangeMax = Vector3.new(4, 4, 4),
		LightSizeRangeMin = Vector3.new(0.1, 0.1, 0.1),
		LightTime = 0.3,
		LightFadeTime = 0.2,
		ShowDtTime = 0.025,
	},
}

-- ============================================================================
-- 公共API
-- ============================================================================

--[[
	创建闪电效果
	@param _StartPos: Vector3 - 起始位置
	@param _GoalPos: Vector3 - 目标位置
	@param _LightningType: string? - 闪电类型（默认为 "Temp"）
]]
function module.CreateLightning(_StartPos: Vector3, _GoalPos: Vector3, _LightningType: string?)
	if not _LightningType then
		_LightningType = "Temp"
	end
	
	local config = LightningType[_LightningType]
	if not config then
		warn("未知的闪电类型:", _LightningType)
		return
	end
	
	-- 获取配置参数
	local LightNum = config.LightNum
	local LightColor = config.LightColor
	local LightRandomLength = config.LightRandomLength
	local LightSizeRangeMin = config.LightSizeRangeMin
	local LightSizeRangeMax = config.LightSizeRangeMax
	local LightTime = config.LightTime
	local FadeTime = config.LightFadeTime
	local showDtTime = config.ShowDtTime
	
	-- 计算闪电方向
	local LightningCF = CFrame.lookAt(_StartPos, _GoalPos)
	local LightningLength = (_StartPos - _GoalPos).Magnitude
	local OneLightningLength = LightningLength / LightNum

	-- 创建闪电Part数组
	local LightVt = {}
	for i = 1, LightNum do
		LightVt[i] = _createLightningPart(LightColor)
	end
	
	local LastGoalCF: CFrame? = nil
	local totalTime = 0
	local cleanedUp = false
	local conn: RBXScriptConnection? = nil

	local function _cleanupLightning()
		if cleanedUp then
			return
		end
		cleanedUp = true
		if conn then
			conn:Disconnect()
			conn = nil
		end
		for _, v in pairs(LightVt) do
			Debris:AddItem(v, 0)
		end
		table.clear(LightVt)
	end

	conn = RunService.Heartbeat:Connect(function(dt)
		if cleanedUp then
			return
		end
		if totalTime >= LightTime + FadeTime then
			_cleanupLightning()
			return
		end

		-- 计算应该显示的闪电段数量
		local ShowNum = math.floor(totalTime / showDtTime)
		
		-- 更新每个闪电段
		for i = 1, LightNum do
			-- 逐渐显示
			if i <= ShowNum then
				LightVt[i].Transparency = 0
			end
			
			-- 计算起始位置
			local StartCF: CFrame
			if i == 1 then
				StartCF = LightningCF:ToWorldSpace(CFrame.new(
					LightRandomLength * (1 - 2 * math.random()),
					LightRandomLength * (1 - 2 * math.random()),
					-OneLightningLength * (i - 1)
				))
			else
				StartCF = LastGoalCF :: CFrame
			end
			
			-- 计算目标位置
			local GoalCF = LightningCF:ToWorldSpace(CFrame.new(
				LightRandomLength * (1 - 2 * math.random()),
				LightRandomLength * (1 - 2 * math.random()),
				-OneLightningLength * i
			))
			
			LastGoalCF = GoalCF
			
			-- 计算随机尺寸
			local LightSize = Vector3.new(
				1,
				LightSizeRangeMin.Y + math.random() * (LightSizeRangeMax.Y - LightSizeRangeMin.Y),
				LightSizeRangeMin.Z + math.random() * (LightSizeRangeMax.Z - LightSizeRangeMin.Z)
			)
			
			-- 渐隐效果
			if totalTime >= LightTime then
				local FadePercent = math.clamp((totalTime - LightTime) / FadeTime, 0, 1)
				local FadeValue = TweenService:GetValue(FadePercent, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
				LightSize = LightSize * (1 - FadeValue)
			end
			
			-- 更新闪电段
			_oneLightning(LightVt[i], StartCF.Position, GoalCF.Position, LightSize)
		end
		
		totalTime += dt
	end)
end

return module
