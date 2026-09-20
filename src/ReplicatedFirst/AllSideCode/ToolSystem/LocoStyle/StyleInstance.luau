--[[
	Module: LocoStyle.StyleInstance
	Description: 角色级基轨风格控制器工厂（StyleStack 合成、bindBaseAction、Gate 推迟 rebind）
	Author: 林奥宇
	Created: 2026-09-01
	Last Modified: 2026-09-01

	仅由 LocoStyle.init Create / GetForCharacter 调用；业务请走 Utils.LocoStyle。
	不写 WalkSpeed / CFrame；只换 Animate 基轨资源。
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local LocoStyleSets = Utils.LocoStyleSets
local AnimationModule = Utils.AnimationModule
local SkillPreloadUtil = Utils.SkillPreloadUtil
local Log = Utils.Log

local StyleInstance = {}

-- ========================================
-- 常量
-- ========================================

local ASSET_PREFIX = "http://www.roblox.com/asset/?id="
local BASE_SOURCE = "__base__"

export type PriorityBand = {
	Base: number,
	Equip: number,
	Transform: number,
	Level: number,
}

--[[
	Create 依赖
	- animate: bindBaseAction(slot, actionData) / resumeBaseAction / invalidateBasePose / BaseActionEnabled
	- arbiter: GetSnapshot() → { pauseBaseTracks: boolean? }；OnChanged(cb) → unsubscribe
	- resyncAfterBaseUnpause: 解闸后按当前意图直切稳定态（跳过 Start*）
	- footStepMarkersFor: 可选；槽名 → Marker 回调表
]]
export type CreateDeps = {
	animate: any,
	arbiter: any,
	resyncAfterBaseUnpause: () -> (),
	footStepMarkersFor: ((slot: string) -> { [string]: (string) -> () })?,
}

export type LocoStyleController = {
	Apply: (self: LocoStyleController, styleId: string) -> boolean,
	SetBaseStyle: (self: LocoStyleController, styleId: string) -> boolean,
	PushStyle: (self: LocoStyleController, source: string, styleId: string, priority: number?) -> boolean,
	PopStyle: (self: LocoStyleController, source: string) -> boolean,
	Reset: (self: LocoStyleController) -> boolean,
	GetActiveStyleId: (self: LocoStyleController) -> string,
	GetAppliedStyleId: (self: LocoStyleController) -> string?,
	FlushPending: (self: LocoStyleController) -> (),
	destroy: (self: LocoStyleController) -> (),
}

type StackEntry = {
	source: string,
	styleId: string,
	priority: number,
	order: number,
}

type SlotBindMeta = {
	Priority: Enum.AnimationPriority,
	Looped: boolean?,
	FootStep: boolean?,
}

type StyleState = {
	character: Model,
	animate: any,
	arbiter: any,
	resyncAfterBaseUnpause: () -> (),
	footStepMarkersFor: ((slot: string) -> { [string]: (string) -> () })?,
	stack: { StackEntry },
	pushOrder: number,
	desiredStyleId: string,
	appliedStyleId: string?,
	pendingStyleId: string?,
	destroyed: boolean,
	unsubGate: (() -> ())?,
	controller: LocoStyleController?,
}

StyleInstance.Priority = table.freeze({
	Base = 0,
	Equip = 10,
	Transform = 50,
	Level = 100,
}) :: PriorityBand

local SLOT_BIND_META: { [string]: SlotBindMeta } = {
	Walk = { Priority = Enum.AnimationPriority.Movement, FootStep = true },
	Walk_Left = { Priority = Enum.AnimationPriority.Movement, FootStep = true },
	Walk_Right = { Priority = Enum.AnimationPriority.Movement, FootStep = true },
	Walk_Back = { Priority = Enum.AnimationPriority.Movement, FootStep = true },
	Run = { Priority = Enum.AnimationPriority.Movement, FootStep = true },
	Run_Left = { Priority = Enum.AnimationPriority.Movement, FootStep = true },
	Run_Right = { Priority = Enum.AnimationPriority.Movement, FootStep = true },
	Run_Back = { Priority = Enum.AnimationPriority.Movement, FootStep = true },
	Swim = { Priority = Enum.AnimationPriority.Movement },
	SwimIdle = { Priority = Enum.AnimationPriority.Idle },
	Idle = { Priority = Enum.AnimationPriority.Idle },
	StartRun = { Priority = Enum.AnimationPriority.Movement, Looped = false },
	StopRun = { Priority = Enum.AnimationPriority.Movement, Looped = false },
	StartWalk = { Priority = Enum.AnimationPriority.Movement, Looped = false },
	StopWalk = { Priority = Enum.AnimationPriority.Movement, Looped = false },
	Jump = { Priority = Enum.AnimationPriority.Movement },
	Fall = { Priority = Enum.AnimationPriority.Movement },
	Land = { Priority = Enum.AnimationPriority.Action },
	LightLand = { Priority = Enum.AnimationPriority.Action },
	Climb = { Priority = Enum.AnimationPriority.Movement },
}

for _, entry in pairs(SLOT_BIND_META) do
	table.freeze(entry)
end
table.freeze(SLOT_BIND_META)

-- ========================================
-- 私有变量
-- ========================================

local _instances: { [Model]: LocoStyleController } = setmetatable({}, { __mode = "k" }) :: any

-- ========================================
-- 私有函数
-- ========================================

--[[
	规范化 styleId：未知风格 warn 并回退 Default
	@param styleId string - 请求风格
	@return string - 可用风格 ID
]]
local function _normalizeStyleId(styleId: string): string
	if type(styleId) ~= "string" or styleId == "" then
		return LocoStyleSets.DEFAULT_STYLE_ID
	end
	if not LocoStyleSets.HasStyle(styleId) then
		Log.warn("[LocoStyle] 未知风格，回退 Default:", styleId)
		return LocoStyleSets.DEFAULT_STYLE_ID
	end
	return styleId
end

--[[
	当前 Gate 是否 pauseBaseTracks（不宜立刻续播）
	@param arbiter any - ActionArbiter 实例（须含 GetSnapshot）
	@return boolean - Gate 是否 pauseBaseTracks
]]
local function _isPauseBase(arbiter: any): boolean
	if not arbiter or not arbiter.GetSnapshot then
		return false
	end
	local snap = arbiter:GetSnapshot()
	return snap ~= nil and snap.pauseBaseTracks == true
end

--[[
	从栈合成最终 styleId（priority 高者胜；同 priority 取后写入 order 更大者）
	@param stack { StackEntry } - 风格栈（低到高写入序）
	@return string - 合成后的 styleId
]]
local function _resolveStackStyleId(stack: { StackEntry }): string
	if #stack == 0 then
		return LocoStyleSets.DEFAULT_STYLE_ID
	end
	local best = stack[1]
	for i = 2, #stack do
		local entry = stack[i]
		if entry.priority > best.priority then
			best = entry
		elseif entry.priority == best.priority and entry.order >= best.order then
			best = entry
		end
	end
	return best.styleId
end

--[[
	写入或替换某 source 的栈项
	@param state StyleState - 控制器状态
	@param source string - 栈条目来源键（如 Equip / Transform）
	@param styleId string - 风格 ID
	@param priority number - 优先级（高者胜）
	@return nil - 无返回值
]]
local function _upsertStack(state: StyleState, source: string, styleId: string, priority: number)
	local normalized = _normalizeStyleId(styleId)
	state.pushOrder += 1
	for _, entry in ipairs(state.stack) do
		if entry.source == source then
			entry.styleId = normalized
			entry.priority = priority
			entry.order = state.pushOrder
			return
		end
	end
	table.insert(state.stack, {
		source = source,
		styleId = normalized,
		priority = priority,
		order = state.pushOrder,
	})
end

--[[
	移除 source；返回是否曾存在
	@param state StyleState - 控制器状态
	@param source string - 栈条目来源键
	@return boolean - 曾存在并已移除为 true
]]
local function _removeSource(state: StyleState, source: string): boolean
	for i, entry in ipairs(state.stack) do
		if entry.source == source then
			table.remove(state.stack, i)
			return true
		end
	end
	return false
end

--[[
	按风格批量 bindBaseAction；可选 invalidate + resync
	@param state StyleState - 控制器状态
	@param styleId string - 已规范化风格
	@param shouldResync boolean? - false=仅绑轨（启动引导）；默认 true
	@return nil - 无返回值
]]
local function _applyNow(state: StyleState, styleId: string, shouldResync: boolean?)
	if state.destroyed then
		return
	end

	local doResync = shouldResync ~= false
	local animate = state.animate
	local footStepMarkersFor = state.footStepMarkersFor

	local animNames = LocoStyleSets.ListAnimNamesForStyle(styleId)
	if SkillPreloadUtil and SkillPreloadUtil.PreloadAnimations then
		SkillPreloadUtil.PreloadAnimations(animNames)
	end

	for _, slot in ipairs(LocoStyleSets.SLOT_ORDER) do
		local meta = SLOT_BIND_META[slot]
		local animName = LocoStyleSets.ResolveAnimName(styleId, slot)
		if not meta or not animName then
			continue
		end
		local animId = AnimationModule.GetAnimID(animName)
		if not animId then
			Log.warn("[LocoStyle] 缺动画 ID，跳过槽:", slot, animName)
			continue
		end

		local actionData: { [string]: any } = {
			ID = ASSET_PREFIX .. tostring(animId),
			Priority = meta.Priority,
		}
		if meta.Looped == false then
			actionData.Looped = false
		end
		if meta.FootStep == true and type(footStepMarkersFor) == "function" then
			actionData.MarkerEvents = footStepMarkersFor(slot)
		end
		animate:bindBaseAction(slot, actionData)
	end

	state.appliedStyleId = styleId
	state.pendingStyleId = nil

	if not doResync then
		return
	end

	if _isPauseBase(state.arbiter) then
		-- 轨已换；续播等解闸 Flush
		state.pendingStyleId = styleId
		return
	end

	if animate.BaseActionEnabled == false then
		animate:resumeBaseAction()
	end
	animate:invalidateBasePose()
	state.resyncAfterBaseUnpause()
end

--[[
	栈变更后驱动 Apply / defer
	@param state StyleState - 控制器状态
	@return nil - 无返回值
]]
local function _commitDesired(state: StyleState)
	if state.destroyed then
		return
	end
	state.desiredStyleId = _resolveStackStyleId(state.stack)
	if state.appliedStyleId == state.desiredStyleId and state.pendingStyleId == nil then
		return
	end
	if _isPauseBase(state.arbiter) then
		state.pendingStyleId = state.desiredStyleId
		return
	end
	_applyNow(state, state.desiredStyleId, true)
end

--[[
	设置 base 风格并立刻提交
	@param state StyleState - 控制器状态
	@param styleId string - 风格 ID
	@return boolean - 成功
]]
local function _setBaseStyle(state: StyleState, styleId: string): boolean
	if state.destroyed then
		return false
	end
	if type(styleId) ~= "string" or styleId == "" then
		return false
	end
	_upsertStack(state, BASE_SOURCE, styleId, StyleInstance.Priority.Base)
	_commitDesired(state)
	return true
end

--[[
	压入覆盖风格（source 不可为 base）
	@param state StyleState - 控制器状态
	@param source string - 栈来源键
	@param styleId string - 风格 ID
	@param priority number? - 默认 Priority.Equip
	@return boolean - 成功
]]
local function _pushStyle(state: StyleState, source: string, styleId: string, priority: number?): boolean
	if state.destroyed then
		return false
	end
	if type(source) ~= "string" or source == "" or source == BASE_SOURCE then
		Log.warn("[LocoStyle.PushStyle] source 非法:", source)
		return false
	end
	if type(styleId) ~= "string" or styleId == "" then
		return false
	end
	local p = priority
	-- NaN 与非 number 一律回落 Equip，避免异常优先级数打乱合成
	if type(p) ~= "number" or p ~= p then
		p = StyleInstance.Priority.Equip
	end
	_upsertStack(state, source, styleId, p)
	_commitDesired(state)
	return true
end

--[[
	弹出某 source 覆盖
	@param state StyleState - 控制器状态
	@param source string - 栈来源键
	@return boolean - 曾存在并已移除
]]
local function _popStyle(state: StyleState, source: string): boolean
	if state.destroyed then
		return false
	end
	if type(source) ~= "string" or source == "" or source == BASE_SOURCE then
		Log.warn("[LocoStyle.PopStyle] source 非法:", source)
		return false
	end
	if not _removeSource(state, source) then
		return false
	end
	_commitDesired(state)
	return true
end

--[[
	清空栈并回到 Default base
	@param state StyleState - 控制器状态
	@return boolean - 成功
]]
local function _reset(state: StyleState): boolean
	if state.destroyed then
		return false
	end
	table.clear(state.stack)
	_upsertStack(state, BASE_SOURCE, LocoStyleSets.DEFAULT_STYLE_ID, StyleInstance.Priority.Base)
	_commitDesired(state)
	return true
end

--[[
	闸解 pause 后补一次 bind/resync
	@param state StyleState - 控制器状态
	@return nil - 无返回值
]]
local function _flushPending(state: StyleState)
	if state.destroyed then
		return
	end
	if _isPauseBase(state.arbiter) then
		return
	end
	local target = state.pendingStyleId or state.desiredStyleId
	if state.appliedStyleId == target and state.pendingStyleId == nil then
		return
	end
	_applyNow(state, target, true)
end

--[[
	退订 Gate 并移除弱表实例
	@param state StyleState - 控制器状态
	@return nil - 无返回值
]]
local function _destroy(state: StyleState)
	if state.destroyed then
		return
	end
	state.destroyed = true
	if state.unsubGate then
		state.unsubGate()
		state.unsubGate = nil
	end
	table.clear(state.stack)
	state.pendingStyleId = nil
	local controller = state.controller
	if controller and _instances[state.character] == controller then
		_instances[state.character] = nil
	end
end

-- ========================================
-- 公共函数
-- ========================================

--[[
	创建角色级 LocoStyle 控制器（重复 Create 返回已有实例）
	@param character Model - 角色
	@param deps CreateDeps - animate / arbiter / resync / 脚步 Marker 工厂
	@return LocoStyleController - 角色级控制器
]]
function StyleInstance.create(character: Model, deps: CreateDeps): LocoStyleController
	local existing = _instances[character]
	if existing then
		return existing
	end

	assert(deps and deps.animate, "[LocoStyle.Create] deps.animate 必填")
	assert(deps and deps.arbiter, "[LocoStyle.Create] deps.arbiter 必填")
	assert(deps and type(deps.resyncAfterBaseUnpause) == "function", "[LocoStyle.Create] deps.resyncAfterBaseUnpause 必填")

	local state: StyleState = {
		character = character,
		animate = deps.animate,
		arbiter = deps.arbiter,
		resyncAfterBaseUnpause = deps.resyncAfterBaseUnpause,
		footStepMarkersFor = deps.footStepMarkersFor,
		stack = {},
		pushOrder = 0,
		desiredStyleId = LocoStyleSets.DEFAULT_STYLE_ID,
		appliedStyleId = nil,
		pendingStyleId = nil,
		destroyed = false,
		unsubGate = nil,
		controller = nil,
	}

	local controller = {} :: LocoStyleController
	function controller:SetBaseStyle(styleId: string): boolean
		return _setBaseStyle(state, styleId)
	end
	function controller:Apply(styleId: string): boolean
		return self:SetBaseStyle(styleId)
	end
	function controller:PushStyle(source: string, styleId: string, priority: number?): boolean
		return _pushStyle(state, source, styleId, priority)
	end
	function controller:PopStyle(source: string): boolean
		return _popStyle(state, source)
	end
	function controller:Reset(): boolean
		return _reset(state)
	end
	function controller:GetActiveStyleId(): string
		return state.desiredStyleId
	end
	function controller:GetAppliedStyleId(): string?
		return state.appliedStyleId
	end
	function controller:FlushPending()
		_flushPending(state)
	end
	function controller:destroy()
		_destroy(state)
	end

	state.controller = controller
	-- 初始 base = Default，仅绑轨；姿态由 GroundLocomotion 后续驱动（与历史 init 一致）
	_upsertStack(state, BASE_SOURCE, LocoStyleSets.DEFAULT_STYLE_ID, StyleInstance.Priority.Base)
	state.desiredStyleId = LocoStyleSets.DEFAULT_STYLE_ID
	_applyNow(state, state.desiredStyleId, false)

	state.unsubGate = state.arbiter:OnChanged(function(_snap)
		_flushPending(state)
	end)

	_instances[character] = controller
	return controller
end

--[[
	查询已 create 的实例；未创建返回 nil（不偷偷新建）
	@param character Model - 角色
	@return LocoStyleController? - 已 Create 的实例；未创建为 nil
]]
function StyleInstance.get(character: Model): LocoStyleController?
	if typeof(character) ~= "Instance" or not character:IsA("Model") then
		return nil
	end
	return _instances[character]
end

return StyleInstance
