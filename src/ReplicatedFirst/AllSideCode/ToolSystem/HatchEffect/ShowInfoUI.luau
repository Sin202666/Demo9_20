--[[
	Module: HatchEffect/ShowInfoUI
	Description: 抽蛋奖励信息 UI 创建与进出场动画
	Author: 林奥宇
	Created: 2026-01-29
	Last Modified: 2026-09-01

	由 HatchEffect.init 内部调用。依赖 PlayerGui.UIAnimGui.RngShowUI 与 PetInfo1~5。
	玩家可见名称走 TranslationHelper.SetText + 配置 ZhName。
]]

-- ============================================================================
-- 服务与依赖
-- ============================================================================

local TweenService = game:GetService("TweenService")

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local CfgFind = Utils.CfgFind
local UIMgr = Utils.UIMgr
local TranslationHelper = Utils.TranslationHelper
local Log = Utils.Log
local LocalPlayer = Utils.LocalPlayer

local HatchConfig = require(script.Parent.HatchConfig)

local ShowInfoUI = {}

-- ============================================================================
-- 常量与私有状态
-- ============================================================================

local showTween: {[number]: Tween} = {}
local hideTween: {[number]: Tween} = {}
local showTweenConn: {[number]: RBXScriptConnection} = {}
local hideTweenConn: {[number]: RBXScriptConnection} = {}
local uiSessionId = 0

local SHOW_START_POS = {
	[1] = UDim2.new(0.5, 0, -0.3, 0),
	[2] = UDim2.new(0.73, 0, -0.5, 0),
	[3] = UDim2.new(0.27, 0, -0.5, 0),
	[4] = UDim2.new(0.13, 0, -0.5, 0),
	[5] = UDim2.new(0.87, 0, -0.5, 0),
}

local SHOW_GOAL_POS = {
	[1] = UDim2.new(0.5, 0, 0.72, 0),
	[2] = UDim2.new(0.73, 0, 0.7, 0),
	[3] = UDim2.new(0.27, 0, 0.7, 0),
	[4] = UDim2.new(0.13, 0, 0.68, 0),
	[5] = UDim2.new(0.87, 0, 0.68, 0),
}

local HIDE_GOAL_POS = {
	[1] = UDim2.new(0.5, 0, 1.5, 0),
	[2] = UDim2.new(0.78, 0, 1.1, 0),
	[3] = UDim2.new(0.27, 0, 1.1, 0),
	[4] = UDim2.new(0.13, 0, 1.1, 0),
	[5] = UDim2.new(0.95, 0, 1.1, 0),
}

-- ============================================================================
-- 私有函数
-- ============================================================================

--[[
	断开并销毁指定槽位的 Tween 与 Completed 连接

	@param tweens {[number]: Tween} - 入场或退场 Tween 表
	@param conns {[number]: RBXScriptConnection} - 对应 Completed 连接
	@param index number - PetInfo 槽位（1~5）
]]
local function _clearTweenSlot(tweens: {[number]: Tween}, conns: {[number]: RBXScriptConnection}, index: number)
	if conns[index] then
		conns[index]:Disconnect()
		conns[index] = nil
	end
	if tweens[index] then
		tweens[index]:Pause()
		tweens[index]:Destroy()
		tweens[index] = nil
	end
end

--[[
	获取 RngShowUI 容器

	@return Frame? - PlayerGui.UIAnimGui.RngShowUI；任一层缺失时 nil
]]
local function _getRngShowUI(): Frame?
	if not LocalPlayer then
		Log.warn("缺少 LocalPlayer")
		return nil
	end

	local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
	if not playerGui then
		Log.warn("缺少玩家GUI")
		return nil
	end

	local uiAnimGui = playerGui:FindFirstChild("UIAnimGui")
	if not uiAnimGui then
		Log.warn("缺少UI动画GUI")
		return nil
	end

	local rngShowUI = uiAnimGui:FindFirstChild("RngShowUI")
	if not rngShowUI then
		Log.warn("缺少随机展示UI")
		return nil
	end

	return rngShowUI
end

-- ============================================================================
-- 公共 API
-- ============================================================================

