--[[
	Module: RankBoardRefresh
	Description: 客户端排行榜读 workspace 缓存并刷新格子（按 UserId 去重拉取名/头像）
	Author: 林奥宇
	Created: 2026-09-01
	Last Modified: 2026-09-01

	职责（相对 init / Bind / Prepare）：
	- 只读 workspace「排行榜缓存」「前3名玩家」，解码后写本地 SurfaceGui
	- 按 UserId 去重后 spawn 拉名/头像；时长分走「排行榜时长」字面量 Key
	- 不写 Store、不写 workspace 权威镜像；不负责等场景/克隆格子

	由 SystemRankManager 内部 require(script.RankBoardRefresh)；业务请走 Utils.SystemRankManager。
	写榜与镜像权威见服务端 SystemRank；展示启动见同目录 init.luau。
]]

-- ========================================
-- 服务引用
-- ========================================
local Workspace = game:GetService("Workspace")

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local DataCache = Utils.DataCache
local TimeTransfer = Utils.TimeTransfer
local MathMgr = Utils.MathMgr
local RankConfig = Utils.RankConfig
local TranslationHelper = Utils.TranslationHelper

local RankBoardBind = require(script.Parent.RankBoardBind)

type SlotWidgets = RankBoardBind.SlotWidgets
type RankBoardRef = RankBoardBind.RankBoardRef
type RankSlot = { number }

local RankBoardRefresh = {}

-- ========================================
-- 常量定义
-- ========================================
local PLACEHOLDER_TEXT = "???"
local RANK_INDEX_PREFIX = "#"

-- ========================================
-- 私有函数
-- ========================================

--[[
	写入单个格子的占位或名次色

	@param widgets SlotWidgets - 格子控件
	@param slotIndex number - 1-based 名次
	@param isPlaceholder boolean - true 时用户名/分数写占位符
	@return () - 无返回值
]]
local function _applySlotChrome(widgets: SlotWidgets, slotIndex: number, isPlaceholder: boolean)
	if widgets.rankLabel then
		TranslationHelper.SetRawText(widgets.rankLabel, RANK_INDEX_PREFIX .. tostring(slotIndex))
		local rankColor = RankConfig.RANK_COLORS[slotIndex]
		if rankColor then
			widgets.rankLabel.TextColor3 = rankColor
		end
	end
	if isPlaceholder then
		if widgets.username then
			TranslationHelper.SetRawText(widgets.username, PLACEHOLDER_TEXT)
		end
		if widgets.number then
			TranslationHelper.SetRawText(widgets.number, PLACEHOLDER_TEXT)
		end
	end
end

--[[
	写入时长或缩写数字到分数格。时长走翻译键，切语言可刷新。

	@param widgets SlotWidgets - 格子控件
	@param rankName string - 写榜键
	@param rankValue number - 缓存中的编码分数
	@return () - 无返回值
]]
local function _applyScoreText(widgets: SlotWidgets, rankName: string, rankValue: number)
	if not widgets.number then
		return
	end
	local rawScore = MathMgr.backRankNum(rankValue)
	if RankConfig.IsDurationScore(rankName) then
		local days, hours = TimeTransfer.GetRankDurationParts(rawScore)
		TranslationHelper.SetText(widgets.number, "排行榜时长", { tostring(days), tostring(hours) })
		return
	end
	TranslationHelper.SetRawText(widgets.number, MathMgr.getNumStr(rawScore))
end

--[[
	把一条榜数据写到格子（玩家名 / 头像可能 yield；调用方应按 UserId 去重后再 spawn）

	@param widgets SlotWidgets - 格子控件
	@param userId number - 上榜玩家 UserId
	@param rankValue number - 编码分数
	@param rankName string - 榜名
	@param slotIndex number - 1-based 名次
	@return () - 无返回值
]]
local function _applySlotEntry(
	widgets: SlotWidgets,
	userId: number,
	rankValue: number,
	rankName: string,
	slotIndex: number
)
	_applySlotChrome(widgets, slotIndex, false)
	if widgets.username then
		TranslationHelper.SetRawText(widgets.username, DataCache.GetPlrName(userId))
	end
	if widgets.portrait then
		widgets.portrait.Image = DataCache.GetPortrait(userId)
	end
	_applyScoreText(widgets, rankName, rankValue)
	widgets.frameRank:SetAttribute("UserID", userId)
