--[[
	Module: WarnPop/AllUI
	Description: WarnPop 界面节点索引（根 Frame 名为 WarnPop）
	Author: 林奥宇
	Created: 2026-09-04
	Last Modified: 2026-09-04
]]

local Players = game:GetService("Players")
local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui", math.huge)
local screenGui = playerGui:WaitForChild("ScreenGui", math.huge)
local rootFrame = screenGui:WaitForChild("WarnPop", math.huge)
local contentRoot = rootFrame:FindFirstChild("ContentClip") or rootFrame

local m = {
	UIRoot = rootFrame,
}
-- WarnPop._Bottom
m["Bottom"] = contentRoot["_Bottom"] :: Frame
-- WarnPop.Main._Text
m["Text"] = contentRoot["Main"]["_Text"] :: TextLabel
-- WarnPop.Top._Exit
m["Exit"] = contentRoot["Top"]["_Exit"] :: Frame
-- WarnPop.Top._Title
m["Title"] = contentRoot["Top"]["_Title"] :: TextLabel
-- WarnPop._Bottom._BackBtn
m["BackBtn"] = contentRoot["_Bottom"]["_BackBtn"] :: Frame
-- WarnPop._Bottom._OkBtn
m["OkBtn"] = contentRoot["_Bottom"]["_OkBtn"] :: Frame
return m
