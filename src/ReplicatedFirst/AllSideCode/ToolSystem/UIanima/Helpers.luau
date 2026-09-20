--[[
	Module: UIanima/Helpers
	Description: UIanima 内部辅助——常量、UIScale/尺寸缓存、Tween 连接与按钮缩放
	Author: 林奥宇
	Created: 2026-09-01
	Last Modified: 2026-09-01

	仅供同目录 init / ItemFly / NumberChange require(script.Parent.Helpers)。
	业务请走 Utils.UIanima，不要直接 require 本文件。
]]

local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local InsMgr = Utils.InsMgr

local Helpers = {}

-- ============================================================================
-- 常量（供兄弟子模块读取）
-- ============================================================================

Helpers.SHAKE_TIME = 0.05
Helpers.SHAKE_SCALE_FACTOR = 0.1

Helpers.BUTTON_TWEEN_TIME = 0.1
Helpers.BUTTON_HOVER_TWEEN_TIME = 0.2
Helpers.BUTTON_DOWN_SCALE = 0.9
Helpers.BUTTON_HOVER_SCALE = 1.1
Helpers.BUTTON_REST_SCALE = 1

Helpers.POP_BACK_TWEEN_TIME = 0.1
Helpers.POP_DOWN_TWEEN_TIME = 0.5
Helpers.DEFAULT_SCALE_OUT_TIME = 0.1
Helpers.POP_SLIDE_BASE = UDim2.new(0.5, 0, 0, 0)

Helpers.RED_POINT_TWEEN_FAST = 0.2
Helpers.RED_POINT_TWEEN_SLOW = 0.4
Helpers.RED_POINT_SCALE_MAX = 1.2
Helpers.RED_POINT_SCALE_MIN = 0.8
Helpers.RED_POINT_START_DELAY = 5

Helpers.ITEM_SHOW_TIME = 0.6
Helpers.ITEM_MOVE_TIME = 0.4
Helpers.ITEM_FADE_TIME = 0.4
Helpers.ITEM_SHOW_SIZE = 150
Helpers.ITEM_SMALL_SHOW_SIZE = 100
Helpers.ITEM_SPAWN_CENTER = UDim2.new(0.5, 0, 0.3, 0)
Helpers.ITEM_SPAWN_JITTER = 0.2
Helpers.ITEM_GOAL_ANCHOR = 0.75

Helpers.NUMBER_ANIM_DEFAULT_DURATION = 0.25
Helpers.NUMBER_ANIM_MODE_ROLL = "roll"

Helpers.SCREEN_GUI_NAME = "ScreenGui"
Helpers.ITEM_FLY_TEMPLATE_NAME = "获取物品动画"
Helpers.ITEM_NUM_LABEL_NAME = "物品数量"
Helpers.ITEM_ICON_NAME = "物品图片"
Helpers.BUTTON_SCALE_INS_NAME = "按钮缩放动画"
Helpers.ADAPT_SCALE_ATTR = "AdaptScale"
Helpers.UI_SCALE_CHILD_NAME = "UIScale"
Helpers.SCALE_VALUE_X_NAME = "scaleValueX"
Helpers.SCALE_VALUE_Y_NAME = "scaleValueY"
Helpers.RBX_ASSET_PREFIX = "rbxassetid://"

-- ============================================================================
-- 私有变量 / 私有函数
-- ============================================================================

local _uiMgr: any = nil

--[[
	延迟取 UIMgr 短名；加载期不碰 Utils.UIMgr，避免与 AddListen 成环
	@return any? - UIMgr 模块表；Utils 尚未就绪时为 nil
]]
function Helpers.GetUIMgr(): any?
	if not _uiMgr then
		_uiMgr = Utils.UIMgr
	end
	return _uiMgr
end

--[[
	读取弹窗 UIScale 的适配目标倍率（UISetMgr 写入 AdaptScale；无则 1）
	@param uiScale UIScale - 弹窗上的 UIScale
	@return number - 动画目标 Scale
]]
function Helpers.GetAdaptScale(uiScale: UIScale): number
	local adapt = uiScale:GetAttribute(Helpers.ADAPT_SCALE_ATTR)
	if typeof(adapt) == "number" and adapt > 0 then
		return adapt
	end
	return 1
end

