--[[
	Module: RejoinTip
	Description: 重连/更新等待提示弹窗——循环播放 Waiting 文本动画
	Author: 中台组
	Created: 2026-01-29
	Last Modified: 2026-07-03

	功能：
	- openUi：异步播放 50 轮点号动画（不阻塞调用方）
	- updateUi / closeUi：预留接口

	约定：
	- UI 根节点为 script.Parent（ScreenGui 下同名 Frame）
	- BG.Tips 为 TextLabel

	加载（UIManager 动态 require）：
	local RejoinTip = require(...ModuleScript.RejoinTip)
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local TranslationHelper = Utils.TranslationHelper

local RejoinTip = {}

local UI: Frame = script.Parent :: Frame
local tips = UI:FindFirstChild("BG")
if tips and tips:IsA("Frame") then
	tips = tips:FindFirstChild("Tips")
end

local _tipsLabel: TextLabel? = nil
if tips and tips:IsA("TextLabel") then
	_tipsLabel = tips :: TextLabel
end

local _animRunning = false

--[[
	更新 UI（预留接口）
	@param UiData any? - 业务数据，当前未使用
	@return nil
]]
function RejoinTip:updateUi(UiData: any?)
end

--[[
	打开 UI 并启动等待动画
	@return nil
]]
function RejoinTip:openUi()
	if not _tipsLabel or _animRunning then
		return
	end

	_animRunning = true
	task.spawn(function()
		for _ = 1, 50 do
			if not _tipsLabel or not _animRunning then
				break
			end
			TranslationHelper.SetText(_tipsLabel, "正在等待更新", { "..." })
			task.wait(0.5)
			if not _tipsLabel or not _animRunning then
				break
			end
			TranslationHelper.SetText(_tipsLabel, "正在等待更新", { ".." })
			task.wait(0.5)
			if not _tipsLabel or not _animRunning then
				break
			end
			TranslationHelper.SetText(_tipsLabel, "正在等待更新", { "." })
			task.wait(0.5)
			if not _tipsLabel or not _animRunning then
				break
			end
			TranslationHelper.SetText(_tipsLabel, "正在等待更新", { "" })
			task.wait(0.5)
		end
		_animRunning = false
	end)
end

--[[
	关闭 UI（预留接口）
	@return nil
]]
function RejoinTip:closeUi()
	_animRunning = false
end

return RejoinTip
