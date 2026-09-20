--[[
	Module: EventsSchema
	Description: Part-Icles 每实例 Events 树的读/写/清洗（Enabled、EmitMode、脚本、碰撞参数）
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-09-01

	树：PartIcleProperties/Events/<EventName Configuration>/{Enabled, EmitMode, ScriptEnabled,
	ChainDepthLimit, EmitTarget(ObjectValue), Module(ModuleScript)}。
	Trail（directAccess）排除。OnHit 仅 Part / Attachment / Model。
]]

local TypeRegistry = require(script.Parent.TypeRegistry)

local EventsSchema = {}

local EVENTS_FOLDER_NAME = "Events"
local EVENT_NAMES = { "OnEmit", "OnDeath", "OnDestruction", "OnHit" }
EventsSchema.EVENT_NAMES = EVENT_NAMES
EventsSchema.EVENTS_FOLDER_NAME = EVENTS_FOLDER_NAME

local EMIT_MODES = { AtPosition = true, AtSource = true, AtTarget = true, AtCFrame = true }
EventsSchema.EMIT_MODES = EMIT_MODES

-- OnHit Collision: Off (pass-through) / Kill (snap+destroy) / Stop (freeze) / Bounce (reflect).
local COLLISION_MODES = { Off = true, Kill = true, Stop = true, Bounce = true }
EventsSchema.COLLISION_MODES = COLLISION_MODES

--[[
	把连锁深度钳到 [1, 32]，非数字回退 4
	@param v any - 原始深度（number 或可 tonumber 的值）
	@return number - 钳制后的整数深度
]]
local function _clampDepthValue(v)
	local n = tonumber(v)
	if not n then return 4 end
	return math.clamp(math.floor(n), 1, 32)
end

--[[
	校验 EmitMode；非法值回退 AtPosition
	@param v any - 原始模式字符串
	@return string - AtPosition / AtSource / AtTarget / AtCFrame
]]
local function _safeEmitMode(v)
	if type(v) == "string" and EMIT_MODES[v] then return v end
	return "AtPosition"
end

--[[
	校验 OnHit Collision；非法值回退 Off
	@param v any - 原始模式字符串
	@return string - Off / Kill / Stop / Bounce
]]
local function _safeCollisionMode(v)
	if type(v) == "string" and COLLISION_MODES[v] then return v end
	return "Off"
end

--[[
	把数值钳到 [lo, hi]，非数字回退 default
	@param v any - 原始值
	@param lo number - 下限
	@param hi number - 上限
	@param default number - tonumber 失败时的回退
	@return number - 钳制后的值
]]
local function _clampUnit(v, lo, hi, default)
	local n = tonumber(v)
	if not n then return default end
	if n < lo then return lo end
	if n > hi then return hi end
	return n
end

EventsSchema.clampChainDepth = _clampDepthValue
EventsSchema.safeEmitMode = _safeEmitMode
EventsSchema.safeCollisionMode = _safeCollisionMode
EventsSchema.clampUnit = _clampUnit

-- Per-type event validity (OnHit only on collision-bearing types).
local VALID_PER_TYPE = {
	Part        = { OnEmit = true, OnDeath = true, OnDestruction = true, OnHit = true  },
	Beam        = { OnEmit = true, OnDeath = true, OnDestruction = true, OnHit = false },
	Attachment  = { OnEmit = true, OnDeath = true, OnDestruction = true, OnHit = true  },
	Model       = { OnEmit = true, OnDeath = true, OnDestruction = true, OnHit = true  },
	PointLight  = { OnEmit = true, OnDeath = true, OnDestruction = true, OnHit = false },
	Highlight   = { OnEmit = true, OnDeath = true, OnDestruction = true, OnHit = false },
	TrailEmitter = { OnEmit = true, OnDeath = true, OnDestruction = true, OnHit = false },
	Atmosphere  = { OnEmit = true, OnDeath = true, OnDestruction = true, OnHit = false },
	Blur        = { OnEmit = true, OnDeath = true, OnDestruction = true, OnHit = false },
	Bloom       = { OnEmit = true, OnDeath = true, OnDestruction = true, OnHit = false },
	ColorCorrection = { OnEmit = true, OnDeath = true, OnDestruction = true, OnHit = false },
	ImageLabel  = { OnEmit = true, OnDeath = true, OnDestruction = true, OnHit = false },
}

