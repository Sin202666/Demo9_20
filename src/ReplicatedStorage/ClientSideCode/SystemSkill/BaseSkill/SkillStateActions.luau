--[[
	方向一：状态绑定 SkillAction
	module.StateActions[stateName] = { { action = "Animation", startTime?, overTime?, ... }, ... }
	• startTime / overTime：相对「进入该状态时 skillRunData.State.enteredAt」的偏移（秒）。
	• overTime 为 nil 或 < 0：不按技能时钟结束，仅在退出该状态时 Over/Destroy。
	实例通过 BaseSkillClient：TryTransition 前后、skillStart 首态、收尾路径驱动。
]]

local SkillActionFolder: Folder = script.Parent.SkillAction
local SkillActionControl = require(script.Parent.SkillActionControl)
local SkillActionExclusive = require(script.Parent.SkillAction.SkillActionExclusive)
local ReleasePlayerOnlyPolicy = require(script.Parent.ReleasePlayerOnlyPolicy)

local SkillStateActions = {}

type Stored = {
	activeStateName: string?,
	instances: { any },
}

local function getStore(baseSkill): Stored
	local rd = baseSkill.skillRunData
	if not rd then
		error("[SkillStateActions] skillRunData 缺失")
	end
	if not rd._skillStateActions then
		rd._skillStateActions = {
			activeStateName = nil,
			instances = {},
		}
	end
	return rd._skillStateActions :: Stored
end

--[[
	相对于状态进入点 → 技能累加时钟上的 [gStart, gEnd)；gEnd<0 表示无限
]]
local function toGlobalTimeline(stateEnteredAt: number, actionInfo: any): (number, number)
	local relS = tonumber(actionInfo.startTime) or 0
	local relEnd = actionInfo.overTime
	local gStart = stateEnteredAt + relS
	local gEnd: number
	if type(relEnd) ~= "number" then
		gEnd = -1
	elseif relEnd < 0 then
		gEnd = -1
	elseif relEnd < relS then
		gEnd = gStart + 1e-3
	else
		gEnd = stateEnteredAt + relEnd
	end
	return gStart, gEnd
end

local function buildInstancesForState(baseSkill, stateName: string): { any }
	local out: { any } = {}
	local desc = baseSkill.skillModule.StateActions and baseSkill.skillModule.StateActions[stateName]
	if type(desc) ~= "table" then
		return out
	end

	for _, src in ipairs(desc) do
		if type(src) == "table" then
			local actionInfo = table.clone(src :: any)

			local t0 = (baseSkill.skillRunData and baseSkill.skillRunData.State and baseSkill.skillRunData.State.enteredAt)
				or baseSkill.nowTime
			local gStart, gEnd = toGlobalTimeline(t0, actionInfo)
			actionInfo.startTime = gStart
			actionInfo.overTime = gEnd

			local typename = actionInfo.action
			if type(typename) ~= "string" then
				warn("[SkillStateActions]", baseSkill.skillName, stateName, "Action 条目缺少 action 字段")
			else
				local node = SkillActionFolder:FindFirstChild(typename)
				if node and node:IsA("ModuleScript") then
					local mod = require(node)
					local action = setmetatable(table.clone(mod), { __index = SkillActionControl })
					local skipPlayerSubjectOnly = action.playerSubjectOnly and ReleasePlayerOnlyPolicy.isMonsterOrSyncedNonPlayerSubjectSkill(baseSkill)
					if skipPlayerSubjectOnly then
						-- 如 LookAt：仅玩家施法者需要
					elseif action.isReleasePlayerOnly and not ReleasePlayerOnlyPolicy.shouldRunReleasePlayerOnlyActions(baseSkill) then
						-- 玩家主体：仅施法者客户端；怪物/非玩家主体：各同步客户端均创建
					else
						action.baseSkill = baseSkill
						action.actionInfo = actionInfo
						action._skillStateOwned = stateName
						if action.Create then
							action:Create(actionInfo)
						end
						table.insert(out, action)
					end
				else
					warn("[SkillStateActions]", baseSkill.skillName, stateName, "未知 Action:", typename)
				end
			end
		end
	end
	return out
