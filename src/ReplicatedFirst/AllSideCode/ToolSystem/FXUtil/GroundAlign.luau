--[[
	Module: FXUtil/GroundAlign
	Description: 贴地对齐 CFrame
	Author: LinAoyu
	Created: 2024-01-01
	Last Modified: 2026-07-02
]]

return function(FXUtil)

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
-- ============================================
-- 地面对齐工具 (Ground Alignment Utilities)
-- ============================================

--[[
	计算贴地 CFrame：向下射线取法线，水平朝向在切平面投影作前向。
	适用于地面法阵、地面 AOE、贴地裂缝等需要与地表对齐的特效。
	@param planarPos Vector3 参考位置（射线从此处上方发射）
	@param flatHint Vector3 水平朝向提示（会被投影到水平面后再投影到切平面）
	@param rayTag string? RayCast 的 CollisionGroup 标签，默认 "Ground"
	@param rayUpOffset number? 射线起点相对 planarPos 的向上偏移，默认 4
	@param groundLift number? 结果位置沿法线方向的抬升量，默认 0.12
	@return CFrame? 贴地 CFrame，射线未命中则返回 nil
]]
function FXUtil.GetGroundAlignedCF(planarPos: Vector3, flatHint: Vector3, rayTag: string?, rayUpOffset: number?, groundLift: number?): CFrame?
	local tag = rayTag or "Ground"
	local upOff = rayUpOffset or 4
	local lift = groundLift or 0.12
	local RayCastMod = Utils.RayCast
	local ray = RayCastMod.RayCastDirection(planarPos + Vector3.new(0, upOff, 0), Vector3.new(0, -1, 0), 200, tag)
	if not ray then
		return nil
	end
	local up = ray.Normal
	local pos = ray.Position + up * lift
	local hint = flatHint * Vector3.new(1, 0, 1)
	if hint.Magnitude < 0.05 then
		hint = Vector3.new(0, 0, -1)
	else
		hint = hint.Unit
	end
	local fwd = hint - up * hint:Dot(up)
	if fwd.Magnitude < 0.05 then
		local aux = Vector3.yAxis:Cross(up)
		if aux.Magnitude < 0.05 then
			aux = Vector3.new(0, 0, 1):Cross(up)
		end
		if aux.Magnitude < 0.05 then
			return CFrame.new(pos)
		end
		fwd = aux.Unit
	else
		fwd = fwd.Unit
	end
	return CFrame.lookAt(pos, pos + fwd, up)
end
end