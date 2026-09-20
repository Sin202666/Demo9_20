--[[
	Module: RequestRateLimit
	Description: 服务端 Remote 入站中间件——请求频率限制与异常检测
	Author: 林奥宇
	Created: 2026-07-01
	Last Modified: 2026-09-01

	功能：
	- 按 msgName 滑动窗口频率限制（CheckRateLimit）
	- 数据异常 / 请求模式异常检测（DetectDataAnomaly / DetectRequestPatternAnomaly）
	- 累计异常记录、警告与踢出（RecordCheatAndCheck）
	- 启动期配置注册（SetRateLimitConfig / SetCheatDetectionConfig）

	------------------------------------------------------------------------
	与 NetWork 的关系
	------------------------------------------------------------------------
	NetWork 在服务端 Remote 入站时调用本模块（见 InboundDispatch._passServerRemoteMiddleware）；
	业务 System 不直接监听 Remote，也不应绕过 NetWork 自行限频。
	HandlerOptions.skipRateLimit / skipCheatDetection 可跳过对应检查。

	------------------------------------------------------------------------
	端侧约束
	------------------------------------------------------------------------
	- Kick、Tips、PlayerRemoving 清理仅服务端生效；Init() 在服务端绑定离开清理
	- 写接口（CheckRateLimit / RecordCheatAndCheck / Set*Config / ClearPlayerCheatRecord）
	  在客户端直接失败关闭或空操作，避免误调 Kick
	- 客户端可加载模块（Utils 懒加载），但不应调用上述写接口

	------------------------------------------------------------------------
	配置
	------------------------------------------------------------------------
	RateLimitConfig 字段：maxRequests（窗口内最大次数）、timeWindow（秒）
	未配置的 msgName 使用 RATE_LIMIT_DEFAULT_KEY（"_default"）
	异常检测仅对 SetCheatDetectionConfig / MSG_CHEAT_DETECTION_CONFIG 中 enabled=true 的 msgName 生效
	内置 msgName 键须用 NetMsg 常量，禁止手写中文路由串

	------------------------------------------------------------------------
	加载与 Init
	------------------------------------------------------------------------
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local RequestRateLimit = Utils.RequestRateLimit
		local NetMsg = Utils.NetMsg
		RequestRateLimit.Init()  -- 由 NetWorkManager（服务端）启动时调用

	示例：
	-- 启动期注册 msgName 限频
	RequestRateLimit.SetRateLimitConfig(NetMsg.CLAIM_LEVEL_AWARD, { maxRequests = 3, timeWindow = 2 })

	-- NetWork 中间件内（框架自动调用，业务无需手写）
	if not RequestRateLimit.CheckRateLimit(player, msgName) then return end

	-- 超限提示走 TipsModule.ErrorTips，Key 必须是字面量（已入 LocalizationTable）
	-- 「请求过于频繁，请稍后再试」「检测到异常行为，警告次数」
]]

-- ============================================================================
-- Services
-- ============================================================================

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

-- ============================================================================
-- Requires
-- ============================================================================

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Log = Utils.Log
local TipsModule = Utils.TipsModule
local Copy = Utils.Copy
local NetMsg = Utils.NetMsg

-- ============================================================================
-- Module definition
-- ============================================================================

local RequestRateLimit = {}

-- ============================================================================
-- Constants
-- ============================================================================

local IS_SERVER = RunService:IsServer()

local RATE_LIMIT_DEFAULT_KEY = "_default"

local CHEAT_TYPE_RATE_LIMIT_EXCEEDED = "rate_limit_exceeded"
local CHEAT_TYPE_DATA_INVALID = "data_invalid"
local CHEAT_TYPE_DATA_FORMAT_ERROR = "data_format_error"
local CHEAT_TYPE_REQUEST_PATTERN_ABNORMAL = "request_pattern_abnormal"
local CHEAT_TYPE_SEVERE_CHEAT = "severe_cheat"

