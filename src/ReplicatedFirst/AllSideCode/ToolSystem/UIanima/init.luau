--[[
	Module: UIanima
	Description: 客户端 UI 动画工具库，提供窗口弹出/收回、按钮缩放、红点循环、物品飞入与数字滚动等 Tween
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-09-04

	功能：
	- 窗口：PopUp / PopBack（UIScale 缩放）、PopDownShow / PopUpDisappear（位移动画；PopUpDispear 为历史拼写别名）
	- 按钮：ButtonDown / ButtonUp、BtnScaleAnimEnter / BtnScaleAnimLeave、RedPointAnim / StopRedPointAnim
	- 反馈：ShakeUI 尺寸震动（shakeUI 为历史别名）、GetItemAnimation 物品飞入目标 UI
	- 数字：AnimateNumberChange 将 TextLabel 从 fromValue 滚动到 toValue
	- 通用：UIScaleOut 从 0 缩放到 AdaptScale（无 Attribute 时为 1）

	子模块：
	- Helpers — 常量、UIScale/尺寸缓存、Tween 连接
	- ItemFly — GetItemAnimation
	- NumberChange — AnimateNumberChange

	模块关系：
	- 由 UIManager / GuiScripts / AddListen / TopBarManager 在客户端调用；不含服务端权威逻辑
	- 不替代 UISetMgr（分辨率适配写 AdaptScale）；本模块只 tween 到该 Attribute
	- 不替代 UIMgr（奖励格/模糊层）；PopBack / GetItemAnimation 运行时按需取 Utils.UIMgr，避免循环引用
	- 飞入模板走 AssetPaths.Resolve(AssetRegistry.Catalog.UIanima / 获取物品动画)，不直连 ReplicatedStorage.Assets

	端侧 / 调用约束：
	- 仅客户端有效（依赖 LocalPlayer / PlayerGui）；服务端调用会早退
	- 弹窗目标 Scale 优先读 UIScale.AdaptScale（由 UISetMgr 写入）
	- 玩家可见数量用 TranslationHelper.SetRawText（"+" 与数字不随语言变化）
	- RedPointAnim / AnimateNumberChange 对同一节点重复调用会先停掉上一轮，避免连接叠加

	加载方式：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local UIanima = Utils.UIanima

	使用示例：
		UIanima.PopUp(frame)
		UIanima.PopBack(frame)
		UIanima.PopBack(frame, function() end)
		UIanima.GetItemAnimation(itemId, count, goalLabel)
		UIanima.AnimateNumberChange(label, "up", {
			mode = "roll",
			fromValue = 10,
			toValue = 25,
			duration = 0.25,
			formatFn = function(n)
				return tostring(math.floor(n))
			end,
		})
]]

-- ============================================================================
-- 服务引用 / 模块引用
-- ============================================================================

local TweenService = game:GetService("TweenService")

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local InsMgr = Utils.InsMgr

local Helpers = require(script.Helpers)
local ItemFly = require(script.ItemFly)
local NumberChange = require(script.NumberChange)

-- ============================================================================
-- 模块定义
-- ============================================================================

local UIanima = {}

type RedPointState = {
	tweens: { Tween },
	conns: { RBXScriptConnection },
	destroyingConn: RBXScriptConnection?,
}

local _redPointStates: { [GuiObject]: RedPointState } = {}

-- ============================================================================
-- 私有函数
-- ============================================================================

--[[
	停止同一红点上的循环缩放，断开 Completed 并 Cancel Tween
	@param uiFrame GuiObject - 红点节点
	@return nil - 无返回值
]]
local function _stopRedPointAnim(uiFrame: GuiObject)
	local state = _redPointStates[uiFrame]
	if not state then
		return
	end
	_redPointStates[uiFrame] = nil
	Helpers.DisconnectConnections(state.conns)
	for _, tween in state.tweens do
		tween:Cancel()
	end
	if state.destroyingConn then
		state.destroyingConn:Disconnect()
		state.destroyingConn = nil
	end
end

--[[
	红点循环中播放下一阶段；节点已离树则停止整轮
	@param uiFrame GuiObject - 红点节点
	@param nextTween Tween - 下一阶段缩放 Tween
	@return nil - 无返回值
]]
local function _playRedPointNext(uiFrame: GuiObject, nextTween: Tween)
	if uiFrame.Parent then
		nextTween:Play()
	else
		_stopRedPointAnim(uiFrame)
	end
end

-- ============================================================================
-- 公共 API - 窗口动画
-- ============================================================================

