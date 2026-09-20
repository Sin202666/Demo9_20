--!strict
--[[
	Module: TimeTransfer
	Description: 秒数 / Unix 时间戳转展示串的无状态工具库
	Author: 林奥宇
	Created: 2026-07-02
	Last Modified: 2026-09-01

	功能：
	- HH:MM:SS / HH:MM / MM:SS 固定时钟格式（小时/分钟可超过 24/60，适合倒计时）
	- 紧凑单位串（1d 2h 3m）、排行榜「天+小时」、单一最大单位
	- Unix 时间戳转 YYYY/MM/DD（邮件 / 公告日期）

	与相关模块：
	- 只做展示格式化，不参与发奖 / 倒计时结算 / 存档（§1.6 仍由服务端 System 定结果）
	- 数字带单位用 MathMgr；本模块只处理时长与日历日期
	- 倒计时 UI 优先 FormatTime（已有 SetRawText 用法）
	- 时长榜 UI 用 GetRankDurationParts + TranslationHelper.SetText("排行榜时长", {天, 小时})
	- UniqueTimeStringRank 仍是英文 "1d 2h"，仅日志 / 非玩家可见场景

	加载方式：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local TimeTransfer = Utils.TimeTransfer

	示例：
		TimeTransfer.FormatTime(3661)                    -- "01:01:01"
		TimeTransfer.FormatTimeS(90061)                  -- "1d 1h 1m"
		TimeTransfer.GetRankDurationParts(90000)         -- 1, 1（天, 小时）
		TimeTransfer.FormatUnixTimestampToYMD(1713974400) -- "2024/04/24"
]]

local TimeTransfer = {}

-- ========================================
-- 常量定义
-- ========================================
local SECONDS_PER_MINUTE = 60
local SECONDS_PER_HOUR = 3600
local SECONDS_PER_DAY = 86400
local HOURS_PER_DAY = 24
-- JS Date.now() 量级；大于此值按毫秒再除 1000
local UNIX_MILLIS_THRESHOLD = 1e12
-- 2001-09-09；更早不当日历日期展示（避免把时长误当成时间戳）
local UNIX_SECONDS_DISPLAY_MIN = 1_000_000_000
local INVALID_DATE_PLACEHOLDER = "—"

-- UniqueTimeString 英文单位（历史 API；玩家可见倒计时请用 FormatTime / FormatTimeS）
local UNIT_SEC = " Sec"
local UNIT_MIN = " Min"
local UNIT_HOUR = " Hour"
local UNIT_DAY = " Day"

-- ========================================
-- 私有函数
-- ========================================

--[[
	将入参收成非负有限秒数；NaN / Inf 按 0

	@param seconds number - 原始秒数，可为负、NaN、Inf
	@return number - 非负有限秒数
]]
local function _clampSeconds(seconds: number): number
	if seconds ~= seconds or seconds == math.huge or seconds == -math.huge then
		return 0
	end
	return math.max(0, seconds)
end

--[[
	拆成「总小时 + 余分钟 + 余秒」（小时不封顶，供 HH:MM:SS / HH:MM）

	@param seconds number - 原始秒数；负值 / NaN / Inf 按 0
	@return number, number, number - 总小时、余分钟（0–59）、余秒（0–59）
]]
local function _splitClock(seconds: number): (number, number, number)
	local currentTime = _clampSeconds(seconds)
	local hours = math.floor(currentTime / SECONDS_PER_HOUR)
	local minutes = math.floor(currentTime / SECONDS_PER_MINUTE) % SECONDS_PER_MINUTE
	local secs = math.floor(currentTime) % SECONDS_PER_MINUTE
	return hours, minutes, secs
end

--[[
	拆成「天 + 日内小时 + 余分钟 + 余秒」（小时 0–23，供带天的单位串）

	@param seconds number - 原始秒数；负值 / NaN / Inf 按 0
	@return number, number, number, number - 天、小时（0–23）、分钟（0–59）、秒（0–59）
]]
local function _splitDuration(seconds: number): (number, number, number, number)
	local currentTime = _clampSeconds(seconds)
	local secs = math.floor(currentTime) % SECONDS_PER_MINUTE
	local minutes = math.floor(currentTime / SECONDS_PER_MINUTE) % SECONDS_PER_MINUTE
	local hours = math.floor(currentTime / SECONDS_PER_HOUR) % HOURS_PER_DAY
	local days = math.floor(currentTime / SECONDS_PER_DAY)
	return days, hours, minutes, secs
end

-- ========================================
-- 公共函数
-- ========================================

--[[
	格式化为 HH:MM:SS。小时为累计值，可超过 24（倒计时用，不用「天」）

	@param seconds number - 秒数；负值 / NaN / Inf 按 0
	@return string - 如 "01:01:01"、"25:00:00"
]]
function TimeTransfer.FormatTime(seconds: number): string
	local hours, minutes, secs = _splitClock(seconds)
	return string.format("%02d:%02d:%02d", hours, minutes, secs)
end

--[[
	格式化为 HH:MM。小时为累计值，可超过 24；不显示秒

	@param seconds number - 秒数；负值 / NaN / Inf 按 0
	@return string - 如 "01:01"、"25:00"
]]
function TimeTransfer.FormatTimeM(seconds: number): string
	local hours, minutes = _splitClock(seconds)
	return string.format("%02d:%02d", hours, minutes)
end

