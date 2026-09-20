--[[
	Module: FXUtil/ModelScale
	Description: 模型缩放与体积保护
	Author: LinAoyu
	Created: 2024-01-01
	Last Modified: 2026-07-02
]]

return function(FXUtil)

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local InsMgr = Utils.InsMgr
-- ============================================
-- 模型缩放和动画函数 (Model Scale and Animation Functions)
-- ============================================

--[[
	简单部件缩放动画
	
	@param part BasePart - 目标部件
	@param tweenTime number - 动画时间
	@param goalSize Vector3 - 目标大小
	@param easingStyle Enum.EasingStyle? - 缓动样式（可选，默认Linear）
	@param easingDir Enum.EasingDirection? - 缓动方向（可选，默认In）
--]]
function FXUtil.BasePart_Size_Tween(part: BasePart, tweenTime: number, goalSize: Vector3, easingStyle: Enum.EasingStyle?, easingDir: Enum.EasingDirection?)
	easingStyle = easingStyle or Enum.EasingStyle.Linear
	easingDir = easingDir or Enum.EasingDirection.In

	local tween = TweenService:Create(part, TweenInfo.new(tweenTime, easingStyle, easingDir), {Size = goalSize})
	tween.Completed:Connect(function()
		tween:Destroy()
		tween = nil
	end)
	tween:Play()
end
--[[
	缩放模型（递归缩放所有部件、网格、约束等）
	
	@param model Model - 目标模型
	@param scale number? - 缩放系数（可选）
	@return Model - 缩放后的模型
--]]
function FXUtil.Scale_Model(model: Model, scale: number?)
	if not scale then
		return model
	end

	for _, descendant in pairs(model:GetDescendants()) do
		-- 缩放BasePart
		if descendant:IsA("BasePart") then
			local oriSize = descendant:FindFirstChild("OriSize")
			if not oriSize then
				oriSize = InsMgr.GetIns("OriSize", "Vector3Value", descendant)
				oriSize.Value = descendant.Size
			end
			descendant.Size = oriSize.Value * scale
		end

		-- 缩放SpecialMesh
		if descendant:IsA("SpecialMesh") and descendant.MeshType == Enum.MeshType.FileMesh then
			local oriSize = descendant:FindFirstChild("OriSize")
			if not oriSize then
				oriSize = InsMgr.GetIns("OriSize", "Vector3Value", descendant)
				oriSize.Value = descendant.Scale
			end
			descendant.Scale = oriSize.Value * scale
		end

		-- 缩放Motor6D
		if descendant:IsA("Motor6D") then
			local oriC1 = descendant:FindFirstChild("OriC1")
			if not oriC1 or not oriC1:IsA("CFrameValue") then
				oriC1 = InsMgr.GetIns("OriC1", "CFrameValue", descendant)
				local c1Value = oriC1 :: CFrameValue
				c1Value.Value = descendant.C1
			end

			local oriC0 = descendant:FindFirstChild("OriC0")
			if not oriC0 or not oriC0:IsA("CFrameValue") then
				oriC0 = InsMgr.GetIns("OriC0", "CFrameValue", descendant)
				local c0Value = oriC0 :: CFrameValue
				c0Value.Value = descendant.C0
			end

			if oriC0 and oriC0:IsA("CFrameValue") and oriC1 and oriC1:IsA("CFrameValue") then
				descendant.C0 = oriC0.Value.Rotation + oriC0.Value.Position * scale
				descendant.C1 = oriC1.Value.Rotation + oriC1.Value.Position * scale
			end
		end

		-- 缩放Weld
		if descendant:IsA("Weld") then
			local oriC1 = descendant:FindFirstChild("OriC1")
			if not oriC1 or not oriC1:IsA("CFrameValue") then
				oriC1 = InsMgr.GetIns("OriC1", "CFrameValue", descendant)
				local c1Value = oriC1 :: CFrameValue
				c1Value.Value = descendant.C1
			end

			local oriC0 = descendant:FindFirstChild("OriC0")
			if not oriC0 or not oriC0:IsA("CFrameValue") then
				oriC0 = InsMgr.GetIns("OriC0", "CFrameValue", descendant)
				local c0Value = oriC0 :: CFrameValue
				c0Value.Value = descendant.C0
			end

			if oriC0 and oriC0:IsA("CFrameValue") and oriC1 and oriC1:IsA("CFrameValue") then
				descendant.C0 = oriC0.Value.Rotation + oriC0.Value.Position * scale
				descendant.C1 = oriC1.Value.Rotation + oriC1.Value.Position * scale
			end
		end

		-- 缩放Attachment
		if descendant:IsA("Attachment") then
			local oriPos = descendant:FindFirstChild("OriPos")
			if not oriPos then
				oriPos = InsMgr.GetIns("OriPos", "Vector3Value", descendant)
				oriPos.Value = descendant.CFrame.Position
			end
			if oriPos then
				descendant.Position = oriPos.Value * scale
			end
		end

		-- WeldConstraint处理（已注释，保留代码）
		-- if descendant:IsA("WeldConstraint") then
		-- 	-- 处理逻辑已注释
		-- end
	end

	model:SetAttribute("Scale", scale)
	return model
