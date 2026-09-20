--[[
	Module: CombatWorld
	Description: 战斗仿真统一帧调度（一期 A 薄 World）
	Author: 林奥宇
	Created: 2026-08-12
	Last Modified: 2026-08-31

	================================================================================
	使用说明
	================================================================================

	【定位】
	- 战斗多实体仿真的唯一 Heartbeat 入口（本侧一条 Connect）。
	- 一期 A：只做 register / unregister / step，不强迫组件化。
	- 不绑 Remote、不碰 UI、不写 DataStore。存档型 SystemBUFF / Bag / Save 勿注册到此。

	【与同类模块】
	- 技能 Runtime / Hitbox 逻辑 Tick → 注册到本模块（Phase.SkillRuntime）。
	- EnemySim：逻辑怪批处理挂 Phase.EnemySim（二期 L1）。
	- SkillBuffUtil：一期 B 起由 UpdateManager 调 Init，挂 Phase.StatusEffect。写口仅 ServerSideCode.System；ToolSystem 为查询 stub。
	- PartIcles / FXUtil / SequenceManager：**永不迁入**（中立表现层；与战斗/技能门控正交；见总方案 §4.3.3）。

	【Phase 顺序（数值越小越先）】
	Cooldown(10) → EnemySim(15) → SkillRuntime(20) → Hitbox(30) → StatusEffect(40)

	【加载】
		local CombatWorld = Utils.CombatWorld
		CombatWorld.Init()
		local handle = CombatWorld.register("MyTick:1", function(dt) end, CombatWorld.Phase.SkillRuntime)
		handle:Disconnect() -- 等价 unregister

	【示例】
		-- Manager 启停
		CombatWorld.Init()
		-- BaseSkill 时钟收口（经 BaseSkillRuntimeHost.startClock）
		-- GroupSkill runtime 列表 Tick 注册到 Phase.SkillRuntime
]]

local RunService = game:GetService("RunService")

local CombatWorld = {}

-- ========================================
-- 常量
-- ========================================

CombatWorld.Phase = {
	Cooldown = 10,
	EnemySim = 15,
	SkillRuntime = 20,
	Hitbox = 30,
	StatusEffect = 40,
}

local DEFAULT_PHASE = CombatWorld.Phase.SkillRuntime

-- ========================================
-- 私有状态
-- ========================================

type TickFn = (deltaTime: number) -> ()

type Entry = {
	id: string,
	fn: TickFn,
	phase: number,
	order: number,
}

type Handle = {
	Connected: boolean,
	Disconnect: (self: Handle) -> (),
}

local _entriesById: { [string]: Entry } = {}
local _ordered: { Entry } = {}
local _orderDirty = false
local _nextOrder = 0
local _idSerial = 0
local _heartbeat: RBXScriptConnection? = nil
local _inited = false
local _stepping = false

--[[
	按 phase、注册序重排有序列表
]]
local function _rebuildOrdered()
	table.clear(_ordered)
	for _, entry in pairs(_entriesById) do
		table.insert(_ordered, entry)
	end
	table.sort(_ordered, function(a: Entry, b: Entry): boolean
		if a.phase ~= b.phase then
			return a.phase < b.phase
		end
		return a.order < b.order
	end)
	_orderDirty = false
end

--[[
	确保有序列表最新
]]
local function _ensureOrdered()
	if _orderDirty then
		_rebuildOrdered()
	end
end

--[[
	执行一帧（供 Heartbeat 与测试调用）
	@param deltaTime number - 帧间隔秒
]]
local function _stepInternal(deltaTime: number)
	if _stepping then
		return
	end
	_stepping = true
	_ensureOrdered()
	-- 拷贝长度，允许回调内 unregister 当前项（下一帧生效于有序表重建）
	local snapshot = _ordered
	for i = 1, #snapshot do
		local entry = snapshot[i]
		if entry and _entriesById[entry.id] == entry then
			local ok, err = pcall(entry.fn, deltaTime)
			if not ok then
				warn("[CombatWorld] tick error id=", entry.id, err)
			end
		end
	end
	_stepping = false
	if _orderDirty then
		_rebuildOrdered()
	end
