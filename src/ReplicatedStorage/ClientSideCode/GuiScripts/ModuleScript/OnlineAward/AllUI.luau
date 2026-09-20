--[[
	Module: OnlineAward/AllUI
	Description: OnlineAward 界面节点索引（Login 树，根 Frame 名为 OnlineAward）
	Author: 林奥宇
	Created: 2026-09-04
	Last Modified: 2026-09-04
]]

local Players = game:GetService("Players")
local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui", math.huge)
local screenGui = playerGui:WaitForChild("ScreenGui", math.huge)
local rootFrame = screenGui:WaitForChild("OnlineAward", math.huge)
local contentRoot = rootFrame:FindFirstChild("ContentClip") or rootFrame

local m = {
	UIRoot = rootFrame,
}
-- OnlineAward.Bottom._ClaimAll
m["ClaimAll"] = contentRoot["Bottom"]["_ClaimAll"] :: Frame
-- OnlineAward.Main._OnlineScroll
m["OnlineScroll"] = contentRoot["Main"]["_OnlineScroll"] :: ScrollingFrame
-- OnlineAward.Top._Exit
m["Exit"] = contentRoot["Top"]["_Exit"] :: Frame
-- OnlineAward.Main._OnlineScroll._Temp
m["Temp"] = contentRoot["Main"]["_OnlineScroll"]["_Temp"] :: TextButton
return m
