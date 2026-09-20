--[[
	Module: CameraModule.CameraMode
	Description: 相机模式栈（Default / ShiftLock / OTS / LockOn / Aim）。业务只 Push/Pop；不抢主事件 Scriptable。
	Author: 林奥宇
	Created: 2026-08-05
	Last Modified: 2026-08-31

	【分层】
	- 本模块：基线跟拍策略（模式栈 + LocalPlayer.CameraMode Attribute + 可选 Helper 偏移）
	- CameraModule 主事件：技能/过场完全接管（priority 栈，本模块不介入）
	- 引擎 MouseLockController：用户 ShiftLock 开关；经 SyncEngineShiftLock 映射为栈源 Engine:MouseLock
	- Animate：仍读 IsShiftLocked（朝向/Strafe）；本模块不改写 IsShiftLocked
	- CharacterControl Look 锁（IsControlLookLocked）：Animate 不写 HRP 朝向；与本栈正交，业务可 Transfer + PushMode 组合

	【标准用法】
	local CameraModule = Utils.CameraModule
	CameraModule.PushMode("Skill:Aim", CameraModule.Mode.Aim)
	CameraModule.PopMode("Skill:Aim")
	local mode = CameraModule.GetActiveMode() -- "Default" | "ShiftLock" | ...

	【默认优先级】未传 priority 时：ShiftLock=10、OTS=20、LockOn=30、Aim=40；同 priority 后 Push 胜出。
]]

local CameraConfig = require(script.Parent.CameraConfig)
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Players = Utils.Players

local CameraMode = {}

export type ModeName = "Default" | "ShiftLock" | "OTS" | "LockOn" | "Aim"

export type ModeEntry = {
	sourceId: string,
	mode: ModeName,
	priority: number,
	order: number,
}

export type CameraModeHooks = {
	enableHelper: (eventName: string, func: (number, number?) -> (CFrame?, number?)) -> (boolean, string?),
	disableHelper: (eventName: string) -> (boolean, string?),
}

local MODE = table.freeze({
	Default = "Default" :: ModeName,
	ShiftLock = "ShiftLock" :: ModeName,
	OTS = "OTS" :: ModeName,
	LockOn = "LockOn" :: ModeName,
	Aim = "Aim" :: ModeName,
})

CameraMode.Mode = MODE

local ATTRIBUTE_NAME = "CameraMode"
local HELPER_NAME = "CameraModeBaseline"
local ENGINE_SOURCE = "Engine:MouseLock"

local DEFAULT_PRIORITY: { [ModeName]: number } = {
	Default = 0,
	ShiftLock = 10,
	OTS = 20,
	LockOn = 30,
	Aim = 40,
}

local VALID_PUSH: { [string]: boolean } = {
	[MODE.ShiftLock] = true,
	[MODE.OTS] = true,
	[MODE.LockOn] = true,
	[MODE.Aim] = true,
}

local AIM_SHOULDER_X_SCALE = 0.35
local AIM_SHOULDER_Y_SCALE = 0.5
local FALLBACK_PUSH_PRIORITY = 10

local ERROR = table.freeze({
	NOT_INITIALIZED = "NOT_INITIALIZED",
	INVALID_ARGUMENT = "INVALID_ARGUMENT",
	SOURCE_NOT_FOUND = "SOURCE_NOT_FOUND",
})

CameraMode.ERROR_CODE = ERROR
CameraMode.ENGINE_SOURCE = ENGINE_SOURCE
CameraMode.ATTRIBUTE_NAME = ATTRIBUTE_NAME

local _initialized = false
local _hooks: CameraModeHooks? = nil
local _orderCounter = 0
local _sources: { [string]: ModeEntry } = {}
local _activeMode: ModeName = MODE.Default
local _helperRegistered = false

--[[
	读取 GameConfig.CameraModule 数值
	@param key string - 配置键
	@param fallback number - 缺省值
	@return number - 配置为 number 时用配置，否则 fallback
]]
local function _cfgNumber(key: string, fallback: number): number
	return CameraConfig.GetNumber(key, fallback)
