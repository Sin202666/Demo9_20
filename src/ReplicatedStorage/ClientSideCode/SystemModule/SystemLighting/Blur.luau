--[[
	Module: Blur
	Description: 管理 BlurEffect 参数与显隐（PostEffectChannel 薄封装）
	Author: 中台组 林奥宇
	Created: 2026-01-23
	Last Modified: 2026-08-04

	功能：从模板 tween Size；关闭通道先写目标再 Enabled=false。
]]

local PostEffectChannel = require(script.Parent.PostEffectChannel)

local _core = PostEffectChannel.create({
	instanceName = "Blur",
	className = "BlurEffect",
	propNames = { "Size" },
})

export type Blur = {
	new: (self: Blur) -> Blur,
	setBlurParams: (self: Blur, newBlur: BlurEffect, transitionTime: number, applyGen: number?) -> nil,
	hide: (self: Blur) -> nil,
	show: (self: Blur) -> nil,
	destroy: (self: Blur) -> nil,
}

local Blur = {}
Blur.__index = Blur

--[[
	初始化 Blur 模块

	@return Blur - 模块实例
]]
function Blur.new()
	local self = setmetatable({}, Blur)
	_core.attach(self)
	return self
end

--[[
	设置 Blur 相关参数

	@param newBlur BlurEffect - 参数模板
	@param transitionTime number - 过渡时间（秒）；0 为立即生效
	@param applyGen number? - Weather 生效意图代际
	@return nil - 无返回值
]]
function Blur.setBlurParams(self: Blur, newBlur: BlurEffect, transitionTime: number, applyGen: number?)
	_core.setParams(self, newBlur, transitionTime, applyGen)
end

--[[
	隐藏 Blur 并停止过渡 Tween

	@return nil - 无返回值
]]
function Blur.hide(self: Blur)
	_core.hide(self)
end

--[[
	显示 Blur

	@return nil - 无返回值
]]
function Blur.show(self: Blur)
	_core.show(self)
end

--[[
	销毁模块

	@return nil - 无返回值
]]
function Blur.destroy(self: Blur)
	_core.destroy(self)
end

return Blur
