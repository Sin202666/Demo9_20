--[[
	Module: FXUtil/ModelTransform
	Description: 透明度/颜色/CFrame 控制与焊接
	Author: LinAoyu
	Created: 2024-01-01
	Last Modified: 2026-07-02
]]

return function(FXUtil)

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

local VisibleMgr = Utils.VisibleMgr
-- ============================================
-- 透明度和位置动画函数 (Transparency and Position Animation)
-- ============================================

--[[
	任意实例子树内 BasePart 透明度 Tween（根自身若为 BasePart 亦包含）。
	根可为 Model / Folder / BasePart；整块模型淡出亦传入模型根即可。
]]
function FXUtil.Instance_Transparency_Tween(root: Instance, tweenTime: number?, tweenValue: number, easingStyle: Enum.EasingStyle?, easingDir: Enum.EasingDirection?)
	if not root then
		return
	end

	tweenTime = tweenTime or 0.1
	easingStyle = easingStyle or Enum.EasingStyle.Linear
	easingDir = easingDir or Enum.EasingDirection.In

	if root:IsA("BasePart") then
		TweenService:Create(root, TweenInfo.new(tweenTime, easingStyle, easingDir), { Transparency = tweenValue }):Play()
	end

	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") then
			TweenService:Create(d, TweenInfo.new(tweenTime, easingStyle, easingDir), { Transparency = tweenValue }):Play()
		end
	end
end

--[[
	任意实例子树内 BasePart Color3 Tween（根自身若为 BasePart 亦包含）。
]]
function FXUtil.Instance_Color_Tween(
	root: Instance,
	tweenTime: number?,
	goalColor: Color3,
	easingStyle: Enum.EasingStyle?,
	easingDir: Enum.EasingDirection?
)
	if not root or typeof(goalColor) ~= "Color3" then
		return
	end

	tweenTime = tweenTime or 0.1
	easingStyle = easingStyle or Enum.EasingStyle.Linear
	easingDir = easingDir or Enum.EasingDirection.In

	local info = TweenInfo.new(tweenTime, easingStyle, easingDir)
	if root:IsA("BasePart") then
		TweenService:Create(root, info, { Color = goalColor }):Play()
	end

	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") then
			TweenService:Create(d, info, { Color = goalColor }):Play()
		end
	end
end

--[[
	Model 或 BasePart：Heartbeat 从当前 Pivot/CFrame 插值到 goalCF；进度用 TweenService:GetValue 施加 easing。
	@param shouldContinue 若返回 false 则断开（如技能 runGeneration 失效）
	@return 连接，可交由 BaseSkillClient:BindRunConn
]]
function FXUtil.Pivot_Instance_CF_Lerp_Heartbeat(
	inst: Model | BasePart,
	durationSec: number,
	goalCF: CFrame,
	easingStyle: Enum.EasingStyle?,
	easingDir: Enum.EasingDirection?,
	shouldContinue: (() -> boolean)?
): RBXScriptConnection
	easingStyle = easingStyle or Enum.EasingStyle.Linear
	easingDir = easingDir or Enum.EasingDirection.In

	local p0 = if inst:IsA("Model") then (inst :: Model):GetPivot() else (inst :: BasePart).CFrame
	local dur = math.max(durationSec, 1e-4)
	local elapsed = 0.0
	local conn: RBXScriptConnection?
	conn = RunService.Heartbeat:Connect(function(dt)
		if shouldContinue and not shouldContinue() then
			if conn then
				conn:Disconnect()
			end
			return
		end
		if not inst.Parent then
			if conn then
				conn:Disconnect()
			end
			return
		end

		elapsed += dt
		local u = math.clamp(elapsed / dur, 0, 1)
		local e = TweenService:GetValue(u, easingStyle, easingDir)
		local cf = p0:Lerp(goalCF, e)
		if inst:IsA("Model") then
			(inst :: Model):PivotTo(cf)
		else
			(inst :: BasePart).CFrame = cf
		end

		if u >= 1 then
			if conn then
				conn:Disconnect()
			end
		end
	end)
	return conn :: RBXScriptConnection
end

--[[
	模型CFrame动画
	
	@param model Model - 目标模型
	@param tweenTime number - 动画时间
	@param newCF CFrame - 目标CFrame
	@param easingStyle Enum.EasingStyle? - 缓动样式（可选）
	@param easingDir Enum.EasingDirection? - 缓动方向（可选）
	@param canMove boolean? - 是否允许移动（可选，默认false）
--]]
function FXUtil.Set_CFrame_Model_Tween(model: Model, tweenTime: number, newCF: CFrame, easingStyle: Enum.EasingStyle?, easingDir: Enum.EasingDirection?, canMove: boolean?)
	task.spawn(function()
		local oriCFrame = model:GetPivot()
		local timeline = 0
		local _lastTweenPoint = 0

		while timeline < 1 do
			timeline = math.min(timeline + RunService.Heartbeat:Wait() / tweenTime, 1)
			local tweenPoint = TweenService:GetValue(timeline, easingStyle, easingDir)

			model:PivotTo(oriCFrame:Lerp(newCF, timeline))
			if not canMove then
				model:PivotTo(oriCFrame)
			end
			_lastTweenPoint = tweenPoint
		end
	end)
end

-- ============================================
-- 焊接相关函数 (Weld Functions)
-- ============================================