local CHEAT_ACTION_WARN = "warn"
local CHEAT_ACTION_KICK = "kick"

local REQUEST_PATTERN_TIME_WINDOW_SEC = 5
local REQUEST_PATTERN_MSG_TYPE_LIMIT = 10
local WARN_COOLDOWN_SEC = 10

-- Kick 为 Roblox 断线框，服务端 TranslateByKey 用进程 locale 而非玩家 LocaleId，故用常量
local KICK_MSG_ABNORMAL = "检测到异常行为，已被踢出游戏"

export type RateLimitEntry = {
	maxRequests: number,
	timeWindow: number,
}

export type CheatTypeThreshold = {
	severity: number,
	maxCount: number,
	maxSeverity: number,
	action: string,
}

export type CheatDetectionEntry = {
	enabled: boolean,
	cheatTypes: { string },
	thresholds: { [string]: CheatTypeThreshold },
	globalThresholds: {
		warnThreshold: { maxCount: number?, maxSeverity: number? },
		kickThreshold: { maxCount: number?, maxSeverity: number? },
	}?,
}

export type PlayerCheatRecord = {
	totalCount: number,
	totalSeverity: number,
	records: { [string]: { count: number, severity: number, lastTime: number } },
	warnCount: number,
	lastWarnTime: number,
}

export type GlobalThresholds = {
	warnThreshold: { maxCount: number, maxSeverity: number },
	kickThreshold: { maxCount: number, maxSeverity: number },
}

-- ============================================================================
-- Config tables
-- ============================================================================

local DEFAULT_RATE_LIMIT_ENTRY: RateLimitEntry = {
	maxRequests = 20,
	timeWindow = 1,
}

local RATE_LIMIT_CONFIG: { [string]: RateLimitEntry } = {
	[NetMsg.PRIVATE_SERVER_OWNER_ID] = {
		maxRequests = 5,
		timeWindow = 10,
	},
	[NetMsg.DEBUG_EMAIL] = {
		maxRequests = 5,
		timeWindow = 10,
	},
	[NetMsg.BAG_LOCK_ITEMS] = {
		maxRequests = 8,
		timeWindow = 2,
	},
	[NetMsg.BACKPACK_TOOLBAR_DRAG] = {
		maxRequests = 12,
		timeWindow = 1,
	},
	[RATE_LIMIT_DEFAULT_KEY] = {
		maxRequests = DEFAULT_RATE_LIMIT_ENTRY.maxRequests,
		timeWindow = DEFAULT_RATE_LIMIT_ENTRY.timeWindow,
	},
}

local MSG_CHEAT_DETECTION_CONFIG: { [string]: CheatDetectionEntry } = {
	[NetMsg.PRIVATE_SERVER_OWNER_ID] = {
		enabled = true,
		cheatTypes = { CHEAT_TYPE_RATE_LIMIT_EXCEEDED, CHEAT_TYPE_DATA_INVALID },
		thresholds = {
			[CHEAT_TYPE_RATE_LIMIT_EXCEEDED] = {
				severity = 3,
				maxCount = 5,
				maxSeverity = 15,
				action = CHEAT_ACTION_WARN,
			},
			[CHEAT_TYPE_DATA_INVALID] = {
				severity = 5,
				maxCount = 3,
				maxSeverity = 15,
				action = CHEAT_ACTION_WARN,
			},
		},
		globalThresholds = {
			warnThreshold = { maxCount = 8, maxSeverity = 25 },
			kickThreshold = { maxCount = 15, maxSeverity = 40 },
		},
	},
	[NetMsg.CLAIM_LEVEL_AWARD] = {
		enabled = true,
		cheatTypes = {
			CHEAT_TYPE_RATE_LIMIT_EXCEEDED,
			CHEAT_TYPE_DATA_INVALID,
			CHEAT_TYPE_REQUEST_PATTERN_ABNORMAL,
		},
		thresholds = {
			[CHEAT_TYPE_RATE_LIMIT_EXCEEDED] = {
				severity = 4,
				maxCount = 3,
				maxSeverity = 12,
				action = CHEAT_ACTION_WARN,
			},
			[CHEAT_TYPE_DATA_INVALID] = {
				severity = 6,
				maxCount = 2,
				maxSeverity = 12,
				action = CHEAT_ACTION_WARN,
			},
			[CHEAT_TYPE_REQUEST_PATTERN_ABNORMAL] = {
				severity = 7,
				maxCount = 2,
				maxSeverity = 14,
				action = CHEAT_ACTION_WARN,
			},
		},
		globalThresholds = {
			warnThreshold = { maxCount = 5, maxSeverity = 20 },
			kickThreshold = { maxCount = 10, maxSeverity = 35 },
		},
	},
}

