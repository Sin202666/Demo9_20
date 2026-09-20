--[[
	Module: BaseSkillClient.Clock
	Description: 表现/逻辑时间轴对齐修正与每帧时钟 tick（由 BaseSkillClient/init 挂载，业务勿直接 require）
	Author: 林奥宇
	Created: 2026-08-18
	Last Modified: 2026-08-18

	功能：
	- setSkillTimeFix：注入待消化的时间差（正=表现慢于逻辑）
	- 自适应修正率：按 |差| 在 10%~90% 间插值，单帧注入硬上限 0.06s
	- tick：正式技能与表现预测共用；预测在 ControlOpen / Phase1 后 hold

	与 init / Start / Lifecycle：
	- 业务只调 BaseSkillClient 实例方法，不要直接 require 本文件
	- 时钟仍经 RuntimeHost.startClock 注册，不在本模块 Connect Heartbeat
	- Start 的 skillStart / skillStartPresentationPredict 闭包调用本模块返回的 tick
]]

local Class = require(game.ReplicatedFirst.AllSideCode.Class.Class)
local SkillControlRuntime = require(script.Parent.Parent.SkillControlRuntime)
local SkillEventConst = require(script.Parent.Parent.SkillEventConst)
local SkillStateMachine = require(script.Parent.Parent.SkillStateMachine)
local SkillStateActions = require(script.Parent.Parent.SkillStateActions)

type BaseSkillClient = Class.BaseSkillClient

--表现时间轴与逻辑时间轴对齐修正配置
--自适应修正率：根据时间差大小动态调整修正率
local TIME_SYNC_CONFIG = {
	MIN_FIX_RATE = 0.1,           -- 最小修正率（小时间差时使用，平滑修正）
	MAX_FIX_RATE = 0.9,           -- 最大修正率（大时间差时使用，快速修正）
	SMALL_DIFF_THRESHOLD = 0.1,   -- 小时间差阈值（秒）
	LARGE_DIFF_THRESHOLD = 0.5,   -- 大时间差阈值（秒）
	MAX_APPLIED_FIX_PER_FRAME = 0.06,  -- 单帧可注入修正量硬上限，防止同步异常导致时间突跳
}

--[[
    计算自适应修正率
    根据时间差大小动态调整修正率：
    - 大时间差（>0.5秒）：快速修正（90%）
    - 中等时间差（0.1-0.5秒）：线性插值（10%-90%）
    - 小时间差（<0.1秒）：平滑修正（10%）
    @param timeDiff: number 时间差值
    @return number 修正率（0-1）
]]
local function calculateAdaptiveFixRate(timeDiff: number): number
	local absDiff = math.abs(timeDiff)
	local config = TIME_SYNC_CONFIG

	if absDiff > config.LARGE_DIFF_THRESHOLD then
		-- 大时间差：快速修正（90%）
		return config.MAX_FIX_RATE
	elseif absDiff > config.SMALL_DIFF_THRESHOLD then
		-- 中等时间差：线性插值
		local ratio = (absDiff - config.SMALL_DIFF_THRESHOLD) / 
			(config.LARGE_DIFF_THRESHOLD - config.SMALL_DIFF_THRESHOLD)
		return config.MIN_FIX_RATE + (config.MAX_FIX_RATE - config.MIN_FIX_RATE) * ratio
	else
		-- 小时间差：平滑修正（10%）
		return config.MIN_FIX_RATE
	end
end

