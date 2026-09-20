--[[
	Module: SystemLighting
	Description: 客户端大气效果控制，统一管理 Lighting 服务与各 PostEffect 组件
	Author: 林奥宇
	Created: 2026-01-23
	Last Modified: 2026-08-31

	功能：
	- 按 Configuration 应用天气基线（Lighting 属性 + Cloud/Sky/Atmosphere 等通道）
	- 单通道从天气包恢复 / 按 Instance 应用自定义叠加
	- 单独设置时钟时间
	- 低画质跳过 Bloom/DoF/SunRays，并关闭 Cloud 微动
	- 低→高不 restore 被 skip 通道：须 SystemLightingWeather.reapplyEffective（QualityGate 已绑定）
	- applyWeatherBase 第三返回值 skipReason：FxBusy / QualitySkip（预期跳过，供 LightingSkipReason）

	写者优先级（同通道）：
	1. FxLease — 仅 ColorCorrection；Lighting.FXUtilCcBusy=true 时跳过写 Instance
	2. CustomOverlay — SystemLightingCustomState 同 ClassName 按权重择优后覆盖
	3. WeatherBase — 天气配置包；缺子 Instance 则 hide

	通道显隐：
	- 由各 set*（按 Enabled / Parent）或缺配置时的 hide 负责
	- CHANNELS.apply 不再抢先 show，避免 Enabled=false 模板闪一帧
	- PostEffect 关闭不做属性 Tween：先即时写目标属性，再 Enabled=false（对齐 Cloud）

	失败隔离：
	- applyWeatherBase / applyChannelFromConfig / applyEffectFromInstance 对通道 apply/hide 使用 pcall
	- 单通道抛错不中断其余通道；applyWeatherBase 返回 false 并带首个错误文案

	applyEffectFromInstance 第二返回值为 EnumMgr.LightingApplyResult

	与 FXUtil：
	- 技能/演出滤镜曲线用 FXUtil.PlayColorCorrectionCurve（占租约）
	- 天气与 UI 模糊等走本栈；租约释放后由 LightingManager 仅 reconcile CC
	- applyGen：Weather 每次全量/增量 apply 前 bump；全通道 Tween Completed 校验作废过期副作用
	- 过渡缓动：GameConfig.LightingTween（缓动样式 / 缓动方向）

	单例与封装：
	- 合法创建仅 SystemLightingWeather 调用 createForOwner("SystemLightingWeather")
	- 业务 Utils.SystemLighting.new 恒返回 nil（硬闸门，不回已有单例）
	- 子通道为 _ 私有字段，对外仅 beginApplyGeneration / apply* / setClockTime / getClockTime / setGraphicsQualityLow / destroy
	- destroy() 后可由 Weather 再次 createForOwner
	- 天气 lease / baseline 编排见 SystemLightingWeather；本模块只做通道写入

	子模块（内部）：
	- Lighting / Cloud / Atmosphere / Sky / ColorCorrection / Bloom / Blur / DepthOfField / SunRays
	- EffectChannelUtil / PostEffectChannel（私有工具，不进 Utils）
	- 通道结果：Utils.ChannelResultUtil（ToolBasic；Weather ApplyPipeline 同用）
	- 过渡：Utils.LightingTweenUtil（ToolBasic；Weather 同用）

	使用（经 SystemLightingWeather / LightingManager；业务勿直接 new）：
	local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
	local weather = Utils.SystemLightingWeather.Init()
	weather:setBaseline("Day", 5)
	weather:setClockTime(18, 0)
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Log = Utils.Log
local EnumMgr = Utils.EnumMgr
local LightingTweenUtil = Utils.LightingTweenUtil
local ChannelResultUtil = Utils.ChannelResultUtil

local Cloud = require(script.Cloud)
local Atmosphere = require(script.Atmosphere)
local Bloom = require(script.Bloom)
local Blur = require(script.Blur)
local ColorCorrection = require(script.ColorCorrection)
local SkyEffect = require(script.Sky)
local DepthOfField = require(script.DepthOfField)
local SunRays = require(script.SunRays)
local LightingSettings = require(script.Lighting)

-- ========================================
-- 常量 / 类型
-- ========================================
local LightingQualityLowSkipClass = EnumMgr.LightingQualityLowSkipClass
local LightingApplyResult = EnumMgr.LightingApplyResult
local CC_CLASS_NAME = "ColorCorrectionEffect"

export type SystemLighting = {
	createForOwner: (ownerKey: string) -> SystemLighting?,
	new: () -> SystemLighting?,
	beginApplyGeneration: (self: SystemLighting) -> number,
	getActiveApplyGen: (self: SystemLighting) -> number,
	applyWeatherBase: (
		self: SystemLighting,
		newLighting: Configuration,
		transitionTime: number
	) -> (boolean, string?, string?),
	applyChannelFromConfig: (
		self: SystemLighting,
		config: Configuration,
		className: string,
		transitionTime: number
	) -> (boolean, string?, string?),
	setClockTime: (self: SystemLighting, clockTime: number, transitionTime: number) -> nil,
	getClockTime: (self: SystemLighting) -> number,
	applyEffectFromInstance: (self: SystemLighting, effectInstance: Instance, transitionTime: number) -> (boolean, string),
	setGraphicsQualityLow: (self: SystemLighting, isLow: boolean) -> nil,
	destroy: (self: SystemLighting) -> nil,
}

local OWNER_KEY = "SystemLightingWeather"

type ChannelDef = {
	className: string,
	apply: (self: SystemLighting, effectInstance: Instance, transitionTime: number, applyGen: number) -> boolean | string,
	hide: (self: SystemLighting) -> (boolean, string),
}

-- ========================================
-- 模块定义
-- ========================================
local SystemLighting = {}
SystemLighting.__index = SystemLighting

local _singleton: SystemLighting? = nil

--[[
	通道表：天气包子 Instance 与 applyEffectFromInstance 共用
	显隐由各 set* / hide 负责，apply 不抢先 show
]]
local CHANNELS: { ChannelDef } = {
	{
		className = "Clouds",
		apply = function(self, effectInstance, transitionTime, applyGen)
			self._cloud:setCloudParams(effectInstance :: Clouds, transitionTime, applyGen)
			return true
		end,
		hide = function(self)
			self._cloud:hide()
			return true, LightingApplyResult.Ok
		end,
	},
	{
		className = "Atmosphere",
		apply = function(self, effectInstance, transitionTime, applyGen)
			self._atmosphere:setAtmosphereParams(effectInstance :: Atmosphere, transitionTime, applyGen)
			return true
		end,
		hide = function(self)
			self._atmosphere:hide()
			return true, LightingApplyResult.Ok
		end,
	},
	{
		className = "Sky",
		apply = function(self, effectInstance, transitionTime, applyGen)
			self._sky:setSkyParams(effectInstance :: Sky, transitionTime, applyGen)
			return true
		end,
		hide = function(self)
			self._sky:hide()
			return true, LightingApplyResult.Ok
		end,
	},
	{
		className = CC_CLASS_NAME,
		apply = function(self, effectInstance, transitionTime, applyGen)
			return self._colorCorrection:setColorCorrectionParams(
				effectInstance :: ColorCorrectionEffect,
				transitionTime,
				applyGen
			)
		end,
		hide = function(self)
			-- hide 返回 LightingApplyResult；Ok / FxBusy 均为 handled
			return true, self._colorCorrection:hide()
		end,
	},
	{
		className = "BloomEffect",
		apply = function(self, effectInstance, transitionTime, applyGen)
			self._bloom:setBloomParams(effectInstance :: BloomEffect, transitionTime, applyGen)
			return true
		end,
		hide = function(self)
			self._bloom:hide()
			return true, LightingApplyResult.Ok
		end,
	},
	{
		className = "BlurEffect",
		apply = function(self, effectInstance, transitionTime, applyGen)
			self._blur:setBlurParams(effectInstance :: BlurEffect, transitionTime, applyGen)
			return true
		end,
		hide = function(self)
			self._blur:hide()
			return true, LightingApplyResult.Ok
		end,
	},
	{
		className = "SunRaysEffect",
		apply = function(self, effectInstance, transitionTime, applyGen)
			self._sunRays:setSunRaysParams(effectInstance :: SunRaysEffect, transitionTime, applyGen)
			return true
		end,
		hide = function(self)
			self._sunRays:hide()
			return true, LightingApplyResult.Ok
		end,
	},
	{
		className = "DepthOfFieldEffect",
		apply = function(self, effectInstance, transitionTime, applyGen)
			self._depthOfField:setDepthOfFieldParams(effectInstance :: DepthOfFieldEffect, transitionTime, applyGen)
			return true
		end,
		hide = function(self)
			self._depthOfField:hide()
			return true, LightingApplyResult.Ok
		end,
	},
}

local CHANNEL_BY_CLASS: { [string]: ChannelDef } = {}
for _, ch in CHANNELS do
	CHANNEL_BY_CLASS[ch.className] = ch
end

-- ========================================
-- 私有函数
-- ========================================
--[[
	低画质是否应跳过该通道

	@param self SystemLighting - 本模块
	@param className string - 效果 ClassName
	@return boolean - true 应 hide 且不 apply
]]
local function _shouldSkipChannel(self: SystemLighting, className: string): boolean
	return self._graphicsQualityLow == true and LightingQualityLowSkipClass[className] == true
end

--[[
	pcall 包装通道 hide；失败记 Log

	@param self SystemLighting - 本模块
	@param ch ChannelDef - 通道定义
	@return boolean - true 无硬错误（含 FxBusy 预期跳过）
	@return string? - 硬错误文案
	@return string? - 预期 skipReason（FxBusy / QualitySkip）
]]
local function _safeHide(self: SystemLighting, ch: ChannelDef): (boolean, string?, string?)
	local ok, handled, resultCode = pcall(ch.hide, self)
	if not ok then
		local msg = "hide " .. ch.className .. ": " .. tostring(handled)
		Log.warn("SystemLighting: 通道 hide 失败", ch.className, handled)
		return false, msg, nil
	end
	return ChannelResultUtil.fromHideResult(handled, resultCode, ch.className)
end

--[[
	pcall 包装通道 apply；失败记 Log

	@param self SystemLighting - 本模块
	@param ch ChannelDef - 通道定义
	@param effectInstance Instance - 模板
	@param transitionTime number - 过渡秒数
	@return boolean - true 无硬错误（含 CC FxBusy 跳过）
	@return string? - 硬错误文案
	@return string? - 预期 skipReason
]]
local function _safeApply(
	self: SystemLighting,
	ch: ChannelDef,
	effectInstance: Instance,
	transitionTime: number
): (boolean, string?, string?)
	local ok, resultOrErr = pcall(ch.apply, self, effectInstance, transitionTime, self._activeApplyGen)
	if not ok then
		local msg = "apply " .. ch.className .. ": " .. tostring(resultOrErr)
		Log.warn("SystemLighting: 通道 apply 失败", ch.className, resultOrErr)
		return false, msg, nil
	end
	return ChannelResultUtil.fromApplyResult(resultOrErr :: boolean | string, nil, ch.className)
end

--[[
	创建单例实例（仅 createForOwner 合法路径调用）

	@return SystemLighting - 大气控制实例
]]
local function _createInstance(): SystemLighting
	local self = setmetatable({}, SystemLighting)
	self._lighting = LightingSettings.new()
	self._cloud = Cloud.new()
	self._atmosphere = Atmosphere.new()
	self._sky = SkyEffect.new()
	self._colorCorrection = ColorCorrection.new()
	self._bloom = Bloom.new()
	self._depthOfField = DepthOfField.new()
	self._blur = Blur.new()
	self._sunRays = SunRays.new()
	self._graphicsQualityLow = false
	self._activeApplyGen = 0
	_singleton = self
	return self
end

-- ========================================
-- 公共函数
-- ========================================
--[[
	Weather 专用：校验 ownerKey 后创建或返回单例

	@param ownerKey string - 必须为 "SystemLightingWeather"
	@return SystemLighting? - 实例；非法 key 为 nil
]]
function SystemLighting.createForOwner(ownerKey: string): SystemLighting?
	if ownerKey ~= OWNER_KEY then
		Log.warn("SystemLighting: createForOwner 非法 ownerKey，拒绝创建", ownerKey)
		return nil
	end
	if _singleton then
		Log.warn("SystemLighting: createForOwner 重复调用，返回已有单例")
		return _singleton
	end
	return _createInstance()
end

--[[
	兼容入口（业务禁用）：恒返回 nil；请经 SystemLightingWeather.createForOwner

	@return nil - 始终 nil（硬闸门，即使已有单例也不返回）
]]
function SystemLighting.new(): SystemLighting?
	Log.warn("SystemLighting: 禁止业务 new；请经 SystemLightingWeather / LightingManager Bindable")
	return nil
end

--[[
	开始新一轮生效意图代际（Weather apply / reconcile 前调用）

	@return number - 新的 applyGen
]]
function SystemLighting.beginApplyGeneration(self: SystemLighting): number
	self._activeApplyGen += 1
	return self._activeApplyGen
end

--[[
	当前生效意图代际

	@return number - applyGen
]]
function SystemLighting.getActiveApplyGen(self: SystemLighting): number
	return self._activeApplyGen
end

--[[
	设置低画质模式（跳过 Bloom/DoF/SunRays；关闭 Cloud 微动）

	边界语义：
	- 切至低：立即 hide 被 skip 的 PostEffect 通道
	- 低→高：本模块不 restore 被 skip 通道；须 SystemLightingWeather.reapplyEffective
	  （QualityGate.bind 在画质变化且 Init 首次 apply 完成后自动 reapply）
	- 同档重复调用：仅同步 Cloud 微动开关

	@param isLow boolean - true 为低画质
	@return nil - 无返回值
]]
function SystemLighting.setGraphicsQualityLow(self: SystemLighting, isLow: boolean)
	local nextLow = isLow == true
	if self._graphicsQualityLow == nextLow then
		self._cloud:setMicroMotionAllowed(not nextLow)
		return
	end

	self._graphicsQualityLow = nextLow
	self._cloud:setMicroMotionAllowed(not nextLow)

	if nextLow then
		for className in LightingQualityLowSkipClass do
			local ch = CHANNEL_BY_CLASS[className]
			if ch then
				_safeHide(self, ch)
			end
		end
	end
end

--[[
	应用天气基线（Lighting 属性 + 各效果通道；缺子 Instance 则 hide）

	@param newLighting Configuration - 天气配置（含 Attribute 与子效果 Instance）
	@param transitionTime number - 过渡时间（秒）；0 为立即生效
	@return boolean - true 全部成功；false 至少一处硬错误（其余通道仍继续）
	@return string? - 首个硬错误文案
	@return string? - 预期 skipReason（FxBusy / QualitySkip）；无则 nil
]]
function SystemLighting.applyWeatherBase(
	self: SystemLighting,
	newLighting: Configuration,
	transitionTime: number
): (boolean, string?, string?)
	transitionTime = LightingTweenUtil.normalizeTransitionTime(transitionTime)
	local firstError: string? = nil
	local skipReason: string? = nil

	local lightOk, lightErr = pcall(function()
		self._lighting:setLightingParams(newLighting, transitionTime, self._activeApplyGen)
	end)
	if not lightOk then
		firstError = "Lighting 属性: " .. tostring(lightErr)
		Log.warn("SystemLighting: setLightingParams 失败", lightErr)
	end

	for _, ch in CHANNELS do
		local ok: boolean
		local err: string?
		local skip: string?
		if _shouldSkipChannel(self, ch.className) then
			ok, err, skip = _safeHide(self, ch)
			skip = ChannelResultUtil.mergeSkipReason(LightingApplyResult.QualitySkip, skip)
		else
			local inst = newLighting:FindFirstChildOfClass(ch.className)
			if inst then
				ok, err, skip = _safeApply(self, ch, inst, transitionTime)
			else
				ok, err, skip = _safeHide(self, ch)
			end
		end
		firstError, skipReason = ChannelResultUtil.accumulateOutcome(
			firstError,
			skipReason,
			ok,
			err or (if not ok then ("通道失败: " .. ch.className) else nil),
			skip
		)
	end

	return firstError == nil, firstError, skipReason
end

--[[
	从天气配置包恢复单个效果通道（无子 Instance 则 hide）

	@param config Configuration - 天气配置
	@param className string - 效果 ClassName（如 "BlurEffect"）
	@param transitionTime number - 过渡时间（秒）
	@return boolean - true 已处理已知通道且无硬错误
	@return string? - 硬错误文案
	@return string? - 预期 skipReason
]]
function SystemLighting.applyChannelFromConfig(
	self: SystemLighting,
	config: Configuration,
	className: string,
	transitionTime: number
): (boolean, string?, string?)
	local ch = CHANNEL_BY_CLASS[className]
	if not ch then
		return false, "unknown class: " .. className, nil
	end

	transitionTime = LightingTweenUtil.normalizeTransitionTime(transitionTime)
	if _shouldSkipChannel(self, className) then
		local ok, err, skip = _safeHide(self, ch)
		local mergedSkip = ChannelResultUtil.mergeSkipReason(LightingApplyResult.QualitySkip, skip)
		if not ok then
			return false, err, mergedSkip
		end
		return true, nil, mergedSkip
	end

	local inst = config:FindFirstChildOfClass(className)
	if inst then
		local ok, err, skip = _safeApply(self, ch, inst, transitionTime)
		if not ok then
			return false, err, skip
		end
		return true, nil, skip
	end

	local ok, err, skip = _safeHide(self, ch)
	if not ok then
		return false, err, skip
	end
	return true, nil, skip
end

--[[
	设置时钟时间

	@param clockTime number - 时钟时间（0–24，内部 clamp）
	@param transitionTime number - 过渡时间（秒）；0 为立即生效
	@return nil - 无返回值
]]
function SystemLighting.setClockTime(self: SystemLighting, clockTime: number, transitionTime: number)
	self._lighting:setClockTime(clockTime, LightingTweenUtil.normalizeTransitionTime(transitionTime))
end

--[[
	读取缓存的逻辑时钟

	@return number - 最近一次 setClockTime 的目标值（0–24）
]]
function SystemLighting.getClockTime(self: SystemLighting): number
	return self._lighting:getClockTime()
end

--[[
	按 Instance 类型应用单个大气效果（供自定义状态叠加）

	@param effectInstance Instance - 效果模板 Instance（只读；勿改属性）
	@param transitionTime number - 过渡时间（秒）；0 为立即生效
	@return boolean - true 已应用（或已启动 Tween）
	@return string - EnumMgr.LightingApplyResult 结果码
]]
function SystemLighting.applyEffectFromInstance(
	self: SystemLighting,
	effectInstance: Instance,
	transitionTime: number
): (boolean, string)
	if not effectInstance then
		return false, LightingApplyResult.InvalidArg
	end

	local className = effectInstance.ClassName
	local ch = CHANNEL_BY_CLASS[className]
	if not ch then
		return false, LightingApplyResult.UnknownClass
	end

	if _shouldSkipChannel(self, className) then
		_safeHide(self, ch)
		return false, LightingApplyResult.QualitySkip
	end

	local ok, err, skip = _safeApply(
		self,
		ch,
		effectInstance,
		LightingTweenUtil.normalizeTransitionTime(transitionTime)
	)
	if not ok then
		return false, LightingApplyResult.ChannelError
	end
	if skip then
		return false, skip
	end

	return true, LightingApplyResult.Ok
end

--[[
	销毁大气控制，释放各子模块 Tween 与引用，并清空单例

	@return nil - 无返回值
]]
function SystemLighting.destroy(self: SystemLighting)
	self._lighting:destroy()
	self._cloud:destroy()
	self._atmosphere:destroy()
	self._sky:destroy()
	self._colorCorrection:destroy()
	self._bloom:destroy()
	self._depthOfField:destroy()
	self._blur:destroy()
	self._sunRays:destroy()
	if _singleton == self then
		_singleton = nil
	end
end

return SystemLighting
