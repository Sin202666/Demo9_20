--[[
	Module: ZOffset
	Description: Mixin：沿粒子→相机方向做逐帧位移（Part / Model / Attachment）
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-09-01

	功能：
	- ApplyZOffset：正值更靠近相机；在 Orientation 之后跑，速度推导仍用偏移前位置

	模块关系：
	- 由 Particles / Engine 混入 Particle；读 pData._postUpdateCF，避免叠加上一帧 overlay
	- Attachment.CFrame 是父级局部，先转世界再写回
	- 不写权威伤害/掉落；仅表现层 CFrame / PivotTo

	加载方式：
		require(script.Parent.ZOffset)(Particle)

	使用示例：
		Particle:ApplyZOffset(pData, camera.CFrame.Position)
]]

return function(Particle)

local EPS = 1e-3

--[[
	按 ZOffset 沿粒子→相机方向平移视觉件。无偏移、无相机或非 Part/Model/Attachment 时早退。

	@param pData table - 粒子运行时；字段 ZOffset / VisualPart / Type / _postUpdateCF
	@param camPos Vector3? - 相机世界坐标；nil 时不位移
]]
function Particle:ApplyZOffset(pData, camPos)
	local zo = pData.ZOffset
	if not zo or zo == 0 then return end
	if not camPos then return end
	if not pData.VisualPart or not pData.VisualPart.Parent then return end
	local t = pData.Type
	if t ~= "Part" and t ~= "Model" and t ~= "Attachment" then return end

	local isModel = t == "Model"
	local isAttachment = t == "Attachment"
	-- Use the pre-overlay base CFrame so ZOffset is an absolute shift; reading live would compound each frame.
	local currentCF = pData._postUpdateCF or (isModel and pData.VisualPart:GetPivot() or pData.VisualPart.CFrame)

	-- Attachment.CFrame is parent-local; convert to world for the camera shift, back to local on write.
	local parentPart
	if isAttachment then
		parentPart = pData.VisualPart.Parent
		if parentPart and parentPart:IsA("BasePart") then
			currentCF = parentPart.CFrame * currentCF
		else
			parentPart = nil
		end
	end

	local pos = currentCF.Position
	local toCam = camPos - pos
	local mag = toCam.Magnitude
	if mag < EPS then return end
	local newPos = pos + (toCam / mag) * zo
	local newCF = CFrame.new(newPos) * (currentCF - pos)

	if parentPart then
		newCF = parentPart.CFrame:ToObjectSpace(newCF)
	end

	if isModel then
		pData.VisualPart:PivotTo(newCF)
	else
		pData.VisualPart.CFrame = newCF
	end
end

end
