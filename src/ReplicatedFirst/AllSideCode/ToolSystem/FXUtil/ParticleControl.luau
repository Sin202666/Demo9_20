--[[
	Module: FXUtil/ParticleControl
	Description: 粒子/Trail/Beam 开关、BasePart 与渐隐控制
	Author: LinAoyu
	Created: 2024-01-01
	Last Modified: 2026-07-02
]]

return function(FXUtil)

local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

--[[
	关闭所有粒子发射器
	
	@param instance Instance|Model - 目标实例
--]]
function FXUtil.Stop_All_Particles(instance)
	local insVt = instance:GetDescendants()
	table.insert(insVt, instance)

	for _, descendant in pairs(insVt) do
		if descendant:IsA("ParticleEmitter") then
			descendant.Enabled = false
		end
	end
end

--[[
	开启所有粒子发射器（自由播放）
	
	@param instance Instance|Model - 目标实例
--]]
function FXUtil.Start_All_Particles(instance)
	local insVt = instance:GetDescendants()
	table.insert(insVt, instance)

	for _, descendant in pairs(insVt) do
		if descendant:IsA("ParticleEmitter") then
			descendant.Enabled = true
		end
	end
end

--[[
	粒子 / Beam / Trail：持续 Enabled 与「发射」类 API 约定（不按实例名自动分支，由调用方选择函数）：
	- 整子树开关：SetEmittersTrailsBeamsEnabled
	- 名字含 enable 的可持续层：关 OffEnableVfx；开仍用 SetEmittersTrailsBeamsEnabled 或按需扩展
	- 名字含 emit 的单次爆发：EmitBurstEmitInName（或 Emit_Particles_GetDescendants / Emit_Particles_Children 全树）
	- 按帧持续 :Emit：Start_Emit / Start_All_Emit，停则用 Stop_Emit / Stop_All_Emit
]]
function FXUtil.SetEmittersTrailsBeamsEnabled(root: Instance, enabled: boolean)
	if not root then
		return
	end
	if root:IsA("ParticleEmitter") or root:IsA("Trail") or root:IsA("Beam") then
		(root :: any).Enabled = enabled
	end
	for _, d in root:GetDescendants() do
		if d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Beam") then
			(d :: any).Enabled = enabled
		end
	end
end

--[[
	子树内 ParticleEmitter：延迟后单次 Emit 再开启 Rate 持续发射
	@param pe ParticleEmitter
]]
local function _emitOnceEnablePe(pe: ParticleEmitter)
	local emitDelayA = pe:GetAttribute("EmitDelay")
	local emitDelay = type(emitDelayA) == "number" and emitDelayA or 0
	local emitCountA = pe:GetAttribute("EmitCount")
	local emitCount = type(emitCountA) == "number" and emitCountA or 1
	if emitCount < 1 then
		emitCount = 1
	end
	task.spawn(function()
		if emitDelay > 0 then
			task.wait(emitDelay)
		end
		pe:Emit(emitCount)
		pe.Enabled = true
	end)
end

--[[
	子树内 ParticleEmitter：按 EmitDelay 等待后 Emit(EmitCount)，再 Enabled=true（Rate 持续）；Trail/Beam 仅开 Enabled。
	与 Emit_Particles_GetDescendants（先关 Enabled 再单次 Emit）区分，用于 DoT / 持续挂身特效。
]]
function FXUtil.EmitOnceThenEnableContinuous(root: Instance)
	if root:IsA("ParticleEmitter") then
		_emitOnceEnablePe(root)
	end
	for _, d in root:GetDescendants() do
		if d:IsA("ParticleEmitter") then
			_emitOnceEnablePe(d)
		end
	end
	for _, d in root:GetDescendants() do
		if d:IsA("Trail") or d:IsA("Beam") then
			(d :: any).Enabled = true
		end
	end
end

