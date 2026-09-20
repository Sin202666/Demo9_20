--[[
	技能行为状态枚举与最小基类
	【定位】StateEnum 为框架正式层；Start/Over 为子类可覆写钩子，基类留空
	【注意】Phase1 完成由 SkillAction 驱动各具体 Action（Animation、DashStyleRoll、LockMovement 等）的 state 判定，
	        本模块不直接参与 Phase1Complete，仅提供状态常量与 Run 模板。
	【Gate】技能位移 Action 必须以 DashStyleRoll 为模板（SkillActionLock + ActionArbiter + CharacterMotion +
	        CameraImpulse）；禁止再引入裸 BodyVelocity / 直写 WalkSpeed / 旁路 FOV Helper 的翻滚类 Action。

	【约束】Over/Destroy 幂等，不依赖先 Start 再 Over：
	- Over() 幂等：多次调用安全，未 Start 时调用也安全
	- Destroy() 幂等：多次调用安全，内部会调用 Over 确保清理

	【同角色并行】skillModule.Action 单项可设 allowParallelTracks（默认 true）：
	- 为 false 时，同 character + 同 action 类型在新区间 Start 前会先 Over 已登记的旧实例，并在本实例 Over 时释放登记（见 SkillActionExclusive）。
]]
local SkillActionExclusive = require(script.Parent.SkillAction.SkillActionExclusive)

local SkillActionControl = {
	StateEnum = {
		NoStart = 1,
		Play = 2,
		Over = 3,
	},
	skill = nil,
	skillTimeLine = nil,
	startTime = 0,
	overTime = 0,
}

function SkillActionControl:Init()
	self.state = SkillActionControl.StateEnum.NoStart
	self._destroyed = false
end

-- 子类可覆写：进入播放时回调
function SkillActionControl:Start(time_: number) end

-- 子类可覆写：结束时实际逻辑（不依赖 Start 一定被调用过）
function SkillActionControl:OnOver(time_: number) end

-- 幂等 Over：多次调用安全，未 Start 时调用也安全
function SkillActionControl:Over(time_: number)
	if self.state == SkillActionControl.StateEnum.Over then
		return
	end
	SkillActionExclusive.releaseIfOwner(self)
	self.state = SkillActionControl.StateEnum.Over
	self:OnOver(time_)
end

-- 幂等 Destroy：多次调用安全，内部调用 Over 确保清理
function SkillActionControl:Destroy()
	if self._destroyed then
		return
	end
	self._destroyed = true
	self:Over(0)
end

function SkillActionControl:Run(time_:number)

	if self.state == SkillActionControl.StateEnum.NoStart then
		if self.startTime < time_ then
			self:Start(time_)
			self.state = SkillActionControl.StateEnum.Play
		end

	elseif self.state == SkillActionControl.StateEnum.Play then
		if self.overTime >= 0 and self.overTime < time_ then
			self:Over(time_)
		end

	end

end
return SkillActionControl

