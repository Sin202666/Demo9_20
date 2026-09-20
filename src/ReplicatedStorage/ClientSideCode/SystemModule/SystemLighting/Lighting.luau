--[[
	Module: Lighting
	Description: 管理 Lighting 服务可 tween 的基础属性与时钟
	Author: 林奥宇
	Created: 2026-01-23
	Last Modified: 2026-08-31

	功能：
	- 从 Configuration Attribute 读取并应用 Ambient、Brightness 等属性
	- Attribute 缺省或类型不符时回退到当前 Lighting 服务值并 Log.warn
	- 支持 ClockTime 过渡；写前统一取消旧 Tween，避免即时写与残留 Tween 互盖
	- ClockTime 过渡走最短弧（±12h 内），避免 23→1 倒放整天
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Lighting = Utils.Lighting
local Log = Utils.Log
local LightingTweenUtil = Utils.LightingTweenUtil

export type LightingSettings = {
	Ambient: Color3,
	Brightness: number,
	EnvironmentDiffuseScale: number,
	EnvironmentSpecularScale: number,
	ExposureCompensation: number,
	ShadowSoftness: number,
	OutdoorAmbient: Color3,
	ClockTime: number,
	GeographicLatitude: number,
	TransitionTween: Tween?,
	ClockTransitionTween: Tween?,
	new: (self: LightingSettings) -> LightingSettings,
	setLightingParams: (self: LightingSettings, newLighting: Configuration, transitionTime: number, applyGen: number?) -> nil,
	setClockTime: (self: LightingSettings, clockTime: number, transitionTime: number) -> nil,
	getClockTime: (self: LightingSettings) -> number,
	destroy: (self: LightingSettings) -> nil,
}

local LightingSettings = {}
LightingSettings.__index = LightingSettings

local CLOCK_TIME_MIN = 0
local CLOCK_TIME_MAX = 24

-- ========================================
-- 私有函数
-- ========================================
--[[
	读取 Configuration Attribute；类型不符或缺失时回退 fallback

	@param config Configuration - 天气配置 Instance
	@param name string - Attribute 名
	@param expectedType string - typeof 期望类型（如 "number"、"Color3"）
	@param fallback Color3 | number - 无效时回退到调用前 Lighting 服务当前值
	@return any - 合法 Attribute 或 fallback
]]
local function _readAttr(config: Configuration, name: string, expectedType: string, fallback: any): any
	local v = config:GetAttribute(name)
	if typeof(v) ~= expectedType then
		Log.warn("LightingSettings: Attribute 无效", name, v)
		return fallback
	end
	return v
end

--[[
	立即将缓存属性写入 Lighting 服务

	@param self LightingSettings - 模块实例
	@return nil - 无返回值
]]
local function _applyLightingParams(self: LightingSettings)
	Lighting.Ambient = self.Ambient
	Lighting.Brightness = self.Brightness
	Lighting.EnvironmentDiffuseScale = self.EnvironmentDiffuseScale
	Lighting.EnvironmentSpecularScale = self.EnvironmentSpecularScale
	Lighting.ExposureCompensation = self.ExposureCompensation
	Lighting.ShadowSoftness = self.ShadowSoftness
	Lighting.OutdoorAmbient = self.OutdoorAmbient
	Lighting.GeographicLatitude = self.GeographicLatitude
end

--[[
	将 ClockTime 规范到 [0, 24)

	@param t number - 原始时钟
	@return number - 规范后的时钟
]]
local function _normalizeClockModulo(t: number): number
	local r = t % 24
	if r < 0 then
		r += 24
	end
	return r
end

--[[
	计算从 from 到 to 的最短弧增量（∈ (-12, 12]）

	@param from number - 当前时钟 [0, 24)
	@param to number - 目标时钟 [0, 24]
	@return number - 最短有符号增量小时
]]
local function _shortestClockDelta(from: number, to: number): number
	local delta = (to - from) % 24
	if delta > 12 then
		delta -= 24
	end
	return delta
end

-- ========================================
-- 公共函数
-- ========================================
--[[
	初始化 LightingSettings

	@return LightingSettings - 模块实例
]]
function LightingSettings.new()
	local self = setmetatable({}, LightingSettings)

	self.Ambient = Lighting.Ambient
	self.Brightness = Lighting.Brightness
	self.EnvironmentDiffuseScale = Lighting.EnvironmentDiffuseScale
	self.EnvironmentSpecularScale = Lighting.EnvironmentSpecularScale
	self.ExposureCompensation = Lighting.ExposureCompensation
	self.ShadowSoftness = Lighting.ShadowSoftness
	self.OutdoorAmbient = Lighting.OutdoorAmbient
	self.GeographicLatitude = Lighting.GeographicLatitude
	self.ClockTime = Lighting.ClockTime
	self.TransitionTween = nil
	self.ClockTransitionTween = nil
	self._lastLightingApplyGen = nil

	return self
end

--[[
	设置 Lighting 相关参数

	@param newLighting Configuration - 含 Attribute 的配置 Instance
	@param transitionTime number - 过渡时间（秒）；0 为立即生效；负数按 0
	@param applyGen number? - Weather 生效意图代际；Completed 时校验，过期则不清理副作用以外的逻辑
	@return nil - 无返回值
]]
function LightingSettings.setLightingParams(
	self: LightingSettings,
	newLighting: Configuration,
	transitionTime: number,
	applyGen: number?
)
	transitionTime = LightingTweenUtil.normalizeTransitionTime(transitionTime)

	-- fallback 取调用前服务当前值，保证 Tween goal 不为 nil
	self.Ambient = _readAttr(newLighting, "Ambient", "Color3", Lighting.Ambient)
	self.Brightness = _readAttr(newLighting, "Brightness", "number", Lighting.Brightness)
	self.EnvironmentDiffuseScale = _readAttr(newLighting, "EnvironmentDiffuseScale", "number", Lighting.EnvironmentDiffuseScale)
	self.EnvironmentSpecularScale = _readAttr(newLighting, "EnvironmentSpecularScale", "number", Lighting.EnvironmentSpecularScale)
	self.ExposureCompensation = _readAttr(newLighting, "ExposureCompensation", "number", Lighting.ExposureCompensation)
	self.ShadowSoftness = _readAttr(newLighting, "ShadowSoftness", "number", Lighting.ShadowSoftness)
	self.OutdoorAmbient = _readAttr(newLighting, "OutdoorAmbient", "Color3", Lighting.OutdoorAmbient)
	self.GeographicLatitude = _readAttr(newLighting, "GeographicLatitude", "number", Lighting.GeographicLatitude)

	local capturedGen = applyGen
	self._lastLightingApplyGen = applyGen
	self.TransitionTween = LightingTweenUtil.playOrApply(
		self.TransitionTween,
		Lighting,
		transitionTime,
		{
			Ambient = self.Ambient,
			Brightness = self.Brightness,
			EnvironmentDiffuseScale = self.EnvironmentDiffuseScale,
			EnvironmentSpecularScale = self.EnvironmentSpecularScale,
			ExposureCompensation = self.ExposureCompensation,
			ShadowSoftness = self.ShadowSoftness,
			OutdoorAmbient = self.OutdoorAmbient,
			GeographicLatitude = self.GeographicLatitude,
		},
		function()
			_applyLightingParams(self)
		end,
		function()
			if capturedGen ~= nil and self._lastLightingApplyGen ~= capturedGen then
				return
			end
			self.TransitionTween = nil
		end
	)
end

--[[
	设置时钟时间（过渡走最短弧；goal 可为越界值，引擎 ClockTime 会 wrap）

	@param clockTime number - 时钟时间（会 clamp 到 0–24）
	@param transitionTime number? - 过渡时间（秒）；nil 或 0 为立即生效
	@return nil - 无返回值
]]
function LightingSettings.setClockTime(self: LightingSettings, clockTime: number, transitionTime: number?)
	transitionTime = LightingTweenUtil.normalizeTransitionTime(transitionTime)
	local to = math.clamp(clockTime, CLOCK_TIME_MIN, CLOCK_TIME_MAX)
	self.ClockTime = to

	local from = _normalizeClockModulo(Lighting.ClockTime)
	local delta = _shortestClockDelta(from, to)
	local goalClock = from + delta

	self.ClockTransitionTween = LightingTweenUtil.playOrApply(
		self.ClockTransitionTween,
		Lighting,
		transitionTime,
		{
			ClockTime = goalClock,
		},
		function()
			Lighting.ClockTime = to
		end,
		function()
			self.ClockTransitionTween = nil
		end
	)
end

--[[
	读取缓存的逻辑时钟（可能与服务当前值在 Tween 中途短暂不一致）

	@return number - 最近一次 setClockTime 写入的目标时钟（0–24）
]]
function LightingSettings.getClockTime(self: LightingSettings): number
	return self.ClockTime
end

--[[
	销毁模块，停止进行中的 Tween

	@return nil - 无返回值
]]
function LightingSettings.destroy(self: LightingSettings)
	LightingTweenUtil.cancelTween(self.TransitionTween)
	self.TransitionTween = nil
	LightingTweenUtil.cancelTween(self.ClockTransitionTween)
	self.ClockTransitionTween = nil
end

return LightingSettings
