--[[
	Module: PostEffectChannel
	Description: SystemLighting 同构 PostEffect 通道工厂（Blur/Bloom/DoF/SunRays 共用）
	Author: 林奥宇
	Created: 2026-08-04
	Last Modified: 2026-08-31

	功能：
	- InsMgr 取得 Lighting 下 PostEffect
	- 按 propNames 从模板读写并 Tween
	- applyGen：Completed 时校验，过期意图不清理 TransitionTween 引用
	- 关闭通道：先即时写目标属性，再 Enabled=false（经 EffectChannelUtil）

	不适用：ColorCorrection（FX busy）、Atmosphere/Sky（Parent）、Cloud（Terrain）

	使用：
	local PostEffectChannel = require(script.Parent.PostEffectChannel)
	local LightingTweenUtil = Utils.LightingTweenUtil
	local core = PostEffectChannel.create({
		instanceName = "Bloom",
		className = "BloomEffect",
		propNames = { "Intensity", "Threshold", "Size" },
	})
	-- core 挂到通道实例字段后调用 setParams / hide / show / destroy
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local InsMgr = Utils.InsMgr
local Lighting = Utils.Lighting
local LightingTweenUtil = Utils.LightingTweenUtil
local EffectChannelUtil = require(script.Parent.EffectChannelUtil)

export type PostEffectChannelConfig = {
	instanceName: string,
	className: string,
	propNames: { string },
}

export type PostEffectChannelOwner = {
	Instance: PostEffect,
	TransitionTween: Tween?,
	_lastApplyGen: number?,
	[string]: any,
}

local PostEffectChannel = {}

--[[
	创建通道运行时（绑定到调用方 self 上的 Instance / TransitionTween / 属性缓存）

	@param config PostEffectChannelConfig - 实例名、ClassName、可 tween 属性列表
	@return { attach: (owner) -> (), setParams: (owner, template, time, gen?) -> (), hide: (owner) -> (), show: (owner) -> (), destroy: (owner) -> () } - 绑定到通道实例的运行时 API
]]
function PostEffectChannel.create(config: PostEffectChannelConfig)
	local propNames = config.propNames

	local api = {}

	--[[
		初始化 owner：InsMgr 建 Instance，属性缓存置 0，Tween 置 nil

		@param owner PostEffectChannelOwner - 通道实例表
		@return nil - 无返回值
	]]
	function api.attach(owner: PostEffectChannelOwner)
		owner.Instance = InsMgr.GetIns(config.instanceName, config.className, Lighting)
		owner.TransitionTween = nil
		owner._lastApplyGen = nil
		for _, name in propNames do
			owner[name] = 0
		end
	end

	--[[
		从模板写缓存并过渡到 Instance

		@param owner PostEffectChannelOwner - 通道实例
		@param template PostEffect - 参数模板
		@param transitionTime number - 过渡秒数
		@param applyGen number? - Weather 生效意图代际
		@return nil - 无返回值
	]]
	function api.setParams(
		owner: PostEffectChannelOwner,
		template: PostEffect,
		transitionTime: number,
		applyGen: number?
	)
		transitionTime = LightingTweenUtil.normalizeTransitionTime(transitionTime)

		for _, name in propNames do
			owner[name] = (template :: any)[name]
		end

		if not EffectChannelUtil.beginEnabledWrite(owner, template.Enabled, function()
			for _, name in propNames do
				(owner.Instance :: any)[name] = (template :: any)[name]
			end
		end) then
			return
		end

		local goals: { [string]: any } = {}
		for _, name in propNames do
			goals[name] = owner[name]
		end

		local capturedGen = applyGen
		owner._lastApplyGen = applyGen

		owner.TransitionTween = LightingTweenUtil.playOrApply(
			owner.TransitionTween,
			owner.Instance,
			transitionTime,
			goals,
			function()
				for _, name in propNames do
					(owner.Instance :: any)[name] = (template :: any)[name]
				end
			end,
			function()
				if capturedGen ~= nil and owner._lastApplyGen ~= capturedGen then
					return
				end
				owner.TransitionTween = nil
			end
		)
	end

	--[[
		隐藏通道

		@param owner PostEffectChannelOwner - 通道实例
		@return nil - 无返回值
	]]
	function api.hide(owner: PostEffectChannelOwner)
		EffectChannelUtil.hideEnabledEffect(owner)
	end

	--[[
		显示通道

		@param owner PostEffectChannelOwner - 通道实例
		@return nil - 无返回值
	]]
	function api.show(owner: PostEffectChannelOwner)
		EffectChannelUtil.showEnabledEffect(owner)
	end

	--[[
		销毁：隐藏并停 Tween

		@param owner PostEffectChannelOwner - 通道实例
		@return nil - 无返回值
	]]
	function api.destroy(owner: PostEffectChannelOwner)
		api.hide(owner)
	end

	return api
end

return PostEffectChannel