local DEFAULT_CHEAT_TYPE_CONFIG: { [string]: CheatTypeThreshold } = {
	[CHEAT_TYPE_RATE_LIMIT_EXCEEDED] = {
		severity = 3,
		maxCount = 5,
		maxSeverity = 15,
		action = CHEAT_ACTION_WARN,
	},
	[CHEAT_TYPE_DATA_INVALID] = {
		severity = 5,
		maxCount = 3,
		maxSeverity = 15,
		action = CHEAT_ACTION_WARN,
	},
	[CHEAT_TYPE_DATA_FORMAT_ERROR] = {
		severity = 4,
		maxCount = 5,
		maxSeverity = 20,
		action = CHEAT_ACTION_WARN,
	},
	[CHEAT_TYPE_REQUEST_PATTERN_ABNORMAL] = {
		severity = 6,
		maxCount = 3,
		maxSeverity = 18,
		action = CHEAT_ACTION_WARN,
	},
	[CHEAT_TYPE_SEVERE_CHEAT] = {
		severity = 10,
		maxCount = 1,
		maxSeverity = 10,
		action = CHEAT_ACTION_KICK,
	},
}

local DEFAULT_GLOBAL_THRESHOLDS: GlobalThresholds = {
	warnThreshold = { maxCount = 10, maxSeverity = 30 },
	kickThreshold = { maxCount = 20, maxSeverity = 50 },
}

-- ============================================================================
-- Private state
-- ============================================================================

local _initialized = false
local _playerRemovingConn: RBXScriptConnection? = nil

local _playerRequestRecords: { [number]: { [string]: { timestamps: { number } } } } = {}
local _playerCheatRecords: { [number]: PlayerCheatRecord } = {}

-- ============================================================================
-- Private helpers
-- ============================================================================

--[[
	校验目标是否为仍在数据模型中的 Player
	@param player any - 调用方传入的玩家；可能为伪造值
	@return boolean - 是在线 Player 实例为 true
]]
local function _isValidPlayer(player: any): boolean
	return typeof(player) == "Instance" and player:IsA("Player") and player.Parent ~= nil
end

--[[
	校验 msgName 为非空字符串
	@param msgName any - 调用方传入的路由键
	@return boolean - 非空 string 为 true
]]
local function _isValidMsgName(msgName: any): boolean
	return typeof(msgName) == "string" and msgName ~= ""
end

--[[
	清理指定 msgName 在时间窗口外的请求时间戳
	@param playerId number - 玩家 UserId
	@param msgName string - 消息名称
	@param timeWindow number - 滑动窗口长度（秒）
	@return nil
]]
local function _cleanupExpiredRecords(playerId: number, msgName: string, timeWindow: number)
	local records = _playerRequestRecords[playerId]
	if not records or not records[msgName] then
		return
	end

	local timestamps = records[msgName].timestamps
	local currentTime = os.time()
	local cutoffTime = currentTime - timeWindow

	for i = #timestamps, 1, -1 do
		if timestamps[i] < cutoffTime then
			table.remove(timestamps, i)
		end
	end
