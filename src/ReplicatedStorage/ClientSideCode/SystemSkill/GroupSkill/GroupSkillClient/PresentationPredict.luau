--[[
	Module: GroupSkillClient.PresentationPredict
	Description: 组技能表现预测：启动、超时、软合并快照、清理（由 GroupSkillClient/init 挂载，业务勿直接 require）
	Author: 林奥宇
	Created: 2026-08-18
	Last Modified: 2026-08-18

	功能：
	- _tryStartPresentationPredict：首段 BaseSkill 无 Hitbox 本地模拟至 ControlOpen/Phase1 hold
	- _takePresentationPredictSoftMergeSnapshot：须在 clear 之前取出 nowTime+state
	- _getFirstBaseSkillPredictNowTimeCap / _getPresentationPredictTimeoutSec
	- clearPresentationPredict：拒释、正式开始前、销毁；clearCastTracking=false 时保留追踪 id

	与 Input / InstanceFactory：
	- 业务只调 GroupSkillClient 实例方法
	- onInputBegan 写 clientPredictCastId 后调 tryStart；Factory 在建实例前 take 快照再 clear
]]

local Class = require(game.ReplicatedFirst.AllSideCode.Class.Class)
local BaseSkillClientModule = require(script.Parent.Parent.Parent.BaseSkill.BaseSkillClient)
local BaseSkillDefinitionLoader = require(script.Parent.Parent.Parent.BaseSkill.BaseSkillDefinitionLoader)

type GroupSkillClient = typeof(Class.GroupSkillClient)

