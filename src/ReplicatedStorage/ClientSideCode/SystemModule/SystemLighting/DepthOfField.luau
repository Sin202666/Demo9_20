--[[
	Module: DepthOfField
	Description: 管理 DepthOfFieldEffect 参数与显隐（PostEffectChannel 薄封装）
	Author: 中台组 林奥宇
	Created: 2026-01-23
	Last Modified: 2026-08-04

	功能：从模板 tween 景深参数；关闭通道先写目标再 Enabled=false。
]]

local PostEffectChannel = require(script.Parent.PostEffectChannel)

local _core = PostEffectChannel.create({
	instanceName = "DepthOfField",
	className = "DepthOfFieldEffect",
	propNames = { "FocusDistance", "FarIntensity", "NearIntensity", "InFocusRadius" },
})

export type DepthOfField = {
	new: (self: DepthOfField) -> DepthOfField,
	setDepthOfFieldParams: (
		self: DepthOfField,
		newDepthOfField: DepthOfFieldEffect,
		transitionTime: number,
		applyGen: number?
	) -> nil,
	hide: (self: DepthOfField) -> nil,
	show: (self: DepthOfField) -> nil,
	destroy: (self: DepthOfField) -> nil,
}

local DepthOfField = {}
DepthOfField.__index = DepthOfField

--[[
	初始化 DepthOfField 模块

	@return DepthOfField - 模块实例
]]
function DepthOfField.new()
	local self = setmetatable({}, DepthOfField)
	_core.attach(self)
	return self
end

--[[
	设置 DepthOfField 相关参数

	@param newDepthOfField DepthOfFieldEffect - 参数模板
	@param transitionTime number - 过渡时间（秒）；0 为立即生效
	@param applyGen number? - Weather 生效意图代际
	@return nil - 无返回值
]]
function DepthOfField.setDepthOfFieldParams(
	self: DepthOfField,
	newDepthOfField: DepthOfFieldEffect,
	transitionTime: number,
	applyGen: number?
)
	_core.setParams(self, newDepthOfField, transitionTime, applyGen)
end

--[[
	隐藏景深并停止过渡 Tween

	@return nil - 无返回值
]]
function DepthOfField.hide(self: DepthOfField)
	_core.hide(self)
end

--[[
	显示景深

	@return nil - 无返回值
]]
function DepthOfField.show(self: DepthOfField)
	_core.show(self)
end

--[[
	销毁模块

	@return nil - 无返回值
]]
function DepthOfField.destroy(self: DepthOfField)
	_core.destroy(self)
end

return DepthOfField
