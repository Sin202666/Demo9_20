--[[
	Module: DailyReward/AllUI
	Description: DailyReward 界面节点索引（Login 树，根 Frame 名为 DailyReward）
	Author: 林奥宇
	Created: 2026-09-04
	Last Modified: 2026-09-04
]]

local Players = game:GetService("Players")
local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui", math.huge)
local screenGui = playerGui:WaitForChild("ScreenGui", math.huge)
local rootFrame = screenGui:WaitForChild("DailyReward", math.huge)
local contentRoot = rootFrame:FindFirstChild("ContentClip") or rootFrame

local m = {
	UIRoot = rootFrame,
}
-- DailyReward.Main._LoginFrame
m["LoginFrame"] = contentRoot["Main"]["_LoginFrame"] :: Frame
-- DailyReward.Right
m["Right"] = contentRoot["Right"] :: Frame
-- DailyReward.Top._Exit
m["Exit"] = contentRoot["Top"]["_Exit"] :: Frame
-- DailyReward.Top.每日签到标题
m["Title"] = contentRoot["Top"]["每日签到标题"] :: TextLabel
-- DailyReward.Main._LoginFrame._BigFrame
m["BigFrame"] = contentRoot["Main"]["_LoginFrame"]["_BigFrame"] :: Frame
-- DailyReward.Main._LoginFrame.SmallTemp._Temp
m["Temp"] = contentRoot["Main"]["_LoginFrame"]["SmallTemp"]["_Temp"] :: TextButton
-- DailyReward.Main._LoginFrame._BigFrame._BigTemp
m["BigTemp"] = contentRoot["Main"]["_LoginFrame"]["_BigFrame"]["_BigTemp"] :: TextButton
return m