--[[
	子树内（含根）名字含 substring 的 VFX 设置 Enabled
	@param inst Instance
	@param sub string
	@param enabled boolean
]]
local function _setEnableNameSubstringVfx(inst: Instance, sub: string, enabled: boolean)
	if string.find(string.lower(inst.Name), sub, 1, true) == nil then
		return
	end
	if inst:IsA("ParticleEmitter") or inst:IsA("Beam") or inst:IsA("Trail") then
		(inst :: any).Enabled = enabled
	end
end

--- 子树内（含根）名字含 `enable` 的 ParticleEmitter / Beam / Trail 关 Enabled（美术可持续层，收招常用）
function FXUtil.OffEnableVfx(root: Instance)
	if not root then
		return
	end
	local sub = "enable"
	_setEnableNameSubstringVfx(root, sub, false)
	for _, d in root:GetDescendants() do
		_setEnableNameSubstringVfx(d, sub, false)
	end
end

--- 子树内（含根）名字含 `enable` 的 ParticleEmitter / Beam / Trail 设 Enabled（与 OffEnableVfx 对偶，收招开/关「可持续层」用）
function FXUtil.SetEnableNameVfx(root: Instance, enabled: boolean)
	if not root then
		return
	end
	local sub = "enable"
	_setEnableNameSubstringVfx(root, sub, enabled)
	for _, d in root:GetDescendants() do
		_setEnableNameSubstringVfx(d, sub, enabled)
	end
end

--- 模型下所有 BasePart 设为全透明并 Stop_All_Emit（藏球/收招瞬隐常用）
function FXUtil.HideModelBasePartsStopEmit(model: Model)
	if not model then
		return
	end
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Transparency = 1
		end
	end
	FXUtil.Stop_All_Emit(model)
end

-- --------------------------------------------
-- 子树 BasePart：枚举、瞬时改尺/透明度、贴地 Pivot（技能柱体、粗调 VFX 用）
-- --------------------------------------------

function FXUtil.CollectModelBaseParts(root: Instance): { BasePart }
	local out: { BasePart } = {}
	if root:IsA("BasePart") then
		table.insert(out, root)
	end
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(out, d)
		end
	end
	return out
end

function FXUtil.SetAllBasePartsSize(root: Instance, size: Vector3)
	if root:IsA("BasePart") then
		root.Size = size
		return
	end
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") then
			d.Size = size
		end
	end
end

function FXUtil.SetAllBasePartsTransparency(root: Instance, transparency: number)
	if root:IsA("BasePart") then
		root.Transparency = transparency
	end
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") then
			d.Transparency = transparency
		end
	end
end

--- 以 PrimaryPart（或首 BasePart）高度为「柱高」，将模型 Pivot 到 `groundWorldPos` 使底落点在该地面高度；保留原 `GetPivot().Rotation`。
function FXUtil.PivotModelOnGroundAtWorldY(model: Model, groundWorldPos: Vector3)
	local p = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
	if not p or not p:IsA("BasePart") then
		return
	end
	local h = p.Size.Y
	local r = model:GetPivot().Rotation
	local pos = Vector3.new(groundWorldPos.X, groundWorldPos.Y + h * 0.5, groundWorldPos.Z)
	model:PivotTo(CFrame.new(pos) * r)
end

--[[
	名字含 emit 的 ParticleEmitter 单次爆发（尊重 EmitDelay / EmitCount）
	@param pe ParticleEmitter
	@param closeEnabled boolean?
]]
local function _emitBurstInNamePe(pe: ParticleEmitter, closeEnabled: boolean?)
	local sub = "emit"
	if string.find(string.lower(pe.Name), sub, 1, true) == nil then
		return
	end
	if closeEnabled then
		pe.Enabled = false
	end
	task.spawn(function()
		local emitDelay = pe:GetAttribute("EmitDelay")
		local emitCount = pe:GetAttribute("EmitCount") or 1
		if emitDelay then
			task.wait(emitDelay)
		end
		pe:Emit(emitCount)
	end)
end

