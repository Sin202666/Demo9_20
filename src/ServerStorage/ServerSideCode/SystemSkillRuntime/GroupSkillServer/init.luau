--[[
	Module: GroupSkillServer
	Description: 组技能服务端 façade。实例创建、CombatWorld 调度、输入路由、同步、冷却。
	Author: 林奥宇
	Created: 2026-02-10
	Last Modified: 2026-08-31

	玩家 CD：「技能CD时间戳」为唯一权威；NPC CD：groupSkillCooldownRemaining 内存倒计时。
	单次施法运行逻辑已抽至 GroupSkillInstanceRuntime。
	【一期 A】groupSkillRuntimeEvent / groupSkillCooldownEvent 均经 Utils.CombatWorld.register（Cooldown=Phase.Cooldown）。
	【状态模型】groupState 显式状态：
	- Idle: 无运行实例
	- Casting: 有实例，当前 BaseSkill 持有控制权（Phase1 未完成）
	- ChainWindow: 有实例，等待派生条件或超时
	- Recovering: 有实例，所有 BaseSkill 已释放控制权，等待自然结束
	- Cooldown: 无实例，冷却中

	子模块（业务只经本 façade，不要直接 require 子文件）：
	- Cooldown.luau         时间戳 / 有效 CD / combatSeed
	- Input.luau            onInputRequest
	- InstanceFactory.luau  requestRelease、register/dispose、CombatWorld tick

	GroupSkillInstanceRuntime.luau 与本 façade 同在 SystemSkillRuntime（须同迁）。
	无客户端 PresentationPredict。

	================================================================================
	使用说明
	================================================================================

	【引入方式】
	local GroupSkillServer = require(game.ServerStorage.ServerSideCode.SystemSkillRuntime.GroupSkillServer)

	【调用方】
	SystemPlayerSkill（服）

	【约束】
	- 公开方法名/签名不变
	- ENABLE_DERIVE_SUPPRESS_AFTER_CROSS_INTERRUPT 只在 init 定义一处
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Class = require(game.ReplicatedFirst.AllSideCode.Class.Class)
local CombatWorld = Utils.CombatWorld
local Players = Utils.Players
local Log = Utils.Log
local SkillNet = Utils.SkillNet
local SynSkillEffect = SkillNet.SynSkillEffect --复用：派生确认消息

local BaseSkillServerModule = require(script.Parent.BaseSkillServer)
local SystemSkillFolder = game.ReplicatedStorage.ClientSideCode.SystemSkill
local BaseSkillFolder = SystemSkillFolder.BaseSkill
local SkillModuleValidator = require(BaseSkillFolder.SkillModuleValidator)
local SkillDataSchema = require(BaseSkillFolder.SkillDataSchema)
local DoSomeAfterUserSkill = require(BaseSkillFolder.DoSomeAfterUserSkill)
local Cooldown = require(script.Cooldown)

type GroupSkillServer = typeof(Class.GroupSkillServer)
type GroupSkillInitData = typeof(Class.GroupSkillInitData)
type BaseSkillServer = typeof(Class.BaseSkillServer)
type SkillInputData = typeof(Class.SkillInputData)

--技能组配置文件夹
local GroupSkillFolder:Folder = SystemSkillFolder.GroupSkillModule

-- 跨槽打断：未配置 InterruptionPriority 时视为中档(50)；仅当 B 的优先级 **严格大于** A 时 B 可打断 A
local DEFAULT_INTERRUPTION_PRIORITY = 50

--[[
	从组技能模块读取跨槽打断优先级。
	查找顺序：模块根 InterruptionPriority / PriorityInterruption → Data.InterruptionPriority / interruptionPriority；
	非 number 或 NaN 时回落到 DEFAULT_INTERRUPTION_PRIORITY（50）。

	@param groupSkillModule any - GroupSkillModule 表；须含可选 InterruptionPriority / PriorityInterruption，或 Data 表
	@return number - 打断优先级；越大越能打断低档技能
]]
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

-- 跨槽打断后禁止派生（须与 GroupSkillClient 同值；产品语义见《技能模块作者规范》§2.3）
local ENABLE_DERIVE_SUPPRESS_AFTER_CROSS_INTERRUPT = true

local GroupSkillServer = {}
GroupSkillServer.__index = GroupSkillServer

-- 组技能显式状态
local GROUP_STATE = {
	Idle = "Idle",
	Casting = "Casting",
	ChainWindow = "ChainWindow",
	Recovering = "Recovering",
	Cooldown = "Cooldown",
}

--[[
	根据当前实例与 BaseSkill 控制状态更新 groupState。
	使用 getControlState() 语义区分：Locked / ChainOpen / Released
	- Casting: 存在 Locked（Phase1 未完成）
	- ChainWindow: 存在 ChainOpen（Phase1 完成，可派生窗口）
	- Recovering: 存在运行中 BaseSkill 且均为 Released
	- Idle / Cooldown: 无实例时按 CD 判断

	@param self GroupSkillServer - 组技能服实例
	@return nil
]]
local function _updateGroupState(self)
	local hasInstance = #self.runningRuntimeList > 0
	local hasLockedControl = false
	local hasChainOpenControl = false
	local hasRunningBaseSkill = false
	for _, runtime in ipairs(self.runningRuntimeList) do
		for _, baseSkill in runtime.baseSkills do
			if baseSkill and baseSkill:isRunningFlow() then
				hasRunningBaseSkill = true
				local controlState = baseSkill:getControlState()
				if controlState == "Locked" then
					hasLockedControl = true
				elseif controlState == "ChainOpen" then
					hasChainOpenControl = true
				end
			end
		end
	end

	if not hasInstance then
		self.groupState = Cooldown.isGroupSkillOnCooldown(self) and GROUP_STATE.Cooldown or GROUP_STATE.Idle
	elseif hasLockedControl then
		self.groupState = GROUP_STATE.Casting
	elseif hasChainOpenControl then
		self.groupState = GROUP_STATE.ChainWindow
	elseif hasRunningBaseSkill then
		self.groupState = GROUP_STATE.Recovering
	else
		self.groupState = GROUP_STATE.Idle
	end
end

--[[
	创建组技能服务器对象。玩家或怪物装备技能时调用。
	加载 GroupSkillModule、校验、归一化 Data，并启动 CombatWorld 冷却 tick。

	@param initData GroupSkillInitData - 装备初始化包，字段：
		characterType: "Player" | "NPC" - 角色类型
		characterId: number - 玩家 UserId 或 NPC id
		skillName: string - 组技能模块名（等于 GroupSkillModule 脚本名）
		slotIndex: number? - 装备槽；玩家写 CD 时间戳时必填
		skillPower: number? - 技能强度，默认 1
		skillPurity: number? - 技能纯度，默认 1
		skillMagic: number? - 魔法强度（可选）
		skillID: number? - 技能表 ID，用于 CD / 伤害
		mpTp: string? - 技能槽魔法强度挡位
	@return GroupSkillServer? - 组技能服实例；模块缺失时为 nil
]]
function GroupSkillServer.new(initData: GroupSkillInitData)
	local self = setmetatable({}, GroupSkillServer)
	self.authoritativeState = "Idle"
	self.skillName = initData.skillName
	self.characterType = initData.characterType
	self.characterId = initData.characterId
	self.slotIndex = initData.slotIndex
	self.skillPower = initData.skillPower or 1
	self.skillPurity = initData.skillPurity or 1
	self.skillMagic = initData.skillMagic
	self.skillID = initData.skillID
	self.mpTp = initData.mpTp
	local groupSkillModuleScript = GroupSkillFolder:FindFirstChild(self.skillName)
	if not groupSkillModuleScript then
		Log.warn("组技能模块未找到", self.skillName)
		return nil
	end
	local groupSkillModule = require(groupSkillModuleScript)
	-- 加载期校验
	local baseSkillFolder = SystemSkillFolder.SkillModule
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
	--组技能模块
	self.groupSkillModule = groupSkillModule
	self.interruptionPriority = _resolveInterruptionPriorityFromModule(groupSkillModule)
	-- combatSeed 由服务端权威生成，不接收客户端
	--技能开始时间戳
	self.skillStartTimestamp = 0
	--当前时间
	self.nowTime = 0
	--技能播放速度
	self.skillPlaySpeed = 1
	-- 运行时注册表：列表 + 双 map，统一协议管理生命周期
	self.runningRuntimeList = {}
	self.runtimeByCastId = {}
	self.runtimeByInstanceId = {}
	-- 兼容：runningBaseSkillInstances 指向 runningRuntimeList（调用方可继续用 ipairs）
	self.runningBaseSkillInstances = self.runningRuntimeList
	--已完成的基础技能索引
	self.completedBaseSkillIndex = {}
	--当前执行的基础技能索引
	self.activeBaseSkillIndex = 1
	--组技能冷却时间（秒，来自 skillConf.CD 或组模块 Data.skillCooldown）
	self.groupSkillCooldown = Cooldown.resolveBaseCooldownSeconds(self.skillID, groupSkillModule.Data.skillCooldown)
	-- NPC：内存倒计时；玩家：仅「技能CD时间戳」权威，此字段恒为 0
	self.groupSkillCooldownRemaining = 0
	--显式状态：Idle | Casting | ChainWindow | Recovering | Cooldown（仅 _updateGroupState 写入）
	self.groupState = GROUP_STATE.Idle
	--技能运行数据时 可以让基础技能存储数据
	self.skillRunData = {}
	--派生请求：deriveRequestByIndex[index]=true 表示请求派生到 index；inputFlagsByName 按输入名存储
	self.deriveRequestByIndex = {}
	self.inputFlagsByName = {}
	-- 被高优先级跨槽打断后：当前施法已开始的 BaseSkill 继续播完，但不再接受派生（含 Tick 内条件链）
	self.deriveSuppressedAfterCrossInterrupt = false
	--冷却事件（NPC 内存 CD + groupState；经 CombatWorld Phase.Cooldown）
	self.groupSkillCooldownEvent = nil
	self._cooldownTickId = nil
	do
		local tickId = CombatWorld.allocId("GroupSkillCooldown")
		self._cooldownTickId = tickId
		self.groupSkillCooldownEvent = CombatWorld.register(tickId, function(deltaTime)
			_updateGroupState(self)

			-- NPC 内存 CD 倒计时；玩家 CD 由「技能CD时间戳」表达，不在此递减
			if self.characterType ~= "Player" and self.groupSkillCooldownRemaining > 0 then
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
	是否有运行中实例（instanceMap / runningRuntimeList 非空）

	@param self GroupSkillServer - 组技能服实例
	@return boolean - 有未销毁的施法 runtime 则为 true
]]
function GroupSkillServer.hasActiveRuntime(self: GroupSkillServer): boolean
	return #self.runningRuntimeList > 0
end

--[[
	是否有运行中的 BaseSkill（派生值，不持久存储）

	@param self GroupSkillServer - 组技能服实例
	@return boolean - 任一 runtime 仍有 isRunningFlow 的 BaseSkill 则为 true
]]
function GroupSkillServer.hasActiveBaseSkill(self: GroupSkillServer): boolean
	for _, runtime in ipairs(self.runningRuntimeList) do
		if runtime:hasRunningBaseSkill() then
			return true
		end
	end
	return false
end

--[[
	检查是否存在控制权为 Locked 的 BaseSkill（会阻止派生/释放）。
	等价于：存在 currentBaseSkill 且 getControlState() == "Locked"

	@param self GroupSkillServer - 组技能服实例
	@return boolean - 当前段 Phase1 未完成则为 true
]]
function GroupSkillServer.hasPhase1Incomplete(self: GroupSkillServer): boolean
	for _, runtime in ipairs(self.runningRuntimeList) do
		local currentBaseSkill = runtime.baseSkills[runtime.activeBaseSkillIndex]
		if currentBaseSkill and currentBaseSkill:isRunningFlow() and not currentBaseSkill.isPhase1Complete then
			return true
		end
	end
	return false
end

--[[
	读取本组技能跨槽打断优先级（new 时已从模块解析并缓存）。

	@param self GroupSkillServer - 组技能服实例
	@return number - 打断优先级；未缓存时回落 DEFAULT_INTERRUPTION_PRIORITY（50）
]]
function GroupSkillServer.getInterruptionPriority(self: GroupSkillServer): number
	return self.interruptionPriority or DEFAULT_INTERRUPTION_PRIORITY
end

--[[
	被更高优先级组技能跨槽打断：不强制结束已开始的 BaseSkill 状态机；立即结束各段 SkillAction/放权；禁止后续派生并清缓冲。

	@param self GroupSkillServer - 被打断的组技能服实例
	@return nil
]]
function GroupSkillServer.interruptCrossSlotCast(self: GroupSkillServer)
	if ENABLE_DERIVE_SUPPRESS_AFTER_CROSS_INTERRUPT then
		self.deriveSuppressedAfterCrossInterrupt = true
	end
	self.deriveRequestByIndex = {}
	self.inputFlagsByName = {}
	for _, runtime in ipairs(self.runningRuntimeList) do
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
	提前释放技能组控制权（通过释放所有 BaseSkill 的控制权）。
	不停止 BaseSkill 状态机，表现继续播到自然结束。

	@param self GroupSkillServer - 组技能服实例
	@return nil
]]
function GroupSkillServer.releaseControl(self: GroupSkillServer)
	Log.print("提前释放技能组控制权，技能名称:", self.skillName)

	for _, runtime in ipairs(self.runningRuntimeList) do
		runtime:releaseControl()
	end

	-- 释放后重新计算状态（此时所有 BaseSkill 均为 Released）
	_updateGroupState(self)

	-- 冷却在 releaseSkill 时已设置，与技能表现并行倒计时，此处不重设

	--清除技能组级别的按键输入标志（实例级别的保留）
	self.deriveRequestByIndex = {}
	self.inputFlagsByName = {}

	--注意：不停止 BaseSkill，让它们继续运行直到自然结束
	--运行时事件会继续运行，直到所有实例都结束

	Log.print("技能组控制权已释放，BaseSkill 将继续运行，冷却时间开始倒计时，hasActiveBaseSkill:", self:hasActiveBaseSkill())
