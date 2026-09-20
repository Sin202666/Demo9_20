--[[
	Module: MathMgr
	Description: 数字格式化、单位换算、随机数与权重抽取的无状态工具库
	Author: 林奥宇
	Created: 2026-07-02
	Last Modified: 2026-09-01

	功能：
	- 大数带单位展示（K/M/B…）与单位串反解析
	- 排行榜数值编码 / 解码（与 SystemRank 成对使用）
	- 百分比 / 概率展示、四舍五入、千分符战力串
	- [0, value) / [-value, value) 随机浮点、权重抽池、数组洗牌

	与相关模块：
	- 只做展示与无状态随机，不参与发奖 / 伤害 / 掉落结算（§1.6 仍由服务端 System 定结果）
	- 排行榜存档走 SystemRank；本模块只提供 getRankNum / backRankNum 编解码
	- 时间格式化用 TimeTransfer，不要把秒数丢进 getNumStr

	加载方式：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local MathMgr = Utils.MathMgr

	示例：
		MathMgr.getNumStr(1520)           -- "1.52K"（默认 2 位小数）
		MathMgr.getNumStr0(5.6)           -- "6"（0 位四舍五入，无单位时）
		MathMgr.backRankNum(MathMgr.getRankNum(1e6))
		MathMgr.rollPoolItemByWeight({ 101, 102 }, { 70, 30 })
]]

local MathMgr = {}

-- ========================================
-- 常量定义
-- ========================================
local DECIMAL_CARRY_EPSILON = 0.9999
local DECIMAL_PLACES_DEFAULT = 2
local DECIMAL_PLACES_MAX = 3
local UNIT_GROUP_DIGITS = 3
local COMMA_GROUP_SIZE = 3
local DEFAULT_COMMA_SEPARATOR = ","
local POWER_COMMA_THRESHOLD = 999999
local RANK_ENCODE_BASE = 100000
local RANK_INT_DIGITS = 3
local RANK_FRAC_DIGITS = 2
local RANK_MANTISSA_FORMAT = "%0" .. RANK_INT_DIGITS .. "d%0" .. RANK_FRAC_DIGITS .. "d"
local PERCENT_THRESHOLD_TENTH = 0.1
local PERCENT_THRESHOLD_HUNDREDTH = 0.01
local PERCENT_THRESHOLD_THOUSANDTH = 0.001
-- getChanceStr 入参按「真实百分比」理解（0.03 表示 0.03%），分数形式需再除以 100
local CHANCE_PERCENT_SCALE = 100

local ALLOWED_DECIMAL_PLACES = {
	[0] = true,
	[1] = true,
	[2] = true,
	[3] = true,
}

-- 数字单位后缀（从千到更大；须从后往前匹配，避免 "B" 抢先吃掉 "BB"）
local UNIT_SUFFIXES = table.freeze({
	"K", "M", "B", "T", "P", "E",
	"aa", "bb", "cc", "dd", "ee", "ff", "gg", "hh", "ii", "jj", "kk",
	"ll", "mm", "nn", "oo", "pp", "qq", "rr", "ss", "tt", "uu", "vv", "ww", "xx", "yy", "zz",
	"AA", "BB", "CC", "DD", "EE", "FF", "GG", "HH", "II", "JJ", "KK",
	"LL", "MM", "NN", "OO", "PP", "QQ", "RR", "SS", "TT", "UU", "VV", "WW", "XX", "YY", "ZZ",
})

-- ========================================
-- 私有函数
-- ========================================

--[[
	按指定位数处理 modf 得到的小数部分，含进位
	scaledFrac 达到 10^decimalPlaces 时进到整数部分，避免 0.999→10 位小数溢出

	@param beforeNum number - 整数部分
	@param endNum number - 小数部分（0~1）
	@param decimalPlaces number - 保留的小数位数（0~3）
	@return number, number - 处理后的整数部分与缩放后的小数整数
]]
local function _tranEndNum(beforeNum: number, endNum: number, decimalPlaces: number): (number, number)
	if decimalPlaces <= 0 then
		return beforeNum, 0
	end
	if endNum >= DECIMAL_CARRY_EPSILON then
		return beforeNum + 1, 0
	end

	local multiplier = 10 ^ decimalPlaces
	local scaled, frac = math.modf(endNum * multiplier)
	if frac >= DECIMAL_CARRY_EPSILON then
		scaled += 1
	end
	if scaled >= multiplier then
		return beforeNum + 1, 0
	end
	return beforeNum, scaled
