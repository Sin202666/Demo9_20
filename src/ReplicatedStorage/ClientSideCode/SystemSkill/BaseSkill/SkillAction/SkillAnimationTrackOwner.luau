--[[
	同 Animator + 同 animationName 的轨道归属登记。

	多技能可共用一条 AnimationTrack（如主动技与冲刺都播 RollForward）：
	- Start / Play 时 claim：本实例成为唯一可 StopAnim 的 owner
	- OnOver 仅当 isOwner 时才 StopAnim，否则只 release，避免打断衔接后误停新技能
	- PlayAnim 同轨重占由 TrackCache 强制 Stop(0)+从头 Play，不继承上一段 TimePosition

	典型链路：E 播 RollForward → Q 跨槽打断 E（本地 interrupt）→ Q claim + 同轨重播 → E 晚到 OnOver 因非 owner 不停轨。
]]

-- [Animator] = { [animationName: string] = ownerAction }
local ownerByAnimator = setmetatable({}, { __mode = "k" })

local SkillAnimationTrackOwner = {}

--[[
	登记当前 Action 为该轨唯一停轨权所有者（后 claim 覆盖）
	@param animator Animator - 动画器
	@param animationName string - 配置键名
	@param ownerAction any - SkillAction 实例
]]
function SkillAnimationTrackOwner.claim(animator: Animator, animationName: string, ownerAction: any)
	if not animator or not animationName or not ownerAction then
		return
	end
	local map = ownerByAnimator[animator]
	if not map then
		map = {}
		ownerByAnimator[animator] = map
	end
	map[animationName] = ownerAction
end

--[[
	是否仍为该轨停轨权所有者
	@param animator Animator - 动画器
	@param animationName string - 配置键名
	@param ownerAction any - SkillAction 实例
	@return boolean
]]
function SkillAnimationTrackOwner.isOwner(animator: Animator, animationName: string, ownerAction: any): boolean
	if not animator or not animationName or not ownerAction then
		return false
	end
	local map = ownerByAnimator[animator]
	return map ~= nil and map[animationName] == ownerAction
end

--[[
	释放归属（仅当仍是 owner 时清除登记）
	@param animator Animator - 动画器
	@param animationName string - 配置键名
	@param ownerAction any - SkillAction 实例
]]
function SkillAnimationTrackOwner.release(animator: Animator, animationName: string, ownerAction: any)
	if not animator or not animationName or not ownerAction then
		return
	end
	local map = ownerByAnimator[animator]
	if map and map[animationName] == ownerAction then
		map[animationName] = nil
		if next(map) == nil then
			ownerByAnimator[animator] = nil
		end
	end
end

return SkillAnimationTrackOwner