end

--[[
	施法者死亡/角色失效等：立即中断本组所有运行中实例（Interrupt 语义，广播 StopSkill）。
	不销毁组技能绑定对象；不强制重置冷却（与已成功 requestRelease 后的 CD 倒计时一致）。

	@param self GroupSkillServer - 组技能服实例
	@return nil
]]
function GroupSkillServer.interruptAllRunningCasts(self: GroupSkillServer)
	if #self.runningRuntimeList == 0 then
		return
	end
	self.deriveSuppressedAfterCrossInterrupt = false
	self.deriveRequestByIndex = {}
	self.inputFlagsByName = {}
	if self.groupSkillRuntimeEvent then
		self.groupSkillRuntimeEvent:Disconnect()
		self.groupSkillRuntimeEvent = nil
		self._runtimeTickId = nil
	end
	local toDispose = {}
	for _, r in ipairs(self.runningRuntimeList) do
		table.insert(toDispose, r)
	end
	for _, r in ipairs(toDispose) do
		self:_disposeRuntime(r, "Interrupted")
	end
	self.activeBaseSkillIndex = 1
	self.completedBaseSkillIndex = {}
	_updateGroupState(self)
end

--[[
	结束释放技能（停止所有 BaseSkill），并按角色类型写入冷却。

	@param self GroupSkillServer - 组技能服实例
	@return nil
]]
function GroupSkillServer.requestStop(self: GroupSkillServer)

	--清除所有按键输入标志
	self.deriveRequestByIndex = {}
	self.inputFlagsByName = {}

	--断开运行时事件
	if self.groupSkillRuntimeEvent then
		self.groupSkillRuntimeEvent:Disconnect()
		self.groupSkillRuntimeEvent = nil
		self._runtimeTickId = nil
	end

	local toDispose = {}
	for _, runtime in ipairs(self.runningRuntimeList) do
		runtime:stop()
		table.insert(toDispose, runtime)
	end
	for _, runtime in ipairs(toDispose) do
		self:_disposeRuntime(runtime, "Stop")
	end

	--重置状态
	self.groupState = GROUP_STATE.Cooldown
	self.nowTime = 0
	self.activeBaseSkillIndex = 1
	self.completedBaseSkillIndex = {}

	--设置冷却时间
	if self.characterType == "Player" then
		local player = Players:GetPlayerByUserId(self.characterId)
		if player then
			Cooldown.writePlayerSkillCooldownEndTimestamp(player, self.slotIndex, workspace:GetServerTimeNow() + self.groupSkillCooldown)
		end
	else
		self.groupSkillCooldownRemaining = self.groupSkillCooldown
	end
