--[[
	Module: BaseSkillClient.Start
	Description: 正式开技、表现预测开技与 soft-merge 素材移交（由 BaseSkillClient/init 挂载，业务勿直接 require）
	Author: 林奥宇
	Created: 2026-08-18
	Last Modified: 2026-08-18

	功能：
	- initSkillMaterial：委托 RuntimeHost 建素材，再调 skillModule.onStart
	- skillStart：正式时间轴；opts.softMerge / softMergeRunData / 旧 softMergeInitialNowTime
	- skillStartPresentationPredict：无 Hitbox，StateTimeout 跨态至 ControlOpen/Phase1 后 hold

	与 Clock / Lifecycle：
	- 业务只调 BaseSkillClient 实例方法
	- 时钟闭包调用 Clock 返回的 tick；EnterState / isRunningFlow 走类表（Lifecycle 挂载）
	- CLIENT_HITBOX_DISABLED 仍为 true，不在本拆分打开客户端 Hitbox
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Class = require(game.ReplicatedFirst.AllSideCode.Class.Class)
local SkillEventConst = require(script.Parent.Parent.SkillEventConst)
local BaseSkillRuntimeHost = require(script.Parent.Parent.BaseSkillRuntimeHost)
local SkillStateActions = require(script.Parent.Parent.SkillStateActions)

local RunService = Utils.RunService
local AssetPaths = Utils.AssetPaths
local FXUtil = Utils.FXUtil

type BaseSkillClient = Class.BaseSkillClient

-- 技能模型目录：ReplicatedStorage/Assets/ModelRes/Skill（经 AssetPaths，兼容旧 ModelRes）
local SkillResFolder = AssetPaths.Resolve("ModelRes/Skill", AssetPaths.Scope.Shared)

-- 临时：为 true 时不创建客户端 Hitbox 实例（无双端重复部件；命中仍以服务端为准）
local CLIENT_HITBOX_DISABLED = true

--[[
	InitialState Duration 上限（兼容旧 softMergeInitialNowTime）
]]
local function getInitialStateDurationCap(skillModule: any): number?
	if not skillModule or not skillModule.States or not skillModule.InitialState then
		return nil
	end
	local init = skillModule.InitialState
	local dur = skillModule.States[init] and skillModule.States[init].Duration
	if type(dur) ~= "number" or dur < 0 then
		return nil
	end
	return dur
end

--[[
	InitialState → ControlOpenState（若无则仅 InitialState）路径上 Duration>=0 的累计上限，供软合并 clamp
]]
local function getPredictSoftMergeNowTimeCap(skillModule: any): number?
	if not skillModule or not skillModule.States or not skillModule.InitialState then
		return nil
	end
	local states = skillModule.States
	local transitions = skillModule.Transitions or {}
	local openState = skillModule.ControlOpenState
	local current = skillModule.InitialState
	local sum = 0
	local guard = 0
	while current and guard < 32 do
		guard += 1
		local cfg = states[current]
		if not cfg then
			break
		end
		local dur = cfg.Duration
		if type(dur) == "number" and dur > 0 then
			sum += dur
		end
		if openState and current == openState then
			return sum
		end
		if not openState then
			-- 无 ControlOpen：仅 InitialState
			return (type(dur) == "number" and dur >= 0) and dur or sum
		end
		local nextState = nil
		for _, rule in ipairs(transitions) do
			if rule.From == current and rule.Event == SkillEventConst.StateTimeout then
				nextState = rule.To
				break
			end
		end
		if not nextState or nextState == current then
			break
		end
		current = nextState
	end
	if sum > 0 then
		return sum
	end
	return nil
end

--[[
	挂载开技 API 到 BaseSkillClient 类表。
	@param BaseSkillClient table - 与 init 同一份类表
	@param _skillClientClockTick (self, deltaTime, presentationPredict) -> () - Clock 返回的每帧 tick
	@return () - 无返回值
]]
return function(BaseSkillClient, _skillClientClockTick)
	--[[
	    初始化技能素材（委托 RuntimeHost）
	]]
	function BaseSkillClient.initSkillMaterial(self: BaseSkillClient)
		local runData = BaseSkillRuntimeHost.initMaterial(self._runtimeHost, self._definition, {
			isClient = true,
			skillResFolder = SkillResFolder,
		})
		self.skillRunData = runData
		if self.skillModule.onStart then
			self.skillModule.onStart(self)
		end
	end

	--[[
	    开始基础技能
	    @param self: BaseSkillClient 基础技能对象
		@param opts {
			softMergeInitialNowTime: number?, -- 兼容旧：仅 InitialState 内秒数
			softMerge: { nowTime: number, state: string, enteredAt: number? }?, -- 预测快照软合并
			softMergeRunData: { material: any?, FadeCharacter: any?, runEvent: any?, _fxFired: any?, _rollingFxDirection: string?, _rollingFxStarted: boolean? }?, -- 预测移交的素材/FX 幂等表
		}?
	]]
	function BaseSkillClient.skillStart(self: BaseSkillClient, opts: {
		softMergeInitialNowTime: number?,
		softMerge: { nowTime: number, state: string, enteredAt: number? }?,
		softMergeRunData: { material: any?, FadeCharacter: any?, runEvent: any?, _fxFired: any?, _rollingFxDirection: string?, _rollingFxStarted: boolean? }?,
	}?)
		if self._destroyed or self:isRunningFlow() then return end

		assert(self.skillModule.States and self.skillModule.InitialState,
			("[BaseSkillClient] %s 必须定义 States + InitialState（仅支持状态机范式）"):format(self.skillName))

		self.runGeneration = (self.runGeneration or 0) + 1

		-- 验证角色是否存在
		if not self.character or not self.character.Parent then
			warn("技能无法启动：角色不存在或已销毁", self.skillName)
			return
		end

		-- 验证技能输入数据
		if not self.skillInputData or not self.skillInputData.character then
			warn("技能无法启动：技能输入数据无效", self.skillName)
			return
		end

		-- 同步层快照（仅此处写入，供 StopSkill 等同步）
		self.flowState = "Running"
		self.authoritativeState = "Running"
		self:initSkillMaterial()

		-- 创建命中检测 Hitbox（委托 RuntimeHost）；可临时关闭仅客户端实例化
		if CLIENT_HITBOX_DISABLED then
			self.hitbox = {}
			self.hitboxRuntime = nil
			self._runtimeHost.hitboxRuntime = nil
		else
			self.hitbox = BaseSkillRuntimeHost.initHitbox(self._runtimeHost, self, {
				characterId = self.skillInputData.characterId,
				characterType = self.skillInputData.characterType,
				combatSeed = self.combatSeed,
			})
			self.hitboxRuntime = self._runtimeHost.hitboxRuntime
		end

		opts = opts or {}
		local pendingRun = opts.softMergeRunData
		if pendingRun and self.skillRunData then
			local runData = self.skillRunData
			if type(pendingRun.material) == "table" then
				if type(runData.material) == "table" then
					for name, model in pairs(runData.material) do
						if model then
							pcall(function()
								FXUtil.BackPool_Instance(model)
							end)
						end
						runData.material[name] = nil
					end
				else
					runData.material = {}
				end
				for name, model in pairs(pendingRun.material) do
					runData.material[name] = model
				end
			end
			if pendingRun.FadeCharacter ~= nil then
				runData["FadeCharacter"] = pendingRun.FadeCharacter
			end
			if type(pendingRun._fxFired) == "table" then
				runData._fxFired = pendingRun._fxFired
			end
			if type(pendingRun._rollingFxDirection) == "string" and pendingRun._rollingFxDirection ~= "" then
				runData._rollingFxDirection = pendingRun._rollingFxDirection
			end
			if pendingRun._rollingFxStarted == true then
				runData._rollingFxStarted = true
			end
			if type(pendingRun.runEvent) == "table" then
				runData.runEvent = runData.runEvent or {}
				for k, v in pairs(pendingRun.runEvent) do
					runData.runEvent[k] = v
				end
			end
		end

		self.skillAction:Init()

		local snap = opts.softMerge
		local mergeT = opts.softMergeInitialNowTime
		if snap and type(snap.nowTime) == "number" and type(snap.state) == "string" and snap.nowTime > 1e-4 then
			local into = snap.nowTime
			local cap = getPredictSoftMergeNowTimeCap(self.skillModule)
			if cap then
				into = math.min(into, cap)
			end
			self.nowTime = into
			local targetState = snap.state
			if not (self.skillModule.States and self.skillModule.States[targetState]) then
				targetState = self.skillModule.InitialState
			end
			-- handoff 时 _softMergeSkipEnterHandlers：不重播 OnEnter / StateActions（续跑）
			self.skillAction:startOrCatchUpAtTime(into)
			local enteredAt = type(snap.enteredAt) == "number" and snap.enteredAt or (into)
			self:EnterState(targetState, nil)
			local runData = self.skillRunData
			if runData and runData.State then
				runData.State.enteredAt = enteredAt
			end
			if not self._softMergeSkipEnterHandlers then
				SkillStateActions.enterForState(self, targetState)
			elseif self.skillModule.onSoftMergePresentationCatchUp then
				self.skillModule.onSoftMergePresentationCatchUp(self, snap)
			end
		else
			local useMerge = type(mergeT) == "number" and mergeT > 1e-4
			if useMerge then
				local into = mergeT
				local cap = getInitialStateDurationCap(self.skillModule)
				if cap then
					into = math.min(into, cap)
				end
				self.nowTime = into
				self.skillAction:startOrCatchUpAtTime(into)
				self:EnterState(self.skillModule.InitialState, nil)
				local runData = self.skillRunData
				if runData and runData.State then
					runData.State.enteredAt = self.nowTime - into
				end
				SkillStateActions.enterForState(self, self.skillModule.InitialState)
			else
				self.nowTime = 0
				self.skillAction:startOrCatchUpAtTime(0)
				self:EnterState(self.skillModule.InitialState, nil)
				SkillStateActions.enterForState(self, self.skillModule.InitialState)
			end
		end

		self._softMergeSkipEnterHandlers = false

		self.skillTimeUpdateEvent = BaseSkillRuntimeHost.startClock(self._runtimeHost, RunService, function(deltaTime)
			_skillClientClockTick(self, deltaTime, false)
		end)
	end

	--[[
		表现预测：无 Hitbox；按 StateTimeout 跨态推进至 ControlOpenState（或无 ControlOpen 时 InitialState 结束后）hold。
		组技能由 GroupSkillClient 创建独立临时 BaseSkillClient，正式 BaseSkillStarted 前销毁或 soft-merge。
	]]
	function BaseSkillClient.skillStartPresentationPredict(self: BaseSkillClient)
		if self._destroyed or self:isRunningFlow() then return end

		assert(self.skillModule.States and self.skillModule.InitialState,
			("[BaseSkillClient] %s 必须定义 States + InitialState（仅支持状态机范式）"):format(self.skillName))

		self.runGeneration = (self.runGeneration or 0) + 1

		if not self.character or not self.character.Parent then
			return
		end
		if not self.skillInputData or not self.skillInputData.character then
			return
		end

		self.flowState = "Running"
		self.authoritativeState = "Running"
		self._presentationPredictActive = true
		self._presentationPredictHold = false

		self:initSkillMaterial()

		self.skillAction:Init()
		self.nowTime = 0
		self.skillAction:startOrCatchUpAtTime(0)
		self:EnterState(self.skillModule.InitialState, nil)
		SkillStateActions.enterForState(self, self.skillModule.InitialState)

		self.skillTimeUpdateEvent = BaseSkillRuntimeHost.startClock(self._runtimeHost, RunService, function(deltaTime)
			_skillClientClockTick(self, deltaTime, true)
		end)
	end
end