end

--[[
	填充「我的排名」：未上榜时显示本人名/头像，名次走未上榜文案

	@param widgets SlotWidgets - MyRank 格子
	@param userId number? - 本地玩家 UserId；nil 时只写占位
	@return () - 无返回值
]]
local function _applyMyRankUnranked(widgets: SlotWidgets, userId: number?)
	if widgets.rankLabel then
		TranslationHelper.SetText(widgets.rankLabel, "未上榜")
	end
	if widgets.username then
		if userId and userId > 0 then
			TranslationHelper.SetRawText(widgets.username, DataCache.GetPlrName(userId))
		else
			TranslationHelper.SetRawText(widgets.username, PLACEHOLDER_TEXT)
		end
	end
	if widgets.portrait and userId and userId > 0 then
		widgets.portrait.Image = DataCache.GetPortrait(userId)
	end
	if widgets.number then
		TranslationHelper.SetRawText(widgets.number, PLACEHOLDER_TEXT)
	end
	widgets.frameRank:SetAttribute("UserID", userId or 0)
end

--[[
	预拉玩家名与头像（会 yield）

	@param userId number - UserId；非正数时直接返回
	@return () - 无返回值
]]
local function _prefetchPlayerVisual(userId: number)
	if userId <= 0 then
		return
	end
	DataCache.GetPlrName(userId)
	DataCache.GetPortrait(userId)
end

--[[
	从 workspace 缓存读取指定榜的排名数据

	@param rankName string - 排行榜名称（RankConfig.RANK_NAMES）
	@return { RankSlot }? - {{userId, score}, ...}；无缓存根或无该榜时 nil
]]
local function _readRankCache(rankName: string): { RankSlot }?
	local cacheRoot = Workspace:FindFirstChild(RankConfig.WORKSPACE_CACHE_FOLDER)
	if not cacheRoot then
		return nil
	end

	local rankFolder = cacheRoot:FindFirstChild(rankName)
	if not rankFolder then
		return nil
	end

	local data: { RankSlot } = {}
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
			table.insert(data, { userIdValue.Value, scoreValue.Value })
		end
	end

	return data
end

--[[
	收集本榜刷新所需去重 UserId（含本地玩家）

	@param data { RankSlot }? - 缓存页；nil 时仅可能含本地
	@param localUserId number - 本地 UserId；≤0 忽略
	@return {number} - 去重后的 UserId 列表
]]
local function _collectPrefetchUserIds(data: { RankSlot }?, localUserId: number): { number }
	local uniqueUserIds: { [number]: boolean } = {}
	if data then
		for _, rankEntry in ipairs(data) do
			uniqueUserIds[rankEntry[1]] = true
		end
	end
	if localUserId > 0 then
		uniqueUserIds[localUserId] = true
	end
	local uniqueIdList: { number } = {}
	for userId in uniqueUserIds do
		table.insert(uniqueIdList, userId)
	end
	return uniqueIdList
end

--[[
	把缓存页写到列表格，并刷新 MyRank（已上榜或未上榜）

	@param boardRefs { RankBoardRef } - 已绑定榜板
	@param rankName string - 写榜键
	@param data { RankSlot }? - 编码分缓存页
	@param localUserId number - 本地 UserId；0 表示未知
	@param ownIndex number? - 本人名次；未上榜为 nil
	@param ownScore number? - 本人编码分；未上榜为 nil
	@return () - 无返回值
]]
local function _applyRankBoardEntries(
	boardRefs: { RankBoardRef },
	rankName: string,
	data: { RankSlot }?,
	localUserId: number,
	ownIndex: number?,
	ownScore: number?
)
	if data then
		for i, rankEntry in ipairs(data) do
			local userId = rankEntry[1]
			local rankValue = rankEntry[2]
			for _, boardRef in boardRefs do
				if boardRef.rankName == rankName then
					local widgets = boardRef.slots[i]
					if widgets then
						_applySlotEntry(widgets, userId, rankValue, rankName, i)
					end
				end
			end
		end
	end

	for _, boardRef in boardRefs do
		if boardRef.rankName ~= rankName or not boardRef.myRank then
			continue
		end
		local myRankWidgets = boardRef.myRank
		if ownIndex and ownScore then
			_applySlotEntry(myRankWidgets, localUserId, ownScore, rankName, ownIndex)
		else
			_applyMyRankUnranked(myRankWidgets, if localUserId > 0 then localUserId else nil)
		end
	end