end

--[[
	判断 msgName 是否启用了异常检测
	@param msgName string - 消息名称
	@return boolean - true 表示已启用
]]
local function _isCheatDetectionEnabled(msgName: string): boolean
	local config = MSG_CHEAT_DETECTION_CONFIG[msgName]
	return config ~= nil and config.enabled == true
end

--[[
	获取 msgName 下某异常类型的阈值配置
	@param msgName string - 消息名称
	@param cheatType string - 异常类型键（如 rate_limit_exceeded）
	@return CheatTypeThreshold? - 未配置或未启用时返回 nil
]]
local function _getCheatTypeConfig(msgName: string, cheatType: string): CheatTypeThreshold?
	local msgConfig = MSG_CHEAT_DETECTION_CONFIG[msgName]
	if not msgConfig or not msgConfig.enabled then
		return nil
	end

	if not msgConfig.cheatTypes then
		return nil
	end

	local hasCheatType = false
	for _, ct in ipairs(msgConfig.cheatTypes) do
		if ct == cheatType then
			hasCheatType = true
			break
		end
	end

	if not hasCheatType then
		return nil
	end

	if msgConfig.thresholds and msgConfig.thresholds[cheatType] then
		return msgConfig.thresholds[cheatType]
	end
	return DEFAULT_CHEAT_TYPE_CONFIG[cheatType]
end

--[[
	获取 msgName 的全局 warn/kick 阈值（含默认值回退；始终返回新表）
	@param msgName string - 消息名称
	@return GlobalThresholds - 含 warnThreshold、kickThreshold 字段的阈值表
]]
local function _getGlobalThresholds(msgName: string): GlobalThresholds
	local msgConfig = MSG_CHEAT_DETECTION_CONFIG[msgName]
	local global = msgConfig and msgConfig.globalThresholds
	local warn = global and global.warnThreshold
	local kick = global and global.kickThreshold
	return {
		warnThreshold = {
			maxCount = (warn and warn.maxCount) or DEFAULT_GLOBAL_THRESHOLDS.warnThreshold.maxCount,
			maxSeverity = (warn and warn.maxSeverity) or DEFAULT_GLOBAL_THRESHOLDS.warnThreshold.maxSeverity,
		},
		kickThreshold = {
			maxCount = (kick and kick.maxCount) or DEFAULT_GLOBAL_THRESHOLDS.kickThreshold.maxCount,
			maxSeverity = (kick and kick.maxSeverity) or DEFAULT_GLOBAL_THRESHOLDS.kickThreshold.maxSeverity,
		},
	}
end

--[[
	根据单类型与全局累计判断是否需要 warn 或 kick
	@param playerRecord PlayerCheatRecord - 玩家累计异常记录
	@param typeRecord table - 单 msgName+cheatType 记录，含 count、severity
	@param config CheatTypeThreshold - 当前异常类型阈值
	@param globalThresholds GlobalThresholds - 全局 warn/kick 阈值
	@return boolean - 是否应踢出
	@return boolean - 是否应警告
]]
local function _evaluateCheatAction(
	playerRecord: PlayerCheatRecord,
	typeRecord: { count: number, severity: number },
	config: CheatTypeThreshold,
	globalThresholds: GlobalThresholds
): (boolean, boolean)
	local shouldWarn = false
	local shouldKick = false

	if typeRecord.count >= config.maxCount or typeRecord.severity >= config.maxSeverity then
		if config.action == CHEAT_ACTION_KICK then
			shouldKick = true
		else
			shouldWarn = true
		end
	end

	if playerRecord.totalCount >= globalThresholds.kickThreshold.maxCount
		or playerRecord.totalSeverity >= globalThresholds.kickThreshold.maxSeverity then
		shouldKick = true
	elseif playerRecord.totalCount >= globalThresholds.warnThreshold.maxCount
		or playerRecord.totalSeverity >= globalThresholds.warnThreshold.maxSeverity then
		shouldWarn = true
	end

	return shouldKick, shouldWarn