--[[
	焊接部件
	
	@param main BasePart - 主部件
	@param weldPart BasePart - 要焊接的部件
--]]
function FXUtil.Weld(main: BasePart, weldPart: BasePart)
	if not main or not weldPart then
		return
	end

	local weld = Instance.new("WeldConstraint", weldPart)
	weld.Part0 = weldPart
	weld.Part1 = main
end

--[[
	取消焊接
	
	@param main BasePart - 主部件
--]]
function FXUtil.Unweld(main: BasePart)
	if not main then
		return
	end

	local weld = main:FindFirstChildOfClass("WeldConstraint")
	if weld then
		weld.Enabled = false
		Debris:AddItem(weld, 0)
	end
end


-- ============================================
-- 模型控制函数 (Model Control Functions)
-- ============================================

--[[
	控制模型位置（帧事件控制）
	
	@param instance Model - 目标模型
	@param func function - 返回CFrame的函数，接收时间参数
--]]
function FXUtil.Control_Model_CFrame(instance: Model, func: (number) -> CFrame)
	if not instance then
		return
	end

	if not func then
		return
	end

	local modelControl = instance:FindFirstChild("ModelControl")
	if not modelControl then
		modelControl = Instance.new("BoolValue", instance)
		modelControl.Name = "ModelControl"
		modelControl.Value = false
	end

	if modelControl.Value then
		return
	end

	modelControl.Value = true

	local controlEvent: RBXScriptConnection = nil
	local time = 0

	controlEvent = RunService.Heartbeat:Connect(function(dt)
		local newCF: CFrame = func(time)
		local nowModelControl = instance:FindFirstChild("ModelControl")

		if not instance or not newCF or not nowModelControl or not nowModelControl.Value then
			if controlEvent then
				controlEvent:Disconnect()
			end
			controlEvent = nil
			if nowModelControl then
				nowModelControl.Value = false
			end
			return
		end

		instance:PivotTo(newCF)
		time += dt
	end)
end

--[[
	取消控制模型位置（帧事件控制）
	
	@param instance Model - 目标模型
--]]
function FXUtil.Uncontrol_Model_CFrame(instance: Model)
	if not instance then
		return
	end

	local modelControl = instance:FindFirstChild("ModelControl")
	if modelControl then
		modelControl.Value = false
	end
end

--[[
	控制模型位置（帧事件备用控制）
	
	@param instance Model - 目标模型
	@param func function - 返回CFrame的函数，接收时间参数
--]]
function FXUtil.Control_Model_CFrame_Standby(instance: Model, func: (number) -> CFrame)
	if not instance then
		return
	end

	if not func then
		return
	end

	local modelControl = instance:FindFirstChild("ModelControl_Standby")
	if not modelControl then
		modelControl = Instance.new("BoolValue", instance)
		modelControl.Name = "ModelControl_Standby"
		modelControl.Value = false
	end

	if modelControl.Value then
		return
	end

	modelControl.Value = true

	local _controlEvent: RBXScriptConnection? = nil
	local time = 0
	local connection: RBXScriptConnection? = nil

	connection = RunService.Heartbeat:Connect(function(dt)
		local newCF: CFrame = func(time)
		local nowModelControl = instance:FindFirstChild("ModelControl_Standby")

		if not instance or not newCF or not nowModelControl or not nowModelControl.Value then
			if connection then
				connection:Disconnect()
			end
			_controlEvent = nil
			if nowModelControl then
				nowModelControl.Value = false
			end
			return
		end

		instance:PivotTo(newCF)
		time += dt
	end)
	_controlEvent = connection
end

--[[
	取消控制模型位置（帧事件备用控制）
	
	@param instance Model - 目标模型
--]]
function FXUtil.Uncontrol_Model_CFrame_Standby(instance: Model)
	if not instance then
		return
	end

	local modelControl = instance:FindFirstChild("ModelControl_Standby")
	if modelControl then
		modelControl.Value = false
	end
end

--[[
	控制附件位置（帧事件控制）
	
	@param instance Attachment - 目标附件
	@param func function - 返回CFrame的函数，接收时间参数
--]]
function FXUtil.Control_Attachment_CFrame(instance: Attachment, func: (number) -> CFrame)
	if not instance then
		return
	end

	if not func then
		return
	end

	local modelControl = instance:FindFirstChild("ModelControl")
	if not modelControl then
		modelControl = Instance.new("BoolValue", instance)
		modelControl.Name = "ModelControl"
		modelControl.Value = false
	end

	if modelControl.Value then
		return
	end

	modelControl.Value = true

	local controlEvent: RBXScriptConnection? = nil
	local time = 0
	local connection: RBXScriptConnection? = nil

	connection = RunService.RenderStepped:Connect(function(dt)
		local newCF = func(time)
		local nowModelControl = instance:FindFirstChild("ModelControl")

		if not instance or not newCF or not nowModelControl or not nowModelControl.Value then
			if connection then
				connection:Disconnect()
			end
			controlEvent = nil
			if nowModelControl then
				nowModelControl.Value = false
			end
			return
		end

		instance.WorldCFrame = newCF
		time += dt
	end)
	controlEvent = connection
end

--[[
	取消控制附件位置（帧事件控制）
	
	@param instance Attachment - 目标附件
--]]
function FXUtil.Uncontrol_Attachment_CFrame(instance: Attachment)
	if not instance then
		return
	end

	local modelControl = instance:FindFirstChild("ModelControl")
	if modelControl then
		modelControl.Value = false
	end
end
end