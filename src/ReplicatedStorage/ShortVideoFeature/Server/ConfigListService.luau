--[[
	Module: ConfigListService
	Description: ConfigService 读取 ShortVideoList，热更并向客户端推送
	Author: 林奥宇
	Created: 2026-08-13
	Last Modified: 2026-08-13
]]

local ConfigService = game:GetService("ConfigService")
local Players = game:GetService("Players")

local Constants = require(script.Parent.Parent.Shared.Constants)
local Remotes = require(script.Parent.Parent.Shared.Remotes)
local SocialStore = require(script.Parent.SocialStore)

local ConfigListService = {}

local _snapshot: any = nil
local _list: { any } = {}
local _version = 0
local _idSet: { [string]: boolean } = {}

--[[
	规范化片单条目
	@param raw any - 配置项
	@return table? - VideoItem 或 nil
]]
local function normalizeItem(raw: any): any?
	if typeof(raw) ~= "table" then
		return nil
	end
	local id = raw.id
	local videoId = tonumber(raw.videoId)
	if typeof(id) ~= "string" or id == "" or not videoId then
		return nil
	end
	local title = raw.title
	if title ~= nil and typeof(title) ~= "string" then
		title = tostring(title)
	end
	return {
		id = id,
		videoId = videoId,
		title = title,
	}
end

--[[
	从 snapshot 解析列表
	@param snapshot any - ConfigSnapshot
	@return {any} - 片单
]]
local function parseList(snapshot: any): { any }
	local value = snapshot:GetValue(Constants.CONFIG_KEY)
	local arr = value
	if typeof(value) == "string" then
		local ok, decoded = pcall(function()
			return game:GetService("HttpService"):JSONDecode(value)
		end)
		if ok then
			arr = decoded
		else
			arr = nil
		end
	end
	local out = {}
	if typeof(arr) == "table" then
		for _, raw in ipairs(arr) do
			local item = normalizeItem(raw)
			if item then
				table.insert(out, item)
			end
		end
		-- 兼容字典形态
		if #out == 0 then
			for _, raw in pairs(arr) do
				local item = normalizeItem(raw)
				if item then
					table.insert(out, item)
				end
			end
		end
	end
	return out
end

--[[
	重建 id 集合
]]
local function rebuildIdSet()
	table.clear(_idSet)
	for _, item in ipairs(_list) do
		_idSet[item.id] = true
	end
end

--[[
	向单名玩家推送片单 + watched
	@param player Player - 目标玩家
]]
local function pushToPlayer(player: Player)
	local watched = {}
	local ok, plrData = pcall(function()
		return SocialStore.GetPlayer(player.UserId)
	end)
	if ok and plrData and typeof(plrData.watched) == "table" then
		watched = plrData.watched
	end
	local listUpdated = Remotes.Get("ListUpdated") :: RemoteEvent
	listUpdated:FireClient(player, {
		version = _version,
		list = _list,
		watched = watched,
	})
end

--[[
	向全体在线玩家推送
]]
local function pushToAll()
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(pushToPlayer, player)
	end
end

--[[
	刷新配置并广播
]]
local function refreshAndBroadcast()
	if not _snapshot then
		return
	end
	local ok, err = pcall(function()
		_snapshot:Refresh()
	end)
	if not ok then
		warn("[ShortVideoFeature] Config refresh failed:", err)
		return
	end
	_list = parseList(_snapshot)
	_version += 1
	rebuildIdSet()
	pushToAll()
end

--[[
	初始化 ConfigService 监听
]]
function ConfigListService.Init()
	local ok, snapshotOrErr = pcall(function()
		return ConfigService:GetConfigAsync()
	end)
	if not ok then
		warn("[ShortVideoFeature] GetConfigAsync failed:", snapshotOrErr)
		_list = {}
		_version = 1
		rebuildIdSet()
		return
	end
	_snapshot = snapshotOrErr
	_list = parseList(_snapshot)
	_version = 1
	rebuildIdSet()

	_snapshot.UpdateAvailable:Connect(function()
		refreshAndBroadcast()
	end)
end

--[[
	当前片单（只读引用，调用方勿改）
	@return {any} - 片单数组
]]
function ConfigListService.GetList(): { any }
	return _list
end

--[[
	业务 id 是否在当前片单
	@param id string - 业务 id
	@return boolean - 是否存在
]]
function ConfigListService.HasId(id: string): boolean
	return _idSet[id] == true
end

--[[
	配置版本号
	@return number - version
]]
function ConfigListService.GetVersion(): number
	return _version
end

--[[
	向指定玩家推送最新片单与 watched
	@param player Player - 玩家
]]
function ConfigListService.PushToPlayer(player: Player)
	pushToPlayer(player)
end

return ConfigListService