end

--[[
	执行踢出并写日志（仅服务端）
	@param player Player - 目标玩家
	@param playerId number - 玩家 UserId
	@param msgName string - 消息名称
	@param cheatType string - 异常类型
	@param playerRecord PlayerCheatRecord - 累计记录（用于日志）
	@return nil
]]
local function _executeKick(
	player: Player,
	playerId: number,
	msgName: string,
	cheatType: string,
	playerRecord: PlayerCheatRecord
)
	if not IS_SERVER then
		return
	end

	Log.warn(string.format(
		"检测到玩家 %s (%d) 严重异常行为，消息: %s，类型: %s，总次数: %d，总程度: %d，执行踢出",
		player.Name,
		playerId,
		msgName,
		cheatType,
		playerRecord.totalCount,
		playerRecord.totalSeverity
	))
	player:Kick(KICK_MSG_ABNORMAL)
end

--[[
	执行警告（带冷却），更新 warnCount
	@param player Player - 目标玩家
	@param playerId number - 玩家 UserId
	@param msgName string - 消息名称
	@param cheatType string - 异常类型
	@param playerRecord PlayerCheatRecord - 累计记录（会被更新 lastWarnTime / warnCount）
	@return nil
]]
local function _executeWarn(
	player: Player,
	playerId: number,
	msgName: string,
	cheatType: string,
	playerRecord: PlayerCheatRecord
)
	if not IS_SERVER then
		return
	end

	local currentTime = os.time()
	if currentTime - playerRecord.lastWarnTime < WARN_COOLDOWN_SEC then
		return
	end

	playerRecord.warnCount += 1
	playerRecord.lastWarnTime = currentTime

	Log.warn(string.format(
		"警告玩家 %s (%d) 异常行为，消息: %s，类型: %s，总次数: %d，总程度: %d，警告次数: %d",
		player.Name,
		playerId,
		msgName,
		cheatType,
		playerRecord.totalCount,
		playerRecord.totalSeverity,
		playerRecord.warnCount
	))
	TipsModule.ErrorTips(player, "检测到异常行为，警告次数", { playerRecord.warnCount })
end

--[[
	玩家离开时清理内存中的请求与异常记录
	@param playerId number - 玩家 UserId
	@return nil
]]
local function _clearPlayerRecords(playerId: number)
	_playerRequestRecords[playerId] = nil
	_playerCheatRecords[playerId] = nil
end

-- ============================================================================
-- Public API - anomaly detection
-- ============================================================================

--[[
	检测 payload 数据是否含 NaN、nil 等明显非法值
	@param data any - NetWork 中间件提取的 payload；nil 视为异常
	@return string? - 异常类型键；无异常返回 nil
]]
function RequestRateLimit.DetectDataAnomaly(data: any): string?
	if type(data) == "number" and tostring(data) == "nan" then
		return CHEAT_TYPE_DATA_INVALID
	end

	if data == nil then
		return CHEAT_TYPE_DATA_INVALID
	end

	if type(data) == "table" then
		for _, v in pairs(data) do
			if type(v) == "number" and tostring(v) == "nan" then
				return CHEAT_TYPE_DATA_INVALID
			end
		end
	end

	return nil
end

--[[
	检测短时间窗口内是否请求了过多不同 msgName（刷包模式）
	@param playerId number - 玩家 UserId
	@return boolean - true 表示请求模式异常
]]
function RequestRateLimit.DetectRequestPatternAnomaly(playerId: number): boolean
	local records = _playerRequestRecords[playerId]
	if not records then
		return false
	end

	local currentTime = os.time()
	local recentMsgCount = 0

	for _, record in pairs(records) do
		if record.timestamps then
			for _, timestamp in ipairs(record.timestamps) do
				if currentTime - timestamp <= REQUEST_PATTERN_TIME_WINDOW_SEC then
					recentMsgCount += 1
					break
				end
			end
		end
	end

	return recentMsgCount > REQUEST_PATTERN_MSG_TYPE_LIMIT
