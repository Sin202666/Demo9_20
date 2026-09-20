--[[
	Module: FXUtil/ParticleEmit
	Description: 粒子单次/持续发射
	Author: LinAoyu
	Created: 2024-01-01
	Last Modified: 2026-09-01
]]

return function(FXUtil)

--[[
	单次爆发一颗 ParticleEmitter（可选 EmitDelay）
	@param emitter ParticleEmitter - 发射器
	@param isCloseEnabled boolean? - true 时先关 Enabled 再 Emit
	@return nil
]]
local function _emitOneParticle(emitter: ParticleEmitter, isCloseEnabled: boolean?)
	if isCloseEnabled then
		emitter.Enabled = false
	end
	task.spawn(function()
		local emitDelay = emitter:GetAttribute("EmitDelay")
		local emitCount = emitter:GetAttribute("EmitCount") or 1
		if emitDelay then
			task.wait(emitDelay)
		end
		emitter:Emit(emitCount)
	end)
end

--[[
	按 EffectDuration 等 Attribute 开一次 Beam（无完整四字段则跳过）
	@param beam Beam - 目标 Beam
	@return nil
]]
local function _emitOneBeam(beam: Beam)
	local emitDuration: NumberRange = beam:GetAttribute("EffectDuration")
	local emitDelay = beam:GetAttribute("EmitDelay")
	local transparencyScaleStart = beam:GetAttribute("Transparency_Scale_Start")
	local transparencyScaleEnd = beam:GetAttribute("Transparency_Scale_End")
	if emitDuration and emitDelay and transparencyScaleStart and transparencyScaleEnd then
		beam.Transparency = NumberSequence.new(transparencyScaleStart, transparencyScaleEnd)
		beam.Enabled = true
		task.delay(emitDuration.Min, function()
			beam.Enabled = false
		end)
	end
end

--[[
	用 prep 缓存的发射器/Beam 单次爆发，不再扫子树
	@param emitters { ParticleEmitter } - ParticleEmitter 列表
	@param beams { Beam }? - Beam 列表；nil 视为空
	@param isCloseEnabled boolean? - 是否关闭粒子 Enabled
	@return nil
]]
function FXUtil.Emit_Particles_Cached(emitters: { ParticleEmitter }, beams: { Beam }?, isCloseEnabled: boolean?)
	for _, emitter in emitters do
		_emitOneParticle(emitter, isCloseEnabled)
	end
	if not beams then
		return
	end
	for _, beam in beams do
		_emitOneBeam(beam)
	end
end

--[[
	单次发射粒子 无延迟（所有后代对象）
	
	@param instance Model|ParticleEmitter - 目标实例
	@param isCloseEnabled boolean? - 是否关闭Enabled属性（可选）
--]]
function FXUtil.Emit_Particles_GetDescendants_NoDelay(instance: Model | ParticleEmitter, isCloseEnabled: boolean?)
	-- 如果实例本身就是粒子发射器
	if instance:IsA("ParticleEmitter") then
		if isCloseEnabled then
			instance.Enabled = false
		end
		local emitCount = instance:GetAttribute("EmitCount") or 1
		instance:Emit(emitCount)
	end

	-- 处理所有后代对象
	for _, descendant in pairs(instance:GetDescendants()) do
		if descendant:IsA("ParticleEmitter") then
			if isCloseEnabled then
				descendant.Enabled = false
			end
			local emitCount = descendant:GetAttribute("EmitCount") or 1
			descendant:Emit(emitCount)
		end
	end


end

--[[
	单次发射粒子（仅子对象）
	
	@param instance Model|ParticleEmitter - 目标实例
	@param isCloseEnabled boolean? - 是否关闭Enabled属性（可选）
--]]
function FXUtil.Emit_Particles_Children(instance: Model | ParticleEmitter, isCloseEnabled: boolean?)
	-- 如果实例本身就是粒子发射器
	if instance:IsA("ParticleEmitter") then
		if isCloseEnabled then
			instance.Enabled = false
		end
		task.spawn(function()
			local emitDelay = instance:GetAttribute("EmitDelay")
			local emitCount = instance:GetAttribute("EmitCount") or 1
			if emitDelay then
				task.wait(emitDelay)
			end
			instance:Emit(emitCount)
		end)
	end

	-- 处理子对象
	for _, child in pairs(instance:GetChildren()) do
		if child:IsA("ParticleEmitter") then
			if isCloseEnabled then
				child.Enabled = false
			end
			task.spawn(function()
				local emitDelay = child:GetAttribute("EmitDelay")
				local emitCount = child:GetAttribute("EmitCount") or 1
				if emitDelay then
					task.wait(emitDelay)
				end
				child:Emit(emitCount)
			end)
		end
	end
end

--[[
	单次发射粒子（所有后代对象）
	
	@param instance Model|ParticleEmitter - 目标实例
	@param isCloseEnabled boolean? - 是否关闭Enabled属性（可选）
--]]
function FXUtil.Emit_Particles_GetDescendants(instance: Model | ParticleEmitter, isCloseEnabled: boolean?)
	if instance:IsA("ParticleEmitter") then
		_emitOneParticle(instance, isCloseEnabled)
	end

	-- 处理所有后代对象
	for _, descendant in pairs(instance:GetDescendants()) do
		if descendant:IsA("ParticleEmitter") then
			_emitOneParticle(descendant, isCloseEnabled)
		elseif descendant:IsA("Beam") then
			_emitOneBeam(descendant)
		end
	end
end

end