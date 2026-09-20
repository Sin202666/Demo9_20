--[[
	Module: SocialHandlers
	Description: ShortVideo Remotes 处理（赞/评/已看/限流）；评论双 ODS 分页（hot/newest）；赞表惰性清理
	Author: 林奥宇
	Created: 2026-08-13
	Last Modified: 2026-08-14
]]

local HttpService = game:GetService("HttpService")

local Constants = require(script.Parent.Parent.Shared.Constants)
local Remotes = require(script.Parent.Parent.Shared.Remotes)
local ConfigListService = require(script.Parent.ConfigListService)
local SocialStore = require(script.Parent.SocialStore)
local TextFilter = require(script.Parent.TextFilter)

local SocialHandlers = {}

local _postCd: { [number]: number } = {}
local _likeHits: { [number]: { number } } = {}
local _fetchHits: { [number]: { number } } = {}

--[[
	滑动窗口限流
	@param bucketByUser {[number]: {number}} - 用户命中时间戳表
	@param userId number - 玩家
	@param windowSec number - 窗口秒
	@param maxHits number - 窗口内最大次数
	@return boolean - 是否通过
]]
local function allowWindow(
	bucketByUser: { [number]: { number } },
	userId: number,
	windowSec: number,
	maxHits: number
): boolean
	local now = os.clock()
	local bucket = bucketByUser[userId]
	if not bucket then
		bucket = {}
		bucketByUser[userId] = bucket
	end
	local kept = {}
	for _, t in ipairs(bucket) do
		if now - t <= windowSec then
			table.insert(kept, t)
		end
	end
	if #kept >= maxHits then
		bucketByUser[userId] = kept
		return false
	end
	table.insert(kept, now)
	bucketByUser[userId] = kept
	return true
end

--[[
	点赞滑动窗口是否允许
	@param userId number - 玩家
	@return boolean - 是否通过
]]
local function allowLike(userId: number): boolean
	return allowWindow(_likeHits, userId, Constants.LIKE_WINDOW_SEC, Constants.LIKE_WINDOW_MAX)
end

--[[
	拉评滑动窗口是否允许
	@param userId number - 玩家
	@return boolean - 是否通过
]]
local function allowFetch(userId: number): boolean
	return allowWindow(
		_fetchHits,
		userId,
		Constants.FETCH_COMMENT_WINDOW_SEC,
		Constants.FETCH_COMMENT_WINDOW_MAX
	)
end

--[[
	发评 CD
	@param userId number - 玩家
	@return boolean - 是否通过
]]
local function allowPost(userId: number): boolean
	local now = os.clock()
	local last = _postCd[userId]
	if last and now - last < Constants.POST_COMMENT_CD_SEC then
		return false
	end
	_postCd[userId] = now
	return true
end

