--[[
	Module: ProjectileLinearRuntime
	Description: 直线弹道运动模板（CombatWorld Phase.Hitbox；无伤害/同步副作用）
	Author: 林奥宇
	Created: 2026-08-12
	Last Modified: 2026-08-12

	================================================================================
	使用说明
	================================================================================

	【定位】
	- 直线弹道 spawn / tick 位移 / stop；可同时驱动 Hitbox Part 与可选 Visual 模型。
	- 一律 Utils.CombatWorld.register（Phase.Hitbox）；禁止 Heartbeat:Connect。
	- 不结算伤害、不广播 Remote、不切状态机——由 SkillModule 钩子完成。

	【与同类】
	- ProjectileObjectTracking：自瞄/追踪占位，本轮不实现。
	- 样例：SkillModule/SkillDemoProjectile。

	【加载】
		local ProjectileLinearRuntime = require(script.Parent.Parent._Templates.Projectile.ProjectileLinearRuntime)
		-- 或相对 SkillModule：require(script.Parent._Templates.Projectile.ProjectileLinearRuntime)

	【示例】
		ProjectileLinearRuntime.start(skillInstance, {
			startPos = start,
			endPos = finish,
			speed = 80,
			hitbox = skillInstance.hitbox[1],
			onArrive = function() end,
		})
		-- 退出态 / 命中后：
		ProjectileLinearRuntime.stop(skillInstance)
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local CombatWorld = Utils.CombatWorld

local ProjectileLinearRuntime = {}

local DEFAULT_RUN_EVENT_KEY = "ProjectileLinear"
local DEFAULT_SPEED = 80
local DEFAULT_MAX_DISTANCE = 80

export type LinearOpts = {
	startPos: Vector3,
	flyDir: Vector3?,
	endPos: Vector3?,
	speed: number?,
	maxDistance: number?,
	hitbox: any?,
	visualModel: Instance?,
	onArrive: (() -> ())?,
	runEventKey: string?,
}

--[[
	断开 runEvent 上指定键（CombatWorld Handle 或 RBXScriptConnection）
	@param runEvent table?
	@param key string
]]
local function _disconnectRunEvent(runEvent: any, key: string)
	if type(runEvent) ~= "table" then
		return
	end
	local conn = runEvent[key]
	if conn then
		if typeof(conn) == "RBXScriptConnection" or (type(conn) == "table" and type(conn.Disconnect) == "function") then
			conn:Disconnect()
		end
		runEvent[key] = nil
	end
end

--[[
	归一化飞行方向；优先 flyDir，否则 start→end
	@param startPos Vector3
	@param flyDir Vector3?
	@param endPos Vector3?
	@return Vector3 - 单位方向；无法解析时返回 -Z
]]
local function _resolveFlyDir(startPos: Vector3, flyDir: Vector3?, endPos: Vector3?): Vector3
	if typeof(flyDir) == "Vector3" and flyDir.Magnitude > 1e-4 then
		return flyDir.Unit
	end
	if typeof(endPos) == "Vector3" then
		local delta = endPos - startPos
		if delta.Magnitude > 1e-4 then
			return delta.Unit
		end
	end
	return Vector3.new(0, 0, -1)
end

--[[
	解析最大飞行距离
	@param startPos Vector3
	@param endPos Vector3?
	@param maxDistance number?
	@return number
]]
local function _resolveMaxDistance(startPos: Vector3, endPos: Vector3?, maxDistance: number?): number
	if type(maxDistance) == "number" and maxDistance > 0 then
		return maxDistance
	end
	if typeof(endPos) == "Vector3" then
		return math.max((endPos - startPos).Magnitude, 0.01)
	end
	return DEFAULT_MAX_DISTANCE
end

--[[
	将 Hitbox / Visual 摆到世界位姿（朝向飞行方向）
	@param pos Vector3
	@param flyDir Vector3
	@param hitbox any?
	@param visualModel Instance?
]]
local function _applyPivot(pos: Vector3, flyDir: Vector3, hitbox: any?, visualModel: Instance?)
	local lookAt = pos + flyDir
	local cf = CFrame.lookAt(pos, lookAt)
	if hitbox and hitbox.hitbox and hitbox.hitbox.Parent then
		hitbox.hitbox:PivotTo(cf)
	end
	if visualModel and visualModel.Parent then
		if visualModel:IsA("Model") then
			visualModel:PivotTo(cf)
		elseif visualModel:IsA("BasePart") then
			visualModel.CFrame = cf
		end
	end
end

--[[
	停止直线弹道 Tick（幂等）
	@param skillInstance any - BaseSkill Client/Server
	@param runEventKey string? - 默认 ProjectileLinear
]]
function ProjectileLinearRuntime.stop(skillInstance: any, runEventKey: string?)
	if not skillInstance then
		return
	end
	local runData = skillInstance.skillRunData
	if not runData then
		return
	end
	local key = if type(runEventKey) == "string" and runEventKey ~= "" then runEventKey else DEFAULT_RUN_EVENT_KEY
	_disconnectRunEvent(runData.runEvent, key)
	if runData.Logic then
		runData.Logic.projectileHitboxMotion = nil
	end
end

--[[
	启动直线弹道（写入 Logic 字段并 register Phase.Hitbox）
	@param skillInstance any - BaseSkill Client/Server（需 skillRunData）
	@param opts LinearOpts - startPos 必填；flyDir 或 endPos 至少其一
	@return any? - CombatWorld Handle；失败为 nil
]]
function ProjectileLinearRuntime.start(skillInstance: any, opts: LinearOpts): any?
	if not skillInstance or type(opts) ~= "table" then
		return nil
	end
	if typeof(opts.startPos) ~= "Vector3" then
		return nil
	end

	local runData = skillInstance.skillRunData
	if type(runData) ~= "table" then
		return nil
	end
	if type(runData.runEvent) ~= "table" then
		runData.runEvent = {}
	end
	if type(runData.Logic) ~= "table" then
		runData.Logic = {}
	end

	local key = if type(opts.runEventKey) == "string" and opts.runEventKey ~= "" then opts.runEventKey else DEFAULT_RUN_EVENT_KEY
	ProjectileLinearRuntime.stop(skillInstance, key)

	local startPos = opts.startPos
	local flyDir = _resolveFlyDir(startPos, opts.flyDir, opts.endPos)
	local speed = if type(opts.speed) == "number" and opts.speed > 0 then opts.speed else DEFAULT_SPEED
	local maxDistance = _resolveMaxDistance(startPos, opts.endPos, opts.maxDistance)
	local hitbox = opts.hitbox
	local visualModel = opts.visualModel
	local onArrive = opts.onArrive

	runData.Logic.projectileLastPosition = startPos
	runData.Logic.projectileHitboxMotion = {
		startPos = startPos,
		flyDir = flyDir,
		speed = speed,
		maxDistance = maxDistance,
		traveled = 0,
	}

	_applyPivot(startPos, flyDir, hitbox, visualModel)

	local traveled = 0
	local arrived = false
	local tickId = CombatWorld.allocId("ProjectileLinear")
	local handle = CombatWorld.register(tickId, function(deltaTime: number)
		if arrived then
			return
		end
		local step = speed * math.max(deltaTime, 0)
		traveled += step
		local clamped = math.min(traveled, maxDistance)
		local pos = startPos + flyDir * clamped
		runData.Logic.projectileLastPosition = pos
		if runData.Logic.projectileHitboxMotion then
			runData.Logic.projectileHitboxMotion.traveled = clamped
		end
		_applyPivot(pos, flyDir, hitbox, visualModel)

		if traveled >= maxDistance then
			arrived = true
			ProjectileLinearRuntime.stop(skillInstance, key)
			if type(onArrive) == "function" then
				onArrive()
			end
		end
	end, CombatWorld.Phase.Hitbox)

	runData.runEvent[key] = handle
	return handle
end

return ProjectileLinearRuntime