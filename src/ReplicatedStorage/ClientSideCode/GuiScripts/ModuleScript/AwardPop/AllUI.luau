--[[
	Module: AwardPop/AllUI
	Description: AwardPop 界面节点索引（根 Frame 名为 AwardPop）
	Author: 林奥宇
	Created: 2026-09-04
	Last Modified: 2026-09-04
]]

local Players = game:GetService("Players")
local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui", math.huge)
local screenGui = playerGui:WaitForChild("ScreenGui", math.huge)
local rootFrame = screenGui:WaitForChild("AwardPop", math.huge)
local contentRoot = rootFrame:FindFirstChild("ContentClip") or rootFrame

local main = contentRoot:FindFirstChild("Main")
local top = contentRoot:FindFirstChild("Top")
local bottom = contentRoot:FindFirstChild("Bottom")
local scroll = if main then main:FindFirstChild("_Scroll") else nil

local m = {
	UIRoot = rootFrame,
}
-- AwardPop.Top._Exit
m["Exit"] = if top then top:FindFirstChild("_Exit") else nil
-- AwardPop.Bottom._AwardBtn
m["AwardBtn"] = if bottom then bottom:FindFirstChild("_AwardBtn") else nil
-- AwardPop.Main._Scroll
m["Scroll"] = scroll
-- AwardPop.Main._Scroll._MagicAward（隐藏模板）
m["MagicAward"] = if scroll then scroll:FindFirstChild("_MagicAward") else nil
-- AwardPop.Main._Scroll._MoneyAward（隐藏模板）
m["MoneyAward"] = if scroll then scroll:FindFirstChild("_MoneyAward") else nil
-- AwardPop.Main._Scroll._Temp（隐藏物品模板）
m["Temp"] = if scroll then scroll:FindFirstChild("_Temp") else nil
return m