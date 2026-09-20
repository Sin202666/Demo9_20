--[[
	Module: BaseSkillServer.Lifecycle
	Description: 连接绑定、状态机进出、interrupt/stop/destroy（由 BaseSkillServer/init 挂载，业务勿直接 require）
	Author: 林奥宇
	Created: 2026-08-18
	Last Modified: 2026-08-31

	功能：
	- BindRunConn / BindStateConn 与对应 Cleanup
	- EnterState / ExitState / TryTransition / getFlowState / isTerminal / isRunningFlow
	- clearSkillMaterial、_finish（广播 StopSkill）、interrupt / stop / destroy

	与 Start / Sync：
	- 业务只调 BaseSkillServer 实例方法
	- 运行时互调走 self:；_finish 用 getCharacterPosition
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Class = require(game.ReplicatedFirst.AllSideCode.Class.Class)

local BaseSkillFolder = game.ReplicatedStorage.ClientSideCode.SystemSkill.BaseSkill
local SkillStateRuntime = require(BaseSkillFolder.SkillStateRuntime)
local SkillControlRuntime = require(BaseSkillFolder.SkillControlRuntime)
local SkillEventConst = require(BaseSkillFolder.SkillEventConst)
local SkillSyncDispatcher = require(BaseSkillFolder.SkillSyncDispatcher)
local BaseSkillRuntimeHost = require(BaseSkillFolder.BaseSkillRuntimeHost)

local SkillSyncLog = Utils.SkillSyncLog
local Players = Utils.Players
local SkillBuffUtil = Utils.SkillBuffUtil

type BaseSkillServer = Class.BaseSkillServer

--[[
	挂载生命周期 API 到 BaseSkillServer 类表。
	@param BaseSkillServer table - 与 init 同一份类表
	@return () - 无返回值
]]
return function(BaseSkillServer)
	--[[
		绑定运行级连接（技能结束时统一回收）。

		@param self BaseSkillServer - 基础技能服实例
		@param conn RBXScriptConnection - 运行级连接（Heartbeat 等）
		@return RBXScriptConnection - 原样返回 conn，便于链式写法
	]]
	function BaseSkillServer.BindRunConn(self: BaseSkillServer, conn)
		local runData = self.skillRunData
		if not runData then return conn end
		runData.runEvent = runData.runEvent or {}
		table.insert(runData.runEvent, conn)
		return conn
	end

	--[[
		绑定状态级连接（状态退出时回收）。

		@param self BaseSkillServer - 基础技能服实例
		@param stateName string - 状态名（与 States 键一致）
		@param conn RBXScriptConnection - 状态级连接
		@return RBXScriptConnection - 原样返回 conn
	]]
	function BaseSkillServer.BindStateConn(self: BaseSkillServer, stateName: string, conn)
		local runData = self.skillRunData
		if not runData then return conn end
		runData.stateEventMap = runData.stateEventMap or {}
		runData.stateEventMap[stateName] = runData.stateEventMap[stateName] or {}
		table.insert(runData.stateEventMap[stateName], conn)
		return conn
	end

	--[[
		清理指定状态的连接（状态退出时调用）。

		@param self BaseSkillServer - 基础技能服实例
		@param stateName string - 状态名
		@return nil
	]]
	function BaseSkillServer.CleanupStateConns(self: BaseSkillServer, stateName: string)
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
		清理所有连接（runEvent + stateEventMap）。

		@param self BaseSkillServer - 基础技能服实例
		@return nil
	]]
	function BaseSkillServer.CleanupAllConns(self: BaseSkillServer)
		local data = self.skillRunData
		if not data then return end
		if data.runEvent then
			for index, event in pairs(data.runEvent) do
				pcall(function()
					if not event then
						return
					end
					if typeof(event) == "RBXScriptConnection" then
						event:Disconnect()
					elseif type(event) == "table" and type(event.Disconnect) == "function" then
						event:Disconnect()
					end
				end)
				data.runEvent[index] = nil
			end
			data.runEvent = nil
		end
		if data.stateEventMap then
			for stateName, list in pairs(data.stateEventMap) do
				for _, conn in ipairs(list) do
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
			data.stateEventMap = nil
		end
	end

	--[[
	    状态机：进入状态（callEnterHandler 实现）。
	    玩家进入 ControlOpenState 时可为施法者套技能 Buff。

	    @param self BaseSkillServer - 基础技能服实例
	    @param stateName string - 目标状态名，须存在于 skillModule.States
	    @param payload any? - 传给 OnEnterServer 的附加数据；无则 nil
	    @return nil
	]]
	function BaseSkillServer.EnterState(self: BaseSkillServer, stateName: string, payload: any?)
		local sm = self.skillModule
		if not sm.States or not sm.States[stateName] then return end
		local stateConfig = sm.States[stateName]
		local runData = self.skillRunData
		if runData.State then
			runData.State.current = stateName
			runData.State.enteredAt = self.nowTime
		end
		local cos = sm.ControlOpenState
		if self.characterType == "Player" and cos and cos == stateName then
			local sid = tonumber(self.skillID)
			if sid and sid > 0 then
				local plr = Players:GetPlayerByUserId(self.characterId)
				if plr then
					SkillBuffUtil.ApplyBuffsFromSkillForCaster(plr, sid, {
						skillPower = self.skillPower,
						skillPurity = self.skillPurity,
						mpTp = self.mpTp,
					})
				end
			end
		end
		local handlerName = stateConfig.OnEnterServer
		if handlerName and sm[handlerName] then
			sm[handlerName](self, payload)
		end
	end

	--[[
	    状态机：退出状态（callExitHandler 实现），并清理该状态连接。

	    @param self BaseSkillServer - 基础技能服实例
	    @param stateName string - 即将离开的状态名
	    @param payload any? - 传给 OnExitServer 的附加数据；无则 nil
	    @return nil
	]]
	function BaseSkillServer.ExitState(self: BaseSkillServer, stateName: string, payload: any?)
		local sm = self.skillModule
		if not sm.States or not sm.States[stateName] then return end
		local stateConfig = sm.States[stateName]
		local handlerName = stateConfig.OnExitServer
		if handlerName and sm[handlerName] then
			sm[handlerName](self, payload)
		end
		self:CleanupStateConns(stateName)
	end

	--[[
		状态机：尝试转换（委托 SkillStateRuntime）。

		@param self BaseSkillServer - 基础技能服实例
		@param eventName string - 转换事件名（如 SkillEventConst.Interrupt）
		@param payload any? - 传给进出态回调的附加数据
		@return boolean - 成功转换则为 true
	]]
	function BaseSkillServer.TryTransition(self: BaseSkillServer, eventName: string, payload: any?)
		local handlers = {
			callEnterHandler = function(skill, stateName, p) skill:EnterState(stateName, p) end,
			callExitHandler = function(skill, stateName, p) skill:ExitState(stateName, p) end,
			onTerminalReached = function(skill, terminalState)
				skill:markFinished(terminalState)
			end,
			onFatalError = function(skill) skill:interrupt() end,
		}
		return SkillStateRuntime.tryTransition(self, eventName, payload, handlers)
	end

	--[[
		终态统一收尾（框架约束：进入 IsTerminal 状态时调用）。
		断开时间轴、回收 hitbox、清理资源、广播 StopSkill。

		@param self BaseSkillServer - 基础技能服实例
		@param terminalState string - 终态名；"Finished" 走 Finished，其余走 Interrupted
		@return nil
	]]
	function BaseSkillServer.markFinished(self: BaseSkillServer, terminalState: string)
		local reason = (terminalState == "Finished") and "Finished" or "Interrupted"
		self:_finish(reason)
	end

	--[[
		流程真源：当前状态机状态。

		@param self BaseSkillServer - 基础技能服实例
		@return string? - 当前状态名；无 runData 则为 nil
	]]
	function BaseSkillServer.getFlowState(self: BaseSkillServer): string?
		return SkillStateRuntime.getCurrentState(self.skillRunData)
	end

	--[[
		是否处于终态（Finished / Interrupted）。

		@param self BaseSkillServer - 基础技能服实例
		@return boolean - 无状态或 States[state].IsTerminal == true 则为 true
	]]
	function BaseSkillServer.isTerminal(self: BaseSkillServer): boolean
		local state = self:getFlowState()
		if not state then return true end
		local cfg = self.skillModule.States and self.skillModule.States[state]
		return cfg and cfg.IsTerminal == true
	end

	--[[
		流程是否正在运行（非终态）。

		@param self BaseSkillServer - 基础技能服实例
		@return boolean - 非终态则为 true
	]]
	function BaseSkillServer.isRunningFlow(self: BaseSkillServer): boolean
		return not self:isTerminal()
	end

	--[[
		状态机：获取当前状态（兼容旧 API，优先用 getFlowState）。

		@param self BaseSkillServer - 基础技能服实例
		@return string? - 当前状态名；无则 nil
	]]
	function BaseSkillServer.GetCurrentState(self: BaseSkillServer): string?
		return self:getFlowState()
	end

	--[[
	    自定义清理技能数据（仅 runEvent / stateEventMap / onEndServer / 技能模块资源）。
	    hitbox / timeline / running flag 由 _finish 统一回收。幂等。

	    @param self BaseSkillServer - 基础技能服实例
	    @return nil
	]]
	function BaseSkillServer.clearSkillMaterial(self: BaseSkillServer)
		if self._skillMaterialCleared then return end
		self._skillMaterialCleared = true
		self:CleanupAllConns()
		-- 清理技能模块回调（onEndServer）
		if self.skillModule and self.skillModule.onEndServer then
			self.skillModule.onEndServer(self)
		end
	end

	--[[
		获取控制权状态（委托 SkillControlRuntime）。

		@param self BaseSkillServer - 基础技能服实例
		@return string - "Locked" | "ChainOpen" | "Released"
	]]
	function BaseSkillServer.getControlState(self: BaseSkillServer): string
		return SkillControlRuntime.getState(self.controlRuntime)
	end

	--[[
	    提前释放技能控制权（委托 SkillControlRuntime）。

	    @param self BaseSkillServer - 基础技能服实例
	    @return nil
	]]
	function BaseSkillServer.releaseControl(self: BaseSkillServer)
		SkillControlRuntime.release(self.controlRuntime, self.nowTime)
	end

	--[[
		跨槽打断：无客户端 SkillAction，仅将 Phase1/放权与客户端对齐，不结束状态机、不回收 hitbox/素材。

		@param self BaseSkillServer - 基础技能服实例
		@return nil
	]]
	function BaseSkillServer.interruptSkillActionsOnly(self: BaseSkillServer)
		if self._destroyed or not self:isRunningFlow() then
			return
		end
		if self.skillAction then
			self.skillAction:Over(self.nowTime)
		end
		SkillControlRuntime.forceMarkPhase1CompleteAndRelease(self.controlRuntime, self.nowTime)
		self.isPhase1Complete = self.controlRuntime.isPhase1Complete
		self.isControlReleased = self.controlRuntime.isControlReleased
	end


	--[[
	    内部收尾：统一 stop / interrupt 的生命周期清理，并广播 StopSkill。

	    @param self BaseSkillServer - 基础技能服实例
	    @param reason "Finished" | "Interrupted" - 终态原因，同时写入 flowState
	    @return nil
	]]
	function BaseSkillServer._finish(self: BaseSkillServer, reason: "Finished" | "Interrupted")
		if self.flowState == "Finished" or self.flowState == "Interrupted" then
			return
		end

		BaseSkillRuntimeHost.stopClock(self._runtimeHost)
		self.timeLineRunServer = nil

		if self.skillAction then
			self.skillAction:Over(self.nowTime)
		end

		BaseSkillRuntimeHost.destroyHitbox(self._runtimeHost)
		self.hitbox = {}
		-- 回收技能运行数据（含 runEvent、stateEventMap 连接断开）
		self:clearSkillMaterial()
		self.skillRunData = {}
		-- 回收技能输入数据
		self.skillInputData = {}
		-- 发送技能结束事件（Player/NPC 均广播，旁观端需同步表现结束）
		local stopData = {
			characterId = self.characterId,
			characterType = self.characterType,
			skillName = self.skillName,
			skillCastId = self.skillCastId,
			baseSkillInstanceId = self.baseSkillInstanceId,
			reason = reason,
		}
		SkillSyncLog.log(self.skillName, self.skillCastId, self.baseSkillInstanceId, "Server", "StopSkill", ("reason=%s"):format(reason))
		local endPos = self:getCharacterPosition()
		SkillSyncDispatcher.dispatch(self, "StopSkill", stopData, endPos)
		-- 重置时间
		self.nowTime = 0
		self.skillTimeFix = 0
		self.hitboxControlIndex = 0
		self.flowState = reason
		self.authoritativeState = reason
		self.finishReason = reason
		self.enteredTerminalAt = os.clock()
		BaseSkillRuntimeHost.resetControl(self._runtimeHost)
		self.isPhase1Complete = self.controlRuntime.isPhase1Complete
		self.isControlReleased = self.controlRuntime.isControlReleased
	end

	--[[
	    服务器中断技能。
	    优先 TryTransition("Interrupt") 走状态机；成功时 TryTransition 已调用 _finish，此处直接返回；失败时补 ExitState 再 _finish。

	    @param self BaseSkillServer - 基础技能服实例
	    @return nil
	]]
	function BaseSkillServer.interrupt(self: BaseSkillServer)
		if self:isTerminal() then return end
		if self:TryTransition(SkillEventConst.Interrupt) then
			return  -- 已通过状态机转换到 Interrupted，TryTransition 已调用 _finish
		end
		local runData = self.skillRunData
		if runData and runData.State then
			self:ExitState(runData.State.current, nil)
		end
		self:_finish("Interrupted")
	end

	--[[
	    服务器结束技能。
	    优先 TryTransition("ForceFinish") 走状态机；成功时 TryTransition 已调用 _finish，此处直接返回；失败时补 ExitState 再 _finish。

	    @param self BaseSkillServer - 基础技能服实例
	    @return nil
	]]
	function BaseSkillServer.stop(self: BaseSkillServer)
		if self:isTerminal() then return end
		if self:TryTransition(SkillEventConst.ForceFinish) then
			return  -- 已通过状态机转换到 Finished，递归 stop 会调用 _finish
		end
		local runData = self.skillRunData
		if runData and runData.State then
			self:ExitState(runData.State.current, nil)
		end
		self:_finish("Finished")
	end

	--[[
		destroy 前按原因收尾仍在跑的流程。Finished 走 stop，其余走 interrupt。
		destroy 可重入，清理后旧回调失效、不再广播。

		@param self BaseSkillServer - 基础技能服实例
		@param reason string? - 销毁原因；"Finished" 时 stop，其余 interrupt
		@return nil
	]]
	function BaseSkillServer:_forceFinishIfNeeded(reason: string?)
		if self:isRunningFlow() then
			if reason == "Finished" then
				self:stop()
			else
				self:interrupt()
			end
		end
	end

	--[[
		断开技能素材侧连接（委托 clearSkillMaterial）。

		@param self BaseSkillServer - 基础技能服实例
		@return nil
	]]
	function BaseSkillServer:_disconnectAll()
		self:clearSkillMaterial()
	end

	--[[
		停止 CombatWorld 时钟并清空 timeLineRunServer。

		@param self BaseSkillServer - 基础技能服实例
		@return nil
	]]
	function BaseSkillServer:_clearTimers()
		BaseSkillRuntimeHost.stopClock(self._runtimeHost)
		self.timeLineRunServer = nil
	end

	--[[
		销毁 Hitbox 运行时并清空 hitbox 表。

		@param self BaseSkillServer - 基础技能服实例
		@return nil
	]]
	function BaseSkillServer:_clearHitboxes()
		BaseSkillRuntimeHost.destroyHitbox(self._runtimeHost)
		self.hitbox = {}
	end

	--[[
		销毁基础技能服务器对象（标准清理协议，两阶段与客户端对称）。
		若仍在运行，先 stop/interrupt 确保客户端收到 stop，再做纯对象清理。

		@param self BaseSkillServer - 基础技能服实例
		@param reason string? - "Finished" 时走 stop，否则走 interrupt；nil 视为 "Destroyed"
		@return nil
	]]
	function BaseSkillServer.destroy(self: BaseSkillServer, reason: string?)
		if self._destroyed or self._isDestroying then return end
		self._isDestroying = true

		reason = reason or "Destroyed"
		self.destroyReason = reason
		self:_forceFinishIfNeeded(reason)

		self._destroyed = true
		self._isDestroying = false
		self:_disconnectAll()
		self:_clearTimers()
		self:_clearHitboxes()

		if self.skillAction then
			self.skillAction:Destroy()
			self.skillAction = nil
		end

		self.skillRunData = {}
		self.skillInputData = {}
		self.skillTargetData = nil
		self._runtimeHost = nil
		self._definition = nil
		self._context = nil
		self.cleanupCompleted = true
	end
end