end

--[[
	按指定小数位数格式化数值（补前导零、去掉一位末尾 0）

	@param num number - 要格式化的数字
	@param decimalPlaces number - 小数位数；0 时四舍五入为整数
	@return string - 不含单位的格式化字符串
]]
local function _formatFixed(num: number, decimalPlaces: number): string
	if decimalPlaces <= 0 then
		local sign = if num >= 0 then 1 else -1
		return tostring(sign * math.floor(math.abs(num) + 0.5))
	end

	local beforeNum, frac = math.modf(num)
	beforeNum, frac = _tranEndNum(beforeNum, frac, decimalPlaces)
	if frac <= 0 then
		return tostring(beforeNum)
	end

	local fracStr = tostring(frac)
	while #fracStr < decimalPlaces do
		fracStr = "0" .. fracStr
	end
	if string.sub(fracStr, -1) == "0" then
		fracStr = string.sub(fracStr, 1, -2)
	end
	return beforeNum .. "." .. fracStr
end

--[[
	转换成固定 5 位数字符串（3 位整数 + 2 位小数，供排行榜编码）

	@param num number - 单位缩放后的尾数，期望落在 [1, 1000)
	@return string - 5 位数字符串
]]
local function _toRankMantissa(num: number): string
	local beforeNum, frac = math.modf(num)
	beforeNum, frac = _tranEndNum(beforeNum, frac, RANK_FRAC_DIGITS)
	return string.format(RANK_MANTISSA_FORMAT, beforeNum, frac)
end

--[[
	将整数部分转换为带千分符的格式（不处理小数）

	@param number number - 要格式化的数字
	@param separator string? - 分隔符；nil 时默认 ","
	@return string - 格式化后的字符串
]]
local function _numberWithCommas(number: number, separator: string?): string
	separator = separator or DEFAULT_COMMA_SEPARATOR

	local isNegative = number < 0
	local intPart = math.floor(math.abs(number))
	local reversed = string.reverse(tostring(intPart))
	local parts = {}

	for i = 1, #reversed, COMMA_GROUP_SIZE do
		table.insert(parts, string.sub(reversed, i, i + COMMA_GROUP_SIZE - 1))
	end

	local formatted = string.reverse(table.concat(parts, separator))
	return if isNegative then "-" .. formatted else formatted
end

--[[
	获取第 i 档单位的缩放倍数（10^(i*3)）

	@param unitIndex number - UNIT_SUFFIXES 中的单位索引
	@return number - 缩放倍数
]]
local function _getUnitScale(unitIndex: number): number
	return 10 ^ (unitIndex * UNIT_GROUP_DIGITS)
end

--[[
	按指定小数位数将数字转为带单位字符串

	@param value number? - 要转换的数字；nil / NaN / Inf 视为 0
	@param decimalPlaces number - 小数位数（0~3）
	@return string - 格式化后的字符串
]]
local function _formatNumStr(value: number?, decimalPlaces: number): string
	if value == nil then
		return "0"
	end

	local numValue = tonumber(value)
	if not numValue or numValue ~= numValue or numValue == math.huge or numValue == -math.huge then
		return "0"
	end

	local sign = ""
	if numValue < 0 then
		sign = "-"
		numValue = -numValue
	end

	for i = #UNIT_SUFFIXES, 1, -1 do
		local numDel = _getUnitScale(i)
		if numValue >= numDel then
			return sign .. _formatFixed(numValue / numDel, decimalPlaces) .. UNIT_SUFFIXES[i]
		end
	end

	return sign .. _formatFixed(numValue, decimalPlaces)
end

--[[
	将 decimalPlaces 规范到允许集合，非法时回退默认 2 位

	@param decimalPlaces number? - 调用方传入的小数位数
	@return number - 0 / 1 / 2 / 3
]]
local function _resolveDecimalPlaces(decimalPlaces: number?): number
	if decimalPlaces ~= nil and ALLOWED_DECIMAL_PLACES[decimalPlaces] then
		return decimalPlaces
	end
	return DECIMAL_PLACES_DEFAULT
end

--[[
	去除百分比字符串末尾多余零并追加 %

	@param formatted string - string.format 后的数值字符串
	@return string - 带 % 后缀的字符串
]]
local function _appendPercentSuffix(formatted: string): string
	return formatted:gsub("(%.%d*[1-9])0+$", "%1"):gsub("%.0*$", "") .. "%"