end

--[[
	累计异常并判断是否 warn/kick；踢出后返回 true 表示调用方应拒绝本次请求
	@param player Player - 目标玩家；须在线
	@param msgName string - 消息名称
	@param cheatType string - 异常类型键（与 NetWork 常量一致）
	@return boolean - true 表示已踢出、应拒绝后续处理；false 表示未踢出、可继续
]]
function RequestRateLimit.RecordCheatAndCheck(player: Player, msgName: string, cheatType: string): boolean
	if not IS_SERVER or not _isValidPlayer(player) or not _isValidMsgName(msgName) or typeof(cheatType) ~= "string" then
		return false
	end
	if not _isCheatDetectionEnabled(msgName) then
		return false
	end

	local config = _getCheatTypeConfig(msgName, cheatType)
	if not config then
		return false
	end

	local playerId = player.UserId
	local severity = config.severity

	if not _playerCheatRecords[playerId] then
		_playerCheatRecords[playerId] = {
			totalCount = 0,
			totalSeverity = 0,
			records = {},
			warnCount = 0,
			lastWarnTime = 0,
		}
	end

	local playerRecord = _playerCheatRecords[playerId]
	local recordKey = msgName .. "_" .. cheatType

	if not playerRecord.records[recordKey] then
		playerRecord.records[recordKey] = {
			count = 0,
			severity = 0,
			lastTime = 0,
		}
	end

	local typeRecord = playerRecord.records[recordKey]
	typeRecord.count += 1
	typeRecord.severity += severity
	typeRecord.lastTime = os.time()

	playerRecord.totalCount += 1
	playerRecord.totalSeverity += severity

	local globalThresholds = _getGlobalThresholds(msgName)
	local shouldKick, shouldWarn = _evaluateCheatAction(playerRecord, typeRecord, config, globalThresholds)

	if shouldKick then
		_executeKick(player, playerId, msgName, cheatType, playerRecord)
		return true
	end

	if shouldWarn then
		_executeWarn(player, playerId, msgName, cheatType, playerRecord)
	end

	return false
end

-- ============================================================================
-- Public API - rate limit
-- ============================================================================

--[[
	滑动窗口频率检查；超限则拒绝并可选累计 rate_limit_exceeded
	@param player Player - 目标玩家
	@param msgName string - 消息名称（与 NetMsg 常量一致）
	@return boolean - true 表示允许继续；false 表示超限、已踢出或入参非法
]]
function RequestRateLimit.CheckRateLimit(player: Player, msgName: string): boolean
	if not IS_SERVER or not _isValidPlayer(player) or not _isValidMsgName(msgName) then
		return false
	end

	local playerId = player.UserId
	local config = RATE_LIMIT_CONFIG[msgName] or RATE_LIMIT_CONFIG[RATE_LIMIT_DEFAULT_KEY] or DEFAULT_RATE_LIMIT_ENTRY
	local maxRequests = config.maxRequests
	local timeWindow = config.timeWindow

	if not _playerRequestRecords[playerId] then
		_playerRequestRecords[playerId] = {}
	end

	if not _playerRequestRecords[playerId][msgName] then
		_playerRequestRecords[playerId][msgName] = { timestamps = {} }
	end

	_cleanupExpiredRecords(playerId, msgName, timeWindow)

	local timestamps = _playerRequestRecords[playerId][msgName].timestamps
	if #timestamps >= maxRequests then
		if RequestRateLimit.RecordCheatAndCheck(player, msgName, CHEAT_TYPE_RATE_LIMIT_EXCEEDED) then
			return false
		end

		Log.warn(string.format(
			"玩家 %s (%d) 的请求 '%s' 超过频率限制: %d次/%d秒",
			player.Name,
			playerId,
			msgName,
			maxRequests,
			timeWindow
		))
		TipsModule.ErrorTips(player, "请求过于频繁，请稍后再试")
		return false
	end

	table.insert(timestamps, os.time())
	return true
