--[[
	Module: GroupSkillInstanceRuntime
	Description: 组技能单次施法实例运行器（当前段、派生条件、下一段、回收）
	Author: 林奥宇
	Created: 2026-07-29
	Last Modified: 2026-08-31

	GroupSkillServer 仅负责：创建 runtime、调度 Tick、输入路由、同步入口。
	本文件与 GroupSkillServer 同在 SystemSkillRuntime，须同迁。
]]
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local SkillSyncLog = Utils.SkillSyncLog
local Players = Utils.Players
local Log = Utils.Log

local SystemSkillFolder = game.ReplicatedStorage.ClientSideCode.SystemSkill
local BaseSkillFolder = SystemSkillFolder.BaseSkill
local GroupSkillFolder = SystemSkillFolder.GroupSkill
local SkillSyncEventFactory = require(BaseSkillFolder.SkillSyncEventFactory)
local ClientObserverDurationEstimator = require(BaseSkillFolder.ClientObserverDurationEstimator)
local SkillSyncDispatcher = require(BaseSkillFolder.SkillSyncDispatcher)
local SkillSyncRouter = require(BaseSkillFolder.SkillSyncRouter)
local GetSkillData = require(BaseSkillFolder.GetSkillData)
local BaseSkillServerModule = require(script.Parent.BaseSkillServer)
local DeclarativeCondition = require(GroupSkillFolder.DeclarativeCondition)
local ChainConditionContext = require(GroupSkillFolder.ChainConditionContext)
local SkillEventConst = require(BaseSkillFolder.SkillEventConst)

--[[
	玩家施法输入服权钳制（就地改 skillInputData）；非 Player 跳过
	@param owner any - GroupSkillServer（含 characterType/characterId/skillID）
	@param skillInputData table? - 客户端上传的施法输入
	@return table? - 同一表或 nil
]]
local function _sanitizeCastInputIfPlayer(owner, skillInputData)
	if not skillInputData or not owner or owner.characterType ~= "Player" then
		return skillInputData
	end
	local character = GetSkillData.getCharacter(owner.characterType, owner.characterId)
	if not character then
		return skillInputData
	end
	local maxRange = GetSkillData.resolveCastAimMaxRange(owner.skillID)
	return GetSkillData.sanitizePlayerCastInput(character, skillInputData, maxRange)
end

--[[
	安全执行派生条件，支持 function(ctx) 与声明式 data-driven。
	异常只记 warn，不拖垮 runtime。

	@param nextSkillConfig table - 下一段配置，须含 condition（function 或声明式 table）
	@param ctx ChainConditionContext - 派生条件只读上下文
	@param runtimeInfo table? - 日志附加 { skillName, skillCastId, fromIndex, toIndex }
	@return boolean - 条件通过为 true；缺失/异常为 false
]]
local function _evaluateChainCondition(nextSkillConfig, ctx, runtimeInfo)
	if not nextSkillConfig then return false end
	local cond = nextSkillConfig.condition
	if cond == nil then return false end

	if DeclarativeCondition.isDeclarative(cond) then
		local ok, result = pcall(DeclarativeCondition.evaluate, cond, ctx)
		if not ok then
			local info = runtimeInfo or {}
			Log.warn("[GroupSkillInstanceRuntime] 声明式 condition 解析异常:", info.skillName or "?", info.skillCastId or "?", info.fromIndex, "->", info.toIndex, result)
			return false
		end
		return not not result
	end

	if type(cond) ~= "function" then return false end
	local ok, result = pcall(cond, ctx)
	if not ok then
		local info = runtimeInfo or {}
		Log.warn("[GroupSkillInstanceRuntime] condition 执行异常:", info.skillName or "?", info.skillCastId or "?", info.fromIndex, "->", info.toIndex, result)
		return false
	end
	return not not result
end

-- 生命周期状态：Created -> Running -> Finishing -> Disposed
local LIFE_STATE = {
	Created = "Created",
	Running = "Running",
	Finishing = "Finishing",
	Disposed = "Disposed",
}

local GroupSkillInstanceRuntime = {}
GroupSkillInstanceRuntime.__index = GroupSkillInstanceRuntime

