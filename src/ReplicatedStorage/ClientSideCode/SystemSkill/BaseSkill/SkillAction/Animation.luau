--[[
	Module: SkillAction.Animation
	Description: 技能时间轴动画 Action；经 AnimationLayer 播轨并占闸（不再经 SkillActionLock holder）。
	Author: Dev-Framework
	Created: 2024-01-01
	Last Modified: 2026-07-31

	配置（actionInfo）：
	- animationName string - AnimationModule 配置键
	- animSlot string? - Upper / FullBody / React；默认 FullBody
	- blendPolicy string? - 省略则跟 Slot 默认（Upper→Overlay，FullBody→Override）
	- animationSpeed / animationPriority / animationFadeTime / animationLoop / keyframe*
	- Upper 须使用未键腿资源；否则会盖住 loco 腿部

	占闸：AnimationLayer.acquireGate=true（BlendPolicy → ActionArbiter）。
	不经 SkillActionLock，避免 Init/重入 Start 留下孤儿 holder 导致第二次技能后 loco 永久 pause。
	翻滚等仍用 SkillActionLock；与 Layer 占闸在 Arbiter 层 OR 聚合。

	闸与轨：OnOver/Init 停轨并 Release Layer 占闸；预测 handoff 不停轨，由正式段同 Slot Play 抢占。
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local AnimationModule = Utils.AnimationModule
local AnimationLayer = Utils.AnimationLayer

local SkillActionControl = require(script.Parent.Parent.SkillActionControl)
local SkillAnimationTrackOwner = require(script.Parent.SkillAnimationTrackOwner)

local module = {}

module.isReleasePlayerOnly = true

--[[
	由 Slot 推导默认 BlendPolicy
	@param slot string
	@return string
]]
local function _defaultPolicyForSlot(slot: string): string
	if slot == AnimationLayer.Slot.Upper then
		return AnimationLayer.BlendPolicy.Overlay
	end
	if slot == AnimationLayer.Slot.React then
		return AnimationLayer.BlendPolicy.React
	end
	return AnimationLayer.BlendPolicy.Override
end

--[[
	停止本实例 Layer 轨（失败则按名 StopAnim）
	@param self any
	@param fade number?
	@param requireOwner boolean - true 时仅 TrackOwner 才停轨
]]
local function _stopLayerOrAnim(self: any, fade: number?, requireOwner: boolean)
	local animator = self.animator
	local animationName = self.animationName
	local handle = self._layerHandle
	self._layerHandle = nil

	if requireOwner then
		local stillOwner = animator and animationName
			and SkillAnimationTrackOwner.isOwner(animator, animationName, self)
		if not stillOwner then
			if animator and animationName then
				SkillAnimationTrackOwner.release(animator, animationName, self)
			end
			-- 非 owner 不停轨，但仍清 Slot 占闸（避免本实例 Acquire 残留）
			if handle then
				AnimationLayer.Stop(handle, 0)
			end
			return
		end
	end

	if animator and animationName then
		SkillAnimationTrackOwner.release(animator, animationName, self)
	end

	local fadeOut = if type(fade) == "number" then fade else (self.animationFadeTime or 0)
	if handle then
		AnimationLayer.Stop(handle, fadeOut)
	end
	if animator and animationName then
		AnimationModule.StopAnim(animator, animationName, fadeOut)
	end
end

function module:Create(actionInfo: any)
	self.actionInfo = actionInfo

	self.state = SkillActionControl.StateEnum.NoStart
	self.startTime = self.actionInfo.startTime
	self.overTime = self.actionInfo.overTime

	local character = self.baseSkill.character
	if not character then
		return
	end
	local humanoid = character:WaitForChild("Humanoid")
	local animator = humanoid:WaitForChild("Animator")
	if not animator then
		return
	end
	self.animator = animator
	self.animationName = actionInfo.animationName
	self.animationSpeed = actionInfo.animationSpeed or 1
	self.animationPriority = actionInfo.animationPriority
	self.animationFadeTime = actionInfo.animationFadeTime or 0
	self.animationKeyframeNames = actionInfo.animationKeyframeNames or {}
	self.animationKeyframeFunctions = actionInfo.animationKeyframeFunctions or {}
	self.animationLoop = actionInfo.animationLoop or false

	local slot = actionInfo.animSlot
	if type(slot) ~= "string" or slot == "" then
		slot = AnimationLayer.Slot.FullBody
	end
	self.animSlot = slot
	local policy = actionInfo.blendPolicy
	if type(policy) ~= "string" or policy == "" then
		policy = _defaultPolicyForSlot(slot)
	end
	self.blendPolicy = policy

	if not self.baseSkill._skipAnimationCreatePreload then
		AnimationModule.PlayAnim(self.animator, self.animationName)
		AnimationModule.StopAnim(self.animator, self.animationName)
	end
end

function module:Init()
	if self._layerHandle then
		_stopLayerOrAnim(self, 0, false)
	end
	self.state = SkillActionControl.StateEnum.NoStart
	self._layerHandle = nil
end

function module:Run(cumulativeTime: number)
end

function module:Start(cumulativeTime: number)
	if self._layerHandle then
		_stopLayerOrAnim(self, 0, false)
	end

	local character = self.baseSkill.character
	local handle = AnimationLayer.Play(character, {
		slot = self.animSlot,
		animationName = self.animationName,
		speed = self.animationSpeed,
		fadeIn = self.animationFadeTime,
		fadeOut = self.animationFadeTime,
		blendPolicy = self.blendPolicy,
		priority = self.animationPriority,
		looped = self.animationLoop == true,
		keyframeNames = self.animationKeyframeNames,
		keyframeFunctions = self.animationKeyframeFunctions,
		ownerId = string.format("SkillAnim:%s:%s", tostring(self.animSlot), tostring(self.animationName)),
		acquireGate = true,
		releaseOnStopped = true,
	})
	self._layerHandle = handle

	if self.animator and self.animationName then
		SkillAnimationTrackOwner.claim(self.animator, self.animationName, self)
	end

	local st = self.actionInfo.startTime or 0
	local offset = (type(cumulativeTime) == "number" and cumulativeTime or 0) - st
	if offset > 1e-3 and handle then
		AnimationLayer.SetTimePosition(handle, offset)
		task.defer(function()
			if self._layerHandle == handle then
				AnimationLayer.SetTimePosition(handle, offset)
			end
		end)
	end
end

function module:OnOver(cumulativeTime: number)
	if self.baseSkill and self.baseSkill._presentationPredictAnimHandoff then
		local animator = self.animator
		local animationName = self.animationName
		if animator and animationName then
			SkillAnimationTrackOwner.release(animator, animationName, self)
		end
		-- handoff：不停轨、不 Stop Layer（正式段同 Slot Play 会抢占并 Release 旧 claim）
		self._layerHandle = nil
		return
	end

	_stopLayerOrAnim(self, self.animationFadeTime or 0, true)
end

return module