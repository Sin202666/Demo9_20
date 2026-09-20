--[[
	Module: PartIcles.EventsPayload
	Description: 事件 payload 构造与按 Type 分发的 mutator（供用户 Module 脚本调用）
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-09-01

	功能：
	- build：构造用户 Module 收到的 payload；HitPosition/DeathPosition 等由 Events.fire 后续补
	- apply*：直接改 pData / 视觉（Color / Transparency / Teleport / Spin / Impulse / Freeze / Pause / Size / Velocity / Resurrect）
	- attach*：把 setter 闭包挂到 payload

	约定：改图通道的 Set* 会自动翻对应 pData.Skip*，避免下一帧图写入覆盖。
	加载：由 Events.luau 内部 require，业务勿直接 require
]]

local EventsPayload = {}

--[[
	构造一次事件的 payload。调用方传入预计算 cf（世界 CFrame；屏幕类可为 nil），避免循环依赖 Events.getWorldCF。
	@param pData table - 发射态：_sourceItem / VisualPart / StartTime / LifeTime / SpeedMultiplier / EventChainCtx 等
	@param eventName string - OnEmit / OnDeath / OnDestruction 等
	@param emitCtx table? - 可含 EmitCount / EmitIndex
	@param cf CFrame? - 世界 CFrame；屏幕类 nil
	@return table - payload：SourceItem / Particle / WorldCFrame / LifeProgress 及按事件附加字段
]]
function EventsPayload.build(pData, eventName, emitCtx, cf)
	local pos = cf and cf.Position or nil
	local now = os.clock()
	local elapsed = pData.StartTime and math.max(0, now - pData.StartTime) or 0
	local lifeTime = pData.LifeTime or 0
	local lifeProgress = (lifeTime > 0) and math.min(1, elapsed / lifeTime) or 0
	local timeRemaining = math.max(0, lifeTime - elapsed)
	local speedMult = pData.SpeedMultiplier or 1
	local p = {
		SourceItem      = pData._sourceItem,
		Source          = pData._sourceItem,
		Particle        = pData.VisualPart,
		RenderTemplate  = pData.VisualPart,
		WorldCFrame     = cf,
		WorldPosition   = pos,
		LifeProgress    = lifeProgress,
		TimeRemaining   = timeRemaining,
		StartTime       = pData.StartTime,
		LifeTime        = lifeTime,
		SpeedMultiplier = speedMult,
		ChainDepth      = pData.EventChainCtx and pData.EventChainCtx.Depth or 0,
		EmitCount       = emitCtx and emitCtx.EmitCount,
		_eventName      = eventName,
	}
	if eventName == "OnEmit" then
		p.EmitPosition = pos
		p.EmitIndex = emitCtx and emitCtx.EmitIndex
	elseif eventName == "OnDeath" then
		p.DeathPosition = pos
		-- Real wall-time age. Mid-life Kill reports < LifeTime; natural death equals it.
		if pData.StartTime then
			p.Age = math.max(0, now - pData.StartTime)
		else
			p.Age = pData.LifeTime
		end
	elseif eventName == "OnDestruction" then
		p.DeathPosition = pos
		-- Wall-time inside the linger window. PartLife=0 path has no linger so elapsed=0.
		if pData._lingerStartTime then
			p.LingerElapsed = math.max(0, now - pData._lingerStartTime)
		else
			p.LingerElapsed = 0
		end
	end
	return p
end

