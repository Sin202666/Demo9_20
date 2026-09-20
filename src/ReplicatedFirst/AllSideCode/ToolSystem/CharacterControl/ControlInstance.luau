--[[
	Module: CharacterControl.ControlInstance
	Description: 角色级 Control 实例工厂（Intent 心跳、Lock/Transfer、Sprint/Jump、Attribute）
	Author: 林奥宇
	Created: 2026-09-01
	Last Modified: 2026-09-01

	仅由 CharacterControl.init Create / GetForCharacter 调用；业务请走 Utils.CharacterControl。
	不写 WalkSpeed / CFrame；移速只经 CMS Modifier；跳跃只经 JumpPolicy。
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Players = Utils.Players
local RunService = Utils.RunService
local SystemGameConfig = Utils.SystemGameConfig
local Log = Utils.Log
local GetData = Utils.GetData
local AddListen = Utils.AddListen

local Constants = require(script.Parent.Constants)
local IntentSampler = require(script.Parent.IntentSampler)
local LockMask = require(script.Parent.LockMask)
local SprintMode = require(script.Parent.SprintMode)
local JumpPolicy = require(script.Parent.JumpPolicy)
local PlayerControlsBridge = require(script.Parent.PlayerControlsBridge)

local ControlInstance = {}

-- ========================================
-- 类型
-- ========================================

export type IntentSnapshot = IntentSampler.IntentSnapshot
export type LockChannels = LockMask.LockChannels
export type LockMaskSpec = LockMask.LockMaskSpec
export type MovePolicy = LockMask.MovePolicy
export type GaitMode = SprintMode.GaitMode
export type SprintInputMode = SprintMode.SprintInputMode
export type MoveSpeedBind = SprintMode.MoveSpeedBind

export type ApiKind = "Push" | "Transfer"

export type CreateOptions = {
	moveSpeedBind: MoveSpeedBind,
	localPlayer: Player?,
	enabled: boolean?,
}

export type CharacterControlInstance = {
	GetIntent: (self: CharacterControlInstance) -> IntentSnapshot,
	GetMode: (self: CharacterControlInstance) -> GaitMode,
	PushLock: (self: CharacterControlInstance, sourceId: string, mask: LockMaskSpec) -> (),
	PopLock: (self: CharacterControlInstance, sourceId: string) -> boolean,
	GetLockMask: (self: CharacterControlInstance) -> LockChannels,
	TransferControlOwner: (self: CharacterControlInstance, ownerId: string, mask: LockMaskSpec?) -> (),
	ReleaseControlOwner: (self: CharacterControlInstance, ownerId: string) -> boolean,
	SuppressJump: (self: CharacterControlInstance, durationSec: number, reason: string?) -> (),
	ClearJumpBuffer: (self: CharacterControlInstance) -> (),
	destroy: (self: CharacterControlInstance) -> (),
	Character: Model,
}

type ControlState = {
	character: Model,
	humanoid: Humanoid,
	localPlayer: Player?,
	moveSpeedBind: MoveSpeedBind,
	lockMask: LockMask.LockMaskController,
	controlsBridge: PlayerControlsBridge.PlayerControlsBridgeController,
	movePolicyBySource: { [string]: MovePolicy },
	sampler: IntentSampler.IntentSampler,
	sprintMode: SprintMode.SprintModeController,
	jumpPolicy: JumpPolicy.JumpPolicyController,
	lastIntent: IntentSnapshot,
	destroyed: boolean,
	heartbeatConn: RBXScriptConnection?,
	runModeSettingConn: RBXScriptConnection?,
	unbindLock: (() -> ())?,
	defaultPushMovePolicy: MovePolicy,
	defaultTransferMovePolicy: MovePolicy,
	instance: CharacterControlInstance?,
}

-- ========================================
-- 私有变量
-- ========================================

local _instances: { [Model]: CharacterControlInstance } = setmetatable({}, { __mode = "k" }) :: any

-- ========================================
-- 配置读取
-- ========================================

--[[
	读取 GameConfig.CharacterControl 布尔
	@param key string - 配置键名（如「启用」「进场默认奔跑」）
	@param default boolean - 配置缺失时的默认值
	@return boolean - 配置为 false 时为 false，否则为 true（含默认）
]]
local function _cfgBool(key: string, default: boolean): boolean
	local v = SystemGameConfig.GetValue({ "CharacterControl", key })
	if v == nil then
		return default
	end
	return v ~= false
end

--[[
	读取 GameConfig.CharacterControl 数字
	@param key string - 配置键名（如「跳跃缓冲秒」）
	@param default number - 非数字或 NaN 时的默认值
	@return number - 有效配置值或 default
]]
local function _cfgNumber(key: string, default: number): number
	local v = SystemGameConfig.GetValue({ "CharacterControl", key })
	if type(v) == "number" and v == v then
		return v
	end
	return default
end

--[[
	是否为合法 MovePolicy 字符串
	@param v any - 候选值
	@return boolean - SpeedOnly 或 DisableControls 时为 true
]]
local function _isValidMovePolicy(v: any): boolean
	return v == Constants.MovePolicySpeedOnly or v == Constants.MovePolicyDisableControls
end

--[[
	读取配置中的 Move 策略
	@param key string - 「Move锁默认策略」或「Transfer移控策略」
	@param default MovePolicy - 非法/缺失时回退
	@return MovePolicy - 合法策略名
]]
local function _cfgMovePolicy(key: string, default: MovePolicy): MovePolicy
	local v = SystemGameConfig.GetValue({ "CharacterControl", key })
	if _isValidMovePolicy(v) then
		return v :: MovePolicy
	end
	return default
end

--[[
	读取冲刺键
	@return Enum.KeyCode - 配置解析后的冲刺键；非法名回退 LeftShift
]]
local function _cfgSprintKey(): Enum.KeyCode
	local name = SystemGameConfig.GetValue({ "CharacterControl", "冲刺键" })
	return IntentSampler.resolveKeyCode(
		if type(name) == "string" then name else Constants.DefaultSprintKeyName,
		Constants.DefaultSprintKey
	)
end

--[[
	读取交互键
	@return Enum.KeyCode - 配置解析后的交互键；非法名回退 E
]]
local function _cfgInteractKey(): Enum.KeyCode
	local name = SystemGameConfig.GetValue({ "CharacterControl", "交互键" })
	return IntentSampler.resolveKeyCode(
		if type(name) == "string" then name else Constants.DefaultInteractKeyName,
		Constants.DefaultInteractKey
	)
end

--[[
	读取行走/奔跑速度差（Sprint Modifier add）
	@return number - max(0, 奔跑速 - 行走速)；缺省按 DefaultRunSpeed-DefaultWalkSpeed
]]
local function _runSpeedAdd(): number
	local walk = SystemGameConfig.GetValue({ "CharacterMoveSpeed", "玩家行走移动速度" })
	local run = SystemGameConfig.GetValue({ "CharacterMoveSpeed", "玩家奔跑移动速度" })
	local base = if type(walk) == "number" then walk else Constants.DefaultWalkSpeed
	local runSpeed = if type(run) == "number" then run else Constants.DefaultRunSpeed
	return math.max(0, runSpeed - base)
end

--[[
	将 settingConf.RunMode 数值转为 Sprint 输入模式
	@param value number? - 0=一键切换，1=长按奔跑；nil/其它按 Toggle
	@return SprintInputMode - 「Toggle」或「Hold」
]]
local function _runModeSettingToInputMode(value: number?): SprintInputMode
	if value == Constants.RunModeHold then
		return "Hold"
	end
	return "Toggle"
end

-- ========================================
-- 校验 / 拷贝
-- ========================================

--[[
	浅拷贝 Intent 快照（避免调用方篡改内部 lastIntent）
	@param src IntentSnapshot - 源快照
	@return IntentSnapshot - 字段拷贝后的新表
]]
local function _copyIntent(src: IntentSnapshot): IntentSnapshot
	return {
		moveAxis = src.moveAxis,
		moveMagnitude = src.moveMagnitude,
		jumpPressed = src.jumpPressed,
		jumpHeld = src.jumpHeld,
		sprintHeld = src.sprintHeld,
		crouchHeld = src.crouchHeld,
		interactPressed = src.interactPressed,
	}
end

--[[
	moveSpeedBind 是否具备 CMS Modifier 写口
	@param bind any - CreateOptions.moveSpeedBind
	@return boolean - 含 pushModifier / popModifier 时为 true
]]
local function _isValidMoveSpeedBind(bind: any): boolean
	return type(bind) == "table"
		and type(bind.pushModifier) == "function"
		and type(bind.popModifier) == "function"
end

--[[
	是否允许对本角色 Create（仅本地玩家）
	@param character Model - 角色模型
	@param localPlayer Player? - 本机玩家
	@return boolean - 非本机角色为 false
]]
local function _isLocalCharacter(character: Model, localPlayer: Player?): boolean
	if not localPlayer then
		return true
	end
	local plr = Players:GetPlayerFromCharacter(character)
	if plr and plr ~= localPlayer then
		return false
	end
	return true
end

--[[
	解析角色 Humanoid（缺省时短等）
	@param character Model - 角色模型
	@return Humanoid? - 找到的 Humanoid；超时为 nil
]]
local function _resolveHumanoid(character: Model): Humanoid?
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		humanoid = character:WaitForChild("Humanoid", Constants.HumanoidWaitSec) :: Humanoid?
	end
	return humanoid
end

-- ========================================
-- 锁 / Attribute / CMS
-- ========================================

--[[
	解析本条锁的 Move 策略（无 Move 通道时返回 nil）
	@param state ControlState - 实例状态
	@param mask LockMaskSpec - 调用方 mask
	@param apiKind ApiKind - Push 或 Transfer（决定缺省策略）
	@return MovePolicy? - SpeedOnly / DisableControls；未锁 Move 为 nil
]]
local function _resolveMovePolicy(state: ControlState, mask: LockMaskSpec, apiKind: ApiKind): MovePolicy?
	if mask.Move ~= true then
		return nil
	end
	if _isValidMovePolicy(mask.MovePolicy) then
		return mask.MovePolicy :: MovePolicy
	end
	if apiKind == "Transfer" then
		return state.defaultTransferMovePolicy
	end
	return state.defaultPushMovePolicy
end

--[[
	按 sourceId 同步 Controls Bridge（DisableControls 才 Acquire）
	@param state ControlState - 实例状态
	@param sourceId string - 锁来源 ID
	@param mask LockMaskSpec - 本条 mask
	@param apiKind ApiKind - Push 或 Transfer
]]
local function _syncMovePolicy(state: ControlState, sourceId: string, mask: LockMaskSpec, apiKind: ApiKind)
	local policy = _resolveMovePolicy(state, mask, apiKind)
	if policy == Constants.MovePolicyDisableControls then
		state.movePolicyBySource[sourceId] = policy
		state.controlsBridge:Acquire(sourceId)
	else
		state.movePolicyBySource[sourceId] = nil
		state.controlsBridge:Release(sourceId)
	end
end

--[[
	弹出某 source 的 Move 策略持有（Pop / Release）
	@param state ControlState - 实例状态
	@param sourceId string - 来源 ID
]]
local function _clearMovePolicy(state: ControlState, sourceId: string)
	state.movePolicyBySource[sourceId] = nil
	state.controlsBridge:Release(sourceId)
end

--[[
	同步 Look / Interact 锁到 LocalPlayer Attribute
	@param state ControlState - 实例状态
	@param mask LockChannels - 当前聚合锁快照
]]
local function _publishLookInteractAttrs(state: ControlState, mask: LockChannels)
	local localPlayer = state.localPlayer
	if not localPlayer then
		return
	end
	local lookLocked = mask.Look == true
	local interactLocked = mask.Interact == true
	if localPlayer:GetAttribute(Constants.AttrLookLocked) ~= lookLocked then
		localPlayer:SetAttribute(Constants.AttrLookLocked, lookLocked)
	end
	if localPlayer:GetAttribute(Constants.AttrInteractLocked) ~= interactLocked then
		localPlayer:SetAttribute(Constants.AttrInteractLocked, interactLocked)
	end
end

--[[
	同步 Move 锁 → CMS hardLock；聚合 Move 全无时兜底释放 Controls
	@param state ControlState - 实例状态
	@param mask LockChannels - 当前聚合锁快照
]]
local function _applyMoveLock(state: ControlState, mask: LockChannels)
	if mask.Move then
		state.moveSpeedBind.pushModifier(Constants.OwnerLockMove, { mul = 0, hardLock = true })
	else
		state.moveSpeedBind.popModifier(Constants.OwnerLockMove)
		-- 聚合 Move 已全无：兜底清策略表与 Bridge，防不同步
		table.clear(state.movePolicyBySource)
		state.controlsBridge:ReleaseAll()
	end
end

--[[
	LockMask 变化：Move / Jump buffer / Look·Interact Attribute
	@param state ControlState - 实例状态
	@param mask LockChannels - 变化后的聚合锁
]]
local function _onLockChanged(state: ControlState, mask: LockChannels)
	if state.destroyed then
		return
	end
	_applyMoveLock(state, mask)
	_publishLookInteractAttrs(state, mask)
	if mask.Jump then
		state.jumpPolicy:ClearJumpBuffer()
	end
end

-- ========================================
-- RunMode / 心跳 / 销毁
-- ========================================

--[[
	绑定单个 RunMode NumberValue 的变更监听
	@param state ControlState - 实例状态
	@param nv NumberValue - player.Setting.RunMode
]]
local function _bindRunModeNumberValue(state: ControlState, nv: NumberValue)
	if state.runModeSettingConn then
		state.runModeSettingConn:Disconnect()
		state.runModeSettingConn = nil
	end
	state.runModeSettingConn = AddListen.NumValueAdd(nv, function(val: number)
		if state.destroyed then
			return
		end
		state.sprintMode:SetInputMode(_runModeSettingToInputMode(val))
	end)
end

--[[
	绑定 settingConf.RunMode → SprintMode.SetInputMode（热切换）
	@param state ControlState - 实例状态
]]
local function _bindRunModeSetting(state: ControlState)
	local localPlayer = state.localPlayer
	if not localPlayer then
		return
	end
	local settingFolder = localPlayer:FindFirstChild("Setting")
	local existing = settingFolder and settingFolder:FindFirstChild(Constants.SettingRunMode)
	if existing and existing:IsA("NumberValue") then
		_bindRunModeNumberValue(state, existing)
		return
	end
	task.spawn(function()
		local folder = localPlayer:WaitForChild("Setting", Constants.SettingFolderWaitSec)
		if state.destroyed or not folder then
			return
		end
		local nv = folder:WaitForChild(Constants.SettingRunMode, Constants.RunModeWaitSec)
		if state.destroyed or not nv or not nv:IsA("NumberValue") then
			return
		end
		_bindRunModeNumberValue(state, nv :: NumberValue)
	end)
end

--[[
	每帧采样 Intent 并驱动 Sprint / Jump
	@param state ControlState - 实例状态
]]
local function _onHeartbeat(state: ControlState)
	local character = state.character
	local humanoid = state.humanoid
	if state.destroyed or not character.Parent or not humanoid.Parent then
		if not state.destroyed and state.instance then
			state.instance:destroy()
		end
		return
	end
	state.lastIntent = state.sampler:Sample(humanoid)
	local mask = state.lockMask:Get()
	-- Interact 锁：吞掉本帧交互边沿（采样仍发生，对外 Intent 已过滤）
	if mask.Interact then
		state.lastIntent.interactPressed = false
	end
	state.sprintMode:Update(state.lastIntent.sprintHeld, mask.Sprint)
	state.jumpPolicy:Update(state.lastIntent.jumpPressed, mask.Jump)
end

--[[
	断开连接、清锁、还 Modifier、复位 Attribute
	@param state ControlState - 实例状态
]]
local function _teardown(state: ControlState)
	if state.heartbeatConn then
		state.heartbeatConn:Disconnect()
		state.heartbeatConn = nil
	end
	if state.runModeSettingConn then
		state.runModeSettingConn:Disconnect()
		state.runModeSettingConn = nil
	end
	if state.unbindLock then
		state.unbindLock()
		state.unbindLock = nil
	end
	table.clear(state.movePolicyBySource)
	state.controlsBridge:ReleaseAll()
	state.lockMask:Clear()
	state.moveSpeedBind.popModifier(Constants.OwnerLockMove)
	local localPlayer = state.localPlayer
	if localPlayer then
		localPlayer:SetAttribute(Constants.AttrLookLocked, false)
		localPlayer:SetAttribute(Constants.AttrInteractLocked, false)
	end
	state.sprintMode:destroy()
	state.jumpPolicy:destroy()
	state.sampler:destroy()
	local instance = state.instance
	if instance and _instances[state.character] == instance then
		_instances[state.character] = nil
	end
end

-- ========================================
-- 实例 API
-- ========================================

--[[
	最近一帧 Intent 快照（Interact 锁生效时已清 interactPressed；返回拷贝不可篡改内部）
	@param state ControlState - 实例状态
	@return IntentSnapshot - 本帧 Intent 字段浅拷贝
]]
local function _apiGetIntent(state: ControlState): IntentSnapshot
	return _copyIntent(state.lastIntent)
end

--[[
	当前 Walk/Run 模式
	@param state ControlState - 实例状态
	@return GaitMode - 「Walk」或「Run」
]]
local function _apiGetMode(state: ControlState): GaitMode
	return state.sprintMode:GetMode()
end

--[[
	压入输入锁（Move 默认 SpeedOnly，可用 MovePolicy 覆盖）
	@param state ControlState - 实例状态
	@param sourceId string - 稳定来源 ID（同 ID 覆盖）
	@param mask LockMaskSpec - 要锁的通道（true 生效）；可选 MovePolicy
]]
local function _apiPushLock(state: ControlState, sourceId: string, mask: LockMaskSpec)
	if state.destroyed then
		return
	end
	local m = mask or {}
	state.lockMask:Push(sourceId, m)
	_syncMovePolicy(state, sourceId, m, "Push")
end

--[[
	弹出输入锁
	@param state ControlState - 实例状态
	@param sourceId string - 与 PushLock 对应的来源 ID
	@return boolean - true 表示此前存在该来源
]]
local function _apiPopLock(state: ControlState, sourceId: string): boolean
	if state.destroyed then
		return false
	end
	_clearMovePolicy(state, sourceId)
	return state.lockMask:Pop(sourceId)
end

--[[
	临时接管控制权（缺省 FullLockMask；Move 默认 DisableControls）
	@param state ControlState - 实例状态
	@param ownerId string - 稳定所有者 ID（如 Vehicle:Bike / Cutscene:Intro）
	@param mask LockMaskSpec? - 缺省 FullLockMask；可选 MovePolicy 覆盖
]]
local function _apiTransfer(state: ControlState, ownerId: string, mask: LockMaskSpec?)
	if state.destroyed then
		return
	end
	if type(ownerId) ~= "string" or ownerId == "" then
		Log.warn("[CharacterControl] TransferControlOwner: ownerId 必填")
		return
	end
	local m = mask or Constants.FullLockMask
	state.lockMask:Push(ownerId, m)
	_syncMovePolicy(state, ownerId, m, "Transfer")
	state.jumpPolicy:ClearJumpBuffer()
end

--[[
	归还控制权（= PopLock）
	@param state ControlState - 实例状态
	@param ownerId string - 与 TransferControlOwner 对应的 ID
	@return boolean - true 表示此前存在该所有者锁
]]
local function _apiReleaseOwner(state: ControlState, ownerId: string): boolean
	if state.destroyed then
		return false
	end
	_clearMovePolicy(state, ownerId)
	return state.lockMask:Pop(ownerId)
end

--[[
	限时禁跳
	@param state ControlState - 实例状态
	@param durationSec number - 禁跳时长（秒）；≤0 或非数忽略
	@param reason string? - 调试用原因标签
]]
local function _apiSuppressJump(state: ControlState, durationSec: number, reason: string?)
	if state.destroyed then
		return
	end
	state.jumpPolicy:SuppressJump(durationSec, reason)
end

--[[
	清空跳跃缓冲（落地前预输入失效）
	@param state ControlState - 实例状态
]]
local function _apiClearJumpBuffer(state: ControlState)
	if state.destroyed then
		return
	end
	state.jumpPolicy:ClearJumpBuffer()
end

--[[
	销毁：断连接、清锁、还 Modifier、复位 Attribute、恢复跳跃与 Controls
	@param state ControlState - 实例状态
]]
local function _apiDestroy(state: ControlState)
	if state.destroyed then
		return
	end
	state.destroyed = true
	_teardown(state)
end

--[[
	挂上对外实例方法
	@param state ControlState - 实例状态
]]
local function _bindInstance(state: ControlState)
	local instance = {} :: any
	instance.Character = state.character
	--[[
		最近一帧 Intent 快照（Interact 锁生效时已清 interactPressed；返回拷贝不可篡改内部）
		@return IntentSnapshot - 本帧 Intent 字段浅拷贝
	]]
	function instance:GetIntent(): IntentSnapshot
		return _apiGetIntent(state)
	end
	--[[
		当前 Walk/Run 模式
		@return GaitMode - 「Walk」或「Run」
	]]
	function instance:GetMode(): GaitMode
		return _apiGetMode(state)
	end
	--[[
		压入输入锁（Move 默认 SpeedOnly，可用 MovePolicy 覆盖）
		@param sourceId string - 稳定来源 ID（同 ID 覆盖）
		@param mask LockMaskSpec - 要锁的通道（true 生效）；可选 MovePolicy
	]]
	function instance:PushLock(sourceId: string, mask: LockMaskSpec)
		_apiPushLock(state, sourceId, mask)
	end
	--[[
		弹出输入锁
		@param sourceId string - 与 PushLock 对应的来源 ID
		@return boolean - true 表示此前存在该来源
	]]
	function instance:PopLock(sourceId: string): boolean
		return _apiPopLock(state, sourceId)
	end
	--[[
		当前聚合锁
		@return LockChannels - 各通道 OR 聚合后的浅拷贝
	]]
	function instance:GetLockMask(): LockChannels
		return state.lockMask:Get()
	end
	--[[
		临时接管控制权（缺省 FullLockMask；Move 默认 DisableControls）
		@param ownerId string - 稳定所有者 ID（如 Vehicle:Bike / Cutscene:Intro）
		@param mask LockMaskSpec? - 缺省 FullLockMask；可选 MovePolicy 覆盖
	]]
	function instance:TransferControlOwner(ownerId: string, mask: LockMaskSpec?)
		_apiTransfer(state, ownerId, mask)
	end
	--[[
		归还控制权（= PopLock）
		@param ownerId string - 与 TransferControlOwner 对应的 ID
		@return boolean - true 表示此前存在该所有者锁
	]]
	function instance:ReleaseControlOwner(ownerId: string): boolean
		return _apiReleaseOwner(state, ownerId)
	end
	--[[
		限时禁跳
		@param durationSec number - 禁跳时长（秒）；≤0 或非数忽略
		@param reason string? - 调试用原因标签
	]]
	function instance:SuppressJump(durationSec: number, reason: string?)
		_apiSuppressJump(state, durationSec, reason)
	end
	--[[
		清空跳跃缓冲（落地前预输入失效）
	]]
	function instance:ClearJumpBuffer()
		_apiClearJumpBuffer(state)
	end
	--[[
		销毁：断连接、清锁、还 Modifier、复位 Attribute、恢复跳跃与 Controls
	]]
	function instance:destroy()
		_apiDestroy(state)
	end
	state.instance = instance
end

--[[
	组装控制器与缺省 Intent
	@param character Model - 角色模型
	@param humanoid Humanoid - 本地角色 Humanoid
	@param localPlayer Player? - 本机玩家
	@param moveSpeedBind MoveSpeedBind - CMS Modifier 写口
	@return ControlState - 未绑 API / 心跳的状态
]]
local function _createState(
	character: Model,
	humanoid: Humanoid,
	localPlayer: Player?,
	moveSpeedBind: MoveSpeedBind
): ControlState
	local initialRunMode = if localPlayer then GetData.GetSetting(localPlayer, Constants.SettingRunMode) else nil
	return {
		character = character,
		humanoid = humanoid,
		localPlayer = localPlayer,
		moveSpeedBind = moveSpeedBind,
		lockMask = LockMask.create(),
		controlsBridge = PlayerControlsBridge.create(),
		movePolicyBySource = {},
		sampler = IntentSampler.create({
			sprintKey = _cfgSprintKey(),
			gamepadSprintKey = Constants.DefaultGamepadSprintKey,
			interactKey = _cfgInteractKey(),
			gamepadInteractKey = Constants.DefaultGamepadInteractKey,
		}),
		sprintMode = SprintMode.create({
			moveSpeedBind = moveSpeedBind,
			runSpeedAdd = _runSpeedAdd(),
			spawnInRunMode = _cfgBool("进场默认奔跑", true),
			inputMode = _runModeSettingToInputMode(initialRunMode),
		}),
		jumpPolicy = JumpPolicy.create({
			humanoid = humanoid,
			bufferSec = _cfgNumber("跳跃缓冲秒", Constants.DefaultJumpBufferSec),
			coyoteSec = _cfgNumber("郊狼秒", Constants.DefaultCoyoteSec),
		}),
		lastIntent = {
			moveAxis = Vector3.zero,
			moveMagnitude = 0,
			jumpPressed = false,
			jumpHeld = false,
			sprintHeld = false,
			crouchHeld = false,
			interactPressed = false,
		},
		destroyed = false,
		heartbeatConn = nil,
		runModeSettingConn = nil,
		unbindLock = nil,
		defaultPushMovePolicy = _cfgMovePolicy("Move锁默认策略", Constants.DefaultPushMovePolicy :: MovePolicy),
		defaultTransferMovePolicy = _cfgMovePolicy("Transfer移控策略", Constants.DefaultTransferMovePolicy :: MovePolicy),
		instance = nil,
	}
end

-- ========================================
-- 公共工厂
-- ========================================

--[[
	查询已 Create 实例
	@param character Model - 角色模型
	@return CharacterControlInstance? - 已创建实例；未 Create 或不存在为 nil
]]
function ControlInstance.get(character: Model): CharacterControlInstance?
	if not character then
		return nil
	end
	return _instances[character]
end

--[[
	创建角色级 Control（仅本地玩家角色应由 CharacterManager 调用；重复 Create 返回已有实例）
	@param character Model - 角色模型
	@param options CreateOptions? - 须含 moveSpeedBind（CharacterMoveSpeedBind）；enabled=false 时不创建
	@return CharacterControlInstance? - 新实例或已有实例；禁用/非本机/缺依赖时为 nil
]]
function ControlInstance.create(character: Model, options: CreateOptions?): CharacterControlInstance?
	if not character then
		return nil
	end
	local existing = _instances[character]
	if existing then
		return existing
	end

	local opts = options or {}
	if _cfgBool("启用", true) == false or opts.enabled == false then
		return nil
	end

	local localPlayer = opts.localPlayer or Players.LocalPlayer
	if not _isLocalCharacter(character, localPlayer) then
		Log.warn("[CharacterControl] 仅本地角色可 Create，已忽略:", character.Name)
		return nil
	end

	local moveSpeedBind = opts.moveSpeedBind
	if not _isValidMoveSpeedBind(moveSpeedBind) then
		Log.warn("[CharacterControl.Create] moveSpeedBind 必填")
		return nil
	end

	local humanoid = _resolveHumanoid(character)
	if not humanoid then
		Log.warn("[CharacterControl.Create] 缺少 Humanoid")
		return nil
	end

	local state = _createState(character, humanoid, localPlayer, moveSpeedBind)
	_bindRunModeSetting(state)
	state.unbindLock = state.lockMask:OnChanged(function(mask: LockChannels)
		_onLockChanged(state, mask)
	end)
	_publishLookInteractAttrs(state, state.lockMask:Get())
	_bindInstance(state)

	state.heartbeatConn = RunService.Heartbeat:Connect(function(_dt: number)
		_onHeartbeat(state)
	end)

	local landSuppress = _cfgNumber("默认落地禁跳秒", Constants.DefaultLandSuppressSec)
	if landSuppress > 0 then
		state.jumpPolicy:SuppressJump(landSuppress, "SpawnLandSuppress")
	end

	_instances[character] = state.instance :: CharacterControlInstance
	return state.instance
end

return ControlInstance