--[[
	创建单次施法实例运行器。按组模块 Skill[] 创建各段 BaseSkillServer，并钳制玩家施法输入。

	@param owner GroupSkillServer - 组技能服实例（提供 characterType、characterId、skillPower 等）
	@param skillCastId string - 一次整组施法 ID，从组技能开始到结束所有段共享
	@param skillInputData SkillInputData? - 施法输入；Player 会就地钳制 releaseCF/targetCF
	@param combatSeed number - 服务端权威战斗种子（暴击、伤害浮动等）
	@return GroupSkillInstanceRuntime - 新建运行器（尚未 start）
]]
function GroupSkillInstanceRuntime.new(owner, skillCastId, skillInputData, combatSeed)
	local self = setmetatable({}, GroupSkillInstanceRuntime)
	self.owner = owner
	self.skillCastId = skillCastId
	self.combatSeed = combatSeed
	self._destroyed = false
	self._isDestroying = false
	self.lifeState = LIFE_STATE.Created
	self.groupSkillModule = owner.groupSkillModule

	self.baseSkills = {}
	self.activeBaseSkillIndex = 1
	self.completedBaseSkillIndex = {}
	self.deriveRequestByIndex = {} -- [baseSkillIndex] = requestTime（限时缓冲，超时自动清除）
	self.inputBuffer = {} -- inputName -> lastReceivedAt (nowTime)，用于 CheckInputBuffered 时间窗口判断
	-- 输入快照：本次施法输入，applyInputRequest 仅做字段级更新
	-- Player：写入前服权钳制 releaseCF/targetCF
	skillInputData = _sanitizeCastInputIfPlayer(owner, skillInputData)
	self.castInputSnapshot = {}
	if skillInputData then
		if skillInputData.releaseCF ~= nil then self.castInputSnapshot.releaseCF = skillInputData.releaseCF end
		if skillInputData.targetCF ~= nil then self.castInputSnapshot.targetCF = skillInputData.targetCF end
		if skillInputData.moveDirectionStr ~= nil then self.castInputSnapshot.moveDirectionStr = skillInputData.moveDirectionStr end
		if skillInputData.trackTargetId ~= nil then self.castInputSnapshot.trackTargetId = skillInputData.trackTargetId end
		if skillInputData.skillTargetData ~= nil then self.castInputSnapshot.skillTargetData = skillInputData.skillTargetData end
		if skillInputData.approachLandWorldPos ~= nil then self.castInputSnapshot.approachLandWorldPos = skillInputData.approachLandWorldPos end
		if skillInputData.moveFaceMode ~= nil then self.castInputSnapshot.moveFaceMode = skillInputData.moveFaceMode end
		if skillInputData.moveFaceWorldPos ~= nil then self.castInputSnapshot.moveFaceWorldPos = skillInputData.moveFaceWorldPos end
		if skillInputData.multThunderPathPoints ~= nil then
			self.castInputSnapshot.multThunderPathPoints = skillInputData.multThunderPathPoints
		end
		if typeof(skillInputData.multThunderSpawnGround) == "Vector3" then
			self.castInputSnapshot.multThunderSpawnGround = skillInputData.multThunderSpawnGround
		end
	end
	-- 运行态数据：供 runtime 及技能模块挂载，applyInputRequest 不覆盖
	self.skillRunData = {}
	self.nowTime = 0
	self.startTimestamp = workspace:GetServerTimeNow()

	for index, baseSkillConfig in owner.groupSkillModule.Skill do
		local newBaseSkill = BaseSkillServerModule.new(
			baseSkillConfig.baseSkillName,
			owner.characterType,
			owner.characterId,
			owner.skillPower,
			owner.skillPurity,
			owner.skillID,
			owner.mpTp
		)
		newBaseSkill.combatSeed = combatSeed
		newBaseSkill.skillCastId = skillCastId
		newBaseSkill.baseSkillInstanceId = skillCastId .. "_B" .. tostring(index)
		self.baseSkills[index] = newBaseSkill
	end

	self._chainConditionCtx = ChainConditionContext.createChainConditionContext(self)

	return self
end


