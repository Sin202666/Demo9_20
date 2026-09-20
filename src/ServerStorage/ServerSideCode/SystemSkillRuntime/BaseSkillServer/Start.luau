--[[
	Module: BaseSkillServer.Start
	Description: 服务端开技与素材初始化（由 BaseSkillServer/init 挂载，业务勿直接 require）
	Author: 林奥宇
	Created: 2026-08-18
	Last Modified: 2026-08-31

	功能：
	- initSkillMaterial：委托 RuntimeHost，再调 onStartServer
	- start：更新 context、建 Hitbox、Enter InitialState、RuntimeHost.startClock
	- 时钟 tick 仍在 start 闭包内（SkillStateMachine / HitResolver 在文件顶部 require），不塞进 RuntimeHost

	与 Lifecycle：
	- EnterState / TryTransition / isRunningFlow 走类表
	- 开始同步仅由 GroupSkillServer 发 BaseSkillStarted
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Class = require(game.ReplicatedFirst.AllSideCode.Class.Class)

local BaseSkillFolder = game.ReplicatedStorage.ClientSideCode.SystemSkill.BaseSkill
local SkillControlRuntime = require(BaseSkillFolder.SkillControlRuntime)
local SkillEventConst = require(BaseSkillFolder.SkillEventConst)
local BaseSkillExecutionContext = require(BaseSkillFolder.BaseSkillExecutionContext)
local BaseSkillRuntimeHost = require(BaseSkillFolder.BaseSkillRuntimeHost)
local DoSomeAfterUserSkill = require(BaseSkillFolder.DoSomeAfterUserSkill)
local SkillStateMachine = require(BaseSkillFolder.SkillStateMachine)

local RunService = Utils.RunService
local Players = Utils.Players
local SkillHitPresentation = Utils.SkillHitPresentation
local HitResolver = Utils.HitResolver

type BaseSkillServer = Class.BaseSkillServer
type SkillInputData = Class.SkillInputData

--[[
	挂载开技 API 到 BaseSkillServer 类表。
	@param BaseSkillServer table - 与 init 同一份类表
	@return () - 无返回值
]]
return function(BaseSkillServer)
	--[[
	    自定义初始化技能数据（委托 RuntimeHost），再调 skillModule.onStartServer。

	    @param self BaseSkillServer - 基础技能服实例
	    @return nil
	]]
	function BaseSkillServer.initSkillMaterial(self: BaseSkillServer)
		self._skillMaterialCleared = false
		local runData = BaseSkillRuntimeHost.initMaterial(self._runtimeHost, self._definition, { isClient = false })
		self.skillRunData = runData
		if self.skillModule.onStartServer then
			self.skillModule.onStartServer(self)
		end
	end

	--[[
	    服务器开始技能
	    【P2 规则】基础技能开始同步仅由 GroupSkillServer 发 BaseSkillStarted，本方法不发送任何开始同步。
	    组技能体系中的 BaseSkill 均由 GroupSkillServer 驱动，不存在 BaseSkillServer 独立发开始同步的路径。

	    @param self BaseSkillServer - 基础技能服实例
	    @param inputData SkillInputData - 施法输入（skillCastId / releaseCF / targetCF / combatSeed 等）
	    @return nil
	]]
	function BaseSkillServer.start(self: BaseSkillServer, inputData: SkillInputData)
		if self._destroyed or self._isDestroying or self:isRunningFlow() then return end

		assert(self.skillModule.States and self.skillModule.InitialState,
			("[BaseSkillServer] %s 必须定义 States + InitialState（仅支持状态机范式）"):format(self.skillName))

		-- 更新 context（实例标识、输入数据）
		BaseSkillExecutionContext.update(self._context, {
			skillModule = self.skillModule,
			skillCastId = inputData.skillCastId,
			baseSkillInstanceId = inputData.baseSkillInstanceId,
			activeBaseSkillIndex = inputData.activeBaseSkillIndex,
			combatSeed = inputData.combatSeed,
			releaseCF = inputData.releaseCF,
			targetCF = inputData.targetCF,
			moveDirectionStr = inputData.moveDirectionStr,
			trackTargetId = inputData.trackTargetId,
			skillTargetData = inputData.skillTargetData,
			approachLandWorldPos = inputData.approachLandWorldPos,
			moveFaceMode = inputData.moveFaceMode,
			moveFaceWorldPos = inputData.moveFaceWorldPos,
			multThunderPathPoints = inputData.multThunderPathPoints,
			multThunderSpawnGround = inputData.multThunderSpawnGround,
		})
		self.skillCastId = self._context.skillCastId
		self.baseSkillInstanceId = self._context.baseSkillInstanceId
		self.activeBaseSkillIndex = self._context.activeBaseSkillIndex
		self.combatSeed = self._context.combatSeed

		BaseSkillExecutionContext.refreshCharacter(self._context)
		self.character = self._context.character

		--准备技能运行数据
		self:initSkillMaterial()
		-- 创建命中检测 Hitbox（委托 RuntimeHost）
		self.hitbox = BaseSkillRuntimeHost.initHitbox(self._runtimeHost, self, {
			characterId = inputData.characterId,
			characterType = inputData.characterType,
			combatSeed = self.combatSeed,
		})
		self.hitboxRuntime = self._runtimeHost.hitboxRuntime
		-- 同步层快照（仅此处写入，供 StopSkill 等同步）
		self.flowState = "Running"
		self.authoritativeState = "Running"
		self.skillInputData = self._context.skillInputData
		self.skillTargetData = self.skillInputData.skillTargetData

		self:EnterState(self.skillModule.InitialState, nil)

		if self.skillAction then
			self.skillAction:Init()
			self.skillAction:Start(self.nowTime)
		end

		--每次释放基础技能触发业务逻辑
		if self.characterType == "Player" then
			local player = Players:GetPlayerByUserId(self.characterId)
			if player then
				DoSomeAfterUserSkill.UseSkill(player,self.skillID)
			end
		end


		self.timeLineRunServer = BaseSkillRuntimeHost.startClock(self._runtimeHost, RunService, function(deltaTime)
			if self._destroyed then return end
			self.nowTime += deltaTime
			local runData = self.skillRunData

			if self.skillAction then
				self.skillAction:Run(self.nowTime)
			end

			-- 控制权 Phase 1 判定（委托 SkillControlRuntime）
			SkillControlRuntime.update(self.controlRuntime, self.nowTime, self)
			-- 兼容 GroupSkill 等调用方直接读 isPhase1Complete / isControlReleased
			self.isPhase1Complete = self.controlRuntime.isPhase1Complete
			self.isControlReleased = self.controlRuntime.isControlReleased

			local stateConfig = self.skillModule.States and self.skillModule.States[runData.State.current]
			if stateConfig and SkillStateMachine.shouldStateTimeout(stateConfig, runData.State.enteredAt, self.nowTime) then
				self:TryTransition(SkillEventConst.StateTimeout, nil)
				if not self:isRunningFlow() then return end
			end
			-- 先检测 Hitbox（敌人命中），再检测障碍，确保同一帧时 Enemy 优先于 Obstacle
			for _, hitbox in self.hitbox do
				if hitbox.isActive then
					local _result = hitbox:check()
					if _result and next(_result) then
						-- 技能模块可提供 onProjectileHitServer 处理弹道中途命中（停飞行、提前爆炸、伤害、广播 ProjectileHitConfirmed）
						-- 命中确认广播由技能模块决定，BaseSkillServer 不再统一兜底自动发
						if self.skillModule.onProjectileHitServer then
							self.skillModule.onProjectileHitServer(self, hitbox, _result)
						else
							if SkillHitPresentation and SkillHitPresentation.beginBatch then
								SkillHitPresentation.beginBatch(hitbox.hitboxOwnerId)
							end
							for _partParent, part in _result do
								HitResolver.applyHit(self, hitbox, part, _partParent)
							end
							if SkillHitPresentation and SkillHitPresentation.flushBatch then
								SkillHitPresentation.flushBatch()
							end
						end
					end
				end
			end
			local obstacleCheckState = runData.State.current
			if self.skillModule.Server_UpdateProjectileObstacleCheck
				and (obstacleCheckState == "ProjectileFlying" or obstacleCheckState == "ThrownMoving")
			then
				self.skillModule.Server_UpdateProjectileObstacleCheck(self)
			end
		end)
	end
end
