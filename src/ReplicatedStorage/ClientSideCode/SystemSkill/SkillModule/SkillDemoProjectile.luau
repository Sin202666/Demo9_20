--[[
	Module: SkillDemoProjectile
	Description: 直线弹道样例（撞敌/撞障停飞 + 服权伤害 + Path/Hit 同步）
	Author: 林奥宇
	Created: 2026-08-12
	Last Modified: 2026-08-31

	主流程：Startup -> ProjectileFlying -> Recovery -> Finished
	- 服务端：裁决路径 fireProjectilePathConfirmed；Hitbox 随 ProjectileLinearRuntime 飞行；
	  onProjectileHitServer / Server_UpdateProjectileObstacleCheck → ImpactResolver + HitConfirmed
	- 客户端：简易 Part 表现；onServerEvent 对齐 Path/Hit；无客户端 Hitbox
	- 禁止 Heartbeat:Connect；运动一律 CombatWorld.register（模板 Phase.Hitbox）

	加载：由框架按 SkillModule 名 require；组模块 GroupSkillModule/SkillDemoProjectile
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Class = require(game.ReplicatedFirst.AllSideCode.Class.Class)
local ElementTp = Utils.EnumMgr.ElementTp
local HitResolver = Utils.HitResolver
local EVT = require(script.Parent.Parent.BaseSkill.SkillEventConst)
local SYNC = EVT.SyncEventType
local ImpactContext = require(script.Parent.Parent.BaseSkill.ImpactContext)
local ImpactResolver = require(script.Parent.Parent.BaseSkill.ImpactResolver)
local FriendlyRayUtil = require(script.Parent.Parent.BaseSkill.FriendlyRayUtil)
local PlayerAimSync = require(script.Parent.Parent.BaseSkill.PlayerAimSync)
local ProjectileLinearRuntime = require(script.Parent._Templates.Projectile.ProjectileLinearRuntime)

type BaseSkillClient = Class.BaseSkillClient
type BaseSkillServer = Class.BaseSkillServer

local module = {}

-- ========================================
-- 常量
-- ========================================
local STARTUP_DURATION = 0.15
local RECOVERY_DURATION = 0.25
local PROJECTILE_SPEED = 90
local PROJECTILE_MAX_DISTANCE = 72
local HITBOX_SIZE = Vector3.new(3.5, 3.5, 3.5)
local VISUAL_SIZE = Vector3.new(1.2, 1.2, 1.2)
local VISUAL_COLOR = Color3.fromRGB(120, 200, 255)
local RUN_KEY = "ProjectileLinear"
local VISUAL_NAME = "SkillDemoProjectileBolt"

-- 飞行态最长 = 距离/速度 + 缓冲（StateTimeout 兜底）
local FLY_DURATION = PROJECTILE_MAX_DISTANCE / PROJECTILE_SPEED + 0.35

module.skillTotalTime = -1
module.visualFadeoutTime = 0.4
module.skillElementType = ElementTp.None
module.skillDistanceLimit = PROJECTILE_MAX_DISTANCE

module.InitialState = "Startup"
module.ControlOpenState = "ProjectileFlying"

module.States = {
	Startup = {
		Duration = STARTUP_DURATION,
		OnEnterClient = nil,
		OnEnterServer = "Server_EnterStartup",
		OnExitClient = nil,
		OnExitServer = nil,
	},
	ProjectileFlying = {
		Duration = FLY_DURATION,
		OnEnterClient = "Client_EnterProjectileFlying",
		OnEnterServer = "Server_EnterProjectileFlying",
		OnExitClient = "Client_ExitProjectileFlying",
		OnExitServer = "Server_ExitProjectileFlying",
	},
	Recovery = {
		Duration = RECOVERY_DURATION,
		OnEnterClient = "Client_EnterRecovery",
		OnEnterServer = "Server_EnterRecovery",
		OnExitClient = nil,
		OnExitServer = nil,
	},
	Finished = { Duration = 0, IsTerminal = true },
	Interrupted = { Duration = 0, IsTerminal = true },
}

module.Transitions = {
	{ From = "Startup", To = "ProjectileFlying", Event = EVT.StateTimeout },
	{ From = "ProjectileFlying", To = "Recovery", Event = EVT.StateTimeout },
	{ From = "ProjectileFlying", To = "Recovery", Event = EVT.EnemyHit },
	{ From = "ProjectileFlying", To = "Recovery", Event = EVT.ObstacleHit },
	{ From = "ProjectileFlying", To = "Recovery", Event = EVT.Timeout },
	{ From = "Recovery", To = "Finished", Event = EVT.StateTimeout },
	{ From = "Startup", To = "Interrupted", Event = EVT.Interrupt },
	{ From = "ProjectileFlying", To = "Interrupted", Event = EVT.Interrupt },
	{ From = "Recovery", To = "Interrupted", Event = EVT.Interrupt },
	{ From = "Startup", To = "Finished", Event = EVT.ForceFinish },
	{ From = "ProjectileFlying", To = "Finished", Event = EVT.ForceFinish },
	{ From = "Recovery", To = "Finished", Event = EVT.ForceFinish },
}

module.hitboxConfig = {
	{
		HitboxIndex = 1,
		PartName = "通用球",
		CollisionGroup = "Hitbox",
		ActiveRange = NumberRange.new(0, 0),
		HitPolicy = {
			hitOncePerTarget = true,
			stopOnFirstEnemy = true,
			stopOnObstacle = true,
		},
	},
}

module.AnimateList = {}
module.Action = {}
module.ResNameList = {}

-- ========================================
-- 私有
-- ========================================

--[[
	从瞄准/朝向构建直线路径
	@param Data BaseSkillServer|BaseSkillClient - 技能实例（读 skillInputData.releaseCF/targetCF）
	@return Vector3 - 起点
	@return Vector3 - 终点（起点 + 方向 * PROJECTILE_MAX_DISTANCE）
	@return Vector3 - 单位飞行方向
]]
local function _buildShootPath(Data: any): (Vector3, Vector3, Vector3)
	local input = Data.skillInputData
	local releaseCF = input and input.releaseCF
	local targetCF = input and input.targetCF
	local startPos: Vector3
	if typeof(releaseCF) == "CFrame" then
		startPos = releaseCF.Position + releaseCF.LookVector * 2 + Vector3.new(0, 1.5, 0)
	elseif Data.character and Data.character:FindFirstChild("HumanoidRootPart") then
		local hrp = Data.character.HumanoidRootPart
		startPos = hrp.Position + hrp.CFrame.LookVector * 2 + Vector3.new(0, 1.5, 0)
	else
		startPos = Vector3.zero
	end

	local flyDir: Vector3
	if typeof(targetCF) == "CFrame" then
		local delta = targetCF.Position - startPos
		if delta.Magnitude > 1e-3 then
			flyDir = delta.Unit
		elseif typeof(releaseCF) == "CFrame" then
			flyDir = releaseCF.LookVector
		else
			flyDir = Vector3.new(0, 0, -1)
		end
	elseif typeof(releaseCF) == "CFrame" then
		flyDir = releaseCF.LookVector
	else
		flyDir = Vector3.new(0, 0, -1)
	end
	if flyDir.Magnitude < 1e-4 then
		flyDir = Vector3.new(0, 0, -1)
	else
		flyDir = flyDir.Unit
	end

	local endPos = startPos + flyDir * PROJECTILE_MAX_DISTANCE
	return startPos, endPos, flyDir
end

--[[
	销毁客户端视觉弹体
	@param Data BaseSkillClient - 客户端技能实例
]]
local function _destroyVisual(Data: BaseSkillClient)
	local runData = Data.skillRunData
	if not runData or not runData.Visual then
		return
	end
	local model = runData.Visual.projectileModel
	if model then
		pcall(function()
			model:Destroy()
		end)
		runData.Visual.projectileModel = nil
	end
end

--[[
	创建简易弹体 Part（无 ModelRes 依赖）
	@param Data BaseSkillClient - 客户端技能实例
	@param startPos Vector3 - 弹体起点
	@param flyDir Vector3 - 飞行方向（单位向量）
	@return BasePart? - 新建视觉 Part；runData 缺失为 nil
]]
local function _ensureVisual(Data: BaseSkillClient, startPos: Vector3, flyDir: Vector3): BasePart?
	local runData = Data.skillRunData
	if not runData or not runData.Visual then
		return nil
	end
	_destroyVisual(Data)
	local part = Instance.new("Part")
	part.Name = VISUAL_NAME
	part.Size = VISUAL_SIZE
	part.Color = VISUAL_COLOR
	part.Material = Enum.Material.Neon
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.CFrame = CFrame.lookAt(startPos, startPos + flyDir)
	part.Parent = workspace.Debris
	runData.Visual.projectileModel = part
	return part
end

--[[
	停飞并停 Hitbox（服务端）
	@param Data BaseSkillServer - 服务端技能实例
]]
local function _stopFlightServer(Data: BaseSkillServer)
	ProjectileLinearRuntime.stop(Data, RUN_KEY)
	local hitbox1 = Data.hitbox and Data.hitbox[1]
	if hitbox1 and hitbox1.stop then
		hitbox1:stop()
	end
end

--[[
	超时/到达终点：ImpactResolver Timeout
	@param Data BaseSkillServer - 服务端技能实例
]]
local function _resolveTimeout(Data: BaseSkillServer)
	if not Data or not Data:isRunningFlow() then
		return
	end
	local runData = Data.skillRunData
	if runData and runData.Logic and runData.Logic.hasExploded then
		return
	end
	local pos = (runData and runData.Logic and runData.Logic.projectileLastPosition) or Vector3.zero
	local ctx = ImpactContext.fromImpact({
		type = "Timeout",
		position = pos,
		target = nil,
		source = "Arrive",
	})
	_stopFlightServer(Data)
	ImpactResolver.resolveImpact(ctx, Data)
end

--[[
	客户端按路径启动/校正视觉飞行
	@param Data BaseSkillClient - 客户端技能实例
	@param startPos Vector3 - 起点
	@param endPos Vector3 - 终点
	@param flyDir Vector3 - 飞行方向
]]
local function _startClientFlight(Data: BaseSkillClient, startPos: Vector3, endPos: Vector3, flyDir: Vector3)
	local visual = _ensureVisual(Data, startPos, flyDir)
	local maxDist = (endPos - startPos).Magnitude
	if maxDist < 0.01 then
		maxDist = PROJECTILE_MAX_DISTANCE
	end
	ProjectileLinearRuntime.start(Data, {
		startPos = startPos,
		endPos = endPos,
		flyDir = flyDir,
		speed = PROJECTILE_SPEED,
		maxDistance = maxDist,
		visualModel = visual,
		runEventKey = RUN_KEY,
	})
end

-- ========================================
-- 服务端
-- ========================================

--[[
	进入 Startup：刷新瞄准快照
	@param Data BaseSkillServer - 服务端技能实例
]]
function module.Server_EnterStartup(Data: BaseSkillServer)
	PlayerAimSync.refreshAimSnapshot(Data)
end

--[[
	进入飞行：确认路径、启动 Hitbox 与 CombatWorld 弹道
	@param Data BaseSkillServer - 服务端技能实例
]]
function module.Server_EnterProjectileFlying(Data: BaseSkillServer)
	PlayerAimSync.refreshAimSnapshot(Data)

	local hitbox1 = Data.hitbox and Data.hitbox[1]
	if not hitbox1 or not hitbox1.hitbox then
		return
	end

	local startPos, endPos, flyDir = _buildShootPath(Data)
	Data:fireProjectilePathConfirmed(1, startPos, endPos, flyDir)

	hitbox1.hitbox.Size = HITBOX_SIZE
	hitbox1.hitbox:PivotTo(CFrame.lookAt(startPos, startPos + flyDir))
	hitbox1:start(true)

	ProjectileLinearRuntime.start(Data, {
		startPos = startPos,
		endPos = endPos,
		flyDir = flyDir,
		speed = PROJECTILE_SPEED,
		maxDistance = PROJECTILE_MAX_DISTANCE,
		hitbox = hitbox1,
		runEventKey = RUN_KEY,
		onArrive = function()
			_resolveTimeout(Data)
		end,
	})
end

--[[
	退出飞行：停 Hitbox 与弹道
	@param Data BaseSkillServer - 服务端技能实例
]]
function module.Server_ExitProjectileFlying(Data: BaseSkillServer)
	_stopFlightServer(Data)
end

--[[
	进入 Recovery：停飞并放权
	@param Data BaseSkillServer - 服务端技能实例
]]
function module.Server_EnterRecovery(Data: BaseSkillServer)
	_stopFlightServer(Data)
	if Data.releaseControl then
		Data:releaseControl()
	end
end

--[[
	弹道中途命中敌人（接管默认 applyHit）
	@param Data BaseSkillServer - 服务端技能实例
	@param hitbox any - 命中所用 Hitbox 条目
	@param result { [Model | number]: BasePart | Vector3 } - 重叠结果：键为 Model 或逻辑怪 id
]]
function module.onProjectileHitServer(Data: BaseSkillServer, hitbox: any, result: any)
	if not Data or not result then
		return
	end
	local runData = Data.skillRunData
	if runData and runData.Logic and runData.Logic.hasExploded then
		return
	end

	local firstParent: any = nil
	local firstPart: any = nil
	local hitPos = (runData and runData.Logic and runData.Logic.projectileLastPosition) or Vector3.zero

	for partParent, part in result do
		HitResolver.applyHit(Data, hitbox, part, partParent)
		if not firstParent then
			firstParent = partParent
			firstPart = part
			if typeof(part) == "Vector3" then
				hitPos = part
			elseif part and typeof(part) == "Instance" and part:IsA("BasePart") then
				hitPos = part.Position
			end
		end
	end

	local ctx = ImpactContext.fromImpact({
		type = "Enemy",
		position = hitPos,
		target = if typeof(firstParent) == "Instance" then firstParent else nil,
		hitResult = result,
		source = "Hitbox",
	})
	_stopFlightServer(Data)
	if Data.fireProjectileHitConfirmed then
		local targetId = ctx and ctx.targetId
		if targetId == nil and typeof(firstParent) == "number" then
			targetId = firstParent
		end
		Data:fireProjectileHitConfirmed(hitPos, "Enemy", targetId)
	end
	ImpactResolver.resolveImpact(ctx, Data)
end

--[[
	障碍检测（穿透友方后仅墙体）
	@param Data BaseSkillServer - 服务端技能实例
]]
function module.Server_UpdateProjectileObstacleCheck(Data: BaseSkillServer)
	if not Data or not Data:isRunningFlow() then
		return
	end
	local runData = Data.skillRunData
	if not runData or not runData.Logic or runData.Logic.hasExploded then
		return
	end
	local motion = runData.Logic.projectileHitboxMotion
	local lastPos = runData.Logic.projectileLastPosition
	if not motion or typeof(lastPos) ~= "Vector3" then
		return
	end
	local flyDir = motion.flyDir
	if typeof(flyDir) ~= "Vector3" then
		return
	end

	-- 用上一帧位置向前短扫，检测墙体
	local speed = motion.speed or PROJECTILE_SPEED
	local sweep = math.max(speed * (1 / 30), 1.5)
	local origin = lastPos - flyDir * (sweep * 0.5)
	local ctxRay = {
		id = Data.characterId,
		type = Data.characterType or "Player",
	}
	local result = FriendlyRayUtil.raycastProjectileObstacle(origin, flyDir * sweep, ctxRay, {
		extraIgnore = { Data.character },
	})
	if not result then
		return
	end

	local hitPos = result.Position
	local impactCtx = ImpactContext.fromImpact({
		type = "Obstacle",
		position = hitPos,
		normal = result.Normal,
		target = nil,
		source = "ObstacleRay",
	})
	_stopFlightServer(Data)
	if Data.fireProjectileHitConfirmed then
		Data:fireProjectileHitConfirmed(hitPos, "Obstacle", nil)
	end
	ImpactResolver.resolveImpact(impactCtx, Data)
end

-- ========================================
-- 客户端
-- ========================================

--[[
	进入飞行：本地预测视觉弹道（服 PathConfirmed 会校正）
	@param Data BaseSkillClient - 客户端技能实例
]]
function module.Client_EnterProjectileFlying(Data: BaseSkillClient)
	local startPos, endPos, flyDir = _buildShootPath(Data)
	_startClientFlight(Data, startPos, endPos, flyDir)
end

--[[
	退出飞行：停视觉弹道
	@param Data BaseSkillClient - 客户端技能实例
]]
function module.Client_ExitProjectileFlying(Data: BaseSkillClient)
	ProjectileLinearRuntime.stop(Data, RUN_KEY)
end

--[[
	进入 Recovery：停飞；若尚未 HitConfirmed 则销毁视觉
	@param Data BaseSkillClient - 客户端技能实例
]]
function module.Client_EnterRecovery(Data: BaseSkillClient)
	ProjectileLinearRuntime.stop(Data, RUN_KEY)
	-- 若尚未收到 HitConfirmed，仍销毁视觉
	local runData = Data.skillRunData
	if runData and runData.Visual and not runData.Visual.explosionPlayed then
		_destroyVisual(Data)
	end
end

--[[
	服务端中途事件：Path 校正飞行；Hit 停模
	@param Data BaseSkillClient - 客户端技能实例
	@param eventData table - { eventType, startPos?, endPos?, flyDir?, hitPosition? }
]]
function module.onServerEvent(Data: BaseSkillClient, eventData: any)
	if not Data or type(eventData) ~= "table" then
		return
	end
	local eventType = eventData.eventType
	local runData = Data.skillRunData

	if eventType == SYNC.ProjectilePathConfirmed then
		local startPos = eventData.startPos
		local endPos = eventData.endPos
		local flyDir = eventData.flyDir
		if typeof(startPos) ~= "Vector3" or typeof(endPos) ~= "Vector3" then
			return
		end
		if typeof(flyDir) ~= "Vector3" or flyDir.Magnitude < 1e-4 then
			flyDir = (endPos - startPos)
			if flyDir.Magnitude > 1e-4 then
				flyDir = flyDir.Unit
			else
				flyDir = Vector3.new(0, 0, -1)
			end
		else
			flyDir = flyDir.Unit
		end
		_startClientFlight(Data, startPos, endPos, flyDir)
		return
	end

	if eventType == SYNC.ProjectileHitConfirmed or eventType == SYNC.HitConfirmed then
		ProjectileLinearRuntime.stop(Data, RUN_KEY)
		if runData and runData.Visual then
			runData.Visual.explosionPlayed = true
			local hitPos = eventData.hitPosition
			local model = runData.Visual.projectileModel
			if model and typeof(hitPos) == "Vector3" then
				if model:IsA("BasePart") then
					model.CFrame = CFrame.new(hitPos)
				elseif model:IsA("Model") then
					model:PivotTo(CFrame.new(hitPos))
				end
			end
			-- 短留后销毁
			task.delay(0.08, function()
				_destroyVisual(Data)
			end)
		end
		return
	end
end

return module