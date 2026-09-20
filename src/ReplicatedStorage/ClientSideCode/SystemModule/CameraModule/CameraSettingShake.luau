--[[
	Module: CameraModule.CameraSettingShake
	Description: 监听 LocalPlayer.Setting.Shake 并注入 ShakeRuntime 设置震动强度（由 CameraModule/init 调用，业务勿直接 require）
	Author: 林奥宇
	Created: 2026-08-18
	Last Modified: 2026-08-31

	功能：
	- 解析 NumberValue：>1 视为 0~100 滑条，否则视为 0~1
	- Setting 晚到时经 ChildAdded 延迟绑定

	与 init：Init 时 bind()，destroy 时 destroy()。全局 SetShakeScale 仍走 ShakeRuntime，与本滑条正交。
]]

local ShakeRuntime = require(script.Parent.ShakeRuntime)
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Players = Utils.Players

local CameraSettingShake = {}

local SETTING_SHAKE_NAME = "Shake"
local SETTING_FOLDER_NAME = "Setting"

local _settingFolderConn: RBXScriptConnection? = nil
local _settingShakeConn: RBXScriptConnection? = nil
local _settingShakeScale = 1

--[[
	解析 NumberValue 为 0~1 震动强度
	@param shakeValue NumberValue - Setting.Shake
	@return number - 0~1
]]
local function _parseSettingShakeValue(shakeValue: NumberValue): number
	local v = shakeValue.Value
	if v > 1 then
		return math.clamp(v / 100, 0, 1)
	end
	return math.clamp(v, 0, 1)
end

--[[
	将缓存的设置震动强度同步到 ShakeRuntime
	@return () - 无返回值
]]
local function _applySettingShakeScale()
	ShakeRuntime.SetSettingShakeScale(_settingShakeScale)
end

--[[
	绑定 Setting.Shake NumberValue（Changed）
	@param shakeValue NumberValue - 滑条值
	@return () - 无返回值
]]
local function _bindShakeNumberValue(shakeValue: NumberValue)
	if _settingShakeConn then
		_settingShakeConn:Disconnect()
		_settingShakeConn = nil
	end
	_settingShakeScale = _parseSettingShakeValue(shakeValue)
	_applySettingShakeScale()
	_settingShakeConn = shakeValue.Changed:Connect(function()
		_settingShakeScale = _parseSettingShakeValue(shakeValue)
		_applySettingShakeScale()
	end)
end

--[[
	尝试在 Setting 文件夹下绑定 Shake
	@param settingFolder Instance - LocalPlayer.Setting
	@return () - 无返回值
]]
local function _tryBindShakeFromFolder(settingFolder: Instance)
	local shakeValue = settingFolder:FindFirstChild(SETTING_SHAKE_NAME)
	if shakeValue and shakeValue:IsA("NumberValue") then
		_bindShakeNumberValue(shakeValue)
	end
end

--[[
	绑定 / 延迟绑定玩家设置震动强度
	@return () - 无返回值
]]
function CameraSettingShake.bind()
	if _settingFolderConn then
		_settingFolderConn:Disconnect()
		_settingFolderConn = nil
	end
	if _settingShakeConn then
		_settingShakeConn:Disconnect()
		_settingShakeConn = nil
	end
	_settingShakeScale = 1
	_applySettingShakeScale()

	local localPlayer = Players.LocalPlayer
	if not localPlayer then
		return
	end

	local settingFolder = localPlayer:FindFirstChild(SETTING_FOLDER_NAME)
	if settingFolder then
		_tryBindShakeFromFolder(settingFolder)
		_settingFolderConn = settingFolder.ChildAdded:Connect(function(child)
			if child.Name == SETTING_SHAKE_NAME and child:IsA("NumberValue") then
				_bindShakeNumberValue(child)
			end
		end)
		return
	end

	_settingFolderConn = localPlayer.ChildAdded:Connect(function(child)
		if child.Name ~= SETTING_FOLDER_NAME then
			return
		end
		if _settingFolderConn then
			_settingFolderConn:Disconnect()
			_settingFolderConn = nil
		end
		_tryBindShakeFromFolder(child)
		_settingFolderConn = child.ChildAdded:Connect(function(grandChild)
			if grandChild.Name == SETTING_SHAKE_NAME and grandChild:IsA("NumberValue") then
				_bindShakeNumberValue(grandChild)
			end
		end)
	end)
end

--[[
	断开 Setting 文件夹与 Shake NumberValue 监听
	@return () - 无返回值
]]
function CameraSettingShake.destroy()
	if _settingFolderConn then
		_settingFolderConn:Disconnect()
		_settingFolderConn = nil
	end
	if _settingShakeConn then
		_settingShakeConn:Disconnect()
		_settingShakeConn = nil
	end
end

return CameraSettingShake
