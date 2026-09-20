--[[
	Module: NewRoll
	Description: 长冲翻滚（保留闪现 VFX 前段）。位移经 DashStyleRoll → CharacterMotion。
	Author: 林奥宇
	Created: 2026-07-30
	Last Modified: 2026-09-01

	长冲主轴（Forward）：
	- Travel = Rolling = TRAVEL_FORWARD_SEC(0.4)；controlUnlock=0.38（可略早于电机）
	- 无敌 INVULN_SEC=0.35（嵌在 Travel 前段，≠ 全程无敌）
	- CancelWindow ⊆ 解锁前（约 0.25–0.38）；须侧/后转向
	- 闪现 FX UnFade@0.30 落在长冲前段；Action overTime 仅表现后摇
	- 取消衔步：earlyEndBoostScale（前 0.55 / 侧后 0.5），peak 由 |lastPlanar| 推导
	- LockMovement 为 Travel 从属；服 WudiPlr(INVULN) + 包络观测窗；ExitRolling 关窗
	- 解锁后动画：延后放 ActionLock；接走/跑用 StopAnim(FadeTime)；无操作翻滚可播完
	- DriveEndBlend：有移向 0.30 / 无操作 0.525，QuadOut；尾速 endFactor=0.12

	功能：
	- 状态机 Startup -> Rolling -> Recovery -> Finished（可 Interrupt / ForceFinish）
	- 客户端表现：NewRoll.Fx（时间轴 / soft-merge catch-up）
	- 服务端：Rolling 无敌 + 位移包络观测（不拉回）；ExitRolling / onEndServer 关窗

	模块关系：
	- 位移：ToolSystem/CharacterMotion；Gate：DashStyleRoll + SkillActionLock
	- 表现：script.Fx；方向解析在 Fx 内
	- 与旧 Roll 并存；本模块不修改 Roll

	加载方式：
	-- 由技能框架按 SkillModule 名「NewRoll」require，业务勿直接调用
	local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

	示例：
	module.Action[1].directionConfig.Forward.tweenDuration = 0.4
	module.Action[1].directionConfig.Forward.controlUnlockTime = 0.38
	module.Action[2].directionConfig.Forward.overTime = 0.38
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local EnumMgr = Utils.EnumMgr
local ElementTp = EnumMgr.ElementTp
local Class = require(game.ReplicatedFirst.AllSideCode.Class.Class)
local EVT = require(script.Parent.Parent.BaseSkill.SkillEventConst)
local SystemPlrAttr = Utils.SystemPlrAttr
local FindPlayerByID = Utils.FindPlayerByID
local Players = Utils.Players
local RunService = Utils.RunService
local Fx = require(script.Fx)

-- §1.4：仅按端加载服务端 Utils 键（客户端访问会路径 warn）；非业务 IsServer 分支
local SystemCharacterMotion = nil
if RunService:IsServer() then
	SystemCharacterMotion = Utils.SystemCharacterMotion
end

type BaseSkillClient = Class.BaseSkillClient
type BaseSkillServer = Class.BaseSkillServer

local module = {}

-- ========================================
-- 常量
-- ========================================
-- Forward Travel / Rolling（与 Recipes.NewRoll.Forward.tweenDuration 对齐）
local TRAVEL_FORWARD_SEC = 0.4
-- 无敌嵌在 Travel 前段，不与全程位移等长
local INVULN_SEC = 0.35
local CONTROL_UNLOCK_FORWARD_SEC = 0.38

local RECOVERY_DURATION_SEC = 1.15
local SKILL_TOTAL_TIME_SEC = 1.98
local VISUAL_FADEOUT_TIME_SEC = 2.4
local ACTION_OVER_TIME_SEC = 2.3

local TRAVEL_BACKWARD_SEC = 0.4
local CONTROL_UNLOCK_BACKWARD_SEC = 0.4
local OVER_TIME_BACKWARD_SEC = 0.9
local PLANE_SPEED_BACKWARD = 65

local TRAVEL_SIDE_SEC = 0.45
local CONTROL_UNLOCK_SIDE_SEC = 0.45
local OVER_TIME_SIDE_SEC = 1
local PLANE_SPEED_SIDE = 70

local PLANE_SPEED_FORWARD = 80
local VECTOR_END_FACTOR_FORWARD = 0.12
local VECTOR_END_FACTOR_OTHER = 0.05
local EARLY_END_BOOST_SCALE_FORWARD = 0.55
local EARLY_END_BOOST_SCALE_OTHER = 0.5
local EARLY_END_BOOST_DURATION_SEC = 0.22

local ANIM_SPEED_FORWARD = 1.0
local ANIM_SPEED_OTHER = 1.3
local ANIM_FADE_IN_FORWARD_SEC = 0.05
local ANIM_FADE_IN_DEFAULT_SEC = 0.25
local ANIM_FADE_DEFAULT_SEC = 0.25

local CANCEL_OFFSET_FORWARD_SEC = 0.25
local CANCEL_WINDOW_FORWARD_SEC = 0.13
local CANCEL_OFFSET_BACKWARD_SEC = 0.20
local CANCEL_WINDOW_BACKWARD_SEC = 0.20
local CANCEL_OFFSET_SIDE_SEC = 0.25
local CANCEL_WINDOW_SIDE_SEC = 0.18

-- ========================================
-- 模块字段 / 状态机
-- ========================================
-- Rolling + Recovery：给翻滚尾段与 DriveEndBlend 留够时间
module.skillTotalTime = SKILL_TOTAL_TIME_SEC
module.visualFadeoutTime = VISUAL_FADEOUT_TIME_SEC
module.skillElementType = ElementTp.None

module.InitialState = "Startup"
-- 进入该状态时允许派生/放权（翻滚已提交）
module.ControlOpenState = "Recovery"

module.States = {
	Startup = {
		Duration = 0,
		OnEnterClient = nil,
		OnEnterServer = nil,
		OnExitClient = nil,
		OnExitServer = nil,
	},
	-- Duration 取 Forward 主轴；侧向电机 TRAVEL_SIDE_SEC=0.45，包络可能早约 50ms 关（手感待策划确认，勿擅自改钟）
	Rolling = {
		Duration = TRAVEL_FORWARD_SEC,
		OnEnterClient = "Client_EnterRolling",
		OnEnterServer = "Server_EnterRolling",
		OnExitClient = "Client_ExitRolling",
		OnExitServer = "Server_ExitRolling",
	},
	Recovery = {
		Duration = RECOVERY_DURATION_SEC,
		OnEnterClient = nil,
		OnEnterServer = nil,
		OnExitClient = nil,
		OnExitServer = nil,
	},
	Finished = { Duration = 0, IsTerminal = true },
	Interrupted = { Duration = 0, IsTerminal = true },
}

module.Transitions = {
	{ From = "Startup", To = "Rolling", Event = EVT.StateTimeout },
	{ From = "Rolling", To = "Recovery", Event = EVT.StateTimeout },
	{ From = "Recovery", To = "Finished", Event = EVT.StateTimeout },
	{ From = "Startup", To = "Interrupted", Event = EVT.Interrupt },
	{ From = "Rolling", To = "Interrupted", Event = EVT.Interrupt },
	{ From = "Startup", To = "Finished", Event = EVT.ForceFinish },
	{ From = "Rolling", To = "Finished", Event = EVT.ForceFinish },
	{ From = "Recovery", To = "Finished", Event = EVT.ForceFinish },
}

-- ========================================
-- 私有函数
-- ========================================

--[[
	解析玩家：优先 FindPlayerByID，回退 Players:GetPlayerByUserId。

	@param characterId number | string - 角色/用户 Id；非数字字符串则回退失败
	@return Player? - 在线玩家；找不到为 nil
]]
local function _resolvePlayer(characterId: number | string): Player?
	local player = FindPlayerByID and FindPlayerByID.Find(characterId)
	if player then
		return player
	end
	if not Players then
		return nil
	end
	local userId = tonumber(characterId)
	if not userId then
		return nil
	end
	return Players:GetPlayerByUserId(userId)
end

--[[
	构造侧向（Left/Right）DashStyleRoll 方向配置。每次返回新表，避免框架写 overTime 时左右互扰。

	@return { overTime: number, tweenDuration: number, controlUnlockTime: number, planeSpeed: number, vectorEndFactor: number, earlyEndBoostScale: number, animationSpeed: number, animationFadeInTime: number, animationFadeTime: number, moveInterruptWindowOffset: number, moveInterruptWindowTime: number } - 与 directionConfig.Left/Right 字段一致
]]
local function _makeSideDashDirectionConfig()
	return {
		overTime = OVER_TIME_SIDE_SEC,
		tweenDuration = TRAVEL_SIDE_SEC,
		controlUnlockTime = CONTROL_UNLOCK_SIDE_SEC,
		planeSpeed = PLANE_SPEED_SIDE,
		vectorEndFactor = VECTOR_END_FACTOR_OTHER,
		earlyEndBoostScale = EARLY_END_BOOST_SCALE_OTHER,
		animationSpeed = ANIM_SPEED_OTHER,
		animationFadeInTime = ANIM_FADE_IN_FORWARD_SEC,
		animationFadeTime = ANIM_FADE_DEFAULT_SEC,
		moveInterruptWindowOffset = CANCEL_OFFSET_SIDE_SEC,
		moveInterruptWindowTime = CANCEL_WINDOW_SIDE_SEC,
	}
end

--[[
	关闭 NewRoll 能力位移包络窗（ExitRolling / onEndServer 共用）。

	@param Data BaseSkillServer - 服务端技能实例；读 characterType / characterId / skillCastId
]]
local function _closeAbilityEnvelope(Data: BaseSkillServer)
	if not SystemCharacterMotion or not SystemCharacterMotion.CloseWindow then
		return
	end
	if not Data or Data.characterType ~= "Player" then
		return
	end
	local player = _resolvePlayer(Data.characterId)
	if player then
		local castId = Data.skillCastId or tostring(Data.characterId)
		SystemCharacterMotion.CloseWindow(player, string.format("Skill:NewRoll:%s", tostring(castId)))
	end
end

-- ========================================
-- 公共函数（状态回调）
-- ========================================

--[[
	客户端进入 Rolling：委托 Fx.enterRolling。

	@param Data BaseSkillClient - 客户端技能实例
]]
function module.Client_EnterRolling(Data: BaseSkillClient)
	Fx.enterRolling(Data)
end

--[[
	soft-merge 表现追赶：委托 Fx.softMergeCatchUp。

	@param Data BaseSkillClient - 正式段基础技能
	@param softMergeSnap { nowTime: number, state: string, enteredAt: number? }? - 合并快照
]]
function module.onSoftMergePresentationCatchUp(Data: BaseSkillClient, softMergeSnap: any?)
	Fx.softMergeCatchUp(Data, softMergeSnap)
end

--[[
	客户端离开 Rolling：委托 Fx.exitRolling。

	@param Data BaseSkillClient - 客户端技能实例
]]
function module.Client_ExitRolling(Data: BaseSkillClient)
	Fx.exitRolling(Data)
end

--[[
	服务端进入 Rolling：对玩家施加闪避无敌帧并开包络观测窗。

	@param Data BaseSkillServer - 服务端技能实例
]]
function module.Server_EnterRolling(Data: BaseSkillServer)
	if not Data or Data.characterType ~= "Player" then
		return
	end
	-- 主轴：无敌嵌在 Travel 前段（INVULN_SEC），非全程无敌
	if SystemPlrAttr and SystemPlrAttr.WudiPlr then
		SystemPlrAttr.WudiPlr(Data.characterId, INVULN_SEC)
	end
	-- 正式确认后开位移包络观测窗（不拉回；与无敌窗解耦）
	if not SystemCharacterMotion or not SystemCharacterMotion.OpenWindow then
		return
	end
	local player = _resolvePlayer(Data.characterId)
	if not player then
		return
	end
	local dir = Data.skillInputData and Data.skillInputData.moveDirectionStr
	local castId = Data.skillCastId or tostring(Data.characterId)
	local sessionId = string.format("Skill:NewRoll:%s", tostring(castId))
	SystemCharacterMotion.OpenWindow(player, sessionId, "NewRoll", dir)
end

--[[
	服务端离开 Rolling：Travel 结束即关观测窗。

	@param Data BaseSkillServer - 服务端技能实例
]]
function module.Server_ExitRolling(Data: BaseSkillServer)
	_closeAbilityEnvelope(Data)
end

--[[
	服务端技能结束：关闭位移包络窗（Interrupted / ForceFinish 兜底）。

	@param Data BaseSkillServer - 服务端技能实例；读 characterType / characterId / skillCastId
]]
function module.onEndServer(Data: BaseSkillServer)
	_closeAbilityEnvelope(Data)
end

--[[
	技能结束兜底：委托 Fx.onEnd（FadeCharacter UnFade + 烟尘连接）。

	@param Data BaseSkillClient | BaseSkillServer - 技能实例；客读 skillRunData.FadeCharacter / runEvent，服端通常无 Fade 字段
]]
function module.onEnd(Data: BaseSkillClient | BaseSkillServer)
	Fx.onEnd(Data)
end

-- ========================================
-- 资源配置
-- ========================================
module.SoundList = {
	Fx.SOUND_FORWARD_BIG,
	Fx.SOUND_FORWARD_SMALL,
	Fx.SOUND_SIDE,
}
module.AnimateList = {
	"RollForward",
	"RollBackward",
	"RollLeft",
	"RollRight",
}

module.ResNameList = {
	Fx.RES_SMOKE,
	Fx.RES_BLINK_START,
	Fx.RES_BLINK_END,
}

module.hitboxConfig = {}

module.Action = {
	{
		action = "DashStyleRoll",
		-- 同角色仅保留最新翻滚 Action，新开滚前 Over 旧实例（与 SkillActionExclusive 配合）
		allowParallelTracks = false,
		startTime = 0,
		overTime = ACTION_OVER_TIME_SEC,
		animationNameForward = "RollForward",
		animationNameBackward = "RollBackward",
		animationNameLeft = "RollLeft",
		animationNameRight = "RollRight",
		-- 全局默认；各向可覆盖 animationFadeInTime / animationFadeTime /
		-- animationStopFadeTime / moveInterruptWindowOffset / moveInterruptWindowTime
		animationSpeed = 1,
		animationPriority = Enum.AnimationPriority.Action3,
		animationFadeInTime = ANIM_FADE_IN_DEFAULT_SEC,
		animationFadeTime = ANIM_FADE_DEFAULT_SEC,
		earlyEndBoostDuration = EARLY_END_BOOST_DURATION_SEC,
		-- 不定死 peak：按打断瞬间 |lastPlanar| * scale 推导（见 CharacterMotion.Interrupt）
		earlyEndBoostScale = EARLY_END_BOOST_SCALE_FORWARD,
		earlyEndBoostEasingStyle = Enum.EasingStyle.Quad,
		earlyEndBoostEasingDirection = Enum.EasingDirection.Out,
		directionConfig = {
			-- 长冲：Travel；解锁略早；Cancel ⊆ 解锁前
			Forward = {
				overTime = ACTION_OVER_TIME_SEC,
				tweenDuration = TRAVEL_FORWARD_SEC,
				controlUnlockTime = CONTROL_UNLOCK_FORWARD_SEC,
				planeSpeed = PLANE_SPEED_FORWARD,
				vectorEndFactor = VECTOR_END_FACTOR_FORWARD,
				earlyEndBoostScale = EARLY_END_BOOST_SCALE_FORWARD,
				animationSpeed = ANIM_SPEED_FORWARD,
				animationFadeInTime = ANIM_FADE_IN_FORWARD_SEC,
				animationFadeTime = ANIM_FADE_DEFAULT_SEC,
				moveInterruptWindowOffset = CANCEL_OFFSET_FORWARD_SEC,
				moveInterruptWindowTime = CANCEL_WINDOW_FORWARD_SEC,
			},
			Backward = {
				overTime = OVER_TIME_BACKWARD_SEC,
				tweenDuration = TRAVEL_BACKWARD_SEC,
				controlUnlockTime = CONTROL_UNLOCK_BACKWARD_SEC,
				planeSpeed = PLANE_SPEED_BACKWARD,
				vectorEndFactor = VECTOR_END_FACTOR_OTHER,
				earlyEndBoostScale = EARLY_END_BOOST_SCALE_OTHER,
				animationSpeed = ANIM_SPEED_OTHER,
				animationFadeInTime = ANIM_FADE_IN_FORWARD_SEC,
				animationFadeTime = ANIM_FADE_DEFAULT_SEC,
				moveInterruptWindowOffset = CANCEL_OFFSET_BACKWARD_SEC,
				moveInterruptWindowTime = CANCEL_WINDOW_BACKWARD_SEC,
			},
			Left = _makeSideDashDirectionConfig(),
			Right = _makeSideDashDirectionConfig(),
		},
	},
	-- Travel 从属：锁速时长 = 各向 controlUnlock
	{
		action = "LockMovement",
		startTime = 0,
		overTime = ACTION_OVER_TIME_SEC,
		speedMultiplier = 0,
		directionConfig = {
			Forward = { overTime = CONTROL_UNLOCK_FORWARD_SEC },
			Backward = { overTime = CONTROL_UNLOCK_BACKWARD_SEC },
			Left = { overTime = CONTROL_UNLOCK_SIDE_SEC },
			Right = { overTime = CONTROL_UNLOCK_SIDE_SEC },
		},
	},
}

return module