end

-- ============================================================================
-- Public API - config
-- ============================================================================

--[[
	注册或覆盖 msgName 的频率限制（启动期、仅服务端调用）
	@param msgName string - 消息名称（与 NetMsg 常量一致）
	@param config RateLimitEntry - maxRequests、timeWindow（秒）；内部深拷贝，调用方可丢弃原表
	@return nil
]]
function RequestRateLimit.SetRateLimitConfig(msgName: string, config: RateLimitEntry)
	if not IS_SERVER then
		return
	end
	if not _isValidMsgName(msgName) or typeof(config) ~= "table"
		or typeof(config.maxRequests) ~= "number" or typeof(config.timeWindow) ~= "number" then
		Log.warn("[RequestRateLimit] SetRateLimitConfig 入参非法:", msgName)
		return
	end

	RATE_LIMIT_CONFIG[msgName] = Copy.deepCopy({
		maxRequests = config.maxRequests,
		timeWindow = config.timeWindow,
	})
end

--[[
	注册或覆盖 msgName 的异常检测配置（启动期、仅服务端调用）
	@param msgName string - 消息名称（与 NetMsg 常量一致）
	@param config CheatDetectionEntry - enabled、cheatTypes、thresholds、globalThresholds；内部深拷贝
	@return nil
]]
function RequestRateLimit.SetCheatDetectionConfig(msgName: string, config: CheatDetectionEntry)
	if not IS_SERVER then
		return
	end
	if not _isValidMsgName(msgName) or typeof(config) ~= "table" or typeof(config.enabled) ~= "boolean" then
		Log.warn("[RequestRateLimit] SetCheatDetectionConfig 入参非法:", msgName)
		return
	end

	MSG_CHEAT_DETECTION_CONFIG[msgName] = Copy.deepCopy(config)
end

--[[
	查询 msgName 是否启用了异常检测
	@param msgName string - 消息名称
	@return boolean - true 表示已启用
]]
function RequestRateLimit.IsCheatDetectionEnabled(msgName: string): boolean
	if not _isValidMsgName(msgName) then
		return false
	end
	return _isCheatDetectionEnabled(msgName)
end

-- ============================================================================
-- Public API - record management
-- ============================================================================

--[[
	获取玩家异常记录快照（深拷贝，不可篡改内部状态）
	@param player Player - 目标玩家
	@return PlayerCheatRecord? - 含 totalCount、totalSeverity、records、warnCount、lastWarnTime；无记录时 nil
]]
function RequestRateLimit.GetPlayerCheatRecord(player: Player): PlayerCheatRecord?
	if not _isValidPlayer(player) then
		return nil
	end

	local record = _playerCheatRecords[player.UserId]
	if not record then
		return nil
	end

	return Copy.deepCopy(record)
end

--[[
	清除玩家请求与异常记录（调试或 GM 用，仅服务端）
	@param player Player - 目标玩家
	@return nil
]]
function RequestRateLimit.ClearPlayerCheatRecord(player: Player)
	if not IS_SERVER or not _isValidPlayer(player) then
		return
	end

	_clearPlayerRecords(player.UserId)
	Log.print(string.format("已清除玩家 %s (%d) 的异常记录", player.Name, player.UserId))
end

-- ============================================================================
-- Init
-- ============================================================================

--[[
	绑定玩家离开清理（服务端 NetWorkManager 启动时调用，幂等）
	@return nil
]]
function RequestRateLimit.Init()
	if _initialized then
		return
	end
	_initialized = true

	if not IS_SERVER then
		return
	end

	_playerRemovingConn = Players.PlayerRemoving:Connect(function(player)
		_clearPlayerRecords(player.UserId)
	end)
end

return RequestRateLimit