end

--[[
	启动唯一 Heartbeat（幂等）
]]
local function _ensureHeartbeat()
	if _heartbeat then
		return
	end
	_heartbeat = RunService.Heartbeat:Connect(function(deltaTime: number)
		_stepInternal(deltaTime)
	end)
end

--[[
	停止 Heartbeat（无注册项时）
]]
local function _maybeStopHeartbeat()
	if next(_entriesById) ~= nil then
		return
	end
	if _heartbeat then
		_heartbeat:Disconnect()
		_heartbeat = nil
	end
end

-- ========================================
-- 公开 API
-- ========================================

--[[
	分配唯一注册 id
	@param prefix string? - 前缀，默认 "tick"
	@return string - 唯一 id
]]
function CombatWorld.allocId(prefix: string?): string
	_idSerial += 1
	local p = if type(prefix) == "string" and prefix ~= "" then prefix else "tick"
	return p .. ":" .. tostring(_idSerial)
end

--[[
	初始化（Manager 调用；幂等）。不强制占住 Heartbeat，首个 register 时再 Connect。
]]
function CombatWorld.Init()
	_inited = true
end

--[[
	是否已 Init
	@return boolean - 是否已执行 Init
]]
function CombatWorld.IsInited(): boolean
	return _inited
end

--[[
	当前注册条目数（调试用）
	@return number - 当前仍注册的 tick 条目数
]]
function CombatWorld.GetEntryCount(): number
	local n = 0
	for _ in pairs(_entriesById) do
		n += 1
	end
	return n
end

--[[
	是否已连接 Heartbeat
	@return boolean - Heartbeat 是否已 Connect
]]
function CombatWorld.IsHeartbeatConnected(): boolean
	return _heartbeat ~= nil
end

--[[
	注册每帧回调。同 id 重复注册会替换 fn/phase。
	@param id string - 唯一 id（可用 allocId）
	@param tickFn (deltaTime: number) -> () - 每帧回调
	@param phase number? - CombatWorld.Phase.*，默认 SkillRuntime
	@return Handle - 含 Disconnect；Connected 表示仍注册
]]
function CombatWorld.register(id: string, tickFn: TickFn, phase: number?): Handle
	assert(type(id) == "string" and id ~= "", "[CombatWorld] register: id 必须为非空 string")
	assert(type(tickFn) == "function", "[CombatWorld] register: tickFn 必须为 function")

	local phaseNum = if type(phase) == "number" then phase else DEFAULT_PHASE
	local existing = _entriesById[id]
	local order: number
	if existing then
		order = existing.order
	else
		_nextOrder += 1
		order = _nextOrder
	end

	_entriesById[id] = {
		id = id,
		fn = tickFn,
		phase = phaseNum,
		order = order,
	}
	_orderDirty = true
	_ensureHeartbeat()

	local handle: Handle
	handle = {
		Connected = true,
		Disconnect = function(self: Handle)
			if not self.Connected then
				return
			end
			self.Connected = false
			CombatWorld.unregister(id)
		end,
	}
	return handle
end

--[[
	取消注册（幂等）
	@param id string - register 时的 id
]]
function CombatWorld.unregister(id: string)
	if type(id) ~= "string" or id == "" then
		return
	end
	if _entriesById[id] == nil then
		return
	end
	_entriesById[id] = nil
	_orderDirty = true
	_maybeStopHeartbeat()
end

--[[
	手动推进一帧（单测 / 特殊驱动；正常由 Heartbeat 调用）
	@param deltaTime number - 帧间隔秒
]]
function CombatWorld.step(deltaTime: number)
	_stepInternal(deltaTime)
end

--[[
	清空全部注册并断开 Heartbeat（慎用；一般仅测试）
]]
function CombatWorld.resetForTests()
	table.clear(_entriesById)
	table.clear(_ordered)
	_orderDirty = false
	_maybeStopHeartbeat()
end

return CombatWorld