end

--[[
	写入 LocalPlayer.CameraMode（仅变化时）
	@param mode ModeName - 要写入 Attribute 的优胜模式
	@return () - 无返回值
]]
local function _publishAttribute(mode: ModeName)
	local localPlayer = Players.LocalPlayer
	if not localPlayer then
		return
	end
	if localPlayer:GetAttribute(ATTRIBUTE_NAME) ~= mode then
		localPlayer:SetAttribute(ATTRIBUTE_NAME, mode)
	end
end

--[[
	选取优胜条目：priority 大者胜；同级 order 大者（后 Push）胜
	@return ModeEntry? - 优胜条目；栈空为 nil
]]
local function _pickWinner(): ModeEntry?
	local best: ModeEntry? = nil
	for _, entry in pairs(_sources) do
		if best == nil then
			best = entry
		elseif entry.priority > best.priority then
			best = entry
		elseif entry.priority == best.priority and entry.order > best.order then
			best = entry
		end
	end
	return best
end

--[[
	按当前优胜模式刷新 Helper（OTS 肩偏移 / Aim FOV 增量；Default/ShiftLock 注销）
	@param mode ModeName - 当前优胜模式
	@return () - 无返回值
]]
local function _applyHelper(mode: ModeName)
	local hooks = _hooks
	if not hooks then
		return
	end

	if mode == MODE.Default or mode == MODE.ShiftLock then
		if _helperRegistered then
			hooks.disableHelper(HELPER_NAME)
			_helperRegistered = false
		end
		return
	end

	local shoulderX = _cfgNumber("OTS肩偏移X", 1.5)
	local shoulderY = _cfgNumber("OTS肩偏移Y", 0.35)
	local shoulderZ = _cfgNumber("OTS肩偏移Z", 0.5)
	local lockOnScale = _cfgNumber("LockOn肩偏移系数", 0.6)
	local aimFovDelta = _cfgNumber("Aim视野增量", -8)

	-- 闭包捕获本次 mode 的肩偏 / FOV；注册进 Helper 后每帧调用
	local function _helper(_t: number, _dt: number?): (CFrame?, number?)
		if mode == MODE.OTS then
			return CFrame.new(shoulderX, shoulderY, shoulderZ), 0
		elseif mode == MODE.LockOn then
			return CFrame.new(shoulderX * lockOnScale, shoulderY * lockOnScale, shoulderZ * lockOnScale), 0
		elseif mode == MODE.Aim then
			return CFrame.new(shoulderX * AIM_SHOULDER_X_SCALE, shoulderY * AIM_SHOULDER_Y_SCALE, 0), aimFovDelta
		end
		return CFrame.new(), 0
	end

	if _helperRegistered then
		hooks.disableHelper(HELPER_NAME)
		_helperRegistered = false
	end
	local ok = hooks.enableHelper(HELPER_NAME, _helper)
	if ok then
		_helperRegistered = true
	end
end

--[[
	重算优胜模式并发布 Attribute / Helper
	@return () - 无返回值
]]
local function _rebuild()
	local winner = _pickWinner()
	local nextMode: ModeName = if winner then winner.mode else MODE.Default
	local modeChanged = nextMode ~= _activeMode
	_activeMode = nextMode
	_publishAttribute(nextMode)
	if modeChanged then
		_applyHelper(nextMode)
	end
end

--[[
	绑定 Helper 钩子并复位栈（由 CameraModule.Init 调用；子模块不用 Init 名以免与 Manager 编排混淆）
	@param hooks CameraModeHooks - Helper 注册钩子（避免循环 require 父模块）
	@return () - 无返回值
]]
function CameraMode.bind(hooks: CameraModeHooks)
	if _initialized then
		return
	end
	_hooks = hooks
	_orderCounter = 0
	table.clear(_sources)
	_activeMode = MODE.Default
	_helperRegistered = false
	_publishAttribute(MODE.Default)
	_initialized = true
