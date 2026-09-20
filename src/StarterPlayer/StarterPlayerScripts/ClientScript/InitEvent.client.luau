--[[
	Module: InitEvent
	Description: Roblox 体验事件（Experience Events）RSVP 通知与 TopbarPlus 入口
	Author: 林奥宇
	Created: 2026-07-03
	Last Modified: 2026-08-31

	功能：
	- 拉取未开始的体验事件并缓存 RSVP 状态
	- 未 RSVP 的玩家显示 TopbarPlus 入口
	- 延迟推送 EVENT_NOTIFY，引导玩家 PromptRsvpToEventAsync

	依赖：
	- TopbarPlus Icon：第三方包，未纳入 UtilsSystem，顶部直接 require
	- Utils.NetWork.RegisterBindableEvent(NetMsg.EVENT_NOTIFY)
	- player.IsNewPlayer BoolValue：新玩家延长首次通知延迟
	- Utils.TranslationHelper：顶栏标签 TranslateByKey("活动通知")

	约定：
	- 本文件为 StarterPlayerScripts LocalScript，启动即绑定；无 Init() / 模块表
	- RSVP 走 Roblox SocialService，不写存档、不结算奖励
	- IsNewPlayer 等待超时后按普通玩家延迟推送，避免永久挂起

	加载方式：
		本脚本由 StarterPlayer 自动运行，无需 require
]]

-- ========================================
-- 服务引用
-- ========================================
-- SocialService / Workspace 未纳入 UtilsSystem
local SocialService = game:GetService("SocialService")
local Workspace = game:GetService("Workspace")

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

-- TopbarPlus 第三方包，未纳入 UtilsSystem
local Icon = require(game.ReplicatedStorage.ClientSideCode.Tool.TopbarPlus.Icon)

local InsMgr = Utils.InsMgr
local LocalPlayer = Utils.LocalPlayer
local Log = Utils.Log
local NetMsg = Utils.NetMsg
local NetWork = Utils.NetWork
local TranslationHelper = Utils.TranslationHelper

-- ========================================
-- 类型
-- ========================================
type ExperienceEventTime = {
	Year: number,
	Month: number,
	Day: number,
	Hour: number,
	Minute: number,
	Second: number,
	Millisecond: number,
}

type ExperienceEvent = {
	Title: string,
	HasStarted: boolean,
	Id: string?,
	UserRsvpStatus: Enum.RsvpStatus,
	StartTime: ExperienceEventTime,
}

-- ========================================
-- 常量
-- ========================================
local EVENT_NOTIFY_DELAY_NORMAL = 10
local EVENT_NOTIFY_DELAY_NEW_PLAYER = 300
local IS_NEW_PLAYER_WAIT_SEC = 30

local ICON_NAME = "Event"
local ICON_ORDER = 6

local RSVP_STATUS_GOING = 1
local RSVP_STATUS_NOT_GOING = 0

local EVENT_FOLDER_NAME = "事件通知"
local IS_NEW_PLAYER_VALUE_NAME = "IsNewPlayer"

-- ========================================
-- 私有变量
-- ========================================
local _localPlayer: Player = LocalPlayer

local _eventMap: { [string]: ExperienceEvent } = {}
local _firstEventTitle: string? = nil
local _hasUnnoticedEvent = false
local _curEventName: string? = nil
local _eventIcon: any? = nil

local _eventFolder: Folder = InsMgr.GetIns(EVENT_FOLDER_NAME, "Folder", _localPlayer)

-- ========================================
-- 私有函数
-- ========================================

--[[
	将 Roblox 事件时间表转为 Unix 时间戳
	@param timeData ExperienceEventTime - { Year, Month, Day, Hour, Minute, Second, Millisecond }
	@return number - UTC Unix 时间戳（秒）
]]
local function _tableToUtcTime(timeData: ExperienceEventTime): number
	local dateTime = DateTime.fromUniversalTime(
		timeData.Year,
		timeData.Month,
		timeData.Day,
		timeData.Hour,
		timeData.Minute,
		timeData.Second,
		timeData.Millisecond
	)
	return dateTime.UnixTimestamp
end

--[[
	筛选尚未开始的体验事件
	@param events {ExperienceEvent} - SocialService:GetUpcomingExperienceEventsAsync 返回的事件数组
	@return { [string]: ExperienceEvent } - 标题为键的未开始事件表
	@return string? - 列表中首个未开始事件标题
]]
local function _filterUpcomingEvents(events: { ExperienceEvent }): ({ [string]: ExperienceEvent }, string?)
	local filteredEvents: { [string]: ExperienceEvent } = {}
	local firstTitle: string? = nil

	for _, event in ipairs(events) do
		if not event.HasStarted then
			filteredEvents[event.Title] = event
			if not firstTitle then
				firstTitle = event.Title
			end
		end
	end

	return filteredEvents, firstTitle
end