--[[
	测试用：使用预创建的 BaseSkillServer 实例构造 runtime（不依赖 GetSkillData/loader）。

	@param baseSkills {BaseSkillServer} - 已创建的 BaseSkill 列表
	@param skillCastId string? - 测试施法 ID；nil 时为 "test_cast"
	@param combatSeed number? - 测试战斗种子；nil 时为 0
	@return GroupSkillInstanceRuntime - 测试用运行器
]]
function GroupSkillInstanceRuntime._testNewWithBaseSkills(baseSkills, skillCastId, combatSeed)
	local self = setmetatable({}, GroupSkillInstanceRuntime)
	self.owner = nil
	self.skillCastId = skillCastId or "test_cast"
	self.combatSeed = combatSeed or 0
	self._destroyed = false
	self._isDestroying = false
	self.lifeState = LIFE_STATE.Created
	self.groupSkillModule = nil

	self.baseSkills = {}
	for i, bs in ipairs(baseSkills) do
		self.baseSkills[i] = bs
		if bs then
			bs.combatSeed = self.combatSeed
			bs.skillCastId = self.skillCastId
			bs.baseSkillInstanceId = (self.skillCastId or "test") .. "_B" .. tostring(i)
		end
	end
	self.activeBaseSkillIndex = 1
	self.completedBaseSkillIndex = {}
	self.deriveRequestByIndex = {}
	self.inputBuffer = {}
	self.castInputSnapshot = {}
	self.skillRunData = {}
	self.nowTime = 0
	self.startTimestamp = workspace:GetServerTimeNow()

	self._chainConditionCtx = ChainConditionContext.createChainConditionContext(self)

	return self
end

--[[
	启动第一个基础技能并广播 BaseSkillStarted。
	由 GroupSkillServer.requestRelease 在创建 runtime 后调用。

	@param self GroupSkillInstanceRuntime - 单次施法运行器
	@return boolean - 首段启动成功为 true；缺配置则为 false
]]
function GroupSkillInstanceRuntime:start()
	local firstBaseSkill = self.baseSkills[1]
	if not firstBaseSkill then
		Log.warn("[GroupSkillInstanceRuntime] 第一个基础技能不存在")
		return false
	end

	local firstSkillConfig = self.groupSkillModule.Skill[1]
	if not firstSkillConfig then
		Log.warn("[GroupSkillInstanceRuntime] 第一个基础技能配置不存在")
		return false
	end

	local baseSkillInputData = {
		characterType = self.owner.characterType,
		characterId = self.owner.characterId,
		skillName = firstSkillConfig.baseSkillName,
		releaseCF = self.castInputSnapshot.releaseCF,
		targetCF = self.castInputSnapshot.targetCF,
		combatSeed = self.combatSeed,
		moveDirectionStr = self.castInputSnapshot.moveDirectionStr,
		trackTargetId = self.castInputSnapshot.trackTargetId,
		skillTargetData = self.castInputSnapshot.skillTargetData,
		approachLandWorldPos = self.castInputSnapshot.approachLandWorldPos,
		moveFaceMode = self.castInputSnapshot.moveFaceMode,
		moveFaceWorldPos = self.castInputSnapshot.moveFaceWorldPos,
		multThunderPathPoints = self.castInputSnapshot.multThunderPathPoints,
		multThunderSpawnGround = self.castInputSnapshot.multThunderSpawnGround,
		skillCastId = self.skillCastId,
		baseSkillInstanceId = firstBaseSkill.baseSkillInstanceId,
		activeBaseSkillIndex = 1,
		skipClientSync = true,
	}
	firstBaseSkill:start(baseSkillInputData)

	local startedSid = firstBaseSkill.skillInputData
	if startedSid then
		if startedSid.multThunderPathPoints ~= nil then
			self.castInputSnapshot.multThunderPathPoints = startedSid.multThunderPathPoints
		end
		if typeof(startedSid.multThunderSpawnGround) == "Vector3" then
			self.castInputSnapshot.multThunderSpawnGround = startedSid.multThunderSpawnGround
		end
	end

	local observerMaxSec = ClientObserverDurationEstimator.estimateForGroupSkill(self.groupSkillModule)
	local baseSkillStartedData = SkillSyncEventFactory.baseSkillStarted(self, firstSkillConfig, observerMaxSec)
	SkillSyncLog.log(self.owner.skillName, self.skillCastId, baseSkillStartedData.baseSkillInstanceId, "Server", "BaseSkillStarted", "")
	local releasePos = self.castInputSnapshot.releaseCF and self.castInputSnapshot.releaseCF.Position
	SkillSyncDispatcher.dispatch(self, "BaseSkillStarted", baseSkillStartedData, releasePos)

	self.lifeState = LIFE_STATE.Running
	return true
end