end

--[[
	销毁：清栈、注销 Helper、复位 Attribute
	@return () - 无返回值
]]
function CameraMode.destroy()
	if not _initialized then
		return
	end
	if _helperRegistered and _hooks then
		_hooks.disableHelper(HELPER_NAME)
		_helperRegistered = false
	end
	table.clear(_sources)
	_activeMode = MODE.Default
	_publishAttribute(MODE.Default)
	_hooks = nil
	_initialized = false
end

--[[
	压入/覆盖一条模式
	@param sourceId string - 稳定来源 ID（如 "Skill:Aim" / Engine:MouseLock）
	@param mode ModeName - 不可为 Default（空栈即 Default）
	@param priority number? - 缺省按模式默认表
	@return boolean, string? - 是否成功 / 错误码
]]
function CameraMode.PushMode(sourceId: string, mode: ModeName, priority: number?): (boolean, string?)
	if not _initialized then
		return false, ERROR.NOT_INITIALIZED
	end
	if type(sourceId) ~= "string" or sourceId == "" then
		return false, ERROR.INVALID_ARGUMENT
	end
	if type(mode) ~= "string" or not VALID_PUSH[mode] then
		return false, ERROR.INVALID_ARGUMENT
	end
	local prio = priority
	if prio == nil then
		prio = DEFAULT_PRIORITY[mode :: ModeName] or FALLBACK_PUSH_PRIORITY
	elseif type(prio) ~= "number" then
		return false, ERROR.INVALID_ARGUMENT
	end
	_orderCounter += 1
	_sources[sourceId] = {
		sourceId = sourceId,
		mode = mode :: ModeName,
		priority = prio,
		order = _orderCounter,
	}
	_rebuild()
	return true
end

--[[
	弹出指定来源
	@param sourceId string - 与 PushMode 对应的来源 ID
	@return boolean, string? - 是否成功 / 错误码
]]
function CameraMode.PopMode(sourceId: string): (boolean, string?)
	if not _initialized then
		return false, ERROR.NOT_INITIALIZED
	end
	if type(sourceId) ~= "string" or sourceId == "" then
		return false, ERROR.INVALID_ARGUMENT
	end
	if _sources[sourceId] == nil then
		return false, ERROR.SOURCE_NOT_FOUND
	end
	_sources[sourceId] = nil
	_rebuild()
	return true
end

--[[
	当前优胜模式（栈空为 Default）
	@return ModeName - "Default" | "ShiftLock" | "OTS" | "LockOn" | "Aim"
]]
function CameraMode.GetActiveMode(): ModeName
	return _activeMode
end

--[[
	当前优胜条目浅拷贝；栈空返回 nil（避免外部改写 priority/order）
	@return ModeEntry? - { sourceId, mode, priority, order } 拷贝
]]
function CameraMode.GetActiveEntry(): ModeEntry?
	local winner = _pickWinner()
	if not winner then
		return nil
	end
	return {
		sourceId = winner.sourceId,
		mode = winner.mode,
		priority = winner.priority,
		order = winner.order,
	}
end

--[[
	引擎 MouseLock 开/关 → 映射栈源 Engine:MouseLock（ShiftLock）
	@param locked boolean - MouseBehavior == LockCenter
	@return () - 无返回值
]]
function CameraMode.SyncEngineShiftLock(locked: boolean)
	if not _initialized then
		return
	end
	if locked then
		local existing = _sources[ENGINE_SOURCE]
		if existing and existing.mode == MODE.ShiftLock then
			return
		end
		CameraMode.PushMode(ENGINE_SOURCE, MODE.ShiftLock, DEFAULT_PRIORITY.ShiftLock)
	elseif _sources[ENGINE_SOURCE] ~= nil then
		CameraMode.PopMode(ENGINE_SOURCE)
	end
end

return CameraMode