--[[
	Module: CameraModule.CameraShiftLock
	Description: ShiftLock 属性同步与 MouseLock 开关键重绑（由 CameraModule/init 调用，业务勿直接 require）
	Author: 林奥宇
	Created: 2026-08-18
	Last Modified: 2026-08-31

	功能：
	- MouseBehavior.LockCenter → LocalPlayer.IsShiftLocked（仅值变化时写入）
	- 同步 CameraMode.SyncEngineShiftLock
	- 将引擎 MouseLockController.BoundKeys 重绑到 GameConfig.CharacterControl.ShiftLock键（默认 LeftControl）

	与 init：Init 时 bind()，destroy 时 destroy() 递增世代号以作废进行中的 WaitForChild。
]]

local CameraMode = require(script.Parent.CameraMode)
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Players = Utils.Players
local UserInputService = Utils.UserInputService
local GameConfig = Utils.GameConfig

local CameraShiftLock = {}

local SHIFT_LOCK_ATTRIBUTE = "IsShiftLocked"
local DEFAULT_SHIFT_LOCK_KEY = "LeftControl"
local REBIND_WAIT_SEC = 30
local PLAYER_SCRIPTS_NAME = "PlayerScripts"
local PLAYER_MODULE_NAME = "PlayerModule"
local CAMERA_FOLDER_NAME = "CameraModule"
local MOUSE_LOCK_CONTROLLER_NAME = "MouseLockController"
local BOUND_KEYS_NAME = "BoundKeys"

local _shiftLockConn: RBXScriptConnection? = nil
local _mouseLockRebindToken = 0

--[[
	将当前鼠标锁定状态同步到 LocalPlayer.IsShiftLocked（仅值变化时写入）
	@return () - 无返回值
]]
local function _syncShiftLockAttribute()
	local localPlayer = Players.LocalPlayer
	if not localPlayer then
		return
	end
	local locked = UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter
	if localPlayer:GetAttribute(SHIFT_LOCK_ATTRIBUTE) ~= locked then
		localPlayer:SetAttribute(SHIFT_LOCK_ATTRIBUTE, locked)
	end
	CameraMode.SyncEngineShiftLock(locked)
end

--[[
	解析 ShiftLock 开关键名（默认 LeftControl，与奔跑 LeftShift 分离）
	@return string - BoundKeys 用的 KeyCode 名
]]
local function _resolveShiftLockKeyName(): string
	local cc = GameConfig.CharacterControl
	if type(cc) == "table" then
		local name = cc["ShiftLock键"]
		if type(name) == "string" and name ~= "" then
			return name
		end
	end
	return DEFAULT_SHIFT_LOCK_KEY
end

--[[
	将引擎默认 ShiftLock 从 LeftShift 重绑到配置键（写 MouseLockController.BoundKeys）
	@return () - 无返回值
]]
local function _rebindMouseLockToggleKeys()
	local keyName = _resolveShiftLockKeyName()
	_mouseLockRebindToken += 1
	local token = _mouseLockRebindToken
	task.spawn(function()
		local localPlayer = Players.LocalPlayer
		if not localPlayer then
			return
		end
		local playerScripts = localPlayer:WaitForChild(PLAYER_SCRIPTS_NAME, REBIND_WAIT_SEC)
		if not playerScripts or token ~= _mouseLockRebindToken then
			return
		end
		local playerModule = playerScripts:WaitForChild(PLAYER_MODULE_NAME, REBIND_WAIT_SEC)
		if not playerModule or token ~= _mouseLockRebindToken then
			return
		end
		local cameraFolder = playerModule:WaitForChild(CAMERA_FOLDER_NAME, REBIND_WAIT_SEC)
		if not cameraFolder or token ~= _mouseLockRebindToken then
			return
		end
		local mouseLockController = cameraFolder:WaitForChild(MOUSE_LOCK_CONTROLLER_NAME, REBIND_WAIT_SEC)
		if not mouseLockController or token ~= _mouseLockRebindToken then
			return
		end
		local boundKeys = mouseLockController:FindFirstChild(BOUND_KEYS_NAME)
		if not boundKeys then
			boundKeys = Instance.new("StringValue")
			boundKeys.Name = BOUND_KEYS_NAME
			boundKeys.Parent = mouseLockController
		end
		if boundKeys:IsA("StringValue") and boundKeys.Value ~= keyName then
			boundKeys.Value = keyName
		end
	end)
end

--[[
	订阅 MouseBehavior 并重绑开关键（Init 调用）
	@return () - 无返回值
]]
function CameraShiftLock.bind()
	_syncShiftLockAttribute()
	_shiftLockConn = UserInputService:GetPropertyChangedSignal("MouseBehavior"):Connect(_syncShiftLockAttribute)
	_rebindMouseLockToggleKeys()
end

--[[
	断开连接并作废进行中的 WaitForChild 重绑
	@return () - 无返回值
]]
function CameraShiftLock.destroy()
	_mouseLockRebindToken += 1
	if _shiftLockConn then
		_shiftLockConn:Disconnect()
		_shiftLockConn = nil
	end
end

return CameraShiftLock
