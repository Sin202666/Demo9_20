--[[
	单次施法客户端实例运行器（轻量）
	每个 castId 独立 runtime，负责：当前 base skill index、表现态、本地时间对齐、特效引用、结束/清理
	GroupSkillClient 仅负责：创建 runtime、路由同步事件、回收 runtime
]]
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local RunService = Utils.RunService
local FXUtil = Utils.FXUtil
local BaseSkillClientModule = require(script.Parent.Parent.BaseSkill.BaseSkillClient)
local SkillEventConst = require(script.Parent.Parent.BaseSkill.SkillEventConst)

local GroupSkillClientInstanceRuntime = {}
GroupSkillClientInstanceRuntime.__index = GroupSkillClientInstanceRuntime

-- 表现态：Casting（有 BaseSkill 持有控制权）| Recovering（已释放，等待自然结束）| Finished
local DISPLAY_STATE = {
	Casting = "Casting",
	Recovering = "Recovering",
	Finished = "Finished",
}

--[[
	创建单次施法客户端实例运行器
	@param owner GroupSkillClient 组技能客户端对象
	@param skillCastId string 施法 ID
	@param data table BaseSkillStarted payload（releaseCF, targetCF, moveDirectionStr, characterId, characterType, combatSeed 等）
	@return GroupSkillClientInstanceRuntime
]]
function GroupSkillClientInstanceRuntime.new(owner, skillCastId, data)
	local self = setmetatable({}, GroupSkillClientInstanceRuntime)
	self.owner = owner
	self.skillCastId = skillCastId
	self.groupSkillModule = owner.groupSkillModule
	self._destroyed = false
	self._isDestroying = false
	self._destroyGeneration = 0

	-- 当前段索引、表现态、时间
	self.activeBaseSkillIndex = 1
	self.baseSkillIndex = 1 -- 兼容 PlayerSkillClientManager 等，与 activeBaseSkillIndex 同步
	self.currentState = DISPLAY_STATE.Casting
	self.startTime = 0
	self.lastSyncTime = 0
	self.nowTime = 0

	-- 特效对象引用（技能模块可挂载，清理时统一回收）
	self.activeEffects = {}

	-- 创建时是否为首段动画 handoff（owner 上的 pending 在 new 末尾会清空，start 时读此字段）
	self._softMergeHadAnimHandoff = false

	-- 是否已结束（可回收）
	self.isFinished = false

	-- BaseSkill 实例
	self.baseSkills = {}
	self.baseSkillMap = {}
	self.completedBaseSkillIndex = {}
	self.deriveRequestByIndex = {}
	self.inputBuffer = {}
	self.skillInputData = {
		releaseCF = data.releaseCF,
		targetCF = data.targetCF,
		moveDirectionStr = data.moveDirectionStr,
		trackTargetId = data.trackTargetId,
		skillTargetData = data.skillTargetData,
		moveFaceMode = data.moveFaceMode,
		moveFaceWorldPos = data.moveFaceWorldPos,
		approachLandWorldPos = data.approachLandWorldPos,
		multThunderPathPoints = data.multThunderPathPoints,
		multThunderPathPacked = data.multThunderPathPacked,
		multThunderSpawnGround = data.multThunderSpawnGround,
	}

	local characterId = data.characterId or owner.characterId
	local characterType = data.characterType or owner.characterType

	local skipAnimPreload = owner._pendingSoftMergeAnimHandoffForNextRuntime == true
	self._softMergeHadAnimHandoff = skipAnimPreload
	for index, baseSkillConfig in owner.groupSkillModule.Skill do
		local createOpts: any = {}
		if index == 1 and skipAnimPreload then
			createOpts.skipAnimationCreatePreload = true
		end
		if owner.skillID then
			createOpts.skillID = owner.skillID
		end
		if type(owner.mpTp) == "string" and owner.mpTp ~= "" then
			createOpts.mpTp = owner.mpTp
		end

		local newBaseSkill = BaseSkillClientModule.new(
			baseSkillConfig.baseSkillName,
			characterId,
			characterType,
			owner.skillPower,
			owner.skillPurity,
			createOpts
		)
		newBaseSkill.combatSeed = data.combatSeed or owner.combatSeed
		newBaseSkill.skillCastId = skillCastId
		newBaseSkill.baseSkillInstanceId = skillCastId .. "_B" .. tostring(index)
		self.baseSkills[index] = newBaseSkill
		self.baseSkillMap[newBaseSkill.baseSkillInstanceId] = newBaseSkill
	end
	owner._pendingSoftMergeAnimHandoffForNextRuntime = nil

	return self
end

