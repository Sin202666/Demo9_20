--[[
	Module: TimeTransfer-Type
	Description: TimeTransfer 类型声明（完整使用说明见 ToolBasic/TimeTransfer.luau 文件头）
	Author: 林奥宇
	Created: 2026-07-02
	Last Modified: 2026-09-01
]]

local TimeTransfer = {}

--[[
	格式化为 HH:MM:SS。小时为累计值，可超过 24（倒计时用，不用「天」）

	@param seconds number - 秒数；负值 / NaN / Inf 按 0
	@return string - 如 "01:01:01"、"25:00:00"
]]
function TimeTransfer.FormatTime(seconds: number): string
end

--[[
	格式化为 HH:MM。小时为累计值，可超过 24；不显示秒

	@param seconds number - 秒数；负值 / NaN / Inf 按 0
	@return string - 如 "01:01"、"25:00"
]]
function TimeTransfer.FormatTimeM(seconds: number): string
end

--[[
	格式化为 MM:SS。分钟为累计值，不封顶到 60

	@param seconds number - 秒数；负值 / NaN / Inf 按 0
	@return string - 如 "01:30"、"90:00"
]]
function TimeTransfer.FormatTimeMMSS(seconds: number): string
end

--[[
	紧凑单位串：只拼非零单位，片段之间一个空格。
	有天数时不显示秒，避免过长；全零返回空串。

	@param seconds number - 秒数；负值 / NaN / Inf 按 0
	@return string - 如 "1d 2h 3m"、"2h 3m 4s"；全零为 ""
]]
function TimeTransfer.FormatTimeS(seconds: number): string
end

--[[
	自动选最大合适单位的英文串（历史 API）。
	单位词是英文 Sec/Min/Hour/Day，不宜直接给玩家可见倒计时；请用 FormatTime / FormatTimeS。

	@param seconds number - 秒数；负值 / NaN / Inf 按 0；秒档向下取整
	@return string - 如 "30 Sec"、"5 Min"、"2 Hour"、"1 Day"
]]
function TimeTransfer.UniqueTimeString(seconds: number): string
end

--[[
	排行榜时长拆成天 + 日内小时。UI 请 SetText("排行榜时长", { tostring(days), tostring(hours) })。

	@param seconds number - 秒数；负值 / NaN / Inf 按 0
	@return number, number - 天、小时（0–23）
]]
function TimeTransfer.GetRankDurationParts(seconds: number): (number, number)
end

--[[
	排行榜时长英文串（"1d 2h"）。玩家可见格子请用 GetRankDurationParts + 翻译键。

	@param seconds number - 秒数；负值 / NaN / Inf 按 0
	@return string - 如 "1d 2h"
]]
function TimeTransfer.UniqueTimeStringRank(seconds: number): string
end

--[[
	UniqueTimeStringRank 的兼容别名；新代码请用 UniqueTimeStringRank

	@param seconds number - 秒数；负值 / NaN / Inf 按 0
	@return string - 如 "1d 2h"
]]
function TimeTransfer.UniqueTimeString_Rank(seconds: number): string
end

--[[
	天 / 小时 / 分钟单位串（hrs/mins 历史拼写）。只拼非零单位；全零返回空串。

	@param seconds number - 秒数；负值 / NaN / Inf 按 0
	@return string - 如 "1d 2hrs 3mins"；全零为 ""
]]
function TimeTransfer.FormatTimeMins(seconds: number): string
end

--[[
	将 Unix 时间戳格式化为 YYYY/MM/DD（邮件 / 公告日期）。
	非法、非正、NaN / Inf 返回 "—"；低于约 2001-09-09 的秒时间戳返回原始 tostring。

	@param unixTimestamp number? - Unix 秒或毫秒；nil / 非数字按非法
	@return string - 如 "2026/04/24"；非法为 "—"；过早时间戳为原始输入的 tostring
]]
function TimeTransfer.FormatUnixTimestampToYMD(unixTimestamp: number?): string
end

return TimeTransfer
