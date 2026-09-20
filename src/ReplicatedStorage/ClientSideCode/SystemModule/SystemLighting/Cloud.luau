--[[
	Module: Cloud
	Description: 管理 Terrain Clouds 参数、显隐与微动动画
	Author: 林奥宇
	Created: 2026-01-23
	Last Modified: 2026-08-31

	功能：
	- 从模板 Instance 读取并 tween Cover / Density / Color
	- 可选微动循环动画
	- 过渡与微动互斥：写参前停微动；过渡 Completed（代际 token）后再启微动
	- Terrain 取自 workspace.Terrain（引擎常驻，require 不阻塞）；无 Clouds Instance 时通道 no-op
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local InsMgr = Utils.InsMgr
local TweenService = Utils.TweenService
local LightingTweenUtil = Utils.LightingTweenUtil

local MICRO_MOTION_RANGE_DEFAULT = 0.1
local MICRO_MOTION_TIME_DEFAULT = 10
local MICRO_MOTION_EASING_STYLE = Enum.EasingStyle.Linear
local MICRO_MOTION_EASING_DIR = Enum.EasingDirection.InOut
local MICRO_MOTION_REPEAT_COUNT = -1
local MICRO_MOTION_REVERSES = true

export type Cloud = {
	Instance: Clouds?,
	Cover: number,
	Density: number,
	Color: Color3,
	TransitionTween: Tween?,
	MicroMotionTween: Tween?,
	IsMicroMotion: boolean,
	MicroMotionRange: number,
	MicroMotionTime: number,
	_terrainReady: boolean,
	_microMotionAllowed: boolean,
	_transitionGen: number,
	new: (self: Cloud) -> Cloud,
	setCloudParams: (self: Cloud, newCloud: Clouds, transitionTime: number, applyGen: number?) -> nil,
	setMicroMotionAllowed: (self: Cloud, allowed: boolean) -> nil,
	setMicroMotionRange: (self: Cloud, range: number, time: number) -> nil,
	startMicroMotion: (self: Cloud, range: number?, time: number?) -> nil,
	stopMicroMotion: (self: Cloud) -> nil,
	hide: (self: Cloud) -> nil,
	show: (self: Cloud) -> nil,
	destroy: (self: Cloud) -> nil,
}

local Terrain = workspace.Terrain

local Cloud = {}
Cloud.__index = Cloud

-- ========================================
-- 私有函数
-- ========================================
--[[
	立即将缓存参数写入 Clouds Instance

	@param self Cloud - 模块实例
	@param newCloud Clouds - 参数来源
	@return nil - 无返回值
]]
local function _setCloudParams(self: Cloud, newCloud: Clouds)
	local instance = self.Instance
	if not instance then
		return
	end
	instance.Cover = newCloud.Cover
	instance.Density = newCloud.Density
	instance.Color = newCloud.Color
end

--[[
	取消过渡 Tween 并递增代际以作废过期回调

	@param self Cloud - 模块实例
	@return nil - 无返回值
]]
local function _cancelTransition(self: Cloud)
	self._transitionGen += 1
	LightingTweenUtil.cancelTween(self.TransitionTween)
	self.TransitionTween = nil
end

-- ========================================
-- 公共函数
-- ========================================
--[[
	初始化 Cloud 模块

	@return Cloud - 模块实例
]]
function Cloud.new()
	local self = setmetatable({}, Cloud)
	self.Instance = InsMgr.GetIns("Cloud", "Clouds", Terrain)
	-- GetIns 失败时通道 no-op，不影响其它大气通道
	self._terrainReady = self.Instance ~= nil
	self.Cover = 0
	self.Density = 0
	self.Color = Color3.new(1, 1, 1)
	self.TransitionTween = nil
	self.MicroMotionTween = nil
	self.IsMicroMotion = false
	self.MicroMotionRange = MICRO_MOTION_RANGE_DEFAULT
	self.MicroMotionTime = MICRO_MOTION_TIME_DEFAULT
	self._microMotionAllowed = true
	self._transitionGen = 0
	self._lastApplyGen = nil
	return self
end

--[[
	设置是否允许云层微动（低画质为 false）

	@param allowed boolean - true 允许；false 停微动且后续 start 为 no-op
	@return nil - 无返回值
]]
function Cloud.setMicroMotionAllowed(self: Cloud, allowed: boolean)
	self._microMotionAllowed = allowed == true
	if not self._microMotionAllowed then
		self:stopMicroMotion()
	end
end

--[[
	设置 Cloud 相关参数；过渡期间不启微动，完成后（或即时写后）再启

	@param newCloud Clouds - 参数模板
	@param transitionTime number - 过渡时间（秒）；0 为立即生效
	@param applyGen number? - Weather 生效意图代际（与内部 _transitionGen 双保险）
	@return nil - 无返回值
]]
function Cloud.setCloudParams(self: Cloud, newCloud: Clouds, transitionTime: number, applyGen: number?)
	if not self._terrainReady or not self.Instance then
		return
	end

	transitionTime = LightingTweenUtil.normalizeTransitionTime(transitionTime)

	self:stopMicroMotion()
	_cancelTransition(self)

	self.Cover = newCloud.Cover
	self.Density = newCloud.Density
	self.Color = newCloud.Color
	self._lastApplyGen = applyGen

	if not newCloud.Enabled then
		-- 与 PostEffect 一致：关闭通道先落地目标属性，再 Enabled=false（不做关闭 Tween）
		_setCloudParams(self, newCloud)
		self:hide()
		return
	end

	self:show()

	if transitionTime > 0 then
		local gen = self._transitionGen
		local capturedApplyGen = applyGen
		self.TransitionTween = LightingTweenUtil.playOrApply(
			nil,
			self.Instance,
			transitionTime,
			{
				Cover = self.Cover,
				Density = self.Density,
				Color = self.Color,
			},
			nil,
			function()
				if self._transitionGen ~= gen then
					return
				end
				if capturedApplyGen ~= nil and self._lastApplyGen ~= capturedApplyGen then
					return
				end
				self.TransitionTween = nil
				self:startMicroMotion()
			end
		)
	else
		_setCloudParams(self, newCloud)
		self:startMicroMotion()
	end
end

--[[
	设置微动振幅与周期

	@param range number - Cover/Density 振幅
	@param time number - 单程时间（秒）
	@return nil - 无返回值
]]
function Cloud.setMicroMotionRange(self: Cloud, range: number, time: number)
	self.MicroMotionRange = range
	self.MicroMotionTime = time
end

--[[
	启动 Cover/Density 往复微动（会先停旧微动）

	@param range number? - 可选振幅；nil 用当前 MicroMotionRange
	@param time number? - 可选周期；nil 用当前 MicroMotionTime
	@return nil - 无返回值
]]
function Cloud.startMicroMotion(self: Cloud, range: number?, time: number?)
	if not self._terrainReady or not self.Instance then
		return
	end
	if not self._microMotionAllowed then
		return
	end

	if self.IsMicroMotion then
		self:stopMicroMotion()
	end

	self.IsMicroMotion = true
	if range then
		self.MicroMotionRange = range
	end
	if time then
		self.MicroMotionTime = time
	end

	local tweenCover = math.clamp(self.Cover - self.MicroMotionRange, 0, 1)
	local tweenDensity = math.clamp(self.Density - self.MicroMotionRange, 0, 1)

	self.MicroMotionTween = TweenService:Create(
		self.Instance,
		TweenInfo.new(
			self.MicroMotionTime,
			MICRO_MOTION_EASING_STYLE,
			MICRO_MOTION_EASING_DIR,
			MICRO_MOTION_REPEAT_COUNT,
			MICRO_MOTION_REVERSES
		),
		{
			Cover = tweenCover,
			Density = tweenDensity,
		}
	)
	self.MicroMotionTween:Play()
end

--[[
	停止微动 Tween

	@return nil - 无返回值
]]
function Cloud.stopMicroMotion(self: Cloud)
	if not self.IsMicroMotion then
		return
	end

	self.IsMicroMotion = false
	LightingTweenUtil.cancelTween(self.MicroMotionTween)
	self.MicroMotionTween = nil
end

--[[
	隐藏云层并停止过渡与微动

	@return nil - 无返回值
]]
function Cloud.hide(self: Cloud)
	if not self._terrainReady or not self.Instance then
		return
	end
	_cancelTransition(self)
	self:stopMicroMotion()
	self.Instance.Enabled = false
end

--[[
	显示云层

	@return nil - 无返回值
]]
function Cloud.show(self: Cloud)
	if not self._terrainReady or not self.Instance then
		return
	end
	self.Instance.Enabled = true
end

--[[
	销毁模块

	@return nil - 无返回值
]]
function Cloud.destroy(self: Cloud)
	self:stopMicroMotion()
	self:hide()
end

return Cloud
