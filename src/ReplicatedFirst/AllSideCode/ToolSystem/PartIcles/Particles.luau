--[[
	Module: PartIcles.Particles
	Description: 原生 ParticleEmitter / Trail 的 EmitCount/Delay/Duration 与 gen token 控制
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-09-01

	CANCEL_GEN 门控延迟启动；DURATION_GEN 门控延迟关闭，避免旧闭包覆盖新窗口。
]]

-- Particles  -  fires native ParticleEmitters/Trails inside a transformed item using the
-- EmitCount / EmitDelay / EmitDuration attributes. Per-instance gen tokens prevent stale
-- delayed-off closures from clobbering newer emit sessions.
local Range = require(script.Parent.Range)

local Particle = {}

--[[
	把 EmitDuration（数字或 "min,max" 字符串）解析为标量秒。
	@param raw number | string | nil - 作者属性；nil 返回 nil
	@return number? - 随机或单值秒数；无法解析为 nil
]]
local function _parseDuration(raw)
	if raw == nil then return nil end
	if typeof(raw) == "number" then return raw end
	local text = tostring(raw)
	local vals = {}
	for v in text:gmatch("[^,]+") do local n = tonumber(v:match("^%s*(.-)%s*$")); if n then table.insert(vals, n) end end
	if #vals == 0 then return nil end
	if #vals == 1 then return vals[1] end
	local mn, mx = math.min(vals[1], vals[2]), math.max(vals[1], vals[2])
	return Range.RandomValueFromRange(NumberRange.new(mn, mx))
end
Particle.parseDuration = _parseDuration

--[[
	desc 到 root 之间是否有 Transformed 祖先（子发射器自己处理，此处跳过）。
	@param desc Instance - 当前后代
	@param root Instance - 扫描根
	@return boolean - 有 Transformed 祖先为 true
]]
local function _hasTransformedAncestor(desc, root)
	local p = desc.Parent
	while p and p ~= root do
		if p:GetAttribute("Transformed") then return true end
		p = p.Parent
	end
	return false
end

--[[
	引擎会话是否仍活。false 只取消延迟 START，不取消已排的 delayed-off。
	@param alive (() -> boolean)? - 会话探活；nil 视为仍活
	@return boolean - 仍活为 true
]]
local function _alive(alive)
	return (not alive) or alive()
end

-- Two gens, split responsibilities. CANCEL_GEN gates delayed starts (bumped by
-- CancelNative / Pool release / Disable). DURATION_GEN gates delayed-off closures
-- (bumped on each duration-window start) so a newer window can't be turned off
-- by an older one.
local CANCEL_GEN_ATTR = "_PartIcleNativeEmitGen"
local DURATION_GEN_ATTR = "_PartIcleNativeDurationGen"

--[[
	读取消世代 token（门控延迟启动）。
	@param v Instance - ParticleEmitter / Trail / Beam
	@return number - 当前 cancel gen，缺省 0
]]
local function _readCancelGen(v)
	return v:GetAttribute(CANCEL_GEN_ATTR) or 0
end
--[[
	+1 取消世代，使未执行的延迟启动失效。
	@param v Instance - 目标实例
	@return number - 新 cancel gen
]]
local function _bumpCancelGen(v)
	local gen = _readCancelGen(v) + 1
	pcall(function() v:SetAttribute(CANCEL_GEN_ATTR, gen) end)
	return gen
end
--[[
	取消世代是否仍是当前且实例未销毁。
	@param v Instance - 目标实例
	@param gen number - 闭包捕获的 cancel gen
	@return boolean - 仍有效为 true
]]
local function _cancelGenStillCurrent(v, gen)
	return v.Parent ~= nil and _readCancelGen(v) == gen
end

--[[
	读时长窗口世代 token（门控延迟关闭）。
	@param v Instance - 目标实例
	@return number - 当前 duration gen，缺省 0
]]
local function _readDurationGen(v)
	return v:GetAttribute(DURATION_GEN_ATTR) or 0
