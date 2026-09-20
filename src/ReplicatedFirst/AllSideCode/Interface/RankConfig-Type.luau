--[[
	Module: RankConfig-Type
	Description: RankConfig 类型声明（完整使用说明见 ToolBasic/RankConfig.luau 文件头）
	Author: 林奥宇
	Created: 2026-09-01
	Last Modified: 2026-09-01
]]

local RankConfig = {}

RankConfig.SCORE_FORMAT_NUMBER = "number"
RankConfig.SCORE_FORMAT_DURATION = "duration"
RankConfig.RANK_ROBUX_NAME = "N_Robux"
RankConfig.RANK_TIME_NAME = "N_Time"
RankConfig.RANK_GOLD_NAME = "N_Gold"
RankConfig.RANK_TITLE_GRADIENT = "排行榜标题"
RankConfig.RANK_NAMES = {} :: { string }
RankConfig.RANK_DEFS = {} :: { [string]: any }
RankConfig.RANK_DATA_FIELDS = {} :: { [string]: string }
RankConfig.RANK_GRADIENT_TYPES = {} :: { [string]: string }
RankConfig.SCENE_BOARD_PREFIX = "Rank_"
RankConfig.SCENE_BOARD_TO_RANK = {} :: { [string]: string }
RankConfig.RANK_COLORS = {} :: { [number]: Color3 }
RankConfig.TOP3_COUNT = 3
RankConfig.RANK_COUNTS = 100
RankConfig.RANK_SAVE_MAX_TRIES = 2
RankConfig.RANK_SAVE_RETRY_INTERVAL_SEC = 1
RankConfig.RANK_UPLOAD_INITIAL_DELAY_SEC = 5
RankConfig.WORKSPACE_CACHE_FOLDER = "排行榜缓存"
RankConfig.WORKSPACE_TOP3_FOLDER = "前3名玩家"
RankConfig.RANK_TEMP_NAME = "RankTemp"
RankConfig.RANK_TEMP_FOLDER_NAME = "排行榜"
RankConfig.RANK_TEMP_PATHS = {} :: { string }
RankConfig.RANK_TEMP_SHARED_CATALOGS = {} :: { string }

--[[
	是否为已登记写榜键

	@param rankName string - 写榜键
	@return boolean - 在 RANK_NAMES 中为 true
]]
function RankConfig.IsRankName(rankName: string): boolean
	return false
end

--[[
	取一榜定义（只读冻结表）。返回冻结条目引用，勿改字段。

	@param rankName string - 写榜键
	@return table? - RANK_DEFS 条目；未登记为 nil
]]
function RankConfig.GetRankDef(rankName: string): { [string]: any }?
	return nil
end

--[[
	取该榜标题旁 Icon 的图片 URI（rbxassetid://...）。

	@param rankName string - 写榜键
	@return string? - 非空 icon；未配置或未登记为 nil
]]
function RankConfig.GetRankIcon(rankName: string): string?
	return nil
end

--[[
	取 SystemRecord 统计字段名

	@param rankName string - 写榜键
	@return string? - Record 键；未登记为 nil
]]
function RankConfig.GetRecordField(rankName: string): string?
	return nil
end

--[[
	该榜写 ODS 是否只升不降

	@param rankName string - 写榜键
	@return boolean - 只升不降为 true
]]
function RankConfig.IsMonotonic(rankName: string): boolean
	return false
end

--[[
	分数是否按时长（天/小时）展示

	@param rankName string - 写榜键
	@return boolean - duration 为 true
]]
function RankConfig.IsDurationScore(rankName: string): boolean
	return false
end

--[[
	该榜 UI 格子数量（不超过 RANK_COUNTS）

	@param rankName string - 写榜键
	@return number - 1..RANK_COUNTS
]]
function RankConfig.GetSlotCount(rankName: string): number
	return 100
end

--[[
	由场景 Board 模型名解析写榜 / 缓存键。

	@param boardName string - 场景模型 Name，如 Rank_N_Gold 或 N_Time
	@return string? - RANK_NAMES 中的写榜键；未登记时 nil
]]
function RankConfig.GetRankNameByBoard(boardName: string): string?
	return nil
end

return RankConfig