--[[
	按 Type 写 Color3，并置 SkipColor。Part/Model 写 BasePart+SurfaceAppearance；
	Beam/Trail 压成单停 ColorSequence；Screen 仅 ColorCorrection.TintColor / Atmosphere.Color。
	@param pData table - 发射态：Type / VisualPart / Kind
	@param color Color3 - 目标色；非 Color3 则跳过
	@return () - 无返回值
]]
function EventsPayload.applyColor(pData, color)
	if typeof(color) ~= "Color3" then return end
	pData.SkipColor = true
	local v = pData.VisualPart
	if not v or not v.Parent then return end
	local t = pData.Type
	if t == "Part" or t == "Model" then
		if v:IsA("BasePart") then pcall(function() v.Color = color end) end
		local sa = v.FindFirstChildOfClass and v:FindFirstChildOfClass("SurfaceAppearance")
		if sa then pcall(function() sa.Color = color end) end
	elseif t == "Beam" or t == "TrailEmitter" or t == "BeamNative" then
		pcall(function() v.Color = ColorSequence.new(color) end)
	elseif t == "PointLight" then
		pcall(function() v.Color = color end)
	elseif t == "Highlight" then
		pcall(function() v.FillColor = color end)
		pcall(function() v.OutlineColor = color end)
	elseif t == "ImageLabel" then
		pcall(function() v.ImageColor3 = color end)
	elseif t == "Screen" then
		if pData.Kind == "ColorCorrection" then
			pcall(function() v.TintColor = color end)
		elseif pData.Kind == "Atmosphere" then
			pcall(function() v.Color = color end)
		end
	end
end

--[[
	按 Type 写 0..1 透明度并置 SkipTransparency。
	PointLight 无透明度：首次缓存 _baseBrightness，按 base*(1-amount) 调制，避免连乘衰减。
	Blur/Bloom/Atmosphere 无透明度，仅翻 Skip 供脚本当触发器用。
	@param pData table - 发射态：Type / VisualPart
	@param amount number - 0..1；非数字跳过
	@return () - 无返回值
]]
function EventsPayload.applyTransparency(pData, amount)
	if type(amount) ~= "number" then return end
	amount = math.max(0, math.min(1, amount))
	pData.SkipTransparency = true
	local v = pData.VisualPart
	if not v or not v.Parent then return end
	local t = pData.Type
	if t == "Part" or t == "Model" then
		if v:IsA("BasePart") then pcall(function() v.Transparency = amount end) end
		local d = v.FindFirstChildOfClass and v:FindFirstChildOfClass("Decal")
		if d then pcall(function() d.Transparency = amount end) end
	elseif t == "Beam" or t == "TrailEmitter" or t == "BeamNative" then
		pcall(function() v.Transparency = NumberSequence.new(amount) end)
	elseif t == "PointLight" then
		local base = pData._baseBrightness or v.Brightness
		pData._baseBrightness = base
		pcall(function() v.Brightness = base * (1 - amount) end)
	elseif t == "Highlight" then
		pcall(function() v.FillTransparency = amount end)
		pcall(function() v.OutlineTransparency = amount end)
	elseif t == "ImageLabel" then
		pcall(function() v.ImageTransparency = amount end)
	end
end

--[[
	一次挂上 Skip* setter，翻 pData.SkipColor / SkipTransparency / SkipSize。
	SetSkipRotation 尚未接线（旋转与位移积分耦合）。
	@param payload table - 用户事件 payload（原地挂函数）
	@param pData table - 对应发射态
	@return () - 无返回值
]]
function EventsPayload.attachSkipSetters(payload, pData)
	payload.SetSkipColor = function(value) pData.SkipColor = value == true end
	payload.SetSkipTransparency = function(value) pData.SkipTransparency = value == true end
	payload.SetSkipSize = function(value) pData.SkipSize = value == true end
end

--[[
	清除落地/碰撞 settle 状态，供 Teleport / AddImpulse / SetVelocity 重新启动物理。
	@param pData table - 发射态（清 _settleEngaged / _collisionStopped / 镜像轴等）
	@return () - 无返回值
]]
local function _clearSettleState(pData)
	pData._settleEngaged = false
	pData._restTimer = 0
	pData._settleRotDamp = 1
	pData._settleContactPos = nil
	pData._settleSpawnHalf = nil
	pData._lastHitNormal = nil
	pData._collisionStopped = false
	pData._displacementMirrorX = nil
	pData._displacementMirrorY = nil
	pData._displacementMirrorZ = nil
end

