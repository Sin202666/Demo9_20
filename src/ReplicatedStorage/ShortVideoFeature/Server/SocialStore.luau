--[[
	Module: SocialStore
	Description: ShortVideo 社交存储：Stats / Player；评论 Body+双 ODS；生命周期懒清理；归属校验；写失败回滚
	Author: 林奥宇
	Created: 2026-08-13
	Last Modified: 2026-08-14

	评论：
	- Body：ShortVideoCommentBody，key=cid
	- 赞序：OrderedDataStore ShortVideoCommentRank，scope=videoId，score=like*1e9+time%1e9
	- 时间序：OrderedDataStore ShortVideoCommentTime，scope=videoId，score=createdAt
	- 旧 ShortVideoComments[videoId]=数组 首次访问懒迁移；时间索引后台限速懒补
	- 发评：Body+赞序必须成功；时间索引失败异步重试不拖垮发评
	- Rank 写失败回滚 Body；Stats 失败回滚发评；错挂 ODS 只摘索引不删 Body
	- 生命周期：近 N 天 ∪ 神评保护；Soft/HardCap；见 KickLifecycleIfNeeded / RunLifecyclePass
]]

local DataStoreService = game:GetService("DataStoreService")

local Constants = require(script.Parent.Parent.Shared.Constants)

local SocialStore = {}

local statsStore = DataStoreService:GetDataStore(Constants.DATASTORE.Stats)
local legacyCommentsStore = DataStoreService:GetDataStore(Constants.DATASTORE.Comments)
local bodyStore = DataStoreService:GetDataStore(Constants.DATASTORE.CommentBody)
local playerStore = DataStoreService:GetDataStore(Constants.DATASTORE.Player)
local rankStoreName = Constants.DATASTORE.CommentRank
local timeStoreName = Constants.DATASTORE.CommentTime

local DEFAULT_STATS = { likeCount = 0, commentCount = 0 }
local DEFAULT_PLAYER = { videos = {}, comments = {}, watched = {} }

local SCORE_MUL = Constants.COMMENT_SCORE_LIKE_MUL
local BODY_TTL = Constants.COMMENT_BODY_CACHE_TTL_SEC
local BODY_MISS_TTL = Constants.COMMENT_BODY_MISS_TTL_SEC or 15
local PLAYER_TTL = Constants.PLAYER_CACHE_TTL_SEC or 5
local STATS_TTL = Constants.STATS_CACHE_TTL_SEC or 3
local TIME_BACKFILL_PAGE = math.max(1, math.floor(tonumber(Constants.COMMENT_TIME_BACKFILL_PAGE) or 50))
local TIME_BACKFILL_WAIT = math.max(0, tonumber(Constants.COMMENT_TIME_BACKFILL_WAIT_SEC) or 0.12)
local SORT_HOT = Constants.COMMENT_SORT.Hot
local SORT_NEWEST = Constants.COMMENT_SORT.Newest

local _bodyCache: { [string]: { at: number, data: any } } = {}
local _playerCache: { [number]: { at: number, data: any } } = {}
local _statsCache: { [string]: { at: number, data: any } } = {}
local _migrating: { [string]: boolean } = {}
local _migrated: { [string]: boolean } = {}
local _rankStores: { [string]: OrderedDataStore } = {}
local _timeStores: { [string]: OrderedDataStore } = {}
local _timeMigrating: { [string]: boolean } = {}
local _timeMigrated: { [string]: boolean } = {}
local _lifecycleRunning: { [string]: boolean } = {}
local _lifecycleCoolUntil: { [string]: number } = {}

--[[
	深拷贝简易表
	@param t table - 源表
	@return table - 副本
]]
local function shallowCopy(t: { [any]: any }): { [any]: any }
	local out = {}
	for k, v in pairs(t) do
		if typeof(v) == "table" then
			local inner = {}
			for ik, iv in pairs(v) do
				inner[ik] = iv
			end
			out[k] = inner
		else
			out[k] = v
		end
	end
	return out
end

--[[
	赞序分数
	@param likeCount number - 点赞数
	@param createdAt number - 创建戳
	@return number - ODS 整数分
]]
function SocialStore.EncodeScore(likeCount: number, createdAt: number): number
	local likes = math.max(0, math.floor(tonumber(likeCount) or 0))
	local t = math.max(0, math.floor(tonumber(createdAt) or 0))
	return likes * SCORE_MUL + (t % SCORE_MUL)
end

--[[
	时间序分数（unix 秒；同分靠游标 cid 续页）
	@param createdAt number - 时间戳
	@return number - ODS 整数分
]]
function SocialStore.EncodeTimeScore(createdAt: number): number
	return math.max(0, math.floor(tonumber(createdAt) or 0))
end

--[[
	规范化排序模式
	@param sortMode any - 客户端传入
	@return string - COMMENT_SORT.Hot | Newest
]]
function SocialStore.NormalizeSortMode(sortMode: any): string
	if sortMode == SORT_NEWEST or sortMode == "newest" then
		return SORT_NEWEST
	end
	return SORT_HOT
end

--[[
	是否整段被屏蔽（空或几乎全是 #/* 等）
	@param text any - 正文
	@return boolean - 是否应删除/拒收
]]
function SocialStore.IsBlockedText(text: any): boolean
	if typeof(text) ~= "string" then
		return true
	end
	local trimmed = string.gsub(text, "^%s+", "")
	trimmed = string.gsub(trimmed, "%s+$", "")
	if trimmed == "" then
		return true
	end
	local stripped = string.gsub(trimmed, "[#＊*·•]+", "")
	stripped = string.gsub(stripped, "%s+", "")
	return stripped == ""