--[[
	每帧驱动：时间推进、表现态更新、结束检测
	@param deltaTime number
	@return boolean 是否已结束（可回收）
]]
function GroupSkillClientInstanceRuntime:Tick(deltaTime)
	if self._destroyed or self._isDestroying or self.isFinished then return true end

	self.nowTime += deltaTime

	local currentBaseSkill = self.baseSkills[self.activeBaseSkillIndex]
	if not currentBaseSkill then
		self.isFinished = true
		self.currentState = DISPLAY_STATE.Finished
		return true
	end

	if currentBaseSkill:isRunningFlow()
		and self.groupSkillModule
		and self.groupSkillModule.Data
		and self.groupSkillModule.Data.sustainActiveUntilSkillButtonRelease == true
		and self.inputBuffer
		and self.inputBuffer["buttonUp"] ~= nil
	then
		if currentBaseSkill:TryTransition(SkillEventConst.SkillButtonRelease) then
			self.inputBuffer["buttonUp"] = nil
		end
	end

	local nextBaseSkillIndex = self.activeBaseSkillIndex + 1
	local nextSkillConfig = self.groupSkillModule.Skill[nextBaseSkillIndex]
	if not nextSkillConfig and not currentBaseSkill:isRunningFlow() then
		self.isFinished = true
		self.currentState = DISPLAY_STATE.Finished
		return true
	end

	-- 更新表现态：有运行中且未释放控制权为 Casting，否则 Recovering
	local hasActiveControl = false
	for _, bs in self.baseSkills do
		if bs and bs:isRunningFlow() and not bs.isControlReleased then
			hasActiveControl = true
			break
		end
	end
	self.currentState = hasActiveControl and DISPLAY_STATE.Casting or DISPLAY_STATE.Recovering

	return false
end

--[[
	启动第一个 BaseSkill
]]
function GroupSkillClientInstanceRuntime:start()
	if self._destroyed then return false end
	local firstBaseSkill = self.baseSkills[1]
	if not firstBaseSkill then return false end

	local instData = self.skillInputData
	local owner = self.owner
	firstBaseSkill:setSkillInputData(
		owner.characterId,
		owner.characterType,
		instData.releaseCF,
		instData.targetCF,
		instData.moveDirectionStr,
		self.skillCastId,
		firstBaseSkill.baseSkillInstanceId,
		1,
		instData.trackTargetId,
		instData.skillTargetData
	)
	-- 多重雷跃同步字段：仅当项目带有 MultThunderTrample1 时应用（框架可不带该技能）
	local sid = firstBaseSkill.skillInputData
	if sid then
		local skillModuleFolder = script.Parent.Parent:FindFirstChild("SkillModule")
		local mttFolder = skillModuleFolder and skillModuleFolder:FindFirstChild("MultThunderTrample1")
		local pathMod = mttFolder and mttFolder:FindFirstChild("MultThunderTramplePath")
		if pathMod then
			local ok, MultThunderTramplePath = pcall(require, pathMod)
			if ok and MultThunderTramplePath and MultThunderTramplePath.applySyncFieldsToSkillInputData then
				MultThunderTramplePath.applySyncFieldsToSkillInputData(sid, instData)
			end
		end
	end
	local merge = owner._pendingSoftMergeSnapshot
	local mergeRunData = owner._pendingSoftMergeRunData
	owner._pendingSoftMergeSnapshot = nil
	owner._pendingSoftMergeRunData = nil
	if merge and type(merge.nowTime) == "number" and merge.nowTime > 1e-4 and type(merge.state) == "string" then
		if self._softMergeHadAnimHandoff then
			-- 续跑：不重播目标态 OnEnter（素材已移交）
			firstBaseSkill._softMergeSkipEnterHandlers = true
		end
		firstBaseSkill:skillStart({
			softMerge = {
				nowTime = merge.nowTime,
				state = merge.state,
				enteredAt = merge.enteredAt,
			},
			softMergeRunData = mergeRunData,
		})
	else
		-- 无 handoff：若仍残留移交包则回收，避免泄漏
		if type(mergeRunData) == "table" and type(mergeRunData.material) == "table" then
			for _, model in pairs(mergeRunData.material) do
				if model then
					pcall(function()
						FXUtil.BackPool_Instance(model)
					end)
				end
			end
		end
		firstBaseSkill:skillStart()
	end
	return true
end