--[[
	把视觉写到新世界 CFrame 并重置位移累加 / 命中锚点。
	Part/Attachment 写 CFrame；Model 用 PivotTo；Beam/Light/Image/Screen 空操作。
	LastHitCheckPos 重置为 cf.Position，避免传送缝打到“穿过”的墙。
	@param pData table - 发射态：Type / VisualPart / Link / LocalCF
	@param cf CFrame - 目标世界 CFrame；非 CFrame 则跳过
	@return () - 无返回值
]]
function EventsPayload.applyTeleport(pData, cf)
	if typeof(cf) ~= "CFrame" then return end
	_clearSettleState(pData)
	local v = pData.VisualPart
	if not v or not v.Parent then return end
	local t = pData.Type
	if t == "Part" then
		pcall(function() v.CFrame = cf end)
	elseif t == "Attachment" then
		-- Attachment.CFrame is parent-local; convert world cf via parent.
		local parent = v.Parent
		if parent and parent:IsA("BasePart") then
			pcall(function() v.CFrame = parent.CFrame:ToObjectSpace(cf) end)
		else
			pcall(function() v.CFrame = cf end)
		end
	elseif t == "Model" then
		pcall(function() v:PivotTo(cf) end)
	else
		return
	end
	-- Recompute LocalCF. Frame depends on Type + Link:
	--   • Part/Model unlinked: world-space (Update.luau composes parentCF_now=identity).
	--   • Part/Model linked:   link-relative (parentCF_now = link world CFrame).
	--   • Attachment any:      attachment-parent-relative (Update.luau's Attachment
	--     branch composes against visualPart.Parent.CFrame; LocalCF lives in that
	--     parent space whether or not Link is set).
	if t == "Attachment" then
		local visualParent = v.Parent
		if visualParent and visualParent:IsA("BasePart") then
			pData.LocalCF = visualParent.CFrame:ToObjectSpace(cf)
		else
			pData.LocalCF = cf
		end
	else
		local lk = pData.Link
		if lk and lk.Parent then
			local linkCF
			if lk:IsA("Attachment") then linkCF = lk.WorldCFrame
			elseif lk:IsA("Model") then linkCF = lk:GetPivot()
			else linkCF = lk.CFrame end
			pData.LocalCF = linkCF:ToObjectSpace(cf)
		else
			pData.LocalCF = cf
		end
	end
	pData._localWorldCF = pData.LocalCF
	-- _postUpdateCF mirrors the live VisualPart.CFrame readout (init.luau:165). For
	-- Attachment that's parent-local (matches what was just written above); for
	-- Part/Model that's world. Re-read from the visual rather than re-deriving.
	if t == "Attachment" then
		pData._postUpdateCF = v.CFrame
	elseif t == "Model" then
		pData._postUpdateCF = v:GetPivot()
	else
		pData._postUpdateCF = cf
	end
	pData.CurrentPosition = cf.Position
	pData.LastHitCheckPos = cf.Position
	pData._lastOrientPos = nil -- next ApplyOrientation reseeds velocity from this frame
end

--[[
	给 pData._spinRate 加角速度（度/秒）。碰撞反弹已由 EventsCollision 写入，用户再叠加翻滚。
	@param pData table - 发射态
	@param vec Vector3 - 三轴角速度增量；非 Vector3 跳过
	@return () - 无返回值
]]
function EventsPayload.applyAddSpin(pData, vec)
	if typeof(vec) ~= "Vector3" then return end
	pData._spinRate = (pData._spinRate or Vector3.zero) + vec
end

--[[
	给 pData._accelVel（加速度速度累加器）加冲量；Update 逐步积分会读到。
	@param pData table - 发射态
	@param vec Vector3 - 冲量；非 Vector3 跳过
	@return () - 无返回值
]]
function EventsPayload.applyAddImpulse(pData, vec)
	if typeof(vec) ~= "Vector3" then return end
	_clearSettleState(pData)
	pData._accelVel = (pData._accelVel or Vector3.zero) + vec
end

--[[
	开关 pData._timeFrozen（Update 据此停有效寿命）。置 _freezeTimeExplicit，避免并发 Pause 自动解除。
	@param pData table - 发射态
	@param on boolean - true 冻结
	@return () - 无返回值
]]
function EventsPayload.applyFreezeTime(pData, on)
	pData._timeFrozen = on == true
	pData._freezeTimeExplicit = on == true
