--[[
	Module: SystemRank
	Description: 服务端排行榜写榜与 workspace 榜单缓存发布
	Author: 林奥宇
	Created: 2026-07-03
	Last Modified: 2026-09-01

	功能：
	- 读取 SystemRecord 在线玩家分数，编码后写入 OrderedDataStore
	- 拉取各榜排序页并写入 workspace 镜像，供客户端 SystemRankManager 只读展示
	- RANK_DEFS.monotonic 为 true 的榜只升不降（现为时长榜）
	- Init 时若 RankTemp 仅在 ServerStorage，克隆一份到 ReplicatedStorage.Assets.UI/排行榜
	- UploadPlayer：单人立即写榜；PlayerRemoving 时冲一次，减少「改分后退」丢分
	- GetTop3UserIds / GetCacheEntries：只读 workspace 镜像（解码后的副本）

	与相关模块：
	- 写榜权威仅本模块；客户端 SystemRankManager / DataCache 只读 workspace，不写 Store
	- RankTemp 展示模板：客户端只读 RS；本模块仅补复制，不改模板内容
	- 持久化只经 SystemDataStore.GetOrdered / SetOrdered / GetSortedOrdered
	- 分数来自 SystemRecord.GetDataByID，字段映射见 RankConfig.GetRecordField
	- 数值编解码走 MathMgr.getRankNum / backRankNum（与展示侧成对）
	- UpdateManager 在 UpdateModule.Start 前调用 Init；Studio 另会立刻 UpdateRank 一次

	关键约束：
	- 原始分 <= 0 不上榜（与 GetSortedOrdered 最低分过滤一致）
	- monotonic 榜读旧分失败时跳过本次写入；编码分无变化时不 SetOrdered
	- workspace「排行榜缓存」Score 存的是编码分；查询 API 返回解码分
	- getRankNum 有损（同档约 2 位尾数）；禁止改编码算法，以免打乱现网 OrderedDataStore
	- 「前3名玩家」只镜像 UserId，给场景装扮等只读；排行榜 UI 不读此树
	- 无 Remote；无玩家存档字段；不发奖

	加载方式：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local SystemRank = Utils.SystemRank

	使用示例：
		SystemRank.Init()
		-- 业务只写 Record，不要定时调 UploadPlayerRankInfo
		SystemRecord.RecordAdd(player, RankConfig.RANK_DATA_FIELDS[RankConfig.RANK_GOLD_NAME], n)
		-- 付费等需要尽快上榜时
		SystemRank.UploadPlayer(player)
		local topIds = SystemRank.GetTop3UserIds(RankConfig.RANK_GOLD_NAME)
		local entries = SystemRank.GetCacheEntries(RankConfig.RANK_GOLD_NAME)
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Players = Utils.Players
local ReplicatedStorage = Utils.ReplicatedStorage
local InsMgr = Utils.InsMgr
local Log = Utils.Log
local MathMgr = Utils.MathMgr
local RankConfig = Utils.RankConfig
local AssetPaths = Utils.AssetPaths
local SystemRecord = Utils.SystemRecord
local SystemDataStore = Utils.SystemDataStore
local UpdateModule = Utils.UpdateModule

-- ========================================
-- 模块定义
-- ========================================
local SystemRank = {}

-- ========================================
-- 常量定义
-- ========================================
-- 与 SEC_300 错开，使首次拉榜约在 100s，避开写榜 120s 整点
local RANK_UPDATE_INITIAL_ELAPSED_SEC = 200
local ORDERED_SORT_MIN_VALUE = 1

local ORDERED_LOAD_OPTIONS = {
	maxTries = 1,
	retryIntervalSec = 0,
}

local ORDERED_SAVE_OPTIONS = {
	maxTries = RankConfig.RANK_SAVE_MAX_TRIES,
	retryIntervalSec = RankConfig.RANK_SAVE_RETRY_INTERVAL_SEC,
}

local SORTED_LOAD_OPTIONS = {
	maxTries = 1,
	retryIntervalSec = 0,
}

-- GetSortedOrdered 页条目：{ [1]=userId (string|number), [2]=encodedScore (number) }
type OdsRankEntry = { any }
-- 查询 API 返回：解码后的原始分，非 workspace NumberValue 引用
type RankQueryEntry = { userId: number, score: number }

-- ========================================
-- 私有变量
-- ========================================
local _initialized = false

-- ========================================
-- 私有函数
-- ========================================

--[[
	初始化 workspace 前三名与榜单缓存目录结构

	@return nil - 仅确保 Folder / NumberValue 存在，不写入分数
]]
local function _ensureWorkspaceFolders()
	local top3Folder: Folder = InsMgr.GetIns(RankConfig.WORKSPACE_TOP3_FOLDER, "Folder", workspace)
	for _, rankName in ipairs(RankConfig.RANK_NAMES) do
		local rankTopFolder: Folder = InsMgr.GetIns(rankName, "Folder", top3Folder)
		for i = 1, RankConfig.TOP3_COUNT do
			InsMgr.GetIns(tostring(i), "NumberValue", rankTopFolder)
		end
	end

	InsMgr.GetIns(RankConfig.WORKSPACE_CACHE_FOLDER, "Folder", workspace)
end

--[[
	按路径列表解析 RankTemp Frame

	@param scope string - AssetPaths.Scope.Shared / Server
	@return Frame? - 模板；均未命中或类型不符时 nil
]]
local function _resolveRankTemp(scope: string): Frame?
	for _, path in RankConfig.RANK_TEMP_PATHS do
		local inst = AssetPaths.Resolve(path, scope)
		if inst and inst:IsA("Frame") then
			return inst
		end
	end
	return nil
end

--[[
	确保客户端能读到 RankTemp。已在 ReplicatedStorage 则跳过；否则从 ServerStorage 克隆到 Assets/UI/排行榜。

	@return () - 无返回值；模板两侧都没有时只 Log.warn
]]
local function _ensureRankTempReplicated()
	if _resolveRankTemp(AssetPaths.Scope.Shared) then
		return
	end

	local template = _resolveRankTemp(AssetPaths.Scope.Server)
	if not template then
		Log.warn("[SystemRank] RankTemp 在 Shared/Server 均未找到，无法复制到 ReplicatedStorage")
		return
	end

	local assets = InsMgr.GetIns(AssetPaths.ASSETS_ROOT_NAME, "Folder", ReplicatedStorage)
	local ui = InsMgr.GetIns("UI", "Folder", assets)
	local rankFolder = InsMgr.GetIns(RankConfig.RANK_TEMP_FOLDER_NAME, "Folder", ui)
	if rankFolder:FindFirstChild(RankConfig.RANK_TEMP_NAME) then
		return
	end

	local clone = template:Clone()
	if not clone then
		Log.warn("[SystemRank] RankTemp Clone 失败（Archivable=false?），无法复制到 ReplicatedStorage")
		return
	end
	clone.Name = RankConfig.RANK_TEMP_NAME
	clone.Parent = rankFolder
end

--[[
	保存单榜玩家分数至 OrderedDataStore
	monotonic 榜先读旧分再取较大值；读失败则本轮不写；编码分与旧分相同则跳过 SetOrdered

	@param plrId number - 玩家 UserId，须 > 0
	@param rankName string - OrderedDataStore 名称（RankConfig.RANK_NAMES 之一）
	@param value number - 原始分数（未编码）；须 > 0
	@return nil - 校验失败、monotonic 榜读旧分失败或编码分无变化时静默跳过；写失败只 Log
]]
local function _saveRankInfo(plrId: number, rankName: string, value: number)
	if type(plrId) ~= "number" or plrId <= 0 then
		return
	end
	if not RankConfig.IsRankName(rankName) then
		return
	end
	if type(value) ~= "number" or value <= 0 then
		return
	end

	local saveValue = value
	local playerKey = tostring(plrId)
	local oldEncoded: number? = nil

	if RankConfig.IsMonotonic(rankName) then
		local ok, oldValue, loadErr = SystemDataStore.GetOrdered(rankName, playerKey, ORDERED_LOAD_OPTIONS)
		if not ok then
			Log.warn("SystemRank._saveRankInfo load old monotonic failed:", rankName, playerKey, loadErr)
			return
		end
		oldEncoded = oldValue
		if oldValue then
			local decodedOld = MathMgr.backRankNum(oldValue)
			if value < decodedOld then
				saveValue = decodedOld
			end
		end
	end

	local encoded = MathMgr.getRankNum(saveValue)
	if oldEncoded ~= nil and encoded == oldEncoded then
		return
	end

	local setOk, err = SystemDataStore.SetOrdered(rankName, playerKey, encoded, ORDERED_SAVE_OPTIONS)
	if not setOk then
		Log.warn("SystemRank._saveRankInfo failed:", rankName, playerKey, err)
	end
end

--[[
	将一条缓存槽写入（已有则改 NumberValue，避免 ClearAllChildren 复制抖动）

	@param rankFolder Folder - 该榜缓存目录
	@param slotIndex number - 1-based 名次
	@param userId number - 上榜 UserId；0 表示空槽
	@param encodedScore number - 编码分
	@return nil
]]
local function _upsertCacheSlot(rankFolder: Folder, slotIndex: number, userId: number, encodedScore: number)
	local slotFolder: Folder = InsMgr.GetIns(tostring(slotIndex), "Folder", rankFolder)
	local userIdValue: NumberValue = InsMgr.GetIns("UserId", "NumberValue", slotFolder)
	local scoreValue: NumberValue = InsMgr.GetIns("Score", "NumberValue", slotFolder)
	userIdValue.Value = userId
	scoreValue.Value = encodedScore
end

--[[
	将排序结果写入 workspace 缓存与前三名目录
	缓存 Score 为编码分；前三名 NumberValue 只写 UserId。已有槽就地改值。

	@param rankName string - 排行榜名称（与 RankConfig.RANK_NAMES 一致）
	@param entries {OdsRankEntry} - {{userId, encodedScore}, ...}，已按高分在前
	@return nil - 始终写满 RankConfig.TOP3_COUNT 个槽；缺条目的 UserId 置 0；多余缓存槽 UserId 置 0
]]
local function _publishRankCache(rankName: string, entries: { OdsRankEntry })
	local cacheRoot: Folder = InsMgr.GetIns(RankConfig.WORKSPACE_CACHE_FOLDER, "Folder", workspace)
	local rankFolder: Folder = InsMgr.GetIns(rankName, "Folder", cacheRoot)

	local published = 0
	for i, entry in ipairs(entries) do
		if i > RankConfig.RANK_COUNTS then
			break
		end
		_upsertCacheSlot(rankFolder, i, tonumber(entry[1]) or 0, entry[2])
		published = i
	end

	for _, child in rankFolder:GetChildren() do
		local slotIndex = tonumber(child.Name)
		if slotIndex and slotIndex > published then
			local userIdValue = child:FindFirstChild("UserId")
			local scoreValue = child:FindFirstChild("Score")
			if userIdValue and userIdValue:IsA("NumberValue") then
				userIdValue.Value = 0
			end
			if scoreValue and scoreValue:IsA("NumberValue") then
				scoreValue.Value = 0
			end
		end
	end

	local top3Folder: Folder = InsMgr.GetIns(RankConfig.WORKSPACE_TOP3_FOLDER, "Folder", workspace)
	local rankTopFolder: Folder = InsMgr.GetIns(rankName, "Folder", top3Folder)
	for i = 1, RankConfig.TOP3_COUNT do
		local topValue: NumberValue = InsMgr.GetIns(tostring(i), "NumberValue", rankTopFolder)
		local entry = entries[i]
		if entry then
			topValue.Value = tonumber(entry[1]) or 0
		else
			topValue.Value = 0
		end
	end
end

--[[
	把一名玩家当前 Record 分写入各榜 ODS。先同步快照再写，避免 PlayerRemoving 后会话被清。

	@param plr Player - 在线或正在离开的玩家
	@return () - 无返回值；无效玩家或分 <= 0 跳过
]]
local function _uploadPlayerFromRecord(plr: Player)
	if typeof(plr) ~= "Instance" or not plr:IsA("Player") then
		return
	end
	local userId = plr.UserId
	if type(userId) ~= "number" or userId <= 0 then
		return
	end

	local snapshots: { { rankName: string, value: number } } = {}
	for _, rankName in ipairs(RankConfig.RANK_NAMES) do
		local fieldName = RankConfig.GetRecordField(rankName)
		if fieldName then
			local value = SystemRecord.GetDataByID(plr, fieldName)
			if value > 0 then
				table.insert(snapshots, { rankName = rankName, value = value })
			end
		end
	end

	for _, item in ipairs(snapshots) do
		_saveRankInfo(userId, item.rankName, item.value)
	end
end

--[[
	从 workspace 缓存读一榜（解码分）。无缓存或未登记键返回空表。

	@param rankName string - 写榜键
	@return {RankQueryEntry} - 新表；score 为解码后的原始分
]]
local function _readCacheEntries(rankName: string): { RankQueryEntry }
	local result: { RankQueryEntry } = {}
	if not RankConfig.IsRankName(rankName) then
		return result
	end
	local cacheRoot = workspace:FindFirstChild(RankConfig.WORKSPACE_CACHE_FOLDER)
	if not cacheRoot then
		return result
	end
	local rankFolder = cacheRoot:FindFirstChild(rankName)
	if not rankFolder then
		return result
	end
	for i = 1, RankConfig.RANK_COUNTS do
		local slotFolder = rankFolder:FindFirstChild(tostring(i))
		if not slotFolder then
			continue
		end
		local userIdValue = slotFolder:FindFirstChild("UserId")
		local scoreValue = slotFolder:FindFirstChild("Score")
		if
			userIdValue
			and scoreValue
			and userIdValue:IsA("NumberValue")
			and scoreValue:IsA("NumberValue")
			and userIdValue.Value > 0
		then
			table.insert(result, {
				userId = userIdValue.Value,
				score = MathMgr.backRankNum(scoreValue.Value),
			})
		end
	end
	return result
end

-- ========================================
-- 公共函数
-- ========================================

--[[
	上传一名玩家各榜分数至 OrderedDataStore。先快照 Record 再写。
	原始分 <= 0 跳过。付费成功等需要尽快上榜时调用；不要在金币流水热路径上每笔都调。

	@param player Player - 目标玩家
	@return () - 无返回值；失败见 Log
]]
function SystemRank.UploadPlayer(player: Player)
	_uploadPlayerFromRecord(player)
end

--[[
	上传所有在线玩家的排行榜分数至 OrderedDataStore
	原始分 <= 0 跳过；单条失败只 Log，不中断其余玩家/其余榜

	@return nil - 批量写榜无汇总返回值；失败见 Log
]]
function SystemRank.UploadPlayerRankInfo()
	for _, plr: Player in Players:GetPlayers() do
		_uploadPlayerFromRecord(plr)
	end
end

--[[
	读 workspace「前3名玩家」镜像 UserId（新表，不含 0）。

	@param rankName string - 写榜键
	@return {number} - 最多 3 个 UserId；未登记或无镜像为空表
]]
function SystemRank.GetTop3UserIds(rankName: string): { number }
	local ids: { number } = {}
	if not RankConfig.IsRankName(rankName) then
		return ids
	end
	local top3Folder = workspace:FindFirstChild(RankConfig.WORKSPACE_TOP3_FOLDER)
	if not top3Folder then
		return ids
	end
	local rankTopFolder = top3Folder:FindFirstChild(rankName)
	if not rankTopFolder then
		return ids
	end
	for i = 1, RankConfig.TOP3_COUNT do
		local topValue = rankTopFolder:FindFirstChild(tostring(i))
		if topValue and topValue:IsA("NumberValue") and topValue.Value > 0 then
			table.insert(ids, topValue.Value)
		end
	end
	return ids
end

--[[
	读 workspace 排行榜缓存并解码分数（新表，非 NumberValue 引用）。

	@param rankName string - 写榜键
	@return {RankQueryEntry} - { userId, score }；无缓存或未登记为空表
]]
function SystemRank.GetCacheEntries(rankName: string): { RankQueryEntry }
	return _readCacheEntries(rankName)
end

--[[
	拉取各榜排序页并发布至 workspace 缓存
	单榜失败只 Log，不中断其余榜

	@return nil - 批量拉榜无汇总返回值；失败见 Log
]]
function SystemRank.UpdateRank()
	for _, rankName in ipairs(RankConfig.RANK_NAMES) do
		local ok, entries, err = SystemDataStore.GetSortedOrdered(
			rankName,
			false,
			RankConfig.RANK_COUNTS,
			ORDERED_SORT_MIN_VALUE,
			SORTED_LOAD_OPTIONS
		)

		if ok and entries then
			_publishRankCache(rankName, entries)
		else
			Log.warn("SystemRank.UpdateRank failed:", rankName, err)
		end
	end
end

-- ========================================
-- 初始化
-- ========================================

--[[
	注册排行榜写榜与缓存发布定时任务，由 UpdateManager 在 Start 前调用一次。
	同时把 ServerStorage 上的 RankTemp 补复制到 ReplicatedStorage（若 Shared 已有则跳过）。
	PlayerRemoving 时 UploadPlayer 冲一次。重复调用幂等

	@return nil - 已初始化时直接返回
]]
function SystemRank.Init()
	if _initialized then
		return
	end
	_initialized = true

	_ensureWorkspaceFolders()
	_ensureRankTempReplicated()

	task.delay(RankConfig.RANK_UPLOAD_INITIAL_DELAY_SEC, function()
		SystemRank.UploadPlayerRankInfo()
	end)

	UpdateModule.Register(UpdateModule.INTERVAL.SEC_120, function(_elapsed: number)
		SystemRank.UploadPlayerRankInfo()
	end, { spawn = true, initialElapsed = UpdateModule.INTERVAL.SEC_120 })

	UpdateModule.Register(UpdateModule.INTERVAL.SEC_300, function(_elapsed: number)
		SystemRank.UpdateRank()
	end, { spawn = true, initialElapsed = RANK_UPDATE_INITIAL_ELAPSED_SEC })

	Players.PlayerRemoving:Connect(function(player: Player)
		SystemRank.UploadPlayer(player)
	end)
end

return SystemRank