--[[
	格式化为 MM:SS。分钟为累计值，不封顶到 60

	@param seconds number - 秒数；负值 / NaN / Inf 按 0
	@return string - 如 "01:30"、"90:00"
]]
function TimeTransfer.FormatTimeMMSS(seconds: number): string
	local currentTime = _clampSeconds(seconds)
	local minutes = math.floor(currentTime / SECONDS_PER_MINUTE)
	local secs = math.floor(currentTime) % SECONDS_PER_MINUTE
	return string.format("%02d:%02d", minutes, secs)
end

--[[
	紧凑单位串：只拼非零单位，片段之间一个空格。
	有天数时不显示秒，避免过长；全零返回空串。
	Webhook / 非 UI 日志可用；倒计时 UI 优先 FormatTime。

	@param seconds number - 秒数；负值 / NaN / Inf 按 0
	@return string - 如 "1d 2h 3m"、"2h 3m 4s"；全零为 ""
]]
function TimeTransfer.FormatTimeS(seconds: number): string
	local days, hours, minutes, secs = _splitDuration(seconds)
	local parts: { string } = {}
	if days > 0 then
		table.insert(parts, string.format("%dd", days))
	end
	if hours > 0 then
		table.insert(parts, string.format("%dh", hours))
	end
	if minutes > 0 then
		table.insert(parts, string.format("%dm", minutes))
	end
	if days <= 0 and secs > 0 then
		table.insert(parts, string.format("%ds", secs))
	end
	return table.concat(parts, " ")
end

--[[
	自动选最大合适单位的英文串（历史 API）。
	单位词是英文 Sec/Min/Hour/Day，不宜直接给玩家可见倒计时；请用 FormatTime / FormatTimeS。

	@param seconds number - 秒数；负值 / NaN / Inf 按 0；秒档向下取整
	@return string - 如 "30 Sec"、"5 Min"、"2 Hour"、"1 Day"
]]
function TimeTransfer.UniqueTimeString(seconds: number): string
	local currentTime = _clampSeconds(seconds)
	if currentTime < SECONDS_PER_MINUTE then
		return tostring(math.floor(currentTime)) .. UNIT_SEC
	elseif currentTime < SECONDS_PER_HOUR then
		return tostring(math.ceil(currentTime / SECONDS_PER_MINUTE)) .. UNIT_MIN
	elseif currentTime < SECONDS_PER_DAY then
		return tostring(math.ceil(currentTime / SECONDS_PER_HOUR)) .. UNIT_HOUR
	else
		return tostring(math.ceil(currentTime / SECONDS_PER_DAY)) .. UNIT_DAY
	end
end

--[[
	排行榜时长拆成天 + 日内小时。UI 请 SetText("排行榜时长", { tostring(days), tostring(hours) })。

	@param seconds number - 秒数；负值 / NaN / Inf 按 0
	@return number, number - 天、小时（0–23）
]]
function TimeTransfer.GetRankDurationParts(seconds: number): (number, number)
	local days, hours = _splitDuration(seconds)
	return days, hours
end

--[[
	排行榜时长英文串（"1d 2h"）。玩家可见格子请用 GetRankDurationParts + 翻译键。

	@param seconds number - 秒数；负值 / NaN / Inf 按 0
	@return string - 如 "1d 2h"
]]
function TimeTransfer.UniqueTimeStringRank(seconds: number): string
	local days, hours = TimeTransfer.GetRankDurationParts(seconds)
	return string.format("%dd %dh", days, hours)
end

-- 兼容旧 API 命名；新代码请用 UniqueTimeStringRank
TimeTransfer.UniqueTimeString_Rank = TimeTransfer.UniqueTimeStringRank

--[[
	天 / 小时 / 分钟单位串（hrs/mins 历史拼写）。只拼非零单位；全零返回空串。

	@param seconds number - 秒数；负值 / NaN / Inf 按 0
	@return string - 如 "1d 2hrs 3mins"；全零为 ""
]]
function TimeTransfer.FormatTimeMins(seconds: number): string
	local days, hours, minutes = _splitDuration(seconds)
	local parts: { string } = {}
	if days > 0 then
		table.insert(parts, string.format("%dd", days))
	end
	if hours > 0 then
		table.insert(parts, string.format("%dhrs", hours))
	end
	if minutes > 0 then
		table.insert(parts, string.format("%dmins", minutes))
	end
	return table.concat(parts, " ")
end

--[[
	将 Unix 时间戳格式化为 YYYY/MM/DD（邮件 / 公告日期）。
	存库 / Record 仍用原始数字，仅展示时调用。
	os.date 按时区为运行环境本地（游戏服一般是 UTC）。
	非法、非正、NaN / Inf 返回 "—"；低于 UNIX_SECONDS_DISPLAY_MIN 返回原始 tostring（避免把时长当日期）。

	@param unixTimestamp number? - Unix 秒或毫秒；nil / 非数字按非法
	@return string - 如 "2026/04/24"；非法为 "—"；过早时间戳为原始输入的 tostring
]]
function TimeTransfer.FormatUnixTimestampToYMD(unixTimestamp: number?): string
	local t = tonumber(unixTimestamp)
	if not t or t <= 0 or t ~= t or t == math.huge then
		return INVALID_DATE_PLACEHOLDER
	end
	if t > UNIX_MILLIS_THRESHOLD then
		t = t / 1000
	end
	t = math.floor(t)
	if t < UNIX_SECONDS_DISPLAY_MIN then
		return tostring(unixTimestamp)
	end
	local formatted = os.date("%Y/%m/%d", t)
	if type(formatted) ~= "string" then
		return INVALID_DATE_PLACEHOLDER
	end
	return formatted
end

return TimeTransfer
