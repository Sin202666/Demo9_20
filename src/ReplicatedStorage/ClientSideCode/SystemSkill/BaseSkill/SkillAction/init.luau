--[[
	技能行为模块处理器
	用来控制基础技能中的技能行为拓展 比如：让玩家禁止移动 并且朝向始终朝向目标等
	所有行为模块都包含 Create Init Start OnOver 四个方法对应 创建 初始化 开始 结束时调用
	Over/Destroy 幂等，不依赖先 Start 再 Over
]]
--引用Class
local Class = require(game.ReplicatedFirst.AllSideCode.Class.Class)
local SkillActionControl = require(script.Parent.SkillActionControl)
local SkillActionExclusive = require(script.SkillActionExclusive)
local ReleasePlayerOnlyPolicy = require(script.Parent.ReleasePlayerOnlyPolicy)
local AnimationPlaySide = require(script.Parent.AnimationPlaySide)

type BaseSkillClient = typeof(Class.BaseSkillClient)

export type SkillActionNewOptions = {
	--[[ 服务端：仅实例化 Animation，且忽略 isReleasePlayerOnly 的客户端策略 ]]
	serverMode: boolean?,
}

--行为文件夹
local SkillActionFolder:Folder = script.Parent.SkillAction
local SkillAction = {}
SkillAction.__index = SkillAction

--[[
    创建技能行为处理对象
	判断行为模块运行环境条件是不是只有技能释放者客户端运行
    @param self: SkillAction 技能行为对象
    @param skillName: string 技能名称
    @return SkillAction 技能行为对象
]]
function SkillAction.new(baseSkill: BaseSkillClient, options: SkillActionNewOptions?)
	local self = setmetatable({}, SkillAction)
	options = options or {}
	local serverMode = options.serverMode == true

	self.allActions = {}
	--初始化所有行为的模块
	local actions = baseSkill.skillModule.Action or {}
	for _, actionInfo in actions do
		if serverMode then
			if actionInfo.action ~= "Animation" then
				continue
			end
		elseif actionInfo.action == "Animation" and AnimationPlaySide.shouldSkipClientAnimation(baseSkill) then
			continue
		end
		local mod = require(SkillActionFolder[actionInfo.action])
		local action = setmetatable(table.clone(mod), { __index = SkillActionControl })
		if action.playerSubjectOnly and ReleasePlayerOnlyPolicy.isMonsterOrSyncedNonPlayerSubjectSkill(baseSkill) then
			continue
		end
		if not serverMode and action.isReleasePlayerOnly and not ReleasePlayerOnlyPolicy.shouldRunReleasePlayerOnlyActions(baseSkill) then
			continue
		end
		action.baseSkill = baseSkill
		action.actionInfo = actionInfo
		if action.Create then
			action:Create(actionInfo)
		end
		table.insert(self.allActions, action)
	end

	return self
end

--[[
    初始化技能行为
]]
function SkillAction:Init()
	for _, action in self.allActions do
		action:Init()
		action._destroyed = false
	end
end

--[[
    开始技能行为
    @param cumulativeTime: number 累积时间
]]
function SkillAction:Start(cumulativeTime: number)
	for _, action in self.allActions do
		SkillActionExclusive.beforeStart(action)
		action:Start(cumulativeTime)
		action.state = SkillActionControl.StateEnum.Play
	end
end

--[[
	从累积时间 t 切入（预测软合并）：按各 Action 的 startTime/overTime 设置 NoStart / Play / Over，并补一次 Run(t) 对齐朝向等
]]
function SkillAction:startOrCatchUpAtTime(t: number)
	local StateEnum = SkillActionControl.StateEnum
	for _, action in self.allActions do
		local st = action.startTime or 0
		local ot = action.overTime
		local softMerge = action.baseSkill and action.baseSkill._softMergeSkipEnterHandlers == true
		if type(ot) == "number" and ot > 0 and t >= ot then
			if softMerge then
				-- 禁止 Start+立刻 Over（会重入锁/动画再拆导致跳变与二次冲量）
				SkillActionExclusive.beforeStart(action)
				if action.softMergeCatchUpPastOver then
					action:softMergeCatchUpPastOver(t)
				end
				action.state = StateEnum.Over
			else
				SkillActionExclusive.beforeStart(action)
				action:Start(t)
				action:Over(t)
				action.state = StateEnum.Over
			end
		elseif t >= st then
			SkillActionExclusive.beforeStart(action)
			action:Start(t)
			action.state = StateEnum.Play
			if action.Run then
				action:Run(t)
			end
			if type(ot) == "number" and ot > 0 and t >= ot then
				action:Over(t)
				action.state = StateEnum.Over
			end
		else
			action.state = StateEnum.NoStart
		end
	end
end

--[[
    结束技能行为（幂等，不依赖先 Start）
    @param cumulativeTime: number 累积时间
]]
function SkillAction:Over(cumulativeTime: number)
	for _, action in self.allActions do
		action:Over(cumulativeTime)
	end
end

--[[
    销毁技能行为（幂等，内部调用 Over 确保清理）
]]
function SkillAction:Destroy()
	for _, action in self.allActions do
		action:Destroy()
	end
end

--[[
    检查所有行为是否都已结束（Phase 1 完成判定）
    @return boolean 所有 Action 是否都已 Over
]]
function SkillAction:AreAllActionsOver()
	for _, action in self.allActions do
		if action.state ~= SkillActionControl.StateEnum.Over then
			return false
		end
	end
	return true
end

--[[
    运行技能行为
	更新行为状态 保证行为状态在指定时间内运行
    @param cumulativeTime: number 累积时间
]]
function SkillAction:Run(cumulativeTime: number)
	for _, action in self.allActions do
		if action.state == SkillActionControl.StateEnum.NoStart then
			if cumulativeTime >= action.startTime and cumulativeTime < action.overTime then
				SkillActionExclusive.beforeStart(action)
				action:Start(cumulativeTime)
				action.state = SkillActionControl.StateEnum.Play
			end
		elseif action.state == SkillActionControl.StateEnum.Play then
			if action.overTime > 0 and cumulativeTime >= action.overTime then
				action:Over(cumulativeTime)
			else
				action:Run(cumulativeTime)
			end
		end
	end
end


return SkillAction