end

--[[
	销毁组技能服务器对象
	场景：服内热重载、角色切换、对象销毁等，需彻底清理所有运行中实例

	策略：断开 heartbeat 后，对每个 runtime 调用 _disposeRuntime(runtime, "Destroy")。
	runtime:destroy("Destroy") 会对每个运行中 BaseSkill 先 interrupt() 再 destroy()，
	确保客户端收到 StopSkill、无 heartbeat/hitbox 残留、无幽灵技能实例。

	@param self GroupSkillServer - 组技能服实例
	@return nil
]]
function GroupSkillServer.destroy(self: GroupSkillServer)
	self.deriveSuppressedAfterCrossInterrupt = false
	if self.groupSkillCooldownEvent then
		self.groupSkillCooldownEvent:Disconnect()
		self.groupSkillCooldownEvent = nil
		self._cooldownTickId = nil
	end
	if self.groupSkillRuntimeEvent then
		self.groupSkillRuntimeEvent:Disconnect()
		self.groupSkillRuntimeEvent = nil
		self._runtimeTickId = nil
	end

	local toDispose = {}
	for _, runtime in ipairs(self.runningRuntimeList) do
		table.insert(toDispose, runtime)
	end
	for _, runtime in ipairs(toDispose) do
		self:_disposeRuntime(runtime, "Destroy")
	end
	self.completedBaseSkillIndex = {}
	self.skillRunData = {}
	self.skillInputData = {}
	self.nowTime = 0
	self = nil
end

require(script.Input)(GroupSkillServer, ENABLE_DERIVE_SUPPRESS_AFTER_CROSS_INTERRUPT)
require(script.InstanceFactory)(GroupSkillServer, ENABLE_DERIVE_SUPPRESS_AFTER_CROSS_INTERRUPT)

return GroupSkillServer
