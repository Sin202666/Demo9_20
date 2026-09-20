--[[
	Module: FXUtil/TweenUtil
	Description: 通用 Tween 与 Beam/抛物线动画
	Author: LinAoyu
	Created: 2024-01-01
	Last Modified: 2026-07-02
]]

return function(FXUtil)

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
--[[
	传入两个Attachment 控制这两个Attachment的CFrame从CFrame.new(0,0,0)到offset位置在时间轴上进行插值，使用TweenService进行插值
	@param attachment1 Attachment - 附件1
	@param attachment2 Attachment - 附件2
	@param offset Vector3 - 偏移
	@param time number - 时间
]]
function FXUtil.Tween_Attachment_CFrame(attachment1: Attachment, attachment2: Attachment, time: number,offset: Vector3, easingStyle: Enum.EasingStyle?, easingDir: Enum.EasingDirection?)
	if not attachment1 or not attachment2 then
		return
	end
	attachment1.CFrame = CFrame.new(0,0,0)
	attachment2.CFrame = CFrame.new(0,0,0)

	easingStyle = easingStyle or Enum.EasingStyle.Linear
	easingDir = easingDir or Enum.EasingDirection.In

	local tween1 = TweenService:Create(attachment1, TweenInfo.new(time, easingStyle, easingDir), {CFrame = CFrame.new(offset)})
	tween1.Completed:Once(function()
		if tween1 then
			tween1:Destroy()
		end
	end)
	tween1:Play()
	local tween2 = TweenService:Create(attachment2, TweenInfo.new(time, easingStyle, easingDir), {CFrame = CFrame.new(-offset)})
	tween2.Completed:Once(function()
		if tween2 then
			tween2:Destroy()
		end
	end)
	tween2:Play()

end

--[[
	对传入的实例进行Tween动画 
	@param instance Instance - 实例
	@tweenInfo TweenInfo - 动画信息
]]
function FXUtil.Tween_Instance(instance: Instance, tweenInfo: TweenInfo, properties: {[string]: any})
	if not instance then
		return
	end

	local tween = TweenService:Create(instance, tweenInfo, properties)
	tween.Completed:Once(function()
		if tween then
			tween:Destroy()
		end
	end)
	tween:Play()
end

--[[
	模型缩放动画（从初始尺寸变换到最终尺寸，完成后调用回调）
	
	@param model Model - 目标模型
	@param startScale number - 初始缩放系数
	@param endScale number - 最终缩放系数
	@param tweenTime number - 变换时间（秒）
	@param easingStyle Enum.EasingStyle? - 变换曲线（可选，默认 Linear）
	@param easingDir Enum.EasingDirection? - 变换方向（可选，默认 In）
	@param callback (() -> ())? - 完成回调（可选）
	@param canMove boolean? - 是否允许外部控制位置（true=不覆盖 Pivot，用于与 BezierCurve 等配合；false=每帧固定位置，默认）
--]]
function FXUtil.Model_Scale_Tween(model: Model, startScale: number, endScale: number, tweenTime: number, easingStyle: Enum.EasingStyle?, easingDir: Enum.EasingDirection?, callback: (() -> ())?, canMove: boolean?)
	task.spawn(function()
		easingStyle = easingStyle or Enum.EasingStyle.Linear
		easingDir = easingDir or Enum.EasingDirection.In

		-- 确保模型有原始缩放记录
		if not model:GetAttribute("ModelScale") then
			model:SetAttribute("ModelScale", model:GetScale())
		end

		-- 先设为初始尺寸
		model:ScaleTo(startScale)
		--FXUtil.Set_Scale_Model(model, startScale)

		local oriCFrame = model:GetPivot()
		local timeline = 0

		while timeline < 1 do
			timeline = math.min(timeline + RunService.Heartbeat:Wait() / tweenTime, 1)
			local tweenPoint = TweenService:GetValue(timeline, easingStyle, easingDir)
			local currentScale = startScale + (endScale - startScale) * tweenPoint
			--FXUtil.Set_Scale_Model(model, currentScale)
			model:ScaleTo(currentScale)
			-- 仅当不允许移动时固定位置，避免覆盖 BezierCurve 等外部位置控制
			if not canMove then
				model:PivotTo(oriCFrame)
			end
		end

		if callback then
			callback()
		end
	end)
