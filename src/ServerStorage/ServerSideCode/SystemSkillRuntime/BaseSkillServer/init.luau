--[[
	Module: BaseSkillServer
	Description: 服务端基础技能 façade。拼装 definition/context/runtime，调度开技、命中与生命周期。
	Author: 林奥宇
	Created: 2026-07-29
	Last Modified: 2026-08-31

	【范式】仅支持状态机驱动：States + InitialState + Transitions

	功能：
	- new / newWithDefinition：加载 definition、建 ExecutionContext、拼装 RuntimeHost
	- start：Hitbox + 状态机 + RuntimeHost.startClock（不发 BaseSkillStarted）
	- fire*：中途同步；getTargetCF 与客户端规则对称

	子模块（业务只经本 façade，不要直接 require 子文件）：
	- Sync.luau       getSyncRadius / fire* / getCharacterPosition
	- Start.luau      start / initSkillMaterial
	- Lifecycle.luau  连接、Enter/Exit/TryTransition、interrupt/stop/destroy

	已有同级 façade：DefinitionLoader / ExecutionContext / RuntimeHost。
	时钟不塞进 RuntimeHost；仍经 RuntimeHost.startClock 注册到 CombatWorld。
	无客户端 Clock / 表现预测 / soft-merge。

	================================================================================
	使用说明
	================================================================================

	【引入方式】
	local BaseSkillServer = require(game.ServerStorage.ServerSideCode.SystemSkillRuntime.BaseSkillServer)

	不要经 UtilsSystem 加载本 façade；PlayerAimSync / HitResolver 走 Utils 分流键。不要 require Sync / Start / Lifecycle。

	【调用方】
	GroupSkillServer、GroupSkillInstanceRuntime

	【典型流程】
		local server = BaseSkillServer.new(skillName, "Player", characterId, power, purity, skillID, mpTp)
		server:start(inputData)
		server:destroy("Finished")

	【约束】
	- 公开方法名/签名不变；self 字段仍在实例上
	- Start.luau 顶部缓存 SkillStateMachine / Utils.HitResolver（禁止函数内 require）
]]

local Class = require(game.ReplicatedFirst.AllSideCode.Class.Class)
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local PlayerAimSync = Utils.PlayerAimSync

local BaseSkillFolder = game.ReplicatedStorage.ClientSideCode.SystemSkill.BaseSkill
local BaseSkillDefinitionLoader = require(BaseSkillFolder.BaseSkillDefinitionLoader)
local BaseSkillExecutionContext = require(BaseSkillFolder.BaseSkillExecutionContext)
local BaseSkillRuntimeHost = require(BaseSkillFolder.BaseSkillRuntimeHost)
local BaseSkillTargetFind = require(BaseSkillFolder.BaseSkillTargetFind)
local AnimationPlaySide = require(BaseSkillFolder.AnimationPlaySide)
local SkillAction = require(BaseSkillFolder.SkillAction)

type BaseSkillServer = Class.BaseSkillServer

local BaseSkillServer = {}
BaseSkillServer.__index = function(self, key)
	if key == "isRunning" then
		return self:isRunningFlow()
	end
	return BaseSkillServer[key]
end

--[[
	内部：从 definition + context 拼装实例（供 new 与 newWithDefinition 共用）。
	写入技能名、角色、强度、施法标识、Hitbox 容器与生命周期埋点字段。

	@param self BaseSkillServer - 正在构造的实例
	@param definition table - { skillModule, skillName }，来自 DefinitionLoader 或测试 mock
	@param context table - BaseSkillExecutionContext.create 产出，含 characterId/characterType/skillPower 等
	@param runtimeHost table - BaseSkillRuntimeHost.create 产出，含 controlRuntime
	@param characterType "Player" | "NPC" - 用于 isPlayer 标记
	@return nil
]]
local function _assembleFromDefinition(self, definition, context, runtimeHost, characterType)
	self._definition = definition
	self._context = context
	self._runtimeHost = runtimeHost
	self.skillName = definition.skillName
	self.skillModule = definition.skillModule
	self.characterId = context.characterId
	self.characterType = context.characterType
	self.isPlayer = (characterType == "Player")
	self.character = context.character
	self.skillPower = context.skillPower
	self.skillPurity = context.skillPurity
	self.skillID = context.skillID
	self.mpTp = context.mpTp
	self.skillInputData = context.skillInputData
	self.skillTargetData = nil
	self.combatSeed = context.combatSeed
	self.skillCastId = context.skillCastId
	self.baseSkillInstanceId = context.baseSkillInstanceId
	self.activeBaseSkillIndex = context.activeBaseSkillIndex
	self.nowTime = 0
	self.skillTimeFix = 0
	self.skillPlaySpeed = 1
	self.timeLineRunServer = nil
	self.hitboxControlIndex = 0
	self.hitbox = {}
	self.hitboxRuntime = nil
	self.skillRunData = {}
	self.flowState = "Idle"
	self.authoritativeState = "Idle"
	self.controlRuntime = runtimeHost.controlRuntime
	self.isPhase1Complete = false
	self.isControlReleased = false
	self._destroyed = false
	self._isDestroying = false
	-- 生命周期埋点（排查「为什么偶尔没停干净」）
	self.destroyReason = nil
	self.finishReason = nil
	self.enteredTerminalAt = nil
	self.cleanupCompleted = false
	self.skillAction = nil