--[[
	持续技：buttonUp 时尝试 SkillButtonRelease 转段并同步旁观。

	@param self GroupSkillInstanceRuntime - 单次施法运行器
	@param currentBaseSkill any - 当前段 BaseSkill
	@return nil
]]
local function _tryHandleSustainButtonRelease(self, currentBaseSkill)
	if not currentBaseSkill:isRunningFlow() then
		return
	end
	if not self.groupSkillModule or not self.groupSkillModule.Data then
		return
	end
	if self.groupSkillModule.Data.sustainActiveUntilSkillButtonRelease ~= true then
		return
	end
	if not self.inputBuffer or self.inputBuffer["buttonUp"] == nil then
		return
	end
	if not currentBaseSkill:TryTransition(SkillEventConst.SkillButtonRelease) then
		return
	end
	self.inputBuffer["buttonUp"] = nil
	-- 松手仅在施法端/服务端有 inputBuffer；旁观客户端需与 BaseSkillStateTransition 对齐（同 PerfectBlock 路径）
	local payload = SkillSyncEventFactory.baseSkillStateTransition(self, currentBaseSkill, SkillEventConst.SkillButtonRelease)
	SkillSyncLog.log(
		self.owner.skillName,
		self.skillCastId,
		currentBaseSkill.baseSkillInstanceId,
		"Server",
		"BaseSkillStateTransition",
		SkillEventConst.SkillButtonRelease
	)
	local character = GetSkillData.getCharacter(self.owner.characterType, self.owner.characterId)
	local root = character and (character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart)
	local pos = root and root.Position or (self.castInputSnapshot.releaseCF and self.castInputSnapshot.releaseCF.Position)
	SkillSyncDispatcher.dispatch(self, "BaseSkillStateTransition", payload, pos)
end

--[[
	条件通过后启动下一段，并广播 Derived。
	仅传只读 helper，禁止 condition 内写状态。

	@param self GroupSkillInstanceRuntime - 单次施法运行器
	@param currentBaseSkill any - 当前段 BaseSkill
	@param nextBaseSkillIndex number - 下一段索引
	@param nextSkillConfig table - 下一段配置（含 baseSkillName / breakLastSkill / condition）
	@return nil
]]
local function _tryDeriveNextBaseSkill(self, currentBaseSkill, nextBaseSkillIndex, nextSkillConfig)
	local conditionResult = _evaluateChainCondition(nextSkillConfig, self._chainConditionCtx, {
		skillName = self.owner and self.owner.skillName,
		skillCastId = self.skillCastId,
		fromIndex = self.activeBaseSkillIndex,
		toIndex = nextBaseSkillIndex,
	})
	if not conditionResult then
		return
	end
	local nextBaseSkill = self.baseSkills[nextBaseSkillIndex]
	if not nextBaseSkill or nextBaseSkill:isRunningFlow() then
		return
	end
	if currentBaseSkill:isRunningFlow() then
		if nextSkillConfig.breakLastSkill then
			SkillSyncLog.log(self.owner.skillName, self.skillCastId, currentBaseSkill.baseSkillInstanceId, "Server", "BreakLastSkill", string.format("from=%d to=%d", self.activeBaseSkillIndex, nextBaseSkillIndex))
			currentBaseSkill:stop()
			table.insert(self.completedBaseSkillIndex, self.activeBaseSkillIndex)
		end
	else
		local isAlreadyProcessed = false
		for _, completedIndex in self.completedBaseSkillIndex do
			if completedIndex == self.activeBaseSkillIndex then
				isAlreadyProcessed = true
				break
			end
		end
		if not isAlreadyProcessed then
			table.insert(self.completedBaseSkillIndex, self.activeBaseSkillIndex)
		end
	end

	local fromBaseSkillIndex = self.activeBaseSkillIndex
	self.activeBaseSkillIndex = nextBaseSkillIndex

	local nextBaseSkillInputData = {
		characterType = self.owner.characterType,
		characterId = self.owner.characterId,
		skillName = nextSkillConfig.baseSkillName,
		releaseCF = self.castInputSnapshot.releaseCF,
		targetCF = self.castInputSnapshot.targetCF,
		combatSeed = self.combatSeed,
		moveDirectionStr = self.castInputSnapshot.moveDirectionStr,
		trackTargetId = self.castInputSnapshot.trackTargetId,
		skillTargetData = self.castInputSnapshot.skillTargetData,
		approachLandWorldPos = self.castInputSnapshot.approachLandWorldPos,
		moveFaceMode = self.castInputSnapshot.moveFaceMode,
		moveFaceWorldPos = self.castInputSnapshot.moveFaceWorldPos,
		skillCastId = self.skillCastId,
		baseSkillInstanceId = nextBaseSkill.baseSkillInstanceId,
		activeBaseSkillIndex = nextBaseSkillIndex,
		skipClientSync = true,
	}
	nextBaseSkill:start(nextBaseSkillInputData)

	local derivedData = SkillSyncEventFactory.baseSkillDerived(self, fromBaseSkillIndex, nextBaseSkillIndex, nextBaseSkill, nextSkillConfig)
	SkillSyncLog.log(self.owner.skillName, self.skillCastId, nextBaseSkill.baseSkillInstanceId, "Server", "BaseSkillDerived", string.format("from=%d to=%d breakLast=%s", fromBaseSkillIndex, nextBaseSkillIndex, tostring(nextSkillConfig.breakLastSkill)))
	local character = GetSkillData.getCharacter(self.owner.characterType, self.owner.characterId)
	local root = character and (character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart)
	local pos = root and root.Position or (self.castInputSnapshot.releaseCF and self.castInputSnapshot.releaseCF.Position)
	SkillSyncDispatcher.dispatch(self, "Derived", derivedData, pos)

	self.deriveRequestByIndex[nextBaseSkillIndex] = nil
