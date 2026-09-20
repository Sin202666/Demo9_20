--[[
	Module: SystemLightingWeather/QualityGate
	Description: 监听本地 GraphicsQuality 设置并驱动 SystemLighting 低画质模式
	Author: 林奥宇
	Created: 2026-08-04
	Last Modified: 2026-08-31

	设置项：Player.Setting.GraphicsQuality（0 低 / 1 高，见 EnumMgr.LightingGraphicsQuality）

	边界语义（与 SystemLighting.setGraphicsQualityLow 配合）：
	- 切至低：SystemLighting 立即 hide Bloom/DoF/SunRays，关 Cloud 微动
	- 低→高：SystemLighting 不 restore 被 skip 通道；本模块回调须触发 Weather.reapplyEffective
	  （SystemLightingWeather.Init 内 bind 已绑定：画质变化且首次 apply 完成后 reapply）
	- 同档重复：QualityGate 不回调；SystemLighting 仅同步 Cloud 微动
	- GraphicsQuality / Setting 被移除：回退高画质并回调（避免低档永久粘住）
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Players = Utils.Players
local EnumMgr = Utils.EnumMgr

local SETTING_FOLDER_NAME = "Setting"
local SETTING_GRAPHICS_QUALITY = "GraphicsQuality"
local GRAPHICS_QUALITY_LOW = EnumMgr.LightingGraphicsQuality.Low

local QualityGate = {}

export type QualityGateState = {
	_folderAddedConn: RBXScriptConnection?,
	_folderRemovedConn: RBXScriptConnection?,
	_valueConn: RBXScriptConnection?,
	_playerAddedConn: RBXScriptConnection?,
	_playerRemovedConn: RBXScriptConnection?,
	_isLow: boolean,
	_onChanged: ((boolean) -> ())?,
}

-- ========================================
-- 公共函数
-- ========================================
--[[
	从 NumberValue / GetData 读取是否为低画质

	@param value number? - 设置值；nil 视为高（不降级）
	@return boolean - true 低画质
]]
function QualityGate.isLowFromValue(value: number?): boolean
	return value == GRAPHICS_QUALITY_LOW
end

--[[
	创建监听状态（未绑定）

	@return QualityGateState - 状态表
]]
function QualityGate.createState(): QualityGateState
	return {
		_folderAddedConn = nil,
		_folderRemovedConn = nil,
		_valueConn = nil,
		_playerAddedConn = nil,
		_playerRemovedConn = nil,
		_isLow = false,
		_onChanged = nil,
	}
end

-- ========================================
-- 私有函数
-- ========================================
--[[
	断开 Setting 文件夹级连接（含 GraphicsQuality Value）

	@param state QualityGateState - 状态
	@return nil - 无返回值
]]
local function _disconnectFolderConns(state: QualityGateState)
	if state._valueConn then
		state._valueConn:Disconnect()
		state._valueConn = nil
	end
	if state._folderAddedConn then
		state._folderAddedConn:Disconnect()
		state._folderAddedConn = nil
	end
	if state._folderRemovedConn then
		state._folderRemovedConn:Disconnect()
		state._folderRemovedConn = nil
	end
end

-- ========================================
-- 公共函数（续）
-- ========================================
--[[
	断开全部连接

	@param state QualityGateState - 状态
	@return nil - 无返回值
]]
function QualityGate.disconnect(state: QualityGateState)
	_disconnectFolderConns(state)
	if state._playerAddedConn then
		state._playerAddedConn:Disconnect()
		state._playerAddedConn = nil
	end
	if state._playerRemovedConn then
		state._playerRemovedConn:Disconnect()
		state._playerRemovedConn = nil
	end
end

--[[
	应用新低画质标记（有变化才回调）

	@param state QualityGateState - 状态
	@param isLow boolean - 是否低画质
	@return nil - 无返回值
]]
local function _applyIsLow(state: QualityGateState, isLow: boolean)
	if state._isLow == isLow then
		return
	end
	state._isLow = isLow
	if state._onChanged then
		state._onChanged(isLow)
	end
end

--[[
	绑定 GraphicsQuality NumberValue

	@param state QualityGateState - 状态
	@param valueObject NumberValue - 设置值
	@return nil - 无返回值
]]
local function _bindValue(state: QualityGateState, valueObject: NumberValue)
	if state._valueConn then
		state._valueConn:Disconnect()
		state._valueConn = nil
	end
	_applyIsLow(state, QualityGate.isLowFromValue(valueObject.Value))
	state._valueConn = valueObject.Changed:Connect(function()
		_applyIsLow(state, QualityGate.isLowFromValue(valueObject.Value))
	end)
end

--[[
	按 Setting 文件夹当前内容解析 GraphicsQuality；缺失则回退高画质

	@param state QualityGateState - 状态
	@param settingFolder Instance - Player.Setting
	@return nil - 无返回值
]]
local function _resolveGraphicsFromFolder(state: QualityGateState, settingFolder: Instance)
	local graphicsValue = settingFolder:FindFirstChild(SETTING_GRAPHICS_QUALITY)
	if graphicsValue and graphicsValue:IsA("NumberValue") then
		_bindValue(state, graphicsValue)
		return
	end
	if state._valueConn then
		state._valueConn:Disconnect()
		state._valueConn = nil
	end
	_applyIsLow(state, false)
end

--[[
	绑定 Setting 文件夹（ChildAdded / ChildRemoved）

	@param state QualityGateState - 状态
	@param settingFolder Instance - Player.Setting
	@return nil - 无返回值
]]
local function _bindSettingFolder(state: QualityGateState, settingFolder: Instance)
	_disconnectFolderConns(state)
	_resolveGraphicsFromFolder(state, settingFolder)

	state._folderAddedConn = settingFolder.ChildAdded:Connect(function(child)
		if child.Name == SETTING_GRAPHICS_QUALITY and child:IsA("NumberValue") then
			_bindValue(state, child)
		end
	end)

	state._folderRemovedConn = settingFolder.ChildRemoved:Connect(function(child)
		if child.Name == SETTING_GRAPHICS_QUALITY then
			_resolveGraphicsFromFolder(state, settingFolder)
		end
	end)
end

--[[
	开始监听本地玩家 Setting（仿 CameraModule Shake）

	@param state QualityGateState - 状态
	@param onChanged (boolean) -> () - 低画质变化回调
	@return nil - 无返回值
]]
function QualityGate.bind(state: QualityGateState, onChanged: (boolean) -> ())
	QualityGate.disconnect(state)
	state._onChanged = onChanged

	local localPlayer = Players.LocalPlayer
	if not localPlayer then
		return
	end

	local settingFolder = localPlayer:FindFirstChild(SETTING_FOLDER_NAME)
	if settingFolder then
		_bindSettingFolder(state, settingFolder)
	else
		-- 无 Setting 时默认高画质；等待文件夹出现
		_applyIsLow(state, false)
	end

	state._playerAddedConn = localPlayer.ChildAdded:Connect(function(child)
		if child.Name == SETTING_FOLDER_NAME then
			_bindSettingFolder(state, child)
		end
	end)

	state._playerRemovedConn = localPlayer.ChildRemoved:Connect(function(child)
		if child.Name == SETTING_FOLDER_NAME then
			_disconnectFolderConns(state)
			_applyIsLow(state, false)
		end
	end)
end

--[[
	当前缓存的低画质标记

	@param state QualityGateState - 状态
	@return boolean - 是否低画质
]]
function QualityGate.getIsLow(state: QualityGateState): boolean
	return state._isLow == true
end

return QualityGate
