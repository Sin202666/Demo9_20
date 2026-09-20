--[[
	Module: FXUtil/SkillSettle
	Description: 技能命中结算与 Hit_Effect
	Author: LinAoyu
	Created: 2024-01-01
	Last Modified: 2026-07-02
]]

return function(FXUtil)

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VisibleMgr = Utils.VisibleMgr
local SoundModule = Utils.SoundModule
local AssetPaths = Utils.AssetPaths

local DEFAULT_HIT_SOUND = "受击-通用"
local SETTLE_HIT_EFFECT_NAME = "受击效果"
local SETTLE_EFFECT_LIFETIME_SEC = 2

-- ============================================
-- 统一操作函数 (Unified Operation Functions)
-- ============================================

--[[
	统一结算技能攻击效果
	@param target Model - 目标模型
	@param hitPoint Vector3? - 命中点位置（可选）
]]
function FXUtil.Settle_Skill_Effect(target: Model, hitPoint: Vector3?)
	if not target then
		return
	end

	local template = AssetPaths.Resolve("ModelRes/Effect", AssetPaths.Scope.Shared)
	local hitTemplate = template and template:FindFirstChild(SETTLE_HIT_EFFECT_NAME)
	if not hitTemplate then
		return
	end

	local hitEffect = hitTemplate:Clone()
	hitEffect.Parent = workspace
	VisibleMgr.AnchoredAll(hitEffect)
	VisibleMgr.UnTransparencyAll(hitEffect)
	VisibleMgr.UnQueryAll(hitEffect)
	VisibleMgr.UnCollideAll(hitEffect)
	VisibleMgr.UnTouchAll(hitEffect)

	local hitPos = target:GetPivot().Position
	if hitPoint then
		hitPos = hitPoint
	end

	SoundModule:PlaySoundLocal({
		SoundName = DEFAULT_HIT_SOUND,
		Is2D = false,
		PlayPosition = hitPos,
	})

	hitEffect:PivotTo(CFrame.new(hitPos))
	FXUtil.Emit_Particles_GetDescendants(hitEffect, true)

	task.delay(SETTLE_EFFECT_LIFETIME_SEC, function()
		FXUtil.Debris(hitEffect, 0)
	end)
end

--[[
	统一结算技能攻击效果（多次）
	@param target Model - 目标模型
	@param settleTimes number - 结算次数
	@param settleDelay number? - 结算延迟（可选，默认0.1）
]]
function FXUtil.Settle_Skill_All_Effects(target: Model, settleTimes: number, settleDelay: number?)
	if not target or not settleTimes then
		return
	end

	settleDelay = settleDelay or 0.1
	for k = 1, settleTimes do
		task.delay(settleDelay * (k - 1), function()
			FXUtil.Settle_Skill_Effect(target)
		end)
	end
end

--[[
	命中效果
	@param effectName string - 特效名称
	@param cf CFrame|BasePart - 位置或部件
	@param soundName string? - 音效名称（可选）
]]
function FXUtil.Hit_Effect(effectName: string, cf: CFrame | BasePart, soundName: string?)
	soundName = soundName or DEFAULT_HIT_SOUND
	FXUtil.PlayEffect(effectName, cf, 0.3, 3)
	SoundModule:PlaySoundLocal({
		SoundName = soundName,
		Is2D = true,
	})
end

end