end

--[[
	按数量级格式化百分比数值（不含负号前缀）

	@param value number - 非负百分比数值
	@return string? - 格式化后的百分比字符串；数量级过小时返回 nil
]]
local function _formatPercentMagnitude(value: number): string?
	if value >= PERCENT_THRESHOLD_TENTH then
		return _appendPercentSuffix(string.format("%0.2f", value))
	end
	if value >= PERCENT_THRESHOLD_HUNDREDTH then
		return _appendPercentSuffix(string.format("%0.3f", value))
	end
	if value >= PERCENT_THRESHOLD_THOUSANDTH then
		return _appendPercentSuffix(string.format("%0.4f", value))
	end
	return nil
end

-- ========================================
-- 公共函数
-- ========================================

--[[
	将数字转换为带单位的字符串格式

	@param value number? - 要转换的数字；nil 时 "0"
	@param decimalPlaces number? - 小数位数，仅 0/1/2/3；nil 或非法时默认 2
	@return string - 格式化后的字符串（如 1.52K、2.34M）
]]
function MathMgr.getNumStr(value: number?, decimalPlaces: number?): string
	return _formatNumStr(value, _resolveDecimalPlaces(decimalPlaces))
end

--[[
	将数字转换为带单位的字符串（0 位小数，四舍五入）

	@param value number? - 要转换的数字
	@return string - 格式化后的字符串
]]
function MathMgr.getNumStr0(value: number?): string
	return _formatNumStr(value, 0)
end

--[[
	将数字转换为带单位的字符串（保留 1 位小数）

	@param value number? - 要转换的数字
	@return string - 格式化后的字符串（如 1.5K、2.3M）
]]
function MathMgr.getNumStr1(value: number?): string
	return _formatNumStr(value, 1)
end

--[[
	将数字转换为带单位的字符串（保留 3 位小数）

	@param value number? - 要转换的数字
	@return string - 格式化后的字符串（如 1.523K、2.345M）
]]
function MathMgr.getNumStr3(value: number?): string
	return _formatNumStr(value, DECIMAL_PLACES_MAX)
end

--[[
	将带单位的字符串转换回数字

	@param str string? - 带单位的字符串（如 1.5K、2.3M）；nil 时 0
	@return number - 转换后的数字；无法解析时返回 0
]]
function MathMgr.backNumStr(str: string?): number
	if not str then
		return 0
	end

	for i = #UNIT_SUFFIXES, 1, -1 do
		local key = string.find(str, UNIT_SUFFIXES[i], 1, true)
		if key then
			local num = tonumber(string.sub(str, 1, key - 1))
			if num then
				return num * _getUnitScale(i)
			end
		end
	end

	local plainNum = tonumber(str)
	if plainNum then
		return plainNum
	end

	return 0
end

--[[
	将数字转换为排行榜编码格式
	编码 = 单位档位 * 100000 + 尾数*100（5 位），供 OrderedDataStore 比较。
	同档仅约 2 位有效尾数，大数会撞码。现网榜已按此写入，禁止改算法或提高位数（会打乱旧分排序）。

	@param value number? - 原始数值
	@return number - 排行榜编码数字；无效输入返回 0
]]
function MathMgr.getRankNum(value: number?): number
	if not value then
		return 0
	end

	value = math.floor(value)

	for i = #UNIT_SUFFIXES, 1, -1 do
		local numDel = _getUnitScale(i)
		if value >= numDel then
			local encoded = i .. _toRankMantissa(value / numDel)
			return tonumber(encoded) or 0
		end
	end

	return value
end

--[[
	将排行榜编码数字转换回原始数值

	@param value number? - 排行榜编码数字
	@return number - 原始数值；无效输入返回 0
]]
function MathMgr.backRankNum(value: number?): number
	if not value then
		return 0
	end

	value = math.floor(value)

	if value < RANK_ENCODE_BASE then
		return value
	end

	local startNum = math.floor(value / RANK_ENCODE_BASE)
	local endNum = math.floor(value % RANK_ENCODE_BASE)
	return endNum * _getUnitScale(startNum) / (10 ^ RANK_FRAC_DIGITS)
end

--[[
	生成 [-value, value) 区间内的随机浮点数

	@param value number - 随机数区间半径
	@return number - [-value, value) 内的随机数
]]
function MathMgr.getRandNumSigned(value: number): number
	return -value + math.random() * (value * 2)
end

