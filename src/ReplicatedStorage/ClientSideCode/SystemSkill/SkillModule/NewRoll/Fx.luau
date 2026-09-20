--[[
	Module: NewRoll.Fx
	Description: NewRoll 客户端表现（时间轴 seek、闪现/烟尘/音效、soft-merge catch-up）。
	Author: 林奥宇
	Created: 2026-08-06
	Last Modified: 2026-09-01

	功能：
	- 声明式时间轴（绝对偏移 + _fxFired 幂等）；Enter / CatchUp 共用 seek
	- Forward 闪现 Fade/UnFade；侧后贴地烟尘 RenderStepped
	- onEnd 兜底 UnFade

	模块关系：
	- 仅由 NewRoll/init 调用；勿作为独立 SkillModule 加载
	- 位移/无敌/包络仍在 NewRoll 主模块

	加载方式：
		local Fx = require(script.Fx) -- 于 NewRoll/init.luau

	示例：
		Fx.enterRolling(Data)
		Fx.softMergeCatchUp(Data, softMergeSnap)
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Class = require(game.ReplicatedFirst.AllSideCode.Class.Class)
local GetSkillData = require(script.Parent.Parent.Parent.BaseSkill.GetSkillData)
local FXUtil = Utils.FXUtil
local VisibleMgr = Utils.VisibleMgr
local RayCast = Utils.RayCast
local RunService = Utils.RunService
local SoundModule = Utils.SoundModule
local Log = Utils.Log

type BaseSkillClient = Class.BaseSkillClient

local Fx = {}

-- ========================================
-- 常量
-- ========================================
local FORWARD_FADE_AT = 0.05
local FORWARD_BIG_SOUND_AT = 0.15
local FORWARD_BLINK_END_AT = 0.22
local FORWARD_UNFADE_AT = 0.30
local FORWARD_FADE_DURATION = 0.08
local UNFADE_DURATION = 0.1

local BACKWARD_SMOKE_START_AT = 0.12
local BACKWARD_SMOKE_STOP_AT = 0.35
local SIDE_SMOKE_START_AT = 0.16
local SMOKE_EMIT_INTERVAL = 0.03
local GROUND_RAY_DISTANCE = 10

local RES_SMOKE = "翻滚烟尘"
local RES_BLINK_START = "闪现收缩特效"
local RES_BLINK_END = "闪现释放特效"
local EVENT_KEY_BACKWARD_SMOKE = "向后翻滚烟尘"
local EVENT_KEY_SIDE_SMOKE = "翻滚烟尘"
local SOUND_FORWARD_SMALL = "技能_向前闪避-小光圈"
local SOUND_FORWARD_BIG = "技能_向前闪避-大光圈"
local SOUND_SIDE = "技能_左后右闪避"

local BLINK_START_LOCAL_CF = CFrame.new(0, 0, 1)
local BLINK_END_LOCAL_CF = CFrame.new(0, 0, -1)

local FX_ID = {
	SmallSound = "SmallSound",
	BlinkStartFade = "BlinkStartFade",
	BigSound = "BigSound",
	BlinkEnd = "BlinkEnd",
	UnFade = "UnFade",
	SideSound = "SideSound",
	SmokeStart = "SmokeStart",
	SmokeStop = "SmokeStop",
}

local FORWARD_TIMELINE = {
	{ id = FX_ID.SmallSound, at = 0 },
	{ id = FX_ID.BlinkStartFade, at = FORWARD_FADE_AT },
	{ id = FX_ID.BigSound, at = FORWARD_BIG_SOUND_AT },
	{ id = FX_ID.BlinkEnd, at = FORWARD_BLINK_END_AT },
	{ id = FX_ID.UnFade, at = FORWARD_UNFADE_AT },
}

local BACKWARD_TIMELINE = {
	{ id = FX_ID.SideSound, at = 0 },
	{ id = FX_ID.SmokeStart, at = BACKWARD_SMOKE_START_AT },
	{ id = FX_ID.SmokeStop, at = BACKWARD_SMOKE_STOP_AT },
}

local SIDE_TIMELINE = {
	{ id = FX_ID.SideSound, at = 0 },
	{ id = FX_ID.SmokeStart, at = SIDE_SMOKE_START_AT },
	-- 侧向烟尘停止统一在 exitRolling
}

-- 供主模块 SoundList / ResNameList 复用，避免字面量分叉
Fx.SOUND_FORWARD_SMALL = SOUND_FORWARD_SMALL
Fx.SOUND_FORWARD_BIG = SOUND_FORWARD_BIG
Fx.SOUND_SIDE = SOUND_SIDE
Fx.RES_SMOKE = RES_SMOKE
Fx.RES_BLINK_START = RES_BLINK_START
Fx.RES_BLINK_END = RES_BLINK_END

-- ========================================
-- 私有函数
-- ========================================

--[[
	安全播放本地音效；SoundModule 缺失或播放失败时打调试警告。

	@param opts { SoundName: string, PlayPosition: Vector3?, Is2D: boolean? } - PlaySoundLocal 参数
]]
local function _safePlaySoundLocal(opts: { SoundName: string, PlayPosition: Vector3?, Is2D: boolean? })
	if not SoundModule or not SoundModule.PlaySoundLocal then
		return
	end
	local ok, err = pcall(function()
		SoundModule:PlaySoundLocal(opts)
	end)
	if not ok then
		Log.warn("[NewRoll.Fx] PlaySoundLocal failed:", err)
	end
end

--[[
	从技能输入读取翻滚方向字符串。

	@param Data BaseSkillClient - 客户端技能实例；读 skillInputData.character
	@return string - Forward|Backward|Left|Right；无角色时默认 Forward
]]
local function _getDirection(Data: BaseSkillClient): string
	local character = Data.skillInputData and Data.skillInputData.character
	if not character then
		return "Forward"
	end
	return GetSkillData.getCharacterDirectionStr(character)
end

--[[
	从技能输入取角色、HRP、Humanoid。

	@param Data BaseSkillClient - 客户端技能实例；读 skillInputData.character
	@return Model? - 角色模型
	@return BasePart? - HumanoidRootPart
	@return Humanoid? - Humanoid
]]
local function _getCharacterParts(Data: BaseSkillClient): (Model?, BasePart?, Humanoid?)
	local character = Data.skillInputData and Data.skillInputData.character
	if not character then
		return nil, nil, nil
	end
	local HRP = character:FindFirstChild("HumanoidRootPart")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	return character, HRP, humanoid
end

--[[
	从 skillRunData.material 取命名资源实例。

	@param Data BaseSkillClient - 客户端技能实例
	@param name string - 资源键（如「翻滚烟尘」）
	@return Instance? - 资源实例；缺失或 material 非表时为 nil
]]
local function _getRunMaterial(Data: BaseSkillClient, name: string): Instance?
	local runData = Data and Data.skillRunData
	local material = runData and runData.material
	if type(material) ~= "table" then
		return nil
	end
	return material[name]
end

--[[
	判断客户端技能实例是否仍可推进表现（未 destroy、流程仍在跑、runData 有效）。

	@param Data BaseSkillClient? - 客户端技能实例；nil 视为已结束
	@return boolean - 是否可继续播特效/音效
]]
local function _isSkillClientAlive(Data: BaseSkillClient?): boolean
	if not Data or Data._destroyed then
		return false
	end
	if Data.isRunningFlow and not Data:isRunningFlow() then
		return false
	end
	return type(Data.skillRunData) == "table" and next(Data.skillRunData) ~= nil
end

--[[
	确保 runData._fxFired 表存在。

	@param runData { _fxFired: { [string]: boolean }? } - skillRunData（至少可写 _fxFired）
	@return { [string]: boolean } - 已触发事件表
]]
local function _ensureFxFired(runData: { _fxFired: { [string]: boolean }? }): { [string]: boolean }
	if type(runData._fxFired) ~= "table" then
		runData._fxFired = {}
	end
	return runData._fxFired
end

--[[
	幂等领取事件：未触发则标记并返回 true。

	@param runData { _fxFired: { [string]: boolean }? } - skillRunData
	@param id string - FX_ID
	@return boolean - true 表示本次可执行
]]
local function _tryClaimFx(runData: { _fxFired: { [string]: boolean }? }, id: string): boolean
	local fired = _ensureFxFired(runData)
	if fired[id] == true then
		return false
	end
	fired[id] = true
	return true
end

--[[
	若 runData.FadeCharacter 仍指向指定目标，则清空该字段（避免误清他人引用）。

	@param Data BaseSkillClient? - 客户端技能实例；nil 则跳过
	@param fadeTarget Model? - 曾 Fade 的角色
]]
local function _clearFadeCharacterField(Data: BaseSkillClient?, fadeTarget: Model?)
	local rd = Data and Data.skillRunData
	if type(rd) ~= "table" then
		return
	end
	if rd["FadeCharacter"] == fadeTarget then
		rd["FadeCharacter"] = nil
	end
end

--[[
	还原角色可见性并清理 FadeCharacter 字段。

	@param fadeTarget Model? - 目标角色
	@param Data BaseSkillClient? - 客户端技能实例（可为空，仅影响字段清理）
]]
local function _unfadeCharacterSafe(fadeTarget: Model?, Data: BaseSkillClient?)
	if not fadeTarget or not fadeTarget.Parent then
		return
	end
	VisibleMgr.UnFadeCharacterModel(fadeTarget, UNFADE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	_clearFadeCharacterField(Data, fadeTarget)
end

--[[
	断开并清空 runEvent 上指定键的 RBXScriptConnection。

	@param runEvent { [string]: RBXScriptConnection }? - skillRunData.runEvent
	@param key string - 连接键名
]]
local function _disconnectRunEvent(runEvent: { [string]: RBXScriptConnection }?, key: string)
	if not runEvent then
		return
	end
	local conn = runEvent[key]
	if conn then
		conn:Disconnect()
		runEvent[key] = nil
	end
end

--[[
	绑定贴地烟尘循环：缓存 ParticleEmitter，按间隔射线取色并 Emit。
	实例已销毁时自断连接，避免 ExitRolling 漏调时 RenderStepped 泄漏。

	@param Data BaseSkillClient - 客户端技能实例（循环内做存活检查）
	@param runEvent { [string]: RBXScriptConnection } - 存放连接的 runEvent 表
	@param eventKey string - 连接键（向后/侧向区分）
	@param rollSmoke Instance - 烟尘模型
	@param humanoid Humanoid - 用于 FloorMaterial 判断
	@param HRP BasePart - 射线起点
]]
local function _bindGroundSmokeLoop(
	Data: BaseSkillClient,
	runEvent: { [string]: RBXScriptConnection },
	eventKey: string,
	rollSmoke: Instance,
	humanoid: Humanoid,
	HRP: BasePart
)
	_disconnectRunEvent(runEvent, eventKey)
	rollSmoke.Parent = workspace.Debris
	local emitters: { ParticleEmitter } = {}
	for _, desc in pairs(rollSmoke:GetDescendants()) do
		if desc:IsA("ParticleEmitter") then
			table.insert(emitters, desc)
		end
	end

	local accum = 0
	local conn = RunService.RenderStepped:Connect(function(dt)
		if not _isSkillClientAlive(Data) then
			_disconnectRunEvent(runEvent, eventKey)
			return
		end
		accum += dt
		if accum < SMOKE_EMIT_INTERVAL then
			return
		end
		accum = 0
		if not HRP.Parent or humanoid.FloorMaterial == Enum.Material.Air then
			return
		end
		local result = RayCast.RayCast(
			HRP.Position,
			HRP.Position - Vector3.new(0, GROUND_RAY_DISTANCE, 0),
			"Ground"
		)
		if not result then
			return
		end
		if result.Instance and result.Instance:IsA("BasePart") then
			local color = result.Instance.Color
			local seq = ColorSequence.new({
				ColorSequenceKeypoint.new(0, color),
				ColorSequenceKeypoint.new(1, color),
			})
			for _, emitter in ipairs(emitters) do
				emitter.Color = seq
			end
		end
		rollSmoke:PivotTo(CFrame.new(result.Position))
		FXUtil.Emit_Particles_GetDescendants(rollSmoke, true)
	end)
	runEvent[eventKey] = conn
end

--[[
	按方向解析时间轴表。

	@param direction string - Forward|Backward|Left|Right
	@return { { id: string, at: number } } - 事件列表
]]
local function _getTimelineForDirection(direction: string): { { id: string, at: number } }
	if direction == "Forward" then
		return FORWARD_TIMELINE
	elseif direction == "Backward" then
		return BACKWARD_TIMELINE
	elseif direction == "Left" or direction == "Right" then
		return SIDE_TIMELINE
	end
	return FORWARD_TIMELINE
end

--[[
	确保 skillRunData.runEvent 表存在并返回。

	@param Data BaseSkillClient - 客户端技能实例
	@return { [string]: RBXScriptConnection } - runEvent 表
]]
local function _ensureRunEvent(Data: BaseSkillClient): { [string]: RBXScriptConnection }
	local runData = Data.skillRunData
	local runEvent = runData and runData.runEvent
	if type(runEvent) ~= "table" then
		runEvent = {}
		if type(runData) == "table" then
			runData.runEvent = runEvent
		end
	end
	return runEvent
end

--[[
	FX：向前小光圈音效。

	@param Data BaseSkillClient - 客户端技能实例
	@param _fadeTarget Model - 捕获角色（未使用）
]]
local function _fxSmallSound(Data: BaseSkillClient, _fadeTarget: Model)
	local _, HRP = _getCharacterParts(Data)
	if HRP then
		_safePlaySoundLocal({
			SoundName = SOUND_FORWARD_SMALL,
			PlayPosition = HRP.Position,
			Is2D = false,
		})
	end
end

--[[
	FX：侧后闪避音效。

	@param Data BaseSkillClient - 客户端技能实例
	@param _fadeTarget Model - 捕获角色（未使用）
]]
local function _fxSideSound(Data: BaseSkillClient, _fadeTarget: Model)
	local _, HRP = _getCharacterParts(Data)
	if HRP then
		_safePlaySoundLocal({
			SoundName = SOUND_SIDE,
			PlayPosition = HRP.Position,
			Is2D = false,
		})
	end
end

--[[
	FX：闪现收缩 + Fade 角色。

	@param Data BaseSkillClient - 客户端技能实例
	@param fadeTarget Model - 捕获角色
]]
local function _fxBlinkStartFade(Data: BaseSkillClient, fadeTarget: Model)
	local _, HRP = _getCharacterParts(Data)
	local runData = Data.skillRunData
	local blinkStart = _getRunMaterial(Data, RES_BLINK_START)
	if blinkStart and HRP then
		blinkStart.Parent = workspace.Debris
		blinkStart:PivotTo(HRP:GetPivot():ToWorldSpace(BLINK_START_LOCAL_CF))
		FXUtil.Emit_Particles_GetDescendants(blinkStart, true)
	end
	if type(runData) == "table" then
		runData["FadeCharacter"] = fadeTarget
	end
	if fadeTarget and fadeTarget.Parent then
		VisibleMgr.FadeCharacterModel(fadeTarget, 1, FORWARD_FADE_DURATION, Enum.EasingStyle.Quart, Enum.EasingDirection.In)
	end
end

--[[
	FX：向前大光圈音效。

	@param Data BaseSkillClient - 客户端技能实例
	@param _fadeTarget Model - 捕获角色（未使用）
]]
local function _fxBigSound(Data: BaseSkillClient, _fadeTarget: Model)
	local _, HRP = _getCharacterParts(Data)
	if HRP then
		_safePlaySoundLocal({
			SoundName = SOUND_FORWARD_BIG,
			PlayPosition = HRP.Position,
			Is2D = false,
		})
	end
end

--[[
	FX：闪现释放特效（单次取 HRP，不再二次取部件）。

	@param Data BaseSkillClient - 客户端技能实例
	@param _fadeTarget Model - 捕获角色（未使用）
]]
local function _fxBlinkEnd(Data: BaseSkillClient, _fadeTarget: Model)
	local _, HRP = _getCharacterParts(Data)
	local blinkEnd = _getRunMaterial(Data, RES_BLINK_END)
	if blinkEnd and HRP then
		blinkEnd.Parent = workspace.Debris
		blinkEnd:PivotTo(HRP:GetPivot():ToWorldSpace(BLINK_END_LOCAL_CF))
		FXUtil.Emit_Particles_GetDescendants(blinkEnd, true)
	end
end

--[[
	FX：UnFade 角色。

	@param Data BaseSkillClient - 客户端技能实例
	@param fadeTarget Model - 捕获角色
]]
local function _fxUnFade(Data: BaseSkillClient, fadeTarget: Model)
	_unfadeCharacterSafe(fadeTarget, Data)
end

--[[
	FX：启动贴地烟尘循环。

	@param Data BaseSkillClient - 客户端技能实例
	@param _fadeTarget Model - 捕获角色（未使用）
]]
local function _fxSmokeStart(Data: BaseSkillClient, _fadeTarget: Model)
	local _, HRP, humanoid = _getCharacterParts(Data)
	local runData = Data.skillRunData
	local runEvent = _ensureRunEvent(Data)
	local direction = (type(runData) == "table" and runData._rollingFxDirection) or "Forward"
	local eventKey = if direction == "Backward" then EVENT_KEY_BACKWARD_SMOKE else EVENT_KEY_SIDE_SMOKE
	local rollSmoke = _getRunMaterial(Data, RES_SMOKE)
	if rollSmoke and humanoid and HRP then
		_bindGroundSmokeLoop(Data, runEvent, eventKey, rollSmoke, humanoid, HRP)
	end
end

--[[
	FX：停止向后烟尘连接。

	@param Data BaseSkillClient - 客户端技能实例
	@param _fadeTarget Model - 捕获角色（未使用）
]]
local function _fxSmokeStop(Data: BaseSkillClient, _fadeTarget: Model)
	local runEvent = _ensureRunEvent(Data)
	_disconnectRunEvent(runEvent, EVENT_KEY_BACKWARD_SMOKE)
end

-- id -> handler（避免长 if 链）
local FX_HANDLERS: { [string]: (BaseSkillClient, Model) -> () } = {
	[FX_ID.SmallSound] = _fxSmallSound,
	[FX_ID.SideSound] = _fxSideSound,
	[FX_ID.BlinkStartFade] = _fxBlinkStartFade,
	[FX_ID.BigSound] = _fxBigSound,
	[FX_ID.BlinkEnd] = _fxBlinkEnd,
	[FX_ID.UnFade] = _fxUnFade,
	[FX_ID.SmokeStart] = _fxSmokeStart,
	[FX_ID.SmokeStop] = _fxSmokeStop,
}

--[[
	执行单个表现事件（调用前须已 _tryClaimFx）。

	@param Data BaseSkillClient - 客户端技能实例
	@param id string - FX_ID
	@param fadeTarget Model - 捕获的角色（Fade/UnFade）
]]
local function _executeFxEvent(Data: BaseSkillClient, id: string, fadeTarget: Model)
	local handler = FX_HANDLERS[id]
	if handler then
		handler(Data, fadeTarget)
	end
end

--[[
	尝试触发事件：实例须存活且仍持有表现所有权；幂等领取后执行。

	@param Data BaseSkillClient - 客户端技能实例
	@param id string - FX_ID
	@param fadeTarget Model - 捕获角色
]]
local function _tryFireFxEvent(Data: BaseSkillClient, id: string, fadeTarget: Model)
	if not _isSkillClientAlive(Data) then
		return
	end
	local runData = Data.skillRunData
	if type(runData) ~= "table" then
		return
	end
	-- soft-merge 已移交表现所有权：预测段残留 delay 不得再 claim / Emit
	if runData._fxOwnershipReleased == true then
		return
	end
	-- UnFade 与其余事件均要求角色仍在场景；其余另依赖当前 runData（含 soft-merge 后的 material）
	if not fadeTarget or not fadeTarget.Parent then
		return
	end
	if not _tryClaimFx(runData, id) then
		return
	end
	_executeFxEvent(Data, id, fadeTarget)
end

--[[
	按 sinceRolling seek 时间轴：已过时刻立即补播，未到则 delay。
	EnterRolling 与 soft-merge CatchUp 共用此入口。

	@param Data BaseSkillClient - 客户端技能实例
	@param sinceRolling number - 距 Rolling 进入的秒数（>=0）
]]
local function _seekRollingFx(Data: BaseSkillClient, sinceRolling: number)
	local runData = Data.skillRunData
	if type(runData) ~= "table" then
		return
	end
	local character = Data.skillInputData and Data.skillInputData.character
	if not character then
		return
	end
	local fadeTarget = character
	local direction = runData._rollingFxDirection
	if type(direction) ~= "string" or direction == "" then
		direction = _getDirection(Data)
		runData._rollingFxDirection = direction
	end
	_ensureFxFired(runData)

	local timeline = _getTimelineForDirection(direction)
	local since = math.max(0, sinceRolling)
	for _, ev in ipairs(timeline) do
		local id = ev.id
		local at = ev.at
		local fired = runData._fxFired
		if fired[id] == true then
			continue
		end
		local remain = at - since
		if remain <= 1e-4 then
			_tryFireFxEvent(Data, id, fadeTarget)
		else
			task.delay(remain, function()
				_tryFireFxEvent(Data, id, fadeTarget)
			end)
		end
	end
end

--[[
	由 softMergeSnap / runData.State 估算距 Rolling 进入的秒数。

	@param Data BaseSkillClient - 客户端技能实例
	@param softMergeSnap { nowTime: number, state: string, enteredAt: number? }? - 合并快照
	@return number - sinceRolling（>=0）
]]
local function _computeSinceRolling(Data: BaseSkillClient, softMergeSnap: any?): number
	local runData = Data.skillRunData
	local nowTime = type(Data.nowTime) == "number" and Data.nowTime or 0
	local rollingEnteredAt = 0
	if softMergeSnap and type(softMergeSnap.enteredAt) == "number" and softMergeSnap.state == "Rolling" then
		rollingEnteredAt = softMergeSnap.enteredAt
	elseif type(runData) == "table" and runData.State and runData.State.current == "Rolling" and type(runData.State.enteredAt) == "number" then
		rollingEnteredAt = runData.State.enteredAt
	elseif softMergeSnap and type(softMergeSnap.nowTime) == "number" then
		-- Startup Duration=0：无 enteredAt 时用 nowTime 近似已推进量
		return math.max(0, softMergeSnap.nowTime)
	end
	return math.max(0, nowTime - rollingEnteredAt)
end

-- ========================================
-- 公共函数
-- ========================================

--[[
	客户端进入 Rolling：arm 时间轴并以 since=0 seek（同实例防双排）。

	@param Data BaseSkillClient - 客户端技能实例
]]
function Fx.enterRolling(Data: BaseSkillClient)
	local character, HRP = _getCharacterParts(Data)
	if not character or not HRP then
		return
	end

	local runData = Data.skillRunData
	if type(runData) ~= "table" then
		return
	end
	-- 同实例已 arm：跳过；soft-merge 后正式段走 softMergeCatchUp（不经此早退）
	if runData._rollingFxTimelineArmed == true then
		return
	end
	runData._rollingFxTimelineArmed = true
	runData._rollingFxDirection = _getDirection(Data)
	runData.runEvent = runData.runEvent or {}
	_ensureFxFired(runData)
	_seekRollingFx(Data, 0)
end

--[[
	soft-merge 表现追赶：与 Enter 共用 seek；按 sinceRolling 补播未触发事件。

	@param Data BaseSkillClient - 正式段基础技能
	@param softMergeSnap { nowTime: number, state: string, enteredAt: number? }? - 合并快照
]]
function Fx.softMergeCatchUp(Data: BaseSkillClient, softMergeSnap: any?)
	local runData = Data and Data.skillRunData
	if type(runData) ~= "table" then
		return
	end

	runData._rollingFxTimelineArmed = true
	if type(runData._rollingFxDirection) ~= "string" or runData._rollingFxDirection == "" then
		runData._rollingFxDirection = _getDirection(Data)
	end
	runData.runEvent = runData.runEvent or {}
	_ensureFxFired(runData)

	local sinceRolling = _computeSinceRolling(Data, softMergeSnap)
	_seekRollingFx(Data, sinceRolling)
end

--[[
	客户端离开 Rolling：断开烟尘 RenderStepped 连接。

	@param Data BaseSkillClient - 客户端技能实例
]]
function Fx.exitRolling(Data: BaseSkillClient)
	local runData = Data.skillRunData
	local runEvent = runData and runData.runEvent
	if not runEvent then
		return
	end
	_disconnectRunEvent(runEvent, EVENT_KEY_BACKWARD_SMOKE)
	_disconnectRunEvent(runEvent, EVENT_KEY_SIDE_SMOKE)
	-- 侧向无 SmokeStop 事件：Exit 时标记，避免 catch-up 误补绑
	if type(runData) == "table" then
		local fired = _ensureFxFired(runData)
		fired[FX_ID.SmokeStop] = true
	end
end

--[[
	技能结束兜底：断开烟尘连接；若仍挂着 FadeCharacter，强制 UnFade 并清空字段。

	@param Data BaseSkillClient | { skillRunData: { FadeCharacter: Model?, runEvent: { [string]: RBXScriptConnection }?, _fxFired: { [string]: boolean }? }? }? - 技能实例；服端通常无 FadeCharacter
]]
function Fx.onEnd(Data: any)
	if Data then
		Fx.exitRolling(Data)
	end
	local runData = Data and Data.skillRunData
	if type(runData) ~= "table" then
		return
	end
	local character = runData["FadeCharacter"]
	if character then
		VisibleMgr.UnFadeCharacterModel(character, UNFADE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		runData["FadeCharacter"] = nil
	end
	local fired = _ensureFxFired(runData)
	fired[FX_ID.UnFade] = true
end

return Fx
