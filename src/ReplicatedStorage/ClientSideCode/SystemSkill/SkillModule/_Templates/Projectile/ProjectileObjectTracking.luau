--[[
	Module: ProjectileObjectTracking
	Description: 弹道自瞄/追踪目标占位（本轮不做真自瞄；直线弹道见 ProjectileLinearRuntime）
	Author: 林奥宇
	Created: 2026-07-29
	Last Modified: 2026-08-28

	实现时约束：弹道 Tick 必须 Utils.CombatWorld.register，禁止 RunService.Heartbeat:Connect。
	自瞄/追踪后置；当前 getTrackTargetId / getWorldPosition 恒返回 nil。
]]

local ProjectileObjectTracking = {}

--[[
	从技能输入解析追踪目标 id（占位：未实现自瞄）
	@return any? - 恒 nil；实现后为可被 getWorldPosition 解析的目标 id
]]
function ProjectileObjectTracking.getTrackTargetIdForSkillInput(): any?
	return nil
end

--[[
	按追踪目标 id 取世界坐标（占位：未实现自瞄）
	@param _trackTargetId any - 目标 id；本迭代忽略
	@return Vector3? - 恒 nil；实现后为世界位置
]]
function ProjectileObjectTracking.getWorldPositionByTrackTargetId(_trackTargetId: any): Vector3?
	return nil
end

return ProjectileObjectTracking