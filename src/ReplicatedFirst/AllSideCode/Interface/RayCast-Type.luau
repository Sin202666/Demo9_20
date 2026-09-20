--[[
	Module: RayCast-Type
	Description: RayCast 类型声明（完整使用说明见 ToolSystem/RayCast.luau 文件头）
	Author: 林奥宇
	Created: 2026-03-02
	Last Modified: 2026-09-01
]]

local RayCast = {}

-- ============================================================================
-- 类型定义
-- ============================================================================

export type RayCastConfig = {
	filterType: Enum.RaycastFilterType?,
	collisionGroup: string?,
	instances: { Instance }?,
	ignoreWater: boolean?,
	ignoreTransparentParts: boolean?,
}

-- ============================================================================
-- 公共 API 类型定义
-- ============================================================================

--[[
	根据预设名构建独立的 RaycastParams 实例。
	不处理 ignoreTransparentParts（该字段只作用于 RayCast / RayCastDirection）。

	@param rayType string - 预设名称（Player / Enemy / Ground / All / CollisionGroup）
	@param customConfig RayCastConfig? - 覆盖预设字段；nil 时仅用预设
	@return RaycastParams - 新创建的参数对象，可安全持有与修改
]]
function RayCast.GetRayCastParams(rayType: string, customConfig: RayCastConfig?): RaycastParams
end

--[[
	两点间射线检测

	@param startPos Vector3 - 射线起点
	@param endPos Vector3 - 射线终点
	@param rayType string? - 预设名称；nil 时使用 All
	@param customConfig RayCastConfig? - 覆盖预设字段
	@return RaycastResult? - 命中结果；起终点重合或无命中时 nil
]]
function RayCast.RayCast(
	startPos: Vector3,
	endPos: Vector3,
	rayType: string?,
	customConfig: RayCastConfig?
): RaycastResult?
end

--[[
	按方向向量与最大距离射线检测

	@param origin Vector3 - 射线起点
	@param direction Vector3 - 方向向量（勿为零向量）
	@param maxDistance number - 最大检测距离（stud），必须 > 0
	@param rayType string? - 预设名称；nil 时使用 All
	@param customConfig RayCastConfig? - 覆盖预设字段
	@return RaycastResult? - 命中结果；零方向、距离非法或无命中时 nil
]]
function RayCast.RayCastDirection(
	origin: Vector3,
	direction: Vector3,
	maxDistance: number,
	rayType: string?,
	customConfig: RayCastConfig?
): RaycastResult?
end

--[[
	获取所有可用预设名称（已排序）

	@return { string } - 新数组，调用方可持有
]]
function RayCast.GetAvailablePresets(): { string }
end

return RayCast