end

--[[
	取某视频赞序 ODS
	@param videoId string - 业务 id
	@return OrderedDataStore
]]
local function getRankStore(videoId: string): OrderedDataStore
	local cached = _rankStores[videoId]
	if cached then
		return cached
	end
	local store = DataStoreService:GetOrderedDataStore(rankStoreName, videoId)
	_rankStores[videoId] = store
	return store
end

--[[
	取某视频时间序 ODS
	@param videoId string - 业务 id
	@return OrderedDataStore
]]
local function getTimeStore(videoId: string): OrderedDataStore
	local cached = _timeStores[videoId]
	if cached then
		return cached
	end
	local store = DataStoreService:GetOrderedDataStore(timeStoreName, videoId)
	_timeStores[videoId] = store
	return store
end

--[[
	写入时间索引（失败返回 false）
	@param videoId string - 视频 id
	@param cid string - 评论 id
	@param createdAt number - 时间戳
	@return boolean - 是否成功
]]
local function writeTimeIndex(videoId: string, cid: string, createdAt: number): boolean
	local score = SocialStore.EncodeTimeScore(createdAt)
	local ok = pcall(function()
		getTimeStore(videoId):SetAsync(cid, score)
	end)
	return ok
end

--[[
	时间索引失败时异步重试（不阻塞发评）
	@param videoId string - 视频 id
	@param cid string - 评论 id
	@param createdAt number - 时间戳
]]
local function retryWriteTimeIndex(videoId: string, cid: string, createdAt: number)
	task.spawn(function()
		for attempt = 1, 3 do
			task.wait(0.4 * attempt)
			if writeTimeIndex(videoId, cid, createdAt) then
				return
			end
		end
		warn("[ShortVideoFeature] time index write failed after retries:", videoId, cid)
	end)
end

--[[
	规范化评论体
	@param raw any - 原始
	@param videoId string - 视频 id
	@return any? - CommentItem 或 nil
]]
local function normalizeComment(raw: any, videoId: string): any?
	if typeof(raw) ~= "table" or typeof(raw.cid) ~= "string" or raw.cid == "" then
		return nil
	end
	if #raw.cid > 50 then
		return nil
	end
	local text = raw.text
	if SocialStore.IsBlockedText(text) then
		return nil
	end
	return {
		cid = raw.cid,
		videoId = videoId,
		userId = tonumber(raw.userId) or 0,
		name = if typeof(raw.name) == "string" then raw.name else "",
		text = text,
		likeCount = math.max(0, tonumber(raw.likeCount) or 0),
		createdAt = tonumber(raw.createdAt) or 0,
	}
end

--[[
	仅从某视频索引移除（保留 Body；用于错挂清理；赞序+时间序）
	@param videoId string - 视频 id
	@param cid string - 评论 id
]]
function SocialStore.RemoveRankEntry(videoId: string, cid: string)
	pcall(function()
		getRankStore(videoId):RemoveAsync(cid)
	end)
	pcall(function()
		getTimeStore(videoId):RemoveAsync(cid)
	end)
end

--[[
	写入 Body + 赞序 ODS；赞序失败则回滚 Body；时间索引失败异步重试
	@param videoId string - 视频 id
	@param comment any - 评论
	@return boolean - 是否成功（以 Body+赞序为准）
]]
local function writeCommentIndex(videoId: string, comment: any): boolean
	local score = SocialStore.EncodeScore(comment.likeCount, comment.createdAt)
	local okBody = pcall(function()
		bodyStore:SetAsync(comment.cid, comment)
	end)
	if not okBody then
		return false
	end
	_bodyCache[comment.cid] = { at = os.clock(), data = comment }
	local okRank = pcall(function()
		getRankStore(videoId):SetAsync(comment.cid, score)
	end)
	if not okRank then
		-- Body 已落库但索引失败：补偿删除 Body，避免「发评失败却有幽灵」
		pcall(function()
			bodyStore:RemoveAsync(comment.cid)
		end)
		_bodyCache[comment.cid] = nil
		return false
	end
	if not writeTimeIndex(videoId, comment.cid, comment.createdAt) then
		retryWriteTimeIndex(videoId, comment.cid, comment.createdAt)
	end
	return true
end

--[[
	删除一条评论（Body + 双 ODS），并可选扣计数
	@param videoId string - 视频 id
	@param cid string - 评论 id
	@param decCount boolean - 是否减少 commentCount
]]
function SocialStore.DeleteComment(videoId: string, cid: string, decCount: boolean)
	pcall(function()
		bodyStore:RemoveAsync(cid)
	end)
	_bodyCache[cid] = nil
	pcall(function()
		getRankStore(videoId):RemoveAsync(cid)
	end)
	pcall(function()
		getTimeStore(videoId):RemoveAsync(cid)
	end)
	if decCount then
		SocialStore.UpdateStats(videoId, function(old)
			old.commentCount = math.max(0, (tonumber(old.commentCount) or 0) - 1)
			return old
		end)
	end
end

