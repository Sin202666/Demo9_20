--[[
	Module: FXUtil/PlayEffectInternal
	Description: PlayEffect / DoT 挂身 FX 共用内部工具（非 FXUtil 公共 API）
	Author: LinAoyu
	Created: 2024-01-01
	Last Modified: 2026-09-01
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local AssetPaths = Utils.AssetPaths

local PlayEffectInternal = {}

export type FxEmitCache = {
	emitters: { ParticleEmitter },
	beams: { Beam },
}

-- 与 VisibleMgr 对象池 Init* 快照同名，归还时 RestoreDefaultVisualState 才能还原
local ATTR_INIT_TRANSPARENCY = "InitTransparency"
local ATTR_INIT_ENABLED = "InitEnabled"
local FULLY_TRANSPARENT = 1

local _fxUtil = nil

--[[
	注入 FXUtil 引用（由 PlayEffectPrep 加载时调用一次；visibleMgr 保留签名兼容）
	@param fxUtil table - FXUtil 模块表
	@param _visibleMgr table - 历史参数，prep 已改为单次扫树，不再使用
]]
function PlayEffectInternal.setup(fxUtil: any, _visibleMgr: any)
	_fxUtil = fxUtil
end

--[[
	首次入池播放前记下 Transparency / Enabled，供归还时 RestoreDefaultVisualState
	@param inst Instance - BasePart 写 InitTransparency；粒子 / Trail / Beam 写 InitEnabled
	@return nil
]]
local function _snapshotInitVisualIfMissing(inst: Instance)
	if inst:IsA("BasePart") then
		if inst:GetAttribute(ATTR_INIT_TRANSPARENCY) == nil then
			inst:SetAttribute(ATTR_INIT_TRANSPARENCY, inst.Transparency)
		end
		return
	end
	if inst:IsA("ParticleEmitter") or inst:IsA("Trail") or inst:IsA("Beam") then
		if inst:GetAttribute(ATTR_INIT_ENABLED) == nil then
			inst:SetAttribute(ATTR_INIT_ENABLED, inst.Enabled)
		end
	end
end

--[[
	世界播特效 Part 标志：锚定、无查询/碰撞/触摸、无质量；池化实例再藏网格
	@param part BasePart - 目标部件
	@param hideParts boolean - true 时先快照再设为全透明
	@return nil
]]
local function _applyWorldPartFlags(part: BasePart, hideParts: boolean)
	part.Anchored = true
	part.CanQuery = false
	part.CanCollide = false
	part.CanTouch = false
	part.Massless = true
	if hideParts then
		_snapshotInitVisualIfMissing(part)
		part.Transparency = FULLY_TRANSPARENT
	end
end

--[[
	PlayEffect / DoT 共用：一次扫子树完成物理预处理，并缓存 ParticleEmitter / Beam
	@param effect Instance - 特效根
	@param usePoolModel boolean - 池化实例藏网格并补 Init* 快照
	@return FxEmitCache - 供同一次播放直接 Emit，避免再 GetDescendants
]]
function PlayEffectInternal.prepEffectModelForWorldShared(effect: Instance, usePoolModel: boolean): FxEmitCache
	local emitters: { ParticleEmitter } = {}
	local beams: { Beam } = {}

	local function visit(inst: Instance)
		if inst:IsA("BasePart") then
			_applyWorldPartFlags(inst, usePoolModel)
			return
		end
		if inst:IsA("ParticleEmitter") then
			if usePoolModel then
				_snapshotInitVisualIfMissing(inst)
			end
			table.insert(emitters, inst)
			return
		end
		if inst:IsA("Beam") then
			if usePoolModel then
				_snapshotInitVisualIfMissing(inst)
			end
			table.insert(beams, inst)
			return
		end
		if usePoolModel and inst:IsA("Trail") then
			_snapshotInitVisualIfMissing(inst)
		end
	end

	visit(effect)
	for _, descendant in effect:GetDescendants() do
		visit(descendant)
	end

	return {
		emitters = emitters,
		beams = beams,
	}
end

--[[
	摘除挂身 WeldConstraint，避免对象池归还后残留跨目标焊接
	@param root Instance
]]
function PlayEffectInternal.destroyFxWeldConstraintsRecursive(root: Instance)
	local descendants = root:GetDescendants()
	for i = #descendants, 1, -1 do
		local d = descendants[i]
		if d and d:IsA("WeldConstraint") then
			d:Destroy()
		end
	end
end

--[[
	对象池 VFX 停播并归还
	@param effect Instance
]]
function PlayEffectInternal.stopPooledVfxAndRecycle(effect: Instance)
	_fxUtil.Stop_All_Emit(effect)
	_fxUtil.SetEmittersTrailsBeamsEnabled(effect, false)
	_fxUtil.Stop_All_Particles(effect)
	_fxUtil.BackPool_Instance(effect)
end

--[[
	克隆 Assets/ModelRes/Effect 下同名 Model
	@param effectName string - 特效 Model 名称
	@return Model? - 克隆体；模板不存在或非 Model 时为 nil
]]
function PlayEffectInternal.cloneModelResEffectModel(effectName: string): Model?
	if type(effectName) ~= "string" or effectName == "" then
		return nil
	end
	local template = AssetPaths.Resolve("ModelRes/Effect/" .. effectName, AssetPaths.Scope.Shared)
	if not template or not template:IsA("Model") then
		return nil
	end
	return template:Clone() :: Model
end

return PlayEffectInternal
