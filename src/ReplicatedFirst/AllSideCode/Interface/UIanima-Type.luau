--[[
	Module: UIanima-Type
	Description: UIanima 类型声明（完整使用说明见 ToolSystem/UIanima.luau 文件头）
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-09-04
]]

local UIanima = {}

--[[
	窗口弹出动画（UIScale 从 0 缩放到 AdaptScale，无 Attribute 时为 1）
	@param uiFrame GuiObject - 要弹出的 UI 根节点；非法时静默返回
	@return nil - 无返回值
]]
function UIanima.PopUp(uiFrame: GuiObject)
end

--[[
	窗口收回动画（UIScale 从 AdaptScale 缩放到 0 后隐藏，并刷新 UIMgr 模糊层）
	@param uiFrame GuiObject - 要收回的 UI 根节点；非法时仍调用 onCompleted
	@param onCompleted (() -> ())? - Tween 结束后回调；非法节点时立即调用
	@return nil - 无返回值
]]
function UIanima.PopBack(uiFrame: GuiObject, onCompleted: (() -> ())?)
end

--[[
	按钮按下缩放动画
	@param uiFrame GuiObject - 按钮或容器节点；非法时静默返回
	@return nil - 无返回值
]]
function UIanima.ButtonDown(uiFrame: GuiObject)
end

--[[
	按钮抬起缩放动画
	@param uiFrame GuiObject - 按钮或容器节点；非法时静默返回
	@return nil - 无返回值
]]
function UIanima.ButtonUp(uiFrame: GuiObject)
end

--[[
	按钮悬停进入缩放动画
	@param uiFrame GuiObject - 按钮或容器节点；非法时静默返回
	@return nil - 无返回值
]]
function UIanima.BtnScaleAnimEnter(uiFrame: GuiObject)
end

--[[
	按钮悬停离开缩放动画
	@param uiFrame GuiObject - 按钮或容器节点；非法时静默返回
	@return nil - 无返回值
]]
function UIanima.BtnScaleAnimLeave(uiFrame: GuiObject)
end

--[[
	红点循环缩放动画（同一节点重复调用会先停上一轮）
	@param uiFrame GuiObject - 红点 UI 节点；非法时静默返回
	@return nil - 无返回值
]]
function UIanima.RedPointAnim(uiFrame: GuiObject)
end

--[[
	停止红点循环缩放
	@param uiFrame GuiObject - 红点 UI 节点
	@return nil - 无返回值
]]
function UIanima.StopRedPointAnim(uiFrame: GuiObject)
end

--[[
	UI 尺寸震动反馈
	@param ui GuiObject - 要震动的 UI 节点；非法时静默返回
	@return nil - 无返回值
]]
function UIanima.ShakeUI(ui: GuiObject)
end

--[[
	ShakeUI 历史 camelCase 别名
	@param ui GuiObject - 要震动的 UI 节点
	@return nil - 无返回值
]]
function UIanima.shakeUI(ui: GuiObject)
end

--[[
	窗口自上而下滑入显示
	@param uiFrame GuiObject - 要显示的 UI 节点；非法时静默返回
	@return Tween? - 位移动画；入参非法时 nil
]]
function UIanima.PopDownShow(uiFrame: GuiObject): Tween?
end

--[[
	窗口向上滑出并隐藏
	@param uiFrame GuiObject - 要隐藏的 UI 节点；非法时静默返回
	@return Tween? - 位移动画；入参非法时 nil
]]
function UIanima.PopUpDisappear(uiFrame: GuiObject): Tween?
end

--[[
	PopUpDisappear 历史拼写别名
	@param uiFrame GuiObject - 要隐藏的 UI 节点
	@return Tween? - 位移动画；入参非法时 nil
]]
function UIanima.PopUpDispear(uiFrame: GuiObject): Tween?
end

--[[
	物品获得飞入动画
	@param itemID number - 物品配置 ID（CfgFind.FindCfgByID）
	@param itemNum number? - 显示数量；nil 时为 1
	@param goalUi GuiObject - 飞入终点 UI
	@return nil - 无返回值
]]
function UIanima.GetItemAnimation(itemID: number, itemNum: number?, goalUi: GuiObject)
end

--[[
	将 TextLabel 数字从 fromValue 滚动到 toValue（当前仅 mode=roll）
	@param label TextLabel - 目标文本
	@param direction string - "up" 或 "down"，影响缓动方向
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
end

--[[
	UIScale 从 0 缩放到 AdaptScale（无 Attribute 时为 1）
	@param uiFrame GuiObject - 目标节点
	@param tweenTime number? - 动画时长（秒）；nil 时为 0.1
	@return nil - 无返回值
]]
function UIanima.UIScaleOut(uiFrame: GuiObject, tweenTime: number?)
end

return UIanima
