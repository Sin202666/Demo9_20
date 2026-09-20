--[[
	Module: Recommend
	Description: 客户端 R1 推荐队列（未看优先 + 打散，L1 看完再轮）
	Author: 林奥宇
	Created: 2026-08-13
	Last Modified: 2026-08-13
]]

local Recommend = {}

--[[
	Fisher-Yates 打乱
	@param arr {any} - 数组（原地）
]]
local function shuffle(arr: { any })
	for i = #arr, 2, -1 do
		local j = math.random(1, i)
		arr[i], arr[j] = arr[j], arr[i]
	end
end

--[[
	构建播放序列：未看优先（打散），已看垫后（打散）
	@param list {any} - 片单 VideoItem[]
	@param watched {[string]: boolean} - 已看 map
	@return {any} - 序列（元素为 VideoItem）
]]
function Recommend.BuildFeed(list: { any }, watched: { [string]: boolean }): { any }
	local unseen = {}
	local seen = {}
	for _, item in ipairs(list) do
		if watched[item.id] then
			table.insert(seen, item)
		else
			table.insert(unseen, item)
		end
	end
	shuffle(unseen)
	shuffle(seen)
	local feed = {}
	for _, item in ipairs(unseen) do
		table.insert(feed, item)
	end
	for _, item in ipairs(seen) do
		table.insert(feed, item)
	end
	return feed
end

--[[
	未看耗尽后 L1：打乱全部再生成一轮（等价全量打乱）
	@param list {any} - 片单
	@return {any} - 新序列
]]
function Recommend.RebuildAfterRound(list: { any }): { any }
	local copy = table.clone(list)
	shuffle(copy)
	return copy
end

--[[
	构建 Feed，并将指定业务 id 置顶（若存在），保证预览小屏与正式 UI 首条一致
	@param list {any} - 片单
	@param watched {[string]: boolean} - 已看 map
	@param preferId string? - 优先首条业务 id
	@return {any} - 序列
]]
function Recommend.BuildFeedPreferFirst(list: { any }, watched: { [string]: boolean }, preferId: string?): { any }
	local feed = Recommend.BuildFeed(list, watched)
	if typeof(preferId) ~= "string" or preferId == "" then
		return feed
	end
	local preferIndex = nil
	for i, item in ipairs(feed) do
		if item and item.id == preferId then
			preferIndex = i
			break
		end
	end
	if not preferIndex or preferIndex == 1 then
		return feed
	end
	local preferred = table.remove(feed, preferIndex)
	table.insert(feed, 1, preferred)
	return feed
end

return Recommend
