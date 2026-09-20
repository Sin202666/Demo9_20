--[[
	Module: SystemFeedback
	Description: 玩家反馈提交——CD 校验、文本校验、Webhook 投递与 reportTime 持久化
	Author: 林奥宇
	Created: 2026-07-03
	Last Modified: 2026-09-01

	功能：
	- SubmitFeedback：校验并投递反馈至 Discord Webhook，成功后写 reportTime
	- RegisterNetWork：注册 SUBMIT_FEEDBACK RemoteFunction，并配置 RequestRateLimit（幂等）

	调用关系：
	- UpdateManager 预加载以在入服前完成 Remote 注册（模块加载时 RegisterNetWork，避免客户端 Invoke 早于 Init）
	- 客户端 Feedback UI 通过 NetWork.InvokeServer(SUBMIT_FEEDBACK, comment) 提交
	- 本模块只写 reportTime；不发奖、不改背包

	配置（SystemGameConfig.Feedback）：
	- Webhook网址：Discord Webhook 完整 URL；空则拒绝提交
	- 反馈CD分钟：两次反馈最小间隔（分钟）

	校验：
	- 玩家须在线；comment 须为 string，去首尾空白后 UTF-8 长度 20~256
	- CD 以 SystemSave.GetStat.reportTime 与 os.time 比较
	- Remote 只回传 boolean，不回传内部错误

	加载方式（仅服务端）：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local SystemFeedback = Utils.SystemFeedback

	示例：
		local ok = SystemFeedback.SubmitFeedback(player, "反馈内容...")
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local HttpService = Utils.HttpService
local Log = Utils.Log
local NetMsg = Utils.NetMsg
local NetWork = Utils.NetWork
local SystemSave = Utils.SystemSave
local SystemRecord = Utils.SystemRecord
local RankConfig = Utils.RankConfig
local SystemGameConfig = Utils.SystemGameConfig
local TimeTransfer = Utils.TimeTransfer
local RequestRateLimit = Utils.RequestRateLimit

-- ========================================
-- 模块定义
-- ========================================
local SystemFeedback = {}

-- ========================================
-- 常量定义
-- ========================================
local MIN_TEXT_LENGTH = 20
local MAX_TEXT_LENGTH = 256
local RECORD_KEY_PLAY_TIME = RankConfig.GetRecordField(RankConfig.RANK_TIME_NAME) :: string
local STAT_KEY_REPORT_TIME = "reportTime"
local SECONDS_PER_MINUTE = 60
local RATE_LIMIT_MAX_REQUESTS = 3
local RATE_LIMIT_WINDOW_SEC = 10
local WEBHOOK_USERNAME_PREFIX = "Feedback Bot - New Feedback by "
local CONFIG_WEBHOOK_URL_PATH = { "Feedback", "Webhook网址" }
local CONFIG_CD_MINUTES_PATH = { "Feedback", "反馈CD分钟" }

-- ========================================
-- 私有变量
-- ========================================
local _webhookUrl: string = ""
local _cooldownSeconds: number = 0
local _configured = false
local _registered = false

-- ========================================
-- 私有函数
-- ========================================

--[[
	从 GameConfig 加载 Webhook 与 CD 配置
	@return nil - 无返回值
]]
local function _loadConfig()
	local webhookUrl = SystemGameConfig.GetValue(CONFIG_WEBHOOK_URL_PATH)
	_webhookUrl = if type(webhookUrl) == "string" then webhookUrl else ""

	local cdMinutes = SystemGameConfig.GetValue(CONFIG_CD_MINUTES_PATH)
	local minutes = if type(cdMinutes) == "number" then cdMinutes else 0
	_cooldownSeconds = math.max(0, minutes * SECONDS_PER_MINUTE)

	_configured = _webhookUrl ~= ""
	if not _configured then
		Log.warn("SystemFeedback: GameConfig.Feedback.Webhook网址 未配置，反馈将无法投递")
	end
end

--[[
	校验玩家对象是否在线且有效
	@param plr Player - 待校验玩家
	@return boolean - 有效为 true
]]
local function _validatePlayer(plr: Player): boolean
	return plr ~= nil and plr:IsA("Player") and plr.Parent ~= nil
end

--[[
	去掉字符串首尾空白
	@param text string - 原始字符串
	@return string - 去空白后的字符串
]]
local function _trimComment(text: string): string
	return (string.gsub(text, "^%s*(.-)%s*$", "%1"))
end

--[[
	按 UTF-8 计算文本字符数
	@param text string - 待计数字符串
	@return number - 字符数
]]
local function _utf8CharCount(text: string): number
	return utf8.len(text) or 0
end

--[[
	校验反馈文本类型与长度（调用方须已去首尾空白）
	@param comment string - 去空白后的反馈正文
	@return boolean - 合法为 true
]]
local function _validateComment(comment: string): boolean
	if type(comment) ~= "string" then
		return false
	end
	if comment == "" then
		return false
	end
	local length = _utf8CharCount(comment)
	return length >= MIN_TEXT_LENGTH and length <= MAX_TEXT_LENGTH
end

--[[
	读取玩家上次反馈 Unix 时间戳
	@param plr Player - 目标玩家
	@return number - 上次反馈时间戳；无存档字段时为 0
]]
local function _getLastReportTime(plr: Player): number
	local stat = SystemSave.GetStat(plr)
	if stat and type(stat[STAT_KEY_REPORT_TIME]) == "number" then
		return stat[STAT_KEY_REPORT_TIME]
	end
	return 0
end

--[[
	判断玩家是否处于反馈 CD 中
	@param plr Player - 目标玩家
	@return boolean - 在 CD 中为 true
]]
local function _isInCooldown(plr: Player): boolean
	if _cooldownSeconds <= 0 then
		return false
	end
	local lastReportTime = _getLastReportTime(plr)
	return os.time() - lastReportTime < _cooldownSeconds
end

--[[
	向 Webhook 投递反馈 payload
	@param plr Player - 提交玩家
	@param comment string - 去空白后的反馈正文
	@return boolean - 投递成功为 true
]]
local function _postWebhook(plr: Player, comment: string): boolean
	if _webhookUrl == "" then
		Log.warn("SystemFeedback: Webhook 未配置")
		return false
	end

	local playTimeSeconds = SystemRecord.GetDataByID(plr, RECORD_KEY_PLAY_TIME)
	local playTimeFormatted = TimeTransfer.FormatTimeS(playTimeSeconds)

	local payload = HttpService:JSONEncode({
		content = comment,
		username = WEBHOOK_USERNAME_PREFIX .. plr.Name .. "<" .. playTimeFormatted .. ">",
	})

	local ok, err = pcall(function()
		HttpService:PostAsync(_webhookUrl, payload)
	end)

	if not ok then
		Log.warn("SystemFeedback: Webhook 投递失败", plr.Name, err)
		return false
	end

	return true
end

_loadConfig()

-- ========================================
-- 公共 API
-- ========================================

--[[
	提交玩家反馈
	@param plr Player - 提交玩家
	@param comment string - 反馈正文（允许含首尾空白，内部会去掉）
	@return boolean - 提交成功为 true（Webhook 已投递）；失败为 false
]]
function SystemFeedback.SubmitFeedback(plr: Player, comment: string): boolean
	if not _configured then
		Log.warn("SystemFeedback: Webhook 未配置，拒绝提交")
		return false
	end

	if not _validatePlayer(plr) then
		return false
	end

	if type(comment) ~= "string" then
		return false
	end

	local trimmed = _trimComment(comment)
	if not _validateComment(trimmed) then
		return false
	end

	if _isInCooldown(plr) then
		return false
	end

	if not _postWebhook(plr, trimmed) then
		return false
	end

	-- Webhook 已送达：写档失败只记日志，仍返回 true，避免客户端重试导致重复投递
	local saveOk = SystemSave.ChangeStat(plr, STAT_KEY_REPORT_TIME, os.time())
	if not saveOk then
		Log.warn("SystemFeedback: reportTime 写入失败", plr.Name)
	end

	return true
end

--[[
	注册反馈相关 RemoteFunction，并配置限频（幂等；须在模块加载时调用，避免客户端 Invoke 早于 Init）
	@return nil - 无返回值
]]
function SystemFeedback.RegisterNetWork()
	if _registered then
		return
	end
	_registered = true

	if RequestRateLimit and RequestRateLimit.SetRateLimitConfig then
		RequestRateLimit.SetRateLimitConfig(NetMsg.SUBMIT_FEEDBACK, {
			maxRequests = RATE_LIMIT_MAX_REQUESTS,
			timeWindow = RATE_LIMIT_WINDOW_SEC,
		})
	end

	NetWork.RegisterServerRemoteFunction(NetMsg.SUBMIT_FEEDBACK, function(player: Player, comment: string)
		if not _validatePlayer(player) then
			Log.warn("SystemFeedback: Remote 无效玩家")
			return false
		end
		return SystemFeedback.SubmitFeedback(player, comment)
	end)
end

-- ========================================
-- 模块加载时注册通信（ServerStorage，无需 IsServer）
-- ========================================
SystemFeedback.RegisterNetWork()

return SystemFeedback
