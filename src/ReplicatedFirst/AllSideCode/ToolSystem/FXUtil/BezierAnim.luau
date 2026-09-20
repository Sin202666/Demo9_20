--[[
	Module: FXUtil/BezierAnim
	Description: 贝塞尔曲线轨迹动画聚合入口（Basic + LookAt + Multi）
	Author: LinAoyu
	Created: 2024-01-01
	Last Modified: 2026-07-02
]]

local BezierAnimBasic = require(script.Parent.BezierAnimBasic)
local BezierAnimLookAt = require(script.Parent.BezierAnimLookAt)
local BezierAnimMulti = require(script.Parent.BezierAnimMulti)

local BezierAnim = {}
for key, fn in BezierAnimBasic do
	BezierAnim[key] = fn
end
for key, fn in BezierAnimLookAt do
	BezierAnim[key] = fn
end
for key, fn in BezierAnimMulti do
	BezierAnim[key] = fn
end

return BezierAnim