--[[
	挂载表现预测 API 到 GroupSkillClient 类表。
	@param GroupSkillClient table - 与 init 同一份类表
	@return () - 无返回值
]]
return function(GroupSkillClient)
	--[[
		结束表现预测（Remote 拒绝、正式 BaseSkillStarted 前、销毁等）
		@param clearCastTracking boolean? 默认 true：清空 _lastPresentationPredictCastId / 时钟（拒绝、超时、合并收尾）。
			传 false 时仅拆掉旧预测实例，保留追踪 id（供 onInputBegan 刚写入的 clientPredictCastId 与服务器确认对齐）。
	]]
	function GroupSkillClient.clearPresentationPredict(self: GroupSkillClient, clearCastTracking: boolean?)
		local wipeTracking = clearCastTracking ~= false
		local p = self._presentationPredict
		if not p then
			if wipeTracking then
				self._lastPresentationPredictCastId = nil
				self._presentationPredictStartClock = nil
			end
			return
		end
		self._presentationPredict = nil
		if p.client then
			p.client:destroy("Interrupted", true)
		end
		if type(p.cleanup) == "function" then
			p.cleanup()
		end
		if wipeTracking then
			self._lastPresentationPredictCastId = nil
			self._presentationPredictStartClock = nil
		end
	end

	--[[
		首段 BaseSkill：InitialState→ControlOpenState（若无则仅 InitialState）路径 Duration 累计上限
	]]
	function GroupSkillClient._getFirstBaseSkillPredictNowTimeCap(self: GroupSkillClient): number?
		local mod = self.groupSkillModule
		local c = mod.Skill and mod.Skill[1]
		if not c or type(c.baseSkillName) ~= "string" then
			return nil
		end
		local def, _err = BaseSkillDefinitionLoader.load(c.baseSkillName)
		local sm = def and def.skillModule
		if not sm or not sm.States or not sm.InitialState then
			return nil
		end
		local states = sm.States
		local transitions = sm.Transitions or {}
		local openState = sm.ControlOpenState
		local current = sm.InitialState
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
				return (type(dur) == "number" and dur >= 0) and dur or sum
			end
			local nextState = nil
			for _, rule in ipairs(transitions) do
				if rule.From == current and rule.Event == "StateTimeout" then
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
		预测超时秒数：路径 cap + 余量；下限 0.8、上限 3
	]]
	function GroupSkillClient._getPresentationPredictTimeoutSec(self: GroupSkillClient): number
		local cap = self:_getFirstBaseSkillPredictNowTimeCap()
		if type(cap) == "number" and cap > 0 then
			return math.clamp(cap + 0.35, 0.8, 3)
		end
		return 1.2
	end

	--[[
		与确认 castId 对齐时取出软合并快照；须在 clearPresentationPredict 之前调用
		@return { nowTime: number, state: string, enteredAt: number }?
	]]
	function GroupSkillClient._takePresentationPredictSoftMergeSnapshot(self: GroupSkillClient, confirmCastId: string): { nowTime: number, state: string, enteredAt: number }?
		if not confirmCastId or confirmCastId ~= self._lastPresentationPredictCastId then
			return nil
		end
		if not self.groupSkillModule.Data.predictPresentation then
			return nil
		end
		local cap = self:_getFirstBaseSkillPredictNowTimeCap()
		local elapsed = 0
		local stateName = nil
		local enteredAt = nil
		local p = self._presentationPredict
		if p and p.client then
			elapsed = p.client.nowTime
			local st = p.client.skillRunData and p.client.skillRunData.State
			if st then
				stateName = st.current
				enteredAt = st.enteredAt
			end
		end
		if elapsed < 1e-3 and self._presentationPredictStartClock then
			elapsed = os.clock() - self._presentationPredictStartClock
		end
		if cap then
			elapsed = math.min(elapsed, cap)
		end
		if elapsed < 1e-4 then
			return nil
		end
		if type(stateName) ~= "string" then
			local c = self.groupSkillModule.Skill and self.groupSkillModule.Skill[1]
			local def = c and BaseSkillDefinitionLoader.load(c.baseSkillName)
			stateName = def and def.skillModule and def.skillModule.InitialState or "Startup"
			enteredAt = 0
		end
		if type(enteredAt) ~= "number" then
			enteredAt = elapsed
		end
		return {
			nowTime = elapsed,
			state = stateName,
			enteredAt = enteredAt,
		}
	end

	--[[
		表现预测：Data.predictPresentation 时启动首段 BaseSkill 本地模拟（无 Hitbox，推至 ControlOpen 后 hold）
	]]
	function GroupSkillClient._tryStartPresentationPredict(self: GroupSkillClient, clientPredictCastId: string, snapshot: { releaseCF: CFrame, targetCF: CFrame, moveDirectionStr: string?, trackTargetId: any?, skillTargetData: any? })
		-- 只清旧预测实例，勿清 _lastPresentationPredictCastId（已在 onInputBegan 设为本次 clientPredictCastId）
		self:clearPresentationPredict(false)
		local mod = self.groupSkillModule
		local data = mod and mod.Data
		if not data or not data.predictPresentation then
			return
		end
		local firstConfig = mod.Skill and mod.Skill[1]
		if not firstConfig or type(firstConfig.baseSkillName) ~= "string" then
			return
		end

		local ok, err = pcall(function()
			local predictClient = BaseSkillClientModule.new(
				firstConfig.baseSkillName,
				self.characterId,
				self.characterType,
				self.skillPower,
				self.skillPurity,
				{ skillID = self.skillID, mpTp = self.mpTp }
			)
			predictClient:setSkillInputData(
				self.characterId,
				self.characterType,
				snapshot.releaseCF,
				snapshot.targetCF,
				snapshot.moveDirectionStr,
				clientPredictCastId,
				clientPredictCastId .. "_B1",
				1,
				snapshot.trackTargetId,
				snapshot.skillTargetData
			)
			predictClient.combatSeed = self.combatSeed or 0
			predictClient:skillStartPresentationPredict()

			self._presentationPredictEpoch += 1
			local epoch = self._presentationPredictEpoch
			self._presentationPredict = { client = predictClient, epoch = epoch }
			local timeoutSec = self:_getPresentationPredictTimeoutSec()
			task.delay(timeoutSec, function()
				local cur = self._presentationPredict
				if cur and cur.epoch == epoch and cur.client == predictClient then
					self:clearPresentationPredict()
				end
			end)
		end)

		if not ok then
			warn("[GroupSkillClient] 表现预测启动失败:", self.skillName, err)
		end
	end
end