end

--[[
	每帧驱动：当前段检查、条件判断、下一段启动。

	@param self GroupSkillInstanceRuntime - 单次施法运行器
	@param deltaTime number - 帧间隔（秒）
	@return boolean - 已完成（可被 GroupSkillServer 移除）为 true
]]
function GroupSkillInstanceRuntime:Tick(deltaTime)
	if self._destroyed then return true end
	self.nowTime += deltaTime

	local currentBaseSkill = self.baseSkills[self.activeBaseSkillIndex]
	if not currentBaseSkill then
		return true
	end

	_tryHandleSustainButtonRelease(self, currentBaseSkill)

	local nextBaseSkillIndex = self.activeBaseSkillIndex + 1
	local nextSkillConfig = self.groupSkillModule.Skill[nextBaseSkillIndex]
	if not nextSkillConfig then
		return not currentBaseSkill:isRunningFlow()
	end

	_tryDeriveNextBaseSkill(self, currentBaseSkill, nextBaseSkillIndex, nextSkillConfig)
	return false
end

--[[
	获取当前 BaseSkill（供 ChainConditionContext 等只读访问，不暴露内部结构）。

	@param self GroupSkillInstanceRuntime - 单次施法运行器
	@return BaseSkillServer? - 当前段 BaseSkill；无则 nil
]]
function GroupSkillInstanceRuntime:GetCurrentBaseSkill()
	return self.baseSkills[self.activeBaseSkillIndex]
end

--[[
	获取当前 BaseSkill 的状态机状态名。

	@param self GroupSkillInstanceRuntime - 单次施法运行器
	@return string? - 状态名；无运行态则为 nil
]]
function GroupSkillInstanceRuntime:GetCurrentBaseSkillState()
	local current = self:GetCurrentBaseSkill()
	if not current or not current.skillRunData or not current.skillRunData.State then
		return nil
	end
	return current.skillRunData.State.current
end

--[[
	获取当前 BaseSkill 在当前状态的已运行时间。

	@param self GroupSkillInstanceRuntime - 单次施法运行器
	@return number? - 已运行秒数；无运行态则为 nil
]]
function GroupSkillInstanceRuntime:GetCurrentBaseSkillStateElapsed()
	local current = self:GetCurrentBaseSkill()
	if not current or not current.skillRunData or not current.skillRunData.State then
		return nil
	end
	local enteredAt = current.skillRunData.State.enteredAt or 0
	return current.nowTime - enteredAt
end

--[[
	获取当前 BaseSkill 从启动开始的累计时间。

	@param self GroupSkillInstanceRuntime - 单次施法运行器
	@return number? - 累计秒数；无当前段则为 nil
]]
function GroupSkillInstanceRuntime:GetCurrentBaseSkillTotalTime()
	local current = self:GetCurrentBaseSkill()
	return current and current.nowTime or nil
end

