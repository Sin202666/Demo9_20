--[[
	Module: FootStepManager
	Description: 客户端脚步声音管理器，为所有玩家绑定/解绑 FootstepSoundModule
	Author: 林奥宇
	Created: 2026-07-03
	Last Modified: 2026-09-01

	功能：
	- 监听 PlayerAdded / PlayerRemoving / CharacterAdded，创建与销毁播放器
	- 角色移出世界时清运行时（保留 CharacterAdded，便于重生再绑）
	- GameConfig.FootStep.启用 为 false 时本 Manager 不运行

	与相关模块：
	- FootstepSoundModule：单角色计步、落地音、静音默认 Running/Landing
	- FootLand：本地动画 Marker 写 AnimFootStepAt；本 Manager 不播 Marker 脚步
	- ToolSystem/FootstepSound：简单 Running 替换，不走本编排

	配置（GameConfig.FootStep）：
	- 启用：false 时直接 return
	- 动画Marker驱动：由 FootstepSoundModule 读取，抑制速度计步双踩

	加载：LocalScript，随 StarterPlayerScripts 启动；不经 Utils 注册。
]]

-- ============================================================================
-- 模块引用 / 开关
-- ============================================================================

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local SystemGameConfig = Utils.SystemGameConfig

if SystemGameConfig.GetValue({ "FootStep", "启用" }) == false then
	return
end

local Players = Utils.Players
local Log = Utils.Log
local FootstepSoundModule = require(script.FootstepSoundModule)

-- ============================================================================
-- 私有变量
-- ============================================================================

-- _playerFootstepData[player] = { footstepPlayer, cleanupConnection, characterAddedConnection, bindId }
local _playerFootstepData = {}

-- ============================================================================
-- 私有函数
-- ============================================================================

--[[
	断开角色运行时（播放器 + AncestryChanged），保留 CharacterAdded

	@param data table - 玩家条目；允许缺字段
]]
local function _clearCharacterRuntime(data)
	if data.cleanupConnection then
		data.cleanupConnection:Disconnect()
		data.cleanupConnection = nil
	end
	if data.footstepPlayer then
		data.footstepPlayer:destroy()
		data.footstepPlayer = nil
	end
end

--[[
	清理玩家全部脚步数据（含 CharacterAdded）

	@param player Player - 离场或需全量解绑的玩家
]]
local function _cleanupPlayerFootstep(player)
	local data = _playerFootstepData[player]
	if not data then
		return
	end
	if data.characterAddedConnection then
		data.characterAddedConnection:Disconnect()
	end
	_clearCharacterRuntime(data)
	_playerFootstepData[player] = nil
end

--[[
	为指定角色创建播放器并监听移出世界

	@param player Player - 所属玩家
	@param character Model - 角色模型
]]
local function _bindCharacter(player, character)
	local data = _playerFootstepData[player]
	if not data then
		return
	end
	_clearCharacterRuntime(data)

	-- new() 内 WaitForChild 会 yield；用代数丢掉过期绑定，避免快重生叠两个播放器
	data.bindId = (data.bindId or 0) + 1
	local bindId = data.bindId
	local footstepPlayer = FootstepSoundModule.new(character)
	if data.bindId ~= bindId then
		if footstepPlayer then
			footstepPlayer:destroy()
		end
		return
	end
	if not footstepPlayer then
		Log.warn("FootStepManager: 角色脚步播放器创建失败", player.Name)
		return
	end

	data.footstepPlayer = footstepPlayer
	data.cleanupConnection = character.AncestryChanged:Connect(function()
		if character.Parent then
			return
		end
		local currentData = _playerFootstepData[player]
		if currentData then
			_clearCharacterRuntime(currentData)
		end
	end)
end

--[[
	为玩家绑定 CharacterAdded，并处理当前已有角色

	@param player Player - 目标玩家
]]
local function _bindPlayerCharacter(player)
	local data = _playerFootstepData[player]
	if data and data.characterAddedConnection then
		data.characterAddedConnection:Disconnect()
	end
	if not data then
		data = {
			footstepPlayer = nil,
			cleanupConnection = nil,
			characterAddedConnection = nil,
		}
		_playerFootstepData[player] = data
	end

	data.characterAddedConnection = player.CharacterAdded:Connect(function(character)
		_bindCharacter(player, character)
	end)
	if player.Character then
		_bindCharacter(player, player.Character)
	end
end

-- ============================================================================
-- 初始化
-- ============================================================================

for _, player in ipairs(Players:GetPlayers()) do
	_bindPlayerCharacter(player)
end

Players.PlayerAdded:Connect(_bindPlayerCharacter)
Players.PlayerRemoving:Connect(_cleanupPlayerFootstep)