--- 仅对名字含 `emit` 的 ParticleEmitter 单次 Emit（EmitDelay / EmitCount）；closeEnabled 同 Emit_Particles_GetDescendants 第二参
function FXUtil.EmitBurstEmitInName(root: Instance, closeEnabled: boolean?)
	if root:IsA("ParticleEmitter") then
		_emitBurstInNamePe(root, closeEnabled)
	end
	for _, d in root:GetDescendants() do
		if d:IsA("ParticleEmitter") then
			_emitBurstInNamePe(d, closeEnabled)
		end
	end
end

--[[
	在子树内按名称查找 Attachment
	@param r Instance
	@param name string
	@return Attachment?
]]
local function _findBeamAttachmentByName(r: Instance, name: string): Attachment?
	local d = r:FindFirstChild(name, true)
	if d and d:IsA("Attachment") then
		return d
	end
	return nil
end

--[[
	clone 后 Beam 仍指向模板内附件时：在 rootA / rootB 下按名找 Attachment，将两棵子树下所有 Beam 的 Attachment0/1 指到该对附件并 Enabled=true。
]]
function FXUtil.WireAllBeamsBetweenAttachments(rootA: Instance, rootB: Instance, attachmentNameA: string, attachmentNameB: string)
	local a0 = _findBeamAttachmentByName(rootA, attachmentNameA)
	local a1 = _findBeamAttachmentByName(rootB, attachmentNameB)
	if not a0 or not a1 then
		return
	end
	local roots = { rootA, rootB }
	for ri = 1, #roots do
		local root = roots[ri]
		for _, d in root:GetDescendants() do
			if d:IsA("Beam") then
				d.Attachment0 = a0
				d.Attachment1 = a1
				d.Enabled = true
			end
		end
	end
end

--[[
	NumberSequence 透明度向不透明方向线性插值（t=0 保持原样，t=1 全透明）
	@param orig NumberSequence
	@param t number
	@return NumberSequence
]]
local function _numSeqLerpTowardOpaque(orig: NumberSequence, t: number): NumberSequence
	local kp = {}
	for _, k in orig.Keypoints do
		local nv = k.Value + (1 - k.Value) * t
		local ne = k.Envelope * (1 - t)
		table.insert(kp, NumberSequenceKeypoint.new(k.Time, nv, ne))
	end
	return NumberSequence.new(kp)
end

--[[
	子树内 ParticleEmitter / Trail / Beam 的 Transparency（NumberSequence）在 duration 内线性变为全透明，
	结束时统一 Enabled=false（同 SetEmittersTrailsBeamsEnabled(root, false)）。
	若需同时淡出 BasePart，可另调 Instance_Transparency_Tween。
	@param root Instance - 根实例
	@param duration number - 时长（秒）
	@param onComplete (() -> ())? - 结束回调（可选）
--]]
function FXUtil.FadeEmittersTrailsBeamsTransparencyOverTime(root: Instance, duration: number, onComplete: (() -> ())?)
	if not root or duration <= 0 then
		if onComplete then
			onComplete()
		end
		return
	end

	local emitters: { ParticleEmitter } = {}
	local trailsBeams: { Instance } = {}
	for _, d in root:GetDescendants() do
		if d:IsA("ParticleEmitter") then
			table.insert(emitters, d)
		elseif d:IsA("Trail") or d:IsA("Beam") then
			table.insert(trailsBeams, d)
		end
	end
	if root:IsA("ParticleEmitter") then
		table.insert(emitters, root)
	elseif root:IsA("Trail") or root:IsA("Beam") then
		table.insert(trailsBeams, root)
	end

	local originals: { [Instance]: NumberSequence } = {}
	for _, pe in emitters do
		originals[pe] = pe.Transparency
	end
	for _, tb in trailsBeams do
		originals[tb] = (tb :: any).Transparency
	end

	task.spawn(function()
		local elapsed = 0
		while elapsed < duration do
			if not root.Parent then
				if onComplete then
					onComplete()
				end
				return
			end
			elapsed += RunService.Heartbeat:Wait()
			local alpha = math.clamp(elapsed / duration, 0, 1)
			local k = TweenService:GetValue(alpha, Enum.EasingStyle.Linear, Enum.EasingDirection.In)
			for _, pe in emitters do
				if pe.Parent then
					local orig = originals[pe]
					pe.Transparency = _numSeqLerpTowardOpaque(orig, k)
				end
			end
			for _, tb in trailsBeams do
				if tb.Parent then
					local orig = originals[tb]
					local tbAny: any = tb
					tbAny.Transparency = _numSeqLerpTowardOpaque(orig, k)
				end
			end
		end

		if root.Parent then
			FXUtil.SetEmittersTrailsBeamsEnabled(root, false)
		end
		if onComplete then
			onComplete()
		end
	end)
