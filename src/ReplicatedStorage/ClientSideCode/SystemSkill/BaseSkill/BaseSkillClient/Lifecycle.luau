--[[
	Module: BaseSkillClient.Lifecycle
	Description: 连接绑定、状态机进出、终态收尾与 destroy（由 BaseSkillClient/init 挂载，业务勿直接 require）
	Author: 林奥宇
	Created: 2026-08-18
	Last Modified: 2026-08-18

	功能：
	- BindRunConn / BindStateConn 与对应 Cleanup
	- EnterState / ExitState / TryTransition / getFlowState / isTerminal / isRunningFlow
	- clearSkillMaterial（含预测 material handoff 与 visualFadeoutTime 延迟回收）
	- skillEnd / skillInterrupt / interruptSkillActionsOnly / destroy

	与 Start / Clock：
	- 业务只调 BaseSkillClient 实例方法
	- 运行时互调走 self:（EnterState、clearSkillMaterial 等），require 期不取对端子模块函数
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Class = require(game.ReplicatedFirst.AllSideCode.Class.Class)
local SkillStateRuntime = require(script.Parent.Parent.SkillStateRuntime)
local SkillControlRuntime = require(script.Parent.Parent.SkillControlRuntime)
local SkillEventConst = require(script.Parent.Parent.SkillEventConst)
local BaseSkillRuntimeHost = require(script.Parent.Parent.BaseSkillRuntimeHost)
local SkillStateActions = require(script.Parent.Parent.SkillStateActions)

local FXUtil = Utils.FXUtil

type BaseSkillClient = Class.BaseSkillClient

--[[
	挂载生命周期 API 到 BaseSkillClient 类表。
	@param BaseSkillClient table - 与 init 同一份类表
	@return () - 无返回值
]]
return function(BaseSkillClient)
	--[[
		绑定运行级连接（技能结束时统一回收）
		@param conn RBXScriptConnection
		@return conn
	]]
	function BaseSkillClient.BindRunConn(self: BaseSkillClient, conn)
		local runData = self.skillRunData
		if not runData then return conn end
		runData.runEvent = runData.runEvent or {}
		table.insert(runData.runEvent, conn)
		return conn
	end

	--[[
		绑定状态级连接（状态退出时回收）
		@param stateName string 状态名
		@param conn RBXScriptConnection
		@return conn
	]]
	function BaseSkillClient.BindStateConn(self: BaseSkillClient, stateName: string, conn)
		local runData = self.skillRunData
		if not runData then return conn end
		runData.stateEventMap = runData.stateEventMap or {}
		runData.stateEventMap[stateName] = runData.stateEventMap[stateName] or {}
		table.insert(runData.stateEventMap[stateName], conn)
		return conn
	end

	--[[
		清理指定状态的连接（状态退出时调用）
		@param stateName string
	]]
	function BaseSkillClient.CleanupStateConns(self: BaseSkillClient, stateName: string)
		local runData = self.skillRunData
		if not runData or not runData.stateEventMap then return end
		local list = runData.stateEventMap[stateName]
		if not list then return end
		for _, conn in list do
			pcall(function()
				if conn and typeof(conn) == "RBXScriptConnection" then
					conn:Disconnect()
				end
			end)
		end
		runData.stateEventMap[stateName] = nil
	end

	--[[
		清理所有连接（runEvent + stateEventMap）
		@param runDataToClear table? 指定 runData；nil 则用 self.skillRunData
	]]
	function BaseSkillClient.CleanupAllConns(self: BaseSkillClient, runDataToClear: any?)
		local data = runDataToClear or self.skillRunData
		if not data then return end
		if data.runEvent then
			for index, event in data.runEvent do
				pcall(function()
					if not event then
						return
					end
					-- RBXScriptConnection 或 CombatWorld Handle（均含 Disconnect）
					if typeof(event) == "RBXScriptConnection" then
						event:Disconnect()
					elseif type(event) == "table" and type(event.Disconnect) == "function" then
						event:Disconnect()
					end
				end)
				data.runEvent[index] = nil
			end
		end
		if data.stateEventMap then
			for stateName, list in data.stateEventMap do
				for _, conn in list do
					pcall(function()
						if not conn then
							return
						end
						if typeof(conn) == "RBXScriptConnection" then
							conn:Disconnect()
						elseif type(conn) == "table" and type(conn.Disconnect) == "function" then
							conn:Disconnect()
						end
					end)
				end
				data.stateEventMap[stateName] = nil
			end
		end
	end

	--[[
	    状态机：进入状态（callEnterHandler 实现）
	]]
	function BaseSkillClient.EnterState(self: BaseSkillClient, stateName: string, payload: any?)
		local sm = self.skillModule
		if not sm.States or not sm.States[stateName] then return end
		local stateConfig = sm.States[stateName]
		local runData = self.skillRunData
		if runData.State then
			runData.State.current = stateName
			runData.State.enteredAt = self.nowTime
		end
		if self._softMergeSkipEnterHandlers then
			return
		end
		local handlerName = stateConfig.OnEnterClient
		if handlerName and sm[handlerName] then
			sm[handlerName](self, payload)
		end
	end

	--[[
	    状态机：退出状态（callExitHandler 实现）
	]]
	function BaseSkillClient.ExitState(self: BaseSkillClient, stateName: string, payload: any?)
		local sm = self.skillModule
		if not sm.States or not sm.States[stateName] then return end
		local stateConfig = sm.States[stateName]
		local handlerName = stateConfig.OnExitClient
		if handlerName and sm[handlerName] then
			sm[handlerName](self, payload)
		end
		self:CleanupStateConns(stateName)
	end

	--[[
		状态机：尝试转换（委托 SkillStateRuntime）
		@return boolean 是否成功转换
	]]
	--[[
		流程真源：当前状态机状态
	]]
	function BaseSkillClient.getFlowState(self: BaseSkillClient): string?
		return SkillStateRuntime.getCurrentState(self.skillRunData)
	end

	--[[
		是否处于终态（Finished / Interrupted）
	]]
	function BaseSkillClient.isTerminal(self: BaseSkillClient): boolean
		local state = self:getFlowState()
		if not state then return true end
		local cfg = self.skillModule.States and self.skillModule.States[state]
		return cfg and cfg.IsTerminal == true
	end

	--[[
		流程是否正在运行（非终态）
	]]
	function BaseSkillClient.isRunningFlow(self: BaseSkillClient): boolean
		return not self:isTerminal()
	end

	function BaseSkillClient.TryTransition(self: BaseSkillClient, eventName: string, payload: any?)
		local handlers = {
			callEnterHandler = function(skill, stateName, p)
				skill:EnterState(stateName, p)
				SkillStateActions.enterForState(skill, stateName)
			end,
			callExitHandler = function(skill, stateName, p)
				SkillStateActions.exitForState(skill, stateName)
				skill:ExitState(stateName, p)
			end,
			onTerminalReached = function(skill, terminalState)
				skill:markFinished(terminalState)
			end,
			onFatalError = function(skill) skill:skillInterrupt() end,
		}
		return SkillStateRuntime.tryTransition(self, eventName, payload, handlers)
	end

	--[[
		终态统一收尾（框架约束：进入 IsTerminal 状态时调用）
		结束技能行为、断开时间轴、回收 hitbox、清理资源
	]]
	function BaseSkillClient.markFinished(self: BaseSkillClient, terminalState: string, immediate: boolean?)
		if self._presentationPredictActive then
			self._presentationPredictActive = false
			immediate = true
		end
		self:_doSkillEndCleanup(immediate, terminalState)
	end

	--[[
	    状态机：获取当前状态（兼容旧 API，优先用 getFlowState）
	]]
	function BaseSkillClient.GetCurrentState(self: BaseSkillClient): string?
		return self:getFlowState()
	end

	--[[
	    清理技能素材
	    @param runDataToClear table? 指定要清理的 runData；若为 nil 则清理 self.skillRunData
	        用于 visualFadeoutTime 延迟回收时：需传入当时的 runData，避免对象池复用后误销毁新 run 的素材
	]]
	function BaseSkillClient.clearSkillMaterial(self: BaseSkillClient, runDataToClear: any?)
		local data = runDataToClear or self.skillRunData
		if not data then return end
		if runDataToClear == nil and self._skillMaterialCleared then return end
		if runDataToClear == nil then self._skillMaterialCleared = true end

		-- 表现预测 handoff：素材已移交正式实例，勿 BackPool / 勿 onEnd 拆淡出
		if runDataToClear == nil and self._presentationPredictMaterialHandoff then
			self._presentationPredictMaterialHandoff = false
			self:CleanupAllConns(data)
			if data.material then
				for index in data.material do
					data.material[index] = nil
				end
			end
			return
		end

		-- 技能模块自定义清理：当前 run 走 onEnd；延迟清理历史 runData 走 onClearRunData（避免对象池复用后 Clone 残留）
		if runDataToClear ~= nil and self.skillModule.onClearRunData then
			self.skillModule.onClearRunData(self, runDataToClear)
		elseif runDataToClear == nil and self.skillModule.onEnd then
			self.skillModule.onEnd(self)
		end
		self:CleanupAllConns(data)
		--清理技能素材
		if data.material then
			for index, model in data.material do
				if model and model.Parent then
					FXUtil.BackPool_Instance(model)
					--model:Destroy()
					data.material[index] = nil
				end
			end
		end
	end

	--[[
		获取控制权状态（委托 SkillControlRuntime）
		@return "Locked" | "ChainOpen" | "Released"
	]]
	function BaseSkillClient.getControlState(self: BaseSkillClient): string
		return SkillControlRuntime.getState(self.controlRuntime)
	end

	--[[
	    提前释放技能控制权（委托 SkillControlRuntime）
	]]
	function BaseSkillClient.releaseControl(self: BaseSkillClient)
		SkillControlRuntime.release(self.controlRuntime, self.nowTime)
		self.isControlReleased = true
	end

	--[[
		仅立即结束 SkillAction（锁移动、动画轨道等），不结束状态机/不回收素材；用于跨槽打断时清理 A 的表现层。
	]]
	function BaseSkillClient.interruptSkillActionsOnly(self: BaseSkillClient)
		if self._destroyed or not self:isRunningFlow() then
			return
		end
		if self.skillAction then
			self.skillAction:Over(self.nowTime)
		end
		SkillStateActions.destroyAll(self)
		SkillControlRuntime.update(self.controlRuntime, self.nowTime, self)
		self.isPhase1Complete = self.controlRuntime.isPhase1Complete
		self.isControlReleased = self.controlRuntime.isControlReleased
		if not self.controlRuntime.isControlReleased then
			self:releaseControl()
		end
	end

	--[[
	    中断基础技能
	    @param self: BaseSkillClient 基础技能对象
	]]
	function BaseSkillClient.skillInterrupt(self: BaseSkillClient)
		self.flowState = "Interrupted"
		self.authoritativeState = "Interrupted"
		self:skillEnd(nil, "Interrupted")
	end

	--[[
	    内部：终态收尾逻辑（markFinished 与 skillEnd 共用）
	]]
	function BaseSkillClient._doSkillEndCleanup(self: BaseSkillClient, immediate: boolean?, terminalState: string?)
		local reason = terminalState or self.flowState or "Finished"
		if reason == "Interrupted" then
			self.flowState = "Interrupted"
			self.authoritativeState = "Interrupted"
		else
			self.flowState = "Finished"
			self.authoritativeState = "Finished"
		end
		self.finishReason = reason
		self.enteredTerminalAt = os.clock()

		SkillStateActions.destroyAll(self)
		self.skillAction:Over(self.nowTime)
		-- soft-merge destroy 时保留 handoff 标记到 skillAction:Destroy 之后，否则 Destroy 会误拆已保留的冲刺物理
		if not self._isDestroying then
			self._presentationPredictAnimHandoff = false
		end

		local fadeoutTime = (not immediate) and self.skillModule and self.skillModule.visualFadeoutTime
		if fadeoutTime and fadeoutTime > 0 then
			local runDataToClear = self.skillRunData
			local generationAtEnd = self.runGeneration
			task.delay(fadeoutTime, function()
				if self._destroyed then return end
				if self.clearSkillMaterial and runDataToClear then
					if self.runGeneration == generationAtEnd or runDataToClear ~= self.skillRunData then
						self:clearSkillMaterial(runDataToClear)
					end
				end
			end)
		else
			self:clearSkillMaterial()
		end

		BaseSkillRuntimeHost.stopClock(self._runtimeHost)
		self.skillTimeUpdateEvent = nil

		BaseSkillRuntimeHost.destroyHitbox(self._runtimeHost)
		self.hitbox = {}
		self.hitboxRuntime = nil
		self.skillInputData = {}
		self.skillTargetData = nil
		self.hitboxControlIndex = 0
		self.nowTime = 0
		BaseSkillRuntimeHost.resetControl(self._runtimeHost)
		self.isPhase1Complete = self.controlRuntime.isPhase1Complete
		self.isControlReleased = self.controlRuntime.isControlReleased
	end

	--[[
	    结束基础技能
	    @param self: BaseSkillClient     基础技能对象
	    @param immediate: boolean?       true=立即回收素材（destroy 时用），false/nil=可延迟（StopSkill 时让爆炸等播完）
	    @param reason: "Interrupted"|"Finished"?  调用方已设 flowState 时传入，用于优先走状态机
	]]
	function BaseSkillClient.skillEnd(self: BaseSkillClient, immediate: boolean?, reason: "Interrupted" | "Finished"?)
		if self._destroyed and not self._isDestroying then return end
		local targetReason = reason or self.flowState or "Finished"
		if targetReason == "Interrupted" then
			if self:TryTransition(SkillEventConst.Interrupt) then
				return -- 已通过状态机到终态，markFinished 已收尾
			end
			local runData = self.skillRunData
			if runData and runData.State then
				local cur = runData.State.current
				SkillStateActions.exitForState(self, cur)
				self:ExitState(cur, nil)
			end
		else
			if self:TryTransition(SkillEventConst.ForceFinish) then
				return -- 已通过状态机到终态，markFinished 已收尾
			end
			local runData = self.skillRunData
			if runData and runData.State then
				local cur = runData.State.current
				SkillStateActions.exitForState(self, cur)
				self:ExitState(cur, nil)
			end
		end

		self:_doSkillEndCleanup(immediate, targetReason)
	end

	-- 标准清理协议：destroy 可重入，清理后旧回调失效、不再广播
	function BaseSkillClient:_forceFinishIfNeeded(reason: string?, immediate: boolean?)
		if not self:isTerminal() then
			self:skillEnd(immediate, reason)
		end
	end

	function BaseSkillClient:_disconnectAll()
		self:clearSkillMaterial()
	end

	function BaseSkillClient:_clearTimers()
		BaseSkillRuntimeHost.stopClock(self._runtimeHost)
		if self.skillTimeUpdateEvent then
			self.skillTimeUpdateEvent:Disconnect()
			self.skillTimeUpdateEvent = nil
		end
	end

	function BaseSkillClient:_clearHitboxes()
		BaseSkillRuntimeHost.destroyHitbox(self._runtimeHost)
		self.hitbox = {}
		self.hitboxRuntime = nil
	end

	--[[
		销毁技能（标准清理协议）
		异常销毁（切图、角色重建、对象淘汰）默认 Interrupted；正常结束回收时显式传 "Finished"
		@param self: BaseSkillClient 基础技能对象
		@param reason: "Interrupted"|"Finished"? 默认 "Interrupted"
		@param immediate: boolean? 默认 true，立即回收素材；false 时尊重 visualFadeoutTime
	]]
	function BaseSkillClient.destroy(self: BaseSkillClient, reason: ("Interrupted" | "Finished")?, immediate: boolean?)
		if self._destroyed or self._isDestroying then return end
		self._isDestroying = true
		self._presentationPredictActive = false
		self._presentationPredictHold = false

		reason = reason or "Interrupted"
		self.destroyReason = reason
		if immediate == nil then
			immediate = true
		end

		self:_forceFinishIfNeeded(reason, immediate)

		if self.skillAction then
			self.skillAction:Destroy()
		end
		-- Destroy 已按 handoff 决定是否保留物理；此处再清标记
		self._presentationPredictAnimHandoff = false

		self._destroyed = true
		self._isDestroying = false
		self:_disconnectAll()
		self:_clearTimers()
		self:_clearHitboxes()

		self.skillRunData = {}
		self.skillInputData = {}
		self.skillTargetData = nil
		self.hitboxControlIndex = 0
		self.nowTime = 0
		BaseSkillRuntimeHost.resetControl(self._runtimeHost)
		self.isPhase1Complete = self.controlRuntime.isPhase1Complete
		self.isControlReleased = self.controlRuntime.isControlReleased
		self.cleanupCompleted = true
	end
end