--[[
	生成 [0, value) 区间内的随机浮点数

	@param value number - 随机数上限（不含）
	@return number - [0, value) 内的随机数
]]
function MathMgr.getRandNum(value: number): number
	return math.random() * value
end

--[[
	将数值转换为百分比字符串
	传入的是真实百分比，例如 0.03 表示 0.03%

	@param value number - 百分比数值（如 0.03 表示 0.03%）
	@return string - 格式化后的百分比字符串
]]
function MathMgr.getPercentStr(value: number): string
	local prefix = ""
	if value < 0 then
		value = -value
		prefix = "-"
	end

	local formatted = _formatPercentMagnitude(value)
	if formatted then
		return prefix .. formatted
	end

	return prefix .. tostring(value) .. "%"
end

--[[
	计算并返回概率字符串
	child/parent*100 作为百分比；过小时改为 1/N 分数（N 再除以 100，与历史展示约定一致）

	@param childValue number - 子值（分子）
	@param parentValue number - 父值（分母）
	@return string - 百分比或分数形式的概率字符串
]]
function MathMgr.getChanceStr(childValue: number, parentValue: number): string
	if parentValue == 0 or childValue == 0 then
		return "0%"
	end

	local chance = childValue / parentValue * CHANCE_PERCENT_SCALE
	local formatted = _formatPercentMagnitude(chance)
	if formatted then
		return formatted
	end

	return "1/" .. MathMgr.getNumStr(parentValue / childValue / CHANCE_PERCENT_SCALE)
end

--[[
	检查随机结果是否落在指定概率范围内
	在 [0, max) 上取均匀随机数，小于 rate 视为命中；max <= 0 时恒为 false

	@param rate number - 命中阈值
	@param max number - 随机数上限（不含）
	@return boolean - 随机数小于 rate 时为 true
]]
function MathMgr.isInRate(rate: number, max: number): boolean
	if max <= 0 then
		return false
	end
	return math.random() * max < rate
end

--[[
	随机打乱数组顺序（Fisher-Yates，不修改原表）

	@param t {any}? - 要打乱的数组（1..n 连续下标，元素类型不限）；nil 时返回 nil
	@return {any}? - 打乱后的新数组；入参为 nil 时返回 nil
]]
function MathMgr.shuffleArray(t: { any }?): { any }?
	if t == nil then
		return nil
	end

	local shuffled = table.clone(t)
	for i = #shuffled, 2, -1 do
		local j = math.random(1, i)
		shuffled[i], shuffled[j] = shuffled[j], shuffled[i]
	end
	return shuffled
end

--[[
	四舍五入保留指定小数位数

	@param num number - 要处理的数字
	@param decimals number? - 保留的小数位数；nil 时视为 0
	@return number - 四舍五入后的数字
]]
function MathMgr.roundNumber(num: number, decimals: number?): number
	local factor = 10 ^ (decimals or 0)
	local sign = if num >= 0 then 1 else -1
	return sign * math.floor(math.abs(num) * factor + 0.5) / factor
end

--[[
	获取战力的数字显示形式
	小于 POWER_COMMA_THRESHOLD 使用千分符，否则使用 K/M/B 单位格式

	@param num number - 战力数值
	@return string - 格式化后的字符串
]]
function MathMgr.getPowerNumStr(num: number): string
	if num < POWER_COMMA_THRESHOLD then
		return _numberWithCommas(num)
	end
	return MathMgr.getNumStr(num)
end

--[[
	按权重从池子中随机抽取物品
	weight 与 pool 按下标一一对应；总权重 <= 0 或抽中空槽时返回 nil

	@param pool {number} - 物品 ID 列表，索引与 weight 一一对应
	@param weight {number} - 各索引对应权重，须 >= 0
	@return number? - 抽中的物品 ID；总权重 <= 0 或池为空时 nil
]]
function MathMgr.rollPoolItemByWeight(pool: { number }, weight: { number }): number?
	local totalWeight = 0
	for _, itemWeight in ipairs(weight) do
		totalWeight += itemWeight
	end

	if totalWeight <= 0 then
		return nil
	end

	local randWeight = math.random() * totalWeight
	local lastIndex: number? = nil
	for index, itemWeight in ipairs(weight) do
		if itemWeight > 0 then
			lastIndex = index
		end
		randWeight -= itemWeight
		if randWeight <= 0 then
			return pool[index]
		end
	end

	return if lastIndex then pool[lastIndex] else nil
end

return MathMgr