--[[
	为每个事件在玩家下创建 RSVP 状态 NumberValue
	@param events { [string]: ExperienceEvent } - 标题为键的事件表
	@return boolean - 是否存在尚未 RSVP（非 Going）的事件
]]
local function _initializeEventRsvpStatus(events: { [string]: ExperienceEvent }): boolean
	local hasUnnoticedEvent = false

	for eventTitle, eventData in pairs(events) do
		local numValue: NumberValue = InsMgr.GetIns(eventTitle, "NumberValue", _eventFolder)
		if eventData.UserRsvpStatus == Enum.RsvpStatus.Going then
			numValue.Value = RSVP_STATUS_GOING
		else
			hasUnnoticedEvent = true
			numValue.Value = RSVP_STATUS_NOT_GOING
		end
	end

	return hasUnnoticedEvent
end

--[[
	创建 TopbarPlus 事件通知图标
	@param firstEventTitle string - 点击时传入 EVENT_NOTIFY 的事件标题
	@return nil - 无返回值
]]
local function _createEventIcon(firstEventTitle: string)
	local icon = Icon.new()
		:setName(ICON_NAME)
		:setLabel(TranslationHelper.TranslateByKey("活动通知"))
		:setRight()
		:setOrder(ICON_ORDER)
		:setCornerRadius(UDim.new(1, 0))
		:autoDeselect(false)

	icon:bindEvent("selected", function()
		NetWork.FireBindable(NetMsg.EVENT_NOTIFY, firstEventTitle)
		icon:deselect()
	end)

	_eventIcon = icon
end

--[[
	响应 EVENT_NOTIFY：弹出 RSVP 对话框并更新本地状态
	@param eventName string - 事件标题，须在 _eventMap 中存在
	@return nil - 已有处理中事件、事件已开始、数据缺失或 Prompt 失败时静默 return
]]
local function _handleEventRsvp(eventName: string)
	if _curEventName then
		return
	end

	local eventData = _eventMap[eventName]
	if not eventData or not eventData.Id then
		return
	end

	local startTime = _tableToUtcTime(eventData.StartTime)
	if Workspace:GetServerTimeNow() > startTime then
		return
	end

	local numValueInstance: Instance? = _eventFolder:FindFirstChild(eventName)
	if not numValueInstance or not numValueInstance:IsA("NumberValue") then
		return
	end

	local numValue = numValueInstance :: NumberValue
	_curEventName = eventName
	local promptOk, rsvpStatus = pcall(function()
		return SocialService:PromptRsvpToEventAsync(eventData.Id)
	end)
	_curEventName = nil

	if not promptOk then
		Log.warn("[InitEvent] PromptRsvpToEventAsync 失败", rsvpStatus)
		return
	end

	if rsvpStatus == Enum.RsvpStatus.Going then
		numValue.Value = RSVP_STATUS_GOING
		if _eventIcon then
			_eventIcon:destroy()
			_eventIcon = nil
		end
	else
		numValue.Value = RSVP_STATUS_NOT_GOING
	end
end

--[[
	延迟向未 RSVP 玩家推送事件通知
	@param eventName string - 事件标题
	@param delaySeconds number - 延迟秒数
	@return nil - 无返回值
]]
local function _scheduleEventNotification(eventName: string, delaySeconds: number)
	task.delay(delaySeconds, function()
		local numValueInstance: Instance? = _eventFolder:FindFirstChild(eventName)
		if numValueInstance and numValueInstance:IsA("NumberValue") then
			local numValue = numValueInstance :: NumberValue
			if numValue.Value == RSVP_STATUS_NOT_GOING then
				NetWork.FireBindable(NetMsg.EVENT_NOTIFY, eventName)
			end
		end
	end)
end

-- ========================================
-- 初始化
-- ========================================
local success, eventsOrError = pcall(function()
	return SocialService:GetUpcomingExperienceEventsAsync()
end)

if not success then
	Log.warn("[InitEvent] 获取体验事件失败", eventsOrError)
	return
end

_eventMap, _firstEventTitle = _filterUpcomingEvents(eventsOrError)
_hasUnnoticedEvent = _initializeEventRsvpStatus(_eventMap)

if _hasUnnoticedEvent and _firstEventTitle then
	_createEventIcon(_firstEventTitle)
end

NetWork.RegisterBindableEvent(NetMsg.EVENT_NOTIFY, _handleEventRsvp)

if _firstEventTitle then
	local isNewPlayerInstance: Instance? = _localPlayer:FindFirstChild(IS_NEW_PLAYER_VALUE_NAME)
	if not isNewPlayerInstance then
		isNewPlayerInstance = _localPlayer:WaitForChild(IS_NEW_PLAYER_VALUE_NAME, IS_NEW_PLAYER_WAIT_SEC)
	end

	local delaySeconds = EVENT_NOTIFY_DELAY_NORMAL
	if isNewPlayerInstance and isNewPlayerInstance:IsA("BoolValue") and (isNewPlayerInstance :: BoolValue).Value then
		delaySeconds = EVENT_NOTIFY_DELAY_NEW_PLAYER
	end
	_scheduleEventNotification(_firstEventTitle, delaySeconds)
end