--[[
	客户端时钟 tick（正式技能 / 表现预测共用）
	@param presentationPredict boolean
		true=无 Hitbox 预测：Duration 走 StateTimeout 跨态；进入 ControlOpen/Phase1 后 hold，不再切态
]]
local function _skillClientClockTick(self: BaseSkillClient, deltaTime: number, presentationPredict: boolean)
	if self._destroyed then return end

	if self.skillTimeFix ~= 0 then
		local fixRate = calculateAdaptiveFixRate(self.skillTimeFix)
		local rawFixDelta = deltaTime * fixRate
		local fixDeltaTime = math.min(rawFixDelta, TIME_SYNC_CONFIG.MAX_APPLIED_FIX_PER_FRAME)
		local fixDirection = self.skillTimeFix > 0 and 1 or -1

		if math.abs(self.skillTimeFix) > math.abs(fixDeltaTime) then
			self.skillTimeFix = self.skillTimeFix - (fixDeltaTime * fixDirection)
			deltaTime = deltaTime + (fixDeltaTime * fixDirection)
		else
			local clampedFix = math.min(math.abs(self.skillTimeFix), TIME_SYNC_CONFIG.MAX_APPLIED_FIX_PER_FRAME) * fixDirection
			deltaTime = deltaTime + clampedFix
			self.skillTimeFix = self.skillTimeFix - clampedFix
		end

		if math.abs(self.skillTimeFix) < 0.001 then
			self.skillTimeFix = 0
		end
	end

	self.nowTime += deltaTime * self.skillPlaySpeed

	local runData = self.skillRunData
	local stateConfig = self.skillModule.States and self.skillModule.States[runData.State.current]

	if presentationPredict then
		SkillControlRuntime.update(self.controlRuntime, self.nowTime, self)
		self.isPhase1Complete = self.controlRuntime.isPhase1Complete
		self.isControlReleased = self.controlRuntime.isControlReleased

		local sm = self.skillModule
		local current = runData.State and runData.State.current
		local openState = sm.ControlOpenState

		if not self._presentationPredictHold then
			if openState and current == openState then
				self._presentationPredictHold = true
			elseif SkillControlRuntime.getState(self.controlRuntime) ~= "Locked" then
				self._presentationPredictHold = true
			elseif stateConfig and SkillStateMachine.shouldStateTimeout(stateConfig, runData.State.enteredAt, self.nowTime) then
				if openState then
					self:TryTransition(SkillEventConst.StateTimeout, nil)
					if not self:isRunningFlow() then return end
					local cur2 = self.skillRunData.State and self.skillRunData.State.current
					if cur2 == openState or SkillControlRuntime.getState(self.controlRuntime) ~= "Locked" then
						self._presentationPredictHold = true
					end
				else
					-- 无 ControlOpenState：跑完 InitialState 后 hold，不进入后续战斗态
					self._presentationPredictHold = true
				end
			end
		end

		self.skillAction:Run(self.nowTime)
		SkillStateActions.run(self, self.nowTime)
		return
	end

	if stateConfig and SkillStateMachine.shouldStateTimeout(stateConfig, runData.State.enteredAt, self.nowTime) then
		self:TryTransition(SkillEventConst.StateTimeout, nil)
		if not self:isRunningFlow() then return end
	end

	self.skillAction:Run(self.nowTime)
	SkillStateActions.run(self, self.nowTime)

	SkillControlRuntime.update(self.controlRuntime, self.nowTime, self)
	self.isPhase1Complete = self.controlRuntime.isPhase1Complete
	self.isControlReleased = self.controlRuntime.isControlReleased
end

--[[
	挂载时钟 API 到 BaseSkillClient 类表，并返回每帧 tick（供 Start 闭包调用）。
	@param BaseSkillClient table - 与 init 同一份类表
	@return (self: BaseSkillClient, deltaTime: number, presentationPredict: boolean) -> () - 原 _skillClientClockTick
]]
return function(BaseSkillClient)
	--[[
	    表现时间轴与逻辑时间轴对齐修正
	    @param self: BaseSkillClient 基础技能对象
	    @param deltaTime: number 时间差值
	]]
	function BaseSkillClient.setSkillTimeFix(self: BaseSkillClient,deltaTime: number)
		--表现时间轴慢了或快了
		self.skillTimeFix = deltaTime
	end

	return _skillClientClockTick
end