-- Per-event defaults. Enabled=false so ensureEvent paths don't implicitly arm the runtime.
local DEFAULT_ATTRS = {
	Enabled         = false,
	EmitMode        = "AtPosition",
	ScriptEnabled   = false,
	ChainDepthLimit = 4,
	Collision       = "Off",
	-- Collision physics: 0..1 each. Bounciness = normal restitution; Friction = tangential
	-- damping; Spin = nrm×v_t coefficient.
	Bounciness      = 0.7,
	Friction        = 0.2,
	Spin            = 0.5,
	-- 0 = check every Heartbeat. Clamp 0..0.5.
	HitCheckInterval = 0,
	-- OnHit raycast filters. CollisionGroup = "" means raycast leaves the group
	-- unset (matches every group). ExcludeList lives as a child Folder of ObjectValues
	-- (see ensureExcludeListFolder); missing folder reads as "no excludes".
	CollisionGroup = "",
}

-- Default Module source  -  commented payload reference for the Edit Script panel.
-- Outer literal uses [==[ ... ]==] so the inner --[[ ... ]] block comment's `]]`
-- doesn't terminate the long-string early.
local DEFAULT_MODULE_SOURCE = [==[--[[
	Part-Icles event handler.

	Source emitters supported: Part / Beam / PointLight / Attachment / Model /
	Highlight / TrailEmitter / Blur / Bloom / ColorCorrection / Atmosphere /
	ImageLabel.

	Raw ParticleEmitters and raw Trails are NOT supported as event SOURCES (they
	have no event-binding UI). As event TARGETS they ARE supported: a raw PE
	target gets wrapped in a holder Part at the emit-position; a raw Trail target
	emits in-place (the position override is ignored).
]]
-- ============================================================================
--  READ ONLY  (data fields  -  writing has no engine effect)
-- ============================================================================
--   Shared (every event scope)
--     payload.Source                            -- the source emitter Instance
--     payload.Particle, payload.RenderTemplate  -- the live emitted clone (RenderTemplate is a legacy alias)
--     payload.WorldCFrame                       -- world-space CFrame (nil for screen types)
--     payload.WorldPosition                     -- world position (nil for screen types)
--     payload.StartTime                         -- os.clock() at spawn
--     payload.LifeTime                          -- configured lifetime in seconds (use SetLifetime to change)
--     payload.LifeProgress                      -- t in [0, 1] of life elapsed (clamped)
--     payload.TimeRemaining                     -- seconds until natural death (max(0, LifeTime - elapsed))
--     payload.SpeedMultiplier                   -- current bounce-attenuated speed scalar (1 by default)
--     payload.ChainDepth                        -- depth of this event in the cross-emitter chain (0 = root)
--
--   OnEmit only
--     payload.EmitPosition                      -- Vector3 (alias for WorldPosition in OnEmit scope)
--     payload.EmitIndex                         -- 1-based batch index
--     payload.EmitCount                         -- batch size when emitted via burst (nil otherwise)
--
--   OnHit only
--     payload.HitPosition                       -- Vector3
--     payload.HitNormal                         -- Vector3
--     payload.HitInstance, payload.Other        -- the hit Instance (Other is an alias)
--
--   OnDeath only
--     payload.DeathPosition                     -- Vector3 (alias for WorldPosition in OnDeath scope)
--     payload.Age                               -- particle age in seconds
--
--   OnDestruction only
--     payload.DeathPosition                     -- Vector3 (alias for WorldPosition in OnDestruction scope)
--     payload.LingerElapsed                     -- seconds elapsed since linger started
--
-- ============================================================================
--  MUTATORS  (functions  -  call to change the live particle's state)
--             All mutators are available in every event scope.
-- ============================================================================
--   Emission control
--     payload.Emit(target, mode)         -- mode = "AtPosition"|"AtSource"|"AtTarget"|"AtCFrame"
--     payload.Kill()                     -- destroy/disable particle; Animate-mode-aware
--     payload.Resurrect()                -- undo a Kill (clears _killedManually + _forceDead)
--
--   Graph-channel override (auto-skip future graph writes on that channel)
--     payload.SetColor(color3)
--     payload.SetTransparency(scalar)
--     payload.SetSize(size)              -- BasePart.Size (Vector3) / Model ScaleTo / ImageLabel UDim2
--
--   Graph-channel skip (manual gate; no value write)
--     payload.SetSkipColor(bool)
--     payload.SetSkipTransparency(bool)
--     payload.SetSkipSize(bool)          -- Part only for now
--
--   Lifecycle
--     payload.SetLifetime(seconds)       -- set NEW total LifeTime; <=0.001 = instant kill next frame
--     payload.FreezeTime(bool)           -- toggle effective-elapsed advance (true = paused)
--     payload.Pause(seconds)             -- temporary FreezeTime; auto-clears after duration
--
--   Spatial / kinematic
--     payload.Teleport(cframe)           -- write VisualPart to a new CFrame (Part/Attachment/Model only)
--     payload.SetVelocity(vec3)          -- replace BaseDirection (unit) + speed override (magnitude)
--     payload.SetSpeedMultiplier(scalar) -- multiplicative scalar applied per-step
--     payload.AddSpin(vec3)              -- add angular velocity to pData._spinRate
--     payload.AddImpulse(vec3)           -- kick pData._accelVel (acceleration-velocity accumulator)
return function(payload)
	-- your code here
end
]==]

--[[
	取 item 的 PartIcleProperties；directAccess（Trail）或不存在则 nil，不创建
	@param item Instance? - 发射器
	@return Configuration? - PartIcleProperties
]]
local function _getConfig(item)
	if not item then return nil end
	local typeDef = TypeRegistry.getTypeFor(item)
	if not typeDef or typeDef.directAccess then return nil end
	return TypeRegistry.getConfig(item)
end

--[[
	解析 TypeRegistry 类型名
	@param item Instance - 发射器
	@return string? - 类型名；无法识别为 nil
]]
local function _getTypeName(item)
	local _, typeName = TypeRegistry.getTypeFor(item)
	return typeName
end

--[[
	查找 PartIcleProperties/Events 文件夹；未创建、Trail 或未知类型返回 nil（不创建）
	@param item Instance - 发射器
	@return Folder? - Events 文件夹
]]
function EventsSchema.read(item)
	local config = _getConfig(item)
	if not config then return nil end
	local folder = config:FindFirstChild(EVENTS_FOLDER_NAME)
	if folder and folder:IsA("Folder") then return folder end
	return nil
end

--[[
	判断 eventName 是否对该 item 类型合法（UI 隐藏行、ensureEvent 拒建非法事件）
	@param item Instance - 发射器
	@param eventName string - OnEmit / OnDeath / OnDestruction / OnHit
	@return boolean - 合法则为 true
]]
function EventsSchema.isValidForItem(item, eventName)
	local typeName = _getTypeName(item)
	if not typeName then return false end
	return EventsSchema.isValidForTypeName(typeName, eventName)
end

--[[
	按类型名判断事件是否合法（无活实例时 UI 建区用，与 isValidForItem 对齐）
	@param typeName string - TypeRegistry 类型名
	@param eventName string - 事件名
	@return boolean - 合法则为 true
]]
function EventsSchema.isValidForTypeName(typeName, eventName)
	local valid = VALID_PER_TYPE[typeName]
	return valid and valid[eventName] == true or false
end

--[[
	取已有的单事件 Configuration，不创建
	@param item Instance - 发射器
	@param eventName string - 事件名
	@return Configuration? - 事件配置
]]
function EventsSchema.readEvent(item, eventName)
	local folder = EventsSchema.read(item)
	if not folder then return nil end
	local cfg = folder:FindFirstChild(eventName)
	if cfg and cfg:IsA("Configuration") then return cfg end
	return nil
end

--[[
	确保 OnHit 配置下有 ExcludeList Folder（懒创建）；子节点 ObjectValue.Value 为排除实例
	@param cfg Configuration? - OnHit 事件配置
	@return Folder? - ExcludeList；cfg 为 nil 则 nil
]]
function EventsSchema.ensureExcludeListFolder(cfg)
	if not cfg then return nil end
	local folder = cfg:FindFirstChild("ExcludeList")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "ExcludeList"
		folder.Parent = cfg
	end
	return folder
end

--[[
	快照当前已启用事件供运行时使用；无启用或无文件夹返回 nil
	每条是普通表（非活 Configuration）：Enabled / EmitMode / ScriptEnabled / ChainDepthLimit /
	EmitTarget(Instance?) / Module(ModuleScript? 仅 ScriptEnabled) / Collision 与物理字段
	ImportedUntrusted=true 的事件一律跳过（导入失败关闭，需用户 Trust）
	@param item Instance - 发射器
	@return table? - { [eventName]=snapshot }；无启用事件为 nil
]]
function EventsSchema.readEnabled(item)
	local folder = EventsSchema.read(item)
	if not folder then return nil end
	local out
	for _, name in ipairs(EVENT_NAMES) do
		-- Per-type validity gate: VALID_PER_TYPE forbids OnHit on Beam / PointLight /
		-- screens / ImageLabel because they have no discrete-particle collision concept.
		-- Sanitize removes invalid configs on save / import, but a hand-edited cfg between
		-- write and the next sanitize would otherwise reach the runtime path and crash
		-- (e.g. Beam has no .CFrame, so EventsCollision.readWorldCF errors). Filter here
		-- so readEnabled and the schema agree on what's runtime-eligible.
		if not EventsSchema.isValidForItem(item, name) then continue end
		local cfg = folder:FindFirstChild(name)
		if cfg and cfg:IsA("Configuration") and cfg:GetAttribute("Enabled") == true
			and not cfg:GetAttribute("ImportedUntrusted")
		then
			local et = cfg:FindFirstChild("EmitTarget")
			local scriptOn = cfg:GetAttribute("ScriptEnabled") == true
			local mod = scriptOn and cfg:FindFirstChild("Module") or nil
			if mod and not mod:IsA("ModuleScript") then mod = nil end
			out = out or {}
			out[name] = {
				Enabled         = true,
				EventName       = name,
				EmitMode        = _safeEmitMode(cfg:GetAttribute("EmitMode")),
				ScriptEnabled   = scriptOn,
				ChainDepthLimit = _clampDepthValue(cfg:GetAttribute("ChainDepthLimit")),
				EmitTarget      = et and et:IsA("ObjectValue") and et.Value or nil,
				Module          = mod,
				-- Collision is OnHit-only at runtime; cheap to include for all events.
				Collision       = _safeCollisionMode(cfg:GetAttribute("Collision")),
				Bounciness      = _clampUnit(cfg:GetAttribute("Bounciness"), 0, 1, 0.7),
				Friction        = _clampUnit(cfg:GetAttribute("Friction"), 0, 1, 0.2),
				Spin            = _clampUnit(cfg:GetAttribute("Spin"), 0, 2, 0.5),
				HitCheckInterval = _clampUnit(cfg:GetAttribute("HitCheckInterval"), 0, 0.5, 0),
			}
		end
	end
	return out
end

--[[
	懒创建 PartIcleProperties/Events 文件夹
	@param item Instance - 发射器
	@return Folder? - Events 文件夹；非配置模式为 nil
]]
function EventsSchema.ensure(item)
	local config = _getConfig(item)
	if not config then return nil end
	local folder = config:FindFirstChild(EVENTS_FOLDER_NAME)
	if folder and folder:IsA("Folder") then return folder end
	-- Replace if a non-Folder instance with the reserved name slipped in.
	if folder then folder:Destroy() end
	folder = Instance.new("Folder")
	folder.Name = EVENTS_FOLDER_NAME
	folder.Parent = config
	return folder
end

--[[
	懒创建单事件 Configuration（默认 Attribute + stub Module）；类型非法则拒绝；已存在则原样返回
	@param item Instance - 发射器
	@param eventName string - 事件名
	@return Configuration? - 事件配置；非法或无法建文件夹为 nil
]]
function EventsSchema.ensureEvent(item, eventName)
	if not EventsSchema.isValidForItem(item, eventName) then return nil end
	local folder = EventsSchema.ensure(item)
	if not folder then return nil end
	local cfg = folder:FindFirstChild(eventName)
	if cfg and cfg:IsA("Configuration") then return cfg end
	if cfg then cfg:Destroy() end
	cfg = Instance.new("Configuration")
	cfg.Name = eventName
	for attrName, attrVal in pairs(DEFAULT_ATTRS) do
		cfg:SetAttribute(attrName, attrVal)
	end
	local emitTarget = Instance.new("ObjectValue")
	emitTarget.Name = "EmitTarget"
	emitTarget.Value = nil
	emitTarget.Parent = cfg
	local moduleScript = Instance.new("ModuleScript")
	moduleScript.Name = "Module"
	moduleScript.Source = DEFAULT_MODULE_SOURCE
	moduleScript.Parent = cfg
	cfg.Parent = folder
	return cfg
end

--[[
	切换事件 Enabled；首次开启会 ensureEvent，关闭保留 cfg+Module（不丢用户脚本）
	不清除 ImportedUntrusted（信任必须走 trustEvent）
	@param item Instance - 发射器
	@param eventName string - 事件名
	@param enabled boolean - true 开启，false 关闭
	@return Configuration? - 事件配置；非法或不存在（关且未建）为 nil
]]
function EventsSchema.setEnabled(item, eventName, enabled)
	if enabled then
		local cfg = EventsSchema.ensureEvent(item, eventName)
		if not cfg then return nil end
		cfg:SetAttribute("Enabled", true)
		-- setEnabled MUST NOT clear ImportedUntrusted. Otherwise the ordinary event toggle
		-- becomes an implicit trust action. Trust requires the dedicated trustEvent /
		-- trustAllEvents methods, wired from a visible "Trust Script" UI action.
		--
		-- If the user toggles an untrusted event on without trusting first, readEnabled
		-- still gates on `not ImportedUntrusted` so the runtime stays safe.
		return cfg
	end
	local cfg = EventsSchema.readEvent(item, eventName)
	if not cfg then return nil end
	cfg:SetAttribute("Enabled", false)
	return cfg
end

--[[
	清除单个事件的 ImportedUntrusted（用户审过脚本后点 Trust）；不改 Enabled
	@param item Instance - 发射器
	@param eventName string - 事件名
	@return boolean - 确实清掉了标志则为 true
]]
function EventsSchema.trustEvent(item, eventName)
	local cfg = EventsSchema.readEvent(item, eventName)
	if not cfg then return false end
	if cfg:GetAttribute("ImportedUntrusted") then
		cfg:SetAttribute("ImportedUntrusted", nil)
		return true
	end
	return false
end

--[[
	清除该 item 下全部事件的 ImportedUntrusted（Trust Asset）；调用方需先确认
	@param item Instance - 发射器
	@return boolean - 至少清过一个标志则为 true
]]
function EventsSchema.trustAllEvents(item)
	local folder = EventsSchema.read(item)
	if not folder then return false end
	local cleared = false
	for _, cfg in ipairs(folder:GetChildren()) do
		if cfg:IsA("Configuration") and cfg:GetAttribute("ImportedUntrusted") then
			cfg:SetAttribute("ImportedUntrusted", nil)
			cleared = true
		end
	end
	return cleared
end

--[[
	导入后盖章：全部事件 ImportedUntrusted=true 且 Enabled=false（失败关闭）
	@param item Instance - 刚反序列化的发射器
	@return boolean - 至少盖章过一个配置则为 true
]]
function EventsSchema.stampImportedUntrusted(item)
	local folder = EventsSchema.read(item)
	if not folder then return false end
	local stamped = false
	for _, cfg in ipairs(folder:GetChildren()) do
		if cfg:IsA("Configuration") then
			cfg:SetAttribute("ImportedUntrusted", true)
			cfg:SetAttribute("Enabled", false)
			stamped = true
		end
	end
	return stamped
end

--[[
	删除单事件 Configuration（含作者脚本）；空 Events 文件夹一并删掉
	@param item Instance - 发射器
	@param eventName string - 事件名
	@return boolean - 确实删除了则为 true
]]
function EventsSchema.deleteEvent(item, eventName)
	local cfg = EventsSchema.readEvent(item, eventName)
	if not cfg then return false end
	cfg:Destroy()
	-- If the Events folder is now empty, delete it too. Keeps "no events configured"
	-- distinguishable from "events configured but all disabled".
	local folder = EventsSchema.read(item)
	if folder and #folder:GetChildren() == 0 then folder:Destroy() end
	return true
end

--[[
	清洗 Events 树（Migrate.fix 调用）：删未知名/类型非法事件、回填默认 Attribute、
	补 EmitTarget+Module、丢 _CompiledEventModule 缓存克隆
	@param item Instance - 发射器
	@return boolean - 有改动则为 true
]]
function EventsSchema.sanitize(item)
	local folder = EventsSchema.read(item)
	if not folder then return false end
	local changed = false
	local validSet = {}
	for _, n in ipairs(EVENT_NAMES) do validSet[n] = true end
	for _, child in ipairs(folder:GetChildren()) do
		-- Drop unrecognized siblings  -  anything not a per-event Configuration with a
		-- known event name. The compile-cache clones (named "_CompiledEventModule")
		-- live elsewhere, but if a clone leaked into the Events folder we kill it here.
		if not (child:IsA("Configuration") and validSet[child.Name]) then
			child:Destroy()
			changed = true
		elseif not EventsSchema.isValidForItem(item, child.Name) then
			-- Event name is known but doesn't apply to this type (OnHit on a Beam, etc.).
			child:Destroy()
			changed = true
		else
			-- Backfill missing default attributes.
			for attrName, defaultVal in pairs(DEFAULT_ATTRS) do
				if child:GetAttribute(attrName) == nil then
					child:SetAttribute(attrName, defaultVal)
					changed = true
				end
			end
			-- Clamp ChainDepthLimit to the documented 1..32 range. Drops any non-numeric
			-- value back to the default 4  -  protects runtime apply() / readEnabled from
			-- stringly-typed garbage data on disk-imported assets.
			local depth = child:GetAttribute("ChainDepthLimit")
			local clamped = _clampDepthValue(depth)
			if depth ~= clamped then
				child:SetAttribute("ChainDepthLimit", clamped)
				changed = true
			end
			-- Snap EmitMode back to AtPosition when imported assets carry an unrecognized
			-- string. Mirrors _safeEmitMode in readEnabled but at sanitize time so disk
			-- state matches runtime expectations.
			local mode = child:GetAttribute("EmitMode")
			local safe = _safeEmitMode(mode)
			if mode ~= safe then
				child:SetAttribute("EmitMode", safe)
				changed = true
			end
			-- Same coercion for Collision. OnHit-only at runtime; non-OnHit events keep
			-- the attribute but it's inert. Imported assets with bogus values snap to "Off".
			local cmode = child:GetAttribute("Collision")
			local csafe = _safeCollisionMode(cmode)
			if cmode ~= csafe then
				child:SetAttribute("Collision", csafe)
				changed = true
			end
			-- Clamp Bounciness / Friction / Spin to safe ranges. Backfill defaults if missing.
			local physicsRows = {
				{ name = "Bounciness",       lo = 0, hi = 1,   default = 0.7 },
				{ name = "Friction",         lo = 0, hi = 1,   default = 0.2 },
				{ name = "Spin",             lo = 0, hi = 2,   default = 0.5 },
				{ name = "HitCheckInterval", lo = 0, hi = 0.5, default = 0 },
			}
			for _, row in ipairs(physicsRows) do
				local raw = child:GetAttribute(row.name)
				local clamped = _clampUnit(raw, row.lo, row.hi, row.default)
				if raw ~= clamped then
					child:SetAttribute(row.name, clamped)
					changed = true
				end
			end
			-- EmitTarget ObjectValue child.
			local et = child:FindFirstChild("EmitTarget")
			if not et or not et:IsA("ObjectValue") then
				if et then et:Destroy() end
				et = Instance.new("ObjectValue")
				et.Name = "EmitTarget"
				et.Parent = child
				changed = true
			end
			-- Module ModuleScript child.
			local mod = child:FindFirstChild("Module")
			if not mod or not mod:IsA("ModuleScript") then
				if mod then mod:Destroy() end
				mod = Instance.new("ModuleScript")
				mod.Name = "Module"
				mod.Source = DEFAULT_MODULE_SOURCE
				mod.Parent = child
				changed = true
			end
			-- Drop any stray cache clones siblings of Module.
			for _, sub in ipairs(child:GetChildren()) do
				if sub.Name == "_CompiledEventModule" then
					sub:Destroy()
					changed = true
				end
			end
		end
	end
	-- Empty-folder cleanup.
	if #folder:GetChildren() == 0 then
		folder:Destroy()
		changed = true
	end
	return changed
end

--[[
	把 Events 树拍成普通表（剪贴板/迁移）；无文件夹返回 nil
	条目含 Enabled / EmitMode / ScriptEnabled / ChainDepthLimit / Collision / 物理字段 /
	ImportedUntrusted / EmitTargetPresent+Value+Path / ModuleSource
	@param item Instance - 发射器
	@return table? - { [eventName]=entry }
]]
function EventsSchema.snapshot(item)
	local folder = EventsSchema.read(item)
	if not folder then return nil end
	local snap
	for _, name in ipairs(EVENT_NAMES) do
		local cfg = folder:FindFirstChild(name)
		if cfg and cfg:IsA("Configuration") then
			snap = snap or {}
			local entry = {
				Enabled           = cfg:GetAttribute("Enabled"),
				EmitMode          = cfg:GetAttribute("EmitMode"),
				ScriptEnabled     = cfg:GetAttribute("ScriptEnabled"),
				ChainDepthLimit   = cfg:GetAttribute("ChainDepthLimit"),
				Collision         = cfg:GetAttribute("Collision"),
				Bounciness        = cfg:GetAttribute("Bounciness"),
				Friction          = cfg:GetAttribute("Friction"),
				Spin              = cfg:GetAttribute("Spin"),
				HitCheckInterval  = cfg:GetAttribute("HitCheckInterval"),
				ImportedUntrusted = cfg:GetAttribute("ImportedUntrusted") == true,
			}
			local et = cfg:FindFirstChild("EmitTarget")
			-- EmitTarget.Value is an Instance ref. Resolution at apply time can't restore
			-- across game-tree boundaries (clipboard between places, asset-import) so the
			-- snapshot stores the FullName for diagnostic display + the live ref for same-
			-- session paste. Apply uses the live ref when valid; FullName is fallback log.
			if et and et:IsA("ObjectValue") then
				entry.EmitTargetPresent = true
				entry.EmitTargetValue = et.Value
				entry.EmitTargetPath = et.Value and et.Value:GetFullName() or nil
			end
			local mod = cfg:FindFirstChild("Module")
			if mod and mod:IsA("ModuleScript") then
				entry.ModuleSource = mod.Source
			end
			snap[name] = entry
		end
	end
	return snap
end

--[[
	把 snapshot 写回 item；类型非法的事件跳过；已有 cfg 原地更新，缺失则创建
	@param item Instance - 目标发射器
	@param snap table? - snapshot 产物 { [eventName]=entry }；nil 则 false
	@return boolean - 至少写入过一个事件则为 true
]]
function EventsSchema.apply(item, snap)
	if not snap then return false end
	local applied = false
	for name, entry in pairs(snap) do
		if EventsSchema.isValidForItem(item, name) then
			local cfg = EventsSchema.ensureEvent(item, name)
			if cfg then
				if entry.Enabled ~= nil then cfg:SetAttribute("Enabled", entry.Enabled == true) end
				if entry.EmitMode ~= nil then cfg:SetAttribute("EmitMode", _safeEmitMode(entry.EmitMode)) end
				if entry.ScriptEnabled ~= nil then cfg:SetAttribute("ScriptEnabled", entry.ScriptEnabled == true) end
				if entry.ChainDepthLimit ~= nil then
					cfg:SetAttribute("ChainDepthLimit", _clampDepthValue(entry.ChainDepthLimit))
				end
				if entry.Collision ~= nil then
					cfg:SetAttribute("Collision", _safeCollisionMode(entry.Collision))
				end
				if entry.Bounciness ~= nil then cfg:SetAttribute("Bounciness", _clampUnit(entry.Bounciness, 0, 1, 0.7)) end
				if entry.Friction ~= nil then cfg:SetAttribute("Friction", _clampUnit(entry.Friction, 0, 1, 0.2)) end
				if entry.Spin ~= nil then cfg:SetAttribute("Spin", _clampUnit(entry.Spin, 0, 2, 0.5)) end
				if entry.HitCheckInterval ~= nil then cfg:SetAttribute("HitCheckInterval", _clampUnit(entry.HitCheckInterval, 0, 0.5, 0)) end
				-- ImportedUntrusted round-trip: untrusted source stays untrusted, trusted
				-- source clears destination's untrusted flag. Paste of a trusted event
				-- onto a previously-imported untrusted destination unblocks the paste,
				-- because the user has now provided trusted source code by an explicit
				-- copy/paste action (clipboard is user-driven, unlike asset import).
				if entry.ImportedUntrusted == true then
					cfg:SetAttribute("ImportedUntrusted", true)
				else
					cfg:SetAttribute("ImportedUntrusted", nil)
				end
				local et = cfg:FindFirstChild("EmitTarget")
				if et and et:IsA("ObjectValue") and entry.EmitTargetPresent then
					-- Write even when EmitTargetValue is nil so paste can clear a
					-- stale destination target. Snapshot sets EmitTargetPresent
					-- whenever the source had an ObjectValue field.
					et.Value = entry.EmitTargetValue
				end
				local mod = cfg:FindFirstChild("Module")
				if mod and mod:IsA("ModuleScript") and entry.ModuleSource ~= nil then
					mod.Source = entry.ModuleSource
				end
				applied = true
			end
		end
	end
	return applied
end

return EventsSchema
