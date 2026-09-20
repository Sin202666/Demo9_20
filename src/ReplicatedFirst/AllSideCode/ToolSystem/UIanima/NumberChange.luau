--[[
	Module: UIanima/NumberChange
	Description: UIanima 子模块——TextLabel 数字滚动（mode=roll）
	Author: 林奥宇
	Created: 2026-09-01
	Last Modified: 2026-09-01

	仅供 init 挂到 UIanima.AnimateNumberChange。业务请走 Utils.UIanima。
]]

local TweenService = game:GetService("TweenService")

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Log = Utils.Log
local TranslationHelper = Utils.TranslationHelper

local Helpers = require(script.Parent.Helpers)

local NumberChange = {}

type NumberAnimState = {
	proxy: NumberValue,
	tween: Tween,
	changedConn: RBXScriptConnection,
	completedConn: RBXScriptConnection,
	destroyingConn: RBXScriptConnection?,
}

local _numberAnimStates: { [TextLabel]: NumberAnimState } = {}

--[[
	停止同一 TextLabel 上的数字滚动并销毁代理 NumberValue
	@param label TextLabel - 数量文本
	@return nil - 无返回值
]]
local function _stopNumberAnim(label: TextLabel)
	local state = _numberAnimStates[label]
	if not state then
		return
	end
	_numberAnimStates[label] = nil
	state.changedConn:Disconnect()
	state.completedConn:Disconnect()
	state.tween:Cancel()
	state.proxy:Destroy()
	if state.destroyingConn then
		state.destroyingConn:Disconnect()
	end
end

--[[
	将 TextLabel 数字从 fromValue 滚动到 toValue（当前仅实现 mode=roll 插值）
	重复调用同一 label 会取消上一轮。展示串走 SetRawText。
	@param label TextLabel - 目标文本
	@param direction string - "up" 或 "down"，影响缓动方向（Out / In）
	@param options table - 须含 fromValue / toValue（number）；可选 mode（"roll"）、duration（秒，默认 0.25）、formatFn ((number)->string)、onComplete (() -> ())
	@return nil - 无返回值
]]
function NumberChange.Play(
	label: TextLabel,
	direction: string,
	options: {
		mode: string?,
		fromValue: number,
		toValue: number,
		duration: number?,
		formatFn: ((number) -> string)?,
		onComplete: (() -> ())?,
	}
)
	if not label or not label:IsA("TextLabel") then
		Log.warn("[UIanima] AnimateNumberChange label 非法")
		return
	end
	if type(options) ~= "table" or type(options.fromValue) ~= "number" or type(options.toValue) ~= "number" then
		Log.warn("[UIanima] AnimateNumberChange options 须含 fromValue / toValue")
		return
	end

	local mode = options.mode or Helpers.NUMBER_ANIM_MODE_ROLL
	if mode ~= Helpers.NUMBER_ANIM_MODE_ROLL then
		Log.warn("[UIanima] AnimateNumberChange 未知 mode，按 roll 处理", mode)
	end

	local duration = options.duration or Helpers.NUMBER_ANIM_DEFAULT_DURATION
	if duration < 0 then
		duration = Helpers.NUMBER_ANIM_DEFAULT_DURATION
	end

	local formatFn = options.formatFn
	if type(formatFn) ~= "function" then
		formatFn = function(n: number): string
			return tostring(math.floor(n))
		end
	end

	local fromValue = options.fromValue
	local toValue = options.toValue
	local onComplete = options.onComplete

	_stopNumberAnim(label)
	TranslationHelper.SetRawText(label, formatFn(fromValue))

	if duration == 0 or fromValue == toValue then
		TranslationHelper.SetRawText(label, formatFn(toValue))
		if type(onComplete) == "function" then
			onComplete()
		end
		return
	end

	local easingDirection = if direction == "down" then Enum.EasingDirection.In else Enum.EasingDirection.Out
	local proxy = Instance.new("NumberValue")
	proxy.Value = fromValue

	local tween = TweenService:Create(
		proxy,
		TweenInfo.new(duration, Enum.EasingStyle.Quad, easingDirection),
		{ Value = toValue }
	)

	local changedConn = proxy:GetPropertyChangedSignal("Value"):Connect(function()
		if label.Parent then
			TranslationHelper.SetRawText(label, formatFn(proxy.Value))
		end
	end)

	local state: NumberAnimState
	local completedConn = Helpers.OnTweenCompletedOnce(tween, function()
		if _numberAnimStates[label] == state then
			_numberAnimStates[label] = nil
		end
		changedConn:Disconnect()
		if state.destroyingConn then
			state.destroyingConn:Disconnect()
		end
		proxy:Destroy()
		if label.Parent then
			TranslationHelper.SetRawText(label, formatFn(toValue))
		end
		if type(onComplete) == "function" then
			onComplete()
		end
	end)

	state = {
		proxy = proxy,
		tween = tween,
		changedConn = changedConn,
		completedConn = completedConn,
		destroyingConn = nil,
	}
	_numberAnimStates[label] = state
	state.destroyingConn = label.Destroying:Connect(function()
		_stopNumberAnim(label)
	end)

	tween:Play()
end

return NumberChange