--[[
	获取当前 BaseSkill 的控制权状态。

	@param self GroupSkillInstanceRuntime - 单次施法运行器
	@return string? - "Locked" | "ChainOpen" | "Released"；无当前段或无 getControlState 则为 nil
]]
function GroupSkillInstanceRuntime:GetCurrentBaseSkillControlState()
	local current = self:GetCurrentBaseSkill()
	if not current or type(current.getControlState) ~= "function" then return nil end
	return current:getControlState()
end

--[[
	是否有派生到 index 的按键请求（限时缓冲，超时自动清除）。

	@param self GroupSkillInstanceRuntime - 单次施法运行器
	@param index number - 目标段索引
	@param maxBufferTime number? - 缓冲有效时长（秒）；nil 时默认 0.25
	@return boolean - 缓冲仍有效则为 true
]]
function GroupSkillInstanceRuntime:CheckDeriveRequest(index, maxBufferTime)
	local requestTime = self.deriveRequestByIndex and self.deriveRequestByIndex[index]
	if requestTime == nil or type(requestTime) ~= "number" then
		if self.deriveRequestByIndex and requestTime ~= nil then
			self.deriveRequestByIndex[index] = nil
		end
		return false
	end
	local bufferTime = maxBufferTime or 0.25
	if (self.nowTime - requestTime) > bufferTime then
		self.deriveRequestByIndex[index] = nil
		return false
	end
	return true
end

--[[
	指定输入是否在最近 duration 秒内发生过（避免粘住，窗口错过后旧输入不会误触发）。

	@param self GroupSkillInstanceRuntime - 单次施法运行器
	@param name string - 输入名（如 "buttonUp"）
	@param duration number - 有效窗口秒数，超过则视为过期
	@return boolean - 窗口内收到过该输入则为 true
]]
function GroupSkillInstanceRuntime:CheckInputBuffered(name, duration)
	if not self.inputBuffer or not self.inputBuffer[name] then return false end
	local receivedAt = self.inputBuffer[name]
	return (self.nowTime - receivedAt) <= duration
end

--[[
	是否有指定按键输入（兼容旧 API，默认 0.3 秒窗口）。
	@deprecated 建议用 CheckInputBuffered(name, duration) 明确时间窗口

	@param self GroupSkillInstanceRuntime - 单次施法运行器
	@param name string - 输入名
	@return boolean - 0.3 秒窗口内收到过则为 true
]]
function GroupSkillInstanceRuntime:CheckInputFlag(name)
	return self:CheckInputBuffered(name, 0.3)
end

--[[
	是否已完成（所有 BaseSkill 已结束，可被移除）。

	@param self GroupSkillInstanceRuntime - 单次施法运行器
	@return boolean - 无运行中 BaseSkill 则为 true
]]
function GroupSkillInstanceRuntime:isFinished()
	return not self:hasRunningBaseSkill()
end

--[[
	是否有运行中的 BaseSkill（含已释放控制权）。

	@param self GroupSkillInstanceRuntime - 单次施法运行器
	@return boolean - 任一 BaseSkill 仍 isRunningFlow 则为 true
]]
function GroupSkillInstanceRuntime:hasRunningBaseSkill()
	for _, baseSkill in self.baseSkills do
		if baseSkill and baseSkill:isRunningFlow() then
			return true
		end
	end
	return false
end

--[[
	应用派生输入请求。
	仅做字段级更新 castInputSnapshot，不覆盖 skillRunData（运行态数据）。

	@param self GroupSkillInstanceRuntime - 单次施法运行器
	@param inputData SkillInputData? - 增量输入；仅当携带 releaseCF/targetCF 时再钳制
	@param inputName string? - 输入名，写入 inputBuffer 时间戳
	@param nextBaseSkillIndex number? - 目标派生段索引，写入 deriveRequestByIndex
	@return nil
]]
function GroupSkillInstanceRuntime:applyInputRequest(inputData, inputName, nextBaseSkillIndex)
	if self._destroyed then return end
	if inputData then
		-- 仅当本次携带 CF 时再钳制，避免无 CF 的派生/松手请求清空位姿
		if inputData.releaseCF ~= nil or inputData.targetCF ~= nil then
			inputData = _sanitizeCastInputIfPlayer(self.owner, inputData) or inputData
		end
		self.castInputSnapshot = self.castInputSnapshot or {}
		if inputData.releaseCF ~= nil then
			self.castInputSnapshot.releaseCF = inputData.releaseCF
		end
		if inputData.targetCF ~= nil then
			self.castInputSnapshot.targetCF = inputData.targetCF
		end
		if inputData.moveDirectionStr ~= nil then
			self.castInputSnapshot.moveDirectionStr = inputData.moveDirectionStr
		end
		if inputData.trackTargetId ~= nil then
			self.castInputSnapshot.trackTargetId = inputData.trackTargetId
		end
		if inputData.skillTargetData ~= nil then
			self.castInputSnapshot.skillTargetData = inputData.skillTargetData
		end
		if inputData.approachLandWorldPos ~= nil then
			self.castInputSnapshot.approachLandWorldPos = inputData.approachLandWorldPos
		end
		if inputData.moveFaceMode ~= nil then
			self.castInputSnapshot.moveFaceMode = inputData.moveFaceMode
		end
		if inputData.moveFaceWorldPos ~= nil then
			self.castInputSnapshot.moveFaceWorldPos = inputData.moveFaceWorldPos
		end
	end
	if inputName then
		self.inputBuffer[inputName] = self.nowTime
	end
	if nextBaseSkillIndex then
		self.deriveRequestByIndex[nextBaseSkillIndex] = self.nowTime
	end