end

--[[
	模型缩放动画（使用Scale_Model方法）
	
	@param model Model - 目标模型
	@param tweenTime number - 动画时间
	@param scale number - 目标缩放系数
	@param easingStyle Enum.EasingStyle? - 缓动样式（可选）
	@param easingDir Enum.EasingDirection? - 缓动方向（可选）
	@param canMove boolean? - 是否允许移动（可选，默认false）
--]]
function FXUtil.Scale_Model_Tween(model: Model, tweenTime: number, scale: number, easingStyle: Enum.EasingStyle?, easingDir: Enum.EasingDirection?, canMove: boolean?)
	task.spawn(function()
		local oriCFrame = model:GetPivot()

		if not model:GetAttribute("Scale") then
			model:SetAttribute("Scale", 1)
		end

		local modelScale = model:GetAttribute("Scale")
		local timeline = 0
		local _lastTweenPoint = 0

		while timeline < 1 do
			timeline = math.min(timeline + RunService.Heartbeat:Wait() / tweenTime, 1)
			local tweenPoint = TweenService:GetValue(timeline, easingStyle, easingDir)
			FXUtil.Scale_Model(model, (tweenPoint * (scale - modelScale) + modelScale))

			-- 如果不允许移动，保持原始位置
			if not canMove then
				model:PivotTo(oriCFrame)
			end
			_lastTweenPoint = tweenPoint
		end
	end)
end

--[[
	直接缩放模型（使用ScaleTo方法）
	
	@param model Model - 目标模型
	@param scale number - 缩放系数
--]]
function FXUtil.Set_Scale_Model(model: Model, scale: number)
	if model:IsA("Model") then
		local oriScale = model:GetAttribute("ModelScale")
		if not oriScale then
			model:SetAttribute("ModelScale", model:GetScale())
			oriScale = model:GetScale()
		end

		local newScale = oriScale * scale
		model:SetAttribute("Scale", scale)
		model:ScaleTo(newScale)
	end
end

--[[
	直接缩放模型动画（使用Set_Scale_Model方法）
	
	@param model Model - 目标模型
	@param tweenTime number - 动画时间
	@param scale number - 目标缩放系数
	@param easingStyle Enum.EasingStyle? - 缓动样式（可选，默认Linear）
	@param easingDir Enum.EasingDirection? - 缓动方向（可选，默认In）
	@param canMove boolean? - 是否允许移动（可选，默认false）
--]]
function FXUtil.Set_Scale_Model_Tween(model: Model, tweenTime: number, scale: number, easingStyle: Enum.EasingStyle?, easingDir: Enum.EasingDirection?, canMove: boolean?)
	task.spawn(function()
		easingStyle = easingStyle or Enum.EasingStyle.Linear
		easingDir = easingDir or Enum.EasingDirection.In

		local oriCFrame = model:GetPivot()
		local oriScale = model:GetAttribute("ModelScale")
		if not oriScale then
			model:SetAttribute("ModelScale", model:GetScale())
			oriScale = model:GetScale()
		end

		if not model:GetAttribute("Scale") then
			model:SetAttribute("Scale", 1)
		end

		local nowScale = model:GetAttribute("Scale")
		local timeline = 0
		local _lastTweenPoint = 0

		while timeline < 1 do
			timeline = math.min(timeline + RunService.Heartbeat:Wait() / tweenTime, 1)
			local tweenPoint = TweenService:GetValue(timeline, easingStyle, easingDir)
			FXUtil.Set_Scale_Model(model, (nowScale + (scale - nowScale) * tweenPoint))

			if not canMove then
				model:PivotTo(oriCFrame)
			end
			_lastTweenPoint = tweenPoint
		end
	end)
end

