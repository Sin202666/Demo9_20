--[[
	Module: ApplyPipelineValidationTest
	Description: SystemLightingWeather/ApplyPipeline 验收用例（Studio require + runAll）
	Author: 中台组 林奥宇
	Created: 2026-08-04
	Last Modified: 2026-08-05

	覆盖：预期 held / 硬 held / 缺配置 / schema / 意图与落地 Attribute / _effectiveName 不误推进
	运行方式：在 Studio 中 require 本模块并调用 runAll()
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Lighting = Utils.Lighting
local EnumMgr = Utils.EnumMgr
local ApplyPipeline = require(script.Parent.ApplyPipeline)
local DebugAttrs = require(script.Parent.DebugAttrs)
local EffectChannelUtil = require(script.Parent.Parent.SystemLighting.EffectChannelUtil)

local ATTRS = DebugAttrs
local LightingApplyResult = EnumMgr.LightingApplyResult

local M = {}

--[[
	断言并累计结果

	@param name string - 用例名
	@param cond boolean - 条件
	@param passed number - 通过数
	@param failed number - 失败数
	@return number - 新通过数
	@return number - 新失败数
]]
local function _check(name: string, cond: boolean, passed: number, failed: number): (number, number)
	if cond then
		print(("[ApplyPipelineValidationTest] %s: 通过"):format(name))
		return passed + 1, failed
	end
	warn(("[ApplyPipelineValidationTest] %s: 失败"):format(name))
	return passed, failed + 1
end

--[[
	构造可注入的 WeatherHost mock

	@param opts table - 行为开关（hasConfig / weatherOk / overlayHeld / overlaySkip / weatherSkip / appliedName）
	@return ApplyPipeline.WeatherHost - mock
	@return table - 计数器
]]
local function _makeHost(opts: {
	hasConfig: boolean?,
	weatherOk: boolean?,
	overlayHeld: boolean?,
	overlaySkip: string?,
	weatherSkip: string?,
	appliedName: string?,
}): (any, { weatherCalls: number })
	local counters = { weatherCalls = 0 }
	local configFolder: Folder? = nil
	if opts.hasConfig ~= false then
		local folder = Instance.new("Folder")
		folder.Name = "_ApplyPipelineTestConfig"
		local cfg = Instance.new("Configuration")
		cfg.Name = "Day"
		cfg.Parent = folder
		configFolder = folder
	end

	local host = {
		_configFolder = configFolder,
		_baselineName = "Day",
		_effectiveName = if opts.appliedName ~= nil then opts.appliedName else "",
		_leases = {},
		_lightingSystem = {
			beginApplyGeneration = function(_self)
				return 1
			end,
			applyWeatherBase = function(_self, _cfg, _t)
				counters.weatherCalls += 1
				if opts.weatherOk == false then
					return false, "mock weather fail", nil
				end
				return true, nil, opts.weatherSkip
			end,
			applyChannelFromConfig = function()
				return true, nil, nil
			end,
			applyEffectFromInstance = function()
				return true, "Ok"
			end,
			setGraphicsQualityLow = function() end,
		},
		_customState = {
			getOverlayTopNames = function()
				return if opts.overlayHeld then "UiBlur" else nil
			end,
			tryApplyWinningOverlay = function()
				if opts.overlayHeld then
					return "held", opts.overlaySkip or "FxBusy"
				end
				return "none", nil
			end,
			applyAllWinningOverlays = function()
				if opts.overlayHeld then
					return {
						hasHeld = true,
						heldMessage = "overlay held: ColorCorrectionEffect",
						skipReason = opts.overlaySkip or "FxBusy",
						overlayTop = "UiBlur",
					}
				end
				return {
					hasHeld = false,
					heldMessage = nil,
					skipReason = nil,
					overlayTop = nil,
				}
			end,
		},
	}
	return host, counters
end

--[[
	清理 mock 配置 Folder

	@param host any - mock host
	@return nil - 无返回值
]]
local function _cleanupHost(host: any)
	if host._configFolder then
		host._configFolder:Destroy()
	end
end

--[[
	运行全部用例

	@return boolean - 全部通过为 true
]]
function M.runAll(): boolean
	local passed = 0
	local failed = 0

	local prevErr = Lighting:GetAttribute(ATTRS.lastError)
	local prevSkip = Lighting:GetAttribute(ATTRS.skipReason)
	local prevOverlay = Lighting:GetAttribute(ATTRS.overlayTop)
	local prevCurrent = Lighting:GetAttribute(ATTRS.currentLighting)
	local prevApplied = if ATTRS.appliedLighting then Lighting:GetAttribute(ATTRS.appliedLighting) else nil

	-- 1. isExpectedHold（委托 ChannelResultUtil.isExpectedSkip）
	do
		passed, failed = _check(
			"isExpectedHold FxBusy",
			ApplyPipeline.isExpectedHold(LightingApplyResult.FxBusy) == true,
			passed,
			failed
		)
		passed, failed = _check(
			"isExpectedHold QualitySkip",
			ApplyPipeline.isExpectedHold(LightingApplyResult.QualitySkip) == true,
			passed,
			failed
		)
		passed, failed = _check(
			"isExpectedHold ChannelError",
			ApplyPipeline.isExpectedHold(LightingApplyResult.ChannelError) == false,
			passed,
			failed
		)
		passed, failed = _check("isExpectedHold nil", ApplyPipeline.isExpectedHold(nil) == false, passed, failed)
	end

	-- 2. overlay held FxBusy：不写 LastError，返回成功；天气落地 commit
	do
		local host, counters = _makeHost({ overlayHeld = true, overlaySkip = "FxBusy" })
		Lighting:SetAttribute(ATTRS.lastError, "stale")
		local ok = ApplyPipeline.applyEffectiveWeather(host, ATTRS, 0)
		passed, failed = _check("FxBusy held 返回 true", ok == true, passed, failed)
		passed, failed = _check("FxBusy held 清空 LastError", Lighting:GetAttribute(ATTRS.lastError) == nil, passed, failed)
		passed, failed = _check("FxBusy held 写 SkipReason", Lighting:GetAttribute(ATTRS.skipReason) == "FxBusy", passed, failed)
		passed, failed = _check("FxBusy held 仍 apply 天气", counters.weatherCalls == 1, passed, failed)
		passed, failed = _check("FxBusy held commit AppliedName", host._effectiveName == "Day", passed, failed)
		passed, failed = _check(
			"FxBusy held Attribute AppliedName",
			ATTRS.appliedLighting ~= nil and Lighting:GetAttribute(ATTRS.appliedLighting) == "Day",
			passed,
			failed
		)
		_cleanupHost(host)
	end

	-- 3. overlay held ChannelError：写 LastError，返回失败；天气已成功仍 commit
	do
		local host = _makeHost({ overlayHeld = true, overlaySkip = "ChannelError" })
		local ok = ApplyPipeline.applyEffectiveWeather(host, ATTRS, 0)
		passed, failed = _check("ChannelError held 返回 false", ok == false, passed, failed)
		local err = Lighting:GetAttribute(ATTRS.lastError)
		passed, failed = _check(
			"ChannelError held 写 LastError",
			typeof(err) == "string" and string.find(err, "overlay held") ~= nil,
			passed,
			failed
		)
		passed, failed = _check(
			"ChannelError held 写 SkipReason",
			Lighting:GetAttribute(ATTRS.skipReason) == "ChannelError",
			passed,
			failed
		)
		passed, failed = _check("ChannelError held 仍 commit 天气名", host._effectiveName == "Day", passed, failed)
		_cleanupHost(host)
	end

	-- 4. 缺配置：写 LastError，不调用 applyWeatherBase，不推进落地名
	do
		local host, counters = _makeHost({ hasConfig = false, appliedName = "PrevNight" })
		local ok = ApplyPipeline.applyEffectiveWeather(host, ATTRS, 0)
		passed, failed = _check("缺配置返回 false", ok == false, passed, failed)
		passed, failed = _check("缺配置不调天气", counters.weatherCalls == 0, passed, failed)
		local err = Lighting:GetAttribute(ATTRS.lastError)
		passed, failed = _check(
			"缺配置写 LastError",
			typeof(err) == "string" and string.find(err, "LightingConfig") ~= nil,
			passed,
			failed
		)
		passed, failed = _check("缺配置不推进 _effectiveName", host._effectiveName == "PrevNight", passed, failed)
		passed, failed = _check(
			"缺配置意图名 CurrentLightingName",
			Lighting:GetAttribute(ATTRS.currentLighting) == "Day",
			passed,
			failed
		)
		passed, failed = _check(
			"缺配置保留 AppliedName",
			ATTRS.appliedLighting ~= nil and Lighting:GetAttribute(ATTRS.appliedLighting) == "PrevNight",
			passed,
			failed
		)
		_cleanupHost(host)
	end

	-- 4b. schema：Attribute 类型错误 → findLightingConfig 失败
	do
		local folder = Instance.new("Folder")
		folder.Name = "_ApplyPipelineSchemaTest"
		local cfg = Instance.new("Configuration")
		cfg.Name = "Day"
		cfg:SetAttribute("Brightness", "bad")
		cfg.Parent = folder
		local host = {
			_configFolder = folder,
			_baselineName = "Day",
			_effectiveName = "",
			_leases = {},
			_lightingSystem = {
				beginApplyGeneration = function()
					return 1
				end,
				applyWeatherBase = function()
					return true, nil, nil
				end,
				applyChannelFromConfig = function()
					return true, nil, nil
				end,
				applyEffectFromInstance = function()
					return true, "Ok"
				end,
				setGraphicsQualityLow = function() end,
			},
			_customState = {
				getOverlayTopNames = function()
					return nil
				end,
				tryApplyWinningOverlay = function()
					return "none", nil
				end,
				applyAllWinningOverlays = function()
					return {
						hasHeld = false,
						heldMessage = nil,
						skipReason = nil,
						overlayTop = nil,
					}
				end,
			},
		}
		local found = ApplyPipeline.findLightingConfig(host, "Day", ATTRS.lastError)
		passed, failed = _check("schema 类型错误返回 nil", found == nil, passed, failed)
		local err = Lighting:GetAttribute(ATTRS.lastError)
		passed, failed = _check(
			"schema 类型错误写 LastError",
			typeof(err) == "string" and string.find(err, "schema") ~= nil,
			passed,
			failed
		)
		local schemaOk, schemaErr = ApplyPipeline.validateLightingConfig(cfg)
		passed, failed = _check("validateLightingConfig 拒绝错误类型", schemaOk == false, passed, failed)
		passed, failed = _check(
			"validateLightingConfig 错误文案",
			typeof(schemaErr) == "string" and string.find(schemaErr, "Brightness") ~= nil,
			passed,
			failed
		)
		folder:Destroy()
	end

	-- 4c. schema：合法空 Configuration 通过
	do
		local cfg = Instance.new("Configuration")
		local schemaOk = ApplyPipeline.validateLightingConfig(cfg)
		passed, failed = _check("validateLightingConfig 空配置通过", schemaOk == true, passed, failed)
		cfg:Destroy()
	end

	-- 5. 天气 FxBusy skip 与 overlay 合并
	do
		local host = _makeHost({ weatherSkip = "FxBusy", overlayHeld = false })
		Lighting:SetAttribute(ATTRS.lastError, "stale")
		local ok = ApplyPipeline.applyEffectiveWeather(host, ATTRS, 0)
		passed, failed = _check("weather FxBusy 返回 true", ok == true, passed, failed)
		passed, failed = _check("weather FxBusy 清空 LastError", Lighting:GetAttribute(ATTRS.lastError) == nil, passed, failed)
		passed, failed = _check(
			"weather FxBusy 写 SkipReason",
			Lighting:GetAttribute(ATTRS.skipReason) == "FxBusy",
			passed,
			failed
		)
		passed, failed = _check("weather FxBusy commit AppliedName", host._effectiveName == "Day", passed, failed)
		_cleanupHost(host)
	end

	-- 5b. 天气硬失败：不推进落地名；意图与 Applied 可对账
	do
		local host, counters = _makeHost({ weatherOk = false, appliedName = "PrevNight" })
		local ok = ApplyPipeline.applyEffectiveWeather(host, ATTRS, 0)
		passed, failed = _check("天气失败返回 false", ok == false, passed, failed)
		passed, failed = _check("天气失败仍调用 apply", counters.weatherCalls == 1, passed, failed)
		passed, failed = _check("天气失败不推进 _effectiveName", host._effectiveName == "PrevNight", passed, failed)
		passed, failed = _check(
			"天气失败意图 CurrentLightingName=Day",
			Lighting:GetAttribute(ATTRS.currentLighting) == "Day",
			passed,
			failed
		)
		passed, failed = _check(
			"天气失败保留 AppliedName",
			ATTRS.appliedLighting ~= nil and Lighting:GetAttribute(ATTRS.appliedLighting) == "PrevNight",
			passed,
			failed
		)
		local err = Lighting:GetAttribute(ATTRS.lastError)
		passed, failed = _check(
			"天气失败写 LastError",
			typeof(err) == "string" and string.find(err, "apply 失败") ~= nil,
			passed,
			failed
		)
		_cleanupHost(host)
	end

	-- 5c. 成功路径：意图与落地对齐
	do
		local host = _makeHost({ appliedName = "" })
		local ok = ApplyPipeline.applyEffectiveWeather(host, ATTRS, 0)
		passed, failed = _check("成功 apply 返回 true", ok == true, passed, failed)
		passed, failed = _check("成功 commit _effectiveName", host._effectiveName == "Day", passed, failed)
		passed, failed = _check(
			"成功 CurrentLightingName=Day",
			Lighting:GetAttribute(ATTRS.currentLighting) == "Day",
			passed,
			failed
		)
		passed, failed = _check(
			"成功 LightingAppliedName=Day",
			ATTRS.appliedLighting ~= nil and Lighting:GetAttribute(ATTRS.appliedLighting) == "Day",
			passed,
			failed
		)
		_cleanupHost(host)
	end

	-- 5d. applyEffectiveIfChanged：失败后同名可再试（_effectiveName 未推进）
	do
		local host, counters = _makeHost({ weatherOk = false, appliedName = "PrevNight" })
		local ok1 = ApplyPipeline.applyEffectiveIfChanged(host, ATTRS, 0, false)
		passed, failed = _check("IfChanged 失败返回 false", ok1 == false, passed, failed)
		passed, failed = _check("IfChanged 失败后 _effectiveName 仍 PrevNight", host._effectiveName == "PrevNight", passed, failed)
		host._lightingSystem.applyWeatherBase = function(_self, _cfg, _t)
			counters.weatherCalls += 1
			return true, nil, nil
		end
		local ok2 = ApplyPipeline.applyEffectiveIfChanged(host, ATTRS, 0, false)
		passed, failed = _check("IfChanged 重试成功", ok2 == true, passed, failed)
		passed, failed = _check("IfChanged 重试调用天气", counters.weatherCalls == 2, passed, failed)
		passed, failed = _check("IfChanged 重试后落地 Day", host._effectiveName == "Day", passed, failed)
		_cleanupHost(host)
	end

	-- 6. EffectChannelUtil.beginEnabledWrite：关闭路径先写目标再关，不经 tween
	do
		local wrote = false
		local owner = {
			Instance = { Enabled = true },
			TransitionTween = nil,
		}
		local shouldTween = EffectChannelUtil.beginEnabledWrite(owner :: any, false, function()
			wrote = true
		end)
		passed, failed = _check("beginEnabledWrite 关闭返回 false", shouldTween == false, passed, failed)
		passed, failed = _check("beginEnabledWrite 关闭先写目标", wrote == true, passed, failed)
		passed, failed = _check("beginEnabledWrite 关闭后 Enabled=false", owner.Instance.Enabled == false, passed, failed)

		wrote = false
		shouldTween = EffectChannelUtil.beginEnabledWrite(owner :: any, true, function()
			wrote = true
		end)
		passed, failed = _check("beginEnabledWrite 开启返回 true", shouldTween == true, passed, failed)
		passed, failed = _check("beginEnabledWrite 开启不调 applyTargets", wrote == false, passed, failed)
		passed, failed = _check("beginEnabledWrite 开启 Enabled=true", owner.Instance.Enabled == true, passed, failed)
	end

	-- 恢复 Attribute
	Lighting:SetAttribute(ATTRS.lastError, prevErr)
	Lighting:SetAttribute(ATTRS.skipReason, prevSkip)
	Lighting:SetAttribute(ATTRS.overlayTop, prevOverlay)
	Lighting:SetAttribute(ATTRS.currentLighting, prevCurrent)
	if ATTRS.appliedLighting then
		Lighting:SetAttribute(ATTRS.appliedLighting, prevApplied)
	end

	print(("[ApplyPipelineValidationTest] 完成：通过 %d / 失败 %d"):format(passed, failed))
	return failed == 0
end

return M