--[[
	填充奖励信息 UI 内容（稀有度渐变、名称、点击继续显隐）

	@param itemIds {number} - 已按 xyd 降序的宠物 ID，对应 PetInfo1~N
	@param isAutoSkip boolean? - true 时隐藏「点击继续」；nil 视为 false
	@return nil - 无返回值；缺 UI 或配置时跳过对应槽位
]]
function ShowInfoUI.createUI(itemIds: {number}, isAutoSkip: boolean?)
	local rngShowUI = _getRngShowUI()
	if not rngShowUI then
		return
	end

	for index, itemId in ipairs(itemIds) do
		local infoUI = rngShowUI:FindFirstChild("PetInfo" .. index)
		if not infoUI then
			continue
		end

		infoUI.Visible = false

		if index == 1 then
			local tips = infoUI:FindFirstChild("点击继续")
			if tips then
				tips.Visible = not isAutoSkip
			end
		end

		local cfg = CfgFind.FindCfgByID(itemId)
		if not cfg then
			continue
		end

		if cfg["xyd"] then
			UIMgr.AddGradientColor(cfg["xyd"], infoUI.Rare, true)
			UIMgr.setXydLabel(infoUI.Rare, cfg["xyd"])
		end

		if cfg["ZhName"] then
			TranslationHelper.SetText(infoUI.PetName, cfg["ZhName"])
		end
	end
end

--[[
	播放 UI 入场动画

	@param speedScale number - 时长倍率，越大越慢
	@param infoNum number - 要播放的 PetInfo 槽位数（1~MAX_HATCH_TIME）
	@return nil - 无返回值
]]
function ShowInfoUI.showUI(speedScale: number, infoNum: number)
	local rngShowUI = _getRngShowUI()
	if not rngShowUI then
		return
	end

	uiSessionId += 1
	local sessionId = uiSessionId

	for index = 1, infoNum do
		local ui = rngShowUI:FindFirstChild("PetInfo" .. index)
		if not ui then
			continue
		end

		local startPos = SHOW_START_POS[index]
		local goalPos = SHOW_GOAL_POS[index]
		local goalSize = ui.Size

		ui.Position = startPos
		ui.Size = goalSize
		ui.Visible = true

		_clearTweenSlot(showTween, showTweenConn, index)
		_clearTweenSlot(hideTween, hideTweenConn, index)

		local tweenTime = HatchConfig.SHOW_UI_TWEEN_TIME * speedScale
		showTween[index] = TweenService:Create(
			ui,
			TweenInfo.new(tweenTime, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Size = goalSize, Position = goalPos }
		)
		showTweenConn[index] = showTween[index].Completed:Connect(function()
			if sessionId ~= uiSessionId then
				return
			end
			_clearTweenSlot(showTween, showTweenConn, index)
		end)

		showTween[index]:Play()
	end
end

--[[
	播放 UI 退场动画

	@param speedScale number - 时长倍率，越大越慢
	@param infoNum number - 要播放的 PetInfo 槽位数
	@return nil - 无返回值
]]
function ShowInfoUI.hideUI(speedScale: number, infoNum: number)
	local rngShowUI = _getRngShowUI()
	if not rngShowUI then
		return
	end

	uiSessionId += 1
	local sessionId = uiSessionId

	for index = 1, infoNum do
		local ui = rngShowUI:FindFirstChild("PetInfo" .. index)
		if not ui then
			continue
		end

		ui.Position = SHOW_GOAL_POS[index]
		local goalPos = HIDE_GOAL_POS[index]
		local tweenTime = HatchConfig.HIDE_UI_TWEEN_TIME * speedScale

		_clearTweenSlot(hideTween, hideTweenConn, index)
		_clearTweenSlot(showTween, showTweenConn, index)

		hideTween[index] = TweenService:Create(
			ui,
			TweenInfo.new(tweenTime, Enum.EasingStyle.Back, Enum.EasingDirection.In),
			{ Position = goalPos }
		)
		hideTweenConn[index] = hideTween[index].Completed:Connect(function()
			if sessionId ~= uiSessionId then
				return
			end
			_clearTweenSlot(hideTween, hideTweenConn, index)
		end)

		hideTween[index]:Play()
	end
end

return ShowInfoUI
