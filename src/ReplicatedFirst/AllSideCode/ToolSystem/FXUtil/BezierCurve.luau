--[[
	Module: FXUtil/BezierCurve
	Description: 贝塞尔曲线模块入口（聚合 Util + Anim）
	Author: LinAoyu
	Created: 2024-01-01
	Last Modified: 2026-07-02
]]

local BezierUtil = require(script.Parent.BezierUtil)
local BezierAnim = require(script.Parent.BezierAnim)

local BezierCurve = {}
for key, fn in BezierUtil do
	BezierCurve[key] = fn
end
for key, fn in BezierAnim do
	BezierCurve[key] = fn
end

return BezierCurve