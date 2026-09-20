--[[
	Module: FXUtil/PlayEffect
	Description: 统一特效播放 PlayEffect（仅客户端；服务端调用直接返回）
	Author: LinAoyu
	Created: 2024-01-01
	Last Modified: 2026-09-01
]]

return function(FXUtil)

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

local VisibleMgr = Utils.VisibleMgr
local AssetPaths = Utils.AssetPaths
local PlayEffectInternal = require(script.Parent.PlayEffectInternal)

local EMIT_STOP_BUFFER_SEC = 1

--[[
	获取特效实例（内部辅助函数）
	@param effectName string - 特效名称
	@return Instance? - 克隆的特效实例
]]
local function _getEffectClone(effectName: string)
	local template = AssetPaths.Resolve("ModelRes/Effect/" .. effectName, AssetPaths.Scope.Shared)
	if not template then
		return nil
	end
	return template:Clone()
end

--[[
	从对象池或模板解析 PlayEffect 用特效实例
	@param effectName string
	@param resourceCategory string
	@param usePool boolean
	@return Instance?
]]
local function _getEffectInstanceForPlay(effectName: string, resourceCategory: string, usePool: boolean): Instance?
	local subName = resourceCategory == "Skill" and "Skill" or "Effect"
	local folder = AssetPaths.Resolve("ModelRes/" .. subName, AssetPaths.Scope.Shared)
	local template = folder and folder:FindFirstChild(effectName)
	if not template then
		return nil
	end
	if usePool and template:IsA("Model") then
		return FXUtil.GetInstance_From_Pool(template)
	end
	return template:Clone()
end

--[[
	单次爆发特效在 delay 后停播；对象池实例归还池
	@param effect Instance
	@param delaySec number
	@param usePool boolean
]]
local function _scheduleOnceEmitCleanup(effect: Instance, delaySec: number, usePool: boolean)
	if usePool then
		task.spawn(function()
			task.wait(delaySec)
			if effect.Parent == nil then
				return
			end
			PlayEffectInternal.stopPooledVfxAndRecycle(effect)
		end)
		return
	end
	task.delay(delaySec, function()
		Debris:AddItem(effect, 0)
	end)
end

--[[
	将特效 Pivot 到 CFrame 或 BasePart 位置（含 offset）
	@param effect Instance
	@param cf BasePart | CFrame
	@param offset CFrame
]]
local function _pivotEffectToTarget(effect: Instance, cf: BasePart | CFrame, offset: CFrame)
	if typeof(cf) == "CFrame" then
		local cfValue = cf :: CFrame
		if offset then
			effect:PivotTo(cfValue:ToWorldSpace(offset))
		else
			effect:PivotTo(cfValue)
		end
	elseif cf:IsA("BasePart") then
		local part = cf :: BasePart
		if offset then
			effect:PivotTo(part:GetPivot():ToWorldSpace(offset))
		else
			effect:PivotTo(part:GetPivot())
		end
	end
end

--[[
	持续发射结束后停播并延迟销毁
	@param effect Instance
	@param emitTime number
]]
local function _scheduleContinuousEmitCleanup(effect: Instance, emitTime: number)
	task.delay(emitTime, function()
		FXUtil.Stop_All_Emit(effect)
		FXUtil.Stop_All_Particles(effect)
		task.delay(EMIT_STOP_BUFFER_SEC, function()
			Debris:AddItem(effect, 0)
		end)
	end)
end

--[[
	焊接特效到 BasePart
	@param effect Instance
	@param part BasePart
	@param usePrimaryPart boolean - Model 时 Part0 用 PrimaryPart
]]
local function _weldEffectToPart(effect: Instance, part: BasePart, usePrimaryPart: boolean)
	local weld = Instance.new("WeldConstraint", effect)
	if usePrimaryPart and effect:IsA("Model") and effect.PrimaryPart then
		weld.Part0 = effect.PrimaryPart
	else
		weld.Part0 = effect :: BasePart
	end
	weld.Part1 = part
end

--[[
	类型1：世界坐标持续发射
]]
local function _playEffectType1(effect: Instance, cf: BasePart | CFrame, emitTime: number)
	_pivotEffectToTarget(effect, cf, CFrame.new())
	FXUtil.Start_All_Emit(effect, emitTime)
	_scheduleContinuousEmitCleanup(effect, emitTime)
end

--[[
	类型2：挂身持续发射
]]
local function _playEffectType2(effect: Instance, part: BasePart, offset: CFrame, emitTime: number)
	VisibleMgr.UnAnchoredAll(effect)
	_pivotEffectToTarget(effect, part, offset)
	_weldEffectToPart(effect, part, false)
	FXUtil.Start_All_Emit(effect, emitTime)
	_scheduleContinuousEmitCleanup(effect, emitTime)
end

