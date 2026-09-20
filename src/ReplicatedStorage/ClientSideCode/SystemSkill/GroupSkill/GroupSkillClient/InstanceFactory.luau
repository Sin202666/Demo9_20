--[[
	Module: GroupSkillClient.InstanceFactory
	Description: 服务端确认后建实例、CombatWorld tick、实例删除（由 GroupSkillClient/init 挂载，业务勿直接 require）
	Author: 林奥宇
	Created: 2026-08-18
	Last Modified: 2026-08-18

	功能：
	- _createInstanceFromServerData：soft-merge 快照/素材 handoff、跳过 FixSkillTime、创建 InstanceRuntime
	- createInstanceFromServerStart / applyDerivedToInstance
	- _removeSkillInstance：instanceMap 与 runningBaseSkillInstances 同步清理

	与 PresentationPredict / Input：
	- 业务只调 GroupSkillClient 实例方法
	- GroupSkillClientInstanceRuntime 仍在 GroupSkill/ 下，本模块不搬它
	- ENABLE_DERIVE_SUPPRESS_AFTER_CROSS_INTERRUPT 由 init 传入，只定义一处
	- start 失败会清 pending merge 与 sustain 等待标志
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Class = require(game.ReplicatedFirst.AllSideCode.Class.Class)
local GroupSkillClientInstanceRuntime = require(script.Parent.Parent.GroupSkillClientInstanceRuntime)

local SkillSyncLog = Utils.SkillSyncLog
local CombatWorld = Utils.CombatWorld
local LocalPlayer = Utils.LocalPlayer

type GroupSkillClient = typeof(Class.GroupSkillClient)

--[[
	挂载实例工厂 API 到 GroupSkillClient 类表。
	@param GroupSkillClient table - 与 init 同一份类表
	@param ENABLE_DERIVE_SUPPRESS_AFTER_CROSS_INTERRUPT boolean - 跨槽打断后禁派生（与 init / Input 同值）
	@return () - 无返回值
]]
return function(GroupSkillClient, ENABLE_DERIVE_SUPPRESS_AFTER_CROSS_INTERRUPT)
	--[[
	    私有：由服务端数据创建实例（createInstanceFromServerStart 唯一调用）
	    @param data BaseSkillStarted payload（含 skillCastId, characterId, characterType, releaseCF, targetCF, moveDirectionStr 等）
	]]
	function GroupSkillClient._createInstanceFromServerData(self: GroupSkillClient, data: any)
		local castId = data.skillCastId
		if not castId then return end
		if self.instanceMap[castId] then return end

		local softMergeSnap = self:_takePresentationPredictSoftMergeSnapshot(castId)
		local p = self._presentationPredict
		local animHandoff = p
			and p.client
			and softMergeSnap
			and type(softMergeSnap.nowTime) == "number"
			and softMergeSnap.nowTime > 1e-4
			and p.client:isRunningFlow()
		self._pendingSoftMergeRunData = nil
		if animHandoff then
			p.client._presentationPredictAnimHandoff = true
			-- 移交素材/淡出/烟尘连接，避免销毁预测时 BackPool 或断连导致 FX 断、正式段又重开
			local rd = p.client.skillRunData
			if type(rd) == "table" then
				self._pendingSoftMergeRunData = {
					material = rd.material,
					FadeCharacter = rd["FadeCharacter"],
					runEvent = rd.runEvent,
					_fxFired = rd._fxFired,
					_rollingFxDirection = rd._rollingFxDirection,
					-- 兼容旧字段：任一 FX 已触发则视为 started
					_rollingFxStarted = rd._rollingFxStarted == true
						or (type(rd._fxFired) == "table" and next(rd._fxFired) ~= nil),
				}
				-- 先释放预测段 FX 所有权，再清空引用，避免 handoff 窗内残留 delay 误 claim
				rd._fxOwnershipReleased = true
				rd.material = {}
				rd["FadeCharacter"] = nil
				rd.runEvent = {}
				rd._fxFired = nil
				rd._rollingFxDirection = nil
				rd._rollingFxStarted = nil
				rd._rollingFxTimelineArmed = nil
				p.client._presentationPredictMaterialHandoff = true
			end
		end
		-- 正式表现开始前结束预测（避免双实例叠轨）；软合并快照已取出；handoff 时 Action 不拆物理/动画
		self:clearPresentationPredict()
		self._pendingSoftMergeSnapshot = softMergeSnap
		self._pendingSoftMergeAnimHandoffForNextRuntime = animHandoff == true
		if softMergeSnap then
			-- soft-merge 已对齐本地时钟，本 cast 跳过随后的 FixSkillTime
			self._skipFixSkillTimeForCastId = castId
		end

		SkillSyncLog.log(self.skillName, castId, data.baseSkillInstanceId or (castId .. "_B1"), "Client", "InstanceCreated", "")

		-- 本地玩家 CD 由服务端「技能CD时间戳」复制到客户端，不在此维护内存倒计时
		if not (self.characterType == "Player" and self.characterId == LocalPlayer.UserId) then
			self.groupSkillCooldownRemaining = self.groupSkillCooldown
		end
		if data.combatSeed then self.combatSeed = data.combatSeed end
		if data.skillPower then self.skillPower = data.skillPower end
		if data.skillPurity then self.skillPurity = data.skillPurity end
		if type(data.mpTp) == "string" and data.mpTp ~= "" then
			self.mpTp = data.mpTp
		end

		local runtime = GroupSkillClientInstanceRuntime.new(self, castId, data)
		table.insert(self.runningBaseSkillInstances, runtime)
		self.instanceMap[castId] = runtime
		self.lastDerivableSkillCastId = castId

		if not self.groupSkillRuntimeEvent then
			local tickId = CombatWorld.allocId("GroupSkillRuntime")
			self._runtimeTickId = tickId
			self.groupSkillRuntimeEvent = CombatWorld.register(tickId, function(deltaTime)
				local toRemove = {}
				for cid, rt in pairs(self.instanceMap) do
					if rt:Tick(deltaTime) then
						table.insert(toRemove, cid)
					end
				end
				for _, cid in ipairs(toRemove) do
					self:_removeSkillInstance(cid)
				end
				local hasRunningBaseSkill = false
				for _, rt in pairs(self.instanceMap) do
					for _, baseSkill in rt.baseSkills do
						if baseSkill and baseSkill:isRunningFlow() then hasRunningBaseSkill = true break end
					end
					if hasRunningBaseSkill then break end
				end
				local hasActiveBaseSkill = false
				for _, rt in pairs(self.instanceMap) do
					for _, baseSkill in rt.baseSkills do
						if baseSkill and baseSkill:isRunningFlow() and not baseSkill.isControlReleased then hasActiveBaseSkill = true break end
					end
					if hasActiveBaseSkill then break end
				end
				if not hasRunningBaseSkill then
					if ENABLE_DERIVE_SUPPRESS_AFTER_CROSS_INTERRUPT and self.deriveSuppressedAfterCrossInterrupt and next(self.instanceMap) == nil then
						self.deriveSuppressedAfterCrossInterrupt = false
					end
					if self.groupSkillRuntimeEvent then
						self.groupSkillRuntimeEvent:Disconnect()
						self.groupSkillRuntimeEvent = nil
						self._runtimeTickId = nil
					end
				end
			end, CombatWorld.Phase.SkillRuntime)
		end

		if not runtime:start() then
			self._pendingSoftMergeSnapshot = nil
			self._pendingSoftMergeRunData = nil
			self._skipFixSkillTimeForCastId = nil
			self._sustainAwaitingFirstInstanceFromReleaseRequest = false
			self._pendingEarlyButtonUpForSustainHold = false
			self:_removeSkillInstance(castId)
			return
		end

		self._sustainAwaitingFirstInstanceFromReleaseRequest = false
		if self._pendingEarlyButtonUpForSustainHold then
			self._pendingEarlyButtonUpForSustainHold = false
			self:_applyLocalSustainHoldButtonRelease()
		end
	end

	--[[
	    由服务端 BaseSkillStarted 消息驱动创建实例（服务端确认驱动，统一表现入口）
	    @param self: GroupSkillClient 组技能客户端对象
	    @param data: SynSkillEffectData BaseSkillStarted  payload
	]]
	function GroupSkillClient.createInstanceFromServerStart(self: GroupSkillClient, data: any)
		self:_createInstanceFromServerData(data)
	end

	--[[
	    应用派生确认（BaseSkillDerived）到指定实例
	    由 PlayerSkillClientManager 等路由 SynSkillEffect 时调用
	]]
	function GroupSkillClient.applyDerivedToInstance(self: GroupSkillClient, skillCastId: string, data: any)
		if ENABLE_DERIVE_SUPPRESS_AFTER_CROSS_INTERRUPT and self.deriveSuppressedAfterCrossInterrupt then
			return
		end
		local runtime = self.instanceMap[skillCastId]
		if runtime and runtime.applyDerived then
			runtime:applyDerived(data)
		end
	end

	--【P2】实例删除唯一入口：instanceMap 与 runningBaseSkillInstances 必须同步清理，禁止其他路径直接修改
	-- @param immediate boolean? true=立即回收素材（destroy 时）；false/nil=尊重 visualFadeoutTime
	function GroupSkillClient._removeSkillInstance(self: GroupSkillClient, skillCastId: string, immediate: boolean?)
		local runtime = self.instanceMap[skillCastId]
		if not runtime then return end
		if runtime.destroy then runtime:destroy(immediate) end
		self.instanceMap[skillCastId] = nil
		if self.lastDerivableSkillCastId == skillCastId then
			self.lastDerivableSkillCastId = nil
		end
		for i = #self.runningBaseSkillInstances, 1, -1 do
			if self.runningBaseSkillInstances[i] == runtime then
				table.remove(self.runningBaseSkillInstances, i)
				break
			end
		end
	end
end
