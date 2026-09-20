--[[
	Module: Atmosphere
	Description: 管理 Atmosphere 参数与显隐
	Author: 中台组 林奥宇
	Created: 2026-01-23
	Last Modified: 2026-08-04

	功能：
	- 从模板 Instance 读取并 tween 大气散射参数
	- 显隐通过 Parent（挂到 Lighting / Parent=nil）；与 PostEffect 的 Enabled 语义不同
	- 天气包有 Atmosphere 子 Instance → setAtmosphereParams 开头 show（挂到 Lighting）
	- 天气包无 Atmosphere 子 Instance → 通道 hide（Parent=nil）
	- 写前统一取消旧 Tween
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local InsMgr = Utils.InsMgr
local Lighting = Utils.Lighting
local LightingTweenUtil = Utils.LightingTweenUtil

export type Atmosphere = {
	Instance: Atmosphere,
	Density: number,
	Offset: number,
	Color: Color3,
	Decay: Color3,
	Glare: number,
	Haze: number,
	TransitionTween: Tween?,
	_lastApplyGen: number?,
	new: (self: Atmosphere) -> Atmosphere,
	setAtmosphereParams: (self: Atmosphere, newAtmosphere: Atmosphere, transitionTime: number, applyGen: number?) -> nil,
	hide: (self: Atmosphere) -> nil,
	show: (self: Atmosphere) -> nil,
	destroy: (self: Atmosphere) -> nil,
}

local Atmosphere = {}
Atmosphere.__index = Atmosphere

--[[
	立即将缓存参数写入 Atmosphere Instance

	@param self Atmosphere - 模块实例
	@param newAtmosphere Atmosphere - 参数来源
	@return nil - 无返回值
]]
local function _setAtmosphereParams(self: Atmosphere, newAtmosphere: Atmosphere)
	self.Instance.Density = newAtmosphere.Density
	self.Instance.Offset = newAtmosphere.Offset
	self.Instance.Color = newAtmosphere.Color
	self.Instance.Decay = newAtmosphere.Decay
	self.Instance.Glare = newAtmosphere.Glare
	self.Instance.Haze = newAtmosphere.Haze
end

--[[
	初始化 Atmosphere 模块

	@return Atmosphere - 模块实例
]]
function Atmosphere.new()
	local self = setmetatable({}, Atmosphere)
	self.Instance = InsMgr.GetIns("Atmosphere", "Atmosphere", Lighting)
	self.Density = 0
	self.Offset = 0
	self.Color = Color3.new(1, 1, 1)
	self.Decay = Color3.new(1, 1, 1)
	self.Glare = 0
	self.Haze = 0
	self.TransitionTween = nil
	self._lastApplyGen = nil
	return self
end

--[[
	设置 Atmosphere 相关参数

	@param newAtmosphere Atmosphere - 参数模板
	@param transitionTime number - 过渡时间（秒）；0 为立即生效
	@param applyGen number? - Weather 生效意图代际
	@return nil - 无返回值
]]
function Atmosphere.setAtmosphereParams(
	self: Atmosphere,
	newAtmosphere: Atmosphere,
	transitionTime: number,
	applyGen: number?
)
	-- 有模板即挂到 Lighting；显隐不由 CHANNEL 抢先 show，避免与 PostEffect 路径不一致
	self:show()
	transitionTime = LightingTweenUtil.normalizeTransitionTime(transitionTime)
	self.Density = newAtmosphere.Density
	self.Offset = newAtmosphere.Offset
	self.Color = newAtmosphere.Color
	self.Decay = newAtmosphere.Decay
	self.Glare = newAtmosphere.Glare
	self.Haze = newAtmosphere.Haze

	local capturedGen = applyGen
	self._lastApplyGen = applyGen

	self.TransitionTween = LightingTweenUtil.playOrApply(
		self.TransitionTween,
		self.Instance,
		transitionTime,
		{
			Density = self.Density,
			Offset = self.Offset,
			Color = self.Color,
			Decay = self.Decay,
			Glare = self.Glare,
			Haze = self.Haze,
		},
		function()
			_setAtmosphereParams(self, newAtmosphere)
		end,
		function()
			if capturedGen ~= nil and self._lastApplyGen ~= capturedGen then
				return
			end
			self.TransitionTween = nil
		end
	)
end

--[[
	隐藏大气（Parent=nil）并停止过渡 Tween

	@return nil - 无返回值
]]
function Atmosphere.hide(self: Atmosphere)
	LightingTweenUtil.cancelTween(self.TransitionTween)
	self.TransitionTween = nil
	self.Instance.Parent = nil
end

--[[
	显示大气（Parent=Lighting）

	@return nil - 无返回值
]]
function Atmosphere.show(self: Atmosphere)
	self.Instance.Parent = Lighting
end

--[[
	销毁模块

	@return nil - 无返回值
]]
function Atmosphere.destroy(self: Atmosphere)
	self:hide()
end

return Atmosphere