--[[
	应用派生确认（BaseSkillDerived）
	@param data table 含 fromBaseSkillIndex, toBaseSkillIndex, breakLastSkill, releaseCF, targetCF, moveDirectionStr, baseSkillInstanceId
]]
function GroupSkillClientInstanceRuntime:applyDerived(data)
	if self._destroyed then return end
	local fromIndex = data.fromBaseSkillIndex
	local toIndex = data.toBaseSkillIndex
	if not fromIndex or not toIndex then return end

	local prevBaseSkill = self.baseSkills[fromIndex]
	local nextBaseSkill = self.baseSkills[toIndex]
	if prevBaseSkill and prevBaseSkill:isRunningFlow() then
		if data.breakLastSkill then
			prevBaseSkill:skillEnd()
		else
			prevBaseSkill.skillAction:Over(prevBaseSkill.nowTime)
		end
	end
	table.insert(self.completedBaseSkillIndex, fromIndex)
	self.activeBaseSkillIndex = toIndex
	self.baseSkillIndex = toIndex -- 兼容层，与 activeBaseSkillIndex 同步

	if data.trackTargetId ~= nil then self.skillInputData.trackTargetId = data.trackTargetId end
	if data.skillTargetData ~= nil then self.skillInputData.skillTargetData = data.skillTargetData end

	if nextBaseSkill and not nextBaseSkill:isRunningFlow() then
		local owner = self.owner
		nextBaseSkill:setSkillInputData(
			owner.characterId,
			owner.characterType,
			data.releaseCF,
			data.targetCF,
			data.moveDirectionStr,
			data.skillCastId or self.skillCastId,
			data.baseSkillInstanceId or nextBaseSkill.baseSkillInstanceId,
			data.activeBaseSkillIndex or toIndex,
			data.trackTargetId or self.skillInputData.trackTargetId,
			data.skillTargetData or self.skillInputData.skillTargetData
		)
		nextBaseSkill:skillStart()
	end
end

--[[
	时间轴对齐（fixSkillTime）
	@param serverTime number
]]
function GroupSkillClientInstanceRuntime:fixTime(serverTime)
	if self._destroyed then return end
	local deltaTime = (workspace:GetServerTimeNow() - serverTime) - self.nowTime
	local currentBaseSkill = self.baseSkills[self.activeBaseSkillIndex]
	if currentBaseSkill then
		currentBaseSkill:setSkillTimeFix(deltaTime)
	end
	self.lastSyncTime = self.nowTime
end

--[[
	释放本实例所有 BaseSkill 控制权
]]
function GroupSkillClientInstanceRuntime:releaseControl()
	for _, baseSkill in self.baseSkills do
		if baseSkill and baseSkill:isRunningFlow() and not baseSkill.isControlReleased then
			baseSkill:releaseControl()
		end
	end
end

--[[
	精准停止指定 BaseSkill
	@param baseSkillInstanceId string
	@param reason string?
	@return boolean 本实例是否已无运行中 BaseSkill（可回收）
]]
function GroupSkillClientInstanceRuntime:stopBaseSkill(baseSkillInstanceId, reason)
	local baseSkill = self.baseSkillMap and self.baseSkillMap[baseSkillInstanceId]
	if baseSkill and baseSkill:isRunningFlow() then
		baseSkill:skillEnd(nil, reason)
	end

	local hasRunning = false
	for _, bs in self.baseSkills do
		if bs and bs:isRunningFlow() then hasRunning = true break end
	end
	return not hasRunning
end

-- 标准清理协议：destroy 可重入，清理后旧回调失效、不再广播、buffer 清空
function GroupSkillClientInstanceRuntime:_forceFinishIfNeeded(immediate)
	local gen = self._destroyGeneration
	for _, baseSkill in self.baseSkills do
		if baseSkill then
			if immediate then
				baseSkill:destroy("Interrupted", true)
			else
				if baseSkill:isRunningFlow() then
					baseSkill:skillEnd(nil, baseSkill.flowState or "Finished")
				end
				local fadeoutTime = (baseSkill.skillModule and baseSkill.skillModule.visualFadeoutTime) or 0
				local reason = baseSkill.flowState or "Finished"
				local capturedBaseSkill = baseSkill
				task.delay(fadeoutTime, function()
					if self._destroyGeneration ~= gen then return end
					capturedBaseSkill:destroy(reason, true)
				end)
			end
		end
	end
end

function GroupSkillClientInstanceRuntime:_clearBuffers()
	self.deriveRequestByIndex = {}
	self.inputBuffer = {}
end

--[[
	销毁 runtime（标准清理协议，两阶段与 BaseSkillClient 对称）
	@param immediate boolean? true=立即回收素材（GroupSkillClient destroy 时）；false/nil=尊重 visualFadeoutTime 延迟回收
]]
function GroupSkillClientInstanceRuntime:destroy(immediate)
	if self._destroyed or self._isDestroying then return end
	self._isDestroying = true
	self._destroyGeneration = (self._destroyGeneration or 0) + 1

	self.isFinished = true
	self.currentState = DISPLAY_STATE.Finished
	self:_forceFinishIfNeeded(immediate)
	self:_clearBuffers()

	self._destroyed = true
	self._isDestroying = false
	self.baseSkills = {}
	self.baseSkillMap = {}
	self.activeEffects = {}
	self.owner = nil
end

return GroupSkillClientInstanceRuntime