end

--[[
	Part 缩放动画（从初始尺寸变换到最终尺寸，以 Part 的初始 Size 为基准，完成后调用回调）
	
	@param part BasePart - 目标部件
	@param startScale number - 初始缩放系数
	@param endScale number - 最终缩放系数
	@param tweenTime number - 变换时间（秒）
	@param easingStyle Enum.EasingStyle? - 变换曲线（可选，默认 Linear）
	@param easingDir Enum.EasingDirection? - 变换方向（可选，默认 In）
	@param callback (() -> ())? - 完成回调（可选）
	@param isChangeAttachment boolean? - 是否同时缩放 Attachment（可选，默认 false）
--]]
function FXUtil.Part_Scale_Tween(part: BasePart, startScale: number, endScale: number, tweenTime: number, easingStyle: Enum.EasingStyle?, easingDir: Enum.EasingDirection?, callback: (() -> ())?)
	task.spawn(function()
		easingStyle = easingStyle or Enum.EasingStyle.Linear
		easingDir = easingDir or Enum.EasingDirection.In

		-- 以 Part 的初始尺寸为基准
		local baseSize = part.Size
		part:SetAttribute("OriSize", baseSize)

		-- 先设为初始尺寸
		--FXUtil.Set_Scale_Basepart(part, startScale, isChangeAttachment)
		part.Size = startScale * baseSize

		local oriCFrame = part:GetPivot()
		local timeline = 0

		while timeline < 1 do
			timeline = math.min(timeline + RunService.Heartbeat:Wait() / tweenTime, 1)
			local tweenPoint = TweenService:GetValue(timeline, easingStyle, easingDir)
			local currentScale = startScale + (endScale - startScale) * tweenPoint
			part.Size = currentScale * baseSize
			--FXUtil.Set_Scale_Basepart(part, currentScale, isChangeAttachment)

		end

		if callback then
			callback()
		end
	end)
end

--[[
	Beam 对象渐隐至完全透明，完成后禁用并恢复原始透明度
	
	@param beam Beam - 目标 Beam 对象
	@param tweenTime number - 动画时长（秒）
	@param easingStyle Enum.EasingStyle? - 变化曲线（可选，默认 Linear）
	@param easingDir Enum.EasingDirection? - 变化方向（可选，默认 In）
--]]
function FXUtil.Beam_Fade_To_Transparent_Then_Disable(beam: Beam, tweenTime: number, easingStyle: Enum.EasingStyle?, easingDir: Enum.EasingDirection?)
	task.spawn(function()
		easingStyle = easingStyle or Enum.EasingStyle.Linear
		easingDir = easingDir or Enum.EasingDirection.In

		local oriTrans = beam.Transparency.Keypoints
		local oriTransparency = beam.Transparency
		local timeline = 0

		while timeline < 1 do
			timeline = math.min(timeline + RunService.Heartbeat:Wait() / tweenTime, 1)
			local tweenPoint = TweenService:GetValue(timeline, easingStyle, easingDir)

			local newTemp: {NumberSequenceKeypoint} = {}
			for _, keypoint in ipairs(oriTrans) do
				local oriValue = keypoint.Value
				local newValue = oriValue + (1 - oriValue) * tweenPoint
				table.insert(newTemp, NumberSequenceKeypoint.new(keypoint.Time, newValue, keypoint.Envelope or 0))
			end

			if #newTemp > 0 and beam.Parent then
				beam.Transparency = NumberSequence.new(newTemp)
			end
		end

		if beam.Parent then
			beam.Enabled = false
			beam.Transparency = oriTransparency
		end
	end)
end

