--[[

	NOTE: This script should be in game.ServerScriptService

--]]
local isDebug = false
local RunService = game:GetService("RunService")

if RunService:IsStudio() then
	isDebug = true
end

local ReplicatedStorage = game:GetService("ReplicatedStorage")
if isDebug==true then
	return
end

print("启动GA")

local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ServerStorage = game:GetService("ServerStorage")
local GameAnalytics = require(ServerStorage.GameAnalytics)
local Utils = require(ReplicatedFirst.AllSideCode.UtilsSystem)

local versionID: string = Utils.SystemGameConfig.GetValue("版本号")

local OnPlayerReadyEvent: BindableEvent = ReplicatedStorage:WaitForChild("OnPlayerReadyEvent", math.huge)
OnPlayerReadyEvent.Event:Connect(function(_plr: Player)
	local isPremium = _plr.MembershipType == Enum.MembershipType.Premium

	pcall(function()
		GameAnalytics:setCustomDimension01(_plr.UserId, isPremium and 'Premium' or 'NonPremium')
	end)
end)

local gameK = nil
local secretK = nil
if isDebug==true then
	gameK = "52bfa28e7bd3044516d7a7e70bdb05e7"
	secretK = "9dcad57c028bb95eb5cc0690cb051983e92c50e4"
else
	gameK = "52bfa28e7bd3044516d7a7e70bdb05e7"
	secretK = "9dcad57c028bb95eb5cc0690cb051983e92c50e4"
end

GameAnalytics:initialize({
	build = versionID,
	
	gameKey = gameK,
	secretKey = secretK,

	enableInfoLog = isDebug,
	enableVerboseLog = false,

	--debug is by default enabled in studio only
	enableDebugLog = nil,

	automaticSendBusinessEvents = true,
	reportErrors = true,

	availableCustomDimensions01 = {},
	availableCustomDimensions02 = {},
	availableCustomDimensions03 = {},
	availableResourceCurrencies = {},
	availableResourceItemTypes = {},
	availableGamepasses = {}
})

local GADesignEvent = Instance.new("RemoteEvent", ReplicatedStorage)
GADesignEvent.Name = "GADesignEvent"

local function onMyDesignEventFired(player, myEventId)
	GameAnalytics:addDesignEvent(player.UserId, {
		eventId = myEventId
	})
end

GADesignEvent.OnServerEvent:Connect(onMyDesignEventFired)