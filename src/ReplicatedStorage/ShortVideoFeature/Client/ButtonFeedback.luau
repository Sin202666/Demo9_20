--[[
	Module: ButtonFeedback
	Description: 短视频按钮悬浮放大 + 按下缩小反馈（对齐 UIanima.BtnScaleAnimEnter/Leave、ButtonDown/Up；无 Utils 时可独立迁移）
	Author: 林奥宇
	Created: 2026-08-13
	Last Modified: 2026-08-14

	能力:
		- 鼠标进入：放大至 HoverScale（默认 1.1）
		- 鼠标离开：恢复 1；若处于按下态一并清掉
		- 按下：缩至 DownScale（默认 0.9）；抬起后若仍悬浮则回到 HoverScale，否则回 1
		- PlayLikePop：点赞态切换后的弹跳（立刻可感知，不依赖服务端回包）

	用法:
		ButtonFeedback.Bind(btn) -- 返回需在 destroy 时 Disconnect 的连接表
		ButtonFeedback.BindMany({ btn1, btn2 })
		ButtonFeedback.PlayLikePop(likeBtn) -- 乐观切图后调用
]]

local TweenService = game:GetService("TweenService")

local Constants = require(script.Parent.Parent.Shared.Constants)

local ButtonFeedback = {}

local ATTR_MOUSE_DOWN = "SV_BtnPressed"
local ATTR_HOVERING = "SV_BtnHovering"
local SCALE_NAME = "UIScale"

local cfg = Constants.UI.ButtonFeedback
local DOWN_SCALE = cfg.DownScale or 0.9
local TWEEN_TIME = cfg.TweenTime or 0.1
local HOVER_SCALE = cfg.HoverScale or 1.1
local HOVER_TWEEN_TIME = cfg.HoverTweenTime or 0.2
local LIKE_POP_SCALE = cfg.LikePopScale or 1.28
local LIKE_POP_UP_SEC = cfg.LikePopUpSec or 0.08
local LIKE_POP_DOWN_SEC = cfg.LikePopDownSec or 0.16

--[[
	获取或创建 UIScale
	@param gui GuiObject - 目标
	@return UIScale - 缩放实例
]]
local function getOrCreateScale(gui: GuiObject): UIScale
	local existing = gui:FindFirstChild(SCALE_NAME)
	if existing and existing:IsA("UIScale") then
		return existing
	end
	local s = Instance.new("UIScale")
	s.Name = SCALE_NAME
	s.Scale = 1
	s.Parent = gui
	return s
end

--[[
	播放缩放到目标值
	@param gui GuiObject - 目标
	@param scale number - 目标倍率
	@param duration number? - 时长；默认按下 TweenTime
	@param easingStyle Enum.EasingStyle? - 缓动；按下用 Bounce，悬浮用 Linear
]]
local function tweenScale(
	gui: GuiObject,
	scale: number,
	duration: number?,
	easingStyle: Enum.EasingStyle?
)
	local uiScale = getOrCreateScale(gui)
	local tw = TweenService:Create(
		uiScale,
		TweenInfo.new(
			duration or TWEEN_TIME,
			easingStyle or Enum.EasingStyle.Bounce,
			Enum.EasingDirection.Out
		),
		{ Scale = scale }
	)
	tw:Play()
end

--[[
	按当前悬浮态选恢复倍率（悬浮中 → HoverScale，否则 1）
	@param gui GuiObject - 缩放目标
	@return number - 目标倍率
]]
local function idleScale(gui: GuiObject): number
	if gui:GetAttribute(ATTR_HOVERING) == true then
		return HOVER_SCALE
	end
	return 1
end

--[[
	若处于按下态则抬起，并按悬浮态恢复
	@param gui GuiObject - 缩放目标
]]
local function restoreIfPressed(gui: GuiObject)
	if gui:GetAttribute(ATTR_MOUSE_DOWN) == true then
		gui:SetAttribute(ATTR_MOUSE_DOWN, nil)
		tweenScale(gui, idleScale(gui), TWEEN_TIME, Enum.EasingStyle.Bounce)
	end
end

--[[
	为可点击 GuiButton 绑定悬浮放大 + 按下缩小反馈
	@param btn GuiButton - 按钮
	@param scaleTarget GuiObject? - 实际缩放节点，默认 btn 自身
	@return {RBXScriptConnection} - 连接列表
]]
function ButtonFeedback.Bind(btn: GuiButton, scaleTarget: GuiObject?): { RBXScriptConnection }
	local target = scaleTarget or btn
	getOrCreateScale(target)
	local conns: { RBXScriptConnection } = {}

	table.insert(conns, btn.MouseEnter:Connect(function()
		target:SetAttribute(ATTR_HOVERING, true)
		if target:GetAttribute(ATTR_MOUSE_DOWN) ~= true then
			tweenScale(target, HOVER_SCALE, HOVER_TWEEN_TIME, Enum.EasingStyle.Linear)
		end
	end))
	table.insert(conns, btn.MouseLeave:Connect(function()
		target:SetAttribute(ATTR_HOVERING, nil)
		if target:GetAttribute(ATTR_MOUSE_DOWN) == true then
			target:SetAttribute(ATTR_MOUSE_DOWN, nil)
		end
		tweenScale(target, 1, HOVER_TWEEN_TIME, Enum.EasingStyle.Linear)
	end))
	table.insert(conns, btn.MouseButton1Down:Connect(function()
		target:SetAttribute(ATTR_MOUSE_DOWN, true)
		tweenScale(target, DOWN_SCALE, TWEEN_TIME, Enum.EasingStyle.Bounce)
	end))
	table.insert(conns, btn.MouseButton1Up:Connect(function()
		restoreIfPressed(target)
	end))

	return conns
end

--[[
	批量绑定
	@param buttons {GuiButton} - 按钮列表
	@return {RBXScriptConnection} - 全部连接
]]
function ButtonFeedback.BindMany(buttons: { GuiButton }): { RBXScriptConnection }
	local all: { RBXScriptConnection } = {}
	for _, btn in ipairs(buttons) do
		if btn then
			for _, c in ipairs(ButtonFeedback.Bind(btn)) do
				table.insert(all, c)
			end
		end
	end
	return all
end

--[[
	点赞切图后的弹跳反馈（先冲高再回落至当前悬浮/常态倍率）
	@param gui GuiObject - 通常为 LikeBtn
]]
function ButtonFeedback.PlayLikePop(gui: GuiObject)
	local uiScale = getOrCreateScale(gui)
	local back = idleScale(gui)
	uiScale.Scale = math.min(uiScale.Scale, 1)
	local up = TweenService:Create(
		uiScale,
		TweenInfo.new(LIKE_POP_UP_SEC, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Scale = LIKE_POP_SCALE }
	)
	local down = TweenService:Create(
		uiScale,
		TweenInfo.new(LIKE_POP_DOWN_SEC, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Scale = back }
	)
	up:Play()
	up.Completed:Once(function()
		-- 弹跳中途若又按下，交给 Down 态接管，避免盖掉按压缩放
		if gui:GetAttribute(ATTR_MOUSE_DOWN) == true then
			return
		end
		down:Play()
	end)
end

return ButtonFeedback
