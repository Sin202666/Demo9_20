--[[
	Module: Range
	Description: 从 NumberRange 均匀抽样一个标量，供 PartIcles 发射/动画路径共用
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-09-01

	功能：
	- RandomValueFromRange：Min==Max 时直接返回该值，否则在闭区间内均匀随机

	模块关系：
	- 被 Emit / EmitAnimate / EmitModel / Engine / PointLight / ScreenEmit / Flipbook /
	  TrailEmitter / Highlight / ImageEmit / PartConstants 等只读调用
	- 不持有状态、不写权威数据、不访问 DataStore / Remote

	加载方式：
		local Range = require(script.Parent.Range)
		-- 或由兄弟模块 require(script.Parent.Range)

	使用示例：
		local life = Range.RandomValueFromRange(data.Lifetime)
]]

local Range = {}

--[[
	从 NumberRange 均匀抽样。Min 与 Max 相等时跳过随机，避免无意义的 math.random。

	@param range NumberRange - 闭区间 [Min, Max]；调用方须保证已是 NumberRange
	@return number - 区间内的标量；相等时即 Min
]]
function Range.RandomValueFromRange(range: NumberRange)
	if range.Min == range.Max then return range.Min end
	return range.Min + ((range.Max - range.Min) * math.random())
end

return Range
