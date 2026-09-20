--[[
	Module: Sky
	Description: 管理 Sky 天空盒参数与显隐
	Author: 中台组 林奥宇
	Created: 2026-01-23
	Last Modified: 2026-08-04

	功能：
	- 从模板 Instance 读取天空盒纹理与天体参数
	- 纹理类属性立即应用，数值属性可 tween
	- 写前统一取消旧 Tween，避免即时写与残留 Tween 互盖
	- 显隐通过 Parent（挂到 Lighting / Parent=nil）；与 PostEffect 的 Enabled 语义不同
	- 天气包有 Sky 子 Instance → setSkyParams 开头 show（挂到 Lighting）
	- 天气包无 Sky 子 Instance → 通道 hide（Parent=nil）
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local InsMgr = Utils.InsMgr
local Lighting = Utils.Lighting
local LightingTweenUtil = Utils.LightingTweenUtil

export type SkyEffect = {
	Instance: Sky,
	TransitionTween: Tween?,
	_lastApplyGen: number?,
	MoonAngularSize: number?,
	SkyboxOrientation: Vector3?,
	StarCount: number?,
	SunAngularSize: number?,
	MoonTextureId: string?,
	SkyboxBk: string?,
	SkyboxDn: string?,
	SkyboxFt: string?,
	SkyboxLf: string?,
	SkyboxRt: string?,
	SkyboxUp: string?,
	SunTextureId: string?,
	CelestialBodiesShown: boolean?,
	new: (self: SkyEffect) -> SkyEffect,
	setSkyParams: (self: SkyEffect, newSky: Sky, transitionTime: number, applyGen: number?) -> nil,
	hide: (self: SkyEffect) -> nil,
	show: (self: SkyEffect) -> nil,
	destroy: (self: SkyEffect) -> nil,
}

local SkyEffect = {}
SkyEffect.__index = SkyEffect

--[[
	立即将全部天空参数写入 Instance

	@param self SkyEffect - 模块实例
	@param newSky Sky - 参数模板
	@return nil - 无返回值
]]
local function _setSkyEffectParams(self: SkyEffect, newSky: Sky)
	self.Instance.MoonAngularSize = newSky.MoonAngularSize
	self.Instance.MoonTextureId = newSky.MoonTextureId
	self.Instance.SkyboxBk = newSky.SkyboxBk
	self.Instance.SkyboxDn = newSky.SkyboxDn
	self.Instance.SkyboxFt = newSky.SkyboxFt
	self.Instance.SkyboxLf = newSky.SkyboxLf
	self.Instance.SkyboxRt = newSky.SkyboxRt
	self.Instance.SkyboxUp = newSky.SkyboxUp
	self.Instance.SunTextureId = newSky.SunTextureId
	self.Instance.SkyboxOrientation = newSky.SkyboxOrientation
	self.Instance.StarCount = newSky.StarCount
	self.Instance.SunAngularSize = newSky.SunAngularSize
	self.Instance.CelestialBodiesShown = newSky.CelestialBodiesShown
end

--[[
	初始化 Sky 模块

	@return SkyEffect - 模块实例
]]
function SkyEffect.new()
	local self = setmetatable({}, SkyEffect)
	self.Instance = InsMgr.GetIns("Sky", "Sky", Lighting)
	self.TransitionTween = nil
	self._lastApplyGen = nil
	return self
end

--[[
	设置 Sky 相关参数；纹理立即写，可 tween 数值走过渡

	@param newSky Sky - 参数模板
	@param transitionTime number - 过渡时间（秒）；0 为立即生效
	@param applyGen number? - Weather 生效意图代际
	@return nil - 无返回值
]]
function SkyEffect.setSkyParams(self: SkyEffect, newSky: Sky, transitionTime: number, applyGen: number?)
	-- 有模板即挂到 Lighting；显隐不由 CHANNEL 抢先 show，避免与 PostEffect 路径不一致
	self:show()
	transitionTime = LightingTweenUtil.normalizeTransitionTime(transitionTime)

	local capturedGen = applyGen
	self._lastApplyGen = applyGen

	if transitionTime > 0 then
		self.MoonAngularSize = newSky.MoonAngularSize
		self.SkyboxOrientation = newSky.SkyboxOrientation
		self.StarCount = newSky.StarCount
		self.SunAngularSize = newSky.SunAngularSize

		self.MoonTextureId = newSky.MoonTextureId
		self.Instance.MoonTextureId = self.MoonTextureId :: string
		self.SkyboxBk = newSky.SkyboxBk
		self.Instance.SkyboxBk = self.SkyboxBk :: string
		self.SkyboxDn = newSky.SkyboxDn
		self.Instance.SkyboxDn = self.SkyboxDn :: string
		self.SkyboxFt = newSky.SkyboxFt
		self.Instance.SkyboxFt = self.SkyboxFt :: string
		self.SkyboxLf = newSky.SkyboxLf
		self.Instance.SkyboxLf = self.SkyboxLf :: string
		self.SkyboxRt = newSky.SkyboxRt
		self.Instance.SkyboxRt = self.SkyboxRt :: string
		self.SkyboxUp = newSky.SkyboxUp
		self.Instance.SkyboxUp = self.SkyboxUp :: string
		self.SunTextureId = newSky.SunTextureId
		self.Instance.SunTextureId = self.SunTextureId :: string
		self.CelestialBodiesShown = newSky.CelestialBodiesShown
		self.Instance.CelestialBodiesShown = self.CelestialBodiesShown :: boolean

		self.TransitionTween = LightingTweenUtil.playOrApply(
			self.TransitionTween,
			self.Instance,
			transitionTime,
			{
				MoonAngularSize = self.MoonAngularSize,
				SunAngularSize = self.SunAngularSize,
				StarCount = self.StarCount,
				SkyboxOrientation = self.SkyboxOrientation,
			},
			nil,
			function()
				if capturedGen ~= nil and self._lastApplyGen ~= capturedGen then
					return
				end
				self.TransitionTween = nil
			end
		)
	else
		LightingTweenUtil.cancelTween(self.TransitionTween)
		self.TransitionTween = nil
		_setSkyEffectParams(self, newSky)
	end
end

--[[
	隐藏天空盒（Parent=nil）并停止过渡 Tween

	@return nil - 无返回值
]]
function SkyEffect.hide(self: SkyEffect)
	LightingTweenUtil.cancelTween(self.TransitionTween)
	self.TransitionTween = nil
	self.Instance.Parent = nil
end

--[[
	显示天空盒（Parent=Lighting）

	@return nil - 无返回值
]]
function SkyEffect.show(self: SkyEffect)
	self.Instance.Parent = Lighting
end

--[[
	销毁模块，停止 Tween 并隐藏

	@return nil - 无返回值
]]
function SkyEffect.destroy(self: SkyEffect)
	self:hide()
end

return SkyEffect