--[[
	评论是否归属该视频（无 videoId 的旧数据视为可归属，由写路径回填）
	@param raw any - Body
	@param videoId string - 期望视频 id
	@return boolean - 是否可视为本视频评论
]]
function SocialStore.BelongsToVideo(raw: any, videoId: string): boolean
	if typeof(raw) ~= "table" then
		return false
	end
	local owned = raw.videoId
	if typeof(owned) ~= "string" or owned == "" then
		return true
	end
	return owned == videoId
end

--[[
	读 Body（带短缓存；miss/失败也短缓存，避免 ODS 脏 key 反复 GetAsync）
	@param cid string - 评论 id
	@return any? - 评论或 nil
]]
function SocialStore.GetCommentBody(cid: string): any?
	local cached = _bodyCache[cid]
	if cached then
		local ttl = if cached.data == false then BODY_MISS_TTL else BODY_TTL
		if os.clock() - cached.at <= ttl then
			if cached.data == false then
				return nil
			end
			return cached.data
		end
	end
	local ok, data = pcall(function()
		return bodyStore:GetAsync(cid)
	end)
	if ok and typeof(data) == "table" then
		_bodyCache[cid] = { at = os.clock(), data = data }
		return data
	end
	_bodyCache[cid] = { at = os.clock(), data = false }
	return nil
end

--[[
	读取视频统计（短缓存，降低切集 GetVideoState 打 DS）
	@param videoId string - 业务 id
	@return table - { likeCount, commentCount }
]]
function SocialStore.GetStats(videoId: string): { likeCount: number, commentCount: number }
	local cached = _statsCache[videoId]
	if cached and os.clock() - cached.at <= STATS_TTL then
		return cached.data
	end
	local ok, data = pcall(function()
		return statsStore:GetAsync(videoId)
	end)
	local result
	if ok and typeof(data) == "table" then
		result = {
			likeCount = tonumber(data.likeCount) or 0,
			commentCount = tonumber(data.commentCount) or 0,
		}
	else
		result = shallowCopy(DEFAULT_STATS) :: any
	end
	_statsCache[videoId] = { at = os.clock(), data = result }
	return result
end

--[[
	UpdateAsync 修改统计
	@param videoId string - 业务 id
	@param mutator (old) -> new - 变更函数
	@return boolean - 是否成功
	@return table? - 新统计
]]
function SocialStore.UpdateStats(videoId: string, mutator: (any) -> any): (boolean, any?)
	_statsCache[videoId] = nil
	local ok, result = pcall(function()
		return statsStore:UpdateAsync(videoId, function(old)
			local base = if typeof(old) == "table" then old else shallowCopy(DEFAULT_STATS)
			return mutator(base)
		end)
	end)
	if ok and typeof(result) == "table" then
		_statsCache[videoId] = {
			at = os.clock(),
			data = {
				likeCount = tonumber(result.likeCount) or 0,
				commentCount = tonumber(result.commentCount) or 0,
			},
		}
	end
	return ok, result
end