--[[
	窗口弹出动画（UIScale 从 0 缩放到 AdaptScale，无 Attribute 时为 1）
	@param uiFrame GuiObject - 要弹出的 UI 根节点；非法时静默返回
	@return nil - 无返回值
]]
function UIanima.PopUp(uiFrame: GuiObject)
	if not Helpers.IsGuiObject(uiFrame) then
		return
	end
	Helpers.EnsureScaleValues(uiFrame)
	UIanima.UIScaleOut(uiFrame)
end

--[[
	窗口收回动画（UIScale 从 AdaptScale 缩放到 0 后隐藏，并刷新 UIMgr 模糊层）
	@param uiFrame GuiObject - 要收回的 UI 根节点；非法时仍调用 onCompleted，避免排队锁卡住
	@param onCompleted (() -> ())? - Tween 结束后回调；非法节点时立即调用；现网不传则行为与原先一致
	@return nil - 无返回值
]]
function UIanima.PopBack(uiFrame: GuiObject, onCompleted: (() -> ())?)
	local function finish()
		if type(onCompleted) == "function" then
			onCompleted()
		end
	end

	if not Helpers.IsGuiObject(uiFrame) then
		finish()
		return
	end
	Helpers.EnsureScaleValues(uiFrame)

	local uiScale = Helpers.GetOrCreateUIScale(uiFrame, 1)
	uiScale.Scale = Helpers.GetAdaptScale(uiScale)

	local popTween = TweenService:Create(uiScale, TweenInfo.new(Helpers.POP_BACK_TWEEN_TIME), { Scale = 0 })
	Helpers.OnTweenCompletedOnce(popTween, function()
		uiFrame.Visible = false
		local mgr = Helpers.GetUIMgr()
		if mgr then
			mgr.UpdateBlurVisible()
		end
		finish()
	end)
	popTween:Play()
end

-- ============================================================================
-- 公共 API - 按钮动画
-- ============================================================================

--[[
	按钮按下缩放动画
	@param uiFrame GuiObject - 按钮或容器节点；非法时静默返回
	@return nil - 无返回值
]]
function UIanima.ButtonDown(uiFrame: GuiObject)
	if not Helpers.IsGuiObject(uiFrame) then
		return
	end
	Helpers.PlayButtonScaleTween(
		uiFrame,
		Helpers.BUTTON_REST_SCALE,
		Helpers.BUTTON_DOWN_SCALE,
		Helpers.BUTTON_TWEEN_TIME,
		Enum.EasingStyle.Bounce,
		Enum.EasingDirection.Out
	)
end

--[[
	按钮抬起缩放动画
	@param uiFrame GuiObject - 按钮或容器节点；非法时静默返回
	@return nil - 无返回值
]]
function UIanima.ButtonUp(uiFrame: GuiObject)
	if not Helpers.IsGuiObject(uiFrame) then
		return
	end
	Helpers.PlayButtonScaleTween(
		uiFrame,
		Helpers.BUTTON_DOWN_SCALE,
		Helpers.BUTTON_REST_SCALE,
		Helpers.BUTTON_TWEEN_TIME,
		Enum.EasingStyle.Bounce,
		Enum.EasingDirection.Out
	)
end

--[[
	按钮悬停进入缩放动画
	@param uiFrame GuiObject - 按钮或容器节点；非法时静默返回
	@return nil - 无返回值
]]
function UIanima.BtnScaleAnimEnter(uiFrame: GuiObject)
	if not Helpers.IsGuiObject(uiFrame) then
		return
	end
	Helpers.PlayButtonScaleTween(
		uiFrame,
		Helpers.BUTTON_REST_SCALE,
		Helpers.BUTTON_HOVER_SCALE,
		Helpers.BUTTON_HOVER_TWEEN_TIME,
		Enum.EasingStyle.Linear,
		Enum.EasingDirection.In
	)
end

--[[
	按钮悬停离开缩放动画
	@param uiFrame GuiObject - 按钮或容器节点；非法时静默返回
	@return nil - 无返回值
]]
function UIanima.BtnScaleAnimLeave(uiFrame: GuiObject)
	if not Helpers.IsGuiObject(uiFrame) then
		return
	end
	Helpers.PlayButtonScaleTween(
		uiFrame,
		nil,
		Helpers.BUTTON_REST_SCALE,
		Helpers.BUTTON_HOVER_TWEEN_TIME,
		Enum.EasingStyle.Linear,
		Enum.EasingDirection.In
	)
end

