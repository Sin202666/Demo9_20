--[[
	Module: SystemEnemy
	Description: 敌人权威门面（物理假人 Hit + 逻辑怪 Create/Despawn/OBB 相交；仿真经 EnemySim）
	Author: 林奥宇
	Created: 2026-07-30
	Last Modified: 2026-08-28

	功能：
	- IsEnabled：读 GameConfig「怪物系统.启用」
	- Register / Unregister / Hit：假人与玩家角色受击（既有；玩家互打仍走战斗系统门控）
	- Init：只置 _inited（Manager 专用；不互调其它模块 Init）；EnemySim.Init 由 UpdateManager 收口
	- CreateLogicalEnemy / DespawnById：逻辑怪纯数据权威 + L2 SPAWN/DEATH 同步；出生预贴地
	- PauseMoveAi / ResumeMoveAi / SetMoveGoal / SetMoveDir / GetMoveDriveMode：移动命令（M2 起 SetMoveGoal 落盘 usePath）
	- Ai=Ranger 时装配 RangerAi（L4；批处理进 EnemySim）
	- collectLogicalOverlapHits：服纯数据 OBB/球相交（Hitbox + 弹道共用）
	- Hit：若 enemyName 为逻辑怪 id，则经 LogicalHitValidate 后扣 LogicalStore.hp
	- 受击表现：扣血后、Despawn 前触发 SkillHitPresentation + NPCCosmeticHit（对照 RP18）
	- 扣血后 EnemyLogicalSync.pushState：客 LocalMonster Humanoid 通用血条

	约束：
	- 伤害体积为纯数据 OBB（禁 LocalMonster / 隐形 Part 权威检测）
	- LocalMonster 仅客户端表现（CanQuery=false；CollisionGroup=Enemy）
	- AI/位移禁止每怪 Heartbeat（仅 EnemySim 批处理）
	- 位移权威经 LogicEntityMotion（I7=A：服射线贴地+挡墙）
	- 不自建 Heartbeat

	加载：
		local SystemEnemy = Utils.SystemEnemy
		SystemEnemy.Init()
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local GetData = Utils.GetData
local SystemPlrAttr = Utils.SystemPlrAttr
local SystemGameConfig = Utils.SystemGameConfig
local Log = Utils.Log
local CfgFind = Utils.CfgFind
local ResourceUtil = Utils.ResourceUtil
local EnemyLogicalStore = Utils.EnemyLogicalStore
local EnemySim = Utils.EnemySim
local EnemyLogicalSync = Utils.EnemyLogicalSync
local LogicalHitValidate = Utils.LogicalHitValidate
local RangerAi = Utils.RangerAi
local LogicalMoveCommand = Utils.LogicalMoveCommand
local LogicEntityMotion = Utils.LogicEntityMotion
local SkillHitPresentation = Utils.SkillHitPresentation
local NPCCosmeticHit = Utils.NPCCosmeticHit

local SystemEnemy = {}

local DEFAULT_BBOX = Vector3.new(4, 5, 4)
local DEFAULT_MAX_HP = 2000

-- 弱键注册表：Model → true（物理假人）
local _registered: { [Model]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local _nextLogicalId = 0
local _inited = false

--[[
	解析逻辑怪伤害盒尺寸：覆盖值 > 配表 bbox 字段 > 模型 Extents > 默认
	@param cfg table? - enemyConf 行
	@param override Vector3? - 显式覆盖
	@return Vector3 - 全尺寸 bbox
]]
local function _resolveBBox(cfg: any?, override: Vector3?): Vector3
	if typeof(override) == "Vector3" and override.X > 0 then
		return override
	end
	if type(cfg) == "table" then
		local boxed = cfg.bboxSize or cfg.BBox or cfg.bbox
		if typeof(boxed) == "Vector3" and boxed.X > 0 then
			return boxed
		end
		if type(boxed) == "table" then
			local x, y, z = tonumber(boxed[1] or boxed.X), tonumber(boxed[2] or boxed.Y), tonumber(boxed[3] or boxed.Z)
			if x and y and z and x > 0 then
				return Vector3.new(x, y, z)
			end
		end
		local modelName = cfg.model
		if type(modelName) == "string" and modelName ~= "" then
			local ok, model = pcall(function()
				return ResourceUtil.GetModel("Enemy", modelName)
			end)
			if ok and typeof(model) == "Instance" and model:IsA("Model") then
				local size = model:GetExtentsSize()
				model:Destroy()
				if size.X > 0 then
					return size
				end
			end
		end
	end
	return DEFAULT_BBOX
end

--[[
	构建 allowedSet
	@param ids { number }? - 玩家 UserId 列表；空/nil 表示暂不限制（L1 全开）
	@return ({ number }, { [number]: true }) - UserId 列表与去重集合
]]
local function _buildAllowed(ids: { number }?): ({ number }, { [number]: true })
	local list: { number } = {}
	local set: { [number]: true } = {}
	if type(ids) == "table" then
		for _, uid in ipairs(ids) do
			local n = tonumber(uid)
			if n then
				table.insert(list, n)
				set[n] = true
			end
		end
	end
	return list, set
end

--[[
	从 CFrame 取平面单位朝向（退化时朝 -Z）
	@param cf CFrame - 参考位姿
	@return Vector3 - 平面单位 Look
]]
local function _flatLookFromCFrame(cf: CFrame): Vector3
	local look = cf.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 1e-4 then
		return Vector3.new(0, 0, -1)
	end
	return flat.Unit
end

--[[
	取存活逻辑怪记录；未启用或已死返回 nil
	@param id number - 运行时 id
	@return any? - LogicalRecord
]]
local function _getLiveLogical(id: number): any?
	if not SystemEnemy.IsEnabled() then
		return nil
	end
	local n = tonumber(id)
	if not n then
		return nil
	end
	local rec = EnemyLogicalStore.get(n)
	if not rec or not rec.alive then
		return nil
	end
	return rec
end

--[[
	球与 OBB 是否相交（最近点钳制）

	@param sphereCenter Vector3 - 球心
	@param sphereRadius number - 球半径
	@param boxCf CFrame - OBB 中心位姿
	@param boxHalf Vector3 - OBB 半轴
	@return boolean - 相交为 true
]]
local function _sphereOverlapsObb(
	sphereCenter: Vector3,
	sphereRadius: number,
	boxCf: CFrame,
	boxHalf: Vector3
): boolean
	local localPos = boxCf:PointToObjectSpace(sphereCenter)
	local closest = Vector3.new(
		math.clamp(localPos.X, -boxHalf.X, boxHalf.X),
		math.clamp(localPos.Y, -boxHalf.Y, boxHalf.Y),
		math.clamp(localPos.Z, -boxHalf.Z, boxHalf.Z)
	)
	return (localPos - closest).Magnitude <= sphereRadius
end

--[[
	技能轴对齐盒（在 hitboxCf 局部）与怪物 OBB 是否相交（投影扩展）

	@param hitboxCf CFrame - 技能 Hitbox 位姿
	@param hitboxHalf Vector3 - 技能盒半轴
	@param bodyCf CFrame - 怪物中心位姿
	@param bodyHalf Vector3 - 怪物包围盒半轴
	@return boolean - 相交为 true
]]
local function _blockOverlapsObb(
	hitboxCf: CFrame,
	hitboxHalf: Vector3,
	bodyCf: CFrame,
	bodyHalf: Vector3
): boolean
	local localCenter = hitboxCf:PointToObjectSpace(bodyCf.Position)
	local right = hitboxCf:VectorToObjectSpace(bodyCf.RightVector)
	local up = hitboxCf:VectorToObjectSpace(bodyCf.UpVector)
	local look = hitboxCf:VectorToObjectSpace(bodyCf.LookVector)
	local expand = Vector3.new(
		math.abs(right.X) * bodyHalf.X + math.abs(up.X) * bodyHalf.Y + math.abs(look.X) * bodyHalf.Z,
		math.abs(right.Y) * bodyHalf.X + math.abs(up.Y) * bodyHalf.Y + math.abs(look.Y) * bodyHalf.Z,
		math.abs(right.Z) * bodyHalf.X + math.abs(up.Z) * bodyHalf.Y + math.abs(look.Z) * bodyHalf.Z
	)
	return math.abs(localCenter.X) <= hitboxHalf.X + expand.X
		and math.abs(localCenter.Y) <= hitboxHalf.Y + expand.Y
		and math.abs(localCenter.Z) <= hitboxHalf.Z + expand.Z
end

--[[
	怪物系统总开关（GameConfig.怪物系统.启用）
	@return boolean - true 表示启用逻辑怪仿真与假人受击
]]
function SystemEnemy.IsEnabled(): boolean
	return SystemGameConfig.GetValue({ "怪物系统", "启用" }) ~= false
end

--[[
	初始化（Manager 调用；幂等）。只置 _inited，不互调其它模块 Init。
	EnemySim.Init 由 UpdateManager 在本函数之后调用。
	@return nil - 未启用时直接返回
]]
function SystemEnemy.Init()
	if not SystemEnemy.IsEnabled() then
		return
	end
	if _inited then
		return
	end
	_inited = true
end

--[[
	注册可受击假人/敌人（优先于按名查找）
	@param model Model - 带 Humanoid 的模型
]]
function SystemEnemy.Register(model: Model)
	if typeof(model) == "Instance" and model:IsA("Model") then
		_registered[model] = true
	end
end

--[[
	取消注册
	@param model Model - 已注册的假人/敌人模型
]]
function SystemEnemy.Unregister(model: Model)
	if typeof(model) == "Instance" and model:IsA("Model") then
		_registered[model] = nil
	end
end

--[[
	创建逻辑怪（纯数据；加入 EnemySim 批处理）
	@param cfgId number - enemyConf 行 ID（如 5011001）
	@param cframe CFrame - 初始权威位姿
	@param opts { allowedPlayerIds: {number}?, combatReady: boolean?, bboxSize: Vector3?, maxHp: number? }? - 可选；缺省空表
	@return number? - 运行时 id；失败返回 nil
]]
function SystemEnemy.CreateLogicalEnemy(cfgId: number, cframe: CFrame, opts: any?): number?
	if not SystemEnemy.IsEnabled() then
		return nil
	end
	-- 懒 Init 只置 _inited；仿真 tick 须由 UpdateManager 先 EnemySim.Init
	SystemEnemy.Init()
	local idKey = tonumber(cfgId)
	if not idKey then
		Log.warn("[SystemEnemy.CreateLogicalEnemy] cfgId 无效")
		return nil
	end
	if typeof(cframe) ~= "CFrame" then
		Log.warn("[SystemEnemy.CreateLogicalEnemy] cframe 无效")
		return nil
	end

	local cfg = CfgFind.GetCfgByNameAndID("enemyConf", idKey)
	if not cfg then
		Log.warn("[SystemEnemy.CreateLogicalEnemy] 未找到 enemyConf:", idKey)
		return nil
	end

	opts = if type(opts) == "table" then opts else {}
	local bbox = _resolveBBox(cfg, opts.bboxSize)
	local maxHp = tonumber(opts.maxHp) or DEFAULT_MAX_HP
	if maxHp <= 0 then
		maxHp = DEFAULT_MAX_HP
	end
	local allowedList, allowedSet = _buildAllowed(opts.allowedPlayerIds)
	local combatReady = opts.combatReady ~= false
	local modelName = if type(cfg.model) == "string" then cfg.model else ""
	local ai = if type(cfg.Ai) == "string" then cfg.Ai else ""

	-- I7=A：出生预贴地（无地面命中则保持传入 Y）
	local spawnPos = cframe.Position
	local spawnY = LogicEntityMotion.snapGroundY({ bboxSize = bbox }, spawnPos)
	local look = _flatLookFromCFrame(cframe)
	local spawnCf = CFrame.lookAt(Vector3.new(spawnPos.X, spawnY, spawnPos.Z), Vector3.new(spawnPos.X, spawnY, spawnPos.Z) + look)

	_nextLogicalId += 1
	local runtimeId = _nextLogicalId

	local rec = {
		id = runtimeId,
		cfgId = idKey,
		cframe = spawnCf,
		bboxSize = bbox,
		allowedPlayerIds = allowedList,
		allowedSet = allowedSet,
		combatReady = combatReady,
		hp = maxHp,
		maxHp = maxHp,
		modelName = modelName,
		ai = ai,
		dirtyTransform = true,
		alive = true,
		entity = nil,
	}
	EnemyLogicalStore.put(rec)
	if ai == "Ranger" then
		RangerAi.assemble(rec, cfg)
	elseif ai ~= "" then
		Log.warn("[SystemEnemy.CreateLogicalEnemy] 暂不支持 Ai=", ai, " id=", runtimeId, "（仅 Ranger）")
	end
	EnemySim.add(runtimeId)
	EnemyLogicalSync.spawnToWhitelist(rec)
	return runtimeId
end

--[[
	销毁逻辑怪（移出仿真并删 Store）
	@param id number - 运行时 id
	@return boolean - 是否成功移除
]]
function SystemEnemy.DespawnById(id: number): boolean
	local n = tonumber(id)
	if not n then
		return false
	end
	local rec = EnemyLogicalStore.get(n)
	if rec then
		EnemyLogicalSync.death(rec)
		rec.alive = false
	end
	EnemySim.remove(n)
	EnemyLogicalStore.remove(n)
	return rec ~= nil
end

--[[
	按名解析目标 Model（物理路径）
	@param enemyName string - 目标 Model.Name
	@return Model? - 注册表 / Enemies / 玩家角色 / Workspace 深搜命中；未找到为 nil
]]
local function _findTargetByName(enemyName: string): Model?
	if type(enemyName) ~= "string" or enemyName == "" then
		return nil
	end

	for model, _ in pairs(_registered) do
		if model.Name == enemyName and model.Parent then
			return model
		end
	end

	local enemiesFolder = Workspace:FindFirstChild("Enemies")
	if enemiesFolder then
		local child = enemiesFolder:FindFirstChild(enemyName)
		if child and child:IsA("Model") then
			return child
		end
	end

	for _, plr in Players:GetPlayers() do
		local char = plr.Character
		if char and char.Name == enemyName then
			return char
		end
	end

	local deep = Workspace:FindFirstChild(enemyName, true)
	if deep and deep:IsA("Model") and deep:FindFirstChildOfClass("Humanoid") then
		return deep
	end

	return nil
end

--[[
	逻辑怪体积与 Hitbox 球/盒相交检测（服务端；补 workspace 扫不到纯数据逻辑体的缺口）
	体积取创建时写入的 bboxSize，按当前 Store.cframe 做 OBB 相交。

	@param cf CFrame - Hitbox 位姿
	@param size Vector3 - Hitbox 尺寸（全尺寸）
	@param shape string - "Ball" | "Block"
	@param alreadyHit { [number]: any }? - 已命中逻辑 id 表（跳过）；可与 Hitbox.checkedParts 共用
	@return { [number]: Vector3 } - 逻辑怪 id → 相交参考点（中心 Position）
]]
function SystemEnemy.collectLogicalOverlapHits(
	cf: CFrame,
	size: Vector3,
	shape: string,
	alreadyHit: { [number]: any }?
): { [number]: Vector3 }
	local result: { [number]: Vector3 } = {}
	if not SystemEnemy.IsEnabled() then
		return result
	end
	if typeof(cf) ~= "CFrame" or typeof(size) ~= "Vector3" then
		return result
	end

	local half = size * 0.5
	local ballRadius = math.max(size.X, size.Y, size.Z) * 0.5
	local useBall = shape == "Ball"

	EnemyLogicalStore.forEach(function(rec)
		if not rec.alive then
			return
		end
		if alreadyHit and alreadyHit[rec.id] then
			return
		end

		local bodyCf = rec.cframe
		local bboxSize = rec.bboxSize
		if typeof(bboxSize) ~= "Vector3" or bboxSize.X <= 0 then
			bboxSize = DEFAULT_BBOX
		end
		local bodyHalf = bboxSize * 0.5

		local hit = false
		if useBall then
			hit = _sphereOverlapsObb(cf.Position, ballRadius, bodyCf, bodyHalf)
		else
			hit = _blockOverlapsObb(cf, half, bodyCf, bodyHalf)
		end
		if hit then
			result[rec.id] = bodyCf.Position
		end
	end)

	return result
end

--[[
	逻辑怪受击结算（调用前须已通过 LogicalHitValidate）
	@param attacker Player - 攻击者
	@param rec any - LogicalRecord
	@param hitData any? - 伤害载荷（可含 hitPresentation）
	@return number - 实际伤害
]]
local function _hitLogical(attacker: Player, rec: any, hitData: any?): number
	local damage = GetData.GetDmg(attacker, nil, hitData)
	if damage <= 0 then
		return 0
	end

	local newHp = math.max(0, (rec.hp or 0) - damage)
	rec.hp = newHp

	-- 客 LocalMonster Humanoid 血条：Despawn 前先同步（含归零）
	if EnemyLogicalSync and EnemyLogicalSync.pushState then
		EnemyLogicalSync.pushState(rec)
	end

	-- 表现须在 Despawn/DEATH 同步前下发，避免客模已销毁后丢受击 Anim
	if SkillHitPresentation and SkillHitPresentation.accumulateFromLogical then
		SkillHitPresentation.accumulateFromLogical(rec.id, rec.cfgId, damage, hitData)
	end
	if NPCCosmeticHit and NPCCosmeticHit.tryPlayLogical then
		local skillId = hitData and hitData.skillid
		NPCCosmeticHit.tryPlayLogical(rec, damage, skillId)
	end

	if newHp <= 0 then
		SystemEnemy.DespawnById(rec.id)
	end
	return damage
end

--[[
	玩家技能命中敌人/假人/玩家角色/逻辑怪
	@param ownerId number - 攻击者 UserId
	@param enemyName string - 目标 Model.Name，或逻辑怪运行时 id 字符串
	@param hitData table? - 含 damageRate / finalDamage 等
	@return number - 实际伤害
]]
function SystemEnemy.Hit(ownerId: any, enemyName: string, hitData: any?): number
	if GetData.IsCombatEnabled and not GetData.IsCombatEnabled() then
		return 0
	end
	local attacker = Players:GetPlayerByUserId(tonumber(ownerId) or 0)
	if not attacker then
		return 0
	end

	local logicalId = tonumber(enemyName)
	if logicalId then
		if not SystemEnemy.IsEnabled() then
			return 0
		end
		local rec = EnemyLogicalStore.get(logicalId)
		if rec and rec.alive then
			if not LogicalHitValidate.canAcceptPlayerHit(attacker.UserId, logicalId, hitData) then
				return 0
			end
			return _hitLogical(attacker, rec, hitData)
		end
	end

	local target = _findTargetByName(tostring(enemyName))
	if not target then
		Log.warn("[SystemEnemy.Hit] 未找到目标:", enemyName)
		return 0
	end

	local beHitPlr = Players:GetPlayerFromCharacter(target)
	if beHitPlr then
		local atkModel = attacker.Character
		return SystemPlrAttr.HitPlr(atkModel, beHitPlr, hitData) or 0
	end

	if not SystemEnemy.IsEnabled() then
		return 0
	end

	local humanoid = target:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return 0
	end

	local damage, _isCrit = GetData.GetDmg(attacker, target, hitData)
	if damage <= 0 then
		return 0
	end

	humanoid:TakeDamage(damage)
	return damage
end

--[[
	暂停移动 AI；受击锁结束后仍保持 Pause，直到 ResumeMoveAi
	@param id number - 运行时 id
	@return boolean - 是否接受
]]
function SystemEnemy.PauseMoveAi(id: number): boolean
	local rec = _getLiveLogical(id)
	if not rec then
		return false
	end
	return LogicalMoveCommand.setMode(rec, "Pause")
end

--[[
	解除 Pause，回到 Auto（Ranger 从冻结 state 继续）
	@param id number - 运行时 id
	@return boolean - 是否接受
]]
function SystemEnemy.ResumeMoveAi(id: number): boolean
	local rec = _getLiveLogical(id)
	if not rec then
		return false
	end
	return LogicalMoveCommand.setMode(rec, "Auto")
end

--[[
	覆盖走点（ScriptGoal）。到达回 Auto；timeoutSec 有值则到期未到也回 Auto；缺省则一直走。
	usePath：nil/true 且寻路启用则绕路；false 则直线。锁窗内仍返回 true，落地后再生效。
	@param id number - 运行时 id
	@param worldPos Vector3 - 世界目标（Y 可忽略）
	@param opts { timeoutSec: number?, arriveEps: number?, usePath: boolean? }? - 超时/到达半径/是否寻路
	@return boolean - 是否接受
]]
function SystemEnemy.SetMoveGoal(id: number, worldPos: Vector3, opts: any?): boolean
	local rec = _getLiveLogical(id)
	if not rec then
		return false
	end
	if typeof(worldPos) ~= "Vector3" then
		return false
	end
	local payload = { pos = worldPos }
	if type(opts) == "table" then
		payload.timeoutSec = opts.timeoutSec
		payload.arriveEps = opts.arriveEps
		payload.usePath = opts.usePath
	end
	return LogicalMoveCommand.setMode(rec, "ScriptGoal", payload)
end

--[[
	按平面方向走 durationSec，到期回 Auto
	@param id number - 运行时 id
	@param flatDir Vector3 - 平面方向（不必单位；零向量拒绝）
	@param durationSec number - 持续时间秒，必须 >0
	@return boolean - 是否接受
]]
function SystemEnemy.SetMoveDir(id: number, flatDir: Vector3, durationSec: number): boolean
	local rec = _getLiveLogical(id)
	if not rec then
		return false
	end
	return LogicalMoveCommand.setMode(rec, "ScriptDir", {
		dir = flatDir,
		durationSec = durationSec,
	})
end

--[[
	当前移动驱动模式
	@param id number - 运行时 id
	@return string? - Auto / ScriptGoal / ScriptDir / Pause；无记录返回 nil
]]
function SystemEnemy.GetMoveDriveMode(id: number): string?
	local rec = _getLiveLogical(id)
	if not rec then
		return nil
	end
	return LogicalMoveCommand.getMode(rec)
end

return SystemEnemy