--[[
	Module: GroupSkillClient
	Description: 组技能客户端 façade。按键与表现预测、服务端确认建实例、CD/跨槽打断查询。
	Author: 林奥宇
	Created: 2026-02-10
	Last Modified: 2026-08-18

	表现预测（Data.predictPresentation，须 SkillDataSchema 全局总闸）：
	- 按键后立刻本地预跑首段 BaseSkill（无 Hitbox），跨态至 ControlOpenState 后 hold；
	- 服务端 BaseSkillStarted 同 castId 时 soft-merge（nowTime+state）并 Action/动画 handoff；
	- 拒释 clearPresentationPredict 回滚。作者为位移技配置 ControlOpenState + predictPresentation=true。

	子模块（业务只经本 façade，不要直接 require 子文件）：
	- Input.luau                onInputBegan/Ended/Request、updateSkillInput、sustain 松手
	- PresentationPredict.luau  tryStart/clear/cap/timeout/soft-merge 快照
	- InstanceFactory.luau      _createInstanceFromServerData、CombatWorld tick、remove

	GroupSkillClientInstanceRuntime.luau 仍在 GroupSkill/ 下，本拆分不搬。

	================================================================================
	使用说明
	================================================================================

	【引入方式】
	local GroupSkillClient = require(game.ReplicatedStorage.ClientSideCode.SystemSkill.GroupSkill.GroupSkillClient)

	不要经 UtilsSystem；不要 require Input / PresentationPredict / InstanceFactory。

	【调用方】
	PlayerSkillClientManager（new、onInput*、createInstanceFromServerStart、applyDerivedToInstance）

	【典型流程】
		local client = GroupSkillClient.new(skillName, slotIndex, characterId, "Player", power, purity, magic, skillID, mpTp)
		client:updateSkillInput(releaseCF, targetCF)
		client:onInputBegan()
		-- 服确认：client:createInstanceFromServerStart(payload)
		-- 派生：client:applyDerivedToInstance(castId, data)
		client:destroy()

	【约束】
	- 公开方法名/签名不变；self 字段仍在实例上
	- requestRelease 空壳保留（实例只由 BaseSkillStarted 创建）
	- ENABLE_DERIVE_SUPPRESS_AFTER_CROSS_INTERRUPT 只在 init 定义一处
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Class = require(game.ReplicatedFirst.AllSideCode.Class.Class)
local SkillSyncLog = Utils.SkillSyncLog
local Players = Utils.Players
local CfgFind = Utils.CfgFind
local EnumMgr = Utils.EnumMgr
local CombatWorld = Utils.CombatWorld
local LocalPlayer = Utils.LocalPlayer
local SkillFolder = EnumMgr.SkillFolder

local SkillModuleValidator = require(script.Parent.Parent.BaseSkill.SkillModuleValidator)
local SkillDataSchema = require(script.Parent.Parent.BaseSkill.SkillDataSchema)

type GroupSkillClient = typeof(Class.GroupSkillClient)
type SkillInputData = typeof(Class.SkillInputData)
type BaseSkillClient = typeof(Class.BaseSkillClient)
type Skill = typeof(Class.Skill)

--技能组配置文件夹
local GroupSkillFolder:Folder = script.Parent.Parent.GroupSkillModule

-- 跨槽打断：未配置 InterruptionPriority 时视为中档(50)；仅当 B 的优先级 **严格大于** A 时 B 可打断 A
local DEFAULT_INTERRUPTION_PRIORITY = 50

local function _resolveInterruptionPriorityFromModule(groupSkillModule: any): number
	local v = groupSkillModule.InterruptionPriority
	if v == nil then
		v = groupSkillModule.PriorityInterruption
	end
	local data = groupSkillModule.Data
	if v == nil and type(data) == "table" then
		v = (data :: any).InterruptionPriority or (data :: any).interruptionPriority
	end
	if type(v) == "number" and v == v then
		return v
	end
	return DEFAULT_INTERRUPTION_PRIORITY
end

-- 跨槽打断后禁止派生（须与 GroupSkillServer 同值；产品语义见《技能模块作者规范》§2.3）
local ENABLE_DERIVE_SUPPRESS_AFTER_CROSS_INTERRUPT = true

--组技能客户端类
local GroupSkillClient = {}
GroupSkillClient.__index = GroupSkillClient

local function resolveBaseCooldownSeconds(skillID: number?, moduleDefault: number): number
	if skillID and skillID > 0 then
		local skillCfg = CfgFind.FindCfgByID(skillID, EnumMgr.ItemType.Skill)
		if skillCfg then
			local cd = skillCfg.CD
			if type(cd) == "number" and cd >= 0 then
				return cd
			end
			local n = tonumber(cd)
			if n and n >= 0 then
				return n
			end
		end
	end
	return moduleDefault
end

--[[
    创建组技能客户端对象 播放技能表现
    @param skillName: string 技能名称
    @return GroupSkillClient 组技能客户端对象
]]
function GroupSkillClient.new(skillName: string, slotIndex: number, characterId: number, characterType: "Player" | "NPC", skillPower: number?, skillPurity: number?, skillMagic: number?, skillID: number?, mpTp: string?)
	local self = setmetatable({}, GroupSkillClient)
	self.authoritativeState = "Idle"
	self.skillName = skillName
	self.skillPower = skillPower or 1
	self.skillPurity = skillPurity or 1
	self.skillMagic = skillMagic
	self.skillID = skillID
	self.mpTp = mpTp

	--加载组技能模块
	local groupSkillModuleScript = GroupSkillFolder:FindFirstChild(self.skillName)
	if not groupSkillModuleScript then
		warn("组技能模块未找到", self.skillName)
		return nil
	end
	local groupSkillModule = require(groupSkillModuleScript)
	-- 加载期校验
	local baseSkillFolder = script.Parent.Parent.SkillModule
	local function resolveBaseSkill(name)
		local mod = baseSkillFolder:FindFirstChild(name)
		if not mod or not mod:IsA("ModuleScript") then return nil end
		local ok, result = pcall(require, mod)
		return ok and result or nil
	end
	local ok, errs = SkillModuleValidator.validateForRelease("GroupSkill", groupSkillModule, {
		skillName = self.skillName,
		moduleScriptName = groupSkillModuleScript.Name,
		resolveBaseSkill = resolveBaseSkill,
		env = "production",
		suppressions = groupSkillModule.Data and groupSkillModule.Data.suppressions or nil,
	})
	if not ok then
		SkillModuleValidator.failOnError(self.skillName, errs, true)
	end
	-- 归一化 Data（集中默认值）
	if groupSkillModule.Data then
		groupSkillModule.Data = SkillDataSchema.normalizeSkillData(groupSkillModule.Data)
	end
	self.groupSkillModule = groupSkillModule
	self.interruptionPriority = _resolveInterruptionPriorityFromModule(groupSkillModule)
	--技能栏位索引
	self.slotIndex = slotIndex
	--角色ID
	self.characterId = characterId
	--角色类型
	self.characterType = characterType
	-- isRunning 由 hasActiveBaseSkill() 派生，不持久存储
	--当前时间
	self.nowTime = 0
	--技能播放速度
	self.skillPlaySpeed = 1
	--正在运行的 BaseSkill 实例列表（支持多实例，单次施法由 _createInstanceFromServerData 创建）
	self.runningBaseSkillInstances = {}
	--实例字典，key=skillCastId，用于精准查找（与 runningBaseSkillInstances 并存）
	self.instanceMap = {}
	--【P2】服务端确认的可派生实例 skillCastId，派生输入请求绑定到此实例
	self.lastDerivableSkillCastId = nil
	-- visualSeed：客户端本地，仅用于纯视觉扰动；combatSeed 由服务端同步，权威
	self.visualSeed = math.random(1, 1000000)
	self.combatSeed = nil
	-- 表现预测：ReleaseGroupSkill 后本地模拟至 ControlOpen/Phase1 hold；BaseSkillStarted 或拒绝时清理
	self._presentationPredict = nil
	self._presentationPredictEpoch = 0
	self._lastPresentationPredictCastId = nil
	self._presentationPredictStartClock = nil
	self._pendingSoftMergeSnapshot = nil
	self._pendingSoftMergeAnimHandoffForNextRuntime = nil
	self._pendingSoftMergeRunData = nil
	self._skipFixSkillTimeForCastId = nil
	-- sustainActiveUntilSkillButtonRelease：已 FireServer 新释法、尚未收到首段 BaseSkillStarted 建实例；松手若早于此时则暂存，实例就绪后补发 buttonUp
	self._sustainAwaitingFirstInstanceFromReleaseRequest = false
	self._pendingEarlyButtonUpForSustainHold = false
	--已完成的基础技能索引
	self.completedBaseSkillIndex = {}
	--当前执行的基础技能索引
	self.activeBaseSkillIndex = 1
	--技能运行数据
	self.skillRunData = {}
	--技能输入数据 施法者位置 技能目标位置 角色模型
	self.skillInputData = {}
	--组技能运行时事件
	self.groupSkillRuntimeEvent = nil
	--按键输入请求标志表（用于技能派生，按派生索引存储）
	--派生请求：deriveRequestByIndex[index]=true 表示请求派生到 index；inputFlagsByName 按输入名存储
	self.deriveRequestByIndex = {}
	self.inputFlagsByName = {}
	self.deriveSuppressedAfterCrossInterrupt = false
	--组技能冷却时间（与服一致：有 skillID 时用 skillConf.CD）
	self.groupSkillCooldown = resolveBaseCooldownSeconds(skillID, groupSkillModule.Data.skillCooldown)
	-- NPC 客户端内存 CD；本地玩家 CD 仅「技能CD时间戳」
	self.groupSkillCooldownRemaining = 0
	--冷却事件（NPC / 旁观；经 CombatWorld Phase.Cooldown）
	self.groupSkillCooldownEvent = nil
	self._cooldownTickId = nil

	local isLocalPlayerSkill = characterType == "Player" and characterId == LocalPlayer.UserId
	if not isLocalPlayerSkill then
		local tickId = CombatWorld.allocId("GroupSkillCooldown")
		self._cooldownTickId = tickId
		self.groupSkillCooldownEvent = CombatWorld.register(tickId, function(deltaTime)
			if self.groupSkillCooldownRemaining > 0 then
				if self.groupSkillCooldownRemaining > deltaTime then
					self.groupSkillCooldownRemaining -= deltaTime
				else
					self.groupSkillCooldownRemaining = 0
				end
			end
		end, CombatWorld.Phase.Cooldown)
	end

	return self
end

--[[
	是否处于冷却中：本地玩家仅「技能CD时间戳」；NPC / 旁观角色用内存倒计时
]]
function GroupSkillClient.isCooldownActiveByTimestamp(self: GroupSkillClient): boolean
	if self.characterType == "Player" and self.characterId == LocalPlayer.UserId then
		local folder = LocalPlayer:FindFirstChild(SkillFolder.CooldownName)
		if not folder or not folder:IsA("Folder") or not self.slotIndex then
			return false
		end
		local nv = folder:FindFirstChild(SkillFolder.SlotPrefix .. tostring(self.slotIndex))
		if not nv or not nv:IsA("NumberValue") then
			return false
		end
		return workspace:GetServerTimeNow() < nv.Value
	end
	return self.groupSkillCooldownRemaining > 0
end

--[[
    对齐技能时间轴
    @param self: GroupSkillClient 组技能客户端对象
    @param serverTime: number 服务器时间
    @param serverCooldownTime: number? 服务器冷却时间（可选）
    @param skillCastId: string? 实例 ID（若提供则只对齐该实例，否则对齐所有）
]]
function GroupSkillClient.fixSkillTime(self: GroupSkillClient, serverTime: number, serverCooldownTime: number?, skillCastId: string?)
	if skillCastId and self._skipFixSkillTimeForCastId == skillCastId then
		-- 本 cast 已 soft-merge，跳过 FixSkillTime 双追轴
		self._skipFixSkillTimeForCastId = nil
		return
	end
	if skillCastId then
		local runtime = self.instanceMap[skillCastId]
		if runtime and runtime.fixTime then
			runtime:fixTime(serverTime)
		end
	else
		for _, runtime in pairs(self.instanceMap) do
			if runtime and runtime.fixTime then
				runtime:fixTime(serverTime)
			end
		end
	end
end

--[[
	检查是否存在 Phase 1 未完成的 BaseSkill（派生模式）
	当所有当前 BaseSkill 都完成 Phase 1 且冷却结束时，可再次释放
]]
--[[
	是否有运行中实例（instanceMap 非空）
]]
function GroupSkillClient.hasActiveRuntime(self: GroupSkillClient): boolean
	return next(self.instanceMap) ~= nil
end

--[[
	是否有运行中的 BaseSkill（派生值，不持久存储）
]]
function GroupSkillClient.hasActiveBaseSkill(self: GroupSkillClient): boolean
	for _, runtime in pairs(self.instanceMap) do
		if runtime and runtime.baseSkills then
			for _, baseSkill in runtime.baseSkills do
				if baseSkill and baseSkill:isRunningFlow() then
					return true
				end
			end
		end
	end
	return false
end

function GroupSkillClient.hasPhase1Incomplete(self: GroupSkillClient): boolean
	for _, runtime in pairs(self.instanceMap) do
		local currentBaseSkill = runtime.baseSkills and runtime.baseSkills[runtime.activeBaseSkillIndex]
		if currentBaseSkill and currentBaseSkill:isRunningFlow() and not currentBaseSkill.isPhase1Complete then
			return true
		end
	end
	return false
end

function GroupSkillClient.getInterruptionPriority(self: GroupSkillClient): number
	return self.interruptionPriority or DEFAULT_INTERRUPTION_PRIORITY
end

--[[
	被更高优先级组技能跨槽打断：不结束已开始的 BaseSkill 状态机；立即 Over 各段 SkillAction 并放权；清一期预测、派生缓冲。
]]
function GroupSkillClient.interruptAllCastingForCrossSlot(self: GroupSkillClient)
	self:clearPresentationPredict()
	if ENABLE_DERIVE_SUPPRESS_AFTER_CROSS_INTERRUPT then
		self.deriveSuppressedAfterCrossInterrupt = true
	end
	self.deriveRequestByIndex = {}
	self.inputFlagsByName = {}
	for _, runtime in pairs(self.instanceMap) do
		if runtime and runtime._clearBuffers then
			runtime:_clearBuffers()
		end
		if runtime and runtime.baseSkills then
			for _, bs in runtime.baseSkills do
				if bs and bs.isRunningFlow and bs:isRunningFlow() and bs.interruptSkillActionsOnly then
					bs:interruptSkillActionsOnly()
				end
			end
		end
	end
end

--[[
	本地按下技能键：是否会走「派生」分支（Phase1 未完成、未被跨槽禁止派生、且存在下一段 Skill 配置）。
	为 false 时本次按下视为新开释而非派生，须先满足「技能CD时间戳」（调用方应在跨槽打断前预检）。
]]
function GroupSkillClient.shouldBypassCooldownForLocalPress(self: GroupSkillClient): boolean
	if not self:hasPhase1Incomplete() then
		return false
	end
	if ENABLE_DERIVE_SUPPRESS_AFTER_CROSS_INTERRUPT and self.deriveSuppressedAfterCrossInterrupt then
		return false
	end
	for _, runtime in pairs(self.instanceMap) do
		local hasRunningBaseSkill = false
		for _, baseSkill in runtime.baseSkills do
			if baseSkill and baseSkill:isRunningFlow() then
				hasRunningBaseSkill = true
				break
			end
		end
		if hasRunningBaseSkill then
			local nextBaseSkillIndex = runtime.activeBaseSkillIndex + 1
			local nextSkillConfig = self.groupSkillModule.Skill[nextBaseSkillIndex]
			if nextSkillConfig then
				return true
			end
		end
	end
	return false
end

-- P0: requestRelease 不再保留创建逻辑，实例创建统一由 createInstanceFromServerStart 驱动
function GroupSkillClient.requestRelease(self: GroupSkillClient, fromServerConfirmation: boolean?, overrideData: {releaseCF: CFrame, targetCF: CFrame, moveDirectionStr: string?}?, skillCastId: string?)
	if fromServerConfirmation ~= true then
		warn("[GroupSkillClient] 客户端禁止无服务器确认直接创建技能实例")
		return
	end
	-- 创建逻辑已移除，由 SynSkillEffect BaseSkillStarted -> createInstanceFromServerStart 统一驱动
end

--[[
    提前释放技能组控制权（通过释放所有 BaseSkill 的控制权）
    @param self: GroupSkillClient 组技能客户端对象
]]
function GroupSkillClient.releaseControl(self: GroupSkillClient)
	for _, runtime in pairs(self.instanceMap) do
		if runtime and runtime.releaseControl then
			runtime:releaseControl()
		end
	end

	local hasActiveBaseSkill = false
	for _, runtime in pairs(self.instanceMap) do
		for _, baseSkill in runtime.baseSkills do
			if baseSkill and baseSkill:isRunningFlow() and not baseSkill.isControlReleased then
				hasActiveBaseSkill = true
				break
			end
		end
		if hasActiveBaseSkill then break end
	end
	self.deriveRequestByIndex = {}
	self.inputFlagsByName = {}
end

-- P0 精准停止：按 skillCastId + baseSkillInstanceId 只停单段 BaseSkill，不误杀其他实例
function GroupSkillClient.requestStop(self: GroupSkillClient, stopData: {skillCastId: string?, baseSkillInstanceId: string?, reason: string?}?)
	if not stopData or not stopData.skillCastId or not stopData.baseSkillInstanceId then
		return
	end

	SkillSyncLog.log(self.skillName, stopData.skillCastId, stopData.baseSkillInstanceId, "Client", "StopSkillApplied", stopData.reason and ("reason=" .. stopData.reason) or "")

	local runtime = self.instanceMap[stopData.skillCastId]
	if not runtime then return end

	if runtime:stopBaseSkill(stopData.baseSkillInstanceId, stopData.reason) then
		self:_removeSkillInstance(stopData.skillCastId)
	end

	if not self:hasActiveBaseSkill() then
		self.nowTime = 0
		self.activeBaseSkillIndex = 1
		self.completedBaseSkillIndex = {}
	end
end

-- 仅 destroy 调用：停止并销毁所有实例（正常 StopSkill 走 requestStop(stopData) 精准停）
function GroupSkillClient._stopAllForDestroy(self: GroupSkillClient)
	self.deriveRequestByIndex = {}
	self.inputFlagsByName = {}
	if self.groupSkillRuntimeEvent then
		self.groupSkillRuntimeEvent:Disconnect()
		self.groupSkillRuntimeEvent = nil
		self._runtimeTickId = nil
	end
	local toRemove = {}
	for castId, _ in pairs(self.instanceMap) do
		table.insert(toRemove, castId)
	end
	for _, castId in ipairs(toRemove) do
		self:_removeSkillInstance(castId, true)
	end
	self.nowTime = 0
	self.activeBaseSkillIndex = 1
	self.completedBaseSkillIndex = {}
end

-- 销毁组技能客户端对象
function GroupSkillClient.destroy(self: GroupSkillClient)
	self.deriveSuppressedAfterCrossInterrupt = false
	self:clearPresentationPredict()
	self:_stopAllForDestroy()

	if self.groupSkillCooldownEvent then
		self.groupSkillCooldownEvent:Disconnect()
		self.groupSkillCooldownEvent = nil
		self._cooldownTickId = nil
	end

	self.instanceMap = {}
	self.skillRunData = {}
	self.skillInputData = {}
end

require(script.PresentationPredict)(GroupSkillClient)
require(script.Input)(GroupSkillClient, ENABLE_DERIVE_SUPPRESS_AFTER_CROSS_INTERRUPT)
require(script.InstanceFactory)(GroupSkillClient, ENABLE_DERIVE_SUPPRESS_AFTER_CROSS_INTERRUPT)

return GroupSkillClient