--[[
	红点循环缩放动画（放大 → 缩小 → 还原，控件移出树或 Destroy 时停止）
	同一节点重复调用会先停止上一轮，避免 Completed 连接叠加。
	@param uiFrame GuiObject - 红点 UI 节点；非法时静默返回
	@return nil - 无返回值
]]
function UIanima.RedPointAnim(uiFrame: GuiObject)
	if not Helpers.IsGuiObject(uiFrame) then
		return
	end

	_stopRedPointAnim(uiFrame)

	local uiScale: UIScale = InsMgr.GetIns(Helpers.BUTTON_SCALE_INS_NAME, "UIScale", uiFrame) :: UIScale
	uiScale.Scale = Helpers.BUTTON_REST_SCALE

	local tween1 = TweenService:Create(uiScale, TweenInfo.new(
		Helpers.RED_POINT_TWEEN_FAST,
		Enum.EasingStyle.Linear,
		Enum.EasingDirection.In,
		0,
		false,
		Helpers.RED_POINT_START_DELAY
	), { Scale = Helpers.RED_POINT_SCALE_MAX })
	local tween2 = TweenService:Create(uiScale, TweenInfo.new(
		Helpers.RED_POINT_TWEEN_SLOW,
		Enum.EasingStyle.Linear,
		Enum.EasingDirection.In,
		0,
		false
	), { Scale = Helpers.RED_POINT_SCALE_MIN })
	local tween3 = TweenService:Create(uiScale, TweenInfo.new(
		Helpers.RED_POINT_TWEEN_FAST,
		Enum.EasingStyle.Linear,
		Enum.EasingDirection.In,
		0,
		false
	), { Scale = Helpers.BUTTON_REST_SCALE })

	local state: RedPointState = {
		tweens = { tween1, tween2, tween3 },
		conns = {},
		destroyingConn = nil,
	}
	_redPointStates[uiFrame] = state

	table.insert(state.conns, tween1.Completed:Connect(function()
		_playRedPointNext(uiFrame, tween2)
	end))
	table.insert(state.conns, tween2.Completed:Connect(function()
		_playRedPointNext(uiFrame, tween3)
	end))
	table.insert(state.conns, tween3.Completed:Connect(function()
		_playRedPointNext(uiFrame, tween1)
	end))

	state.destroyingConn = uiFrame.Destroying:Connect(function()
		_stopRedPointAnim(uiFrame)
	end)

	tween1:Play()
end

--[[
	停止红点循环缩放并还原 UIScale（隐藏红点时调用，避免不可见节点继续 Tween）
	@param uiFrame GuiObject - 红点 UI 节点；非法或未在播时静默返回
	@return nil - 无返回值
]]
function UIanima.StopRedPointAnim(uiFrame: GuiObject)
	if not Helpers.IsGuiObject(uiFrame) then
		return
	end
	_stopRedPointAnim(uiFrame)
end

--[[
	UI 尺寸震动反馈（短暂放大后恢复原始 Size）
	@param ui GuiObject - 要震动的 UI 节点；非法时静默返回
	@return nil - 无返回值
]]
function UIanima.ShakeUI(ui: GuiObject)
	if not Helpers.IsGuiObject(ui) then
		return
	end
	Helpers.EnsureScaleValues(ui)

	local scaleValueX: Vector3Value = InsMgr.GetIns(Helpers.SCALE_VALUE_X_NAME, "Vector3Value", ui) :: Vector3Value
	local scaleValueY: Vector3Value = InsMgr.GetIns(Helpers.SCALE_VALUE_Y_NAME, "Vector3Value", ui) :: Vector3Value
	local realSize: UDim2 = UDim2.new(
		scaleValueX.Value.X, scaleValueX.Value.Y,
		scaleValueY.Value.X, scaleValueY.Value.Y
	)
	ui.Size = realSize

	local enlarge = 1 + Helpers.SHAKE_SCALE_FACTOR
	local enlargedSize = UDim2.new(
		realSize.X.Scale * enlarge, realSize.X.Offset * enlarge,
		realSize.Y.Scale * enlarge, realSize.Y.Offset * enlarge
	)
	local shakeBigTween = TweenService:Create(
		ui,
		TweenInfo.new(Helpers.SHAKE_TIME, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Size = enlargedSize }
	)
	local shakeBackTween = TweenService:Create(
		ui,
		TweenInfo.new(Helpers.SHAKE_TIME, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Size = realSize }
	)

	Helpers.OnTweenCompletedOnce(shakeBigTween, function()
		shakeBackTween:Play()
	end)
	shakeBigTween:Play()
