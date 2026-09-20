--[[
	Module: BaseSkillClient
	Description: 客户端基础技能 façade。拼装 definition/context/runtime，调度时钟、开技与生命周期。
	Author: 林奥宇
	Created: 2026-07-29
	Last Modified: 2026-08-18

	【范式】仅支持状态机驱动：States + InitialState + Transitions

	功能：
	- new / newWithDefinition：加载 definition、建 ExecutionContext、拼装 RuntimeHost + SkillAction
	- setSkillInputData / getTargetCF / handleServerEvent
	- 表现预测：skillStartPresentationPredict 无 Hitbox，按 StateTimeout 跨态，
	  进入 ControlOpenState 或 Phase1 非 Locked 后 hold；无 ControlOpen 时 InitialState 结束后 hold
	- 确认后由 GroupSkillClient 软合并 nowTime+state 快照；正式 skillStart(opts.softMerge)

	子模块（业务只经本 façade，不要直接 require 子文件）：
	- Clock.luau      TIME_SYNC_CONFIG、自适应修正、tick、setSkillTimeFix
	- Start.luau      skillStart / skillStartPresentationPredict / initSkillMaterial / soft-merge 移交
	- Lifecycle.luau  连接、Enter/Exit/TryTransition、skillEnd/interrupt/destroy、素材清理

	已有同级 façade（不在本目录）：DefinitionLoader / ExecutionContext / RuntimeHost。
	时钟不塞进 RuntimeHost；仍经 RuntimeHost.startClock 注册到 CombatWorld。

	================================================================================
	使用说明
	================================================================================

	【引入方式】
	local BaseSkillClient = require(game.ReplicatedStorage.ClientSideCode.SystemSkill.BaseSkill.BaseSkillClient)
	-- 组技能侧：require(script.Parent.Parent.BaseSkill.BaseSkillClient)

	不要经 UtilsSystem；不要 require Clock / Start / Lifecycle。

	【调用方】
	PlayerSkillClientManager、GroupSkillClient、GroupSkillClientInstanceRuntime

	【典型流程】
		local client = BaseSkillClient.new(skillName, characterId, "Player", power, purity, { skillID = id })
		client:setSkillInputData(characterId, "Player", startCF, goalCF, moveDir, castId, instId, index)
		client:skillStart()
		-- 预测：client:skillStartPresentationPredict()
		-- 软合并：client:skillStart({ softMerge = { nowTime, state, enteredAt }, softMergeRunData = pending })
		client:destroy("Finished", true)

	【约束】
	- 公开方法名/签名不变；self 字段仍在实例上，子模块不另起状态
	- CLIENT_HITBOX_DISABLED=true（Start 内）；命中以服务端为准
	- soft-merge cap、_softMergeSkipEnterHandlers、material/anim handoff 分支原样
]]

local Class = require(game.ReplicatedFirst.AllSideCode.Class.Class)
local SkillAction = require(script.Parent.SkillAction)
local GetSkillData = require(script.Parent.GetSkillData)
local SkillStateActions = require(script.Parent.SkillStateActions)
local BaseSkillDefinitionLoader = require(script.Parent.BaseSkillDefinitionLoader)
local BaseSkillExecutionContext = require(script.Parent.BaseSkillExecutionContext)
local BaseSkillRuntimeHost = require(script.Parent.BaseSkillRuntimeHost)
local BaseSkillTargetFind = require(script.Parent.BaseSkillTargetFind)
local PlayerAimSync = require(script.Parent.PlayerAimSync)

type BaseSkillClient = Class.BaseSkillClient

local BaseSkillClient = {}
BaseSkillClient.__index = function(self, key)
	if key == "isRunning" then
		return self:isRunningFlow()
	end
	return BaseSkillClient[key]
end

--[[
	内部：从 definition + context 拼装实例（供 new 与 newWithDefinition 共用）
]]
local function _assembleFromDefinition(self, definition, context, runtimeHost)
	self._definition = definition
	self._context = context
	self._runtimeHost = runtimeHost
	self.skillName = definition.skillName
	self.skillModule = definition.skillModule
	self.characterId = context.characterId
	self.characterType = context.characterType
	self.character = context.character
	self.skillPower = context.skillPower
	self.skillPurity = context.skillPurity
	self.skillID = context.skillID
	self.mpTp = context.mpTp
	self.skillInputData = context.skillInputData
	self.skillTargetData = context.skillTargetData
	self.combatSeed = context.combatSeed
	self.skillCastId = context.skillCastId
	self.baseSkillInstanceId = context.baseSkillInstanceId
	self.activeBaseSkillIndex = context.activeBaseSkillIndex
	self.skillPlaySpeed = 1
	self.nowTime = 0
	self.skillRunData = {}
	self.skillTimeUpdateEvent = nil
	self.skillTimeFix = 0
	self.hitbox = {}
	self.hitboxRuntime = nil
	self.hitboxControlIndex = 0
	self.flowState = "Idle"
	self.authoritativeState = "Idle"
	self._destroyed = false
	self._isDestroying = false
	self._skillMaterialCleared = false
	self.runGeneration = 0
	-- 生命周期埋点（排查「为什么偶尔没停干净」）
	self.destroyReason = nil
	self.finishReason = nil
	self.enteredTerminalAt = nil
	self.cleanupCompleted = false
	self.controlRuntime = runtimeHost.controlRuntime
	self.isPhase1Complete = false
	self.isControlReleased = false
	self._presentationPredictActive = false
	self._presentationPredictHold = false
	self._softMergeSkipEnterHandlers = false
	self._presentationPredictAnimHandoff = false
	self._presentationPredictMaterialHandoff = false

end