end

--[[
	释放所有仍持权的 BaseSkill 控制权（不停止状态机）。

	@param self GroupSkillInstanceRuntime - 单次施法运行器
	@return nil
]]
function GroupSkillInstanceRuntime:releaseControl()
	for _, baseSkill in self.baseSkills do
		if baseSkill and baseSkill:isRunningFlow() and not baseSkill.isControlReleased then
			baseSkill:releaseControl()
		end
	end
end

--[[
	停止所有仍在运行的 BaseSkill（Finished 语义）。

	@param self GroupSkillInstanceRuntime - 单次施法运行器
	@return nil
]]
function GroupSkillInstanceRuntime:stop()
	for _, baseSkill in self.baseSkills do
		if baseSkill and baseSkill:isRunningFlow() then
			baseSkill:stop()
		end
	end
end

--[[
	destroy 前按原因收尾仍在跑的 BaseSkill。
	Finished 走 stop，其余走 interrupt。destroy 可重入，清理后旧回调失效、不再广播。

	@param self GroupSkillInstanceRuntime - 单次施法运行器
	@param reason string? - 销毁原因；"Finished" 时 stop，其余 interrupt
	@return nil
]]
function GroupSkillInstanceRuntime:_forceFinishIfNeeded(reason)
	for _, baseSkill in self.baseSkills do
		if baseSkill and baseSkill:isRunningFlow() then
			if reason == "Finished" then
				baseSkill:stop()
			else
				baseSkill:interrupt()
			end
		end
	end
end

--[[
	清除本施法的旁观同步受众表。

	@param self GroupSkillInstanceRuntime - 单次施法运行器
	@return nil
]]
function GroupSkillInstanceRuntime:_clearAudienceTracking()
	SkillSyncRouter.clearAudience(self.skillCastId)
end

--[[
	清空派生请求与输入缓冲（跨槽打断 / destroy 共用）。

	@param self GroupSkillInstanceRuntime - 单次施法运行器
	@return nil
]]
function GroupSkillInstanceRuntime:_clearBuffers()
	self.deriveRequestByIndex = {}
	self.inputBuffer = {}
end

--[[
	销毁 runtime 及其 BaseSkill（标准清理协议，显式 finally 顺序）。

	@param self GroupSkillInstanceRuntime - 单次施法运行器
	@param reason string? - 销毁原因（StartFailed、Finished、Interrupted、Stop、Destroy 等）；nil 视为 "Destroyed"
	@return nil
]]
function GroupSkillInstanceRuntime:destroy(reason)
	if self._destroyed or self._isDestroying then return end
	self._isDestroying = true

	reason = reason or "Destroyed"
	self:_forceFinishIfNeeded(reason)

	for _, baseSkill in self.baseSkills do
		if baseSkill then
			local childReason = (reason == "Finished") and "Finished" or "Interrupted"
			baseSkill:destroy(childReason)
		end
	end

	self:_clearAudienceTracking()
	self:_clearBuffers()

	self._destroyed = true
	self._isDestroying = false
	self.baseSkills = {}
	self._chainConditionCtx = nil
	self.lifeState = LIFE_STATE.Disposed
	self.owner = nil
end

return GroupSkillInstanceRuntime
