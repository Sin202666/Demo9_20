--[[
	Module: LightingTweenUtil
	Description: Lighting 过渡 Tween 共用工具（取消 / 即时写 / 缓动）；供 SystemLighting 与 SystemLightingWeather 共用
	Author: 中台组 林奥宇
	Created: 2026-08-04
	Last Modified: 2026-08-04

	功能：
	- 安全取消 Tween（Cancel + Destroy；Cancelled 不触发 onComplete）
	- 按 transitionTime 选择即时写或 Tween
	- 规范化过渡秒数（nil / 负数 → 0）
	- 缓动取自 GameConfig.LightingTween（缓动样式 / 缓动方向）；非法名回退 Quad/Out
	- 可选 onComplete：仅 PlaybackState.Completed 时回调（用于清引用 / 代际副作用）
	- 可选 tweenInfo 覆盖默认缓动（测试或特殊通道）

	加载：
	local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
	local LightingTweenUtil = Utils.LightingTweenUtil

	使用：
	self.TransitionTween = LightingTweenUtil.playOrApply(
		self.TransitionTween, instance, t, goals, applyNow,
		function()
			self.TransitionTween = nil
		end
	)
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local TweenService = Utils.TweenService
local GameConfig = Utils.GameConfig

local DEFAULT_EASING_STYLE = Enum.EasingStyle.Quad
local DEFAULT_EASING_DIRECTION = Enum.EasingDirection.Out

local LightingTweenUtil = {}

--[[
	将过渡时间规范为非负秒数

	@param transitionTime number? - 原始过渡时间；nil 视为 0
	@return number - max(0, transitionTime)
]]
function LightingTweenUtil.normalizeTransitionTime(transitionTime: number?): number
	if typeof(transitionTime) ~= "number" then
		return 0
	end
	return math.max(0, transitionTime)
end

--[[
	从 GameConfig.LightingTween 解析默认 TweenInfo（仅 duration 由调用方传入）

	@param duration number - 过渡秒数
	@return TweenInfo - 带配置缓动的 TweenInfo
]]
local function _defaultTweenInfo(duration: number): TweenInfo
	local cfg = GameConfig.LightingTween
	local style = DEFAULT_EASING_STYLE
	local direction = DEFAULT_EASING_DIRECTION
	if typeof(cfg) == "table" then
		local styleName = cfg["缓动样式"]
		local dirName = cfg["缓动方向"]
		if typeof(styleName) == "string" and Enum.EasingStyle[styleName] then
			style = Enum.EasingStyle[styleName]
		end
		if typeof(dirName) == "string" and Enum.EasingDirection[dirName] then
			direction = Enum.EasingDirection[dirName]
		end
	end
	return TweenInfo.new(duration, style, direction)
end

--[[
	取消并销毁 Tween（优先 Cancel，避免 Completed 误触发）

	@param tween Tween? - 待取消的 Tween；nil 则无操作
	@return nil - 无返回值
]]
function LightingTweenUtil.cancelTween(tween: Tween?)
	if not tween then
		return
	end
	pcall(function()
		tween:Cancel()
	end)
	pcall(function()
		tween:Destroy()
	end)
end

--[[
	先取消旧 Tween；transitionTime>0 则创建并播放新 Tween，否则执行即时写

	@param oldTween Tween? - 进行中的旧 Tween
	@param instance Instance - Tween 目标
	@param transitionTime number - 过渡秒数（应已 normalize）
	@param goals {[string]: any} - Tween 目标属性表
	@param applyNow (() -> ())? - 即时写入回调；transitionTime==0 时调用
	@param onComplete (() -> ())? - 仅自然 Completed 时回调（Cancelled 不调）
	@param tweenInfo TweenInfo? - 可选覆盖；nil 时用 GameConfig.LightingTween
	@return Tween? - 新创建的 Tween；即时写时为 nil
]]
function LightingTweenUtil.playOrApply(
	oldTween: Tween?,
	instance: Instance,
	transitionTime: number,
	goals: { [string]: any },
	applyNow: (() -> ())?,
	onComplete: (() -> ())?,
	tweenInfo: TweenInfo?
): Tween?
	LightingTweenUtil.cancelTween(oldTween)

	if transitionTime > 0 then
		local info = tweenInfo or _defaultTweenInfo(transitionTime)
		local tween = TweenService:Create(instance, info, goals)
		tween:Play()
		if onComplete then
			tween.Completed:Connect(function(playbackState)
				if playbackState ~= Enum.PlaybackState.Completed then
					return
				end
				onComplete()
			end)
		end
		return tween
	end

	if applyNow then
		applyNow()
	end
	return nil
end

return LightingTweenUtil