--[[
	Beam 对象从完全透明渐显至原始透明度
	
	先将 Beam 设为完全透明，再在指定时间内按指定曲线逐渐恢复到开始时的透明度
	
	@param beam Beam - 目标 Beam 对象
	@param tweenTime number - 动画时长（秒）
	@param easingStyle Enum.EasingStyle? - 变化曲线（可选，默认 Linear）
	@param easingDir Enum.EasingDirection? - 变化方向（可选，默认 In）
--]]
function FXUtil.Beam_Fade_From_Transparent(beam: Beam, tweenTime: number, easingStyle: Enum.EasingStyle?, easingDir: Enum.EasingDirection?)
	task.spawn(function()
		easingStyle = easingStyle or Enum.EasingStyle.Linear
		easingDir = easingDir or Enum.EasingDirection.In

		local oriTrans = beam.Transparency.Keypoints
		local timeline = 0

		-- 先将 Beam 设为完全透明
		local fullTransparentKeypoints: {NumberSequenceKeypoint} = {}
		for _, keypoint in ipairs(oriTrans) do
			table.insert(fullTransparentKeypoints, NumberSequenceKeypoint.new(keypoint.Time, 1, keypoint.Envelope or 0))
		end
		if #fullTransparentKeypoints > 0 and beam.Parent then
			beam.Transparency = NumberSequence.new(fullTransparentKeypoints)
		end

		while timeline < 1 do
			timeline = math.min(timeline + RunService.Heartbeat:Wait() / tweenTime, 1)
			local tweenPoint = TweenService:GetValue(timeline, easingStyle, easingDir)

			local newTemp: {NumberSequenceKeypoint} = {}
			for _, keypoint in ipairs(oriTrans) do
				local oriValue = keypoint.Value
				-- 从 1（透明）插值到 oriValue（原始）
				local newValue = 1 + (oriValue - 1) * tweenPoint
				table.insert(newTemp, NumberSequenceKeypoint.new(keypoint.Time, newValue, keypoint.Envelope or 0))
			end

			if #newTemp > 0 and beam.Parent then
				beam.Transparency = NumberSequence.new(newTemp)
			end
		end
	end)
end



--[[
	设置滤镜 ColorCorrection（无动画）。与关键帧 Tween / Reset 共用快照与临时实例状态。
--[[
	模型沿抛物线运动并同时缩放（Heartbeat 驱动，与 Set_CFrame_Model_Tween / Model_Scale_Tween 相同风格）
	
	轨迹：起点到终点的直线插值，再叠加 arcVector * (4*t*(1-t))，在 t=0.5 时偏移最大（与直线中点相对）。
	
	@param model Model - 目标模型
	@param tweenTime number - 时长（秒）
	@param startCF CFrame - 起始 Pivot
	@param endCF CFrame - 结束 Pivot
	@param arcVector Vector3? - 抛物线隆起方向与幅度（默认：世界向上，高度为弦长的 0.25，至少 1）
	@param startScale number - 起始缩放系数
	@param endScale number - 结束缩放系数
	@param easingStyle Enum.EasingStyle? - 时间与缩放曲线（默认 Linear）
	@param easingDir Enum.EasingDirection? - 缓动方向（默认 In）
	@param callback (() -> ())? - 完成回调
	@param canMove boolean? - true 时只改缩放、不写入 Pivot（与 Model_Scale_Tween 一致，便于外部控位）；false/nil 时沿抛物线更新 Pivot
--]]
function FXUtil.Model_Parabola_Scale_Tween(
	model: Model,
	tweenTime: number,
	endCF: CFrame,
	arcVector: Vector3?,
	endScale: number,
	easingStyle: Enum.EasingStyle?,
	easingDir: Enum.EasingDirection?,
	callback: (() -> ())?
)
	if not model then
		return
	end

	task.spawn(function()
		easingStyle = easingStyle or Enum.EasingStyle.Linear
		easingDir = easingDir or Enum.EasingDirection.In

		local startCF = model:GetPivot()
		local startPos = startCF.Position
		local endPos = endCF.Position
		local chord = endPos - startPos
		local arc = arcVector

		local startScale = model:GetScale()

		local timeline = 0
		while timeline < 1 do
			timeline = math.min(timeline + RunService.Heartbeat:Wait() / tweenTime, 1)
			local t = TweenService:GetValue(timeline, easingStyle, easingDir)
			local arcWeight = 4 * t * (1 - t)
			local linearPos = startPos:Lerp(endPos, t)
			local newPos = linearPos + arc * arcWeight
			local midCF = startCF:Lerp(endCF, t)
			local newCF = midCF + (newPos - midCF.Position)

			if endScale then
				local currentScale = startScale + (endScale - startScale) * t
				model:ScaleTo(currentScale)
			end


			model:PivotTo(newCF)
		end

		if callback then
			callback()
		end
	end)
end
end