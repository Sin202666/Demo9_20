--[[
	Module: SystemTeleport
	Description: 服务端传送工具，支持 TeleportAsync 失败自动重试
	Author: Dev-Framework
	Created: 2026-07-03
	Last Modified: 2026-07-03

	功能：
	- TeleportWithRetry：向目标 Place 传送玩家，失败或 TeleportInitFailed 时按间隔重试
	- IsPending：查询玩家是否已有进行中的传送重试上下文
	- 重试上限 MAX_WAIT 秒，超出后停止并清理上下文

	用法：
	  local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
	  local SystemTeleport = Utils.SystemTeleport
	  SystemTeleport.TeleportWithRetry(game.PlaceId, { player })
]]

-- ============================================================================
-- Services
-- ============================================================================

local TeleportService = game:GetService("TeleportService")
local Players = game:GetService("Players")

-- ============================================================================
-- Requires
-- ============================================================================

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Log = Utils.Log

-- ============================================================================
-- Module
-- ============================================================================

local SystemTeleport = {}

-- ============================================================================
-- Constants
-- ============================================================================

local RETRY_DELAY = 30
local MAX_WAIT = 600

-- ============================================================================
-- Types & private state
-- ============================================================================

type RetryContext = {
	targetPlaceId: number,
	options: TeleportOptions?,
	loadingUI: Instance?,
	elapsedWait: number,
}

local _retryContexts: {[number]: RetryContext} = {}
local _listenersBound = false

-- ============================================================================
-- Private functions
-- ============================================================================

--[[
	清理指定玩家的重试上下文
	@param userId number - 玩家 UserId
]]
local function _clearContext(userId: number)
	_retryContexts[userId] = nil
end

--[[
	执行一次 TeleportAsync
	@param ctx RetryContext - 重试上下文
	@param players {Player} - 待传送玩家列表
	@return boolean - 是否调用成功（不含 TeleportInitFailed）
]]
local function _doTeleport(ctx: RetryContext, players: {Player}): boolean
	local success, err = pcall(function()
		return TeleportService:TeleportAsync(ctx.targetPlaceId, players, ctx.options, ctx.loadingUI)
	end)
	if not success then
		Log.warn("TeleportAsync 失败:", err)
	end
	return success
end

--[[
	为指定玩家调度延迟重试
	@param userId number - 玩家 UserId
]]
local function _scheduleRetry(userId: number)
	local ctx = _retryContexts[userId]
	if not ctx then
		return
	end

	if ctx.elapsedWait >= MAX_WAIT then
		_clearContext(userId)
		Log.warn("传送重试已达上限，停止:", userId)
		return
	end

	task.delay(RETRY_DELAY, function()
		local player = Players:GetPlayerByUserId(userId)
		local activeCtx = _retryContexts[userId]
		if not player or not player.Parent or not activeCtx then
			_clearContext(userId)
			return
		end

		activeCtx.elapsedWait += RETRY_DELAY
		if not _doTeleport(activeCtx, { player }) then
			_scheduleRetry(userId)
		end
	end)
end

--[[
	绑定 TeleportInitFailed 与 PlayerRemoving 全局监听（仅一次）
]]
local function _ensureListeners()
	if _listenersBound then
		return
	end
	_listenersBound = true

	TeleportService.TeleportInitFailed:Connect(function(player: Player, teleportResult: Enum.TeleportResult, errorMessage: string)
		if teleportResult == Enum.TeleportResult.Success then
			return
		end
		if not _retryContexts[player.UserId] then
			return
		end
		Log.warn("TeleportInitFailed:", player.Name, errorMessage)
		_scheduleRetry(player.UserId)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		_clearContext(player.UserId)
	end)
end

-- ============================================================================
-- Public API
-- ============================================================================

--[[
	查询玩家是否已有进行中的传送重试
	@param player Player - 目标玩家
	@return boolean - 是否已有重试上下文
]]
function SystemTeleport.IsPending(player: Player): boolean
	return _retryContexts[player.UserId] ~= nil
end

--[[
	向目标 Place 传送玩家，失败时自动重试；已在重试中的玩家会被跳过
	@param targetPlaceId number - 目标 PlaceId
	@param players {Player} - 待传送玩家列表
	@param teleportOptions TeleportOptions? - 传送选项，默认 nil
	@param loadingUI Instance? - 加载界面实例，默认 nil
]]
function SystemTeleport.TeleportWithRetry(
	targetPlaceId: number,
	players: {Player},
	teleportOptions: TeleportOptions?,
	loadingUI: Instance?
)
	_ensureListeners()

	local playersToTeleport: {Player} = {}

	for _, player in players do
		if not player or not player.Parent then
			continue
		end
		if _retryContexts[player.UserId] then
			continue
		end

		_retryContexts[player.UserId] = {
			targetPlaceId = targetPlaceId,
			options = teleportOptions,
			loadingUI = loadingUI,
			elapsedWait = 0,
		}
		table.insert(playersToTeleport, player)
	end

	if #playersToTeleport == 0 then
		return
	end

	if not _doTeleport({
		targetPlaceId = targetPlaceId,
		options = teleportOptions,
		loadingUI = loadingUI,
		elapsedWait = 0,
	}, playersToTeleport) then
		for _, player in playersToTeleport do
			if _retryContexts[player.UserId] then
				_scheduleRetry(player.UserId)
			end
		end
	end
end

return SystemTeleport
