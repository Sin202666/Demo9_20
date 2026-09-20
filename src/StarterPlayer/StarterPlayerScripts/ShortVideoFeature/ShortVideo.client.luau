--[[
	Module: ShortVideo.client
	Description: ShortVideoFeature 唯一客户端入口；挂载 API
	Author: 林奥宇
	Created: 2026-08-13
	Last Modified: 2026-08-18

	GameConfig「短视频.启用」= false 时不挂载。
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local SystemGameConfig = Utils.SystemGameConfig
local Players = Utils.Players
local ReplicatedStorage = Utils.ReplicatedStorage

if SystemGameConfig.GetValue({ "短视频", "启用" }) == false then
	return
end

local feature = ReplicatedStorage:WaitForChild("ShortVideoFeature")
local ShortVideoFeature = require(feature)

Players.LocalPlayer.AncestryChanged:Connect(function(_, parent)
	if not parent then
		ShortVideoFeature.Close("leave")
	end
end)

print("[ShortVideoFeature] client ready")