end
--[[
	+1 时长世代，使旧 delayed-off 不能关掉新窗口。
	@param v Instance - 目标实例
	@return number - 新 duration gen
]]
local function _bumpDurationGen(v)
	local gen = _readDurationGen(v) + 1
	pcall(function() v:SetAttribute(DURATION_GEN_ATTR, gen) end)
	return gen
end
--[[
	时长世代是否仍是当前且实例未销毁。
	@param v Instance - 目标实例
	@param gen number - 闭包捕获的 duration gen
	@return boolean - 仍有效为 true
]]
local function _durationGenStillCurrent(v, gen)
	return v.Parent ~= nil and _readDurationGen(v) == gen
end

--[[
	立刻 Enabled=true，并在 duration 秒后按 duration gen 关。
	@param v Instance - ParticleEmitter / Trail / Beam
	@param duration number - 开启秒数
	@return () - 无返回值
]]
Particle.SetEnabledForDuration = function(v, duration)
	local durGen = _bumpDurationGen(v)
	v.Enabled = true
	task.delay(duration, function()
		if _durationGenStillCurrent(v, durGen) then v.Enabled = false end
	end)
end

-- 对外稳定别名：读/校验 cancel token（延迟启动门控）。延迟关闭请走 SetEnabledForDuration。
Particle.ReadNativeGen = _readCancelGen
Particle.IsNativeGenCurrent = _cancelGenStillCurrent

--[[
	立刻 Enabled=false，并抬 cancel+duration gen，使未执行的延迟开关全部失效。
	@param v Instance - 目标实例
	@return () - 无返回值
]]
Particle.CancelNative = function(v)
	_bumpCancelGen(v)
	_bumpDurationGen(v)
	pcall(function() v.Enabled = false end)
end

--[[
	同步遍历 part 后代，按 EmitCount/Delay/Duration 触发原生 PE / 非 Transformed Trail/Beam。
	cancelGen 在调用栈捕获，避免 Heartbeat 夹在捕获与延迟 START 之间。
	@param part Instance - 扫描根
	@param alive (() -> boolean)? - 会话探活；仅取消延迟 START
	@return () - 无返回值
]]
Particle.EnableEmit = function(part, alive)
	for i, v in part:GetDescendants() do
		if _hasTransformedAncestor(v, part) then continue end
		if v:IsA('ParticleEmitter') then
			local count = v:GetAttribute('EmitCount') or 1
			local emitDelay = v:GetAttribute('EmitDelay') or 0
			local emitDuration = v:GetAttribute('EmitDuration') or 0
			if count <= 0 and emitDuration <= 0 then continue end
			local cancelGen = _readCancelGen(v)
			--[[
				按 cancel gen 发射 PE：Emit(count) 并可选开 duration 窗口。
			]]
			local function _doEmit()
				if not _alive(alive) or not _cancelGenStillCurrent(v, cancelGen) then return end
				-- Roblox :Emit(0) falls back to 1; gate on count>0.
				if count > 0 then v:Emit(count) end
				if emitDuration > 0 then
					local durGen = _bumpDurationGen(v)
					v.Enabled = true
					-- Delayed-off uses duration gen (not alive) so cleanup survives engine death.
					task.delay(emitDuration, function()
						if _durationGenStillCurrent(v, durGen) then v.Enabled = false end
					end)
				end
			end
			if emitDelay > 0 then task.delay(emitDelay, _doEmit) else _doEmit() end
		end
		-- Skip TrailEmitter (Transformed)  -  the engine pipeline emits cloned visuals
		-- via TrailEmitter.EmitTrail; toggling the SOURCE Trail's Enabled here would
		-- render the unwanted source Trail at default Roblox properties (white) on
		-- top of the authored emit clones.
		if v:IsA('Trail') and not v:GetAttribute('Transformed') then
			local dur = _parseDuration(v:GetAttribute('EmitDuration'))
			if dur and dur > 0 then
				local cancelGen = _readCancelGen(v)
				task.delay(v:GetAttribute('EmitDelay') or 0.001, function()
					if not _alive(alive) or not _cancelGenStillCurrent(v, cancelGen) then return end
					local durGen = _bumpDurationGen(v)
					v.Enabled = true
					task.delay(dur, function()
						if _durationGenStillCurrent(v, durGen) then v.Enabled = false end
					end)
				end)
			end
		end
		-- Raw Beam: native streak between authored attachments. Skip BeamNative
		-- (Transformed)  -  directAccess type handled by Particle:EnableEmit mixin.
		-- Same gen-token pattern as Trail: cancelGen gates delayed-on, durGen owns delayed-off.
		if v:IsA('Beam') and not v:GetAttribute('Transformed') then
			local emitDuration = tonumber(v:GetAttribute('EmitDuration')) or 0
			local emitDelay = tonumber(v:GetAttribute('EmitDelay')) or 0
			if emitDuration > 0 then
				local cancelGen = _readCancelGen(v)
				--[[
					按 cancel gen 打开原生 Beam 的 duration 窗口。
				]]
				local function _doEmit()
					if not _alive(alive) or not _cancelGenStillCurrent(v, cancelGen) then return end
					local durGen = _bumpDurationGen(v)
					v.Enabled = true
					task.delay(emitDuration, function()
						if _durationGenStillCurrent(v, durGen) then v.Enabled = false end
					end)
				end
				if emitDelay > 0 then task.delay(emitDelay, _doEmit) else _doEmit() end
			end
		end
	end
