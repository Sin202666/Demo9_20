--[[
	Module: SpaceSkill1
	Description: 空间技能基础段（纯表现）。各特效为 ModelRes/Skill 独立 Model；PartIcles 播粒；按 Cue 对位。
	Author: 林奥宇
	Created: 2026-08-03
	Last Modified: 2026-08-28

	Lighting：Acquire/Release 天气 lease（writerId=SpaceSkill1），不缓存 prev；释放后 reconcile 到世界基线。
	主流程：Active（整段 MA2 时长）-> Recovery -> Finished
	决策：D2 运镜仅施法者；D3 DualPath；D4 Cue 硬编码；D6 suppressShake；D7 无预测；D8 无 Hitbox。
	一期 A：表现主循环经 Utils.CombatWorld.register（禁止 Heartbeat:Connect 逻辑 Tick）。
	资源：与 Meteor1 相同——ResNameList 顶层独立 Model，material[name] 取用（勿再挂整树「空间技能特效」）。

	位姿：
	  BakedLocal：MA2 初始相对 HRP 的 localCF（SpaceSkillKeys.ResInitialLocalCF）
	               运行时 PivotTo(castAnchor * localCF)；勿再硬贴 castAnchor / 手工下移
	  LiveTorso：每帧跟 UpperTorso/Torso（空间技能2_1 / 空间技能2_2 / 空间技能角色能量特效）
	  早期 Burst（空间技能1_2 / 角色能量）：EnterActive 即摆进 Debris + silence（对齐裂隙），Cue 只 AbsoluteEmit
	裂隙（对齐 MA2）：开场摆整模；Burst Cue 只 AbsoluteEmit 子 Part（*_Burst）；
	  Beam 先关，RiftBeamsOn 再开 + Width 曲线（Width→0 收束，无 Enabled 关轨）
	播粒：Utils.PartIcles AbsoluteEmit（MA2 width=0）；Teardown 不对 FX AbsoluteEmit 硬停，粒子自然消散
	  BodyEnergy：原 MA2 Track5 `2_FX_BodyEngry` codeBegin = AbsoluteEmit（无 Enabled 轨 / 无关窗）
	  会话清理：运镜/Lighting/CC 曲线/Beam 曲线句柄/DualPath；连续层按 MA2 关窗收口（Trail/Rate@F408）
	双球粒子（对齐 MA2 Track29/30）：F196/F204 对 5_LightBall/5_DarkBall
	  Emit 一次后开 Rate；F408（ballRateDisableAt）关 Rate（MA2 无 PE Enabled 轨，与 Trail 同关）
	  子 Part 每帧贴壳
	双球：appearStart 起 DualPath；Trail = phaseTimeline F227→F408

	Studio（Assets/ModelRes/Skill 顶层同名 Model）：
	  空间技能1_2蓄力地面, 空间技能角色能量特效, 空间技能2_1起跳吸收, 空间技能2_2吸收后爆发,
	  空间技能3_1空间裂隙_暗, 空间技能3_2空间裂隙_光,
	  空间技能4_1黑球, 空间技能4_2白球, 空间技能4_3中心,
	  空间技能5_1大蓄力, 空间技能5_2最终爆发, 空间技能5_3最终爆发2, 空间技能5_3最终爆发3
	Lighting：Assets/LightingConfig/空间技能
	动画：空间运镜技能
	音效（与 Cue 同钟，见 SOUND_CUES）：
	  起跳 t=0 进 Active；蓄力对齐 Absorb@2.1 - 0.5s；爆炸对齐 FinalBurst@6.25 + 1.80s
	  本机施法者 2D（运镜拉远不被 3D 衰减）；旁观 3D 挂 HRP
	  爆炸起时淡出蓄力；打断 / Teardown 按 SoundTag 淡出
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local ElementTp = Utils.EnumMgr.ElementTp
local Class = require(game.ReplicatedFirst.AllSideCode.Class.Class)
local EVT = require(script.Parent.Parent.BaseSkill.SkillEventConst)
local CameraModule = Utils.CameraModule
local FXUtil = Utils.FXUtil
local PartIcles = Utils.PartIcles
local KeyframeEval = Utils.KeyframeEval
local AnchorRelative = Utils.AnchorRelative
local CombatWorld = Utils.CombatWorld
local LocalPlayer = Utils.LocalPlayer
local SoundModule = Utils.SoundModule
local NetWork = Utils.NetWork
local NetMsg = Utils.NetMsg

local DualPathBallRuntime = require(script.Parent.Parent.Presentation.DualPathBallRuntime)
local SpaceSkillKeys = require(script.Parent.Parent.Presentation.SpaceSkillKeys)

type BaseSkillClient = Class.BaseSkillClient
type BaseSkillServer = Class.BaseSkillServer

local module = {}

-- ========================================
-- 常量 / 资源名（= ModelRes/Skill 下 Model.Name）
-- ========================================
local DURATION = SpaceSkillKeys.DURATION
local RECOVERY_DURATION = 0.35
local CAM_PRIORITY = 120
local ENABLE_SPACE_SKILL_CAM = true
local EVENT_PRESENTATION = "SpaceSkillPresentation"
local CAM_EVENT_NAME = SpaceSkillKeys.CAM_EVENT_NAME
local ANIM_CAST = "空间运镜技能"
local LIGHTING_CONFIG_NAME = "空间技能"
local LIGHTING_WRITER_ID = "SpaceSkill1"
local LIGHTING_ENTER_SEC = 0.25
local LIGHTING_EXIT_SEC = 0.5
local LIGHTING_PRIORITY = Utils.EnumMgr.WeatherWriterPriority.Skill
-- 技能表现上限 + 裕量；异常未 RELEASE 时由 LightingManager TTL 扫掉
local LIGHTING_LEASE_TTL_SEC = 45

local RES = {
	ChargeGround = "空间技能1_2蓄力地面",
	-- 原 MA2 Track5 Part `2_FX_BodyEngry` → 独立 Model
	BodyEnergy = "空间技能角色能量特效",
	AirAbsorb = "空间技能2_1起跳吸收",
	AirBurst = "空间技能2_2吸收后爆发",
	RiftDark = "空间技能3_1空间裂隙_暗",
	RiftLight = "空间技能3_2空间裂隙_光",
	BallDark = "空间技能4_1黑球",
	BallLight = "空间技能4_2白球",
	Center = "空间技能4_3中心",
	BigCharge = "空间技能5_1大蓄力",
	FinalBurst = "空间技能5_2最终爆发",
	FinalBurst2 = "空间技能5_3最终爆发2",
	FinalBurst3 = "空间技能5_3最终爆发3",
}

local BALL_LIGHT_PART = "白球"
local BALL_DARK_PART = "黑球"
-- MA2 Track30/29：双球粒子 codeBegin 宿主（白/黑球壳下的子 Part）
local BALL_LIGHT_EMIT_PART = "5_LightBall"
local BALL_DARK_EMIT_PART = "5_DarkBall"
-- MA2 Track25/26：Burst Cue 只打这两个子 Part（非整模）
local RIFT_DARK_BURST_PART = "4_空间裂隙_An_Burst"
local RIFT_LIGHT_BURST_PART = "4_空间裂隙_liang_Burst"

-- 技能音效：时间轴与 VFX Cue 对齐（Absorb / FinalBurst），不另开 Heartbeat
local SOUND_JUMP = "音效-技能-空间技能-起跳"
local SOUND_CHARGE = "音效-技能-空间技能-蓄力"
local SOUND_EXPLODE = "音效-技能-空间技能-爆炸"
local SOUND_FADE_HANDOFF = 0.12
local SOUND_FADE_INTERRUPT = 0.2
-- 起跳进 Active；蓄力=Absorb - 0.5s（1.6）；爆炸=FinalBurst + 1.80s（8.05）
local SOUND_CUES = {
	{ t = 0, id = "Jump", sound = SOUND_JUMP },
	{ t = 1.6, id = "Charge", sound = SOUND_CHARGE },
	{ t = 8.05, id = "Explode", sound = SOUND_EXPLODE, stopIds = { "Charge" } },
}

-- Cue 名 → 资源与对位
-- ChargeGround/BodyEnergy：EnterActive 预摆 + silence（贴图流送窗口）；Cue 只 AbsoluteEmit
-- BodyEnergy：原 MA2 Track5 挂 Torso + AbsoluteEmit(width=0) → LiveTorso follow
-- Light/DarkBallEmit：MA2 F196/F204 → 5_* Emit+开 Rate；关窗见 PhaseTimeline.ballRateDisableAt
-- Rift*Burst：emitChild = MA2 Burst 宿主；Beam 仍走 RiftBeamsOn + Width
local CUE_FX = {
	ChargeGround = {
		res = RES.ChargeGround,
		pose = "BakedLocal",
		alreadyPlaced = true,
	},
	BodyEnergy = {
		res = RES.BodyEnergy,
		pose = "LiveTorso",
		follow = true,
		alreadyPlaced = true,
	},
	Absorb = { res = RES.AirAbsorb, pose = "LiveTorso", follow = true },
	RiftLightBurst = {
		res = RES.RiftLight,
		pose = "BakedLocal",
		alreadyPlaced = true,
		emitChild = RIFT_LIGHT_BURST_PART,
	},
	RiftDarkBurst = {
		res = RES.RiftDark,
		pose = "BakedLocal",
		alreadyPlaced = true,
		emitChild = RIFT_DARK_BURST_PART,
	},
	AirBurst = { res = RES.AirBurst, pose = "LiveTorso", follow = true },
	LightBallEmit = {
		res = RES.BallLight,
		pose = "None",
		alreadyPlaced = true,
		ballEmitPart = BALL_LIGHT_EMIT_PART,
		ballShellKey = "lightBall",
	},
	DarkBallEmit = {
		res = RES.BallDark,
		pose = "None",
		alreadyPlaced = true,
		ballEmitPart = BALL_DARK_EMIT_PART,
		ballShellKey = "darkBall",
	},
	Center = { res = RES.Center, pose = "BakedLocal" },
	-- MA2 Track27/28/31/32：codeBegin = AbsoluteEmit + width=0
	BigCharge = { res = RES.BigCharge, pose = "BakedLocal" },
	FinalBurst = { res = RES.FinalBurst, pose = "BakedLocal" },
	FinalBurst2 = { res = RES.FinalBurst2, pose = "BakedLocal" },
	FinalBurst3 = { res = RES.FinalBurst3, pose = "BakedLocal" },
}

-- ========================================
-- 模块字段 / 状态机
-- ========================================
module.skillTotalTime = -1
module.visualFadeoutTime = 1
module.skillElementType = ElementTp.None

module.InitialState = "Active"
module.ControlOpenState = "Recovery"

module.States = {
	Active = {
		Duration = DURATION,
		OnEnterClient = "Client_EnterActive",
		OnEnterServer = nil,
		OnExitClient = "Client_ExitActive",
		OnExitServer = nil,
	},
	Recovery = {
		Duration = RECOVERY_DURATION,
		OnEnterClient = nil,
		OnEnterServer = "Server_EnterRecovery",
		OnExitClient = nil,
		OnExitServer = nil,
	},
	Finished = { Duration = 0, IsTerminal = true },
	Interrupted = {
		Duration = 0,
		IsTerminal = true,
		OnEnterClient = "Client_EnterInterrupted",
		OnEnterServer = nil,
	},
}

module.Transitions = {
	{ From = "Active", To = "Recovery", Event = EVT.StateTimeout },
	{ From = "Recovery", To = "Finished", Event = EVT.StateTimeout },
	{ From = "Active", To = "Interrupted", Event = EVT.Interrupt },
	{ From = "Recovery", To = "Interrupted", Event = EVT.Interrupt },
	{ From = "Active", To = "Finished", Event = EVT.ForceFinish },
	{ From = "Recovery", To = "Finished", Event = EVT.ForceFinish },
}

-- ========================================
-- 私有工具
-- ========================================

--[[
	是否本机施法者。
	@param Data BaseSkillClient - 客户端技能实例
	@return boolean - 是否本机施法者
]]
local function _isLocalPlayerCaster(Data: BaseSkillClient): boolean
	local character = Data.skillInputData and Data.skillInputData.character
	return LocalPlayer and character ~= nil and LocalPlayer.Character == character
end

--[[
	取施法者 HRP 与施法瞬间完整 CFrame 快照。
	@param Data BaseSkillClient - 客户端技能实例
	@return (BasePart?, CFrame?) - HRP 与其 CFrame；缺失为 nil
]]
local function _resolveHrp(Data: BaseSkillClient): (BasePart?, CFrame?)
	local character = Data.skillInputData and Data.skillInputData.character
	if not character then
		return nil, nil
	end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		return hrp, hrp.CFrame
	end
	return nil, nil
end

--[[
	解析活躯干附着点。
	@param character Model - 施法者角色
	@return BasePart? - UpperTorso / Torso / HRP；缺失为 nil
]]
local function _resolveTorsoAttachPart(character: Model): BasePart?
	local upper = character:FindFirstChild("UpperTorso")
	if upper and upper:IsA("BasePart") then
		return upper
	end
	local torso = character:FindFirstChild("Torso")
	if torso and torso:IsA("BasePart") then
		return torso
	end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		return hrp
	end
	return nil
end

--[[
	Anchored 准备（去 Weld）。
	@param node Instance - 特效 Model 或 BasePart
]]
local function _prepareAnchored(node: Instance)
	for _, d in node:GetDescendants() do
		if d:IsA("WeldConstraint") then
			d:Destroy()
		elseif d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.Massless = true
		end
	end
	if node:IsA("BasePart") then
		node.Anchored = true
		node.CanCollide = false
		node.Massless = true
	end
end

--[[
	按 MA2 烘焙初始 localCF 摆到施法锚点相对位（完整 CFrame；PivotTo = 模型 WorldPivot）。
	@param model Instance - 要摆位的特效 Model 或 BasePart
	@param castAnchor CFrame - 施法瞬间 HRP 快照
	@param resName string - ResNameList / ResInitialLocalCF 键
]]
local function _placeAtBakedLocal(model: Instance, castAnchor: CFrame, resName: string)
	_prepareAnchored(model)
	local localCF = SpaceSkillKeys.ResInitialLocalCF and SpaceSkillKeys.ResInitialLocalCF[resName]
	local worldCF = if typeof(localCF) == "CFrame" then AnchorRelative.ToWorld(castAnchor, localCF) else castAnchor
	if model:IsA("Model") then
		model:PivotTo(worldCF)
	elseif model:IsA("BasePart") then
		model.CFrame = worldCF
	end
	model.Parent = workspace.Debris
end

--[[
	取 material 中的特效 Model。
	@param material table? - Data.material 资源表；nil 则返回 nil
	@param name string - ResNameList 键
	@return Instance? - 对应特效实例
]]
local function _getMaterial(material: any, name: string): Instance?
	if not material then
		return nil
	end
	return material[name]
end

--[[
	在模型内找可驱动的球 BasePart。
	@param root Instance - 球整模或 Part
	@param preferName string - 优先子名（如白球/黑球壳）
	@return BasePart? - 可驱动的球壳 Part
]]
local function _findBallPart(root: Instance, preferName: string): BasePart?
	local named = root:FindFirstChild(preferName, true)
	if named and named:IsA("BasePart") then
		return named
	end
	if root:IsA("Model") and root.PrimaryPart then
		return root.PrimaryPart
	end
	if root:IsA("BasePart") then
		return root
	end
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") then
			return d
		end
	end
	return nil
end

--[[
	PartIcles 爆发播粒。
	@param root Instance - 播粒根（整模或 Burst 子 Part）
]]
local function _particlesEmit(root: Instance)
	if PartIcles and PartIcles.AbsoluteEmit then
		PartIcles:AbsoluteEmit(root)
	end
end

--[[
	在已摆好的裂隙 Model 内取 Burst 宿主并 AbsoluteEmit（对齐 MA2 Track25/26）。
	@param riftRoot Instance? - 空间技能3_1 / 空间技能3_2 整模
	@param burstPartName string - 4_空间裂隙_*_Burst
]]
local function _emitRiftBurstChild(riftRoot: Instance?, burstPartName: string)
	if not riftRoot then
		return
	end
	local burst = riftRoot:FindFirstChild(burstPartName, true)
	if burst then
		_particlesEmit(burst)
	else
		_particlesEmit(riftRoot)
	end
end

--[[
	将 5_* 发射子 Part 贴到球壳（Anchored 子 Part 不会随父 CFrame 自动跟）。
	@param emitPart BasePart? - 发射子 Part；nil 则跳过
	@param shellPart BasePart? - 球壳 Part；nil 则跳过
]]
local function _snapEmitPartToShell(emitPart: BasePart?, shellPart: BasePart?)
	if emitPart and shellPart and emitPart.Parent and shellPart.Parent then
		emitPart.CFrame = shellPart.CFrame
	end
end

--[[
	开关已登记的双球 Rate PE（开窗内 Sustained；关窗对齐 MA2 Trail F408）。
	@param runFx table - 表现会话
	@param enabled boolean - true 开启 Rate；false 关闭
]]
local function _setBallRateEmittersEnabled(runFx: any, enabled: boolean)
	local list = runFx.ballRateEmitters
	if not list then
		return
	end
	for _, pe in list do
		if pe and pe.Parent then
			pe.Enabled = enabled
		end
	end
	runFx.ballRateOn = enabled
end

--[[
	MA2 双球粒子：对 5_LightBall/5_DarkBall 单次 Emit 后开启 Rate（不碰 Trail/Beam）。
	关窗由 _pumpCues 在 ballRateDisableAt（F408）统一关掉。
	@param runFx table - 表现会话
	@param ballModel Instance? - 空间技能4_1 / 空间技能4_2 整模
	@param shellPart BasePart? - 白球 / 黑球壳
	@param emitPartName string - 5_LightBall / 5_DarkBall
]]
local function _emitBallMa2Particles(runFx: any, ballModel: Instance?, shellPart: BasePart?, emitPartName: string)
	if not ballModel then
		return
	end
	local emitPart = ballModel:FindFirstChild(emitPartName, true)
	local target: Instance = ballModel
	if emitPart then
		local peCount = 0
		for _, d in emitPart:GetDescendants() do
			if d:IsA("ParticleEmitter") then
				peCount += 1
			end
		end
		if emitPart:IsA("ParticleEmitter") then
			peCount += 1
		end
		if peCount > 0 then
			target = emitPart
			if emitPart:IsA("BasePart") then
				_snapEmitPartToShell(emitPart, shellPart)
				runFx.ballEmitParts = runFx.ballEmitParts or {}
				table.insert(runFx.ballEmitParts, { emit = emitPart, shell = shellPart })
			end
		elseif shellPart then
			-- 5_* 无 PE 时，Rate/Burst 常挂在球壳 Attachment 上
			target = shellPart
		end
	elseif shellPart then
		target = shellPart
	end
	runFx.ballRateEmitters = runFx.ballRateEmitters or {}
	-- 只动 PE：Burst Emit + Rate Enabled；避免误开 Trail；关窗见 ballRateDisableAt
	local function firePe(pe: ParticleEmitter)
		table.insert(runFx.ballRateEmitters, pe)
		local emitDelayA = pe:GetAttribute("EmitDelay")
		local emitDelay = type(emitDelayA) == "number" and emitDelayA or 0
		local emitCountA = pe:GetAttribute("EmitCount")
		local emitCount = type(emitCountA) == "number" and emitCountA or 1
		if emitCount < 1 then
			emitCount = 1
		end
		task.spawn(function()
			if emitDelay > 0 then
				task.wait(emitDelay)
			end
			if not pe.Parent then
				return
			end
			-- 已过关窗则只 Burst、不再开 Rate
			local disableAt = SpaceSkillKeys.PhaseTimeline.ballRateDisableAt
			if type(disableAt) == "number" and type(runFx.elapsed) == "number" and runFx.elapsed >= disableAt then
				pe:Emit(emitCount)
				return
			end
			pe:Emit(emitCount)
			pe.Enabled = true
			runFx.ballRateOn = true
		end)
	end
	if target:IsA("ParticleEmitter") then
		firePe(target)
	end
	for _, d in target:GetDescendants() do
		if d:IsA("ParticleEmitter") then
			firePe(d)
		end
	end
end

--[[
	每帧把已出场的 5_* 贴回球壳。
	@param runFx table - 表现会话
]]
local function _syncBallEmitParts(runFx: any)
	local list = runFx.ballEmitParts
	if not list then
		return
	end
	for _, pair in list do
		_snapEmitPartToShell(pair.emit, pair.shell)
	end
end

--[[
	开关模型下全部 Trail。
	@param root Instance? - 特效根；nil 则跳过
	@param enabled boolean - 是否启用 Trail
]]
local function _setTrailsEnabled(root: Instance?, enabled: boolean)
	if not root then
		return
	end
	for _, d in root:GetDescendants() do
		if d:IsA("Trail") then
			d.Enabled = enabled
		end
	end
end

--[[
	开关模型下全部 Beam。
	@param root Instance? - 特效根；nil 则跳过
	@param enabled boolean - 是否启用 Beam
]]
local function _setBeamsEnabled(root: Instance?, enabled: boolean)
	if not root then
		return
	end
	for _, d in root:GetDescendants() do
		if d:IsA("Beam") then
			d.Enabled = enabled
		end
	end
end

--[[
	初始关闭 PE/Trail/Beam，避免未到 Cue 就冒烟。
	@param root Instance? - 特效根；nil 则跳过
]]
local function _silenceVfx(root: Instance?)
	if not root then
		return
	end
	if FXUtil.SetEmittersTrailsBeamsEnabled then
		FXUtil.SetEmittersTrailsBeamsEnabled(root, false)
	else
		_setTrailsEnabled(root, false)
		_setBeamsEnabled(root, false)
		for _, d in root:GetDescendants() do
			if d:IsA("ParticleEmitter") then
				d.Enabled = false
			end
		end
	end
end

--[[
	断开 runEvent 连接（RBXScriptConnection 或 CombatWorld Handle）。
	@param runEvent table? - Data.skillRunData.runEvent；nil 则跳过
	@param name string - 句柄键名
]]
local function _disconnectRunEvent(runEvent: any, name: string)
	if not runEvent then
		return
	end
	local conn = runEvent[name]
	if conn then
		if typeof(conn) == "RBXScriptConnection" or (type(conn) == "table" and type(conn.Disconnect) == "function") then
			conn:Disconnect()
		end
		runEvent[name] = nil
	end
end

--[[
	中止 Beam Width 曲线句柄。
	@param handles { any }? - FXUtil 曲线句柄列表；nil 则跳过
]]
local function _abortBeamHandles(handles: { any }?)
	if not handles then
		return
	end
	for _, h in handles do
		if h and h.Abort then
			h:Abort()
		elseif h and h.abort then
			h:abort()
		end
	end
end

--[[
	施法者取得专属天气 lease（不缓存 prev；释放后由 LightingManager reconcile 到当前世界基线）。
	@param runFx table - 表现会话
]]
local function _applySkillLighting(runFx: any)
	if runFx.lightingApplied then
		return
	end
	runFx.lightingApplied = true
	NetWork.FireBindable(
		NetMsg.LIGHTING_ACQUIRE,
		LIGHTING_WRITER_ID,
		LIGHTING_CONFIG_NAME,
		LIGHTING_ENTER_SEC,
		LIGHTING_PRIORITY,
		false,
		LIGHTING_LEASE_TTL_SEC
	)
end

--[[
	释放技能天气 lease。
	@param runFx table? - 表现会话；nil 或未申请 lease 则跳过
]]
local function _restoreSkillLighting(runFx: any)
	if not runFx or not runFx.lightingApplied then
		return
	end
	runFx.lightingApplied = false
	NetWork.FireBindable(NetMsg.LIGHTING_RELEASE, LIGHTING_WRITER_ID, LIGHTING_EXIT_SEC)
end

--[[
	对位并登记：BakedLocal / LiveTorso / 已放置则跳过摆位。
	@param runFx table - 表现会话
	@param fx Instance - 特效实例
	@param spec table - CUE_FX 项（pose/res/alreadyPlaced 等）
]]
local function _applyPose(runFx: any, fx: Instance, spec: any)
	if spec.alreadyPlaced then
		return
	end
	local pose = spec.pose
	if pose == "BakedLocal" then
		_placeAtBakedLocal(fx, runFx.castAnchor, spec.res)
	elseif pose == "LiveTorso" then
		local attach = runFx.torsoAttachPart
		if attach and attach.Parent then
			_prepareAnchored(fx)
			if fx:IsA("Model") then
				fx:PivotTo(attach.CFrame)
			elseif fx:IsA("BasePart") then
				fx.CFrame = attach.CFrame
			end
			fx.Parent = workspace.Debris
		else
			_placeAtBakedLocal(fx, runFx.castAnchor, spec.res)
		end
	end
end

--[[
	每帧将 follow 列表对齐活躯干。
	@param runFx table - 表现会话
]]
local function _syncFollowTorso(runFx: any)
	local list = runFx.followTorso
	local attach = runFx.torsoAttachPart
	if not list or not attach or not attach.Parent then
		return
	end
	local cf = attach.CFrame
	for _, fx in list do
		if fx and fx.Parent then
			if fx:IsA("Model") then
				fx:PivotTo(cf)
			elseif fx:IsA("BasePart") then
				fx.CFrame = cf
			end
		end
	end
end

--[[
	淡出并停止本会话音效。
	@param runFx table - 表现会话
	@param ids { string }? - 要停的 Cue id；nil 则停全部已登记标签
	@param fadeTime number - 渐出秒
]]
local function _stopSkillSounds(runFx: any, ids: { string }?, fadeTime: number)
	if not SoundModule or not runFx then
		return
	end
	local tags = runFx.soundTags
	if not tags then
		return
	end
	local list = ids
	if not list then
		list = {}
		for id in tags do
			table.insert(list, id)
		end
	end
	for _, id in list do
		local tag = tags[id]
		if tag then
			SoundModule:StopSoundLocal({
				SoundTag = tag,
				FadeTime = fadeTime,
				DestroyAfter = true,
			})
			tags[id] = nil
		end
	end
end

--[[
	按会话标签播放一条技能音效。
	本机施法者 2D（运镜拉远时不被 3D 衰减）；旁观 3D 挂 HRP，无 HRP 则落在施法锚点。
	@param runFx table - 表现会话
	@param cue { id: string, sound: string, stopIds: { string }? } - SOUND_CUES 项
]]
local function _playSkillSound(runFx: any, cue: any)
	if not SoundModule or not cue or type(cue.sound) ~= "string" or cue.sound == "" then
		return
	end
	if cue.stopIds then
		_stopSkillSounds(runFx, cue.stopIds, SOUND_FADE_HANDOFF)
	end
	local tag = (runFx.soundSession or "SpaceSkill1") .. "_" .. tostring(cue.id)
	runFx.soundTags = runFx.soundTags or {}
	runFx.soundTags[cue.id] = tag
	local payload: any = {
		SoundName = cue.sound,
		SoundTag = tag,
	}
	if runFx.isCaster then
		payload.Is2D = true
	else
		payload.Is2D = false
		local hrp = runFx.hrp
		if hrp and hrp.Parent then
			payload.AttachPart = hrp
		elseif typeof(runFx.castAnchor) == "CFrame" then
			payload.PlayPosition = runFx.castAnchor.Position
		end
	end
	SoundModule:PlaySoundLocal(payload)
end

--[[
	推进音效 Cue（与 _pumpCues / 运镜共用 elapsed；进 Active 先泵一次 t=0）。
	@param runFx table - 表现会话
	@param t number - 相对施法起点秒
]]
local function _pumpSoundCues(runFx: any, t: number)
	local idx = runFx.soundIndex or 1
	while idx <= #SOUND_CUES do
		local cue = SOUND_CUES[idx]
		if t < cue.t then
			break
		end
		_playSkillSound(runFx, cue)
		idx += 1
	end
	runFx.soundIndex = idx
end

--[[
	统一拆除表现（对齐 MA2：不对 FX AbsoluteEmit 硬停，粒子自然消散）。
	会话清理：运镜 / DualPath / Beam 曲线 / ColorCorrection 曲线 / Lighting；连续层按关窗收口（Trail、Rate）。
	@param Data BaseSkillClient - 客户端技能实例
]]
local function _teardownPresentation(Data: BaseSkillClient)
	local runData = Data.skillRunData
	if not runData then
		return
	end
	local runFx = runData.spaceSkillFx
	_disconnectRunEvent(runData.runEvent, EVENT_PRESENTATION)

	if runFx then
		if runFx.camEnabled and CameraModule and CameraModule.DisableCameraEvent then
			CameraModule.DisableCameraEvent(CAM_EVENT_NAME)
			runFx.camEnabled = false
		end
		if runFx.dualPath then
			runFx.dualPath:Stop()
			runFx.dualPath:destroy()
			runFx.dualPath = nil
		end
		_abortBeamHandles(runFx.beamHandles)
		runFx.beamHandles = nil
		-- CC Abort(true) 显式还原并清 FXUtilCcBusy；再 LIGHTING_RELEASE，由 Manager reconcile 生效天气
		if runFx.ccHandle then
			local h = runFx.ccHandle
			runFx.ccHandle = nil
			if h.Abort then
				h.Abort(true)
			elseif h.abort then
				h.abort(true)
			end
		end
		_restoreSkillLighting(runFx)
		_stopSkillSounds(runFx, nil, SOUND_FADE_INTERRUPT)

		-- 中断时收口连续层（与 MA2 Trail/Rate F408 关窗一致）；不 PartIcles 硬停
		if runFx.trailOn then
			runFx.trailOn = false
			_setTrailsEnabled(runFx.ballLightModel, false)
			_setTrailsEnabled(runFx.ballDarkModel, false)
		end
		if runFx.ballRateOn then
			_setBallRateEmittersEnabled(runFx, false)
		end
		runFx.ballRateEmitters = nil
		runFx.spawned = nil
		runFx.followTorso = nil
		runFx.ballEmitParts = nil
		runFx.tornDown = true
	end

	runData.spaceSkillFx = nil
end

--[[
	推进 Cue：取独立 material → 对位 → PartIcles。
	@param runFx table - 表现会话
	@param t number - 相对施法起点秒
]]
local function _pumpCues(runFx: any, t: number)
	local idx = runFx.cueIndex or 1
	local cues = SpaceSkillKeys.Cues
	local material = runFx.material
	while idx <= #cues do
		local cue = cues[idx]
		if t < cue.t then
			break
		end
		local name = cue.name
		if name == "RiftBeamsOn" then
			-- 保留硬开关：开场 silence 关 Beam，此处再开（Width 曲线仍从 EnterActive 跑）
			_setBeamsEnabled(runFx.riftDark, true)
			_setBeamsEnabled(runFx.riftLight, true)
		elseif name == "LightBallEmit" or name == "DarkBallEmit" then
			local spec = CUE_FX[name]
			if spec then
				local fx = _getMaterial(material, spec.res)
				local shell = if spec.ballShellKey == "lightBall" then runFx.lightBall else runFx.darkBall
				_emitBallMa2Particles(runFx, fx, shell, spec.ballEmitPart)
			end
		else
			local spec = CUE_FX[name]
			if spec then
				local fx = _getMaterial(material, spec.res)
				if fx then
					_applyPose(runFx, fx, spec)
					if not spec.skipEmit then
						if type(spec.emitChild) == "string" then
							_emitRiftBurstChild(fx, spec.emitChild)
						else
							_particlesEmit(fx)
						end
					end
					-- 开场已登记的 alreadyPlaced 不再重复塞 spawned
					if not spec.alreadyPlaced then
						runFx.spawned = runFx.spawned or {}
						table.insert(runFx.spawned, fx)
						if spec.follow then
							runFx.followTorso = runFx.followTorso or {}
							table.insert(runFx.followTorso, fx)
						end
					end
				end
			end
		end
		idx += 1
	end
	runFx.cueIndex = idx

	if runFx.dualPath and runFx.dualPath.IsTrailWindow then
		local wantTrail = runFx.dualPath:IsTrailWindow(t)
		if runFx.trailOn ~= wantTrail then
			runFx.trailOn = wantTrail
			_setTrailsEnabled(runFx.ballLightModel, wantTrail)
			_setTrailsEnabled(runFx.ballDarkModel, wantTrail)
		end
	end

	-- 双球 Rate：Emit 后开，F408 关（与 MA2 Trail 关窗对齐；无独立 PE Enabled 轨）
	local rateOffAt = SpaceSkillKeys.PhaseTimeline.ballRateDisableAt
	if runFx.ballRateOn and type(rateOffAt) == "number" and t >= rateOffAt then
		_setBallRateEmittersEnabled(runFx, false)
	end
end

--[[
	appearStart：掰到烘焙位姿后允许 DualPath 连续驱动（粒子改由 Light/DarkBallEmit Cue）。
	@param runFx table - 表现会话
	@param t number - 相对施法起点秒
]]
local function _tryBallAppearBurst(runFx: any, t: number)
	if runFx.ballPathActive or not runFx.dualPath then
		return
	end
	local appearStart = SpaceSkillKeys.PhaseTimeline.appearStart
	if type(appearStart) ~= "number" or t < appearStart then
		return
	end
	runFx.dualPath:Update(appearStart)
	runFx.ballPathActive = true
end

-- ========================================
-- 状态：Active
-- ========================================

--[[
	Active 客户端：独立特效对位、Cue+PartIcles、DualPath、Beam Width、Lighting。
	@param Data BaseSkillClient - 客户端技能实例
]]
function module.Client_EnterActive(Data: BaseSkillClient)
	local hrp, castAnchor = _resolveHrp(Data)
	if not castAnchor then
		return
	end

	local runData = Data.skillRunData
	if not runData then
		return
	end
	if not runData.runEvent then
		runData.runEvent = {}
	end

	local material = runData.material
	if not material then
		return
	end

	local character = Data.skillInputData and Data.skillInputData.character
	local runGen = Data.runGeneration
	local isCaster = _isLocalPlayerCaster(Data)
	local runFx: any = {
		tornDown = false,
		cueIndex = 1,
		trailOn = false,
		ballRateOn = false,
		ballRateEmitters = {},
		ballPathActive = false,
		ballEmitParts = {},
		hrp = hrp,
		castAnchor = castAnchor,
		material = material,
		torsoAttachPart = character and _resolveTorsoAttachPart(character) or nil,
		beamHandles = {},
		ccHandle = nil,
		spawned = {},
		followTorso = {},
		camEnabled = false,
		isCaster = isCaster,
		soundIndex = 1,
		soundTags = {},
		soundSession = string.format("SpaceSkill1_%s_%s", tostring(Data.characterId or 0), tostring(runGen or 0)),
	}
	runData.spaceSkillFx = runFx

	--[[
		当前代数下表现是否仍可推进。
		@return boolean - true 表示本代数仍可推进 Cue/运镜
]]
	local function stillActive(): boolean
		return Data:isRunningFlow() and Data.runGeneration == runGen and runData.spaceSkillFx == runFx and not runFx.tornDown
	end

	-- 早期 Burst：开场摆进 Debris + silence（贴图流送窗口）；Cue 只 AbsoluteEmit（对齐裂隙）
	local chargeGround = _getMaterial(material, RES.ChargeGround)
	if chargeGround then
		_silenceVfx(chargeGround)
		_placeAtBakedLocal(chargeGround, castAnchor, RES.ChargeGround)
		table.insert(runFx.spawned, chargeGround)
	end
	local bodyEnergy = _getMaterial(material, RES.BodyEnergy)
	if bodyEnergy then
		_silenceVfx(bodyEnergy)
		-- 临时关掉 alreadyPlaced，复用 LiveTorso 摆位；follow 开场登记
		_applyPose(runFx, bodyEnergy, { res = RES.BodyEnergy, pose = "LiveTorso" })
		table.insert(runFx.spawned, bodyEnergy)
		table.insert(runFx.followTorso, bodyEnergy)
	end

	-- 裂隙：开场按 MA2 初始相对位摆好，供 Beam 曲线与后续 Burst
	local riftDark = _getMaterial(material, RES.RiftDark)
	local riftLight = _getMaterial(material, RES.RiftLight)
	if riftDark then
		_silenceVfx(riftDark)
		_placeAtBakedLocal(riftDark, castAnchor, RES.RiftDark)
		_setBeamsEnabled(riftDark, false)
		runFx.riftDark = riftDark
		table.insert(runFx.spawned, riftDark)
	end
	if riftLight then
		_silenceVfx(riftLight)
		_placeAtBakedLocal(riftLight, castAnchor, RES.RiftLight)
		_setBeamsEnabled(riftLight, false)
		runFx.riftLight = riftLight
		table.insert(runFx.spawned, riftLight)
	end

	for beamName, widthKeys in SpaceSkillKeys.BeamWidth0 do
		local beamInst = (riftDark and riftDark:FindFirstChild(beamName, true))
			or (riftLight and riftLight:FindFirstChild(beamName, true))
		if beamInst and beamInst:IsA("Beam") then
			-- MA2 仅 Width0 有轨，Width1 资源为 0（锥形）；播完停在末键 0，勿还原默认宽
			local handle = FXUtil.PlayBeamWidthCurve(beamInst, widthKeys, nil, {
				keepWidth1 = true,
				restoreOnEnd = false,
			})
			if handle then
				table.insert(runFx.beamHandles, handle)
			end
		end
	end

	-- 黑白球：开场按 MA2 初始相对位摆好；appearStart 前不驱动；先 AbsoluteEmit 一次再烘焙跟轨
	local ballLightModel = _getMaterial(material, RES.BallLight)
	local ballDarkModel = _getMaterial(material, RES.BallDark)
	local lightBall = ballLightModel and _findBallPart(ballLightModel, BALL_LIGHT_PART)
	local darkBall = ballDarkModel and _findBallPart(ballDarkModel, BALL_DARK_PART)
	if ballLightModel and ballDarkModel and lightBall and darkBall then
		_silenceVfx(ballLightModel)
		_silenceVfx(ballDarkModel)
		_placeAtBakedLocal(ballLightModel, castAnchor, RES.BallLight)
		_placeAtBakedLocal(ballDarkModel, castAnchor, RES.BallDark)
		-- 烘焙键对应球 Part；再钉内层球，避免 Model Pivot ≠ 球 Part
		local lightLocal = SpaceSkillKeys.ResInitialLocalCF[RES.BallLight]
		local darkLocal = SpaceSkillKeys.ResInitialLocalCF[RES.BallDark]
		if typeof(lightLocal) == "CFrame" then
			lightBall.CFrame = AnchorRelative.ToWorld(castAnchor, lightLocal)
		end
		if typeof(darkLocal) == "CFrame" then
			darkBall.CFrame = AnchorRelative.ToWorld(castAnchor, darkLocal)
		end
		_setTrailsEnabled(ballLightModel, false)
		_setTrailsEnabled(ballDarkModel, false)
		runFx.ballLightModel = ballLightModel
		runFx.ballDarkModel = ballDarkModel
		runFx.lightBall = lightBall
		runFx.darkBall = darkBall
		table.insert(runFx.spawned, ballLightModel)
		table.insert(runFx.spawned, ballDarkModel)

		local dual = DualPathBallRuntime.new({
			phaseTimeline = SpaceSkillKeys.PhaseTimeline,
		})
		dual:Start(if isCaster then "CasterBaked" else "ObserverIntuitive", {
			getAnchorCF = function()
				return runFx.castAnchor
			end,
			getCasterCF = function()
				local casterHrp = character and character:FindFirstChild("HumanoidRootPart")
				if casterHrp and casterHrp:IsA("BasePart") then
					return casterHrp.CFrame
				end
				return runFx.castAnchor
			end,
			lightBall = lightBall,
			darkBall = darkBall,
			bakedLightKeys = SpaceSkillKeys.LightBallLocalKeys,
			bakedDarkKeys = SpaceSkillKeys.DarkBallLocalKeys,
		})
		runFx.dualPath = dual
	end

	if ENABLE_SPACE_SKILL_CAM and isCaster and CameraModule and CameraModule.EnableCameraEvent then
		local ok = CameraModule.EnableCameraEvent(CAM_EVENT_NAME, CAM_PRIORITY, 70, function(_t: number, _dt: number?)
			if not stillActive() then
				return nil, nil
			end
			local elapsedCam = runFx.elapsed or 0
			local localCF = KeyframeEval.EvalCFrame(SpaceSkillKeys.CamLocalKeys, elapsedCam)
			local worldCF = AnchorRelative.ToWorld(runFx.castAnchor, localCF)
			local fov = KeyframeEval.EvalNumber(SpaceSkillKeys.CamFovKeys, elapsedCam)
			return worldCF, fov
		end, { suppressShake = true })
		runFx.camEnabled = ok == true
	end

	if isCaster then
		_applySkillLighting(runFx)
		-- MA2 Track39 F485–503：与运镜/Cue 共用 runFx.elapsed；末键停在 0（restoreOnEnd=false）
		runFx.ccHandle = FXUtil.PlayColorCorrectionCurve({
			saturation = SpaceSkillKeys.CcSaturationKeys,
			contrast = SpaceSkillKeys.CcContrastKeys,
		}, {
			manualUpdate = true,
			restoreOnEnd = false,
		})
	end

	local elapsed = 0
	runFx.elapsed = 0
	_pumpSoundCues(runFx, 0)
	_disconnectRunEvent(runData.runEvent, EVENT_PRESENTATION)
	local presentId = CombatWorld.allocId("SpaceSkill1Present")
	runData.runEvent[EVENT_PRESENTATION] = CombatWorld.register(presentId, function(dt)
		if not stillActive() then
			return
		end
		elapsed += dt
		runFx.elapsed = elapsed
		if runFx.ccHandle and runFx.ccHandle.Update then
			runFx.ccHandle.Update(elapsed)
		end
		_pumpCues(runFx, elapsed)
		_pumpSoundCues(runFx, elapsed)
		_syncFollowTorso(runFx)
		-- 已出场的帧才连续跟烘焙；本帧若刚出现则只停在 appearStart 位姿
		if runFx.dualPath and runFx.ballPathActive then
			runFx.dualPath:Update(elapsed)
		end
		_tryBallAppearBurst(runFx, elapsed)
		_syncBallEmitParts(runFx)
		if elapsed >= DURATION then
			_disconnectRunEvent(runData.runEvent, EVENT_PRESENTATION)
		end
	end, CombatWorld.Phase.SkillRuntime)
end

--[[
	Active 退出：拆除表现。
	@param Data BaseSkillClient - 客户端技能实例
]]
function module.Client_ExitActive(Data: BaseSkillClient)
	_teardownPresentation(Data)
end

--[[
	打断：拆除表现。
	@param Data BaseSkillClient - 客户端技能实例
]]
function module.Client_EnterInterrupted(Data: BaseSkillClient)
	_teardownPresentation(Data)
end

--[[
	Recovery 服务端：放权。
	@param Data BaseSkillServer - 服务端技能实例
]]
function module.Server_EnterRecovery(Data: BaseSkillServer)
	Data:releaseControl()
end

-- ========================================
-- 配置
-- ========================================
module.SoundList = {
	SOUND_JUMP,
	SOUND_CHARGE,
	SOUND_EXPLODE,
}
module.AnimateList = {
	ANIM_CAST,
}
module.ResNameList = {
	RES.ChargeGround,
	RES.BodyEnergy,
	RES.AirAbsorb,
	RES.AirBurst,
	RES.RiftDark,
	RES.RiftLight,
	RES.BallDark,
	RES.BallLight,
	RES.Center,
	RES.BigCharge,
	RES.FinalBurst,
	RES.FinalBurst2,
	RES.FinalBurst3,
}

module.hitboxConfig = {}

module.Action = {
	{
		action = "LockMovement",
		startTime = 0,
		overTime = DURATION,
		speedMultiplier = 0,
	},
	{
		action = "Animation",
		startTime = 0,
		overTime = DURATION,
		animationName = ANIM_CAST,
		animationSpeed = 1,
		animationPriority = Enum.AnimationPriority.Action4,
		animationFadeTime = 0.1,
	},
}

return module