--[[
	在 GuiObject 上缓存原始尺寸的 Vector3Value，供 ShakeUI 等恢复 Size 使用
	@param ui GuiObject - 目标 UI 节点
	@return nil - 无返回值
]]
function Helpers.EnsureScaleValues(ui: GuiObject)
	local scaleValueX: Vector3Value = InsMgr.GetIns(Helpers.SCALE_VALUE_X_NAME, "Vector3Value", ui) :: Vector3Value
	if scaleValueX.Value == Vector3.new(0, 0, 0) then
		scaleValueX.Value = Vector3.new(ui.Size.X.Scale, ui.Size.X.Offset, 0)
	end
	local scaleValueY: Vector3Value = InsMgr.GetIns(Helpers.SCALE_VALUE_Y_NAME, "Vector3Value", ui) :: Vector3Value
	if scaleValueY.Value == Vector3.new(0, 0, 0) then
		scaleValueY.Value = Vector3.new(ui.Size.Y.Scale, ui.Size.Y.Offset, 0)
	end
end

--[[
	获取或创建 GuiObject 上的 UIScale 子实例
	@param uiFrame GuiObject - 目标 UI 节点
	@param initialScale number? - 创建时的初始 Scale；nil 时为 1
	@return UIScale - UIScale 实例
]]
function Helpers.GetOrCreateUIScale(uiFrame: GuiObject, initialScale: number?): UIScale
	local uiScale: Instance? = uiFrame:FindFirstChild(Helpers.UI_SCALE_CHILD_NAME)
	if not uiScale or not uiScale:IsA("UIScale") then
		uiScale = Instance.new("UIScale")
		uiScale.Name = Helpers.UI_SCALE_CHILD_NAME
		uiScale.Scale = initialScale or 1
		uiScale.Parent = uiFrame
	end
	return uiScale :: UIScale
end

--[[
	获取本地玩家 ScreenGui 及全局 UIScale 倍率（仅客户端有效）
	@return ScreenGui? - ScreenGui 实例，不存在时 nil
	@return number - ScreenGui 上 UIScale.Scale，无则 1
]]
function Helpers.GetScreenGuiScale(): (ScreenGui?, number)
	local localPlayer = Players.LocalPlayer
	if not localPlayer then
		return nil, 1
	end

	local playerGui = localPlayer:FindFirstChild("PlayerGui")
	if not playerGui then
		return nil, 1
	end

	local screenGui = playerGui:FindFirstChild(Helpers.SCREEN_GUI_NAME)
	if not screenGui or not screenGui:IsA("ScreenGui") then
		return nil, 1
	end

	local uiScaleInst = screenGui:FindFirstChildOfClass("UIScale")
	local scale = 1
	if uiScaleInst then
		scale = uiScaleInst.Scale
	end

	return screenGui, scale
end

--[[
	断开连接数组中的全部 RBXScriptConnection
	@param conns {RBXScriptConnection} - 待断开的连接列表
	@return nil - 无返回值
]]
function Helpers.DisconnectConnections(conns: { RBXScriptConnection })
	for _, conn in conns do
		conn:Disconnect()
	end
	table.clear(conns)
end

--[[
	Tween.Completed 只回调一次并立刻断开，避免节点销毁后连接残留
	@param tween Tween - 已 Create 的 Tween
	@param callback () -> () - Completed 后执行
	@return RBXScriptConnection - 已连接的 Completed
]]
function Helpers.OnTweenCompletedOnce(tween: Tween, callback: () -> ()): RBXScriptConnection
	local conn: RBXScriptConnection
	conn = tween.Completed:Connect(function()
		conn:Disconnect()
		callback()
	end)
	return conn
end

--[[
	在按钮/红点节点上播放 UIScale Tween；fromScale 为 nil 时从当前 Scale 开始
	@param uiFrame GuiObject - 目标节点
	@param fromScale number? - 起始 Scale；nil 时不改当前值
	@param toScale number - 目标 Scale
	@param duration number - 时长（秒）
	@param easingStyle Enum.EasingStyle - 缓动样式
	@param easingDirection Enum.EasingDirection - 缓动方向
	@return Tween - 已 Play 的缩放动画
]]
function Helpers.PlayButtonScaleTween(
	uiFrame: GuiObject,
	fromScale: number?,
	toScale: number,
	duration: number,
	easingStyle: Enum.EasingStyle,
	easingDirection: Enum.EasingDirection
): Tween
	local uiScale: UIScale = InsMgr.GetIns(Helpers.BUTTON_SCALE_INS_NAME, "UIScale", uiFrame) :: UIScale
	if fromScale ~= nil then
		uiScale.Scale = fromScale
	end
	local tween = TweenService:Create(uiScale, TweenInfo.new(
		duration,
		easingStyle,
		easingDirection,
		0,
		false
	), { Scale = toScale })
	tween:Play()
	return tween
end

--[[
	校验节点是否为 GuiObject
	@param inst any - 待校验实例
	@return boolean - 是 GuiObject 时 true
]]
function Helpers.IsGuiObject(inst: any): boolean
	return inst ~= nil and typeof(inst) == "Instance" and inst:IsA("GuiObject")
end

return Helpers
