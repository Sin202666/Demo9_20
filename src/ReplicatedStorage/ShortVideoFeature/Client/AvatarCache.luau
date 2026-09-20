--[[
	Module: AvatarCache
	Description: 头像 URL LRU；同 userId in-flight 合并；失败短冷却；全局限流
	Author: 林奥宇
	Created: 2026-08-13
	Last Modified: 2026-08-14
]]

local Players = game:GetService("Players")

local Constants = require(script.Parent.Parent.Shared.Constants)

local AvatarCache = {}

local FAIL_COOLDOWN_SEC = Constants.AVATAR_FAIL_COOLDOWN_SEC or 45
local API_MAX_INFLIGHT = Constants.AVATAR_API_MAX_INFLIGHT or 3
local API_MIN_GAP_SEC = Constants.AVATAR_API_MIN_GAP_SEC or 0.05

local _cache: { [number]: string } = {}
local _order: { number } = {}
local _inflight: { [number]: { (string?) -> () } } = {}
local _failUntil: { [number]: number } = {}
local _apiInflight = 0
local _apiLastAt = 0

--[[
	LRU 触碰
	@param userId number - 用户
]]
local function touch(userId: number)
	for i, id in ipairs(_order) do
		if id == userId then
			table.remove(_order, i)
			break
		end
	end
	table.insert(_order, userId)
	while #_order > Constants.AVATAR_LRU_MAX do
		local old = table.remove(_order, 1)
		if old then
			_cache[old] = nil
		end
	end
end

--[[
	占用缩略图 API 槽
]]
local function acquireApiSlot()
	while true do
		local now = os.clock()
		if _apiInflight < API_MAX_INFLIGHT and (now - _apiLastAt) >= API_MIN_GAP_SEC then
			_apiInflight += 1
			_apiLastAt = now
			return
		end
		task.wait(0.05)
	end
end

--[[
	释放缩略图 API 槽
]]
local function releaseApiSlot()
	_apiInflight = math.max(0, _apiInflight - 1)
end

--[[
	通知等待回调
	@param userId number
	@param url string?
]]
local function flushWaiters(userId: number, url: string?)
	local list = _inflight[userId]
	_inflight[userId] = nil
	if list then
		for _, fn in ipairs(list) do
			fn(url)
		end
	end
end

--[[
	异步获取头像
	@param userId number - 用户
	@param cb (url: string?) -> () - 回调
]]
function AvatarCache.GetAsync(userId: number, cb: (string?) -> ())
	if typeof(userId) ~= "number" or userId <= 0 then
		cb(nil)
		return
	end

	local hit = _cache[userId]
	if hit then
		touch(userId)
		cb(hit)
		return
	end

	local failUntil = _failUntil[userId]
	if failUntil and os.clock() < failUntil then
		cb(nil)
		return
	end

	local waiters = _inflight[userId]
	if waiters then
		table.insert(waiters, cb)
		return
	end
	_inflight[userId] = { cb }

	task.spawn(function()
		acquireApiSlot()
		local ok, content = pcall(function()
			return Players:GetUserThumbnailAsync(userId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size48x48)
		end)
		releaseApiSlot()

		local url = if ok and typeof(content) == "string" and content ~= "" then content else nil
		if url then
			_failUntil[userId] = nil
			_cache[userId] = url
			touch(userId)
		else
			-- 失败不写正缓存，但记冷却，避免 rebind/翻页反复 429
			_failUntil[userId] = os.clock() + FAIL_COOLDOWN_SEC
		end
		flushWaiters(userId, url)
	end)
end

--[[
	清空缓存（含失败冷却与进行中请求标记）
]]
function AvatarCache.Clear()
	table.clear(_cache)
	table.clear(_order)
	table.clear(_inflight)
	table.clear(_failUntil)
end

return AvatarCache
