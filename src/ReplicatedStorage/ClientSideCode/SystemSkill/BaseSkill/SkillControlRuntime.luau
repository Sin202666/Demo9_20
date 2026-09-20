--[[
	控制权运行时（技能宿主组件）
	职责：Phase 1 完成判定、控制权释放、getControlState
	与状态机解耦：控制权是技能组派生/阻塞逻辑，不是状态机的一部分

	调用方：BaseSkillServer / BaseSkillClient 在 tick 中 update，getControlState / releaseControl 代理到此
]]

local SkillControlRuntime = {}

--[[
	计算 Action 最大 overTime（服务端无 skillAction 时的 Phase 1 回退）
	@param skillModule table 技能模块
	@return number
]]
local function calculateMaxActionOverTime(skillModule)
	local maxOverTime = 0
	local actions = skillModule.Action or {}
	for _, actionInfo in actions do
		if actionInfo and actionInfo.overTime and actionInfo.overTime > maxOverTime then
			maxOverTime = actionInfo.overTime
		end
	end
	return maxOverTime
end

--[[
	创建控制权运行时数据
	@param skillModule table 技能模块
	@param options table? { isClient = boolean, getActionsOverCheck = function() -> boolean } 客户端需传 getActionsOverCheck
	@return table controlData
]]
function SkillControlRuntime.create(skillModule, options)
	options = options or {}
	return {
		isPhase1Complete = false,
		isControlReleased = false,
		maxActionOverTime = calculateMaxActionOverTime(skillModule),
		openedAt = nil,
		releasedAt = nil,
		_isClient = options.isClient,
		_getActionsOverCheck = options.getActionsOverCheck,
	}
end

--[[
	更新 Phase 1 完成判定
	优先级：CanReleaseControl > ControlOpenState > 时间/Action Over
	@param controlData table 由 create 返回
	@param nowTime number
	@param skillInstance table 技能实例（提供 skillModule, skillRunData, skillAction[Client]）
]]
function SkillControlRuntime.update(controlData, nowTime, skillInstance)
	if controlData.isPhase1Complete then return end

	local justOpened = false
	local sm = skillInstance.skillModule

	-- 按住持续类：Phase1 完成仅由 CanReleaseControl 决定（避免 maxActionOverTime 在长按中提前结束 Phase1）
	if sm.SustainHoldDelaysPhase1Complete == true then
		if type(sm.CanReleaseControl) == "function" and sm.CanReleaseControl(skillInstance) then
			controlData.isPhase1Complete = true
			justOpened = true
		end
		if justOpened and not controlData.openedAt then
			controlData.openedAt = nowTime
		end
		return
	end

	if type(sm.CanReleaseControl) == "function" and sm.CanReleaseControl(skillInstance) then
		controlData.isPhase1Complete = true
		justOpened = true
	elseif sm.ControlOpenState and skillInstance.skillRunData and skillInstance.skillRunData.State and skillInstance.skillRunData.State.current == sm.ControlOpenState then
		controlData.isPhase1Complete = true
		justOpened = true
	elseif controlData._getActionsOverCheck then
		if controlData._getActionsOverCheck() then
			controlData.isPhase1Complete = true
			justOpened = true
		end
	else
		-- Action 为空时 maxActionOverTime=0，不可在首帧放权；有 ControlOpenState 的须等状态机进入该态
		if controlData.maxActionOverTime > 0 and nowTime >= controlData.maxActionOverTime then
			controlData.isPhase1Complete = true
			justOpened = true
		end
	end

	if justOpened and not controlData.openedAt then
		controlData.openedAt = nowTime
	end
end

--[[
	获取控制权状态
	@param controlData table
	@return "Locked" | "ChainOpen" | "Released"
]]
function SkillControlRuntime.getState(controlData)
	if controlData.isControlReleased then return "Released" end
	if not controlData.isPhase1Complete then return "Locked" end
	return "ChainOpen"
end

--[[
	释放控制权
	@param controlData table
	@param nowTime number? 释放时刻（用于 releasedAt）
]]
function SkillControlRuntime.release(controlData, nowTime)
	controlData.isControlReleased = true
	if nowTime ~= nil then
		controlData.releasedAt = nowTime
	end
end

--[[
	重置控制权数据（_finish / skillEnd 时调用）
	@param controlData table
]]
function SkillControlRuntime.reset(controlData)
	controlData.isPhase1Complete = false
	controlData.isControlReleased = false
	controlData.openedAt = nil
	controlData.releasedAt = nil
end

--[[
	跨槽打断等：不结束状态机，仅将控制权视为「Action 已结束」并放权（服务端无 skillAction 时用）
]]
function SkillControlRuntime.forceMarkPhase1CompleteAndRelease(controlData, nowTime: number?)
	local t = nowTime or 0
	controlData.isPhase1Complete = true
	if not controlData.openedAt then
		controlData.openedAt = t
	end
	SkillControlRuntime.release(controlData, t)
end

return SkillControlRuntime
