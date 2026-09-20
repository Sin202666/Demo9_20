--[[
	Module: RankConfig
	Description: 排行榜共享配置（SystemRank 写榜 / SystemRankManager 展示）
	Author: 林奥宇
	Created: 2026-07-03
	Last Modified: 2026-09-01

	当前榜：时长 N_Time、罗宝 N_Robux、金币 N_Gold（无战力榜）。

	业务接入（写分）：
	- 不要调 SystemRank.UploadPlayerRankInfo；只写 SystemRecord 对应字段。
	- 字段键必须用 RANK_DATA_FIELDS[RANK_*_NAME]，禁止再抄中文键。
		local RankConfig = Utils.RankConfig
		local SystemRecord = Utils.SystemRecord
		SystemRecord.RecordAdd(player, RankConfig.RANK_DATA_FIELDS[RankConfig.RANK_GOLD_NAME], n)
	- 需要尽快上榜时（如付费成功）再调 SystemRank.UploadPlayer(player)；金币/时长仍可由定时批量写榜覆盖。
	- 原始分 <= 0 不上榜。workspace 缓存 Score 是编码分，展示/查询 API 返回已解码分。

	新增一榜清单：
	1. RANK_*_NAME + RANK_NAMES + RANK_DEFS（recordField / scoreFormat / monotonic / gradient / 可选 slotCount / 可选 icon）
	2. 可选 SCENE_BOARD_TO_RANK（按 Rank_<键> 命名时可省略）
	3. 某个服务端 System 对 recordField 做 RecordAdd/Cover
	4. LocalizationTable.xlsx 标题键；RankBoardBind._bindRankTitleText 补 SetText **字面量分支**（Key 禁止走配置表 / KEYS 查找表）
	5. 场景：Rank_<键>/Board/SurfaceGui/Content/{Main, MyRank, 排行榜-排名, 排行榜-数量, 排行榜-玩家}
	   title/SurfaceGui/{RankTitle, Icon}；RankTitle 用 RANK_TITLE_GRADIENT（GradientCfg「排行榜标题」→ 彩虹 ColorScroll）
	   格子模板 RankTemp 子节点 Frame/Username/Rank/Number/Portrait/BG
	6. 若 duration：Refresh 用「排行榜时长」；若 monotonic：写榜只升不降

	场景 Board：workspace.场景/<世界>/功能/排行榜/<Board>
	- 模型名 = Rank_ + 写榜键（Rank_N_Gold → N_Gold）
	读前三名 / 缓存页：服务端 SystemRank.GetTop3UserIds / GetCacheEntries；客户端 SystemRankManager 同名 API。
	编码：OrderedDataStore 存 MathMgr.getRankNum；禁止改算法。
	RankTemp 只从 ReplicatedStorage 解析（Scope.Shared）。
]]

-- ========================================
-- 模块定义
-- ========================================
local RankConfig = {}

-- ========================================
-- 常量定义
-- ========================================

RankConfig.SCORE_FORMAT_NUMBER = "number"
RankConfig.SCORE_FORMAT_DURATION = "duration"

RankConfig.RANK_ROBUX_NAME = "N_Robux"
RankConfig.RANK_TIME_NAME = "N_Time"
RankConfig.RANK_GOLD_NAME = "N_Gold"

-- RankTitle 共用：GradientCfg「排行榜标题」→ Gridient「彩虹」，ColorScroll（彩虹柔）
RankConfig.RANK_TITLE_GRADIENT = "排行榜标题"

RankConfig.RANK_NAMES = table.freeze({
	RankConfig.RANK_ROBUX_NAME,
	RankConfig.RANK_TIME_NAME,
	RankConfig.RANK_GOLD_NAME,
})

-- 每榜定义；标题翻译 Key 不放这里（必须在 Bind 调用处写字面量）
-- icon：title/SurfaceGui/Icon 的 rbxassetid:// URI；缺省则绑板时隐藏 Icon
RankConfig.RANK_DEFS = table.freeze({
	[RankConfig.RANK_ROBUX_NAME] = table.freeze({
		recordField = "累计消费罗宝",
		scoreFormat = RankConfig.SCORE_FORMAT_NUMBER,
		monotonic = false,
		gradient = "排行榜-罗宝",
		icon = "rbxassetid://131931252853903",
	}),
	[RankConfig.RANK_TIME_NAME] = table.freeze({
		recordField = "累计游戏时长",
		scoreFormat = RankConfig.SCORE_FORMAT_DURATION,
		monotonic = true,
		gradient = "排行榜-时长",
		icon = "rbxassetid://126446199222343",
	}),
	[RankConfig.RANK_GOLD_NAME] = table.freeze({
		recordField = "总金币获得",
		scoreFormat = RankConfig.SCORE_FORMAT_NUMBER,
		monotonic = false,
		gradient = "排行榜-金币",
		icon = "rbxassetid://91454845440900",
	}),
})

local _dataFields: { [string]: string } = {}
local _gradients: { [string]: string } = {}
for _, rankName in ipairs(RankConfig.RANK_NAMES) do
	local def = RankConfig.RANK_DEFS[rankName]
	if def then
		_dataFields[rankName] = def.recordField
		if type(def.gradient) == "string" and def.gradient ~= "" then
			_gradients[rankName] = def.gradient
		end
	end
end
RankConfig.RANK_DATA_FIELDS = table.freeze(_dataFields)
RankConfig.RANK_GRADIENT_TYPES = table.freeze(_gradients)

-- 场景 Board 模型 Name 前缀；Rank_N_Gold → N_Gold
RankConfig.SCENE_BOARD_PREFIX = "Rank_"

