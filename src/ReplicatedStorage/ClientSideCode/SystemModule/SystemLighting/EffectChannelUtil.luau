--[[
	Module: EffectChannelUtil
	Description: SystemLighting 子通道共用的 Enabled 显隐助手（不进 Utils 顶层键）
	Author: 林奥宇
	Created: 2026-08-04
	Last Modified: 2026-08-31

	功能：
	- 按模板 Enabled 决定 show / 先写目标再 hide
	- 隐藏时统一取消 Tween 并 Enabled=false
	- 关闭通道不做属性 Tween：先即时写入目标属性，再 Enabled=false

	适用：Blur / Bloom / SunRays / DepthOfField 等 PostEffect（Enabled 语义）
	不适用：Atmosphere/Sky（Parent）、Cloud（Terrain 自管）
	ColorCorrection 可复用 beginEnabledWrite；FX busy 由通道自行 gate

	使用：
	local EffectChannelUtil = require(script.Parent.EffectChannelUtil)
	if not EffectChannelUtil.beginEnabledWrite(self, template.Enabled, function()
		_applyNow(self, template)
	end) then
		return
	end
	-- 属性过渡见 Utils.LightingTweenUtil.playOrApply
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local LightingTweenUtil = Utils.LightingTweenUtil

export type EnabledEffectOwner = {
	Instance: PostEffect,
	TransitionTween: Tween?,
}

local EffectChannelUtil = {}

--[[
	显示 PostEffect（Enabled=true）

	@param owner EnabledEffectOwner - 通道实例（含 Instance）
	@return nil - 无返回值
]]
function EffectChannelUtil.showEnabledEffect(owner: EnabledEffectOwner)
	owner.Instance.Enabled = true
end

--[[
	隐藏 PostEffect：取消过渡 Tween 并 Enabled=false

	@param owner EnabledEffectOwner - 通道实例（含 Instance / TransitionTween）
	@return nil - 无返回值
]]
function EffectChannelUtil.hideEnabledEffect(owner: EnabledEffectOwner)
	LightingTweenUtil.cancelTween(owner.TransitionTween)
	owner.TransitionTween = nil
	owner.Instance.Enabled = false
end

--[[
	模板 Enabled=false：先即时写目标属性，再取消 Tween 并关闭（无关闭过渡）

	@param owner EnabledEffectOwner - 通道实例
	@param applyTargetsNow (() -> ())? - 将缓存/模板属性写入 Instance
	@return nil - 无返回值
]]
function EffectChannelUtil.disableWithTargets(owner: EnabledEffectOwner, applyTargetsNow: (() -> ())?)
	if applyTargetsNow then
		applyTargetsNow()
	end
	EffectChannelUtil.hideEnabledEffect(owner)
end

--[[
	按模板 Enabled 开始写入：关闭则 disableWithTargets 并返回 false；开启则 show 并返回 true（调用方再 playOrApply）

	@param owner EnabledEffectOwner - 通道实例
	@param enabled boolean - 模板 Enabled
	@param applyTargetsNow (() -> ())? - 关闭时用于落地目标属性
	@return boolean - true 表示应继续属性 Tween；false 表示已关闭并 return
]]
function EffectChannelUtil.beginEnabledWrite(
	owner: EnabledEffectOwner,
	enabled: boolean,
	applyTargetsNow: (() -> ())?
): boolean
	if not enabled then
		EffectChannelUtil.disableWithTargets(owner, applyTargetsNow)
		return false
	end
	EffectChannelUtil.showEnabledEffect(owner)
	return true
end

return EffectChannelUtil