--[[
	批量读 Body（有限并行，批大小 COMMENT_BODY_FETCH_BATCH）
	@param cids {string} - id 列表
	@return {[string]: any} - cid -> body
]]
function SocialStore.GetCommentBodies(cids: { string }): { [string]: any }
	local out: { [string]: any } = {}
	if #cids == 0 then
		return out
	end
	local batchSize = math.max(1, math.floor(tonumber(Constants.COMMENT_BODY_FETCH_BATCH) or 10))
	local i = 1
	while i <= #cids do
		local batchEnd = math.min(i + batchSize - 1, #cids)
		local pending = batchEnd - i + 1
		for j = i, batchEnd do
			local cid = cids[j]
			task.spawn(function()
				local ok, body = pcall(function()
					return SocialStore.GetCommentBody(cid)
				end)
				if ok and body then
					out[cid] = body
				end
				pending -= 1
			end)
		end
		while pending > 0 do
			task.wait()
		end
		i = batchEnd + 1
	end
	return out
end

--[[
	旧数组是否已迁移
	@param videoId string - 视频 id
	@return boolean
]]
local function isMigratedFlag(data: any): boolean
	return typeof(data) == "table" and data.migrated == true
end

--[[
	执行旧数组 → Body+ODS（同步，调用方应串行）
	@param videoId string - 视频 id
]]
local function migrateLegacy(videoId: string)
	local force = Constants.DEBUG_COMMENT_ALWAYS_MIGRATE == true
	local ok, data = pcall(function()
		return legacyCommentsStore:GetAsync(videoId)
	end)
	if not ok then
		return
	end
	if isMigratedFlag(data) then
		if force then
			warn("[ShortVideoFeature] DEBUG remigrate skip: legacy key already marked migrated, array gone:", videoId)
		end
		_migrated[videoId] = true
		return
	end
	local migratedCount = 0
	if typeof(data) == "table" then
		-- 数组形态：ipairs；若是字典且无 migrated，尝试当作列表
		local list = data
		if data[1] == nil and data.cid == nil then
			list = {}
			for _, v in pairs(data) do
				if typeof(v) == "table" and v.cid then
					table.insert(list, v)
				end
			end
		end
		for _, raw in ipairs(list) do
			local comment = normalizeComment(raw, videoId)
			if comment then
				if writeCommentIndex(videoId, comment) then
					migratedCount += 1
				end
			end
			-- 每条两次 DataStore 写已会 yield；不再额外 task.wait，避免 80+ 条迁十几秒
		end
	end
	-- 调试强制重迁：保留旧数组 key，方便下次再迁
	if not force then
		pcall(function()
			legacyCommentsStore:SetAsync(videoId, {
				migrated = true,
				timeMigrated = true,
				at = os.time(),
				count = migratedCount,
			})
		end)
		_timeMigrated[videoId] = true
	else
		warn("[ShortVideoFeature] DEBUG remigrate done:", videoId, "count=", migratedCount)
	end
	if migratedCount > 0 then
		SocialStore.UpdateStats(videoId, function(old)
			-- 以迁入数为准校正（避免旧 count 虚高）
			local prev = tonumber(old.commentCount) or 0
			if prev < migratedCount then
				old.commentCount = migratedCount
			end
			return old
		end)
	end
	if not force then
		_migrated[videoId] = true
	end
end

--[[
	后台触发旧数组迁移（不阻塞调用方；读/写热路径用此）
	@param videoId string - 视频 id
]]
function SocialStore.KickMigrateIfNeeded(videoId: string)
	local force = Constants.DEBUG_COMMENT_ALWAYS_MIGRATE == true
	if not force and _migrated[videoId] then
		return
	end
	if _migrating[videoId] then
		return
	end
	_migrating[videoId] = true
	task.spawn(function()
		local ok, err = pcall(migrateLegacy, videoId)
		_migrating[videoId] = false
		if not ok then
			warn("[ShortVideoFeature] migrateLegacy failed:", videoId, err)
		end
	end)
end

--[[
	迁移入口：默认非阻塞 Kick；DEBUG_COMMENT_ALWAYS_MIGRATE 时同步重迁
	@param videoId string - 视频 id
]]
function SocialStore.EnsureMigrated(videoId: string)
	local force = Constants.DEBUG_COMMENT_ALWAYS_MIGRATE == true
	if not force then
		SocialStore.KickMigrateIfNeeded(videoId)
		return
	end
	if _migrating[videoId] then
		local spin = 0
		while _migrating[videoId] do
			task.wait(0.05)
			spin += 1
			if spin > 600 then
				warn("[ShortVideoFeature] EnsureMigrated wait timeout:", videoId)
				return
			end
		end
	end
	_migrating[videoId] = true
	local ok, err = pcall(migrateLegacy, videoId)
	_migrating[videoId] = false
	if not ok then
		warn("[ShortVideoFeature] migrateLegacy failed:", videoId, err)
	end
end

--[[
	标记时间索引已补齐（写 legacy meta）
	@param videoId string - 视频 id
	@param count number - 写入条数
]]
local function markTimeMigrated(videoId: string, count: number)
	_timeMigrated[videoId] = true
	pcall(function()
		legacyCommentsStore:UpdateAsync(videoId, function(old)
			local base = if typeof(old) == "table" then old else { migrated = true }
			base.timeMigrated = true
			base.timeMigratedAt = os.time()
			base.timeMigratedCount = count
			return base
		end)
	end)
end

--[[
	从赞序 ODS 限速补时间索引（后台；不阻塞 Fetch）
	@param videoId string - 视频 id
]]
local function migrateTimeIndex(videoId: string)
	local okMeta, meta = pcall(function()
		return legacyCommentsStore:GetAsync(videoId)
	end)
	if okMeta and typeof(meta) == "table" and meta.timeMigrated == true then
		_timeMigrated[videoId] = true
		return
	end

	local rank = getRankStore(videoId)
	local okPages, pages = pcall(function()
		return rank:GetSortedAsync(false, TIME_BACKFILL_PAGE)
	end)
	if not okPages or not pages then
		-- 无赞序或读失败：视为无需补（空视频）
		markTimeMigrated(videoId, 0)
		return
	end

	local written = 0
	while true do
		local entries = pages:GetCurrentPage()
		if #entries == 0 then
			break
		end
		local cids: { string } = {}
		for _, entry in ipairs(entries) do
			if typeof(entry.key) == "string" then
				table.insert(cids, entry.key)
			end
		end
		local bodies = SocialStore.GetCommentBodies(cids)
		for _, cid in ipairs(cids) do
			local raw = bodies[cid]
			if raw and SocialStore.BelongsToVideo(raw, videoId) then
				local comment = normalizeComment(raw, videoId)
				if comment then
					if writeTimeIndex(videoId, cid, comment.createdAt) then
						written += 1
					end
				end
			end
		end
		if TIME_BACKFILL_WAIT > 0 then
			task.wait(TIME_BACKFILL_WAIT)
		end
		if pages.IsFinished then
			break
		end
		local okAdv = pcall(function()
			pages:AdvanceToNextPageAsync()
		end)
		if not okAdv then
			break
		end
	end
	markTimeMigrated(videoId, written)
end

--[[
	后台触发时间索引懒补（Newest 路径调用；不阻塞首屏）
	@param videoId string - 视频 id
]]
function SocialStore.KickTimeMigrateIfNeeded(videoId: string)
	if _timeMigrated[videoId] or _timeMigrating[videoId] then
		return
	end
	_timeMigrating[videoId] = true
	task.spawn(function()
		local ok, err = pcall(migrateTimeIndex, videoId)
		_timeMigrating[videoId] = false
		if not ok then
			warn("[ShortVideoFeature] migrateTimeIndex failed:", videoId, err)
		end
	end)
end

--[[
	读取评论生命周期配置
	@return table? - COMMENT_LIFECYCLE；未配置返回 nil
]]
local function getLifecycleCfg(): any?
	local cfg = Constants.COMMENT_LIFECYCLE
	if typeof(cfg) ~= "table" then
		return nil
	end
	return cfg
end

--[[
	等待同视频生命周期任务结束（HardCap 同步腾槽前）
	@param videoId string - 视频 id
]]
local function waitLifecycleIdle(videoId: string)
	local spin = 0
	while _lifecycleRunning[videoId] do
		task.wait(0.05)
		spin += 1
		if spin > 200 then
			warn("[ShortVideoFeature] lifecycle wait timeout:", videoId)
			return
		end
	end
end

--[[
	构建神评保护集（TopK ∧ likeCount≥T）
	@param videoId string - 视频 id
	@param topK number - 赞序取前 K
	@param minLikes number - 最低赞
	@return boolean - Rank/读页是否成功（失败则禁止压力删）
	@return {[string]: boolean} - cid 保护集
]]
local function buildProtectSet(videoId: string, topK: number, minLikes: number): (boolean, { [string]: boolean })
	local set: { [string]: boolean } = {}
	local k = math.max(1, math.floor(topK))
	local okPages, pages = pcall(function()
		return getRankStore(videoId):GetSortedAsync(false, k)
	end)
	if not okPages or not pages then
		return false, set
	end
	local cids: { string } = {}
	for _, entry in ipairs(pages:GetCurrentPage()) do
		if typeof(entry.key) == "string" then
			table.insert(cids, entry.key)
		end
	end
	local bodies = SocialStore.GetCommentBodies(cids)
	for _, cid in ipairs(cids) do
		local raw = bodies[cid]
		if raw and SocialStore.BelongsToVideo(raw, videoId) then
			local likes = math.max(0, tonumber(raw.likeCount) or 0)
			if likes >= minLikes then
				set[cid] = true
			end
		end
	end
	return true, set
end

--[[
	判定并删除一条生命周期候选
	@param videoId string
	@param cid string
	@param body any? - Body；nil 视为脏索引可清
	@param protectOk boolean - 保护集是否可信
	@param protectSet {[string]: boolean}
	@param pressure boolean - Soft/Hard 压力模式
	@param aliveCount number - 存活估计
	@param targetAlive number - 目标水位
	@param now number - os.time
	@param retainSec number - 保留秒
	@return boolean - 是否删除
	@return number - 新 aliveCount
]]
local function tryLifecycleDelete(
	videoId: string,
	cid: string,
	body: any?,
	protectOk: boolean,
	protectSet: { [string]: boolean },
	pressure: boolean,
	aliveCount: number,
	targetAlive: number,
	now: number,
	retainSec: number
): (boolean, number)
	if protectOk and protectSet[cid] then
		return false, aliveCount
	end
	if not body then
		SocialStore.DeleteComment(videoId, cid, true)
		return true, math.max(0, aliveCount - 1)
	end
	if not SocialStore.BelongsToVideo(body, videoId) then
		SocialStore.RemoveRankEntry(videoId, cid)
		return false, aliveCount
	end
	local createdAt = tonumber(body.createdAt) or 0
	local expired = (now - createdAt) >= retainSec
	-- 保护集失败：禁止未过期压力删，避免误伤神评
	local canPressure = protectOk and pressure and aliveCount > targetAlive
	if expired or canPressure then
		SocialStore.DeleteComment(videoId, cid, true)
		return true, math.max(0, aliveCount - 1)
	end
	return false, aliveCount
end

--[[
	沿 ODS 页扫描并删除（受预算约束）
	@param videoId string
	@param pages DataStorePages
	@param protectOk boolean
	@param protectSet {[string]: boolean}
	@param pressure boolean
	@param aliveCount number
	@param targetAlive number
	@param now number
	@param retainSec number
	@param budget number - 剩余可删条数（会被消耗）
	@param stopAtTarget boolean - 压力模式：达目标水位即停；纯过期清扫为 false
	@return number - 新 aliveCount
	@return number - 剩余 budget
	@return boolean - 是否应停止整轮
]]
local function scanPagesForLifecycle(
	videoId: string,
	pages: any,
	protectOk: boolean,
	protectSet: { [string]: boolean },
	pressure: boolean,
	aliveCount: number,
	targetAlive: number,
	now: number,
	retainSec: number,
	budget: number,
	stopAtTarget: boolean
): (number, number, boolean)
	while budget > 0 do
		if stopAtTarget and aliveCount <= targetAlive then
			return aliveCount, budget, true
		end
		local entries = pages:GetCurrentPage()
		if #entries == 0 then
			break
		end
		local cids: { string } = {}
		for _, entry in ipairs(entries) do
			if typeof(entry.key) == "string" then
				table.insert(cids, entry.key)
			end
		end
		local bodies = SocialStore.GetCommentBodies(cids)
		for _, cid in ipairs(cids) do
			if budget <= 0 then
				return aliveCount, budget, true
			end
			if stopAtTarget and aliveCount <= targetAlive then
				return aliveCount, budget, true
			end
			local deleted
			deleted, aliveCount = tryLifecycleDelete(
				videoId,
				cid,
				bodies[cid],
				protectOk,
				protectSet,
				pressure,
				aliveCount,
				targetAlive,
				now,
				retainSec
			)
			if deleted then
				budget -= 1
			end
		end
		if pages.IsFinished then
			break
		end
		local okAdv = pcall(function()
			pages:AdvanceToNextPageAsync()
		end)
		if not okAdv then
			break
		end
	end
	local stop = budget <= 0 or (stopAtTarget and aliveCount <= targetAlive)
	return aliveCount, budget, stop
end

--[[
	执行一轮评论生命周期清理
	@param videoId string - 视频 id
	@param opts { forceHard: boolean?, sync: boolean? }? - forceHard=压到 HardCap-1；sync 用同步预算
	@return number - 本轮删除条数（估计）
]]
function SocialStore.RunLifecyclePass(videoId: string, opts: any?): number
	local cfg = getLifecycleCfg()
	if not cfg or cfg.Enabled ~= true then
		return 0
	end
	local forceHard = typeof(opts) == "table" and opts.forceHard == true
	local sync = typeof(opts) == "table" and opts.sync == true
	local softCap = math.max(1, math.floor(tonumber(cfg.SoftCap) or 1500))
	local hardCap = math.max(softCap, math.floor(tonumber(cfg.HardCap) or 3000))
	local retainDays = math.max(1, math.floor(tonumber(cfg.RetainDays) or 30))
	local retainSec = retainDays * 86400
	local topK = math.max(1, math.floor(tonumber(cfg.ProtectTopK) or 80))
	local minLikes = math.max(0, math.floor(tonumber(cfg.ProtectMinLikes) or 5))
	local pageSize = math.max(1, math.floor(tonumber(cfg.ScanPageSize) or 50))
	local budget = if sync
		then math.max(1, math.floor(tonumber(cfg.MaxDeleteSync) or 8))
		else math.max(1, math.floor(tonumber(cfg.MaxDeleteAsync) or 40))

	local stats = SocialStore.GetStats(videoId)
	local aliveCount = math.max(0, tonumber(stats.commentCount) or 0)
	local targetAlive = if forceHard or aliveCount >= hardCap then hardCap - 1 else softCap - 1
	targetAlive = math.max(0, targetAlive)

	-- 无压力且可能无需过期清理时：轻量探测
	local pressure = forceHard or aliveCount > targetAlive
	if not pressure and aliveCount < softCap then
		SocialStore.KickTimeMigrateIfNeeded(videoId)
		local okProbe, probePages = pcall(function()
			return getTimeStore(videoId):GetSortedAsync(true, math.min(pageSize, 10))
		end)
		if not okProbe or not probePages then
			return 0
		end
		local probeEntries = probePages:GetCurrentPage()
		if #probeEntries == 0 then
			return 0
		end
		local probeCids = {}
		for _, entry in ipairs(probeEntries) do
			if typeof(entry.key) == "string" then
				table.insert(probeCids, entry.key)
			end
		end
		local probeBodies = SocialStore.GetCommentBodies(probeCids)
		local now0 = os.time()
		local anyExpired = false
		for _, cid in ipairs(probeCids) do
			local b = probeBodies[cid]
			if not b then
				anyExpired = true
				break
			end
			if SocialStore.BelongsToVideo(b, videoId) then
				local createdAt = tonumber(b.createdAt) or 0
				if (now0 - createdAt) >= retainSec then
					anyExpired = true
					break
				end
			end
		end
		if not anyExpired then
			return 0
		end
		pressure = false
	end

	local deletedStart = aliveCount
	local protectOk, protectSet = buildProtectSet(videoId, topK, minLikes)
	local now = os.time()
	local stopAtTarget = pressure

	SocialStore.KickTimeMigrateIfNeeded(videoId)

	local okTime, timePages = pcall(function()
		return getTimeStore(videoId):GetSortedAsync(true, pageSize)
	end)
	local usedTime = false
	if okTime and timePages then
		local entries = timePages:GetCurrentPage()
		if #entries > 0 then
			usedTime = true
			local stop
			aliveCount, budget, stop = scanPagesForLifecycle(
				videoId,
				timePages,
				protectOk,
				protectSet,
				pressure and protectOk,
				aliveCount,
				targetAlive,
				now,
				retainSec,
				budget,
				stopAtTarget
			)
			if stop or budget <= 0 or (stopAtTarget and aliveCount <= targetAlive) then
				return math.max(0, deletedStart - SocialStore.GetStats(videoId).commentCount)
			end
		end
	end

	-- HardCap：时间索引空时回退赞序冷端 + Body.createdAt
	if (forceHard or aliveCount >= hardCap) and budget > 0 and aliveCount > targetAlive then
		if not usedTime then
			local okRank, rankPages = pcall(function()
				return getRankStore(videoId):GetSortedAsync(true, pageSize)
			end)
			if okRank and rankPages then
				aliveCount, budget, _ = scanPagesForLifecycle(
					videoId,
					rankPages,
					protectOk,
					protectSet,
					pressure and protectOk,
					aliveCount,
					targetAlive,
					now,
					retainSec,
					budget,
					true
				)
			end
		end
	end

	return math.max(0, deletedStart - SocialStore.GetStats(videoId).commentCount)
end

--[[
	异步触发生命周期（受 Enabled / 冷却 / running 约束）
	@param videoId string - 视频 id
	@param _reason string? - 调用来源（调试）
]]
function SocialStore.KickLifecycleIfNeeded(videoId: string, _reason: string?)
	local cfg = getLifecycleCfg()
	if not cfg or cfg.Enabled ~= true then
		return
	end
	if typeof(videoId) ~= "string" or videoId == "" then
		return
	end
	if _lifecycleRunning[videoId] then
		return
	end
	local now = os.clock()
	if (_lifecycleCoolUntil[videoId] or 0) > now then
		return
	end
	_lifecycleRunning[videoId] = true
	local coolSec = math.max(0, tonumber(cfg.CooldownSec) or 300)
	task.spawn(function()
		local ok, err = pcall(function()
			SocialStore.RunLifecyclePass(videoId, { forceHard = false, sync = false })
		end)
		_lifecycleRunning[videoId] = false
		_lifecycleCoolUntil[videoId] = os.clock() + coolSec
		if not ok then
			warn("[ShortVideoFeature] RunLifecyclePass failed:", videoId, err)
		end
	end)
end

--[[
	HardCap 同步腾槽（发评前）；不设冷却，便于随后异步收尾
	@param videoId string - 视频 id
	@return boolean - 腾槽后是否仍低于 HardCap
]]
function SocialStore.EnsureUnderHardCap(videoId: string): boolean
	local cfg = getLifecycleCfg()
	if not cfg or cfg.Enabled ~= true then
		return true
	end
	local hardCap = math.max(1, math.floor(tonumber(cfg.HardCap) or 3000))
	local stats = SocialStore.GetStats(videoId)
	if (tonumber(stats.commentCount) or 0) < hardCap then
		return true
	end
	waitLifecycleIdle(videoId)
	_lifecycleRunning[videoId] = true
	local ok, err = pcall(function()
		SocialStore.RunLifecyclePass(videoId, { forceHard = true, sync = true })
	end)
	_lifecycleRunning[videoId] = false
	if not ok then
		warn("[ShortVideoFeature] EnsureUnderHardCap failed:", videoId, err)
	end
	stats = SocialStore.GetStats(videoId)
	return (tonumber(stats.commentCount) or 0) < hardCap
end

--[[
	解析客户端游标
	@param cursor any - nil | table | 旧 number（忽略，当首页）
	@return { score: number, cid: string }?
]]
function SocialStore.ParseCursor(cursor: any): { score: number, cid: string }?
	if typeof(cursor) ~= "table" then
		return nil
	end
	local score = tonumber(cursor.score)
	local cid = cursor.cid
	if score == nil or typeof(cid) ~= "string" or cid == "" then
		return nil
	end
	return { score = score, cid = cid }
end

--[[
	按排序拉一页评论（含迁移、屏蔽清理）
	@param videoId string - 视频 id
	@param cursor any - 上一页游标
	@param pageSize number - 页大小
	@param sortMode any? - hot | newest；缺省 hot
	@return boolean - 是否成功
	@return {any} - 评论列表
	@return any? - nextCursor
]]
function SocialStore.FetchCommentsPage(
	videoId: string,
	cursor: any,
	pageSize: number,
	sortMode: any?
): (boolean, { any }, any?)
	SocialStore.EnsureMigrated(videoId)
	local mode = SocialStore.NormalizeSortMode(sortMode)
	if mode == SORT_NEWEST then
		SocialStore.KickTimeMigrateIfNeeded(videoId)
	end
	local parsed = SocialStore.ParseCursor(cursor)
	-- 仅首页异步触发生命周期，不拖分页尾延迟
	if parsed == nil then
		SocialStore.KickLifecycleIfNeeded(videoId, "fetch_home")
	end
	local size = math.clamp(math.floor(pageSize), 1, 100)
	local fetchSize = math.min(100, size + 15)
	local indexStore = if mode == SORT_NEWEST then getTimeStore(videoId) else getRankStore(videoId)
	local function readPage(maxValue: number?): { any }
		local okP, pages = pcall(function()
			if maxValue ~= nil then
				return indexStore:GetSortedAsync(false, fetchSize, nil, maxValue)
			end
			return indexStore:GetSortedAsync(false, fetchSize)
		end)
		if not okP or not pages then
			return {}
		end
		return pages:GetCurrentPage()
	end

	local entries = if parsed then readPage(parsed.score) else readPage(nil)
	local pickedKeys: { string } = {}
	local scoreByCid: { [string]: number } = {}

	local function collectFrom(pageEntries: { any }, startAfterCid: string?)
		local pass = startAfterCid == nil
		for _, entry in ipairs(pageEntries) do
			local cid = entry.key
			local score = entry.value
			if typeof(cid) == "string" then
				if not pass then
					if cid == startAfterCid then
						pass = true
					end
				else
					table.insert(pickedKeys, cid)
					scoreByCid[cid] = score
					if #pickedKeys >= size then
						return
					end
				end
			end
		end
	end

	if parsed then
		collectFrom(entries, parsed.cid)
		if #pickedKeys == 0 and parsed.score > 0 then
			-- 游标条已删：从更低分继续
			entries = readPage(parsed.score - 1)
			collectFrom(entries, nil)
		end
	else
		collectFrom(entries, nil)
	end

	local comments = {}
	local lastScore: number? = nil
	local lastCid: string? = nil
	local bodies = SocialStore.GetCommentBodies(pickedKeys)
	for _, cid in ipairs(pickedKeys) do
		local raw = bodies[cid]
		if raw and not SocialStore.BelongsToVideo(raw, videoId) then
			-- 错挂到本视频 ODS：只摘索引，保留真正归属视频的 Body
			task.spawn(function()
				SocialStore.RemoveRankEntry(videoId, cid)
			end)
		else
			local comment = if raw then normalizeComment(raw, videoId) else nil
			if not comment then
				-- Body 缺失或屏蔽：删除索引+Body，并扣计数
				task.spawn(function()
					SocialStore.DeleteComment(videoId, cid, true)
				end)
			else
				table.insert(comments, {
					cid = comment.cid,
					userId = comment.userId,
					name = comment.name,
					text = comment.text,
					likeCount = comment.likeCount,
					createdAt = comment.createdAt,
				})
				lastScore = scoreByCid[cid]
				lastCid = cid
			end
		end
	end

	local nextCursor = nil
	if lastScore ~= nil and lastCid ~= nil and #pickedKeys >= size then
		nextCursor = { score = lastScore, cid = lastCid }
	end
	return true, comments, nextCursor
end

--[[
	发评入库；Stats 失败则回滚索引，避免 count 虚增或「成功却无数」
	@param videoId string - 视频 id
	@param comment any - 评论（已过滤）
	@return boolean - 是否成功
	@return number? - 新 commentCount
]]
function SocialStore.AddComment(videoId: string, comment: any): (boolean, number?)
	SocialStore.EnsureMigrated(videoId)
	local normalized = normalizeComment(comment, videoId)
	if not normalized then
		return false, nil
	end
	-- HardCap：同步腾槽；仍满则拒发（BUSY）
	if not SocialStore.EnsureUnderHardCap(videoId) then
		return false, nil
	end
	if not writeCommentIndex(videoId, normalized) then
		return false, nil
	end
	local okStats, stats = SocialStore.UpdateStats(videoId, function(old)
		old.commentCount = (tonumber(old.commentCount) or 0) + 1
		return old
	end)
	if not okStats then
		SocialStore.DeleteComment(videoId, normalized.cid, false)
		return false, nil
	end
	SocialStore.KickLifecycleIfNeeded(videoId, "post")
	return true, stats and (tonumber(stats.commentCount) or 0) or nil
end

--[[
	评论点赞数变更并更新 ODS 分数（严格校验归属，禁止改写到其他视频）
	@param videoId string - 视频 id
	@param cid string - 评论 id
	@param delta number - +1 / -1
	@return boolean - 是否成功
	@return number? - 新 likeCount
]]
function SocialStore.AdjustCommentLike(videoId: string, cid: string, delta: number): (boolean, number?)
	SocialStore.EnsureMigrated(videoId)
	local newCount: number? = nil
	local createdAt = 0
	local rejected = false
	local ok = pcall(function()
		bodyStore:UpdateAsync(cid, function(old)
			if typeof(old) ~= "table" then
				return nil
			end
			if not SocialStore.BelongsToVideo(old, videoId) then
				rejected = true
				return nil
			end
			local nextCount = math.max(0, (tonumber(old.likeCount) or 0) + delta)
			old.likeCount = nextCount
			newCount = nextCount
			createdAt = tonumber(old.createdAt) or 0
			-- 旧数据无 videoId：回填归属，永不覆盖为其他视频
			if typeof(old.videoId) ~= "string" or old.videoId == "" then
				old.videoId = videoId
			end
			_bodyCache[cid] = { at = os.clock(), data = old }
			return old
		end)
	end)
	if rejected or not ok or newCount == nil then
		return false, nil
	end
	local score = SocialStore.EncodeScore(newCount, createdAt)
	local okRank = pcall(function()
		getRankStore(videoId):SetAsync(cid, score)
	end)
	-- Rank 失败仍返回 likeCount（Body 已更新）；下次读页/再赞会重试写分
	if not okRank then
		warn("[ShortVideoFeature] AdjustCommentLike rank write failed:", videoId, cid)
	end
	return true, newCount
end

--[[
	读取玩家社交状态（短缓存，降低拉评尾跳）
	@param userId number - 玩家 UserId
	@return table - { videos, comments, watched }
]]
function SocialStore.GetPlayer(userId: number): any
	local cached = _playerCache[userId]
	if cached and os.clock() - cached.at <= PLAYER_TTL then
		return cached.data
	end
	local key = tostring(userId)
	local ok, data = pcall(function()
		return playerStore:GetAsync(key)
	end)
	local result
	if ok and typeof(data) == "table" then
		result = {
			videos = if typeof(data.videos) == "table" then data.videos else {},
			comments = if typeof(data.comments) == "table" then data.comments else {},
			watched = if typeof(data.watched) == "table" then data.watched else {},
		}
	else
		result = shallowCopy(DEFAULT_PLAYER)
	end
	_playerCache[userId] = { at = os.clock(), data = result }
	return result
end

--[[
	UpdateAsync 修改玩家社交状态
	@param userId number - 玩家 UserId
	@param mutator (old) -> new - 变更函数
	@return boolean - 是否成功
	@return any? - 新数据
]]
function SocialStore.UpdatePlayer(userId: number, mutator: (any) -> any): (boolean, any?)
	local key = tostring(userId)
	_playerCache[userId] = nil
	local ok, result = pcall(function()
		return playerStore:UpdateAsync(key, function(old)
			local base = if typeof(old) == "table"
				then {
					videos = if typeof(old.videos) == "table" then old.videos else {},
					comments = if typeof(old.comments) == "table" then old.comments else {},
					watched = if typeof(old.watched) == "table" then old.watched else {},
				}
				else shallowCopy(DEFAULT_PLAYER)
			return mutator(base)
		end)
	end)
	if ok and typeof(result) == "table" then
		_playerCache[userId] = { at = os.clock(), data = result }
	end
	return ok, result
end

return SocialStore
