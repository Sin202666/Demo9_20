--[[
	Module: FXUtil/ObjectPool
	Description: 特效对象池借还
	Author: LinAoyu
	Created: 2024-01-01
	Last Modified: 2026-07-02
]]

return function(FXUtil)

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local ObjectPoolUtil = Utils.ObjectPoolUtil
local VisibleMgr = Utils.VisibleMgr
-- ============================================
-- 对象池相关函数 (Object Pool Functions)
-- ============================================

--[[
	从对象池获取对象
	
	@param instance Instance|string - 对象模板或名称
	@return Instance? - 从对象池获取的对象
--]]
function FXUtil.GetInstance_From_Pool(instance)
	return ObjectPoolUtil.getObjectFromPool(instance)
end

--[[
	将对象返回对象池
	
	@param instance Instance - 要返回的对象
--]]
function FXUtil.BackPool_Instance(instance)
	if instance and instance:IsA("Model") then
		FXUtil.ResetPooledModelBeforeBackPool(instance :: Model)
	end
	ObjectPoolUtil.backToPool(instance)
end

--[[
	对象池实例借出前：对齐模板默认态快照、停播粒子、恢复 Init* 默认视觉、ScaleTo(1)。
	@param model Model - 池实例
	@param template Model? - 资源模板（用于 Sync Init*；省略则仅 Restore 已有快照）
]]
function FXUtil.PreparePooledModelForReuse(model: Model, template: Model?)
	if not model or not model:IsA("Model") then
		return
	end
	if template then
		VisibleMgr.SyncDefaultVisualSnapshotFromTemplate(model, template)
	else
		VisibleMgr.SnapshotDefaultVisualState(model)
	end
	FXUtil.Stop_All_Emit(model)
	VisibleMgr.RestoreDefaultVisualState(model)
	model:ScaleTo(1)
end

--[[
	对象池归还前：停播/关 FX，恢复默认视觉，ScaleTo(1)。
]]
function FXUtil.ResetPooledModelBeforeBackPool(model: Model)
	if not model or not model:IsA("Model") then
		return
	end
	FXUtil.Stop_All_Emit(model)
	FXUtil.SetEmittersTrailsBeamsEnabled(model, false)
	FXUtil.OffEnableVfx(model)
	VisibleMgr.RestoreDefaultVisualState(model)
	model:ScaleTo(1)
end

--[[
	归还对象池（Parent 非 nil；复位由 BackPool_Instance 统一处理）。
]]
function FXUtil.ReturnPooledModelToPool(model: Model)
	if not model or not model:IsA("Model") then
		return
	end
	if model.Parent then
		FXUtil.BackPool_Instance(model)
	end
end
end