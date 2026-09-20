--[[
	Module: GroupSkillClient.Input
	Description: 组技能按键、派生请求与 sustain 松手（由 GroupSkillClient/init 挂载，业务勿直接 require）
	Author: 林奥宇
	Created: 2026-08-18
	Last Modified: 2026-08-18

	功能：
	- updateSkillInput：releaseCF / targetCF / 移动方向 / 自瞄 trackTargetId
	- onInputBegan：派生 FireServer 或新释 + clientPredictCastId + 表现预测
	- onInputEnded / _applyLocalSustainHoldButtonRelease：sustain 松手与早到补发
	- onInputRequest：Phase1 未完成时写入 runtime inputBuffer / deriveRequest

	与 init / PresentationPredict：
	- 业务只调 GroupSkillClient 实例方法
	- ENABLE_DERIVE_SUPPRESS_AFTER_CROSS_INTERRUPT 由 init 传入，与 Factory 同一份
	- requestRelease 空壳仍在 init，不在此恢复创建逻辑
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Class = require(game.ReplicatedFirst.AllSideCode.Class.Class)
local GetSkillData = require(script.Parent.Parent.Parent.BaseSkill.GetSkillData)
local ProjectileObjectTracking = require(script.Parent.Parent.Parent.SkillModule._Templates.Projectile.ProjectileObjectTracking)

local GetData = Utils.GetData
local DeviceType = Utils.DeviceType
local HumanModule = Utils.HumanModule
local LocalPlayer = Utils.LocalPlayer
local SkillNet = Utils.SkillNet
local ReleaseGroupSkill = SkillNet.ReleaseGroupSkill --释放组技能事件

type GroupSkillClient = typeof(Class.GroupSkillClient)

--[[
	挂载输入 API 到 GroupSkillClient 类表。
	@param GroupSkillClient table - 与 init 同一份类表
	@param ENABLE_DERIVE_SUPPRESS_AFTER_CROSS_INTERRUPT boolean - 跨槽打断后禁派生（与 init / Factory 同值）
	@return () - 无返回值
]]
return function(GroupSkillClient, ENABLE_DERIVE_SUPPRESS_AFTER_CROSS_INTERRUPT)
	--[[
	    更新技能输入
	    @param self: GroupSkillClient 组技能客户端对象
	    @param releaseCF: CFrame 释放位置
	    @param targetCF: CFrame 目标位置
	]]
	function GroupSkillClient.updateSkillInput(self: GroupSkillClient, releaseCF: CFrame, targetCF: CFrame)

		-- 计算移动方向字符串
		local character = GetSkillData.getCharacter(self.characterType, self.characterId)
		local moveDirectionStr = GetSkillData.getCharacterDirectionStr(character)
		local trackTargetId = nil
		if self.characterType == "Player" and self.characterId == LocalPlayer.UserId then
			--如果玩家开启ShiftLock则不进行赋值
			if (not HumanModule.GetIsShiftLocked() or DeviceType.IsGamepad()) and GetData.GetSetting(LocalPlayer,"AILock")==1 then
				trackTargetId = ProjectileObjectTracking.getTrackTargetIdForSkillInput()
			end

		end

		--更新技能输入数据（skillPower 为固定属性，仅注册时传入，不在此更新）
		self.skillInputData = {
			characterId = self.characterId,
			characterType = self.characterType,
			skillName = nil,  -- 组技能不需要 skillName
			releaseCF = releaseCF,
			targetCF = targetCF,
			-- 不再上传 seed，combatSeed 由服务端权威生成并同步
			moveDirectionStr = moveDirectionStr,  -- 包含移动方向字符串
			trackTargetId = trackTargetId,
		}

	end

	--[[
	    玩家按下技能键
	    如果技能正在运行 更新玩家输入请求 （用于技能派生）
	    如果技能不在运行 则开始技能
	    @param self: GroupSkillClient 组技能客户端对象
	    @param input: InputObject 输入对象
	]]
	function GroupSkillClient.onInputBegan(self: GroupSkillClient)

		--判断冷却是否合法（只有在新技能释放时才检查，技能派生不受冷却时间限制）
		--Phase 1 未完成时为派生模式，Phase 1 全部完成且冷却结束时方可再次释放

		if self:shouldBypassCooldownForLocalPress() then
			self:onInputRequest("buttonDown", true)
			--【P0】仅发送请求，禁止本地派生；派生由服务端 BaseSkillDerived 驱动
			--【P2】携带 skillCastId 绑定派生目标，避免“最近实例”边界歧义
			local deriveData = {
				releaseCF = self.skillInputData.releaseCF,
				targetCF = self.skillInputData.targetCF,
				moveDirectionStr = self.skillInputData.moveDirectionStr,
				trackTargetId = self.skillInputData.trackTargetId,
				skillCastId = self.lastDerivableSkillCastId,
			}
			ReleaseGroupSkill:FireServer(self.slotIndex, deriveData)
			return
		end

		--Phase 1 已全部完成，可释放新技能（需检查冷却；本地玩家以「技能CD时间戳」为准）
		if self:isCooldownActiveByTimestamp() then
			return
		end

		--保存本次请求的数据，供服务器确认后使用（避免 InputEnded 覆盖 skillInputData）
		self.pendingReleaseData = {
			releaseCF = self.skillInputData.releaseCF,
			targetCF = self.skillInputData.targetCF,
			moveDirectionStr = self.skillInputData.moveDirectionStr,
			trackTargetId = self.skillInputData.trackTargetId,
		}
		--【P0 架构】仅发送请求，禁止本地创建实例；实例创建由 SynSkillEffect BaseSkillStarted 统一驱动
		-- 一期表现预测：携带 clientPredictCastId，与服务端 skillCastId 对齐
		local HttpService = Utils.HttpService
		local clientPredictCastId = HttpService:GenerateGUID(false)
		local releasePayload = {
			characterId = self.skillInputData.characterId,
			characterType = self.skillInputData.characterType,
			skillName = self.skillInputData.skillName,
			releaseCF = self.skillInputData.releaseCF,
			targetCF = self.skillInputData.targetCF,
			moveDirectionStr = self.skillInputData.moveDirectionStr,
			trackTargetId = self.skillInputData.trackTargetId,
			clientPredictCastId = clientPredictCastId,
		}
		self._lastPresentationPredictCastId = clientPredictCastId
		self._presentationPredictStartClock = os.clock()
		ReleaseGroupSkill:FireServer(self.slotIndex, releasePayload)
		self:_tryStartPresentationPredict(clientPredictCastId, self.pendingReleaseData)
		local sustainHold = self.groupSkillModule.Data and self.groupSkillModule.Data.sustainActiveUntilSkillButtonRelease == true
		if sustainHold and self.characterType == "Player" and self.characterId == LocalPlayer.UserId then
			self._sustainAwaitingFirstInstanceFromReleaseRequest = true
			self._pendingEarlyButtonUpForSustainHold = false
		end
	end

	--[[
	    本地：Phase1 已就绪时写入 buttonUp 并同步 sustain 松手（与 onInputEnded / 早到松手补发共用）
	]]
	function GroupSkillClient._applyLocalSustainHoldButtonRelease(self: GroupSkillClient)
		if self:hasPhase1Incomplete() then
			self:onInputRequest("buttonUp", false)
		end
		local sustainHold = self.groupSkillModule.Data and self.groupSkillModule.Data.sustainActiveUntilSkillButtonRelease == true
		if sustainHold and self.characterType == "Player" and self.characterId == LocalPlayer.UserId then
			local castId = self.lastDerivableSkillCastId
			if self:hasPhase1Incomplete() and castId then
				ReleaseGroupSkill:FireServer(self.slotIndex, {
					characterId = self.skillInputData.characterId,
					characterType = self.skillInputData.characterType,
					skillCastId = castId,
					skillButtonPhase = "up",
					releaseCF = self.skillInputData.releaseCF,
					targetCF = self.skillInputData.targetCF,
					moveDirectionStr = self.skillInputData.moveDirectionStr,
					trackTargetId = self.skillInputData.trackTargetId,
				})
			end
		end
	end

	--[[
	    玩家松开技能键
	    如果技能正在运行 更新玩家输入请求 （用于技能派生）
	    @param self: GroupSkillClient 组技能客户端对象
	    @param input: InputObject 输入对象
	]]
	function GroupSkillClient.onInputEnded(self: GroupSkillClient)
		local sustainHold = self.groupSkillModule.Data and self.groupSkillModule.Data.sustainActiveUntilSkillButtonRelease == true
		local localPlr = self.characterType == "Player" and self.characterId == LocalPlayer.UserId
		if sustainHold and localPlr and not self:hasPhase1Incomplete() and self._sustainAwaitingFirstInstanceFromReleaseRequest then
			self._pendingEarlyButtonUpForSustainHold = true
		end
		self:_applyLocalSustainHoldButtonRelease()
	end

	--[[
	    处理按键输入请求（用于技能派生）
	    @param self: GroupSkillClient 组技能客户端对象
	    @param releaseCF: CFrame? 新的施法位置（可选，如果提供则更新）
	    @param targetCF: CFrame? 新的目标位置（可选，如果提供则更新）
	]]
	function GroupSkillClient.onInputRequest(self: GroupSkillClient, inputName: string, isderive:boolean)
		if ENABLE_DERIVE_SUPPRESS_AFTER_CROSS_INTERRUPT and self.deriveSuppressedAfterCrossInterrupt then
			return
		end
		if self:hasPhase1Incomplete() then
			local runtimesToUpdate = {}
			if self.lastDerivableSkillCastId then
				local rt = self.instanceMap[self.lastDerivableSkillCastId]
				if rt then table.insert(runtimesToUpdate, rt) end
			end
			if #runtimesToUpdate == 0 then
				for _, rt in pairs(self.instanceMap) do
					table.insert(runtimesToUpdate, rt)
				end
			end
			for _, runtime in ipairs(runtimesToUpdate) do
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
					runtime.inputBuffer = runtime.inputBuffer or {}
					runtime.inputBuffer[inputName] = runtime.nowTime
					if isderive and nextSkillConfig then
						runtime.deriveRequestByIndex[nextBaseSkillIndex] = runtime.nowTime
					end
				end
			end
		end
	end
end
