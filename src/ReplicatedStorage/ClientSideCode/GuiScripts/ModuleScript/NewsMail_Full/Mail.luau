--[[
	Module: NewsMail_Full.Mail
	Description: 旧邮件收件箱子面板（列表、领取与删除）。当前未挂载：奖励改由 SystemEmail 入服自动发放。
	Author: 林奥宇
	Created: 2026-07-03
	Last Modified: 2026-08-31

	功能（历史，现已停用）：
	- 动态生成邮件标签，展示正文与奖励
	- 领取/删除/已读经 NetWork → SystemEmail
	- OnDataSync：响应 PlayerData Email 增量同步刷新 UI
	- GM 撰写的 TagTitle/正文为已拼好展示串，走 SetText_UnTrans，不查 Language 表

	通信：
	- NetMsg.EMAIL_CLAIM_AWARD / EMAIL_DELETE / EMAIL_READ
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local AddListen = Utils.AddListen
local UIMgr = Utils.UIMgr
local CfgFind = Utils.CfgFind
local EnumMgr = Utils.EnumMgr
local TimeTransfer = Utils.TimeTransfer
local PlayerData = Utils.PlayerData
local TranslationHelper = Utils.TranslationHelper
local NetMsg = Utils.NetMsg
local NetWork = Utils.NetWork
local TweenService = Utils.TweenService
local LocalPlayer = Utils.LocalPlayer
local Struct = Utils.Struct
local gamepassitemConf = CfgFind.GetCfgByName("gamepassitemConf")

local AllUI = require(script.Parent.AllUI)

-- ========================================
-- 模块定义
-- ========================================
local Mail = {}

-- ========================================
-- 常量定义
-- ========================================
local SAVE_KEY_EMAIL = "Email"
local TAG_MAIL = 2
local COLOR_READ = Color3.fromHex("#999999")
local COLOR_UNREAD = Color3.fromHex("#D8B485")
local SLIDE_TWEEN_SEC = 0.2
local CONTENT_DELIMITER = "|"
local CODE_LOCALIZATION_TAG = "代码本地化"

-- ========================================
-- 私有变量
-- ========================================
local MailPanelTag: ScrollingFrame = AllUI.MailPanelTag
local MailContent: Frame = AllUI.MailContent
local MailScroll: ScrollingFrame = AllUI.MailScroll
local MailContentTitleTemp: Frame = AllUI.MailContentTitleTemp
local MailContentTemp: Frame = AllUI.MailContentTemp
local UI: Frame = AllUI.UIRoot
local ClaimBtn: Frame = AllUI.ClaimBtn
local DeleteBtn: Frame = AllUI.DeleteBtn
local MailAwardList: Frame = AllUI.MailAwardList
local MailAwardTemp: Frame = AllUI.MailAwardTemp
local MailAwardTemp_Title: Frame = AllUI.MailAwardTemp_Title
local CurTag: NumberValue = UI.CurTag
local MailTagTemp: Frame = AllUI.MailTagTemp
local CurMailID: NumberValue = AllUI.MailPanel.CurMailID

MailAwardTemp.Visible = false
MailAwardTemp_Title.Visible = false
MailContentTitleTemp.Visible = false
MailContentTemp.Visible = false
MailTagTemp.Visible = false
CurMailID.Value = 1

local _isPlaySlideAnim = false
local SlideIn: Tween = TweenService:Create(MailContent, TweenInfo.new(SLIDE_TWEEN_SEC), {
	Position = UDim2.new(0, 0, 0.5, 0),
})
SlideIn.Completed:Connect(function()
	MailContent.Visible = true
	_isPlaySlideAnim = false
end)

local SlideOut: Tween = TweenService:Create(MailContent, TweenInfo.new(SLIDE_TWEEN_SEC), {
	Position = UDim2.new(1, 0, 0.5, 0),
})
SlideOut.Completed:Connect(function()
	MailContent.Visible = true
	_isPlaySlideAnim = false
end)

AddListen.AddMouseClick(ClaimBtn.Button, function()
	if CurMailID.Value <= 0 then
		return
	end
	local data: Struct.Email = PlayerData.GetPlrDataByKey(LocalPlayer, { SAVE_KEY_EMAIL, tostring(CurMailID.Value) })
	if not data or data.IsClaim == 1 then
		return
	end
	NetWork.FireServer(NetMsg.EMAIL_CLAIM_AWARD, CurMailID.Value)
end, ClaimBtn.Frame)

AddListen.AddMouseClick(DeleteBtn.Button, function()
	if CurMailID.Value <= 0 then
		return
	end
	local data: Struct.Email = PlayerData.GetPlrDataByKey(LocalPlayer, { SAVE_KEY_EMAIL, tostring(CurMailID.Value) })
	if not data or data.IsClaim ~= 1 then
		return
	end
	NetWork.FireServer(NetMsg.EMAIL_DELETE, CurMailID.Value)
end, DeleteBtn.Frame)

-- ========================================
-- 私有函数
-- ========================================

--[[
	写入不参与查表的展示串，并去掉克隆模板可能残留的代码本地化标签

	@param label TextLabel - 目标文本控件
	@param text string - 已拼好的展示文案
	@return nil - 无返回值
]]
local function _setUntranslatedText(label: TextLabel, text: string)
	if label:HasTag(CODE_LOCALIZATION_TAG) then
		label:RemoveTag(CODE_LOCALIZATION_TAG)
	end
	TranslationHelper.SetText_UnTrans(label, text)
end

--[[
	将分隔符文本拆分为数组

	@param text string - 源文本
	@param delimiter string? - 分隔符，默认 |
	@return {string} - 拆分结果；空串返回 {}
]]
local function _splitTextToArray(text: string, delimiter: string?): { string }
	if typeof(text) ~= "string" or text == "" then
		return {}
	end
	local sep = delimiter or CONTENT_DELIMITER
	local result = {}
	for part in string.gmatch(text, "[^" .. sep .. "]+") do
		table.insert(result, part)
	end
	return result
end

--[[
	刷新领取/删除按钮与奖励已领取标记

	@param data Struct.Email - 当前邮件数据
	@return nil
]]
local function _refreshClaimState(data: Struct.Email)
	if not data then
		return
	end

	if next(data.RewardID) and next(data.RewardCount) then
		MailAwardList.Visible = true
		local isClaimed = data.IsClaim == 1
		ClaimBtn.Visible = not isClaimed
		DeleteBtn.Visible = isClaimed
		for _, v in pairs(MailAwardList:GetChildren()) do
			if tonumber(v.Name) then
				v["已领取"].Visible = isClaimed
			end
		end
	else
		MailAwardList.Visible = true
		ClaimBtn.Visible = false
		DeleteBtn.Visible = true
	end
end

--[[
	刷新邮件奖励列表 UI

	@param data Struct.Email - 当前邮件数据
	@return nil
]]
local function _refreshMailAwards(data: Struct.Email)
	local rewardID, rewardCount = nil, nil
	if data.Ex_Data and data.Ex_Data["IsGift"] == 1 and data.Ex_Data["PassID"] then
		local giftCfg = CfgFind.FindCfgByPassID(data.Ex_Data["PassID"])
		if giftCfg then
			if giftCfg.cost == EnumMgr.RobuxType.RobuxItem then
				rewardID = giftCfg.itemID
				rewardCount = giftCfg.itemCount
			else
				for k, v in pairs(gamepassitemConf) do
					if v.OnlyTag == giftCfg.OnlyTag then
						rewardID = { k }
						rewardCount = { 1 }
						break
					end
				end
			end
		end
	else
		rewardID = data.RewardID
		rewardCount = data.RewardCount
	end

	if not rewardID or not rewardCount or not next(rewardID) or not next(rewardCount) then
		return
	end

	for _, v in pairs(MailAwardList:GetChildren()) do
		if tonumber(v.Name) then
			v:Destroy()
		end
	end

	for k, itemId in pairs(rewardID) do
		local itemCfg = CfgFind.FindCfgByID(itemId)
		local count = tonumber(rewardCount[k])
		if not itemCfg or not count then
			continue
		end

		local temp = if itemCfg.tp == EnumMgr.ItemType.Title then AllUI.MailAwardTemp_Title else AllUI.MailAwardTemp
		local newAward: Frame = temp:Clone()
		newAward.Name = tostring(itemId)
		newAward.LayoutOrder = k
		newAward.Visible = true
		newAward.Parent = MailAwardList

		if itemCfg.tp == EnumMgr.ItemType.Title then
			TranslationHelper.SetText(newAward.TitelStr, itemCfg.ZhName)
			UIMgr.ApplyTitleTextByTitleId(newAward.TitelStr, itemId)
		else
			UIMgr.SetupBagGridSlotFromItem(newAward, {
				count = count,
				id = itemId,
			}, {
				showMaterialCount = true,
				bindViewportHover = false,
			})
		end
	end
end

--[[
	刷新邮件正文与奖励区

	@param data Struct.Email? - 当前邮件；nil 时隐藏内容区
	@return nil
]]
local function _refreshContent(data: Struct.Email?)
	if not data then
		AllUI.MailBtnFrame.Visible = false
		MailContent.Visible = false
		return
	end

	AllUI.MailBtnFrame.Visible = true
	MailContent.Visible = true

	local timeStr = TimeTransfer.FormatUnixTimestampToYMD(data.Time) .. " - "
	_setUntranslatedText(AllUI.MailDataTitle, timeStr .. (data.TagTitle or ""))

	local contentTitleVt = _splitTextToArray(data.ContentTitle)
	local contentVt = _splitTextToArray(data.UpdateText)
	if #contentTitleVt > 0 and #contentVt > 0 then
		MailScroll.Visible = true
		for _, v in pairs(MailScroll:GetChildren()) do
			if tonumber(v.Name) then
				v:Destroy()
			end
		end

		for k, titleText in pairs(contentTitleVt) do
			local content = contentVt[k]
			if not content then
				continue
			end

			local newTitle: Frame = MailContentTitleTemp:Clone()
			newTitle.LayoutOrder = k * 10
			newTitle.Name = tostring(k * 10)
			newTitle.Visible = true
			newTitle.Parent = MailScroll

			local titleLabel: TextLabel = newTitle.Title
			_setUntranslatedText(titleLabel, titleText)
			titleLabel:SetAttribute("OriTextSize", titleLabel.TextSize)

			local newContent: Frame = MailContentTemp:Clone()
			newContent.LayoutOrder = k * 10 + 1
			newContent.Name = tostring(k * 10 + 1)
			newContent.Visible = true
			newContent.Parent = MailScroll

			local contentLabel: TextLabel = newContent.Content
			_setUntranslatedText(contentLabel, content)
			contentLabel:SetAttribute("OriTextSize", contentLabel.TextSize)
		end
	else
		MailScroll.Visible = false
	end

	_refreshMailAwards(data)
	_refreshClaimState(data)
end

--[[
	增量刷新邮件标签列表

	@param mailData table - 存档 Email 表 { [string id]: Struct.Email }
	@return nil
]]
local function _refreshPanel(mailData: { [string]: Struct.Email })
	if not mailData then
		return
	end

	local isRefreshSize = false

	for k, v: Struct.Email in pairs(mailData) do
		local oldTagTemp: Frame = MailPanelTag:FindFirstChild(k)
		if oldTagTemp then
			oldTagTemp:SetAttribute("IsRead", v.IsRead)
			oldTagTemp.Text.TextColor3 = if v.IsRead == 1 then COLOR_READ else COLOR_UNREAD
		else
			isRefreshSize = true
			local newTagTemp: Frame = MailTagTemp:Clone()
			newTagTemp.Name = k
			newTagTemp.Parent = MailPanelTag
			newTagTemp.Visible = true
			newTagTemp.LayoutOrder = -v.Time

			local timeStr = TimeTransfer.FormatUnixTimestampToYMD(v.Time) .. " - "
			_setUntranslatedText(newTagTemp.Text, timeStr .. (v.TagTitle or ""))
			newTagTemp:SetAttribute("IsRead", v.IsRead)
			newTagTemp.Text.TextColor3 = if v.IsRead == 1 then COLOR_READ else COLOR_UNREAD

			AddListen.AddMouseClick(newTagTemp.Button, function()
				if _isPlaySlideAnim then
					return
				end

				local clickID = tonumber(newTagTemp.Name)
				if clickID == CurMailID.Value then
					CurMailID.Value = 0
					_isPlaySlideAnim = true
					SlideOut:Play()
					return
				end

				if CurMailID.Value == 0 then
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
				CurMailID.Value = clickID

				if (newTagTemp:GetAttribute("IsRead") or 0) == 0 then
					NetWork.FireServer(NetMsg.EMAIL_READ, CurMailID.Value)
				end
			end, newTagTemp.Frame)
		end
	end

	if not next(mailData) then
		isRefreshSize = true
	end

	for _, v: Frame in pairs(MailPanelTag:GetChildren()) do
		local index = tonumber(v.Name)
		if index and not mailData[tostring(index)] then
			isRefreshSize = true
			v:Destroy()
		end
	end

	if isRefreshSize then
		UIMgr.SetUIlistSize(MailPanelTag)
	end
end

--[[
	打开 UI 时选中默认邮件（优先未读、否则最新）

	@param emailData table - 存档 Email 表
	@return nil
]]
local function _setDefEmailID(emailData: { [string]: Struct.Email })
	local sortVt = {}
	for k, v: Struct.Email in pairs(emailData) do
		table.insert(sortVt, {
			Time = v.Time,
			IsRead = v.IsRead,
			key = k,
		})
	end
	table.sort(sortVt, function(a0, a1): boolean
		return a0.Time > a1.Time
	end)

	local notReadKey: string? = nil
	for _, v in pairs(sortVt) do
		if v.IsRead ~= 1 then
			notReadKey = v.key
			break
		end
	end

	if notReadKey then
		CurMailID.Value = tonumber(notReadKey) or 0
	elseif sortVt[1] then
		CurMailID.Value = tonumber(sortVt[1].key) or 0
	else
		CurMailID.Value = 0
	end

	local curData = emailData[tostring(CurMailID.Value)]
	if CurTag.Value == TAG_MAIL and curData and curData.IsRead == 0 then
		NetWork.FireServer(NetMsg.EMAIL_READ, CurMailID.Value)
	end
end

AddListen.NumValueAdd(CurMailID, function()
	for _, v: Frame in pairs(AllUI.MailPanelTag:GetChildren()) do
		local mailID = tonumber(v.Name)
		if not mailID then
			continue
		end
		local isSelected = mailID == CurMailID.Value
		v.Frame.Open.Visible = isSelected
		v.Frame.Close.Visible = not isSelected
	end

	local email = PlayerData.GetPlrDataByKey(LocalPlayer, SAVE_KEY_EMAIL)
	local data = if email then email[tostring(CurMailID.Value)] else nil
	_refreshContent(data)
end)

-- ========================================
-- 公共函数
-- ========================================

--[[
	邮件面板打开时初始化列表与默认选中
	@return nil - 无返回值
]]
function Mail.OpenUI()
	local emailData = PlayerData.GetPlrDataByKey(LocalPlayer, SAVE_KEY_EMAIL)
	if not emailData then
		return
	end
	_setDefEmailID(emailData)
	_refreshPanel(emailData)
	local data = emailData[tostring(CurMailID.Value)]
	if data then
		_refreshContent(data)
	end
end

--[[
	切换到邮件 Tab 时标记当前邮件已读
	@return nil
]]
function Mail.OnSwitch()
	local oldTemp: Frame = MailPanelTag:FindFirstChild(tostring(CurMailID.Value))
	if oldTemp and (oldTemp:GetAttribute("IsRead") or 0) == 0 then
		NetWork.FireServer(NetMsg.EMAIL_READ, CurMailID.Value)
	end
end

--[[
	响应 PlayerData Email 增量同步

	@param emailData table - 最新 Email 表 { [string id]: Struct.Email }
	@return nil - 无返回值
]]
function Mail.OnDataSync(emailData: { [string]: Struct.Email }?)
	if not UI.Visible then
		return
	end
	if type(emailData) ~= "table" then
		return
	end
	_refreshPanel(emailData)
	local data = emailData[tostring(CurMailID.Value)]
	_refreshContent(data)
end

return Mail