-- 显式别名（前缀规则覆盖不了时用）
RankConfig.SCENE_BOARD_TO_RANK = table.freeze({
	Rank_N_Gold = RankConfig.RANK_GOLD_NAME,
	Rank_N_Robux = RankConfig.RANK_ROBUX_NAME,
	Rank_N_Time = RankConfig.RANK_TIME_NAME,
})

RankConfig.RANK_COLORS = table.freeze({
	[1] = Color3.new(0.996078, 0.941176, 0.0431373),
	[2] = Color3.new(0.00392157, 0.921569, 1),
	[3] = Color3.new(0.0352941, 0.976471, 0.219608),
})

RankConfig.TOP3_COUNT = 3
RankConfig.RANK_COUNTS = 100
RankConfig.RANK_SAVE_MAX_TRIES = 2
RankConfig.RANK_SAVE_RETRY_INTERVAL_SEC = 1
RankConfig.RANK_UPLOAD_INITIAL_DELAY_SEC = 5

RankConfig.WORKSPACE_CACHE_FOLDER = "排行榜缓存"
RankConfig.WORKSPACE_TOP3_FOLDER = "前3名玩家"

RankConfig.RANK_TEMP_NAME = "RankTemp"
RankConfig.RANK_TEMP_FOLDER_NAME = "排行榜"
RankConfig.RANK_TEMP_PATHS = table.freeze({
	"ModelRes/排行榜/RankTemp",
	"UI/排行榜/RankTemp",
})
RankConfig.RANK_TEMP_SHARED_CATALOGS = table.freeze({
	"ModelRes",
	"UI",
})

-- ========================================
-- 私有变量
-- ========================================
local _rankNameSet: { [string]: boolean } = {}
for _, rankName in ipairs(RankConfig.RANK_NAMES) do
	_rankNameSet[rankName] = true
end
table.freeze(_rankNameSet)

-- ========================================
-- 公共函数
-- ========================================

--[[
	是否为已登记写榜键

	@param rankName string - 写榜键
	@return boolean - 在 RANK_NAMES 中为 true
]]
function RankConfig.IsRankName(rankName: string): boolean
	return type(rankName) == "string" and _rankNameSet[rankName] == true
end

--[[
	取一榜定义（只读冻结表）。返回的是 RANK_DEFS 冻结条目引用，勿改字段；需要可变副本时自行 deepCopy。

	@param rankName string - 写榜键
	@return table? - RANK_DEFS 条目；未登记为 nil
]]
function RankConfig.GetRankDef(rankName: string): { [string]: any }?
	if not RankConfig.IsRankName(rankName) then
		return nil
	end
	return RankConfig.RANK_DEFS[rankName]
end

--[[
	取该榜标题旁 Icon 的图片 URI（rbxassetid://...）。

	@param rankName string - 写榜键
	@return string? - 非空 icon；未配置或未登记为 nil
]]
function RankConfig.GetRankIcon(rankName: string): string?
	if not RankConfig.IsRankName(rankName) then
		return nil
	end
	local def = RankConfig.RANK_DEFS[rankName]
	if not def then
		return nil
	end
	local icon = def.icon
	if type(icon) ~= "string" or icon == "" then
		return nil
	end
	return icon
end

--[[
	取 SystemRecord 统计字段名

	@param rankName string - 写榜键
	@return string? - Record 键；未登记为 nil
]]
function RankConfig.GetRecordField(rankName: string): string?
	local def = RankConfig.RANK_DEFS[rankName]
	if not def then
		return nil
	end
	return def.recordField
end

--[[
	该榜写 ODS 是否只升不降

	@param rankName string - 写榜键
	@return boolean - 只升不降为 true
]]
function RankConfig.IsMonotonic(rankName: string): boolean
	local def = RankConfig.RANK_DEFS[rankName]
	return def ~= nil and def.monotonic == true
end

--[[
	分数是否按时长（天/小时）展示

	@param rankName string - 写榜键
	@return boolean - duration 为 true
]]
function RankConfig.IsDurationScore(rankName: string): boolean
	local def = RankConfig.RANK_DEFS[rankName]
	return def ~= nil and def.scoreFormat == RankConfig.SCORE_FORMAT_DURATION
end

--[[
	该榜 UI 格子数量（不超过 RANK_COUNTS）

	@param rankName string - 写榜键
	@return number - 1..RANK_COUNTS
]]
function RankConfig.GetSlotCount(rankName: string): number
	local def = RankConfig.RANK_DEFS[rankName]
	local n = RankConfig.RANK_COUNTS
	if def and type(def.slotCount) == "number" then
		n = def.slotCount
	end
	if n < 1 then
		return 1
	end
	if n > RankConfig.RANK_COUNTS then
		return RankConfig.RANK_COUNTS
	end
	return n
end

--[[
	由场景 Board 模型名解析写榜 / 缓存键。
	顺序：已是 RANK_NAMES → SCENE_BOARD_TO_RANK → 去掉 Rank_ 前缀后查 RANK_NAMES。

	@param boardName string - 场景模型 Name，如 Rank_N_Gold 或 N_Time
	@return string? - RANK_NAMES 中的写榜键；未登记时 nil
]]
function RankConfig.GetRankNameByBoard(boardName: string): string?
	if type(boardName) ~= "string" or boardName == "" then
		return nil
	end
	if _rankNameSet[boardName] then
		return boardName
	end
	local mapped = RankConfig.SCENE_BOARD_TO_RANK[boardName]
	if mapped then
		return mapped
	end
	local prefix = RankConfig.SCENE_BOARD_PREFIX
	if string.sub(boardName, 1, #prefix) == prefix then
		local suffix = string.sub(boardName, #prefix + 1)
		if _rankNameSet[suffix] then
			return suffix
		end
	end
	return nil
end

return RankConfig
