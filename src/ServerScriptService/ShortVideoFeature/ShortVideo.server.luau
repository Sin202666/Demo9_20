--[[
	Module: ShortVideo.server
	Description: ShortVideoFeature 唯一服务端入口：Remotes / Config / Social
	Author: 林奥宇
	Created: 2026-08-13
	Last Modified: 2026-08-18

	GameConfig「短视频.启用」= false 时不 Init。
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local SystemGameConfig = Utils.SystemGameConfig
local ReplicatedStorage = Utils.ReplicatedStorage

if SystemGameConfig.GetValue({ "短视频", "启用" }) == false then
	return
end

local feature = ReplicatedStorage:WaitForChild("ShortVideoFeature")
local Remotes = require(feature.Shared.Remotes)
local ConfigListService = require(feature.Server.ConfigListService)
local SocialHandlers = require(feature.Server.SocialHandlers)

Remotes.Ensure()
ConfigListService.Init()
SocialHandlers.Init()

print("[ShortVideoFeature] server ready")