end

--[[
	对单个 Instance 做原生 Trail / ParticleEmitter 发射（不递归）。
	@param v Instance - Trail 或 ParticleEmitter
	@param alive (() -> boolean)? - 会话探活
	@return () - 无返回值
]]
Particle.EnableEmitSingle = function(v: Instance, alive)
	if v:IsA('Trail') then
		local dur = _parseDuration(v:GetAttribute('EmitDuration'))
		if dur and dur > 0 then
			local cancelGen = _readCancelGen(v)
			local emitDelay = v:GetAttribute('EmitDelay') or 0
			--[[
				按 cancel gen 打开 Trail.Enabled，duration 后关。
			]]
			local function _doEnable()
				if not _alive(alive) or not _cancelGenStillCurrent(v, cancelGen) then return end
				local durGen = _bumpDurationGen(v)
				v.Enabled = true
				task.delay(dur, function()
					if _durationGenStillCurrent(v, durGen) then v.Enabled = false end
				end)
			end
			-- Synchronous enable when EmitDelay=0 so trail renders on the SAME
			-- frame as particle spawn. Prior `task.delay(EmitDelay or 0.001, ...)`
			-- forced a 1ms tick gap even with zero delay → trail invisible on
			-- frame 0, visible from frame 1+. For short-lived particles this is
			-- a noticeable gap in the trail head.
			if emitDelay > 0 then task.delay(emitDelay, _doEnable) else _doEnable() end
		end
	end
	if v:IsA('ParticleEmitter') then
		local count = v:GetAttribute('EmitCount') or 1
		local emitDelay = v:GetAttribute('EmitDelay') or 0
		local emitDuration = v:GetAttribute('EmitDuration') or 0
		if count <= 0 and emitDuration <= 0 then return end
		local cancelGen = _readCancelGen(v)
		--[[
			EnableEmitSingle 的 PE 发射闭包（与 EnableEmit 同语义）。
		]]
		local function _doEmit()
			if not _alive(alive) or not _cancelGenStillCurrent(v, cancelGen) then return end
			if count > 0 then v:Emit(count) end
			if emitDuration > 0 then
				local durGen = _bumpDurationGen(v)
				v.Enabled = true
				task.delay(emitDuration, function()
					if _durationGenStillCurrent(v, durGen) then v.Enabled = false end
				end)
			end
		end
		if emitDelay > 0 then task.delay(emitDelay, _doEmit) else _doEmit() end
	end
end

--[[
	对 part 的直接子级 EnableEmitSingle；遇 Attachment 则递归。
	@param part Instance - 扫描根
	@param alive (() -> boolean)? - 会话探活
	@return () - 无返回值
]]
Particle.EnableEmitChildrenAndRepeatForAttachments = function(part, alive)
	for i, v in part:GetChildren() do
		Particle.EnableEmitSingle(v, alive)
		if v:IsA('Attachment') then
			Particle.EnableEmitChildrenAndRepeatForAttachments(v, alive)
		end
	end
end

return Particle
