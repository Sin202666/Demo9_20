--[[
	Module: SunRays
	Description: 管理 SunRaysEffect 参数与显隐（PostEffectChannel 薄封装）
	Author: 中台组 林奥宇
	Created: 2026-01-23
	Last Modified: 2026-08-04

	功能：从模板 tween Intensity / Spread；关闭通道先写目标再 Enabled=false。
]]

local PostEffectChannel = require(script.Parent.PostEffectChannel)

local _core = PostEffectChannel.create({
	instanceName = "SunRays",
	className = "SunRaysEffect",
	propNames = { "Intensity", "Spread" },
})

export type SunRays = {
	new: (self: SunRays) -> SunRays,
	setSunRaysParams: (self: SunRays, newSunRays: SunRaysEffect, transitionTime: number, applyGen: number?) -> nil,
	hide: (self: SunRays) -> nil,
	show: (self: SunRays) -> nil,
	destroy: (self: SunRays) -> nil,
}

local SunRays = {}
SunRays.__index = SunRays

--[[
	初始化 SunRays 模块

	@return SunRays - 模块实例
]]
function SunRays.new()
	local self = setmetatable({}, SunRays)
	_core.attach(self)
	return self
end

--[[
	设置 SunRays 相关参数

	@param newSunRays SunRaysEffect - 参数模板
	@param transitionTime number - 过渡时间（秒）；0 为立即生效
	@param applyGen number? - Weather 生效意图代际
	@return nil - 无返回值
]]
function SunRays.setSunRaysParams(
	self: SunRays,
	newSunRays: SunRaysEffect,
	transitionTime: number,
	applyGen: number?
)
	_core.setParams(self, newSunRays, transitionTime, applyGen)
end

--[[
	隐藏 SunRays 并停止过渡 Tween

	@return nil - 无返回值
]]
function SunRays.hide(self: SunRays)
	_core.hide(self)
end

--[[
	显示 SunRays

	@return nil - 无返回值
]]
function SunRays.show(self: SunRays)
	_core.show(self)
end

--[[
	销毁模块

	@return nil - 无返回值
]]
function SunRays.destroy(self: SunRays)
	_core.destroy(self)
end

return SunRays
