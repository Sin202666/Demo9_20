--[[
	Module: SystemLightingWeather/ApplyPipeline
	Description: 天气配置查找、Attribute 同步、生效层 apply / reconcile
	Author: 林奥宇
	Created: 2026-08-04
	Last Modified: 2026-08-31

	观测语义（意图 vs 落地）：
	- CurrentLightingName：意图名（lease 优胜或 baseline）；sync 即可更新
	- LightingAppliedName / host._effectiveName：最近一次天气 apply 成功落地的配置名
	- 缺配置 / 天气硬失败：保留上一画面与 AppliedName，不推进 _effectiveName（避免同名短路粘住）
	- 判断落地：Pending==false 且 AppliedName==CurrentLightingName 且 LastError==nil
	- 天气 applyOk 后即 commit AppliedName（含随后 overlay 预期 held）；overlay 硬 held 仍 commit 天气名，LastError 另标 overlay

	reconcileChannel：Overlay 三态 applied/held 均不回退 Weather；仅 none 走天气包。
	applyEffectiveWeather：先 bump applyGen，再天气基线 + overlay 三态汇总。
	LastError：缺配置 / schema 失败 / 天气通道硬错误 / overlay 硬 held（ChannelError 等）。
	FxBusy / QualitySkip 仅写 LightingSkipReason，不污染 LastError；天气成功时视为成功。
	天气 applyWeatherBase 第三返回值与 overlay skipReason 经 ChannelResultUtil.mergeSkipReason 合并。
	预期跳过判定委托 Utils.ChannelResultUtil.isExpectedSkip（单一真相源）。
	调试 Attribute：LightingOverlayTop / LightingSkipReason / LightingAppliedName。

	schema（validateLightingConfig）：
	- 已出现的 Lighting 属性类型必须匹配（缺省允许，运行时回退当前服务值）
	- 白名单通道 ClassName 不得重复；子 Instance ClassName 须等于自身类型名

	applyEffectiveIfChanged：仅同步辅助（测试 / Init 直调）；生产全量 / 增量 reconcile 必须经
	SystemLightingWeather 同帧 coalesce（_requestFullApply / _requestReconcileChannel），勿绕过合并。
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Log = Utils.Log
local Lighting = Utils.Lighting
local ChannelResultUtil = Utils.ChannelResultUtil
local LeaseStack = require(script.Parent.LeaseStack)

export type WeatherLease = LeaseStack.WeatherLease

local ApplyPipeline = {}

-- 与 SystemLighting CHANNELS / LightingSettings 对齐的配置契约
local LIGHTING_ATTR_TYPES: { [string]: string } = {
	Ambient = "Color3",
	Brightness = "number",
	EnvironmentDiffuseScale = "number",
	EnvironmentSpecularScale = "number",
	ExposureCompensation = "number",
	ShadowSoftness = "number",
	OutdoorAmbient = "Color3",
	GeographicLatitude = "number",
}

local KNOWN_CHANNEL_CLASS: { [string]: boolean } = {
	Clouds = true,
	Atmosphere = true,
	Sky = true,
	ColorCorrectionEffect = true,
	BloomEffect = true,
	BlurEffect = true,
	SunRaysEffect = true,
	DepthOfFieldEffect = true,
}

export type AttrNames = {
	currentLighting: string,
	baselineLighting: string,
	leaseCount: string,
	topLeaseWriter: string,
	lastError: string,
	overlayTop: string,
	skipReason: string,
	-- 最近一次天气 apply 成功落地名；与 currentLighting（意图）对照判断落地
	appliedLighting: string?,
	staleLeaseWriters: string?,
	applyPending: string?,
	bootReady: string?,
}

export type OverlayBatchSummary = {
	hasHeld: boolean,
	heldMessage: string?,
	skipReason: string?,
	overlayTop: string?,
}

export type LightingSystemHost = {
	beginApplyGeneration: ((self: LightingSystemHost) -> number)?,
	applyWeatherBase: (self: LightingSystemHost, newLighting: Configuration, transitionTime: number) -> (boolean, string?, string?),
	applyChannelFromConfig: (
		self: LightingSystemHost,
		config: Configuration,
		className: string,
		transitionTime: number
	) -> (boolean, string?, string?),
	applyEffectFromInstance: (self: LightingSystemHost, effectInstance: Instance, transitionTime: number) -> (boolean, string),
	setGraphicsQualityLow: (self: LightingSystemHost, isLow: boolean) -> (),
}

export type CustomStateHost = {
	getOverlayTopNames: ((self: CustomStateHost) -> string?)?,
	tryApplyWinningOverlay: (
		self: CustomStateHost,
		lightingSystem: LightingSystemHost,
		className: string,
		transitionTime: number
	) -> ("applied" | "held" | "none", string?),
	applyAllWinningOverlays: (
		self: CustomStateHost,
		lightingSystem: LightingSystemHost,
		transitionTime: number
	) -> OverlayBatchSummary,
}

export type WeatherHost = {
	_configFolder: Folder?,
	_baselineName: string,
	-- 最近一次天气 apply 成功落地名（同名短路用）；非意图名
	_effectiveName: string,
	_leases: { [string]: WeatherLease },
	_lightingSystem: LightingSystemHost,
	_customState: CustomStateHost,
}

-- ========================================
-- 私有函数
-- ========================================
--[[
	天气 apply 成功后提交落地名（_effectiveName + LightingAppliedName）

	@param host WeatherHost - Weather 实例
	@param attrs AttrNames - Attribute 名表
	@param appliedName string - 已成功 apply 的配置名
	@return nil - 无返回值
]]
local function _commitAppliedWeatherName(host: WeatherHost, attrs: AttrNames, appliedName: string)
	host._effectiveName = appliedName
	local attrName = attrs.appliedLighting
	if attrName then
		Lighting:SetAttribute(attrName, appliedName)
	end
end

--[[
	Applied Attribute 展示值：空字符串表示尚未成功落地

	@param appliedName string - host._effectiveName
	@return string? - Attribute 值；未落地为 nil
]]
local function _appliedAttrValue(appliedName: string): string?
	if appliedName == "" then
		return nil
	end
	return appliedName
end

-- ========================================
-- 公共函数
-- ========================================
--[[
	是否为预期 held（不写 LastError）；委托 ChannelResultUtil.isExpectedSkip

	@param skipReason string? - LightingSkipReason
	@return boolean - true 表示 FxBusy / QualitySkip
]]
function ApplyPipeline.isExpectedHold(skipReason: string?): boolean
	return ChannelResultUtil.isExpectedSkip(skipReason)
end

--[[
	写入或清空 LightingLastError

	@param attrLastError string - Attribute 名
	@param message string? - 错误文案；nil 清空
	@return nil - 无返回值
]]
function ApplyPipeline.setLastError(attrLastError: string, message: string?)
	Lighting:SetAttribute(attrLastError, message)
end

--[[
	同步 overlay 调试 Attribute

	@param attrs AttrNames - Attribute 名表
	@param overlayTop string? - 优胜状态名
	@param skipReason string? - 跳过写原因；false 表示不改 skipReason
	@return nil - 无返回值
]]
function ApplyPipeline.setOverlayDebug(
	attrs: AttrNames,
	overlayTop: string?,
	skipReason: string | boolean?
)
	Lighting:SetAttribute(attrs.overlayTop, overlayTop)
	if skipReason ~= false then
		Lighting:SetAttribute(attrs.skipReason, skipReason :: string?)
	end
end

--[[
	校验天气 Configuration schema（类型契约；不要求属性/通道齐全）

	@param config Configuration - 天气配置
	@return boolean - true 通过
	@return string? - 失败原因
]]
function ApplyPipeline.validateLightingConfig(config: Configuration): (boolean, string?)
	for attrName, expectedType in LIGHTING_ATTR_TYPES do
		local v = config:GetAttribute(attrName)
		if v ~= nil and typeof(v) ~= expectedType then
			return false, ("Attribute %s 类型无效: 期望 %s 实际 %s"):format(attrName, expectedType, typeof(v))
		end
	end

	local seenClass: { [string]: boolean } = {}
	for _, child in config:GetChildren() do
		local className = child.ClassName
		if KNOWN_CHANNEL_CLASS[className] then
			if seenClass[className] then
				return false, ("通道 ClassName 重复: %s"):format(className)
			end
			seenClass[className] = true
			if not child:IsA(className) then
				return false, ("通道类型不符: %s 声明为 %s"):format(child.Name, className)
			end
		end
	end

	return true, nil
end

--[[
	查找天气配置（含 schema）；失败写 LastError 并返回 nil（调用方保留上一画面）

	@param host WeatherHost - Weather 实例字段
	@param lightingName string - 配置名
	@param attrLastError string - LastError Attribute 名
	@return Configuration? - 配置
]]
function ApplyPipeline.findLightingConfig(
	host: WeatherHost,
	lightingName: string,
	attrLastError: string
): Configuration?
	local folder = host._configFolder
	if not folder then
		return nil
	end

	local lightingConfig = folder:FindFirstChild(lightingName)
	if not lightingConfig then
		return nil
	end
	if not lightingConfig:IsA("Configuration") then
		Log.warn("SystemLightingWeather: 天气配置类型无效", lightingName, lightingConfig.ClassName)
		ApplyPipeline.setLastError(attrLastError, "天气配置类型无效: " .. lightingName)
		return nil
	end

	local schemaOk, schemaErr = ApplyPipeline.validateLightingConfig(lightingConfig :: Configuration)
	if not schemaOk then
		Log.warn("SystemLightingWeather: 天气配置 schema 失败", lightingName, schemaErr)
		ApplyPipeline.setLastError(attrLastError, "天气配置 schema 失败: " .. lightingName .. " / " .. tostring(schemaErr))
		return nil
	end

	return lightingConfig :: Configuration
end

--[[
	计算生效天气名

	@param host WeatherHost - Weather 实例
	@return string - lease 名或 baseline
]]
function ApplyPipeline.getEffectiveWeatherName(host: WeatherHost): string
	local winning = LeaseStack.getWinningLease(host._leases)
	if winning then
		return winning.name
	end
	return host._baselineName
end

--[[
	同步调试 Attribute（意图名 + lease 元数据；不推进落地名 _effectiveName）

	@param host WeatherHost - Weather 实例
	@param attrs AttrNames - Attribute 名表
	@return nil - 无返回值
]]
function ApplyPipeline.syncLightingNameAttributes(host: WeatherHost, attrs: AttrNames)
	local desiredName = ApplyPipeline.getEffectiveWeatherName(host)
	Lighting:SetAttribute(attrs.currentLighting, desiredName)
	local appliedAttr = attrs.appliedLighting
	if appliedAttr then
		Lighting:SetAttribute(appliedAttr, _appliedAttrValue(host._effectiveName))
	end
	Lighting:SetAttribute(attrs.baselineLighting, host._baselineName)
	Lighting:SetAttribute(attrs.leaseCount, LeaseStack.countLeases(host._leases))
	local _, topWriter = LeaseStack.getWinningLease(host._leases)
	Lighting:SetAttribute(attrs.topLeaseWriter, topWriter)
	if host._customState.getOverlayTopNames then
		Lighting:SetAttribute(attrs.overlayTop, host._customState:getOverlayTopNames())
	end
end

--[[
	apply 生效天气 + overlay（bump applyGen）

	@param host WeatherHost - Weather 实例
	@param attrs AttrNames - Attribute 名表
	@param transitionTime number - 过渡秒数
	@return boolean - 是否成功（缺配置 / 天气失败 / overlay 硬 held 为 false；预期 held 为 true）
]]
function ApplyPipeline.applyEffectiveWeather(host: WeatherHost, attrs: AttrNames, transitionTime: number): boolean
	if host._lightingSystem.beginApplyGeneration then
		host._lightingSystem:beginApplyGeneration()
	end

	local desiredName = ApplyPipeline.getEffectiveWeatherName(host)
	ApplyPipeline.syncLightingNameAttributes(host, attrs)
	local lightingConfig = ApplyPipeline.findLightingConfig(host, desiredName, attrs.lastError)
	if not lightingConfig then
		Log.warn("SystemLightingWeather: 缺少天气配置，保留上一画面", desiredName)
		if host._configFolder == nil then
			ApplyPipeline.setLastError(attrs.lastError, "缺少 LightingConfig 目录")
		else
			ApplyPipeline.setLastError(attrs.lastError, "缺少天气配置: " .. desiredName)
		end
		return false
	end

	local applyOk, applyErr, weatherSkip = host._lightingSystem:applyWeatherBase(lightingConfig, transitionTime)
	local summary = host._customState:applyAllWinningOverlays(host._lightingSystem, transitionTime)

	local mergedSkip = ChannelResultUtil.mergeSkipReason(weatherSkip, summary.skipReason)
	ApplyPipeline.setOverlayDebug(attrs, summary.overlayTop, mergedSkip)

	if not applyOk then
		-- 不推进 AppliedName / _effectiveName，便于同名重试与意图/落地铁对
		ApplyPipeline.setLastError(attrs.lastError, "天气通道 apply 失败: " .. tostring(applyErr))
		return false
	end

	_commitAppliedWeatherName(host, attrs, desiredName)

	if summary.hasHeld then
		if ApplyPipeline.isExpectedHold(summary.skipReason) then
			-- 预期跳过：天气已落地；只保留 SkipReason，清空硬错误
			ApplyPipeline.setLastError(attrs.lastError, nil)
			return true
		end
		ApplyPipeline.setLastError(attrs.lastError, summary.heldMessage or "overlay held")
		return false
	end

	ApplyPipeline.setLastError(attrs.lastError, nil)
	if mergedSkip == nil then
		Lighting:SetAttribute(attrs.skipReason, nil)
	end
	return true
end

--[[
	生效名变化或 force 时同步 apply（无同帧 coalesce）

	仅供 ValidationTest / 需立即落地的同步路径。生产全量 / 增量 apply 必须经
	SystemLightingWeather coalesce（_requestFullApply / _requestReconcileChannel），勿直接调用本函数绕过合并。
	同名短路对比 host._effectiveName（最近成功落地名），非 CurrentLightingName 意图名。

	@param host WeatherHost - Weather 实例
	@param attrs AttrNames - Attribute 名表
	@param transitionTime number - 过渡秒数
	@param force boolean? - 强制重放
	@return boolean - 是否成功/noop
]]
function ApplyPipeline.applyEffectiveIfChanged(
	host: WeatherHost,
	attrs: AttrNames,
	transitionTime: number,
	force: boolean?
): boolean
	local nextName = ApplyPipeline.getEffectiveWeatherName(host)
	if not force and nextName == host._effectiveName then
		ApplyPipeline.syncLightingNameAttributes(host, attrs)
		return true
	end
	return ApplyPipeline.applyEffectiveWeather(host, attrs, transitionTime)
end

--[[
	reconcile 单通道：overlay 优先（applied/held 不回退），否则天气包

	@param host WeatherHost - Weather 实例
	@param attrs AttrNames - Attribute 名表
	@param className string - ClassName
	@param transitionTime number - 过渡秒数
	@return nil - 无返回值
]]
function ApplyPipeline.reconcileChannel(
	host: WeatherHost,
	attrs: AttrNames,
	className: string,
	transitionTime: number
)
	if host._lightingSystem.beginApplyGeneration then
		host._lightingSystem:beginApplyGeneration()
	end

	local overlayTop = if host._customState.getOverlayTopNames
		then host._customState:getOverlayTopNames()
		else nil
	local overlayResult, skipReason = host._customState:tryApplyWinningOverlay(
		host._lightingSystem,
		className,
		transitionTime
	)

	if overlayResult == "applied" or overlayResult == "held" then
		ApplyPipeline.setOverlayDebug(attrs, overlayTop, if overlayResult == "held" then skipReason else nil)
		if overlayResult == "held" then
			if ApplyPipeline.isExpectedHold(skipReason) then
				-- 预期 held：不写 LastError
			elseif skipReason then
				ApplyPipeline.setLastError(attrs.lastError, "overlay held: " .. className)
			end
		end
		return
	end

	ApplyPipeline.setOverlayDebug(attrs, overlayTop, nil)

	local effectiveName = ApplyPipeline.getEffectiveWeatherName(host)
	local lightingConfig = ApplyPipeline.findLightingConfig(host, effectiveName, attrs.lastError)
	if lightingConfig then
		local ok, err, weatherSkip = host._lightingSystem:applyChannelFromConfig(
			lightingConfig,
			className,
			transitionTime
		)
		if not ok and err then
			ApplyPipeline.setLastError(attrs.lastError, err)
		elseif weatherSkip and ApplyPipeline.isExpectedHold(weatherSkip) then
			ApplyPipeline.setOverlayDebug(attrs, overlayTop, weatherSkip)
		end
	else
		Log.warn("SystemLightingWeather: reconcile 缺配置", effectiveName, className)
		if host._configFolder == nil then
			ApplyPipeline.setLastError(attrs.lastError, "缺少 LightingConfig 目录")
		elseif Lighting:GetAttribute(attrs.lastError) == nil then
			ApplyPipeline.setLastError(attrs.lastError, "缺少天气配置: " .. effectiveName)
		end
	end
end

return ApplyPipeline
