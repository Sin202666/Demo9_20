local module = {}

--[[
	将数字转换为带单位的字符串格式

	@param value number? - 要转换的数字；nil 时 "0"
	@param decimalPlaces number? - 小数位数，仅 0/1/2/3；nil 或非法时默认 2
	@return string - 格式化后的字符串
]]
function module.getNumStr(value: number?, decimalPlaces: number?): string
end

--[[
	将数字转换为带单位的字符串（0 位小数，四舍五入）

	@param value number? - 要转换的数字
	@return string - 格式化后的字符串
]]
function module.getNumStr0(value: number?): string
end

--[[
	将数字转换为带单位的字符串（保留 1 位小数）

	@param value number? - 要转换的数字
	@return string - 格式化后的字符串
]]
function module.getNumStr1(value: number?): string
end

--[[
	将数字转换为带单位的字符串（保留 3 位小数）

	@param value number? - 要转换的数字
	@return string - 格式化后的字符串
]]
function module.getNumStr3(value: number?): string
end

--[[
	将带单位的字符串转换回数字

	@param str string? - 带单位的字符串；nil 时 0
	@return number - 转换后的数字；无法解析时 0
]]
function module.backNumStr(str: string?): number
end

--[[
	将数字转换为排行榜编码格式

	@param value number? - 原始数值
	@return number - 排行榜编码数字；无效输入返回 0
]]
function module.getRankNum(value: number?): number
end

--[[
	将排行榜编码数字转换回原始数值

	@param value number? - 排行榜编码数字
	@return number - 原始数值；无效输入返回 0
]]
function module.backRankNum(value: number?): number
end

--[[
	生成 [-value, value) 区间内的随机浮点数

	@param value number - 随机数区间半径
	@return number - [-value, value) 内的随机数
]]
function module.getRandNumSigned(value: number): number
end

--[[
	生成 [0, value) 区间内的随机浮点数

	@param value number - 随机数上限（不含）
	@return number - [0, value) 内的随机数
]]
function module.getRandNum(value: number): number
end

--[[
	将数值转换为百分比字符串

	@param value number - 百分比数值（如 0.03 表示 0.03%）
	@return string - 百分比字符串
]]
function module.getPercentStr(value: number): string
end

--[[
	计算并返回概率字符串

	@param childValue number - 子值（分子）
	@param parentValue number - 父值（分母）
	@return string - 概率字符串
]]
function module.getChanceStr(childValue: number, parentValue: number): string
end

--[[
	检查随机结果是否落在指定概率范围内

	@param rate number - 命中阈值
	@param max number - 随机数上限（不含）；<= 0 时恒为 false
	@return boolean - 是否命中
]]
function module.isInRate(rate: number, max: number): boolean
end

--[[
	随机打乱数组顺序（不修改原表）

	@param t {any}? - 要打乱的数组（1..n 连续下标，元素类型不限）；nil 时返回 nil
	@return {any}? - 打乱后的新数组
]]
function module.shuffleArray(t: { any }?): { any }?
end

--[[
	四舍五入保留指定小数位数

	@param num number - 数字
	@param decimals number? - 小数位数；nil 时视为 0
	@return number - 四舍五入后的数字
]]
function module.roundNumber(num: number, decimals: number?): number
end

--[[
	获取战力的数字显示形式

	@param num number - 战力数值
	@return string - 格式化后的字符串
]]
function module.getPowerNumStr(num: number): string
end

--[[
	按权重从池子中随机抽取物品

	@param pool {number} - 物品 ID 列表，索引与 weight 对应
	@param weight {number} - 各索引对应权重，须 >= 0
	@return number? - 抽中的物品 ID；总权重 <= 0 时 nil
]]
function module.rollPoolItemByWeight(pool: { number }, weight: { number }): number?
end

return module