end

--[[
	临时冻结：置 _timeFrozen，seconds 后自动清。后到的 Pause 抬 gen 使旧 delay 失效。
	若用户已 FreezeTime(true)，自动解除为空操作。
	@param pData table - 发射态
	@param seconds number - 暂停秒数；<=0 或非数字跳过
	@return () - 无返回值
]]
function EventsPayload.applyPause(pData, seconds)
	if type(seconds) ~= "number" or seconds <= 0 then return end
	pData._timeFrozen = true
	local gen = (pData._pauseGen or 0) + 1
	pData._pauseGen = gen
	task.delay(seconds, function()
		if pData._pauseGen == gen and not pData._freezeTimeExplicit then
			pData._timeFrozen = false
		end
	end)
end

--[[
	直接写视觉尺寸并翻 SkipSize。Part 用 Vector3 Size；Model 用 ScaleTo(size.X)；ImageLabel 用 UDim2。
	@param pData table - 发射态：Type / VisualPart
	@param size Vector3 | UDim2 - Part/Model 为 Vector3；ImageLabel 为 UDim2
	@return () - 无返回值
]]
function EventsPayload.applySetSize(pData, size)
	pData.SkipSize = true
	local v = pData.VisualPart
	if not v or not v.Parent then return end
	local t = pData.Type
	if t == "Part" or t == "Model" then
		if typeof(size) == "Vector3" and v:IsA("BasePart") then
			pcall(function() v.Size = size end)
		elseif typeof(size) == "Vector3" and t == "Model" then
			-- Model has no Size; map to ScaleTo using x component as uniform scale.
			pcall(function() v:ScaleTo(math.max(0.001, size.X)) end)
		end
	elseif t == "ImageLabel" then
		if typeof(size) == "UDim2" then pcall(function() v.Size = size end) end
	end
end

--[[
	替换 BaseDirection（单位）并覆盖速度模。Update 读 _speedOverride 时绕过作者 Speed 图。
	vec=nil 清除覆盖，恢复作者采样。
	@param pData table - 发射态
	@param vec Vector3? - 速度向量；nil 清除覆盖
	@return () - 无返回值
]]
function EventsPayload.applySetVelocity(pData, vec)
	if vec == nil then
		pData._speedOverride = nil
		return
	end
	if typeof(vec) ~= "Vector3" then return end
	_clearSettleState(pData)
	local mag = vec.Magnitude
	if mag < 1e-4 then
		pData.SpeedMultiplier = 0
		pData._speedOverride = 0
		return
	end
	pData.BaseDirection = vec / mag
	pData._speedOverride = mag
end

--[[
	清 _killedManually / _forceDead。须在下一 Heartbeat 死亡帧之前，或与 Kill 同一 OnHit 体内调用。
	@param pData table - 发射态
	@return () - 无返回值
]]
function EventsPayload.applyResurrect(pData)
	pData._killedManually = false
	pData._forceDead = false
end

--[[
	一次挂上 AddSpin / AddImpulse / FreezeTime / Pause / SetSize / SetVelocity / Resurrect。
	@param payload table - 用户事件 payload（原地挂函数）
	@param pData table - 对应发射态
	@return () - 无返回值
]]
function EventsPayload.attachAdvancedSetters(payload, pData)
	payload.AddSpin = function(vec) EventsPayload.applyAddSpin(pData, vec) end
	payload.AddImpulse = function(vec) EventsPayload.applyAddImpulse(pData, vec) end
	payload.FreezeTime = function(on) EventsPayload.applyFreezeTime(pData, on) end
	payload.Pause = function(seconds) EventsPayload.applyPause(pData, seconds) end
	payload.SetSize = function(size) EventsPayload.applySetSize(pData, size) end
	payload.SetVelocity = function(vec) EventsPayload.applySetVelocity(pData, vec) end
	payload.Resurrect = function() EventsPayload.applyResurrect(pData) end
end

return EventsPayload
