--[[
	Module: Bloom
	Description: 管理 BloomEffect 参数与显隐（PostEffectChannel 薄封装）
	Author: 中台组 林奥宇
	Created: 2026-01-23
	Last Modified: 2026-08-04

	功能：从模板 tween Intensity / Threshold / Size；关闭通道先写目标再 Enabled=false。
]]

local PostEffectChannel = require(script.Parent.PostEffectChannel)

local _core = PostEffectChannel.create({
	instanceName = "Bloom",
	className = "BloomEffect",
	propNames = { "Intensity", "Threshold", "Size" },
})

export type Bloom = {
	new: (self: Bloom) -> Bloom,
	setBloomParams: (self: Bloom, newBloom: BloomEffect, transitionTime: number, applyGen: number?) -> nil,
	hide: (self: Bloom) -> nil,
	show: (self: Bloom) -> nil,
	destroy: (self: Bloom) -> nil,
}

local Bloom = {}
Bloom.__index = Bloom

--[[
	初始化 Bloom 模块

	@return Bloom - 模块实例
]]
function Bloom.new()
	local self = setmetatable({}, Bloom)
	_core.attach(self)
	return self
end

--[[
	设置 Bloom 相关参数

	@param newBloom BloomEffect - 参数模板
	@param transitionTime number - 过渡时间（秒）；0 为立即生效
	@param applyGen number? - Weather 生效意图代际
	@return nil - 无返回值
]]
function Bloom.setBloomParams(self: Bloom, newBloom: BloomEffect, transitionTime: number, applyGen: number?)
	_core.setParams(self, newBloom, transitionTime, applyGen)
end

--[[
	隐藏 Bloom 效果并停止过渡 Tween

	@return nil - 无返回值
]]
function Bloom.hide(self: Bloom)
	_core.hide(self)
end

--[[
	显示 Bloom 效果

	@return nil - 无返回值
]]
function Bloom.show(self: Bloom)
	_core.show(self)
end

--[[
	销毁模块，停止进行中的 Tween

	@return nil - 无返回值
]]
function Bloom.destroy(self: Bloom)
	_core.destroy(self)
end

return Bloom