--[[
	直接缩放BasePart
	
	@param part BasePart - 目标部件
	@param scale number - 缩放系数
	@param isChangeAttachment boolean? - 是否同时缩放Attachment（可选）
--]]
function FXUtil.Set_Scale_Basepart(part: BasePart, scale: number, isChangeAttachment: boolean?)
	if part:IsA("BasePart") then
		local oriScale = part:GetAttribute("OriSize")
		if not oriScale then
			part:SetAttribute("OriSize", part.Size)
			oriScale = part.Size
		end

		local newScale = oriScale * scale
		part:SetAttribute("Scale", scale)
		part.Size = newScale

		-- 如果需要，同时缩放Attachment
		if isChangeAttachment then
			for _, child in pairs(part:GetChildren()) do
				if child:IsA("Attachment") then
					local oriPos = child:GetAttribute("OriPos")
					if not oriPos then
						child:SetAttribute("OriPos", child.CFrame.Position)
						oriPos = child.CFrame.Position
					end

					local newPos = oriPos * scale
					child.CFrame = child.CFrame.Rotation + newPos
				end
			end
		end
	end
end

--[[
	直接缩放BasePart动画
	
	@param part BasePart - 目标部件
	@param tweenTime number - 动画时间
	@param scale number - 目标缩放系数
	@param easingStyle Enum.EasingStyle? - 缓动样式（可选）
	@param easingDir Enum.EasingDirection? - 缓动方向（可选）
	@param canMove boolean? - 是否允许移动（可选，默认false）
	@param isChangeAttachment boolean? - 是否同时缩放Attachment（可选）
--]]
function FXUtil.Set_Scale_Basepart_Tween(part: BasePart, tweenTime: number, scale: number, easingStyle: Enum.EasingStyle?, easingDir: Enum.EasingDirection?, canMove: boolean?, isChangeAttachment: boolean?)
	task.spawn(function()
		local oriCFrame = part:GetPivot()

		if not part:GetAttribute("OriSize") then
			part:SetAttribute("OriSize", part.Size)
		end

		if not part:GetAttribute("Scale") then
			part:SetAttribute("Scale", 1)
		end

		local nowScale = part:GetAttribute("Scale")
		local timeline = 0
		local _lastTweenPoint = 0

		while timeline < 1 do
			timeline = math.min(timeline + RunService.Heartbeat:Wait() / tweenTime, 1)
			local tweenPoint = TweenService:GetValue(timeline, easingStyle, easingDir)
			FXUtil.Set_Scale_Basepart(part, (tweenPoint * (scale - nowScale) + nowScale), isChangeAttachment)

			if not canMove then
				part:PivotTo(oriCFrame)
			end
			_lastTweenPoint = tweenPoint
		end
	end)
end

-- ============================================
-- 模型体积保护函数 (Model Volume Protection)
-- ============================================

--[[
	计算模型的体积（立方米）
	
	@param model Model - 目标模型
	@return number - 模型的体积（立方米）
--]]
function FXUtil.Get_Model_Volume(model: Model): number
	if not model or not model:IsA("Model") then
		return 0
	end

	local cf, size = model:GetBoundingBox()
	if not size then
		return 0
	end

	-- 计算体积：长 × 宽 × 高
	return size.X * size.Y * size.Z
end

--[[
	保护模型体积：如果模型体积超过安全值，则缩放至安全值内
	
	@param model Model - 目标模型
	@param maxVolume number - 最大安全体积（立方米），例如 1、0.5、1
	@return boolean - 是否进行了缩放
--]]
function FXUtil.Protect_Model_Volume(model: Model, maxVolume: number): boolean
	if not model or not model:IsA("Model") then
		return false
	end

	if not maxVolume or maxVolume <= 0 then
		warn("FXUtil.Protect_Model_Volume: maxVolume 必须大于 0")
		return false
	end

	local currentVolume = FXUtil.Get_Model_Volume(model)
	if currentVolume <= 0 then
		return false
	end

	-- 如果体积小于等于安全值，不需要缩放
	if currentVolume <= maxVolume then
		return false
	end

	-- 计算需要的缩放系数
	-- 体积缩放 = 尺寸缩放的立方，所以：scale^3 = maxVolume / currentVolume
	-- scale = (maxVolume / currentVolume)^(1/3)
	local scale = math.pow(maxVolume / currentVolume, 1/3)

	-- 使用 ScaleTo 方法设置模型缩放
	-- 获取原始缩放值（如果不存在则保存当前缩放）
	local oriScale = model:GetAttribute("ModelScale")
	if not oriScale then
		model:SetAttribute("ModelScale", model:GetScale())
		oriScale = model:GetScale()
	end

	-- 计算新的缩放值
	local newScale = oriScale * scale
	model:SetAttribute("Scale", scale)
	model:ScaleTo(newScale)

	return true
end
end