end

UIanima.shakeUI = UIanima.ShakeUI

--[[
	窗口自上而下滑入显示（Position 从上方进入 POP_SLIDE_BASE）
	@param uiFrame GuiObject - 要显示的 UI 节点；非法时静默返回
	@return Tween? - 位移动画；入参非法时 nil
]]
function UIanima.PopDownShow(uiFrame: GuiObject): Tween?
	if not Helpers.IsGuiObject(uiFrame) then
		return nil
	end
	uiFrame.Visible = true

	local sizeY = uiFrame.Size.Y.Scale
	local startPos = UDim2.new(
		Helpers.POP_SLIDE_BASE.X.Scale,
		Helpers.POP_SLIDE_BASE.X.Offset,
		Helpers.POP_SLIDE_BASE.Y.Scale - sizeY,
		Helpers.POP_SLIDE_BASE.Y.Offset
	)
	uiFrame.Position = startPos

	local popTween = TweenService:Create(
		uiFrame,
		TweenInfo.new(Helpers.POP_DOWN_TWEEN_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Position = Helpers.POP_SLIDE_BASE }
	)
	popTween:Play()
	return popTween
end

--[[
	窗口向上滑出并隐藏（Position 移出视口后设 Visible=false）
	@param uiFrame GuiObject - 要隐藏的 UI 节点；非法时静默返回
	@return Tween? - 位移动画；入参非法时 nil
]]
function UIanima.PopUpDisappear(uiFrame: GuiObject): Tween?
	if not Helpers.IsGuiObject(uiFrame) then
		return nil
	end

	local sizeY = uiFrame.Size.Y.Scale
	local popTween = TweenService:Create(uiFrame, TweenInfo.new(Helpers.POP_DOWN_TWEEN_TIME), {
		Position = UDim2.new(
			Helpers.POP_SLIDE_BASE.X.Scale,
			Helpers.POP_SLIDE_BASE.X.Offset,
			Helpers.POP_SLIDE_BASE.Y.Scale - sizeY,
			Helpers.POP_SLIDE_BASE.Y.Offset
		),
	})
	popTween:Play()

	Helpers.OnTweenCompletedOnce(popTween, function()
		uiFrame.Visible = false
	end)

	return popTween
end

UIanima.PopUpDispear = UIanima.PopUpDisappear

--[[
	物品获得飞入动画：克隆 UIanima catalog 模板，展示后飞向目标并震动
	@param itemID number - 物品配置 ID（CfgFind.FindCfgByID）
	@param itemNum number? - 显示数量；nil 时为 1
	@param goalUi GuiObject - 飞入终点 UI（用于取 AbsolutePosition）
	@return nil - 无返回值；缺配置/模板/ScreenGui 时 Log.warn 后返回
]]
function UIanima.GetItemAnimation(itemID: number, itemNum: number?, goalUi: GuiObject)
	ItemFly.Play(itemID, itemNum, goalUi, UIanima.ShakeUI)
end

--[[
	将 TextLabel 数字从 fromValue 滚动到 toValue（当前仅实现 mode=roll 插值）
	重复调用同一 label 会取消上一轮。展示串走 SetRawText。
	@param label TextLabel - 目标文本
	@param direction string - "up" 或 "down"，影响缓动方向（Out / In）
	@param options table - 须含 fromValue / toValue（number）；可选 mode（"roll"）、duration（秒，默认 0.25）、formatFn ((number)->string)、onComplete (() -> ())
	@return nil - 无返回值
]]
function UIanima.AnimateNumberChange(
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
	NumberChange.Play(label, direction, options)
end

--[[
	UIScale 从 0 缩放到 AdaptScale（无 Attribute 时为 1）的通用弹出动画
	@param uiFrame GuiObject - 目标节点（需可见时先设 Visible=true）
	@param tweenTime number? - 动画时长（秒）；nil 时为 0.1
	@return nil - 无返回值
]]
function UIanima.UIScaleOut(uiFrame: GuiObject, tweenTime: number?)
	if not Helpers.IsGuiObject(uiFrame) then
		return
	end
	uiFrame.Visible = true

	local uiScale = Helpers.GetOrCreateUIScale(uiFrame, 0)
	uiScale.Scale = 0

	local duration = tweenTime or Helpers.DEFAULT_SCALE_OUT_TIME
	local popTween = TweenService:Create(uiScale, TweenInfo.new(duration), { Scale = Helpers.GetAdaptScale(uiScale) })
	popTween:Play()
end

return UIanima
