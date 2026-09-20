--[[
	Module: ActionArbiter.GateInstance
	Description: 角色级闸实例工厂（claims 合成、Acquire/Release、TTL Heartbeat、Attribute Bridge）
	Author: 林奥宇
	Created: 2026-09-01
	Last Modified: 2026-09-01

	仅由 ActionArbiter.init Create / GetForCharacter 调用；业务请走 Utils.ActionArbiter。
	不写 WalkSpeed / CFrame；只维护表现占用快照。
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Log = Utils.Log
local RunService = Utils.RunService

local Constants = require(script.Parent.Constants)
local Bridge = require(script.Parent.Bridge)

export type FacingOwner = "Animate" | "External" | "None"
export type CameraOwner = "Default" | "External" | "None"

export type AcquireOptions = {
	ownerId: string,
	priority: number,
	blendPolicy: string?,
	suppressLoco: boolean?,
	pauseBaseTracks: boolean?,
	facingOwner: FacingOwner?,
	cameraOwner: CameraOwner?,
	reason: string?,
	ttlSeconds: number?,
}

export type GateSnapshot = {
	suppressLoco: boolean,
	pauseBaseTracks: boolean,
	facingOwner: FacingOwner,
	cameraOwner: CameraOwner,
	activeOwnerId: string?,
	activeOwners: { string },
	reason: string?,
}

export type CreateOptions = {
	localPlayer: Player?,
	enableAttributeBridge: boolean?,
	enableJetPacking: boolean?,
	enableFacingOverride: boolean?,
	enableSkillActionLock: boolean?,
}

export type ExpandedBlendPolicy = {
	suppressLoco: boolean,
	pauseBaseTracks: boolean,
	facingOwner: FacingOwner?,
}

export type ActionArbiterInstance = {
	Acquire: (self: ActionArbiterInstance, options: AcquireOptions) -> string,
	Release: (self: ActionArbiterInstance, token: string) -> boolean,
	ReleaseByOwner: (self: ActionArbiterInstance, ownerId: string) -> boolean,
	GetSnapshot: (self: ActionArbiterInstance) -> GateSnapshot,
	IsLocoSuppressed: (self: ActionArbiterInstance) -> boolean,
	GetFacingOwner: (self: ActionArbiterInstance) -> FacingOwner,
	GetCameraOwner: (self: ActionArbiterInstance) -> CameraOwner,
	OnChanged: (self: ActionArbiterInstance, callback: (GateSnapshot) -> ()) -> () -> (),
	destroy: (self: ActionArbiterInstance) -> (),
	Character: Model,
}

type Claim = {
	token: string,
	ownerId: string,
	priority: number,
	suppressLoco: boolean,
	pauseBaseTracks: boolean?,
	facingOwner: FacingOwner?,
	cameraOwner: CameraOwner?,
	reason: string?,
	expireAt: number?,
	seq: number,
	blendPolicy: string?,
}

type ExpandFn = (string?) -> ExpandedBlendPolicy

type GateState = {
	character: Model,
	claims: { [string]: Claim },
	snapshot: GateSnapshot,
	changedCallbacks: { (GateSnapshot) -> () },
	bridgeDisconnect: (() -> ())?,
	heartbeatConn: RBXScriptConnection?,
	destroyed: boolean,
	expandBlendPolicy: ExpandFn,
	instance: ActionArbiterInstance?,
}

local GateInstance = {}

local _instances: { [Model]: ActionArbiterInstance } = setmetatable({}, { __mode = "k" }) :: any
local _tokenSeq = 0
local _claimSeq = 0

--[[
	收集当前 claim 的 ownerId 并排序
	@param claims { [string]: Claim } - token → claim
	@return { string } - 排序后的 ownerId 列表
]]
local function _copyActiveOwners(claims: { [string]: Claim }): { string }
	local list = {}
	for _, claim in pairs(claims) do
		table.insert(list, claim.ownerId)
	end
	table.sort(list)
	return list
end

--[[
	快照字段拷贝（activeOwners 浅拷贝列表）
	@param src GateSnapshot - 内部缓存
	@return GateSnapshot - 对外只读副本
]]
local function _cloneSnapshot(src: GateSnapshot): GateSnapshot
	return {
		suppressLoco = src.suppressLoco,
		pauseBaseTracks = src.pauseBaseTracks,
		facingOwner = src.facingOwner,
		cameraOwner = src.cameraOwner,
		activeOwnerId = src.activeOwnerId,
		activeOwners = table.clone(src.activeOwners),
		reason = src.reason,
	}
end

--[[
	空闲闸快照（无占用）
	@return GateSnapshot - 默认快照
]]
local function _defaultSnapshot(): GateSnapshot
	return {
		suppressLoco = false,
		pauseBaseTracks = false,
		facingOwner = Constants.FacingOwner.Animate :: FacingOwner,
		cameraOwner = Constants.CameraOwner.Default :: CameraOwner,
		activeOwnerId = nil,
		activeOwners = {},
		reason = nil,
	}
end

--[[
	比较两份快照核心字段是否相同（不含 activeOwners 列表）
	@param a GateSnapshot - 左
	@param b GateSnapshot - 右
	@return boolean - 核心字段全等为 true
]]
local function _snapshotsEqual(a: GateSnapshot, b: GateSnapshot): boolean
	return a.suppressLoco == b.suppressLoco
		and a.pauseBaseTracks == b.pauseBaseTracks
		and a.facingOwner == b.facingOwner
		and a.cameraOwner == b.cameraOwner
		and a.activeOwnerId == b.activeOwnerId
end

--[[
	合并 Acquire 显式字段与 blendPolicy 展开结果
	@param options AcquireOptions - 显式字段与可选 blendPolicy
	@param expandBlendPolicy ExpandFn - ActionArbiter.ExpandBlendPolicy
	@return boolean - 是否 suppressLoco
	@return boolean? - pauseBaseTracks；nil 表示跟随 suppress
	@return FacingOwner? - 朝向占用方；nil 表示不声明
	@return CameraOwner? - 相机占用方；nil 表示不声明
]]
local function _resolveClaimFields(
	options: AcquireOptions,
	expandBlendPolicy: ExpandFn
): (boolean, boolean?, FacingOwner?, CameraOwner?)
	-- 无 blendPolicy：保持旧语义（suppress 默认 false；pause nil 表示跟随 suppress）
	if type(options.blendPolicy) ~= "string" or options.blendPolicy == "" then
		return options.suppressLoco == true, options.pauseBaseTracks, options.facingOwner, options.cameraOwner
	end
	local expanded = expandBlendPolicy(options.blendPolicy)
	local suppressLoco = if options.suppressLoco ~= nil then options.suppressLoco == true else expanded.suppressLoco
	local pauseBaseTracks: boolean? = if options.pauseBaseTracks ~= nil then options.pauseBaseTracks else expanded.pauseBaseTracks
	local facingOwner: FacingOwner? = if options.facingOwner ~= nil then options.facingOwner else expanded.facingOwner
	return suppressLoco, pauseBaseTracks, facingOwner, options.cameraOwner
end

--[[
	从仍有效的 claims 合成 OR 闸与最高优先级 claim
	@param claims { [string]: Claim } - 当前占用表
	@return Claim? - 最高优先级 claim
	@return boolean - 是否还有占用
	@return boolean - OR suppressLoco
	@return boolean - OR pauseBaseTracks
]]
local function _pickBest(claims: { [string]: Claim }): (Claim?, boolean, boolean, boolean)
	local best: Claim? = nil
	local anyClaim = false
	local orSuppress = false
	local orPause = false
	for _, claim in pairs(claims) do
		anyClaim = true
		local claimSuppress = claim.suppressLoco == true
		local claimPause = claim.pauseBaseTracks
		if claimPause == nil then
			claimPause = claimSuppress
		end
		orSuppress = orSuppress or claimSuppress
		orPause = orPause or (claimPause == true)
		if not best
			or claim.priority > best.priority
			or (claim.priority == best.priority and claim.seq > best.seq)
		then
			best = claim
		end
	end
	return best, anyClaim, orSuppress, orPause
end

--[[
	按当前 claims 重建闸快照（过期 token 一并剔除）
	@param state GateState - 实例状态
	@return GateSnapshot - 新快照
]]
local function _rebuildSnapshot(state: GateState): GateSnapshot
	local now = os.clock()
	local expiredTokens: { string } = {}
	for token, claim in pairs(state.claims) do
		if claim.expireAt ~= nil and now >= claim.expireAt then
			table.insert(expiredTokens, token)
		end
	end
	for _, token in ipairs(expiredTokens) do
		state.claims[token] = nil
	end

	local best, anyClaim, orSuppress, orPause = _pickBest(state.claims)
	if anyClaim and best then
		return {
			suppressLoco = orSuppress,
			pauseBaseTracks = orPause,
			facingOwner = (best.facingOwner or Constants.FacingOwner.Animate) :: FacingOwner,
			cameraOwner = (best.cameraOwner or Constants.CameraOwner.Default) :: CameraOwner,
			activeOwnerId = best.ownerId,
			activeOwners = _copyActiveOwners(state.claims),
			reason = best.reason,
		}
	end
	local nextSnap = _defaultSnapshot()
	nextSnap.activeOwners = _copyActiveOwners(state.claims)
	return nextSnap
end

--[[
	快照变化时同步回调订阅者（传拷贝，避免订阅者改内部缓存）
	@param state GateState - 实例状态
]]
local function _publishIfChanged(state: GateState)
	local nextSnap = _rebuildSnapshot(state)
	if _snapshotsEqual(state.snapshot, nextSnap) and #state.snapshot.activeOwners == #nextSnap.activeOwners then
		local ownersSame = true
		for i, id in ipairs(state.snapshot.activeOwners) do
			if nextSnap.activeOwners[i] ~= id then
				ownersSame = false
				break
			end
		end
		if ownersSame then
			return
		end
	end
	state.snapshot = nextSnap
	-- 同步通知：task.spawn 会导致 pause/unpause 乱序套用，第二次技能后 _basePausedByGate 与闸脱节卡死 loco
	for _, cb in ipairs(state.changedCallbacks) do
		local ok, err = pcall(cb, _cloneSnapshot(state.snapshot))
		if not ok then
			Log.warn("[ActionArbiter] OnChanged error:", err)
		end
	end
end

--[[
	声明占用；同 ownerId 会先释放旧 token 再写入（单 owner 单条目）
	@param state GateState - 实例状态
	@param options AcquireOptions - 占用声明（可含 blendPolicy）
	@return string - token，用于 Release
]]
local function _acquire(state: GateState, options: AcquireOptions): string
	if state.destroyed then
		return ""
	end
	assert(type(options) == "table", "Acquire options required")
	assert(type(options.ownerId) == "string" and options.ownerId ~= "", "ownerId required")
	assert(type(options.priority) == "number", "priority required")

	for token, claim in pairs(state.claims) do
		if claim.ownerId == options.ownerId then
			state.claims[token] = nil
		end
	end

	_tokenSeq += 1
	_claimSeq += 1
	local token = string.format("%s#%d", options.ownerId, _tokenSeq)
	local expireAt: number? = nil
	if type(options.ttlSeconds) == "number" and options.ttlSeconds > 0 then
		expireAt = os.clock() + options.ttlSeconds
	end

	local suppressLoco, pauseBaseTracks, facingOwner, cameraOwner =
		_resolveClaimFields(options, state.expandBlendPolicy)

	state.claims[token] = {
		token = token,
		ownerId = options.ownerId,
		priority = options.priority,
		suppressLoco = suppressLoco,
		pauseBaseTracks = pauseBaseTracks,
		facingOwner = facingOwner,
		cameraOwner = cameraOwner,
		reason = options.reason,
		expireAt = expireAt,
		seq = _claimSeq,
		blendPolicy = options.blendPolicy,
	}
	_publishIfChanged(state)
	return token
end

--[[
	按 token 释放占用
	@param state GateState - 实例状态
	@param token string - Acquire 返回值
	@return boolean - 是否找到并释放
]]
local function _release(state: GateState, token: string): boolean
	if state.destroyed or type(token) ~= "string" or token == "" then
		return false
	end
	if state.claims[token] == nil then
		return false
	end
	state.claims[token] = nil
	_publishIfChanged(state)
	return true
end

--[[
	按 ownerId 释放（Bridge / 业务重入用）
	@param state GateState - 实例状态
	@param ownerId string - 占用方 ID
	@return boolean - 是否释放了至少一条
]]
local function _releaseByOwner(state: GateState, ownerId: string): boolean
	if state.destroyed or type(ownerId) ~= "string" then
		return false
	end
	local removed = false
	for token, claim in pairs(state.claims) do
		if claim.ownerId == ownerId then
			state.claims[token] = nil
			removed = true
		end
	end
	if removed then
		_publishIfChanged(state)
	end
	return removed
end

--[[
	订阅快照变化
	@param state GateState - 实例状态
	@param callback (GateSnapshot) -> () - 变更回调
	@return () -> () - 取消订阅
]]
local function _onChanged(state: GateState, callback: (GateSnapshot) -> ()): () -> ()
	table.insert(state.changedCallbacks, callback)
	return function()
		for i, cb in ipairs(state.changedCallbacks) do
			if cb == callback then
				table.remove(state.changedCallbacks, i)
				break
			end
		end
	end
end

--[[
	销毁实例：断 Bridge、清占用、移出弱表
	@param state GateState - 实例状态
]]
local function _destroy(state: GateState)
	if state.destroyed then
		return
	end
	state.destroyed = true
	if state.heartbeatConn then
		state.heartbeatConn:Disconnect()
		state.heartbeatConn = nil
	end
	if state.bridgeDisconnect then
		state.bridgeDisconnect()
		state.bridgeDisconnect = nil
	end
	table.clear(state.claims)
	table.clear(state.changedCallbacks)
	state.snapshot = _defaultSnapshot()
	local instance = state.instance
	if instance and _instances[state.character] == instance then
		_instances[state.character] = nil
	end
end

--[[
	TTL 到期检测（有过期 claim 才重建）
	@param state GateState - 实例状态
]]
local function _onHeartbeat(state: GateState)
	if state.destroyed then
		return
	end
	local now = os.clock()
	for _, claim in pairs(state.claims) do
		if claim.expireAt ~= nil and now >= claim.expireAt then
			_publishIfChanged(state)
			return
		end
	end
end

--[[
	创建角色级仲裁实例（重复 Create 返回已有实例）
	@param character Model - 角色模型
	@param options CreateOptions? - Bridge / LocalPlayer 等
	@param expandBlendPolicy ExpandFn - ActionArbiter.ExpandBlendPolicy
	@return ActionArbiterInstance - 仲裁实例
]]
function GateInstance.create(
	character: Model,
	options: CreateOptions?,
	expandBlendPolicy: ExpandFn
): ActionArbiterInstance
	local existing = _instances[character]
	if existing then
		return existing
	end

	local opts = options or {}
	local state: GateState = {
		character = character,
		claims = {},
		snapshot = _defaultSnapshot(),
		changedCallbacks = {},
		bridgeDisconnect = nil,
		heartbeatConn = nil,
		destroyed = false,
		expandBlendPolicy = expandBlendPolicy,
		instance = nil,
	}

	local instance = {} :: any
	instance.Character = character
	function instance:Acquire(acquireOptions: AcquireOptions): string
		return _acquire(state, acquireOptions)
	end
	function instance:Release(token: string): boolean
		return _release(state, token)
	end
	function instance:ReleaseByOwner(ownerId: string): boolean
		return _releaseByOwner(state, ownerId)
	end
	function instance:GetSnapshot(): GateSnapshot
		return _cloneSnapshot(state.snapshot)
	end
	function instance:IsLocoSuppressed(): boolean
		return state.snapshot.suppressLoco
	end
	function instance:GetFacingOwner(): FacingOwner
		return state.snapshot.facingOwner
	end
	function instance:GetCameraOwner(): CameraOwner
		return state.snapshot.cameraOwner
	end
	function instance:OnChanged(callback: (GateSnapshot) -> ()): () -> ()
		return _onChanged(state, callback)
	end
	function instance:destroy()
		_destroy(state)
	end

	state.instance = instance :: ActionArbiterInstance
	state.heartbeatConn = RunService.Heartbeat:Connect(function()
		_onHeartbeat(state)
	end)

	if opts.enableAttributeBridge ~= false then
		state.bridgeDisconnect = Bridge.attach(instance, character, {
			localPlayer = opts.localPlayer,
			enableJetPacking = opts.enableJetPacking,
			enableFacingOverride = opts.enableFacingOverride,
			enableSkillActionLock = opts.enableSkillActionLock,
		})
	end

	_instances[character] = instance
	return instance :: ActionArbiterInstance
end

--[[
	查询已 create 的实例；未创建返回 nil（不偷偷新建）
	@param character Model - 角色
	@return ActionArbiterInstance? - 仲裁实例
]]
function GateInstance.get(character: Model): ActionArbiterInstance?
	if not character then
		return nil
	end
	return _instances[character]
end

return GateInstance
