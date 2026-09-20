--[[
	Module: PartIcles.Pool
	Description: 发射视觉对象池：按源 LIFO、硬上限、环形溢出、TTL 回收
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-09-01

	功能：
	- acquire / release：按 RenderTemplate 源取还克隆视觉
	- acquireOrClone / acquireOrCopyBare：池未命中时 Clone 或 fromExisting
	- tickSweep / tickReport / tick：TTL 清扫与诊断打印
	- bumpGen / flushSource / flushAll：世代失效与整池清空

	与相关模块：
	- PoolHide 负责隐藏/显示与 Trail.Enabled 快照
	- TypeRegistry.write 编辑后调 bumpGen，避免脏克隆复用
	- Animate 模式不走池（视觉即活源）

	容量：cap = rate * TTL * 1.25 + 8；全局硬上限 MAX_POOL_TOTAL=2048
	世代：源上 `_PoolGen` 属性；write 时 +1，acquire 发现漂移则整源丢弃

	加载：由 PartIcles 引擎内部 require(script.Pool)，业务勿直接 require
]]

local PoolHide = require(script.Parent.PoolHide)

local Pool = {}

--[[
	取或创建空闲池 Folder（Terrain.Part_IclesPooled）。
	归还实例会再挂到此 Folder，便于 Explorer 识别可回收克隆。
	@return Folder - 池 Folder
]]
local function _getPoolFolder()
	local f = workspace.Terrain:FindFirstChild("Part_IclesPooled")
	if f then return f end
	f = Instance.new("Folder")
	f.Name = "Part_IclesPooled"
	f.Archivable = false
	f.Parent = workspace.Terrain
	return f
end

-- Weak-key so a destroyed RenderTemplate's pool entry can gc instead of leaking
-- the source instance + cached visuals across un-transform / re-transform cycles.
Pool._pools = setmetatable({}, {__mode = "k"})  -- [sourceRT] = {entries, gen, cap, peakSize, hits, misses, evictions}
Pool._totalSize = 0
Pool._lastSweepAt = 0
Pool._lastReportAt = 0

Pool.MAX_POOL_TOTAL = 2048
Pool.TTL = 5
Pool.SWEEP_INTERVAL = 2
Pool.REPORT_INTERVAL = 0        -- 0 disables the periodic Output print
Pool.MIN_CAP = 8
Pool.CAP_SAFETY = 1.25

--[[
	按发射速率估算单源容量上限
	@param rate number? - 发射速率；nil/负值按 0
	@return number - ceil(rate * TTL * CAP_SAFETY) + MIN_CAP
]]
local function _estimateCap(rate)
	local r = math.max(rate or 0, 0)
	return math.ceil(r * Pool.TTL * Pool.CAP_SAFETY) + Pool.MIN_CAP
end

--[[
	取或初始化某源的池表
	@param source Instance - RenderTemplate 源
	@return table - {entries, gen, cap, peakSize, hits, misses, evictions}；entries 为 LIFO {instance, pooledAt}
]]
local function _getOrInitPool(source)
	local p = Pool._pools[source]
	if p then return p end
	p = {
		entries = {},                              -- LIFO of {instance, pooledAt}
		gen = source:GetAttribute("_PoolGen") or 0,
		cap = Pool.MIN_CAP,
		peakSize = 0,
		hits = 0, misses = 0, evictions = 0,
	}
	Pool._pools[source] = p
	return p
end

--[[
	销毁池条目中的 Instance
	@param entry table? - {instance: Instance?}；nil 则跳过
	@return () - 无返回值
]]
local function _destroyEntry(entry)
	if entry and entry.instance then
		pcall(function() entry.instance:Destroy() end)
	end
end