--[[
	注册全部 Remote 回调
]]
function SocialHandlers.Init()
	local requestList = Remotes.Get("RequestList") :: RemoteEvent
	local reportWatch = Remotes.Get("ReportWatchProgress") :: RemoteEvent
	local getVideoState = Remotes.Get("GetVideoState") :: RemoteFunction
	local fetchComments = Remotes.Get("FetchComments") :: RemoteFunction
	local toggleVideoLike = Remotes.Get("ToggleVideoLike") :: RemoteFunction
	local toggleCommentLike = Remotes.Get("ToggleCommentLike") :: RemoteFunction
	local postComment = Remotes.Get("PostComment") :: RemoteFunction

	requestList.OnServerEvent:Connect(function(player: Player)
		if not player or not player:IsDescendantOf(game) then
			return
		end
		ConfigListService.PushToPlayer(player)
	end)

	reportWatch.OnServerEvent:Connect(function(player: Player, videoId: any, playedSec: any, durationSec: any, ended: any)
		if not player or typeof(videoId) ~= "string" or not ConfigListService.HasId(videoId) then
			return
		end
		local played = tonumber(playedSec) or 0
		local duration = tonumber(durationSec)
		local isEnded = ended == true
		local pass = isEnded
		if not pass then
			if duration and duration > 0 then
				pass = played >= duration * 0.5
			else
				pass = played >= Constants.WATCH_FALLBACK_SEC
			end
		end
		if not pass then
			return
		end
		SocialStore.UpdatePlayer(player.UserId, function(old)
			old.watched[videoId] = true
			return old
		end)
	end)

	getVideoState.OnServerInvoke = function(player: Player, videoId: any)
		if not player or typeof(videoId) ~= "string" or not ConfigListService.HasId(videoId) then
			return { ok = false, err = Constants.ERROR.INVALID }
		end
		local stats = SocialStore.GetStats(videoId)
		local plr = SocialStore.GetPlayer(player.UserId)
		return {
			ok = true,
			likeCount = stats.likeCount,
			commentCount = stats.commentCount,
			liked = plr.videos[videoId] == true,
			watched = plr.watched[videoId] == true,
		}
	end

	fetchComments.OnServerInvoke = function(player: Player, videoId: any, cursor: any, pageSize: any, sortMode: any)
		if not player or typeof(videoId) ~= "string" or not ConfigListService.HasId(videoId) then
			return { ok = false, err = Constants.ERROR.INVALID }
		end
		if not allowFetch(player.UserId) then
			return { ok = false, err = Constants.ERROR.RATE_LIMIT }
		end
		local size = math.clamp(tonumber(pageSize) or Constants.COMMENT_PAGE_SIZE, 1, Constants.COMMENT_PAGE_SIZE)
		local mode = SocialStore.NormalizeSortMode(sortMode)
		local ok, page, nextCursor = SocialStore.FetchCommentsPage(videoId, cursor, size, mode)
		if not ok then
			return { ok = false, err = Constants.ERROR.BUSY }
		end
		local plr = SocialStore.GetPlayer(player.UserId)
		local likedMap = {}
		for _, c in ipairs(page) do
			if c and c.cid and plr.comments[c.cid] then
				likedMap[c.cid] = true
			end
		end
		return {
			ok = true,
			comments = page,
			nextCursor = nextCursor,
			likedMap = likedMap,
			sortMode = mode,
		}
	end

	toggleVideoLike.OnServerInvoke = function(player: Player, videoId: any)
		if not player or typeof(videoId) ~= "string" or not ConfigListService.HasId(videoId) then
			return { ok = false, err = Constants.ERROR.INVALID }
		end
		if not allowLike(player.UserId) then
			return { ok = false, err = Constants.ERROR.RATE_LIMIT }
		end
		-- 与评论赞对齐：先改权威计数，再写玩家态；失败回滚计数
		local plr = SocialStore.GetPlayer(player.UserId)
		local currentlyLiked = plr.videos[videoId] == true
		local liked = not currentlyLiked
		local delta = if liked then 1 else -1
		local okStats, stats = SocialStore.UpdateStats(videoId, function(old)
			old.likeCount = math.max(0, (tonumber(old.likeCount) or 0) + delta)
			return old
		end)
		if not okStats then
			return { ok = false, err = Constants.ERROR.BUSY }
		end
		local okPlr = SocialStore.UpdatePlayer(player.UserId, function(old)
			if liked then
				old.videos[videoId] = true
			else
				old.videos[videoId] = nil
			end
			return old
		end)
		if not okPlr then
			SocialStore.UpdateStats(videoId, function(old)
				old.likeCount = math.max(0, (tonumber(old.likeCount) or 0) - delta)
				return old
			end)
			return { ok = false, err = Constants.ERROR.BUSY }
		end
		return {
			ok = true,
			liked = liked,
			likeCount = stats and stats.likeCount or 0,
		}
	end

	toggleCommentLike.OnServerInvoke = function(player: Player, videoId: any, cid: any)
		if not player or typeof(videoId) ~= "string" or typeof(cid) ~= "string" or not ConfigListService.HasId(videoId) then
			return { ok = false, err = Constants.ERROR.INVALID }
		end
		if not allowLike(player.UserId) then
			return { ok = false, err = Constants.ERROR.RATE_LIMIT }
		end
		-- 先校验归属，再改计数，最后写玩家态（失败则回滚计数）
		local body = SocialStore.GetCommentBody(cid)
		if not body or not SocialStore.BelongsToVideo(body, videoId) then
			-- 生命周期硬删后：惰性摘除玩家赞表孤儿 key
			local plrMiss = SocialStore.GetPlayer(player.UserId)
			if plrMiss.comments[cid] == true then
				SocialStore.UpdatePlayer(player.UserId, function(old)
					old.comments[cid] = nil
					return old
				end)
			end
			return { ok = false, err = Constants.ERROR.NOT_FOUND }
		end
		local plr = SocialStore.GetPlayer(player.UserId)
		local currentlyLiked = plr.comments[cid] == true
		local liked = not currentlyLiked
		local delta = if liked then 1 else -1
		local okCmt, newCount = SocialStore.AdjustCommentLike(videoId, cid, delta)
		if not okCmt or newCount == nil then
			return { ok = false, err = Constants.ERROR.NOT_FOUND }
		end
		local okPlr = SocialStore.UpdatePlayer(player.UserId, function(old)
			if liked then
				old.comments[cid] = true
			else
				old.comments[cid] = nil
			end
			return old
		end)
		if not okPlr then
			SocialStore.AdjustCommentLike(videoId, cid, -delta)
			return { ok = false, err = Constants.ERROR.BUSY }
		end
		return { ok = true, liked = liked, likeCount = newCount }
	end

	postComment.OnServerInvoke = function(player: Player, videoId: any, text: any)
		if not player or typeof(videoId) ~= "string" or typeof(text) ~= "string" or not ConfigListService.HasId(videoId) then
			return { ok = false, err = Constants.ERROR.INVALID }
		end
		local trimmed = string.gsub(text, "^%s+", "")
		trimmed = string.gsub(trimmed, "%s+$", "")
		if trimmed == "" then
			return { ok = false, err = Constants.ERROR.INVALID }
		end
		-- 按 UTF-8 字节长度限制（与 COMMENT_MAX_LEN 一致）
		if #trimmed > Constants.COMMENT_MAX_LEN then
			return { ok = false, err = Constants.ERROR.TOO_LONG }
		end
		if not allowPost(player.UserId) then
			return { ok = false, err = Constants.ERROR.RATE_LIMIT }
		end
		local filtered = TextFilter.FilterForBroadcast(trimmed, player.UserId)
		-- 过滤失败或整段屏蔽：不入库
		if not filtered or SocialStore.IsBlockedText(filtered) then
			return { ok = false, err = Constants.ERROR.FILTER_FAIL }
		end
		local comment = {
			cid = string.format("%d_%d_%s", player.UserId, os.time(), string.sub(HttpService:GenerateGUID(false), 1, 8)),
			userId = player.UserId,
			name = player.DisplayName,
			text = filtered,
			likeCount = 0,
			createdAt = os.time(),
			videoId = videoId,
		}
		if #comment.cid > 50 then
			comment.cid = string.sub(comment.cid, 1, 50)
		end
		local okAdd, commentCount = SocialStore.AddComment(videoId, comment)
		if not okAdd then
			return { ok = false, err = Constants.ERROR.BUSY }
		end
		return {
			ok = true,
			comment = {
				cid = comment.cid,
				userId = comment.userId,
				name = comment.name,
				text = comment.text,
				likeCount = comment.likeCount,
				createdAt = comment.createdAt,
			},
			commentCount = commentCount,
		}
	end
end

return SocialHandlers