end

--[[
	初始化基础技能服务器对象（façade：load definition、create context、assemble runtimes）。

	@param skillName string - 基础技能模块名（SkillModule 脚本名）
	@param characterType "Player" | "NPC" - 施法者类型
	@param characterId number - 玩家 UserId 或 NPC id
	@param skillPower number? - 技能强度；nil 时由 ExecutionContext 默认
	@param skillPurity number? - 技能纯度；nil 时由 ExecutionContext 默认
	@param skillID number? - 技能表 ID，用于 skillConf.DamageRate
	@param mpTp string? - 技能槽魔法强度挡位（伤害等在结算处由 GetData.GetSkillMpTierEffects 换算）
	@return BaseSkillServer - 已拼装但尚未 start 的实例
]]
function BaseSkillServer.new(skillName: string, characterType: "Player" | "NPC", characterId: number, skillPower: number?, skillPurity: number?, skillID: number?, mpTp: string?)
	local self = setmetatable({}, BaseSkillServer)

	-- 1. Load definition
	local definition, loadErr = BaseSkillDefinitionLoader.load(skillName)
	assert(definition, ("[BaseSkillServer] %s"):format(loadErr or "加载失败"))

	-- 2. Create context
	local context = BaseSkillExecutionContext.create({
		characterId = characterId,
		characterType = characterType,
		skillPower = skillPower,
		skillPurity = skillPurity,
		skillID = skillID,
		mpTp = mpTp,
	})

	-- 3. Assemble runtimes（服务端 animationPlaySide=Server 时用 SkillAction 驱动 Animation）
	self.skillModule = definition.skillModule
	self.characterType = characterType
	local useServerSkillAction = AnimationPlaySide.shouldRunServerSkillAction(self)
	local runtimeHost = BaseSkillRuntimeHost.create(definition, {
		isClient = false,
		getActionsOverCheck = useServerSkillAction and function()
			if self.skillAction then
				return self.skillAction:AreAllActionsOver()
			end
			return true
		end or nil,
	})

	-- 4. Expose public API
	_assembleFromDefinition(self, definition, context, runtimeHost, characterType)
	if useServerSkillAction then
		self.skillAction = SkillAction.new(self, { serverMode = true })
	else
		self.skillAction = nil
	end
	return self
end

--[[
	测试用：使用 mock 的 definition 与 context 创建实例（不 require 真实模块）。

	@param definition table - { skillModule, skillName }，不走 DefinitionLoader
	@param context table - BaseSkillExecutionContext.create 格式（characterId/characterType 等）
	@return BaseSkillServer - 测试实例
]]
function BaseSkillServer.newWithDefinition(definition: any, context: any)
	local self = setmetatable({}, BaseSkillServer)
	self.skillModule = definition.skillModule
	self.characterType = context.characterType or "NPC"
	local useServerSkillAction = AnimationPlaySide.shouldRunServerSkillAction(self)
	local runtimeHost = BaseSkillRuntimeHost.create(definition, {
		isClient = false,
		getActionsOverCheck = useServerSkillAction and function()
			if self.skillAction then
				return self.skillAction:AreAllActionsOver()
			end
			return true
		end or nil,
	})
	_assembleFromDefinition(self, definition, context, runtimeHost, context.characterType or "NPC")
	if useServerSkillAction then
		self.skillAction = SkillAction.new(self, { serverMode = true })
	else
		self.skillAction = nil
	end
	return self
end

--[[
	获取施法目标位置。
	- 自瞄：trackTargetId / skillTargetData 动态解析
	- 未自瞄：从 PlayerAimSync 缓冲冻结一次快照（持武时客户端同步的瞄准点）

	@param self BaseSkillServer - 基础技能服实例
	@return CFrame - 目标 CFrame；无输入时为 CFrame.new()
]]
function BaseSkillServer.getTargetCF(self: BaseSkillServer): CFrame
	if PlayerAimSync.isAutoAimActiveForSkill(self) then
		local _newCF = BaseSkillTargetFind.findTarget(self.skillTargetData)
		if _newCF and self.skillInputData then
			self.skillInputData.targetCF = _newCF
		end
		return self.skillInputData and self.skillInputData.targetCF or CFrame.new()
	end
	return PlayerAimSync.getOrFreezeManualAimCF(self)
end

require(script.Sync)(BaseSkillServer)
require(script.Lifecycle)(BaseSkillServer)
require(script.Start)(BaseSkillServer)

return BaseSkillServer