--[[
	清空某源池内全部条目并修正全局计数
	@param pool table - _getOrInitPool 返回的池表
	@return () - 无返回值
]]
local function _discardAllEntries(pool)
	for i = 1, #pool.entries do _destroyEntry(pool.entries[i]) end
	Pool._totalSize = math.max(0, Pool._totalSize - #pool.entries)
	pool.entries = {}
end

--[[
	弹出一条存活条目；调用方须像新 Clone 一样还原全部视觉属性。
	@param source Instance? - RenderTemplate 源；nil 返回 nil
	@param kind string - PoolHide 种类（如 "Highlight" / "TrailEmitter"）
	@return Instance? - 可复用实例；池空或实例已销毁时 nil
]]
function Pool.acquire(source, kind)
	if not source then return nil end
	local pool = _getOrInitPool(source)
	local sourceGen = source:GetAttribute("_PoolGen") or 0
	if sourceGen ~= pool.gen then
		-- Generation drifted; flush all entries.
		_discardAllEntries(pool)
		pool.gen = sourceGen
	end
	while #pool.entries > 0 do
		local entry = table.remove(pool.entries)
		Pool._totalSize = math.max(0, Pool._totalSize - 1)
		local inst = entry.instance
		if inst and inst.Parent then
			PoolHide.show(inst, kind)
			pool.hits += 1
			return inst
		end
	end
	pool.misses += 1
	return nil
end

--[[
	归还实例。全局满则 Destroy；单源满则环形踢出最旧条目。
	@param instance Instance? - 待归还克隆
	@param source Instance? - 对应 RenderTemplate 源
	@param kind string - PoolHide 种类
	@param rate number? - 有值时重算 pool.cap
	@return () - 无返回值
]]
function Pool.release(instance, source, kind, rate)
	if not instance or not source then return end
	if not instance.Parent then return end
	local pool = _getOrInitPool(source)
	if rate then pool.cap = _estimateCap(rate) end
	if Pool._totalSize >= Pool.MAX_POOL_TOTAL then
		pcall(function() instance:Destroy() end)
		return
	end
	while #pool.entries >= pool.cap do
		local oldest = table.remove(pool.entries, 1)  -- O(n) shift, n <= cap
		Pool._totalSize = math.max(0, Pool._totalSize - 1)
		_destroyEntry(oldest)
		pool.evictions += 1
	end
	PoolHide.hide(instance, kind)
	-- Re-parent idle entry into the visible pool folder so the user can see, at any moment,
	-- which clones are recyclable. PoolHide already teleported / disabled it; reparent now
	-- so the Explorer reflects the idle state.
	pcall(function() instance.Parent = _getPoolFolder() end)
	pool.entries[#pool.entries + 1] = { instance = instance, pooledAt = os.clock() }
	Pool._totalSize += 1
	if #pool.entries > pool.peakSize then pool.peakSize = #pool.entries end
end

--[[
	TTL 清扫，单帧预算 64 条，避免巨池卡帧。
	@param now number - os.clock() 或引擎传入的当前时间
	@return () - 无返回值
]]
function Pool.tickSweep(now)
	if (now - Pool._lastSweepAt) < Pool.SWEEP_INTERVAL then return end
	Pool._lastSweepAt = now
	local budget = 64
	-- Collect drained sources to drop after iteration; mutating Pool._pools while
	-- iterating it would skip / double-visit entries. A pool is droppable when its
	-- entries list is empty AND its source RT has been destroyed (no Parent), so
	-- live RTs that just hit a quiet stretch keep their stats.
	local toDrop = nil
	for source, pool in pairs(Pool._pools) do
		local i = 1
		while i <= #pool.entries and budget > 0 do
			local entry = pool.entries[i]
			local inst = entry.instance
			local stale = (now - entry.pooledAt) > Pool.TTL or not inst or not inst.Parent
			if stale then
				_destroyEntry(entry)
				local n = #pool.entries
				if i < n then pool.entries[i] = pool.entries[n] end
				pool.entries[n] = nil
				Pool._totalSize = math.max(0, Pool._totalSize - 1)
				pool.evictions += 1
				budget -= 1
				-- Don't advance i; current slot now holds what was at the end.
			else
				i += 1
			end
		end
		if #pool.entries == 0 and (not source or not source.Parent) then
			toDrop = toDrop or {}
			toDrop[#toDrop + 1] = source
		end
	end
	if toDrop then
		for _, source in ipairs(toDrop) do
			Pool._pools[source] = nil
		end
	end
end

--[[
	由 TypeRegistry.write 调用，使该源旧外观池条目失效。
	@param source Instance? - RenderTemplate 源
	@return () - 无返回值
]]
function Pool.bumpGen(source)
	if not source then return end
	local cur = source:GetAttribute("_PoolGen") or 0
	pcall(function() source:SetAttribute("_PoolGen", cur + 1) end)
end

--[[
	源 RT 销毁时丢掉该源整池。
	@param source Instance - RenderTemplate 源
	@return () - 无返回值
]]
function Pool.flushSource(source)
	local pool = Pool._pools[source]
	if not pool then return end
	_discardAllEntries(pool)
	Pool._pools[source] = nil
end

--[[
	清空全部池；Particle:Deactivate 调用。
	@return () - 无返回值
]]
function Pool.flushAll()
	for _, pool in pairs(Pool._pools) do
		_discardAllEntries(pool)
	end
	Pool._pools = setmetatable({}, {__mode = "k"})
	Pool._totalSize = 0
end

--[[
	聚合诊断 print，受 REPORT_INTERVAL 门控（0 关闭）。
	@param now number - 当前时间
	@return () - 无返回值
]]
function Pool.tickReport(now)
	if Pool.REPORT_INTERVAL <= 0 then return end
	if (now - Pool._lastReportAt) < Pool.REPORT_INTERVAL then return end
	Pool._lastReportAt = now
	local poolCount, totalEntries, totalHits, totalMisses, totalEvictions, peakAcross = 0, 0, 0, 0, 0, 0
	for _ in pairs(Pool._pools) do poolCount += 1 end
	for _, pool in pairs(Pool._pools) do
		totalEntries += #pool.entries
		totalHits += pool.hits
		totalMisses += pool.misses
		totalEvictions += pool.evictions
		if pool.peakSize > peakAcross then peakAcross = pool.peakSize end
	end
	local hitRate = (totalHits + totalMisses) > 0 and (totalHits / (totalHits + totalMisses) * 100) or 0
	print(string.format(
		"[Part-Icles Pool] sources=%d entries=%d/%d peak=%d hits=%d misses=%d (%.1f%% hit) evictions=%d",
		poolCount, totalEntries, Pool.MAX_POOL_TOTAL, peakAcross, totalHits, totalMisses, hitRate, totalEvictions
	))
end

--[[
	取池或 Clone。打 `_PartIcleEmit` 标记供下游识别。
	`pooled=false` 每次强制新克隆且不走归还；嵌套 Trail/PE 始终反映作者 RT 属性。
	@param rt Instance - RenderTemplate
	@param kind string - PoolHide 种类
	@param pooled boolean? - false 强制 Clone；其余走池
	@return Instance - 带 _PartIcleEmit 的实例
]]
function Pool.acquireOrClone(rt, kind, pooled)
	local inst
	if pooled == false then
		inst = rt:Clone()
	else
		inst = Pool.acquire(rt, kind) or rt:Clone()
	end
	inst:SetAttribute("_PartIcleEmit", true)
	return inst
end

--[[
	用 Instance.fromExisting 重建 RT 子树，跳过 Transformed 分支
	（嵌套 SOURCE Part-Icles 由 NestedEmit 单独发射）。
	@param source Instance - 当前复制节点
	@param map table? - 源→克隆映射；nil 时新建
	@param isRoot boolean? - nil/true 时重绑本子树 Trail/Beam Attachment0/1
	@return Instance - 裸克隆根
	@return table - 源→克隆映射
]]
local function _copyBare(source, map, isRoot)
	map = map or {}
	local bare = Instance.fromExisting(source)
	map[source] = bare
	for _, child in ipairs(source:GetChildren()) do
		if not child:GetAttribute("Transformed") then
			_copyBare(child, map, false).Parent = bare
		end
	end
	-- Rebind intra-subtree Trail/Beam Attachment0/1. fromExisting copies refs
	-- verbatim; only Instance:Clone auto-rebinds. Cross-subtree refs (map miss)
	-- left for nested-context _parentCloneMap pass at consumer site.
	if isRoot == nil or isRoot then
		for src, clone in pairs(map) do
			if src:IsA("Trail") or src:IsA("Beam") then
				local a0, a1 = src.Attachment0, src.Attachment1
				if a0 and map[a0] then clone.Attachment0 = map[a0] end
				if a1 and map[a1] then clone.Attachment1 = map[a1] end
			end
		end
	end
	return bare, map
end
Pool.copyBare = _copyBare

-- Weak-keyed by clone root. Map auto-GC's with the clone; pool-hits reuse it
-- until _PoolGen drifts (mutation evicts pool entry, next acquire rebuilds).
Pool._cloneMaps = setmetatable({}, {__mode = "k"})

--[[
	取池或 _copyBare。池命中复用 _cloneMaps；世代漂移后下次重建。
	@param rt Instance - RenderTemplate
	@param kind string - PoolHide 种类
	@param pooled boolean? - false 强制 _copyBare
	@return Instance - 带 _PartIcleEmit 的实例
]]
function Pool.acquireOrCopyBare(rt, kind, pooled)
	local inst, map
	if pooled == false then
		inst, map = _copyBare(rt)
	else
		inst = Pool.acquire(rt, kind)
		if inst then
			map = Pool._cloneMaps[inst]
		else
			inst, map = _copyBare(rt)
		end
	end
	if map then Pool._cloneMaps[inst] = map end
	inst:SetAttribute("_PartIcleEmit", true)
	return inst
end

--[[
	须在写入新生成 CFrame 并挂 Parent 之后调用。延迟一帧恢复 Trail.Enabled，
	避免渲染器用上一发射死亡位画出第一条线段。无 `_pooledTrailEnabled` 的新克隆为空操作。
	@param instance Instance - 刚挂出的视觉
	@param kind string - PoolHide 种类
	@return () - 无返回值
]]
function Pool.restoreTrails(instance, kind)
	task.delay(0, function()
		if not instance or not instance.Parent then return end
		PoolHide.restoreTrails(instance, kind)
	end)
end

--[[
	Heartbeat 钩子；清扫与报告各自按间隔门控。
	@param now number - 当前时间
	@return () - 无返回值
]]
function Pool.tick(now)
	Pool.tickSweep(now)
	Pool.tickReport(now)
end

--[[
	聚合诊断快照（不打印）。
	@return table - {totalSize: number, sources: {[Instance]: {size, peakSize, cap, gen, hits, misses, evictions}}}
]]
function Pool.stats()
	local out = { totalSize = Pool._totalSize, sources = {} }
	for source, pool in pairs(Pool._pools) do
		out.sources[source] = {
			size = #pool.entries, peakSize = pool.peakSize, cap = pool.cap, gen = pool.gen,
			hits = pool.hits, misses = pool.misses, evictions = pool.evictions,
		}
	end
	return out
end

return Pool
