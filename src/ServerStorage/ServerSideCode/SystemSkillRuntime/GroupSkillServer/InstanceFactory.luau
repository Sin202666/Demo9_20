--[[
	Module: GroupSkillServer.InstanceFactory
	Description: 释法建实例、CombatWorld tick、runtime 注册/销毁（由 GroupSkillServer/init 挂载，业务勿直接 require）
	Author: 林奥宇
	Created: 2026-08-18
	Last Modified: 2026-08-31

	功能：
	- _registerRuntime / _unregisterRuntime / _disposeRuntime / _removeSkillInstance
	- requestRelease：CD 校验、clientPredictCastId、创建 GroupSkillInstanceRuntime、启动 tick

	与 init / Cooldown / Input：
	- GroupSkillInstanceRuntime 与本 façade 同在 SystemSkillRuntime
	- ENABLE_DERIVE_SUPPRESS_AFTER_CROSS_INTERRUPT 由 init 传入
	- 冷却辅助走 Cooldown（与 init 同一份）
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Class = require(game.ReplicatedFirst.AllSideCode.Class.Class)
local GroupSkillInstanceRuntime = require(script.Parent.Parent.GroupSkillInstanceRuntime)
local SkillReleaseCrossCheck = require(script.Parent.Parent.SkillReleaseCrossCheck)
local Cooldown = require(script.Parent.Cooldown)

local SkillSyncLog = Utils.SkillSyncLog
local Players = Utils.Players
local SkillBuffUtil = Utils.SkillBuffUtil
local CombatWorld = Utils.CombatWorld
local SkillNet = Utils.SkillNet
local ReleaseGroupSkill = SkillNet.ReleaseGroupSkill --释放组技能事件
local FixSkillTime = SkillNet.FixSkillTime --技能时间轴对齐事件

type GroupSkillServer = typeof(Class.GroupSkillServer)
type SkillInputData = typeof(Class.SkillInputData)

--[[
	挂载实例工厂 API 到 GroupSkillServer 类表。
	@param GroupSkillServer table - 与 init 同一份类表
	@param ENABLE_DERIVE_SUPPRESS_AFTER_CROSS_INTERRUPT boolean - 跨槽打断后禁派生
	@return () - 无返回值
]]
return function(GroupSkillServer, ENABLE_DERIVE_SUPPRESS_AFTER_CROSS_INTERRUPT)
	--[[
		注册 runtime（列表 + 双 map）。

		@param self GroupSkillServer - 组技能服实例
		@param runtime GroupSkillInstanceRuntime - 刚创建的单次施法运行器
		@return nil
	]]
	function GroupSkillServer:_registerRuntime(runtime)
		table.insert(self.runningRuntimeList, runtime)
		self.runtimeByCastId[runtime.skillCastId] = runtime
		for _, baseSkill in runtime.baseSkills do
			if baseSkill and baseSkill.baseSkillInstanceId then
				self.runtimeByInstanceId[baseSkill.baseSkillInstanceId] = runtime
			end
		end
	end

	--[[
		反注册 runtime（从列表与双 map 移除，不销毁）。

		@param self GroupSkillServer - 组技能服实例
		@param runtime GroupSkillInstanceRuntime - 待移除的运行器
		@return nil
	]]
	function GroupSkillServer:_unregisterRuntime(runtime)
		self.runtimeByCastId[runtime.skillCastId] = nil
		for _, baseSkill in runtime.baseSkills do
			if baseSkill and baseSkill.baseSkillInstanceId then
				self.runtimeByInstanceId[baseSkill.baseSkillInstanceId] = nil
			end
		end
		for i, item in ipairs(self.runningRuntimeList) do
			if item == runtime then
				table.remove(self.runningRuntimeList, i)
				break
			end
		end
	end

	--[[
		销毁并反注册 runtime（先反注册再销毁，避免 destroy 清空 baseSkills 后无法从 map 移除）

		策略：reason 决定收尾语义，runtime:destroy(reason) 内部会：
		- reason == "Finished"：对运行中 BaseSkill 先 stop() 再 destroy()
		- 其他（StartFailed、Destroy、Stop、Interrupted）：先 interrupt() 再 destroy()
		- 每个 BaseSkill 的 interrupt/stop 会 _finish → broadcastStopTrackedAndClear → 客户端收到 StopSkill
		- 最终每个 BaseSkill 完整 stop/interrupt + stop sync + cleanup，无幽灵实例

		@param self GroupSkillServer - 组技能服实例
		@param runtime GroupSkillInstanceRuntime? - 待销毁的运行器；nil 则直接返回
		@param reason string - 销毁原因（Finished / StartFailed / Destroy / Stop / Interrupted）
		@return nil
	]]
	function GroupSkillServer:_disposeRuntime(runtime, reason)
		if not runtime then return end
		self:_unregisterRuntime(runtime)
		runtime:destroy(reason)
	end

	--[[
	    移除技能实例（内部方法）
	    当前策略：悬空自然结束——仅移除实例记录，不主动 stop BaseSkill，残余 BaseSkill 自行播完。
	    备选策略（见 技能状态设计.md 五）：保留至全结束，便于日志/调试/中途 reconcile。

	    @param self GroupSkillServer - 组技能服实例
	    @param index number - runningRuntimeList 下标
	    @return nil
	]]
	function GroupSkillServer._removeSkillInstance(self: GroupSkillServer, index: number)
		local runtime = self.runningRuntimeList[index]
		if runtime then
			self:_disposeRuntime(runtime, "Finished")
			--冷却时间仅在 releaseSkill 时设置并倒计时，此处不再重设，与客户端一致
			--（若在“无运行中技能且冷却已为 0”时再次设为满值，会导致技能时长大于冷却时错误地多一轮冷却）
		end
	end

	--[[
	    开始释放技能。校验 CD / 跨槽、生成 combatSeed 与 skillCastId，创建 runtime 并启动 CombatWorld tick。

	    @param self GroupSkillServer - 组技能服实例
	    @param skillInputData SkillInputData - 施法输入（releaseCF / targetCF / clientPredictCastId 等）；玩家输入须经服权钳制
	    @return nil
	]]
	function GroupSkillServer.requestRelease(self: GroupSkillServer, skillInputData: SkillInputData)
		--print("releaseSkill 被调用，技能名称:", self.skillName, "isPlayingSkill:", self.isPlayingSkill, "冷却时间:", self.groupSkillCooldownRemaining)

		--当存在 Phase 1 未完成的 BaseSkill 时，由 onInputRequest 处理（派生），不进入 releaseSkill
		--当所有 Phase 1 完成且冷却结束时，可再次释放
		if not self:hasPhase1Incomplete() then
			if Cooldown.isGroupSkillOnCooldown(self) then
				local remainForLog = self.groupSkillCooldownRemaining
				if self.characterType == "Player" then
					local player = Players:GetPlayerByUserId(self.characterId)
					if player then
						remainForLog = Cooldown.getPlayerSlotCooldownRemainingSeconds(player, self.slotIndex)
					end
				end
				SkillSyncLog.log(self.skillName, "?", "?", "Server", "ReleaseGroupSkill", string.format("rejected reason=cooldown remaining=%.2f", remainForLog))
				if self.characterType == "Player" then
					local player = Players:GetPlayerByUserId(self.characterId)
					if player then
						ReleaseGroupSkill:FireClient(player, self.slotIndex, false)
					end
				end
				return
			end
		end
		--不再检查 isPlayingSkill，允许在 BaseSkill 运行期间再次释放（即使已释放控制权）

		if self.characterType == "Player" then
			SkillReleaseCrossCheck.runAll({
				characterId = self.characterId,
				characterType = self.characterType,
				incomingGroupSkillName = self.skillName,
				incomingSlotIndex = self.slotIndex,
			})
		end

		--在技能开始时进入冷却（玩家写时间戳；NPC 写内存倒计时）
		local effCooldown = self.groupSkillCooldown
		if self.characterType == "Player" then
			local plr = Players:GetPlayerByUserId(self.characterId)
			if plr then
				effCooldown = Cooldown.getEffectiveCooldownSecondsForPlayer(self, plr)
			end
		else
			self.groupSkillCooldownRemaining = effCooldown
		end

		-- 服务端权威生成 combatSeed（暴击、伤害浮动、命中序列等战斗结果均基于此）
		self._castSeq = (self._castSeq or 0) + 1
		local t = math.floor(workspace:GetServerTimeNow() * 1000)
		local combatSeed = math.abs((Cooldown.combatSeedFromCharacterId(self.characterId) * 73856093 + self._castSeq * 19349663 + t) % 2147483647)

		local function fallbackSkillCastId(): string
			return string.format("%s_%d_%d", tostring(self.characterId), t, self._castSeq)
		end

		-- 一期表现预测：客户端上传 clientPredictCastId，校验通过后用作 skillCastId，与 BaseSkillStarted 一致
		local skillCastId = fallbackSkillCastId()
		local clientId = skillInputData and skillInputData.clientPredictCastId
		if type(clientId) == "string" and #clientId > 0 and #clientId <= 80 then
			-- 允许 GUID 外的合法 id（如带下划线）；仍排除空白与过长
			if clientId:match("^[%w%-_]+$") and not self.runtimeByCastId[clientId] then
				skillCastId = clientId
			end
		end

		-- 创建单次施法实例运行器
		local runtime = GroupSkillInstanceRuntime.new(self, skillCastId, skillInputData, combatSeed)
		self:_registerRuntime(runtime)

		local ok = runtime:start()
		if not ok then
			self:_disposeRuntime(runtime, "StartFailed")
			if self.characterType ~= "Player" then
				self.groupSkillCooldownRemaining = 0
			end
			if self.characterType == "Player" then
				local player = Players:GetPlayerByUserId(self.characterId)
				if player then
					ReleaseGroupSkill:FireClient(player, self.slotIndex, false)
				end
			end
			return
		end

		if self.characterType == "Player" and (not skillInputData or skillInputData.skipCastTrait ~= true) then
			local player = Players:GetPlayerByUserId(self.characterId)
			local traitInput = skillInputData or runtime.castInputSnapshot
			if player and traitInput then
				SkillBuffUtil.TryProcCastTraitsOnSkillCast(player, self.skillID, {
					skillPower = self.skillPower,
					skillPurity = self.skillPurity,
					mpTp = self.mpTp,
					combatSeed = combatSeed,
					skillName = self.skillName,
					slotIndex = self.slotIndex,
					skillInputData = traitInput,
				})
			end
		end

		-- 确保运行时事件已启动（经 CombatWorld 调度各 runtime 的 Tick）
		if not self.groupSkillRuntimeEvent then
			local tickId = CombatWorld.allocId("GroupSkillRuntime")
			self._runtimeTickId = tickId
			self.groupSkillRuntimeEvent = CombatWorld.register(tickId, function(deltaTime)
				-- 两段式：先收集待移除，再销毁，避免边遍历边删
				local toRemove = {}
				for _, r in ipairs(self.runningRuntimeList) do
					r:Tick(deltaTime)
					if r:isFinished() then
						table.insert(toRemove, r)
					end
				end
				for _, r in ipairs(toRemove) do
					self:_disposeRuntime(r, "Finished")
				end

				local hasRunningBaseSkill = false
				for _, r in ipairs(self.runningRuntimeList) do
					if r:hasRunningBaseSkill() then
						hasRunningBaseSkill = true
						break
					end
				end
				if not hasRunningBaseSkill and self.groupSkillRuntimeEvent then
					if ENABLE_DERIVE_SUPPRESS_AFTER_CROSS_INTERRUPT and self.deriveSuppressedAfterCrossInterrupt and #self.runningRuntimeList == 0 then
						self.deriveSuppressedAfterCrossInterrupt = false
					end
					self.groupSkillRuntimeEvent:Disconnect()
					self.groupSkillRuntimeEvent = nil
					self._runtimeTickId = nil -- CombatWorld id
				end
			end, CombatWorld.Phase.SkillRuntime)
		end
		--技能时间轴对齐（仅施法者本人）；玩家 CD 结束时刻写入「技能CD时间戳」
		if self.characterType == "Player" then
			local player = Players:GetPlayerByUserId(self.characterId)
			if player then

				--DoSomeAfterUserSkill.UseSkill(player,self.skillID)

				local serverTime = workspace:GetServerTimeNow()
				FixSkillTime:FireClient(player, self.slotIndex, serverTime, nil, skillCastId)
				local endTs = serverTime
				if effCooldown > 0 then
					endTs = serverTime + effCooldown
				end
				Cooldown.writePlayerSkillCooldownEndTimestamp(player, self.slotIndex, endTs)
			end
		end

		-- 冷却与技能表现并行；玩家仅时间戳，NPC 为 groupSkillCooldownRemaining 内存倒计时
	end
end
