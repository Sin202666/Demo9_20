--[[
	Module: PathFindUtil
	Description: PathfindingService 无状态封装（CreatePath + ComputeAsync）；仅供 LogicalPathFollow
	Author: 林奥宇
	Created: 2026-08-28
	Last Modified: 2026-08-28

	功能：
	- agentParamsFromBBox：AgentRadius=bbox 水平半宽，AgentHeight=bbox.Y，AgentCanJump=false（D9）
	- compute：自建 Path + ComputeAsync（会 yield）；Jump 路点只取 Position（当 Walk）
	- isDirectClear：Ground 中心水平射线，只打 workspace.场景

	与相关模块：
	- 业务禁止直接调 PathfindingService（计划 D3）
	- LogicalPathFollow 只在 task.spawn 里调 compute；禁止放进 EnemySim.step 调用栈（D18）
	- 直线可达与 Motion 挡墙同一预设 Ground；墙不在 workspace.场景 则当没墙

	约束：
	- 每次 compute 自建 CreatePath，禁止并发共用一个 Path
	- 不持有 Path 引用、不订 Blocked、不绑 Remote

	加载：
		local PathFindUtil = Utils.PathFindUtil
		local params = PathFindUtil.agentParamsFromBBox(rec.bboxSize)
		-- 仅在 task.spawn / 非 EnemySim.step 栈：
		local status, points = PathFindUtil.compute(start, dest, params)
		if PathFindUtil.isDirectClear(from, to) then
			-- 跳过 Path，直线 + M0
		end
]]

local PathfindingService = game:GetService("PathfindingService")

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local RayCast = Utils.RayCast
local Log = Utils.Log

local PathFindUtil = {}

local DEFAULT_BBOX = Vector3.new(4, 5, 4)
local MIN_AGENT_RADIUS = 0.5
local MIN_AGENT_HEIGHT = 1
local GROUND_RAY_TAG = "Ground"
--- 射线末端留皮，避免把目标点上的场景 Part 当成挡墙
local RAY_END_SKIN = 0.35

--[[
	从 bbox 得到 Agent 参数（不改传入表）
	@param bbox Vector3? - 逻辑怪全尺寸；非法则用默认 4×5×4
	@return { AgentRadius: number, AgentHeight: number, AgentCanJump: boolean } - CreatePath 用表
]]
function PathFindUtil.agentParamsFromBBox(bbox: Vector3?): { [string]: any }
	local size = bbox
	if typeof(size) ~= "Vector3" or size.X <= 0 or size.Y <= 0 or size.Z <= 0 then
		size = DEFAULT_BBOX
	end
	local radius = math.max(size.X, size.Z) * 0.5
	if radius < MIN_AGENT_RADIUS then
		radius = MIN_AGENT_RADIUS
	end
	local height = size.Y
	if height < MIN_AGENT_HEIGHT then
		height = MIN_AGENT_HEIGHT
	end
	return {
		AgentRadius = radius,
		AgentHeight = height,
		AgentCanJump = false,
	}
end

--[[
	中心水平射线是否无挡（Ground / workspace.场景）
	@param from Vector3 - 起点（权威中心）
	@param to Vector3 - 终点（Y 忽略，用 from.Y）
	@return boolean - 无命中为 true（已重叠也视为通）
]]
function PathFindUtil.isDirectClear(from: Vector3, to: Vector3): boolean
	if typeof(from) ~= "Vector3" or typeof(to) ~= "Vector3" then
		return false
	end
	local delta = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
	local dist = delta.Magnitude
	if dist <= RAY_END_SKIN then
		return true
	end
	local dir = delta.Unit
	local origin = Vector3.new(from.X, from.Y, from.Z)
	local hit = RayCast.RayCastDirection(origin, dir, dist - RAY_END_SKIN, GROUND_RAY_TAG)
	return hit == nil
end

--[[
	计算路径（会 yield）。禁止在 EnemySim.step 调用栈内调用。
	失败或非 Success 返回 status 与 nil 点列。
	@param start Vector3 - 起点
	@param dest Vector3 - 终点
	@param agentParams { AgentRadius: number?, AgentHeight: number? }? - 缺省按默认 bbox
	@return Enum.PathStatus - 引擎状态；pcall 失败视为 NoPath
	@return { Vector3 }? - 路点世界坐标（含 Jump 点位置）；失败为 nil
]]
function PathFindUtil.compute(start: Vector3, dest: Vector3, agentParams: any?): (Enum.PathStatus, { Vector3 }?)
	if typeof(start) ~= "Vector3" or typeof(dest) ~= "Vector3" then
		return Enum.PathStatus.NoPath, nil
	end
	local params = agentParams
	if type(params) ~= "table" then
		params = PathFindUtil.agentParamsFromBBox(nil)
	end
	local radius = tonumber(params.AgentRadius)
	local height = tonumber(params.AgentHeight)
	if not radius or radius <= 0 then
		radius = MIN_AGENT_RADIUS
	end
	if not height or height <= 0 then
		height = MIN_AGENT_HEIGHT
	end
	local path = PathfindingService:CreatePath({
		AgentRadius = radius,
		AgentHeight = height,
		AgentCanJump = false,
	})
	local ok, err = pcall(function()
		path:ComputeAsync(start, dest)
	end)
	if not ok then
		Log.warn("[PathFindUtil] ComputeAsync 失败:", err)
		return Enum.PathStatus.NoPath, nil
	end
	local status = path.Status
	if status ~= Enum.PathStatus.Success then
		return status, nil
	end
	local waypoints = path:GetWaypoints()
	if type(waypoints) ~= "table" or #waypoints == 0 then
		return Enum.PathStatus.NoPath, nil
	end
	local points: { Vector3 } = {}
	for i = 1, #waypoints do
		local wp = waypoints[i]
		local pos = wp and wp.Position
		if typeof(pos) == "Vector3" then
			table.insert(points, pos)
		end
	end
	if #points == 0 then
		return Enum.PathStatus.NoPath, nil
	end
	return status, points
end

return PathFindUtil
