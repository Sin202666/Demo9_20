--[[
	Module: Events
	Description: PartIcles 运行时事件：编译缓存、链深度、burst 上限、payload 与 OnHit 射线
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-09-01

	功能：
	- 每事件 ModuleScript 编译缓存（克隆 require，Source 变更失效）
	- ChainCtx（ChainId + Depth）传递；每事件 ChainDepthLimit + 硬顶
	- 每帧 burst 上限 + 每秒一次丢弃汇报
	- payload 构建、世界位姿辅助、Events.fire 分发
	- emitTargetInstance / _emitTransformed：EmitTarget + EmitMode → EnableEmit / EnableEmitAt
	- afterUpdate：每帧 OnHit 射线

	跨文件约定：
	- pData.Events 在发射时冻结（EventsSchema.readEnabled 快照）；热路径不再读配置
	- pData.EventChainCtx 经 _registerEmit 与每次 fire 传递
	- 插件拆除必须调用 Events.cleanup() 释放 Module 连接

	本文件是独立 helper，不是 mixin；由 Engine / Lifecycle / Emit 直接 require。
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Log = Utils.Log

local TypeRegistry = require(script.Parent.TypeRegistry)
local EventsCollision = require(script.Parent.EventsCollision)
local EventsPayload = require(script.Parent.EventsPayload)
local EventsSchema = require(script.Parent.EventsSchema)
local Pool = require(script.Parent.Pool)

local Events = {}

local MAX_EVENT_FIRES_PER_FRAME = 256
local DEFAULT_CHAIN_DEPTH_LIMIT = 4
local HARD_CHAIN_DEPTH_CEILING  = 32
local CONFIG_NAME = TypeRegistry.CONFIG_NAME
local EVENTS_FOLDER_NAME = "Events"

-- Per-Module compile cache; key = source ModuleScript. _invalidate clears entries.
local cache = {}

-- Per-frame burst state.
Events._frameCount = 0
Events._burstDropped = 0
Events._burstReportPending = false

local _depthDropPending = false
local _depthDropped = 0

-- Bumped by cleanup() so stale 1s-delay warn closures bail.
local _reportGeneration = 0

-- Warn-once sentinels for emit-mode mismatches.
local _unsupportedOriginWarned = {}
local _nilOriginWarned = {}

local _nextChainId = 0
--[[
	分配下一个事件链 ChainId。

	@return number - 递增后的链 id
]]
local function _allocChainId()
	_nextChainId += 1
	return _nextChainId
end

--[[
	新建根事件链上下文。

	@return table - {ChainId: number, Depth: number}，Depth 从 0 起
]]
function Events.newChainCtx()
	return { ChainId = _allocChainId(), Depth = 0 }
end

--[[
	浅拷贝 emitCtx 并写入 1-based EmitIndex，供 burst 循环克隆使用。

	@param emitCtx table? - 原发射上下文；nil 则只带 EmitIndex
	@param i number - burst 内序号（从 1 起）
	@return table - 新上下文（含 EmitIndex）
]]
function Events.withEmitIndex(emitCtx, i)
	if not emitCtx then return { EmitIndex = i } end
	local out = { EmitIndex = i }
	for k, v in pairs(emitCtx) do
		if k ~= "EmitIndex" then out[k] = v end
	end
	return out
end

--[[
	浅拷贝并写入 EmitIndex + EmitCount，EvenDistribution 采样需要这对字段。

	@param emitCtx table? - 原发射上下文
	@param i number - burst 内序号
	@param n number - 本轮 EmitCount
	@return table - 新上下文
]]
function Events.withEmitIndexAndCount(emitCtx, i, n)
	if not emitCtx then return { EmitIndex = i, EmitCount = n } end
	local out = { EmitIndex = i, EmitCount = n }
	for k, v in pairs(emitCtx) do
		if k ~= "EmitIndex" and k ~= "EmitCount" then out[k] = v end
	end
	return out
end

--[[
	浅拷贝并写入 burst 内序号 (i/count) 以及 EvenDistribution 滚动偏移。
	采样器保留 i/count 均匀分布，再叠 pos/rot 偏移，使每轮整体平移。
	posN/rotN 为周期长度（0=无偏移）；方向已编进传入的 idx。

	@param emitCtx table? - 原发射上下文
	@param i number - burst 内序号
	@param count number - 本轮 EmitCount
	@param posIdx number? - 位置周期下标
	@param posN number? - 位置周期长度；>0 才写入偏移
	@param rotIdx number? - 旋转周期下标
	@param rotN number? - 旋转周期长度；>0 才写入偏移
	@return table - 新上下文（EmitIndex / EmitCount / EvenOffset*）
]]
function Events.withEvenOffset(emitCtx, i, count, posIdx, posN, rotIdx, rotN)
	local out = { EmitIndex = i, EmitCount = count }
	if emitCtx then
		for k, v in pairs(emitCtx) do
			if k ~= "EmitIndex" and k ~= "EmitCount"
				and k ~= "EvenOffsetIdx_Pos" and k ~= "EvenOffsetN_Pos"
				and k ~= "EvenOffsetIdx_Rot" and k ~= "EvenOffsetN_Rot" then
				out[k] = v
			end
		end
	end
	if posN and posN > 0 then
		out.EvenOffsetIdx_Pos = posIdx
		out.EvenOffsetN_Pos = posN
	end
	if rotN and rotN > 0 then
		out.EvenOffsetIdx_Rot = rotIdx
		out.EvenOffsetN_Rot = rotN
	end
	return out
end

--[[
	把 emitCtx 传给链式子发射时剥掉原点覆盖字段，只保留 ChainCtx + EmitIndex/EmitCount。

	@param emitCtx table? - 原发射上下文
	@return table? - 无原点字段则原表；否则新浅表；emitCtx 为 nil 则 nil
]]
function Events.descendCtx(emitCtx)
	if not emitCtx then return nil end
	if emitCtx.EventOriginCF == nil and emitCtx.IgnoreLink == nil
		and emitCtx.UseFullOrigin == nil and emitCtx.EventOriginResolver == nil then
		return emitCtx
	end
	return {
		ChainCtx  = emitCtx.ChainCtx,
		EmitIndex = emitCtx.EmitIndex,
		EmitCount = emitCtx.EmitCount,
	}
end

-- Compile / cache

-- Plugin context allows Source reads; play / non-plugin lacks PluginOrOpenCloud capability.
-- Play mode: skip clone+require (Source immutable anyway, direct require works).
local _isPluginContext = pcall(function() return (Instance.new("ModuleScript")).Source end)

--[[
	编译事件 ModuleScript。插件态克隆后 require；Play 态直接 require（Source 不可变）。

	@param moduleScript ModuleScript - 须 return function(payload)
	@return function? - 编译出的处理函数
	@return string? - 失败时的错误信息
	@return ModuleScript? - 插件态克隆；Play 态为 nil
]]
function Events._compile(moduleScript)
	if not _isPluginContext then
		local ok, fn = pcall(require, moduleScript)
		if not ok then return nil, fn elseif type(fn) ~= "function" then return nil, "module must return function(payload)" end
		return fn, nil, nil
	end
	local clone = moduleScript:Clone()
	clone.Name = "_CompiledEventModule"
	clone.Archivable = false
	clone.Parent = moduleScript.Parent
	local ok, fn = pcall(require, clone)
	if not ok then
		clone:Destroy()
		return nil, fn
	end
	if type(fn) ~= "function" then
		clone:Destroy()
		return nil, "module must return function(payload)"
	end
	return fn, nil, clone
end

--[[
	校验缓存条目是否仍对应「Events 文件夹 / 事件 Configuration / 名为 Module 的脚本」。

	@param cacheEntry table? - 缓存项；字段 expectedEventCfg / expectedEventName
	@param moduleScript ModuleScript? - 源脚本
	@return boolean - 树位置与名称仍匹配
]]
function Events._isCacheValid(cacheEntry, moduleScript)
	if not cacheEntry or not moduleScript or not moduleScript:IsA("ModuleScript") then return false end
	if moduleScript.Name ~= "Module" then return false end
	local eventCfg = cacheEntry.expectedEventCfg
	if not eventCfg or not eventCfg.Parent then return false end
	if eventCfg.Name ~= cacheEntry.expectedEventName then return false end
	if not eventCfg.Parent or eventCfg.Parent.Name ~= EVENTS_FOLDER_NAME then return false end
	return moduleScript.Parent == eventCfg
end

--[[
	释放缓存：断开 Source/Ancestry/Name 信号、销毁编译克隆、删除条目。

	@param moduleScript ModuleScript - 缓存 key
]]
function Events._invalidate(moduleScript)
	local entry = cache[moduleScript]
	if not entry then return end
	if entry.sourceConn then entry.sourceConn:Disconnect(); entry.sourceConn = nil end
	if entry.ancestryConn then entry.ancestryConn:Disconnect(); entry.ancestryConn = nil end
	if entry.nameConn then entry.nameConn:Disconnect(); entry.nameConn = nil end
	if entry.compiledClone then
		pcall(function() entry.compiledClone:Destroy() end)
		entry.compiledClone = nil
	end
	cache[moduleScript] = nil
end

--[[
	取或编译事件脚本；Source 变脏或树位置不匹配时重编译。

	@param moduleScript ModuleScript? - 事件 Module；非 ModuleScript 返回 nil
	@return function? - payload 处理函数；失败 nil
]]
function Events.compile(moduleScript)
	if not moduleScript or not moduleScript:IsA("ModuleScript") then return nil end
	local entry = cache[moduleScript]
	if entry and not entry.dirty and Events._isCacheValid(entry, moduleScript) then
		return entry.fn
	end
	-- Stale entry: invalidate first so signals don't double-fire on the new entry.
	if entry then Events._invalidate(moduleScript) end

	local fn, err, clone = Events._compile(moduleScript)
	if not fn then
		Events.reportScriptError(moduleScript, err)
		return nil
	end

	local eventCfg = moduleScript.Parent
	if not eventCfg or not eventCfg:IsA("Configuration") then
		clone:Destroy()
		return nil
	end

	local newEntry = {
		fn = fn,
		expectedEventCfg = eventCfg,
		expectedEventName = eventCfg.Name,
		dirty = false,
		compiledClone = clone,
	}
	-- Mark dirty on Source-change; recompile lazily on next fire. Play / non-plugin contexts
	-- lack the PluginOrOpenCloud capability and Source is immutable there anyway  -  skip.
	if _isPluginContext then
		newEntry.sourceConn = moduleScript:GetPropertyChangedSignal("Source"):Connect(function()
			if cache[moduleScript] then cache[moduleScript].dirty = true end
		end)
	end
	-- Module dragged out / destroyed → invalidate.
	newEntry.ancestryConn = moduleScript.AncestryChanged:Connect(function()
		if not Events._isCacheValid(cache[moduleScript], moduleScript) then
			Events._invalidate(moduleScript)
		end
	end)
	-- Snap user-renames back to "Module" so the cache-validity check doesn't
	-- treat every fire as stale and trigger a clone+require+destroy cycle.
	newEntry.nameConn = moduleScript:GetPropertyChangedSignal("Name"):Connect(function()
		if moduleScript.Name ~= "Module" then
			pcall(function() moduleScript.Name = "Module" end)
		end
	end)
	cache[moduleScript] = newEntry
	return fn
end

--[[
	拆除全部编译缓存与 burst/depth 汇报状态。插件开关必须调用，避免信号泄漏。
]]
function Events.cleanup()
	-- Snapshot keys first; mutating during pairs() is undefined.
	local keys = {}
	for moduleScript in pairs(cache) do table.insert(keys, moduleScript) end
	for _, moduleScript in ipairs(keys) do Events._invalidate(moduleScript) end
	-- Bump report gen so in-flight task.delay warn closures bail.
	_reportGeneration += 1
	Events._frameCount = 0
	Events._burstDropped = 0
	Events._burstReportPending = false
	_depthDropped = 0
	_depthDropPending = false
	table.clear(_unsupportedOriginWarned)
	table.clear(_nilOriginWarned)
end

-- Burst cap + reporting

--[[
	记录一次 burst 丢弃；每秒最多打一条汇总日志（按帧打会刷屏）。
]]
function Events._reportBurst()
	Events._burstDropped += 1
	if not Events._burstReportPending then
		Events._burstReportPending = true
		local gen = _reportGeneration
		task.delay(1, function()
			if gen ~= _reportGeneration then return end
			if Events._burstDropped > 0 then
				Log.warn(("[Part-Icles Events] dropped %d event fires this second."):format(Events._burstDropped))
			end
			Events._burstDropped = 0
			Events._burstReportPending = false
		end)
	end
end

--[[
	占用本帧一次事件发射名额。超 MAX_EVENT_FIRES_PER_FRAME 则丢弃并汇报。

	@return boolean - true 表示本帧仍可 fire
]]
function Events.reserveFrameFire()
	if Events._frameCount >= MAX_EVENT_FIRES_PER_FRAME then
		Events._reportBurst()
		return false
	end
	Events._frameCount += 1
	return true
end

--[[
	Heartbeat 每帧调用一次，清零本帧 fire 计数。
]]
function Events.tickFrame()
	Events._frameCount = 0
end

--[[
	记录一次因链深度超限而丢弃的 fire；每秒汇总一条。

	@param eventName string? - 触发丢弃的事件名，写入日志后缀
]]
function Events.dropDepth(eventName)
	_depthDropped += 1
	if not _depthDropPending then
		_depthDropPending = true
		local gen = _reportGeneration
		task.delay(1, function()
			if gen ~= _reportGeneration then return end
			if _depthDropped > 0 then
				Log.warn(("[Part-Icles Events] dropped %d event fire(s) this second (chain depth limit reached%s)."):format(
					_depthDropped, eventName and (" on " .. eventName) or ""))
			end
			_depthDropped = 0
			_depthDropPending = false
		end)
	end
end

--[[
	把事件脚本运行/编译错误打到 Log。

	@param moduleScript ModuleScript? - 出错脚本；已销毁则路径为 "<destroyed>"
	@param err any - 错误对象或字符串
]]
function Events.reportScriptError(moduleScript, err)
	local path = moduleScript and moduleScript:GetFullName() or "<destroyed>"
	Log.warn(("[Part-Icles Events] %s\n  %s"):format(path, tostring(err)))
end

--[[
	按视觉类型取世界 CFrame（Attachment / Model / Beam / PointLight 等）。

	@param pData table - 粒子状态；用 VisualPart
	@return CFrame? - 世界 CFrame；无视觉或无法解析时 nil
]]
function Events.getWorldCF(pData)
	local v = pData.VisualPart
	if not v or not v.Parent then return nil end
	if v:IsA("BasePart") then return v.CFrame end
	if v:IsA("Attachment") then return v.WorldCFrame end
	if v:IsA("Model") then return v:GetPivot() end
	if v:IsA("PointLight") then
		local p = v.Parent
		if p and p:IsA("BasePart") then return p.CFrame end
		if p and p:IsA("Attachment") then return p.WorldCFrame end
		return nil
	end
	if v:IsA("Beam") then
		local a0 = v.Attachment0
		if a0 then
			local a1 = v.Attachment1
			if a1 then return CFrame.new((a0.WorldPosition + a1.WorldPosition) * 0.5) end
			return CFrame.new(a0.WorldPosition)
		end
		return nil
	end
	return nil
end

--[[
	取视觉世界坐标。

	@param pData table - 粒子状态
	@return Vector3? - 世界坐标；getWorldCF 失败时 nil
]]
function Events.getWorldPosition(pData)
	local cf = Events.getWorldCF(pData)
	return cf and cf.Position or nil
end

--[[
	取源实例世界 CFrame（BasePart / Attachment / Model / Beam / PointLight）。

	@param sourceItem Instance? - 发射源
	@return CFrame? - 世界 CFrame；无效或无法解析时 nil
]]
function Events.getSourceWorldCF(sourceItem)
	if not sourceItem or not sourceItem.Parent then return nil end
	if sourceItem:IsA("BasePart") then return sourceItem.CFrame end
	if sourceItem:IsA("Attachment") then return sourceItem.WorldCFrame end
	if sourceItem:IsA("Model") then return sourceItem:GetPivot() end
	if sourceItem:IsA("Beam") then
		local a0 = sourceItem.Attachment0
		if a0 then
			local a1 = sourceItem.Attachment1
			if a1 then return CFrame.new((a0.WorldPosition + a1.WorldPosition) * 0.5) end
			return CFrame.new(a0.WorldPosition)
		end
		return nil
	end
	if sourceItem:IsA("PointLight") then
		local p = sourceItem.Parent
		if p and p:IsA("BasePart") then return p.CFrame end
		if p and p:IsA("Attachment") then return p.WorldCFrame end
		return nil
	end
	return nil
end

-- ============================================================================
-- OnHit raycast filter
-- ============================================================================

--[[
	构建 OnHit 射线 Exclude 参数。必须用 table.insert：`{a, nil, b}` 字面量会变稀疏并丢掉后续过滤项。
	过滤视觉、源、RenderTemplate、EmitParent、Attachment 父级，以及事件 cfg 的 CollisionGroup / ExcludeList。

	@param pData table - 粒子状态；用 VisualPart / _sourceItem
	@return RaycastParams - 已填 FilterDescendantsInstances、IgnoreWater=true
]]
function Events.makeHitParams(pData)
	local p = RaycastParams.new()
	p.FilterType = Enum.RaycastFilterType.Exclude
	local filter = {}
	if pData.VisualPart then table.insert(filter, pData.VisualPart) end
	if pData._sourceItem then table.insert(filter, pData._sourceItem) end
	if pData._sourceItem then
		local rt = pData._sourceItem:FindFirstChild("RenderTemplate")
		if rt then table.insert(filter, rt) end
		-- EmitParent ObjectValue: filter the picked anchor + its descendants so the
		-- first afterUpdate raycast doesn't fire OnHit on the user's emission anchor.
		local ep = pData._sourceItem:FindFirstChild("EmitParent")
		if ep and ep:IsA("ObjectValue") and ep.Value then
			table.insert(filter, ep.Value)
		end
	end
	-- Attachments self-hit on first ray without filtering parent BasePart.
	if pData.VisualPart and pData.VisualPart:IsA("Attachment") and pData.VisualPart.Parent then
		table.insert(filter, pData.VisualPart.Parent)
	end
	-- User-configured OnHit filters from the source's per-event cfg. Read once at
	-- emit time (not on heartbeat), so mid-session edits apply to the next emit
	-- cycle. Missing cfg / missing attrs / missing folder all read as "no filter".
	if pData._sourceItem then
		local cfg = EventsSchema.readEvent(pData._sourceItem, "OnHit")
		if cfg then
			local group = cfg:GetAttribute("CollisionGroup")
			if type(group) == "string" and group ~= "" then
				-- pcall guards against the user deleting the group in Studio's collision
				-- editor between cfg-write and this read; the raycast falls back to
				-- "no group" behavior instead of erroring out per particle.
				pcall(function() p.CollisionGroup = group end)
			end
			local excludeFolder = cfg:FindFirstChild("ExcludeList")
			if excludeFolder then
				for _, child in ipairs(excludeFolder:GetChildren()) do
					if child:IsA("ObjectValue") and child.Value then
						table.insert(filter, child.Value)
					end
				end
			end
		end
	end
	p.FilterDescendantsInstances = filter
	p.IgnoreWater = true
	return p
end

--[[
	构建事件 payload。薄封装，字段填充在 EventsPayload.build。

	@param particle table - PartIcles 实例（透传给 Payload，本函数不直接用）
	@param pData table - 粒子状态
	@param eventName string - OnEmit / OnHit / OnDeath / OnDestruction
	@param emitCtx table? - 发射上下文（EmitIndex 等）
	@return table - payload 表（字段见 EventsPayload.build）
]]
function Events.makePayload(particle, pData, eventName, emitCtx)
	return EventsPayload.build(pData, eventName, emitCtx, Events.getWorldCF(pData))
end

-- EmitMode + dispatch

-- Push OnHit spawn off the hit surface along its normal so the emitted particle's first
-- raycast doesn't immediately re-fire OnHit on the same surface.
local ONHIT_SPAWN_NORMAL_OFFSET = 0.1

--[[
	解析非 AtTarget 模式的原点 CFrame（AtPosition / AtSource / AtCFrame）。
	OnEmit 用实时源位置，EmitDelay 间隔仍能跟上移动。
	OnHit 沿 HitNormal 外推 ONHIT_SPAWN_NORMAL_OFFSET，避免贴面立刻再中。

	@param mode string - "AtPosition" / "AtSource" / "AtCFrame"
	@param payload table? - 事件 payload；字段 HitPosition / DeathPosition / EmitPosition / WorldCFrame / HitNormal / _eventName
	@param pData table - 粒子状态
	@return CFrame? - 原点；无法解析时 nil
]]
function Events.resolveEmitModeCF(mode, payload, pData)
	if mode == "AtPosition" then
		if payload and payload._eventName == "OnEmit" then
			local cf = Events.getWorldCF(pData)
			if cf then return cf end
			-- Source destroyed mid-EmitDelay; fall back to last-frame CurrentPosition.
			if pData.CurrentPosition then return CFrame.new(pData.CurrentPosition) end
		end
		local pos = payload.HitPosition or payload.DeathPosition or payload.EmitPosition
		if pos and payload._eventName == "OnHit" and payload.HitNormal then
			pos = pos + payload.HitNormal * ONHIT_SPAWN_NORMAL_OFFSET
		end
		return pos and CFrame.new(pos) or nil
	elseif mode == "AtSource" then
		return Events.getSourceWorldCF(pData._sourceItem)
	elseif mode == "AtCFrame" then
		if payload and payload._eventName == "OnEmit" then
			local cf = Events.getWorldCF(pData)
			if cf then return cf end
		end
		local cf = payload and payload.WorldCFrame
		if cf and payload._eventName == "OnHit" and payload.HitNormal then
			cf = cf + payload.HitNormal * ONHIT_SPAWN_NORMAL_OFFSET
		end
		return cf or nil
	end
	return nil
end

--[[
	原点覆盖仅支持 BasePart / Attachment / Model。

	@param target Instance - 发射目标
	@return boolean - 是否支持 EnableEmitAt 原点覆盖
]]
function Events._supportsOriginOverride(target)
	return target:IsA("BasePart") or target:IsA("Attachment") or target:IsA("Model")
end

--[[
	新建隔离发射用的隐形锚点 Part（Anchored、无碰撞、Transparency=1）。
	源不是 BasePart/Model 时，用来挂克隆的 ParticleEmitter / Attachment。

	@return Part - 新锚点，尚未 Parent
]]
local function _newHolderPart()
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Massless = true
	p.Transparency = 1
	p.Size = Vector3.new(0.001, 0.001, 0.001)
	p.Archivable = false
	return p
end

--[[
	把克隆根及其子孙 BasePart 全部 Anchored，避免在 Terrain 下落体。

	@param root Instance - 克隆根
]]
local function _anchorClone(root)
	if root:IsA("BasePart") then root.Anchored = true end
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") then d.Anchored = true end
	end
end

--[[
	把克隆根放到 originCF。Model 用 PivotTo；BasePart 写 CFrame；Attachment 写 WorldCFrame（须先有 BasePart 父级）。

	@param root Instance - 克隆根（Model / BasePart / Attachment）
	@param originCF CFrame - 目标世界位姿
]]
local function _positionClone(root, originCF)
	if root:IsA("Model") then
		root:PivotTo(originCF)
	elseif root:IsA("BasePart") then
		root.CFrame = originCF
	elseif root:IsA("Attachment") then
		root.WorldCFrame = originCF
	end
end

--[[
	取活动发射桶里共享的 `_AttachmentHolder`。裸 Attachment 克隆挂到这一颗 BasePart 上写 WorldCFrame，
	不按次新建 holder。

	@param particle table - PartIcles 实例（调 GetFolder）
	@return BasePart - 共享锚点
]]
local function _getAttachmentHolder(particle)
	local pooled = particle:GetFolder()
	local h = pooled:FindFirstChild("_AttachmentHolder")
	if h then return h end
	h = _newHolderPart()
	h.Name = "_AttachmentHolder"
	h.CFrame = CFrame.new()
	h.Parent = pooled
	return h
end

-- Pool integration helpers ---------------------------------------------------------------
--[[
	把新鲜克隆上每个 PE/Trail 的作者 Enabled 打到 `_PartIcleAuthoredEnabled`。
	入池会强制 Enabled=false，取出时按该属性还原，避免跨周期丢失作者意图。

	@param root Instance - 克隆根
]]
local function _stampAuthoredEnabled(root)
	--[[
		给单个 PE/Trail 写入 `_PartIcleAuthoredEnabled`。

		@param inst Instance - 当前节点
	]]
	local function _visit(inst)
		if inst:IsA("ParticleEmitter") or inst:IsA("Trail") then
			pcall(function() inst:SetAttribute("_PartIcleAuthoredEnabled", inst.Enabled) end)
		end
	end
	_visit(root)
	for _, d in ipairs(root:GetDescendants()) do _visit(d) end
end

--[[
	Pool.acquire 取出缓存克隆后，按 `_PartIcleAuthoredEnabled` 还原 Enabled。
	缺属性当 false，避免池里误开发射。

	@param root Instance - 克隆根
]]
local function _restoreAuthoredEnabled(root)
	--[[
		按属性还原单个 PE/Trail 的 Enabled。

		@param inst Instance - 当前节点
	]]
	local function _visit(inst)
		if inst:IsA("ParticleEmitter") or inst:IsA("Trail") then
			local v = inst:GetAttribute("_PartIcleAuthoredEnabled")
			pcall(function() inst.Enabled = v == true end)
		end
	end
	_visit(root)
	for _, d in ipairs(root:GetDescendants()) do _visit(d) end
end

--[[
	还池前关掉所有 PE/Trail，避免池文件夹里继续喷。与 PoolHide.hide 叠加且幂等。

	@param root Instance - 克隆根
]]
local function _killEmittersForRelease(root)
	--[[
		关闭单个 PE/Trail。

		@param inst Instance - 当前节点
	]]
	local function _visit(inst)
		if inst:IsA("ParticleEmitter") or inst:IsA("Trail") then
			pcall(function() inst.Enabled = false end)
		end
	end
	_visit(root)
	for _, d in ipairs(root:GetDescendants()) do _visit(d) end
end

--[[
	把 EmitTarget 映射到 PoolHide kind，须与 _buildEmitClone 包装一致。
	Folder / PE 走 BasePart 风格（Folder 包 Model，PE 包 holder Part）。

	@param target Instance - EmitTarget
	@return string - "Part" / "Model" / "Attachment"
]]
local function _kindFor(target)
	if target:IsA("BasePart") then return "Part" end
	if target:IsA("Model") then return "Model" end
	if target:IsA("Folder") then return "Model" end
	if target:IsA("Attachment") then return "Attachment" end
	if target:IsA("ParticleEmitter") then return "Part" end
	return "Part"
end

--[[
	估算克隆最坏发射窗口：各 PE/Trail 的 emitDelay+emitDuration+Lifetime，下限 2s，上限 600s。

	@param root Instance - 克隆根
	@return number - 还池前等待秒数
]]
local function _computeCloneLifetime(root)
	local maxWindow = 2
	--[[
		把单个 PE/Trail 的窗口并入 maxWindow。

		@param inst Instance - 当前节点
	]]
	local function _visit(inst)
		if inst:IsA("ParticleEmitter") then
			local emitDelay = tonumber(inst:GetAttribute("EmitDelay")) or 0
			local emitDuration = tonumber(inst:GetAttribute("EmitDuration")) or 0
			local lifeMax = 2
			pcall(function() lifeMax = math.max(lifeMax, inst.Lifetime.Max) end)
			local total = emitDelay + emitDuration + lifeMax + 0.5
			if total > maxWindow then maxWindow = total end
		elseif inst:IsA("Trail") then
			local emitDuration = tonumber(inst:GetAttribute("EmitDuration")) or 0
			local lifeT = 2
			pcall(function() lifeT = math.max(lifeT, inst.Lifetime) end)
			local total = emitDuration + lifeT + 0.5
			if total > maxWindow then maxWindow = total end
		end
	end
	_visit(root)
	for _, d in ipairs(root:GetDescendants()) do _visit(d) end
	-- Ceiling: pathological authored Lifetimes (e.g. 1e6) would otherwise hold the clone in
	-- the live folder until session end. Spawned particles continue independently of the holder.
	if maxWindow > 600 then maxWindow = 600 end
	return maxWindow
end

--[[
	为 EmitTarget 建克隆根（每次 fire 一个 holder）。返回根上再 AbsoluteEmit，由克隆子树自己开火。
	BasePart/Model 直接 Clone；Folder 包进 Model；Attachment/PE 走 holder Part。

	@param target Instance - EmitTarget（BasePart / Model / Folder / Attachment / ParticleEmitter）
	@return Instance? - 克隆根；无法构建时 nil
]]
local function _buildEmitClone(target)
	local root
	if target:IsA("BasePart") then
		root = target:Clone()
		root.Archivable = false
	elseif target:IsA("Model") then
		-- Trusts source Model.WorldPivot as the authored anchor. If user authored WorldPivot
		-- offset from their BaseParts, the prefab fires offset by design  -  Model is user-authored,
		-- only the Folder branch (synthetic wrapper) stamps WorldPivot itself.
		root = target:Clone()
		root.Archivable = false
	elseif target:IsA("Folder") then
		local wrapper = Instance.new("Model")
		wrapper.Archivable = false
		local folderClone = target:Clone()
		folderClone.Archivable = false
		folderClone.Parent = wrapper
		-- Pivot wrapper at the first cloned BasePart's authored POSITION (not full CFrame) so
		-- PivotTo(originCF) lands that anchor at originCF without picking up the BasePart's
		-- authored rotation. AtCFrame mode applies originCF's rotation directly; AtPosition
		-- preserves the prefab's authored sibling layout. Skip ForgeConverter's synthetic
		-- anchor stubs (`_isAnchor` attribute)  -  they sit at origin and would shift the
		-- pivot away from authored emitter offsets when picked first by descendant order.
		for _, d in ipairs(folderClone:GetDescendants()) do
			if d:IsA("BasePart") and not d:GetAttribute("_isAnchor") then
				wrapper.WorldPivot = CFrame.new(d.Position)
				break
			end
		end
		root = wrapper
	elseif target:IsA("Attachment") then
		-- No per-fire holder Part. Caller parents the clone to the shared _AttachmentHolder
		-- inside the live folder and writes .WorldCFrame directly.
		root = target:Clone()
	elseif target:IsA("ParticleEmitter") then
		local holder = _newHolderPart()
		-- Inherit source parent BasePart's Size so PE.Shape="Box" emission preserves authored area.
		-- Holder.Transparency stays 1 (from _newHolderPart)  -  invisible regardless of size.
		if target.Parent and target.Parent:IsA("BasePart") then
			pcall(function() holder.Size = target.Parent.Size end)
		end
		local peClone = target:Clone()
		peClone.Parent = holder
		root = holder
	end
	if root then
		_stampAuthoredEnabled(root)
		-- Stamp `_PartIcleEmit` so init.luau's workspace sweep catches the clone at Deactivate
		-- even if the user reparented it out of the live folder mid-emit. Mirror of the same
		-- attribute Pool.acquireOrClone stamps on regular-emit clones (Pool.luau:216).
		pcall(function() root:SetAttribute("_PartIcleEmit", true) end)
	end
	return root
end

--[[
	Transformed 目标的原点覆盖路径：走引擎 EnableEmitAt，由当前会话跟踪，不另开克隆会话。
	depthLimit 来自源事件 cfg；目标自己的上限在它自己 fire 时再检。

	@param particle table - PartIcles 实例
	@param target Instance - Transformed 发射目标
	@param mode string? - EmitMode（AtTarget / AtPosition / AtSource / AtCFrame）
	@param payload table? - 事件 payload（含 _eventName）
	@param pData table - 源粒子状态
	@param chainCtx table? - {ChainId, Depth}；nil 则新建
	@param depthLimit number? - 链深度上限；默认 DEFAULT_CHAIN_DEPTH_LIMIT
]]
function Events._emitTransformed(particle, target, mode, payload, pData, chainCtx, depthLimit)
	chainCtx = chainCtx or Events.newChainCtx()
	depthLimit = depthLimit or DEFAULT_CHAIN_DEPTH_LIMIT
	local nextDepth = chainCtx.Depth + 1
	-- `>=` so limit=1 means "no nested emits" (drops first nested at nextDepth=1).
	if nextDepth >= depthLimit then
		Events.dropDepth(payload and payload._eventName)
		return
	end
	local subCtx = { ChainId = chainCtx.ChainId, Depth = nextDepth }
	local subEmitCtx = { ChainCtx = subCtx }

	if mode == "AtTarget" then
		particle:EnableEmit(target, nil, subEmitCtx)
		return
	end

	if not Events._supportsOriginOverride(target) then
		local key = tostring(mode) .. ":" .. target.ClassName
		if not _unsupportedOriginWarned[key] then
			_unsupportedOriginWarned[key] = true
			Log.warn(("[Part-Icles Events] transformed %s target requires EmitMode=AtTarget"):format(target.ClassName))
		end
		return
	end

	local originCF = Events.resolveEmitModeCF(mode, payload, pData)
	if not originCF then
		local key = tostring(mode) .. ":" .. tostring(payload and payload._eventName)
		if not _nilOriginWarned[key] then
			_nilOriginWarned[key] = true
			Log.warn(("[Part-Icles Events] EmitMode %q has no resolvable origin (payload position nil)"):format(tostring(mode)))
		end
		return
	end
	if not particle.EnableEmitAt then
		Log.warn("[Part-Icles Events] EnableEmitAt missing on particle; skipped origin-override emit")
		return
	end
	-- Resolver re-runs at spawn time (after target's EmitDelay) so OnEmit AtPosition tracks live.
	--[[
		EmitDelay 后再解析原点，OnEmit AtPosition 能跟上实时位置。

		@return CFrame - 解析结果；失败回退到本次已算好的 originCF
	]]
	local function _originResolver()
		return Events.resolveEmitModeCF(mode, payload, pData) or originCF
	end
	local useFullOrigin = (mode == "AtCFrame")
	particle:EnableEmitAt(target, originCF, {
		IgnoreLink = true,
		ChainCtx = subCtx,
		OriginResolver = _originResolver,
		UseFullOrigin = useFullOrigin,
	})
end

--[[
	EmitTarget 分发：原生扇出只克隆最外层一次再 AbsoluteEmit，相对布局靠父变换保留。
	AtTarget/nil/Trail → 原件 AbsoluteEmit；Transformed → _emitTransformed；其余 → 克隆定位后发射再还池。

	@param particle table - PartIcles 实例
	@param target Instance? - EmitTarget；无 Parent 则返回
	@param mode string? - EmitMode
	@param payload table? - 事件 payload
	@param pData table - 源粒子状态
	@param chainCtx table? - 事件链
	@param depthLimit number? - 链深度上限（Transformed 路径使用）
]]
function Events.emitTargetInstance(particle, target, mode, payload, pData, chainCtx, depthLimit)
	if not target or not target.Parent then return end

	if mode == nil or mode == "AtTarget" or target:IsA("Trail") then
		if target:GetAttribute("Transformed") then
			Events._emitTransformed(particle, target, mode, payload, pData, chainCtx, depthLimit)
		else
			pcall(function() particle:AbsoluteEmit(target, false, { ChainCtx = chainCtx }) end)
		end
		return
	end

	if target:GetAttribute("Transformed") then
		Events._emitTransformed(particle, target, mode, payload, pData, chainCtx, depthLimit)
		return
	end

	local originCF = Events.resolveEmitModeCF(mode, payload, pData)
	if not originCF then
		pcall(function() particle:AbsoluteEmit(target, false, { ChainCtx = chainCtx }) end)
		return
	end

	-- Pool acquire (cached clone) → fall back to fresh _buildEmitClone on miss.
	local kind = _kindFor(target)
	local cloneRoot = Pool.acquire(target, kind)
	local isFreshClone = false
	if not cloneRoot then
		cloneRoot = _buildEmitClone(target)
		if not cloneRoot then
			pcall(function() particle:AbsoluteEmit(target, false, { ChainCtx = chainCtx }) end)
			return
		end
		isFreshClone = true
	end
	-- Restore authored Enabled state on cached clones (release forced it false to silence
	-- the pool folder). Fresh clones already have authored Enabled from :Clone().
	if not isFreshClone then
		_restoreAuthoredEnabled(cloneRoot)
	end

	if cloneRoot:IsA("Attachment") then
		-- Parent FIRST: WorldCFrame setter relies on parent BasePart's CFrame for the
		-- inverse-transform math. Setting WorldCFrame on an unparented Attachment is a no-op
		-- (or fall-through to local CFrame, depending on engine state).
		cloneRoot.Parent = _getAttachmentHolder(particle)
		cloneRoot.WorldCFrame = originCF
	else
		_anchorClone(cloneRoot)
		_positionClone(cloneRoot, originCF)
		cloneRoot.Parent = particle:GetFolder()
		-- Re-pivot after parenting: PivotTo before Parent set is allowed but Studio renderer
		-- occasionally caches stale pre-parent pose for one frame. Re-applying is cheap insurance.
		_positionClone(cloneRoot, originCF)
	end

	-- Delegate to AbsoluteEmitAt with SkipClone so transformed Part-Icles nested
	-- inside the cloneRoot pick up per-node origin override (Pass 1's
	-- `originCF * anchor:ToObjectSpace(node.CFrame)` math). Caller owns cloneRoot
	-- lifecycle (pool acquire/release below); SkipClone short-circuits the clone +
	-- destroy block inside AbsoluteEmitAt. Per-mode option defaults mirror the
	-- prior manual positioning behavior (AtPosition = position-only, AtCFrame =
	-- full pose; both detach authored Link per the event-spawn convention).
	local emitOptions = {
		ChainCtx      = chainCtx,
		UseFullOrigin = (mode == "AtCFrame"),
		IgnoreLink    = (mode == "AtPosition" or mode == "AtCFrame"),
		SkipClone     = true,
	}
	pcall(function() particle:AbsoluteEmitAt(cloneRoot, originCF, emitOptions) end)

	-- Release back to pool after the worst-case emit window. Kill in-flight emission first
	-- so the cached clone is silent in the pool folder until next acquire.
	local lifetime = _computeCloneLifetime(cloneRoot)
	task.delay(lifetime, function()
		if not cloneRoot.Parent then return end
		_killEmittersForRelease(cloneRoot)
		Pool.release(cloneRoot, target, kind, nil)
	end)
end

-- Fire dispatcher

--[[
	事件分发：校验 Enabled / 链深度 / burst 上限后，按 cfg.EmitTarget 与 cfg.Module 执行。
	达粒子上限时跳过 EmitTarget，Module 仍跑。

	@param particle table - PartIcles 实例
	@param pData table - 粒子状态；Events[eventName] 为冻结配置
	@param eventName string - OnEmit / OnHit / OnDeath / OnDestruction
	@param chainCtx table? - {ChainId, Depth}；nil 则新建
	@param payload table? - 已构建 payload；nil 时现场 makePayload
]]
function Events.fire(particle, pData, eventName, chainCtx, payload)
	chainCtx = chainCtx or Events.newChainCtx()
	local cfg = pData.Events and pData.Events[eventName]
	-- Enabled gate first; disabled events don't burn depth budget or warn.
	if not cfg or not cfg.Enabled then return end

	-- Two depth checks: fire-side (this event) and _emitTransformed-side (downstream fan-out).
	local depthLimit = math.clamp(math.floor(tonumber(cfg.ChainDepthLimit) or DEFAULT_CHAIN_DEPTH_LIMIT), 1, HARD_CHAIN_DEPTH_CEILING)
	if chainCtx.Depth >= depthLimit then
		Events.dropDepth(eventName)
		return
	end

	-- Nothing wired → no dispatch.
	if not cfg.EmitTarget and not cfg.Module then return end

	-- Backfill payload first so payload.X writes below don't nil-index.
	if not payload then
		payload = Events.makePayload(particle, pData, eventName, nil)
	end
	payload._eventName = payload._eventName or eventName

	-- Burst cap after config check.
	if not Events.reserveFrameFire() then return end

	payload.Source = payload.Source or pData._sourceItem
	payload.Particle = payload.Particle or pData.VisualPart
	payload.RenderTemplate = payload.RenderTemplate or payload.Particle

	-- Inject helpers only when Module runs (avoid closure alloc for EmitTarget-only events).
	if cfg.Module then
		payload.Emit = function(target, mode)
			Events.emitTargetInstance(particle, target, mode or cfg.EmitMode, payload, pData, chainCtx, depthLimit)
		end
		payload.Kill = function()
			if particle._killParticle then
				particle:_killParticle(pData, { fireOnDeath = false })
			end
		end
		-- Setters auto-flip the matching skip flag so per-frame graph writes don't clobber the override.
		EventsPayload.attachSkipSetters(payload, pData)
		payload.SetColor = function(color) EventsPayload.applyColor(pData, color) end
		payload.SetTransparency = function(amount) EventsPayload.applyTransparency(pData, amount) end
		payload.Teleport = function(cf) EventsPayload.applyTeleport(pData, cf) end
		EventsPayload.attachAdvancedSetters(payload, pData)
		payload.SetSpeedMultiplier = function(scalar)
			if type(scalar) == "number" then pData.SpeedMultiplier = scalar end
		end
		-- New total LifeTime in seconds. Clamped to 0.001 to avoid div-by-zero in
		-- the real_i (currentTime - StartTime) / LifeTime computation.
		payload.SetLifetime = function(seconds)
			if type(seconds) == "number" then pData.LifeTime = math.max(0.001, seconds) end
		end
	end

	-- Active-particle cap: skip cfg.EmitTarget when at cap, but always run Module.
	local capHit = #particle._activeEmits + (particle._lingerVisualCount or 0) >= (particle.MAX_ACTIVE_PARTICLES or 1000)

	if cfg.EmitTarget and not capHit then
		Events.emitTargetInstance(particle, cfg.EmitTarget, cfg.EmitMode, payload, pData, chainCtx, depthLimit)
	end

	if cfg.Module then
		local fn = Events.compile(cfg.Module)
		if fn then
			task.spawn(function()
				local ok, err = xpcall(fn, debug.traceback, payload)
				if not ok then Events.reportScriptError(cfg.Module, err) end
			end)
		end
	end
end

-- OnHit per-frame hook

-- Min displacement for a raycast; filters ReapplyLink / Orientation jitter.
local HIT_MIN_DIST = 0.05

--[[
	每帧 OnHit 射线。Stop 后 `_hitFired` 保持；干净 miss 重新武装。
	反向 Timescale 不打 OnHit，但更新 LastHitCheckPos，正放恢复时段落是新的。

	@param particle table - PartIcles 实例
	@param pData table - 粒子状态（Events.OnHit / LastHitCheckPos / HitParams）
	@param isDead boolean - 本帧是否死亡（仍可能打最后一段）
	@param currentTime number - os.clock，用于 HitCheckInterval
]]
function Events.afterUpdate(particle, pData, isDead, currentTime)
	if not pData.Events or not pData.Events.OnHit then return end
	if pData._lastEffectiveDt and pData._lastEffectiveDt < 0 then
		pData.LastHitCheckPos = Events.getWorldPosition(pData)
		pData.LastHitCheckTime = currentTime
		return
	end
	local newPos = Events.getWorldPosition(pData)
	if not newPos then return end
	if not pData.LastHitCheckPos then
		pData.LastHitCheckPos = newPos
		pData.LastHitCheckTime = currentTime
		return
	end

	-- HitCheckInterval throttle; LastHitCheckPos pins so segment grows during skip window.
	local interval = pData.Events.OnHit.HitCheckInterval or 0
	if interval > 0 then
		local lastT = pData.LastHitCheckTime or 0
		if currentTime - lastT < interval then return end
	end

	local prevPos = pData.LastHitCheckPos
	local prevTime = pData.LastHitCheckTime or currentTime
	local segmentDT = currentTime - prevTime
	if segmentDT <= 0 then segmentDT = 1/60 end
	local dir = newPos - prevPos
	if dir.Magnitude > HIT_MIN_DIST then
		local hit = workspace:Raycast(prevPos, dir, pData.HitParams)
		if hit then
			if not pData._hitFired then
				local payload = Events.makePayload(particle, pData, "OnHit", nil)
				payload.HitInstance = hit.Instance
				payload.Other = hit.Instance
				payload.HitPosition = hit.Position
				payload.HitNormal = hit.Normal
				Events.fire(particle, pData, "OnHit", pData.EventChainCtx, payload)

				-- "snap" → helper updated LastHitCheckPos, caller returns. "off" → caller continues.
				if EventsCollision.handle(particle, pData, hit, dir, segmentDT) == "snap" then return end
			end
		else
			-- Clean miss → particle has cleared the previous surface. Re-arm so the next
			-- surface contact can fire OnHit again (Off-mode per-collision behavior).
			-- Stop mode keeps `_hitFired` sticky via `_collisionStopped` so a link-moved
			-- frozen particle doesn't re-fire after being explicitly halted.
			if not pData._collisionStopped then
				pData._hitFired = false
			end
		end
		pData.LastHitCheckPos = newPos
		pData.LastHitCheckTime = currentTime
	end
end

return Events