--[[
    创建基础技能对象（façade：load definition、create context、assemble runtimes）
    @param skillName string 技能名称
    @param characterId number
    @param characterType "Player" | "NPC"
    @param skillPower number?
    @param skillPurity number?
    @param createOpts { skipAnimationCreatePreload: boolean?, skillID: number?, mpTp: string? }? — skillID 用于 client 读 skillConf Size/Band（体量等）
]]
function BaseSkillClient.new(
	skillName: string,
	characterId: number,
	characterType: "Player" | "NPC",
	skillPower: number?,
	skillPurity: number?,
	createOpts: { skipAnimationCreatePreload: boolean?, skillID: number?, mpTp: string? }?
)
	local self = setmetatable({}, BaseSkillClient)

	-- 1. Load definition
	local definition, loadErr = BaseSkillDefinitionLoader.load(skillName)
	assert(definition, ("[BaseSkillClient] %s"):format(loadErr or "加载失败"))

	createOpts = createOpts or {}
	-- 2. Create context
	local context = BaseSkillExecutionContext.create({
		characterId = characterId,
		characterType = characterType,
		skillPower = skillPower,
		skillPurity = skillPurity,
		skillID = createOpts.skillID,
		mpTp = createOpts.mpTp,
	})

	-- 3. Assemble runtimes（SkillAction 需要 skillModule，先设置必要字段）
	self.skillModule = definition.skillModule
	self.skillName = definition.skillName
	self.characterId = context.characterId
	self.characterType = context.characterType
	self.character = context.character
	self._skipAnimationCreatePreload = createOpts.skipAnimationCreatePreload == true
	self.skillAction = SkillAction.new(self)
	local runtimeHost = BaseSkillRuntimeHost.create(definition, {
		isClient = true,
		getActionsOverCheck = function()
			local okGlobal = self.skillAction:AreAllActionsOver()
			if self.skillModule.phase1UsesStateActions then
				return okGlobal and SkillStateActions.areAllOver(self)
			end
			return okGlobal
		end,
	})

	-- 4. Expose public API
	_assembleFromDefinition(self, definition, context, runtimeHost)
	return self
end

--[[
	测试用：使用 mock 的 definition 与 context 创建实例（不 require 真实模块）
	@param definition table { skillModule, skillName }
	@param context table BaseSkillExecutionContext.create 格式
]]
function BaseSkillClient.newWithDefinition(definition: any, context: any)
	local self = setmetatable({}, BaseSkillClient)
	self.skillModule = definition.skillModule
	self.skillName = definition.skillName
	self.characterId = context.characterId
	self.characterType = context.characterType
	self.character = context.character
	self._skipAnimationCreatePreload = false
	self.skillAction = SkillAction.new(self)
	local runtimeHost = BaseSkillRuntimeHost.create(definition, {
		isClient = true,
		getActionsOverCheck = function()
			local okGlobal = self.skillAction:AreAllActionsOver()
			if self.skillModule.phase1UsesStateActions then
				return okGlobal and SkillStateActions.areAllOver(self)
			end
			return okGlobal
		end,
	})
	_assembleFromDefinition(self, definition, context, runtimeHost)
	return self
end

--[[
    设置技能输入数据
]]
function BaseSkillClient.setSkillInputData(self: BaseSkillClient, characterId: number, characterType: "Player" | "NPC", startCF: CFrame, goalCF: CFrame, moveDirectionStr: string?, skillCastId: string?, baseSkillInstanceId: string?, activeBaseSkillIndex: number?, trackTargetId: any?, skillTargetData: any?)
	BaseSkillExecutionContext.update(self._context, {
		skillModule = self.skillModule,
		characterId = characterId,
		characterType = characterType,
		releaseCF = startCF,
		targetCF = goalCF,
		moveDirectionStr = moveDirectionStr,
		skillCastId = skillCastId,
		baseSkillInstanceId = baseSkillInstanceId,
		activeBaseSkillIndex = activeBaseSkillIndex,
		trackTargetId = trackTargetId,
		skillTargetData = skillTargetData,
	})
	BaseSkillExecutionContext.refreshCharacter(self._context)

	local ctx = self._context
	self.characterId = ctx.characterId
	self.characterType = ctx.characterType
	self.character = ctx.character
	self.skillInputData = ctx.skillInputData
	self.skillTargetData = ctx.skillTargetData
	self.skillCastId = ctx.skillCastId
	self.baseSkillInstanceId = ctx.baseSkillInstanceId
	self.activeBaseSkillIndex = ctx.activeBaseSkillIndex
end

--[[
    处理服务端中途事件（如 ProjectileHitConfirmed）
    委托给技能模块 onServerEvent，由技能模块按 eventType 处理
    @param self BaseSkillClient
    @param eventData table 事件数据（含 eventType, hitPosition 等）
]]
function BaseSkillClient.handleServerEvent(self: BaseSkillClient, eventData: any)
	if self._destroyed then return end
	if self.skillModule and self.skillModule.onServerEvent then
		self.skillModule.onServerEvent(self, eventData)
	end
end

--[[
	获取施法目标位置（规则同 BaseSkillServer.getTargetCF）
]]
function BaseSkillClient.getTargetCF(self: BaseSkillClient): CFrame
	local input = self.skillInputData
	if not input then
		return CFrame.new()
	end
	if PlayerAimSync.isAutoAimActiveForSkill(self) then
		local _newCF = BaseSkillTargetFind.findTarget(self.skillTargetData)
		if _newCF then
			input.targetCF = _newCF
		end
		return input.targetCF
	end
	return PlayerAimSync.getOrFreezeManualAimCF(self)
end

local _skillClientClockTick = require(script.Clock)(BaseSkillClient)
require(script.Lifecycle)(BaseSkillClient)
require(script.Start)(BaseSkillClient, _skillClientClockTick)

return BaseSkillClient
