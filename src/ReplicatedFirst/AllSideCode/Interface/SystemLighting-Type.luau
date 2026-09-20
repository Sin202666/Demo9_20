--[[
	Module: SystemLighting-Type
	Description: SystemLighting 类型声明（完整使用说明见 SystemModule/SystemLighting/init.luau 文件头）
	Author: 中台组 林奥宇
	Created: 2026-07-03
	Last Modified: 2026-08-05

	合法创建：SystemLightingWeather.createForOwner("SystemLightingWeather")。
	业务 Utils.SystemLighting.new 恒返回 nil（硬闸门）。
	子通道已封装为私有，类型桩不暴露 Cloud/Blur 等字段。
	applyWeatherBase / applyChannelFromConfig 第三返回值为预期 skipReason（FxBusy / QualitySkip）。
	applyEffectFromInstance 第二返回值为 EnumMgr.LightingApplyResult。
]]

local SystemLighting = {}

export type SystemLightingInstance = {
	beginApplyGeneration: (self: SystemLightingInstance) -> number,
	getActiveApplyGen: (self: SystemLightingInstance) -> number,
	applyWeatherBase: (
		self: SystemLightingInstance,
		newLighting: Configuration,
		transitionTime: number
	) -> (boolean, string?, string?),
	applyChannelFromConfig: (
		self: SystemLightingInstance,
		config: Configuration,
		className: string,
		transitionTime: number
	) -> (boolean, string?, string?),
	setClockTime: (self: SystemLightingInstance, clockTime: number, transitionTime: number) -> (),
	getClockTime: (self: SystemLightingInstance) -> number,
	applyEffectFromInstance: (
		self: SystemLightingInstance,
		effectInstance: Instance,
		transitionTime: number
	) -> (boolean, string),
	setGraphicsQualityLow: (self: SystemLightingInstance, isLow: boolean) -> (),
	destroy: (self: SystemLightingInstance) -> (),
}

function SystemLighting.createForOwner(ownerKey: string): SystemLightingInstance?
end

function SystemLighting.new(): SystemLightingInstance?
end

function SystemLighting.beginApplyGeneration(self: SystemLightingInstance): number
end

function SystemLighting.getActiveApplyGen(self: SystemLightingInstance): number
end

function SystemLighting.applyWeatherBase(
	self: SystemLightingInstance,
	newLighting: Configuration,
	transitionTime: number
): (boolean, string?, string?)
end

function SystemLighting.applyChannelFromConfig(
	self: SystemLightingInstance,
	config: Configuration,
	className: string,
	transitionTime: number
): (boolean, string?, string?)
end

function SystemLighting.setClockTime(self: SystemLightingInstance, clockTime: number, transitionTime: number)
end

function SystemLighting.getClockTime(self: SystemLightingInstance): number
end

function SystemLighting.applyEffectFromInstance(
	self: SystemLightingInstance,
	effectInstance: Instance,
	transitionTime: number
): (boolean, string)
end

function SystemLighting.setGraphicsQualityLow(self: SystemLightingInstance, isLow: boolean)
end

function SystemLighting.destroy(self: SystemLightingInstance)
end

return SystemLighting
