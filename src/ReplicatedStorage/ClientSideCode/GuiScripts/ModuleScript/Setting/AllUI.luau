local Players = game:GetService("Players")
local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui", math.huge)
local screenGui = playerGui:WaitForChild("ScreenGui", math.huge)
local rootFrame = screenGui:WaitForChild("Setting", math.huge)
local contentRoot = rootFrame:FindFirstChild("ContentClip") or rootFrame

local m = {
	UIRoot = rootFrame,
}
-- Setting._TopTab
m["TopTab"] = contentRoot["_TopTab"]::Frame
-- Setting.BG._滑动条bg
m["滑动条bg"] = contentRoot["BG"]["_滑动条bg"]::ImageLabel
-- Setting.Frame._ScrollingFrame
m["ScrollingFrame"] = contentRoot["Frame"]["_ScrollingFrame"]::ScrollingFrame
-- Setting.Top._Exit
m["Exit"] = contentRoot["Top"]["_Exit"]::Frame
-- Setting._TopTab._TabTemp
m["TabTemp"] = contentRoot["_TopTab"]["_TabTemp"]::Frame
-- Setting.Frame._ScrollingFrame._SecondFrame
m["SecondFrame"] = contentRoot["Frame"]["_ScrollingFrame"]["_SecondFrame"]::Frame
-- Setting.Frame._ScrollingFrame._SecondFrame._Temp
m["Temp"] = contentRoot["Frame"]["_ScrollingFrame"]["_SecondFrame"]["_Temp"]::Frame
-- Setting.Frame._ScrollingFrame._SecondFrame._TempBar
m["TempBar"] = contentRoot["Frame"]["_ScrollingFrame"]["_SecondFrame"]["_TempBar"]::Frame
-- Setting.Frame._ScrollingFrame._SecondFrame._TempChoose
m["TempChoose"] = contentRoot["Frame"]["_ScrollingFrame"]["_SecondFrame"]["_TempChoose"]::Frame
-- Setting.Frame._ScrollingFrame._SecondFrame._TempInput
m["TempInput"] = contentRoot["Frame"]["_ScrollingFrame"]["_SecondFrame"]["_TempInput"]::Frame
return m