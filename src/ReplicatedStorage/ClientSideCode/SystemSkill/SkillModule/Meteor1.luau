--[[
	Module: Meteor1
	Description: 陨石术基础技能（含 Hitbox 主动技样板）。Startup 施法 → MeteorFalling 坠落/落地命中 → Recovery。
	Author: 林奥宇
	Created: 2026-07-30
	Last Modified: 2026-09-01

	主流程：Startup -> MeteorFalling -> Recovery -> Finished
	- SkillAction：LookAt(0～Startup) + Animation「技能释放动作4」(0～1.4)
	- Startup：尾迹延迟开启；施法结束点出法阵；服务端预热 Hitbox
	- MeteorFalling：客户端火球坠落/爆炸/BurstStone；服务端落地窗 start/stop 球形 Hitbox
	- Recovery：关尾迹；服务端 releaseControl
	- 打断 / ForceFinish：不经 Recovery；客户端 onEnd 兜底关尾迹（连接由框架 CleanupAllConns 断开）
	- 【一期 A】坠落/Hitbox 逻辑 Tick 走 Utils.CombatWorld.register；尾迹跟随可用 RenderStepped（纯表现）
	- 禁止对本模块逻辑 Tick 使用 RunService.Heartbeat:Connect

	Hitbox：
	- PartName「通用球」；落地瞬间 Size=HITBOX_LAND_SIZE×scale；激活窗 METEOR_MOVE_TIME±HITBOX_WINDOW
	- CollisionGroup 配置「Hitbox」（实例组由 Hitbox.new 覆盖为 Hitbox；目标组按施法者 ownerType 过滤）
	- 伤害倍率走 skillConf.DamageRate[1]；权威结算在服务端（客只播坠落/爆炸）

	模块关系：
	- 状态机/生命周期：BaseSkill（Client/Server）+ SkillEventConst
	- 瞄准快照：BaseSkill/PlayerAimSync.refreshAimSnapshot
	- 公共表现：SkillModule/_Templates/SkillCommon（魔杖尖、缩放带、本地 3D 音效）
	- 震屏：CameraModule；碎石：BurstStone；射线贴地：RayCast
	- 组技能：GroupSkillModule/Meteor（CD / 派生指向本模块）

	资源（需放入 Assets/ModelRes/Skill 与 Hitbox，见 ResNameList / hitboxConfig）：
	- 陨石术火球 / 陨石术法阵 / 陨石术爆炸 / 火系尾迹；Hitbox「通用球」

	加载方式：
	local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
	-- 由技能框架按 SkillModule 名 require，一般不直接业务调用

	示例（配置侧关键字段）：
	module.hitboxConfig[1].PartName = "通用球"
	module.States.MeteorFalling.Duration = 1.1
	module.Action[1].action = "LookAt" -- overTime 对齐 Startup
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local EnumMgr = Utils.EnumMgr
local ElementTp = EnumMgr.ElementTp
local Class = require(game.ReplicatedFirst.AllSideCode.Class.Class)
local EVT = require(script.Parent.Parent.BaseSkill.SkillEventConst)
local SC = require(script.Parent._Templates.SkillCommon)
local PlayerAimSync = require(script.Parent.Parent.BaseSkill.PlayerAimSync)
local CameraModule = Utils.CameraModule
local FXUtil = Utils.FXUtil
local RayCast = Utils.RayCast
local BurstStone = Utils.BurstStone
local RunService = Utils.RunService
local CombatWorld = Utils.CombatWorld
local TweenService = Utils.TweenService
local LocalPlayer = Utils.LocalPlayer

type BaseSkillClient = Class.BaseSkillClient
type BaseSkillServer = Class.BaseSkillServer
type RunEventHandle = RBXScriptConnection | { Disconnect: (self: any) -> () }
type RunEventMap = { [string]: RunEventHandle? }

local module = {}

-- ========================================
-- 常量
-- ========================================
local STARTUP_DURATION = 0.73
local METEOR_FALLING_DURATION = 1.1
local RECOVERY_DURATION = 0.2
local ANIM_OVER_TIME = 1.4
local ANIM_SPEED = 1
local ANIM_FADE_TIME = 0.1
local LOOKAT_SPEED_TYPE = "RELEASE_SKILL_STATE_HALF"

local METEOR_MOVE_TIME = 0.5
local METEOR_START_OFFSET = 60
local HITBOX_PREHEAT_SIZE = Vector3.new(40, 40, 40)
local HITBOX_LAND_SIZE = Vector3.new(35, 35, 35)
local HITBOX_WINDOW = 0.1

local TRAIL_START_DELAY = 0.3
local TRAIL_END_DELAY = 0.9
local MAGIC_CIRCLE_LOCAL_OFFSET = CFrame.new(0, 0, -2)
local MAGIC_CIRCLE_ROT = CFrame.Angles(math.rad(90), 0, 0)

local GROUND_RAY_UP = Vector3.new(0, 3, 0)
local GROUND_RAY_DIR = Vector3.new(0, -1, 0)
local GROUND_RAY_DIST = 100
local GROUND_RAY_FILTER = "Ground"
local CLIENT_LAND_Y_OFFSET = 0.5
local SERVER_LAND_Y_OFFSET = 0.1

local METEOR_EMIT_DURATION = 10
local BEAM_FADE_IN = 0.5
local BEAM_FADE_OUT = 0.1

local RES_TRAIL = "火系尾迹"
local RES_CIRCLE = "陨石术法阵"
local RES_METEOR = "陨石术火球"
local RES_EXPLOSION = "陨石术爆炸"
local EVENT_TRAIL = "陨石术魔杖尾迹"
local EVENT_FALL = "陨石坠落移动"
local EVENT_HITBOX = "陨石命中检测坠落移动"
local SOUND_FLY = "音效-技能-陨石术-飞行"
local SOUND_EXPLODE = "音效-技能-陨石术-爆炸"
local ANIM_CAST = "技能释放动作4"
local BURST_STYLE = "Meteor"
local HITBOX_PART = "通用球"
local HITBOX_COLLISION_GROUP = "Hitbox"
local HIT_EFFECT_NAME = "通用受击"
local HIT_SOUND_NAME = "通用受击"
local PHYS_EFFECT_NAME = "中等力度受击物理效果"
local CHARACTER_TYPE_PLAYER = "Player"
local COMBAT_FALL_ID_PREFIX = "Meteor1Fall"
local COMBAT_HITBOX_ID_PREFIX = "Meteor1Hitbox"

-- ========================================
-- 模块字段 / 状态机
-- ========================================
module.skillTotalTime = -1
module.visualFadeoutTime = 2
module.skillElementType = ElementTp.Fire
module.skillDistanceLimit = 64

module.InitialState = "Startup"
-- 进入该状态时允许派生/放权（陨石已离手）
module.ControlOpenState = "MeteorFalling"

module.States = {
	Startup = {
		Duration = STARTUP_DURATION,
		OnEnterClient = "Client_EnterStartup",
		OnEnterServer = "Server_EnterStartup",
		OnExitClient = nil,
		OnExitServer = nil,
	},
	MeteorFalling = {
		Duration = METEOR_FALLING_DURATION,
		OnEnterClient = "Client_EnterMeteorFalling",
		OnEnterServer = "Server_EnterMeteorFalling",
		OnExitClient = "Client_ExitMeteorFalling",
		OnExitServer = "Server_ExitMeteorFalling",
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
	{ From = "Startup", To = "MeteorFalling", Event = EVT.StateTimeout },
	{ From = "MeteorFalling", To = "Recovery", Event = EVT.StateTimeout },
	{ From = "Recovery", To = "Finished", Event = EVT.StateTimeout },
	{ From = "Startup", To = "Interrupted", Event = EVT.Interrupt },
	{ From = "MeteorFalling", To = "Interrupted", Event = EVT.Interrupt },
	{ From = "Recovery", To = "Interrupted", Event = EVT.Interrupt },
	{ From = "Startup", To = "Finished", Event = EVT.ForceFinish },
	{ From = "MeteorFalling", To = "Finished", Event = EVT.ForceFinish },
	{ From = "Recovery", To = "Finished", Event = EVT.ForceFinish },
}

-- ========================================
-- 私有函数
-- ========================================

--[[
	本机玩家是否为本次施法者（旁观不震屏）。

	@param Data BaseSkillClient - 客户端技能实例
	@return boolean - 本机玩家角色施法时为 true
]]
local function _isLocalPlayerCaster(Data: BaseSkillClient): boolean
	if not Data or not LocalPlayer or Data.characterType ~= CHARACTER_TYPE_PLAYER then
		return false
	end
	return Data.characterId == LocalPlayer.UserId
end

--[[
	当前施法代数下流程是否仍可推进（延迟回调守卫）。

	@param Data BaseSkillClient - 客户端技能实例
	@param runGen number - 调度时记录的 runGeneration
	@return boolean - 仍在跑且代数未变时为 true
]]
local function _isSameRun(Data: BaseSkillClient, runGen: number): boolean
	return Data:isRunningFlow() and Data.runGeneration == runGen
end

--[[
	保证 skillRunData.runEvent 表存在。

	@param runData table - skillRunData（须已存在）
	@return RunEventMap - runEvent 表（原表或新建）
]]
local function _ensureRunEvent(runData: any): RunEventMap
	if not runData.runEvent then
		runData.runEvent = {}
	end
	return runData.runEvent
end

--[[
	断开并清空 runEvent 上指定键（RBXScriptConnection 或 CombatWorld Handle）。

	@param runEvent RunEventMap? - skillRunData.runEvent；键为事件名，值为连接/Handle
	@param key string - 连接键名（EVENT_TRAIL / EVENT_FALL / EVENT_HITBOX）
]]
local function _disconnectRunEvent(runEvent: RunEventMap?, key: string)
	if not runEvent then
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
	开关尾迹模型上的 Trail / ParticleEmitter。

	@param trailInst Instance? - 尾迹模型实例；nil 则跳过
	@param enabled boolean - true 开启发射，false 关闭
]]
local function _setTrailEmittersEnabled(trailInst: Instance?, enabled: boolean)
	if not trailInst then
		return
	end
	for _, v in pairs(trailInst:GetDescendants()) do
		if v:IsA("Trail") or v:IsA("ParticleEmitter") then
			v.Enabled = enabled
		end
	end
end

--[[
	关闭尾迹发射器并断开跟随连接。

	@param Data BaseSkillClient? - 客户端技能实例；nil 则跳过
]]
local function _cleanupMeteorTrail(Data: BaseSkillClient?)
	if not Data then
		return
	end
	local runData = Data.skillRunData
	if runData and runData.material then
		_setTrailEmittersEnabled(runData.material[RES_TRAIL], false)
	end
	_disconnectRunEvent(runData and runData.runEvent, EVENT_TRAIL)
end

--[[
	将瞄准点沿竖直向下射线贴地，并抬升 Y 偏移。

	@param endCF CFrame - 瞄准落点（含朝向）
	@param yOffset number - 贴地后向上抬升的世界单位
	@return CFrame - 贴地后的落点 CF（无射线命中则返回原 endCF）
]]
local function _resolveGroundedEndCF(endCF: CFrame, yOffset: number): CFrame
	local rayResult = RayCast.RayCastDirection(endCF.Position + GROUND_RAY_UP, GROUND_RAY_DIR, GROUND_RAY_DIST, GROUND_RAY_FILTER)
	if not rayResult then
		return endCF
	end
	return endCF.Rotation + rayResult.Position + Vector3.new(0, yOffset, 0)
end

--[[
	火球落地：震屏/爆炸音效/粒子/碎石，并淡出火球网格与 Beam。

	@param Data BaseSkillClient - 客户端技能实例
	@param meteorModel Model - 火球模型
	@param meteorExp Model - 爆炸特效模型
	@param finalCF CFrame - 落地世界姿态
	@param startScale number - 与技能缩放带一致的缩放
]]
local function _playMeteorLandFx(
	Data: BaseSkillClient,
	meteorModel: Model,
	meteorExp: Model,
	finalCF: CFrame,
	startScale: number
)
	if _isLocalPlayerCaster(Data) and CameraModule and CameraModule.CameraShakeAt then
		CameraModule.CameraShakeAt(EnumMgr.CameraShakeType.Explosion, finalCF.Position)
	end
	SC.playSoundLocal3D(SOUND_EXPLODE, meteorModel:GetPivot().Position)
	FXUtil.Emit_Particles_GetDescendants(meteorExp, true)
	if BurstStone then
		BurstStone.CreateLandBreak(finalCF, BURST_STYLE, startScale)
		BurstStone.CreateStoneFly(finalCF, BURST_STYLE, startScale)
	end
	FXUtil.Stop_All_Emit(meteorModel)
	for _, v in pairs(meteorModel:GetDescendants()) do
		if v:IsA("Beam") then
			FXUtil.Beam_Fade_To_Transparent_Then_Disable(v, BEAM_FADE_OUT, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		end
		if v:IsA("MeshPart") then
			v.Transparency = 1
		end
	end
end

--[[
	Startup：延迟开启魔杖尾迹并在 TRAIL_END 关闭。

	@param Data BaseSkillClient - 客户端技能实例
	@param wandTip Instance - 魔杖尖端（跟随目标）
	@param runGen number - 进入 Startup 时的 runGeneration
]]
local function _scheduleWandTrail(Data: BaseSkillClient, wandTip: Instance, runGen: number)
	task.delay(TRAIL_START_DELAY, function()
		if not _isSameRun(Data, runGen) then
			return
		end
		local runData = Data.skillRunData
		if not runData or not runData.material then
			return
		end
		local magicTrail = runData.material[RES_TRAIL]
		if not magicTrail then
			return
		end
		_setTrailEmittersEnabled(magicTrail, true)
		magicTrail.Parent = workspace.Debris
		local runEvent = _ensureRunEvent(runData)
		_disconnectRunEvent(runEvent, EVENT_TRAIL)
		runEvent[EVENT_TRAIL] = RunService.RenderStepped:Connect(function()
			if wandTip.Parent and magicTrail.Parent then
				magicTrail:PivotTo(wandTip:GetPivot())
			end
		end)
	end)

	task.delay(TRAIL_END_DELAY, function()
		if Data.runGeneration ~= runGen then
			return
		end
		_cleanupMeteorTrail(Data)
	end)
end

--[[
	Startup：与施法动作对齐出法阵（不依赖魔杖）。

	@param Data BaseSkillClient - 客户端技能实例
	@param HRP BasePart - 施法者 HumanoidRootPart
	@param runGen number - 进入 Startup 时的 runGeneration
]]
local function _scheduleMagicCircle(Data: BaseSkillClient, HRP: BasePart, runGen: number)
	task.delay(STARTUP_DURATION, function()
		if not _isSameRun(Data, runGen) then
			return
		end
		local runData = Data.skillRunData
		local material = runData and runData.material
		local magicStart = material and material[RES_CIRCLE]
		if not magicStart then
			return
		end
		local effectStartCF = HRP:GetPivot():ToWorldSpace(MAGIC_CIRCLE_LOCAL_OFFSET)
		magicStart:ScaleTo(SC.scaleBandFromData(Data, SC.bandScaleOptsFromSkillData(Data)))
		magicStart:PivotTo(effectStartCF * MAGIC_CIRCLE_ROT)
		magicStart.Parent = workspace.Debris
		FXUtil.Emit_Particles_GetDescendants(magicStart, true)
	end)
end

-- ========================================
-- 状态：Startup
-- ========================================

--[[
	Startup 客户端：魔杖尾迹 + 法阵。

	@param Data BaseSkillClient - 客户端技能实例
]]
function module.Client_EnterStartup(Data: BaseSkillClient)
	local character = Data.skillInputData.character
	if not character then
		return
	end
	local HRP = character:FindFirstChild("HumanoidRootPart")
	if not HRP or not HRP:IsA("BasePart") then
		return
	end
	local runGen = Data.runGeneration
	local wandTip = SC.resolveWandTipFromCharacter(character)
	if wandTip then
		_scheduleWandTrail(Data, wandTip, runGen)
	end
	_scheduleMagicCircle(Data, HRP, runGen)
end

--[[
	Startup 服务端：预热 Hitbox 尺寸。

	@param Data BaseSkillServer - 服务端技能实例
]]
function module.Server_EnterStartup(Data: BaseSkillServer)
	local hitbox1 = Data.hitbox[1]
	if hitbox1 and hitbox1.hitbox then
		hitbox1.hitbox.Size = HITBOX_PREHEAT_SIZE
	end
end

-- ========================================
-- 状态：MeteorFalling
-- ========================================

--[[
	坠落客户端：火球插值坠落 + 落地爆炸/震屏/BurstStone。

	@param Data BaseSkillClient - 客户端技能实例
]]
function module.Client_EnterMeteorFalling(Data: BaseSkillClient)
	PlayerAimSync.refreshAimSnapshot(Data)

	local character = Data.skillInputData.character
	if not character then
		return
	end
	local HRP = character:FindFirstChild("HumanoidRootPart")
	if not HRP then
		return
	end

	local endCF = _resolveGroundedEndCF(Data.skillInputData.targetCF, CLIENT_LAND_Y_OFFSET)
	local startScale = SC.scaleBandFromData(Data, SC.bandScaleOptsFromSkillData(Data))
	local startPos = HRP:GetPivot():PointToWorldSpace(Vector3.new(
		METEOR_START_OFFSET * (1 - 2 * math.random()),
		METEOR_START_OFFSET,
		METEOR_START_OFFSET
	))
	local startCF = CFrame.lookAt(startPos, endCF.Position)
	local finalCF = startCF.Rotation + endCF.Position

	local material = Data.skillRunData.material
	local meteorModel = material and material[RES_METEOR]
	local meteorExp = material and material[RES_EXPLOSION]
	if not meteorModel or not meteorExp then
		return
	end
	meteorModel:ScaleTo(startScale)
	meteorModel:PivotTo(startCF)
	meteorModel.Parent = workspace.Debris
	meteorExp:ScaleTo(startScale)
	meteorExp:PivotTo(CFrame.new(finalCF.Position))
	meteorExp.Parent = workspace.Debris
	SC.playSoundLocal3D(SOUND_FLY, meteorModel:GetPivot().Position)

	FXUtil.Start_All_Emit(meteorModel, METEOR_EMIT_DURATION)
	for _, v in pairs(meteorModel:GetDescendants()) do
		if v:IsA("Beam") then
			v.Enabled = true
			FXUtil.Beam_Fade_From_Transparent(v, BEAM_FADE_IN, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		end
		if v:IsA("MeshPart") then
			v.Transparency = 0
		end
	end

	local runData = Data.skillRunData
	local runEvent = _ensureRunEvent(runData)
	local totalTime = 0
	_disconnectRunEvent(runEvent, EVENT_FALL)
	local fallId = CombatWorld.allocId(COMBAT_FALL_ID_PREFIX)
	runEvent[EVENT_FALL] = CombatWorld.register(fallId, function(dt)
		totalTime += dt
		local percent = TweenService:GetValue(
			math.clamp(totalTime / METEOR_MOVE_TIME, 0, 1),
			Enum.EasingStyle.Quad,
			Enum.EasingDirection.In
		)
		meteorModel:PivotTo(startCF:Lerp(finalCF, percent))

		if percent >= 1 then
			_disconnectRunEvent(runEvent, EVENT_FALL)
			_playMeteorLandFx(Data, meteorModel, meteorExp, finalCF, startScale)
		end
	end, CombatWorld.Phase.SkillRuntime)
end

--[[
	退出坠落：断开客户端移动连接。

	@param Data BaseSkillClient - 客户端技能实例
]]
function module.Client_ExitMeteorFalling(Data: BaseSkillClient)
	local runData = Data.skillRunData
	_disconnectRunEvent(runData and runData.runEvent, EVENT_FALL)
end

--[[
	坠落服务端：贴地后短窗激活 Hitbox。

	@param Data BaseSkillServer - 服务端技能实例
]]
function module.Server_EnterMeteorFalling(Data: BaseSkillServer)
	PlayerAimSync.refreshAimSnapshot(Data)

	local hitbox1 = Data.hitbox[1]
	if not hitbox1 then
		return
	end

	local hitboxPart = hitbox1.hitbox
	local endCF = _resolveGroundedEndCF(Data.skillInputData.targetCF, SERVER_LAND_Y_OFFSET)
	local startScale = SC.scaleBandFromData(Data, SC.bandScaleOptsFromSkillData(Data))
	hitboxPart.Size = HITBOX_LAND_SIZE * startScale
	hitboxPart:PivotTo(CFrame.new(endCF.Position))

	local runData = Data.skillRunData
	local runEvent = _ensureRunEvent(runData)
	local totalTime = 0
	local enableAction = false
	_disconnectRunEvent(runEvent, EVENT_HITBOX)
	local hitboxTickId = CombatWorld.allocId(COMBAT_HITBOX_ID_PREFIX)
	runEvent[EVENT_HITBOX] = CombatWorld.register(hitboxTickId, function(dt)
		totalTime += dt
		if totalTime >= METEOR_MOVE_TIME - HITBOX_WINDOW and not enableAction then
			enableAction = true
			hitbox1:start()
			return
		end
		if totalTime >= METEOR_MOVE_TIME + HITBOX_WINDOW then
			_disconnectRunEvent(runEvent, EVENT_HITBOX)
			hitbox1:stop()
		end
	end, CombatWorld.Phase.Hitbox)
end

--[[
	退出坠落服务端：停 Hitbox、断连接。

	@param Data BaseSkillServer - 服务端技能实例
]]
function module.Server_ExitMeteorFalling(Data: BaseSkillServer)
	local runData = Data.skillRunData
	_disconnectRunEvent(runData and runData.runEvent, EVENT_HITBOX)
	local hitbox1 = Data.hitbox[1]
	if hitbox1 and hitbox1.isActive then
		hitbox1:stop()
	end
end

-- ========================================
-- 状态：Recovery / 结束
-- ========================================

--[[
	Recovery 服务端：放权。

	@param Data BaseSkillServer - 服务端技能实例
]]
function module.Server_EnterRecovery(Data: BaseSkillServer)
	Data:releaseControl()
end

--[[
	Recovery 客户端：确保尾迹关闭。

	@param Data BaseSkillClient - 客户端技能实例
]]
function module.Client_EnterRecovery(Data: BaseSkillClient)
	_cleanupMeteorTrail(Data)
end

--[[
	客户端技能结束：打断 / ForceFinish 不经 Recovery 时兜底关尾迹。
	框架随后 CleanupAllConns，此处只关发射器并 Disconnect 尾迹键。

	@param Data BaseSkillClient - 客户端技能实例
]]
function module.onEnd(Data: BaseSkillClient)
	_cleanupMeteorTrail(Data)
end

-- ========================================
-- 配置
-- ========================================
module.SoundList = {
	SOUND_FLY,
	SOUND_EXPLODE,
}
module.AnimateList = { ANIM_CAST }
module.ResNameList = {
	RES_EXPLOSION,
	RES_CIRCLE,
	RES_METEOR,
	RES_TRAIL,
}

module.hitboxConfig = {
	{
		HitboxIndex = 1,
		PartName = HITBOX_PART,
		CollisionGroup = HITBOX_COLLISION_GROUP,
		EffectName = HIT_EFFECT_NAME,
		SoundName = HIT_SOUND_NAME,
		PhysicsEffectName = PHYS_EFFECT_NAME,
	},
}

module.Action = {
	{ action = "LookAt", startTime = 0, overTime = STARTUP_DURATION, speedType = LOOKAT_SPEED_TYPE },
	{
		action = "Animation",
		startTime = 0,
		overTime = ANIM_OVER_TIME,
		animationName = ANIM_CAST,
		animationSpeed = ANIM_SPEED,
		animationPriority = Enum.AnimationPriority.Action4,
		animationFadeTime = ANIM_FADE_TIME,
	},
}

return module