--[[
	类型3/4：单次爆发（世界 / 挂身）。锚定已在 prep 做过，此处不再 AnchoredAll。
	@param effect Instance - 已预处理的特效实例
	@param cf BasePart | CFrame - 世界位置或挂身部件
	@param offset CFrame - 相对偏移
	@param emitTime number - 单次发射后回收/销毁延迟（秒）
	@param usePool boolean - true 时到期归还对象池
	@param weldPart BasePart? - 类型4 挂身目标；nil 为类型3 世界播
	@param emitCache PlayEffectInternal.FxEmitCache? - prep 一次扫树得到的发射器/Beam
	@return nil
]]
local function _playEffectTypeOnce(
	effect: Instance,
	cf: BasePart | CFrame,
	offset: CFrame,
	emitTime: number,
	usePool: boolean,
	weldPart: BasePart?,
	emitCache: PlayEffectInternal.FxEmitCache?
)
	if weldPart then
		VisibleMgr.UnAnchoredAll(effect)
	end
	_pivotEffectToTarget(effect, cf, offset)
	if weldPart then
		_weldEffectToPart(effect, weldPart, true)
	end
	if emitCache then
		FXUtil.Emit_Particles_Cached(emitCache.emitters, emitCache.beams, true)
	else
		FXUtil.Emit_Particles_GetDescendants(effect, true)
	end
	_scheduleOnceEmitCleanup(effect, emitTime, usePool)
end

--[[
	类型5：挂身单次全树 Emit（返回实例供调用方持有）
]]
local function _playEffectType5(effect: Instance, part: BasePart, offset: CFrame): Instance
	VisibleMgr.UnAnchoredAll(effect)
	VisibleMgr.UnCollideAll(effect)
	VisibleMgr.UnTouchAll(effect)
	VisibleMgr.UnQueryAll(effect)
	VisibleMgr.MasslessAll(effect)
	_pivotEffectToTarget(effect, part, offset)
	_weldEffectToPart(effect, part, true)
	FXUtil.Emit_Particles_GetDescendants(effect)
	effect.Parent = part
	return effect
end

--[[
	播放特效
	
	类型说明：
	- 类型1：在指定位置播放（持续发射）
	- 类型2：焊接在部件上播放（持续发射）
	- 类型3：在指定位置播放一次（单次发射）
	- 类型4：焊接在部件上播放一次（单次发射）
	- 类型5：挂身单次全树 Emit（返回实例）
	
	@param effectName string - 特效名称
	@param cf BasePart|CFrame - 位置或部件
	@param emitTime number? - 发射时间（可选，默认1）
	@param effectType number? - 特效类型（可选，默认1）
	@param offset CFrame? - 偏移量（可选，默认CFrame.new(0,0,0)）
	@param scale number? - 特效尺寸缩放
	@param playOpts PlayEffectOpts? - resourceCategory / usePool / parent
--]]
function FXUtil.PlayEffect(
	effectName: string,
	cf: BasePart | CFrame,
	emitTime: number?,
	effectType: number?,
	offset: CFrame?,
	scale: number?,
	playOpts: PlayEffectOpts?
): Instance?
	if RunService:IsServer() then
		return nil
	end
	if not cf then
		return nil
	end

	effectType = effectType or 1
	emitTime = emitTime or 1
	offset = offset or CFrame.new(0, 0, 0)
	scale = scale or 1

	local resourceCategory = (playOpts and playOpts.resourceCategory) or "Effect"
	local usePool = playOpts and playOpts.usePool
	if usePool and effectType ~= 3 and effectType ~= 4 then
		usePool = false
	end
	local parentFolder = (playOpts and playOpts.parent) or workspace

	local effect: Instance? = nil
	if resourceCategory == "Effect" and not usePool then
		effect = _getEffectClone(effectName)
	else
		effect = _getEffectInstanceForPlay(effectName, resourceCategory, usePool or false)
	end
	if not effect then
		return nil
	end

	if resourceCategory == "Skill" and effect:IsA("Model") then
		local ResRestore = Utils.ResRestore
		if ResRestore and ResRestore.Restore then
			ResRestore.Restore(effect)
		end
	end

	if effect:IsA("Model") then
		if usePool then
			if scale ~= 1 then
				effect:ScaleTo(scale)
			end
		else
			effect:ScaleTo(effect:GetScale() * scale)
		end
	end

	local emitCache = PlayEffectInternal.prepEffectModelForWorldShared(effect, usePool or false)
	effect.Parent = parentFolder

	if effectType == 1 then
		_playEffectType1(effect, cf, emitTime)
	elseif effectType == 2 and typeof(cf) ~= "CFrame" and cf:IsA("BasePart") then
		_playEffectType2(effect, cf :: BasePart, offset, emitTime)
	elseif effectType == 3 then
		_playEffectTypeOnce(effect, cf, offset, emitTime, usePool or false, nil, emitCache)
	elseif effectType == 4 and typeof(cf) ~= "CFrame" and cf:IsA("BasePart") then
		_playEffectTypeOnce(effect, cf, offset, emitTime, usePool or false, cf :: BasePart, emitCache)
	elseif effectType == 5 and typeof(cf) ~= "CFrame" and cf:IsA("BasePart") then
		return _playEffectType5(effect, cf :: BasePart, offset)
	end

	return nil
end

end