end

function SkillStateActions.exitForState(baseSkill, stateName: string?)
	if baseSkill._destroyed or not stateName then
		return
	end
	local rd = baseSkill.skillRunData
	if not rd or not rd._skillStateActions then
		return
	end
	local store = rd._skillStateActions :: Stored
	if store.activeStateName ~= stateName then
		return
	end
	for _, action in ipairs(store.instances) do
		pcall(function()
			action:Destroy()
		end)
	end
	store.instances = {}
	store.activeStateName = nil
end

function SkillStateActions.enterForState(baseSkill, stateName: string?)
	if baseSkill._destroyed then
		return
	end
	if not stateName or type(baseSkill.skillModule.StateActions) ~= "table" then
		return
	end
	local rd = baseSkill.skillRunData
	if not rd or not rd.State then
		return
	end

	local store = getStore(baseSkill)
	if store.activeStateName == stateName and #store.instances > 0 then
		return
	end

	SkillStateActions.exitForState(baseSkill, store.activeStateName :: any)

	store.instances = buildInstancesForState(baseSkill, stateName)
	store.activeStateName = stateName
	if #store.instances == 0 then
		store.activeStateName = nil
		return
	end

	for _, action in ipairs(store.instances) do
		action:Init()
		action._destroyed = false
	end

	local cumulativeTime = baseSkill.nowTime
	for _, action in ipairs(store.instances) do
		SkillActionExclusive.beforeStart(action)
		action:Start(cumulativeTime)
		action.state = SkillActionControl.StateEnum.Play
	end
end

function SkillStateActions.run(baseSkill, cumulativeTime: number)
	local rd = baseSkill.skillRunData
	if not rd or not rd._skillStateActions then
		return
	end
	local store = rd._skillStateActions :: Stored
	local instances = store.instances

	for _, action in ipairs(instances) do
		if action.state == SkillActionControl.StateEnum.NoStart then
			if cumulativeTime >= (action.startTime or 0) then
				local ot = action.overTime
				local infinite = ot == nil or type(ot) ~= "number" or ot < 0
				if infinite or cumulativeTime < ot then
					SkillActionExclusive.beforeStart(action)
					action:Start(cumulativeTime)
					action.state = SkillActionControl.StateEnum.Play
				end
			end
		elseif action.state == SkillActionControl.StateEnum.Play then
			local ot = action.overTime
			local infinite = ot == nil or type(ot) ~= "number" or ot < 0
			if not infinite and ot > 0 and cumulativeTime >= ot then
				action:Over(cumulativeTime)
			else
				if action.Run then
					action:Run(cumulativeTime)
				end
			end
		end
	end
end

function SkillStateActions.overAll(baseSkill, cumulativeTime: number?)
	local t = cumulativeTime or baseSkill.nowTime
	local rd = baseSkill.skillRunData
	if baseSkill._destroyed or not rd or not rd._skillStateActions then
		return
	end
	local store = rd._skillStateActions :: Stored
	for _, action in ipairs(store.instances) do
		pcall(function()
			action:Over(t)
		end)
	end
end

function SkillStateActions.destroyAll(baseSkill)
	local rd = baseSkill.skillRunData
	if not rd or not rd._skillStateActions then
		return
	end
	local store = rd._skillStateActions :: Stored
	for _, action in ipairs(store.instances) do
		pcall(function()
			action:Destroy()
		end)
	end
	store.instances = {}
	store.activeStateName = nil
end

--[[
	并入 Phase1 的可选判定：需在 BaseSkill RuntimeHost 勾选 phase1UsesStateActions。
]]
function SkillStateActions.areAllOver(baseSkill): boolean
	local rd = baseSkill.skillRunData
	if not rd or not rd._skillStateActions then
		return true
	end
	for _, action in ipairs((rd._skillStateActions :: Stored).instances) do
		if action.state ~= SkillActionControl.StateEnum.Over then
			return false
		end
	end
	return true
end

return SkillStateActions
