--[[
	Module: SystemInputBind
	Description: 玩家输入键位存档读写（不透明 Binding 表；非 SystemSet 数值管线）
	Author: 林奥宇
	Created: 2026-08-27
	Last Modified: 2026-08-28

	功能：
	- Get / Set InputBindings 存档字段
	- RegisterNetWork：INPUT_BINDINGS_GET / INPUT_BINDINGS_SET（模块加载时注册，入服前必须就绪）
	- Init：SET/GET 限频；须由 UpdateManager 显式调用

	形状：
		InputBindings = {
			[scheme] = { [actionId] = "KeyCodeName" },
		}
		scheme ≤ 8；每 scheme action ≤ 64；actionId ≤ 64 字符；KeyCode.Name ≤ 48 字符

	加载：
		local SystemInputBind = Utils.SystemInputBind
		SystemInputBind.Init()

	形状：
		InputBindings = {
			[scheme] = { [actionId] = "KeyCodeName" },
		}
		scheme ≤ 8；每 scheme action ≤ 64；actionId ≤ 64 字符；KeyCode.Name ≤ 48 字符

	加载：
		local SystemInputBind = Utils.SystemInputBind
		SystemInputBind.Init()
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Copy = Utils.Copy
local Log = Utils.Log
local NetMsg = Utils.NetMsg
local NetWork = Utils.NetWork
local PlayerData = Utils.PlayerData
local RequestRateLimit = Utils.RequestRateLimit

local SystemInputBind = {}

local SAVE_KEY = "InputBindings"
local MAX_SCHEMES = 8
local MAX_ACTIONS_PER_SCHEME = 64
local MAX_ACTION_ID_LEN = 64
local MAX_KEYCODE_NAME_LEN = 48
local _inited = false

--[[
	校验玩家在线
	@param player Player? - 玩家
	@return boolean - 有效为 true
]]
local function _validatePlayer(player: Player?): boolean
	return player ~= nil and player:IsA("Player") and player.Parent ~= nil
end

--[[
	校验并深拷贝 bindings 表
	@param raw any - { [scheme: string]: { [actionId: string]: KeyCode.Name } }；上限见文件头
	@return table? - 合法拷贝；非法为 nil
	@return string? - 错误码
]]
local function _sanitizeBindings(raw: any): ({ [string]: { [string]: string } }?, string?)
	if type(raw) ~= "table" then
		return nil, "INVALID_TYPE"
	end
	local out: { [string]: { [string]: string } } = {}
	local schemeCount = 0
	for scheme, actions in pairs(raw) do
		if type(scheme) ~= "string" or scheme == "" then
			return nil, "INVALID_SCHEME"
		end
		if type(actions) ~= "table" then
			return nil, "INVALID_SCHEME_TABLE"
		end
		schemeCount += 1
		if schemeCount > MAX_SCHEMES then
			return nil, "TOO_MANY_SCHEMES"
		end
		local actionMap: { [string]: string } = {}
		local actionCount = 0
		for actionId, keyName in pairs(actions) do
			if type(actionId) ~= "string" or actionId == "" or #actionId > MAX_ACTION_ID_LEN then
				return nil, "INVALID_ACTION"
			end
			if type(keyName) ~= "string" or keyName == "" or #keyName > MAX_KEYCODE_NAME_LEN then
				return nil, "INVALID_KEYCODE"
			end
			actionCount += 1
			if actionCount > MAX_ACTIONS_PER_SCHEME then
				return nil, "TOO_MANY_ACTIONS"
			end
			actionMap[actionId] = keyName
		end
		out[scheme] = actionMap
	end
	return out, nil
end

--[[
	读取玩家键位表（深拷贝）
	@param player Player - 目标玩家
	@return table - InputBindings；无数据时为空表
]]
function SystemInputBind.Get(player: Player): { [string]: { [string]: string } }
	if not _validatePlayer(player) then
		return {}
	end
	local plrData = PlayerData.GetPlrData(player)
	if not plrData then
		return {}
	end
	local bindings = plrData[SAVE_KEY]
	if type(bindings) ~= "table" then
		return {}
	end
	return Copy.deepCopy(bindings) :: any
end

--[[
	写入玩家键位表
	@param player Player - 目标玩家
	@param bindings table - scheme → actionId → KeyCode.Name
	@return boolean - 成功为 true
	@return string? - 错误码
]]
function SystemInputBind.Set(player: Player, bindings: any): (boolean, string?)
	if not _validatePlayer(player) then
		return false, "INVALID_PLAYER"
	end
	local clean, err = _sanitizeBindings(bindings)
	if not clean then
		return false, err
	end
	local ok, changeErr = PlayerData.ChangePlrData(player, { SAVE_KEY }, clean)
	if not ok then
		return false, changeErr or "CHANGE_FAILED"
	end
	return true, nil
end

--[[
	注册 RemoteFunction（模块加载时调用一次）
]]
function SystemInputBind.RegisterNetWork()
	NetWork.RegisterServerRemoteFunction(NetMsg.INPUT_BINDINGS_GET, function(player: Player)
		if not _validatePlayer(player) then
			Log.warn("[SystemInputBind] GET 无效玩家")
			return {}
		end
		return SystemInputBind.Get(player)
	end)
	NetWork.RegisterServerRemoteFunction(NetMsg.INPUT_BINDINGS_SET, function(player: Player, bindings: any)
		if not _validatePlayer(player) then
			Log.warn("[SystemInputBind] SET 无效玩家")
			return false
		end
		local ok, err = SystemInputBind.Set(player, bindings)
		if not ok then
			Log.warn("[SystemInputBind] SET 失败:", err)
		end
		return ok
	end)
end

--[[
	Manager-only：限频（Remote 已在模块加载时注册）
]]
function SystemInputBind.Init()
	if _inited then
		return
	end
	_inited = true
	if RequestRateLimit and RequestRateLimit.SetRateLimitConfig then
		RequestRateLimit.SetRateLimitConfig(NetMsg.INPUT_BINDINGS_SET, {
			maxRequests = 6,
			timeWindow = 2,
		})
		RequestRateLimit.SetRateLimitConfig(NetMsg.INPUT_BINDINGS_GET, {
			maxRequests = 8,
			timeWindow = 2,
		})
	end
end

SystemInputBind.RegisterNetWork()

return SystemInputBind