end

function FXUtil.Start_All_Trail(instance)
	local insVt = instance:GetDescendants()
	table.insert(insVt, instance)

	for _, descendant in pairs(insVt) do
		if descendant:IsA("Trail") then
			descendant.Enabled = true
		end
	end
end


--[[
	开始发射粒子（帧事件控制）
	
	@param particleEmitter ParticleEmitter - 粒子发射器
	@param duringTime number? - 持续时间（可选，默认100）
--]]
function FXUtil.Start_Emit(particleEmitter: ParticleEmitter, duringTime: number?)
	if not particleEmitter then
		return
	end

	duringTime = duringTime or 100
	particleEmitter.Enabled = false

	-- 检查是否已经在发射
	local autoEmit = particleEmitter:FindFirstChild("AutoEmit")
	if not autoEmit then
		autoEmit = Instance.new("BoolValue", particleEmitter)
		autoEmit.Name = "AutoEmit"
		autoEmit.Value = false
	end

	if autoEmit.Value == true then
		return
	end

	autoEmit.Value = true

	-- 计算发射参数
	local emitTime = math.max(particleEmitter.Rate, 1) * (duringTime or 100)  -- 总发射次数
	local emitInterval = (duringTime or 100) / emitTime  -- 每次发射的间隔时间

	local emittedTime = 0
	local time = 0

	local emitEvent: RBXScriptConnection? = nil
	emitEvent = RunService.Heartbeat:Connect(function(dt)
		time += dt

		-- 检查是否应该停止
		if emittedTime >= emitTime or not particleEmitter or not autoEmit.Value then
			if emitEvent then
				emitEvent:Disconnect()
				emitEvent = nil
			end
			return
		end

		-- 计算应该发射的粒子数
		if time >= emittedTime * emitInterval then
			local num = math.ceil((time - emittedTime * emitInterval) / emitInterval)
			emittedTime += num
			particleEmitter:Emit(num)
		end
	end)
end

--[[
	停止发射粒子（帧事件控制）
	
	@param particleEmitter ParticleEmitter - 粒子发射器
--]]
function FXUtil.Stop_Emit(particleEmitter: ParticleEmitter)
	if not particleEmitter then
		return
	end

	local autoEmit = particleEmitter:FindFirstChild("AutoEmit")
	if autoEmit then
		autoEmit.Value = false
	end
end

--[[
	开始所有粒子发射器发射（帧事件控制）
	
	@param instance Model - 目标模型
	@param duringTime number? - 持续时间（可选）
--]]
function FXUtil.Start_All_Emit(instance: Model, duringTime: number?)
	if not instance then
		return
	end

	local insVt = instance:GetDescendants()
	table.insert(insVt, instance)

	for _, descendant in pairs(insVt) do
		if descendant:IsA("ParticleEmitter") then
			FXUtil.Start_Emit(descendant, duringTime)
		end
	end
end

--[[
	停止所有粒子发射器发射（帧事件控制）
	
	@param instance Model - 目标模型
--]]
function FXUtil.Stop_All_Emit(instance: Model)
	if not instance then
		return
	end

	local insVt = instance:GetDescendants()
	table.insert(insVt, instance)

	for _, descendant in pairs(insVt) do
		if descendant:IsA("ParticleEmitter") then
			FXUtil.Stop_Emit(descendant)
		end
	end
end

end