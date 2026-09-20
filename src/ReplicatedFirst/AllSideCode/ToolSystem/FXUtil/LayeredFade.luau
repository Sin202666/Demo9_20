--[[
	Module: FXUtil/LayeredFade
	Description: 分层消失（保留 Trail）
	Author: LinAoyu
	Created: 2024-01-01
	Last Modified: 2026-07-02
]]

return function(FXUtil)

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
-- ============================================
-- 模型分层消失 (Layered Model Fade)
-- ============================================

--[[
	模型消失但保留 Trail：BasePart 立刻透明、粒子关断、Beam 渐隐，但 Trail 保留。
	适用于弹道类命中后需要保留尾迹的场景。
	@param model Instance 要消失的模型
	@param beamFadeTime number? Beam 渐隐时长，默认 0.12
	@param destroyAfter number? 延迟销毁时长，默认 0.5；传 0 则不自动销毁
]]
function FXUtil.FadeModel_KeepTrails(model: Instance, beamFadeTime: number?, destroyAfter: number?)
	local bft = beamFadeTime or 0.12
	local delayDest = destroyAfter or 0.5

	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Transparency = 1
		elseif d:IsA("ParticleEmitter") then
			d.Enabled = false
		elseif d:IsA("Beam") then
			FXUtil.Beam_Fade_To_Transparent_Then_Disable(d, bft, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		elseif d:IsA("Decal") or d:IsA("Texture") then
			d.Transparency = 1
		end
	end

	if delayDest > 0 then
		task.delay(delayDest, function()
			if model.Parent then
				model:Destroy()
			end
		end)
	end
end
end