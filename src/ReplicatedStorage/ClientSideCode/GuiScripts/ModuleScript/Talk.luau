--[[
	Module: Talk
	Description: 对话系统 UI——控制 Talk 弹窗显隐与主 UI 遮挡
	Author: 中台组
	Created: 2026-01-29
	Last Modified: 2026-07-03

	功能：
	- openUi：显示 Talk Frame，隐藏主 UI
	- closeUi：隐藏 Talk Frame，恢复主 UI

	约定：
	- ScreenGui 下须存在 Talk Frame

	加载（UIManager 动态 require）：
	local Talk = require(...ModuleScript.Talk)
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local UIMgr = Utils.UIMgr
local LocalPlayer = Utils.LocalPlayer

local Talk = {}

local _playerGui = LocalPlayer:WaitForChild("PlayerGui", math.huge)
local _screenGui = _playerGui:WaitForChild("ScreenGui", math.huge)
local TalkUI = _screenGui:WaitForChild("Talk") :: Frame

--[[
	更新 UI（预留接口）
	@param UiData any? - 业务数据，当前未使用
	@return nil
]]
function Talk:updateUi(UiData: any?)
end

--[[
	打开对话 UI
	@return nil
]]
function Talk:openUi()
	TalkUI.Visible = true
	UIMgr.SetMainUIVisible(false)
end

--[[
	关闭对话 UI
	@return nil
]]
function Talk:closeUi()
	TalkUI.Visible = false
	UIMgr.SetMainUIVisible(true)
end

return Talk