end

-- ========================================
-- 公共函数
-- ========================================

--[[
	列表格占位（Init 绑板时用）

	@param widgets SlotWidgets - 格子控件
	@param slotIndex number - 1-based 名次
	@return () - 无返回值
]]
function RankBoardRefresh.applyPlaceholder(widgets: SlotWidgets, slotIndex: number)
	_applySlotChrome(widgets, slotIndex, true)
end

--[[
	MyRank 初始未上榜（Init 绑板时用）

	@param widgets SlotWidgets - MyRank 格子
	@param userId number? - 本地玩家 UserId
	@return () - 无返回值
]]
function RankBoardRefresh.applyMyRankUnranked(widgets: SlotWidgets, userId: number?)
	_applyMyRankUnranked(widgets, userId)
end

--[[
	读 workspace 缓存并解码分数（新表）。

	@param rankName string - 写榜键
	@return { { userId: number, score: number } } - 解码后的条目；无缓存为空表
]]
function RankBoardRefresh.getCacheEntries(rankName: string): { { userId: number, score: number } }
	local result: { { userId: number, score: number } } = {}
	if not RankConfig.IsRankName(rankName) then
		return result
	end
	local encoded = _readRankCache(rankName)
	if not encoded then
		return result
	end
	for _, slot in ipairs(encoded) do
		table.insert(result, {
			userId = slot[1],
			score = MathMgr.backRankNum(slot[2]),
		})
	end
	return result
end

--[[
	读 workspace「前3名玩家」UserId（新表，不含 0）。

	@param rankName string - 写榜键
	@return {number} - 最多 TOP3_COUNT 个 UserId
]]
function RankBoardRefresh.getTop3UserIds(rankName: string): { number }
	local ids: { number } = {}
	if not RankConfig.IsRankName(rankName) then
		return ids
	end
	local top3Folder = Workspace:FindFirstChild(RankConfig.WORKSPACE_TOP3_FOLDER)
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
	用已缓存的 Board 引用刷新单个榜。同一 UserId 只 spawn 一次名/头像拉取。

	@param boardRefs { RankBoardRef } - 已绑定榜板
	@param rankName string - 排行榜名称
	@param localUserId number - 本地玩家 UserId；0 表示未知
	@return () - 无返回值；无缓存时仍刷新 MyRank 为未上榜
]]
function RankBoardRefresh.updateRankDisplay(boardRefs: { RankBoardRef }, rankName: string, localUserId: number)
	local data = _readRankCache(rankName)

	local ownIndex: number? = nil
	local ownScore: number? = nil
	if data then
		for i, rankEntry in ipairs(data) do
			if rankEntry[1] == localUserId then
				ownIndex = i
				ownScore = rankEntry[2]
				break
			end
		end
	end

	local uniqueIdList = _collectPrefetchUserIds(data, localUserId)

	--[[
		预拉完成后（或无需预拉时）写格子

		@return () - 无返回值
	]]
	local function applyAll()
		_applyRankBoardEntries(boardRefs, rankName, data, localUserId, ownIndex, ownScore)
	end

	if #uniqueIdList == 0 then
		applyAll()
		return
	end

	local remaining = #uniqueIdList
	for _, userId in uniqueIdList do
		task.spawn(function()
			_prefetchPlayerVisual(userId)
			remaining -= 1
			if remaining == 0 then
				applyAll()
			end
		end)
	end
end

--[[
	刷新所有已配置排行榜的 SurfaceGui

	@param boardRefs { RankBoardRef } - 已绑定榜板
	@param localUserId number - 本地玩家 UserId；0 表示未知
	@return () - 无返回值
]]
function RankBoardRefresh.refreshAll(boardRefs: { RankBoardRef }, localUserId: number)
	for _, rankName in ipairs(RankConfig.RANK_NAMES) do
		RankBoardRefresh.updateRankDisplay(boardRefs, rankName, localUserId)
	end
end

return RankBoardRefresh
