--[[
	Module: FXUtil/PlayEffectPrep
	Description: PlayEffect 预处理与挂身焊接公共 API
	Author: LinAoyu
	Created: 2024-01-01
	Last Modified: 2026-07-02
]]

return function(FXUtil)

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local VisibleMgr = Utils.VisibleMgr
local PlayEffectInternal = require(script.Parent.PlayEffectInternal)

PlayEffectInternal.setup(FXUtil, VisibleMgr)

--[[ 通用：世界播特效前的 Part/粒子物理与可见性预处理（无业务语义）。]]
function FXUtil.PrepEffectForWorldShared(effect: Instance, usePoolModel: boolean)
	PlayEffectInternal.prepEffectModelForWorldShared(effect, usePoolModel)
end

--[[ 通用：挂身特效 Model 用 WeldConstraint 焊到世界 BasePart（如 HRP）。]]
function FXUtil.WeldFxModelToBasePart(fx: Model, worldPart: BasePart, pivotOffset: CFrame?): boolean
	VisibleMgr.UnAnchoredAll(fx)
	PlayEffectInternal.destroyFxWeldConstraintsRecursive(fx)
	local baseCf = worldPart:GetPivot()
	if pivotOffset then
		baseCf = baseCf * pivotOffset
	end
	local p0: BasePart? = fx.PrimaryPart
	if not p0 or not p0:IsA("BasePart") then
		p0 = fx:FindFirstChildWhichIsA("BasePart", true)
	end
	if not p0 then
		return false
	end
	if fx.PrimaryPart ~= p0 then
		fx.PrimaryPart = p0
	end
	fx:PivotTo(baseCf)
	local weld = Instance.new("WeldConstraint", fx)
	weld.Part0 = p0
	weld.Part1 = worldPart
	return true
end

function FXUtil.CloneModelResEffectModel(effectName: string): Model?
	return PlayEffectInternal.cloneModelResEffectModel(effectName)
end

end
