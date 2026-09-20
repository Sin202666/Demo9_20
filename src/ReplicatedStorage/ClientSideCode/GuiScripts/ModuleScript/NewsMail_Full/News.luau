--[[
	Module: NewsMail_Full.News
	Description: NewsMail_Full 公告子面板——版本列表与已读状态
	Author: 林奥宇
	Created: 2026-07-03
	Last Modified: 2026-08-31

	功能：
	- 按 updatelogConf 生成版本标签与内容切换
	- 页签/标题走 ZhTagTitle（Language Key）；时间戳走 SetText_UnTrans
	- 已读经 NetWork → SystemUpdateLog
	- OnDataSync：响应 PlayerData UpdateLog 增量同步刷新 UI

	通信：
	- NetMsg.UPDATE_LOG_READ
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local AddListen = Utils.AddListen
local UIMgr = Utils.UIMgr
local TranslationHelper = Utils.TranslationHelper
local CfgFind = Utils.CfgFind
local TimeTransfer = Utils.TimeTransfer
local PlayerData = Utils.PlayerData
local NetMsg = Utils.NetMsg
local NetWork = Utils.NetWork
local TweenService = Utils.TweenService
local LocalPlayer = Utils.LocalPlayer

local AllUI = require(script.Parent.AllUI)

-- ========================================
-- 模块定义
-- ========================================
local News = {}

-- ========================================
-- 常量定义
-- ========================================
local SAVE_KEY_UPDATE_LOG = "UpdateLog"
local COLOR_READ = Color3.fromHex("#999999")
local COLOR_UNREAD = Color3.fromHex("#D8B485")
local SLIDE_TWEEN_SEC = 0.2

-- ========================================
-- 私有变量
-- ========================================
local UI: Frame = AllUI.UIRoot
local UpdateContent: Frame = AllUI.UpdateContent
local UpdatePanelTag: ScrollingFrame = AllUI.UpdatePanelTag
local UpdateTagTemp: Frame = AllUI.UpdateTagTemp
local CurUpdateID: NumberValue = AllUI.UpdatePanel.CurUpdateID

local updatelogConf = CfgFind.GetCfgByName("updatelogConf")
CurUpdateID.Value = #updatelogConf
UpdateTagTemp.Visible = false

local _isPlaySlideAnim = false
local SlideIn: Tween = TweenService:Create(UpdateContent, TweenInfo.new(SLIDE_TWEEN_SEC), {
	Position = UDim2.new(0, 0, 0.5, 0),
})
SlideIn.Completed:Connect(function()
	UpdateContent.Visible = true
	_isPlaySlideAnim = false
end)

local SlideOut: Tween = TweenService:Create(UpdateContent, TweenInfo.new(SLIDE_TWEEN_SEC), {
	Position = UDim2.new(1, 0, 0.5, 0),
})
SlideOut.Completed:Connect(function()
	UpdateContent.Visible = true
	_isPlaySlideAnim = false
end)

-- ========================================
-- 私有函数
-- ========================================

--[[
	刷新公告标签已读颜色与 IsRead 属性

	@param logData table? - UpdateLog 存档 { [string id]: { IsRead: number } }
	@return nil - 无返回值
]]
local function _refreshReadState(logData: { [string]: { IsRead: number } }?)
	if not logData then
		return
	end

	for _, v: Frame in pairs(UpdatePanelTag:GetChildren()) do
		local data = logData[v.Name]
		if not data then
			continue
		end
		v:SetAttribute("IsRead", data.IsRead)
		v.Time.TextColor3 = if data.IsRead == 1 then COLOR_READ else COLOR_UNREAD
	end
end

--[[
	打开 UI 时选中默认公告（优先未读、否则最新）

	@return nil - 无返回值
]]
local function _setDefUpdateID()
	local sortVt = {}
	for _, v: Frame in pairs(UpdatePanelTag:GetChildren()) do
		local index = tonumber(v.Name)
		if not index then
			continue
		end
		table.insert(sortVt, {
			Time = v:GetAttribute("UpdateTime"),
			IsRead = v:GetAttribute("IsRead"),
			key = index,
		})
	end
	table.sort(sortVt, function(a0, a1): boolean
		return a0.Time > a1.Time
	end)

	local notReadKey: number? = nil
	for _, v in pairs(sortVt) do
		if v.IsRead ~= 1 then
			notReadKey = v.key
			break
		end
	end

	if notReadKey then
		CurUpdateID.Value = notReadKey
	elseif sortVt[1] then
		CurUpdateID.Value = sortVt[1].key
	else
		CurUpdateID.Value = 0
	end
end

-- ========================================
-- 模块初始化（生成版本标签）
-- ========================================

for k, v in pairs(updatelogConf) do
	local newTemp: Frame = UpdateTagTemp:Clone()
	newTemp.Visible = true
	newTemp.Parent = UpdatePanelTag
	newTemp.Name = tostring(k)
	newTemp.LayoutOrder = -v.UpdateTime

	local timeStr = TimeTransfer.FormatUnixTimestampToYMD(v.UpdateTime)
	TranslationHelper.SetText_UnTrans(newTemp.Time, timeStr)
	TranslationHelper.SetText(newTemp.Title, v.ZhTagTitle)
	newTemp:SetAttribute("UpdateTime", v.UpdateTime)

	AddListen.AddMouseClick(newTemp.Button, function()
		if _isPlaySlideAnim then
			return
		end

		local clickID = tonumber(newTemp.Name)
		if clickID == CurUpdateID.Value then
			CurUpdateID.Value = 0
			_isPlaySlideAnim = true
			SlideOut:Play()
			return
		end

		if CurUpdateID.Value == 0 then
			_isPlaySlideAnim = true
			SlideIn:Play()
		else
			_isPlaySlideAnim = true
			SlideOut:Play()
			SlideOut.Completed:Wait()
			if not UI.Visible then
				_isPlaySlideAnim = false
				return
			end
			SlideIn:Play()
		end

		CurUpdateID.Value = clickID

		if (newTemp:GetAttribute("IsRead") or 0) == 0 then
			NetWork.FireServer(NetMsg.UPDATE_LOG_READ, CurUpdateID.Value)
		end
	end, newTemp.Frame)
end
UIMgr.SetUIlistSize(UpdatePanelTag)

AddListen.NumValueAdd(CurUpdateID, function(value)
	if value == 0 then
		return
	end

	UpdateContent.Visible = true

	for _, v: Frame in pairs(UpdatePanelTag:GetChildren()) do
		local updateID = tonumber(v.Name)
		if not updateID then
			continue
		end
		local isSelected = updateID == CurUpdateID.Value
		for _, child: Frame in pairs(v.Frame:GetChildren()) do
			if child.Name == "Open" then
				child.Visible = isSelected
			elseif child.Name == "Close" then
				child.Visible = not isSelected
			end
		end
	end

	for _, v: Frame in pairs(AllUI.UpdateContent:GetChildren()) do
		local updateID = tonumber(v.Name)
		if not updateID then
			continue
		end
		v.Visible = updateID == CurUpdateID.Value
	end

	local updateCfg = updatelogConf[CurUpdateID.Value]
	if updateCfg then
		local timeStr = TimeTransfer.FormatUnixTimestampToYMD(updateCfg.UpdateTime) .. " - "
		TranslationHelper.SetText(AllUI.UpdateCfgTitle, "{1}{2}", { timeStr, { updateCfg.ZhTagTitle } })
	end
end)

-- ========================================
-- 公共函数
-- ========================================

--[[
	公告面板打开时刷新已读并选中默认项
	@return nil - 无返回值
]]
function News.OpenUI()
	local data = PlayerData.GetPlrDataByKey(LocalPlayer, SAVE_KEY_UPDATE_LOG)
	_refreshReadState(data)
	_setDefUpdateID()
end

--[[
	切换到公告 Tab 时标记当前公告已读
	@return nil - 无返回值
]]
function News.OnSwitch()
	local oldTemp: Frame = UpdatePanelTag:FindFirstChild(tostring(CurUpdateID.Value))
	if oldTemp and (oldTemp:GetAttribute("IsRead") or 0) == 0 then
		NetWork.FireServer(NetMsg.UPDATE_LOG_READ, CurUpdateID.Value)
	end
end

--[[
	响应 PlayerData UpdateLog 增量同步

	@param logData table - 最新 UpdateLog 表 { [string id]: { IsRead: number } }
	@return nil - 无返回值
]]
function News.OnDataSync(logData: { [string]: { IsRead: number } }?)
	if not UI.Visible then
		return
	end
	if type(logData) ~= "table" then
		return
	end
	_refreshReadState(logData)
end

return News
