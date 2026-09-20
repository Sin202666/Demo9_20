--[[
	Module: PlayerData
	Description: 客户端入服请求会话全量同步，直到本地缓存就绪后退出
	Author: 林奥宇
	Created: 2026-02-03
	Last Modified: 2026-08-31

	功能：
	- 向服务端 FireServer PLAYER_DATA_REQUEST
	- 若首次请求时会话尚未加载，按间隔重试直到 GetPlrData 非 nil
	- 收到 PLAYER_DATA_SYNC 后立即停止重试（ListenClientSync）

	与 ToolSystem.PlayerData 的关系：
	- 本脚本只做入服编排；读写与缓存在 Utils.PlayerData
	- 不写存档、不结算奖励、不绑定业务 Remote
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local NetMsg = Utils.NetMsg
local NetWork = Utils.NetWork
local PlayerData = Utils.PlayerData
local Players = Utils.Players

local REQUEST_RETRY_SEC = 1

local localPlayer: Player = Players.LocalPlayer

--[[
	本地会话缓存是否已就绪

	@return boolean - GetPlrData 非 nil 为 true
]]
local function _hasLocalData(): boolean
	return PlayerData.GetPlrData(localPlayer) ~= nil
end

--[[
	向服务端请求一次全量回推

	@return nil
]]
local function _requestFullSync()
	NetWork.FireServer(NetMsg.PLAYER_DATA_REQUEST)
end

if _hasLocalData() then
	return
end

_requestFullSync()

if _hasLocalData() then
	return
end

local finished = false
local retryThread: thread? = nil
local disconnectListen: (() -> ())?

--[[
	停止重试并取消同步监听（可重复调用）

	@return nil
]]
local function _finish()
	if finished then
		return
	end
	finished = true
	if disconnectListen then
		disconnectListen()
		disconnectListen = nil
	end
	local thread = retryThread
	retryThread = nil
	if thread then
		task.cancel(thread)
	end
end

disconnectListen = PlayerData.ListenClientSync(function()
	if _hasLocalData() then
		_finish()
	end
end)

if _hasLocalData() then
	_finish()
	return
end

retryThread = task.spawn(function()
	while not finished and not _hasLocalData() do
		task.wait(REQUEST_RETRY_SEC)
		if finished or _hasLocalData() then
			break
		end
		_requestFullSync()
	end
	retryThread = nil
	_finish()
end)
