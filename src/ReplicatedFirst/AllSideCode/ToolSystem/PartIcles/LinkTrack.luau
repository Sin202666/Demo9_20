--[[
	Module: LinkTrack
	Description: Mixin：每帧把 Part / Model / Attachment 的 link 变换写回视觉件
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-09-01

	功能：
	- ReapplyLink：在 Heartbeat 步进门之外每帧跟踪 link（pData._localWorldCF 由 Update 各路径缓存）

	模块关系：
	- Attachment 在 actualParent 局部空间合成，对齐 Update.luau 的 getAttachmentLinkCF
	- LinkMode：Weld / WeldWithoutRotation / Follow / Pivot / RigidLocal
	- RigidLocal 用发射时快照 _rigidLocalParentCF，忽略 live link 运动
	- link 中途销毁则清空 pData.Link，下一帧改自由飞行，避免无 PrimaryPart 的 Model:GetPivot 抛错

	加载方式：
		require(script.Parent.LinkTrack)(Particle)

	使用示例：
		Particle:ReapplyLink(pData)
]]

local Constants = require(script.Parent.PartConstants)

return function(Particle)

--[[
	把缓存的 link 相对 CFrame 合成到当前 link 目标并写入 VisualPart。
	pData.Link 为 nil 或已销毁时 no-op。

	@param pData table - 粒子运行时；字段 Link / LinkMode / _localWorldCF / VisualPart / Type / _rigidLocalParentCF
]]
function Particle:ReapplyLink(pData)
	local link = pData.Link
	if not link then return end
	-- Detect mid-flight link destruction: drop pData.Link so the next frame
	-- falls back to free-flying physics instead of freezing on the link's
	-- last CFrame (and avoiding a Model:GetPivot throw on a destroyed model
	-- with no PrimaryPart).
	if not link.Parent then
		pData.Link = nil
		return
	end
	local lcf = pData._localWorldCF
	if not lcf then return end
	if not pData.VisualPart or not pData.VisualPart.Parent then return end
	local t = pData.Type
	if t ~= "Part" and t ~= "Model" and t ~= "Attachment" then return end

	if t == "Attachment" then
		local visualParent = pData.VisualPart.Parent
		if not visualParent then return end
		-- RigidLocal: per-frame parent CFrame stays frozen at the emit-time snapshot
		-- (world space). Live link motion is intentionally ignored.
		local linkWorldCF = (pData.LinkMode == "RigidLocal")
			and (pData._rigidLocalParentCF or CFrame.new())
			or Constants.resolveLinkCFrame(link)
		local convCF = visualParent:IsA("BasePart") and visualParent.CFrame or CFrame.new()
		local linkLocalCF = convCF:ToObjectSpace(linkWorldCF)
		local parentCF_now
		if pData.LinkMode == "Follow" or pData.LinkMode == "Pivot" then
			parentCF_now = CFrame.new(linkLocalCF.Position)
		else
			parentCF_now = linkLocalCF
		end
		pData.VisualPart.CFrame = parentCF_now * lcf
		return
	end

	-- RigidLocal: read the at-emit snapshot, not the live link. lcf composes against
	-- the frozen frame so the particle behaves like Weld-then-released.
	local linkCF = (pData.LinkMode == "RigidLocal")
		and (pData._rigidLocalParentCF or CFrame.new())
		or Constants.resolveLinkCFrame(link)
	local linkPos = linkCF.Position

	local lm = pData.LinkMode
	local newCF
	if lm == "WeldWithoutRotation" then
		-- Offset rotates with link, mesh rotation stays independent.
		local worldOffset = linkCF:VectorToWorldSpace(lcf.Position)
		local rotOnly = lcf - lcf.Position
		newCF = CFrame.new(linkPos + worldOffset) * rotOnly
	elseif lm == "Follow" or lm == "Pivot" then
		newCF = CFrame.new(linkPos) * lcf
	else -- Weld
		newCF = linkCF * lcf
	end

	if t == "Model" then
		pData.VisualPart:PivotTo(newCF)
	else
		pData.VisualPart.CFrame = newCF
	end
end

end
