--[[
	Module: GMEmail
	Description: GM 发邮件面板（选配奖励、InvokeServer DEBUG_EMAIL）；由 GMEmail.client 懒加载
	Author: 林奥宇
	Created: 2026-08-18
	Last Modified: 2026-08-31

	功能：
	- create()：构建面板，返回 Show/Hide
	- 页签 Item / GamePass，选配后发送；奖励一律入包（含 GamePass 配置 ID）
	- 不采集、不发送药水 purity / mpTp
	- 无 RewardUITemp 资源时用程序化格子兜底
	- 在线发放未完成时提示 QueuedGrantFailed；同步标记回滚失败时提示 SyncRevertFailed，均不显示「发送完成」

	与门禁脚本关系：
	- StarterPlayerScripts/ClientScript/GMEmail.client.luau 负责白名单早退与 /gmemail
	- 本模块仅在白名单玩家首次打开面板时 require

	加载方式：
		local GMEmail = require(game.ReplicatedStorage.ClientSideCode.GuiScripts.ModuleScript.GMEmail)
		local panel = GMEmail.create()
		panel.Show()
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Players = Utils.Players
local CfgFind = Utils.CfgFind
local EnumMgr = Utils.EnumMgr
local NetMsg = Utils.NetMsg
local NetWork = Utils.NetWork
local ReplicatedStorage = Utils.ReplicatedStorage

local GmEmailWidgets = require(script.GmEmailWidgets)
local GmEmailRewardSlots = require(script.GmEmailRewardSlots)

local LocalPlayer = Players.LocalPlayer

-- ========================================
-- 模块定义
-- ========================================
local GMEmail = {}

export type GmMailPanelHandle = {
	Show: () -> (),
	Hide: () -> (),
}

type PanelLayout = {
	mainFrame: Frame,
	userIdBox: TextBox,
	tagTitleBox: TextBox,
	contentTitleBox: TextBox,
	mailDescBox: TextBox,
	tabFrame: ScrollingFrame,
	itemScrollHolder: Frame,
	selectedRewardScroll: ScrollingFrame,
	selectedLayout: UIGridLayout,
	itemIdBox: TextBox,
	countBox: TextBox,
	statusLabel: TextLabel,
	currentPreview: GuiObject,
	rewardTemplate: GuiObject,
	addButton: TextButton,
	removeButton: TextButton,
	clearButton: TextButton,
	sendButton: TextButton,
}

type SendFlow = {
	setStatus: (string, boolean?) -> (),
	setCurrentSelectId: (number) -> (),
	updatePreview: () -> (),
	refreshSelected: () -> (),
}

-- ========================================
-- 常量定义
-- ========================================
local GM_MAIL_TAB_CONFIG_MAP = {
	{ tabName = "Item", cfgName = "itemdataConf" },
	{ tabName = "GamePass", cfgName = "gamepassitemConf" },
}

-- ========================================
-- 私有函数
-- ========================================

--[[
	拷贝数字数组，避免把可变内部表发给服务端

	@param source {number} - 源数组
	@return {number} - 浅拷贝
]]
local function _cloneNumberArray(source: { number }): { number }
	local result: { number } = {}
	for index, value in ipairs(source) do
		result[index] = value
	end
	return result
end

--[[
	解析奖励格模板（优先 Assets.UI.RewardUITemp）

	@return GuiObject - 可 Clone 的格子模板
]]
local function _resolveRewardSlotTemplate(): GuiObject
	local assetsFolder = ReplicatedStorage:FindFirstChild("Assets")
	local assetsUi = if assetsFolder then assetsFolder:FindFirstChild("UI") else nil
	local template = if assetsUi then assetsUi:FindFirstChild("RewardUITemp") else nil
	if template and template:IsA("GuiObject") then
		return template
	end
	return GmEmailWidgets.createRewardSlotTemplate()
end

--[[
	构建面板静态布局（输入框、滚动区、按钮），不含页签数据与发送逻辑

	@param playerGui PlayerGui - 本地玩家 PlayerGui
	@param rewardTemplate GuiObject - 奖励格模板
	@return PanelLayout - 布局引用
]]
local function _buildLayout(playerGui: Instance, rewardTemplate: GuiObject): PanelLayout
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "GMEmailPanel"
	screenGui.ResetOnSpawn = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.DisplayOrder = 1002
	screenGui.Parent = playerGui

	local mainFrame = Instance.new("Frame")
	mainFrame.Name = "Main"
	mainFrame.Size = UDim2.new(0, 1280, 0, 860)
	mainFrame.Position = UDim2.new(1, -1320, 0, 110)
	mainFrame.BackgroundColor3 = Color3.fromRGB(28, 28, 32)
	mainFrame.BorderSizePixel = 0
	mainFrame.Visible = false
	mainFrame.Parent = screenGui
	GmEmailWidgets.createCorner(mainFrame, 10)
	GmEmailWidgets.createStroke(mainFrame, Color3.fromRGB(78, 78, 86))

	GmEmailWidgets.createLabel(mainFrame, "GM发送邮件", UDim2.new(0, 18, 0, 10), UDim2.new(0, 220, 0, 34), 30, true)

	local closeButton = GmEmailWidgets.createButton(
		mainFrame,
		"×",
		UDim2.new(1, -50, 0, 10),
		UDim2.new(0, 36, 0, 36),
		Color3.fromRGB(190, 60, 60),
		24
	)
	closeButton.MouseButton1Click:Connect(function()
		mainFrame.Visible = false
	end)

	GmEmailWidgets.createLabel(mainFrame, "玩家ID", UDim2.new(0, 20, 0, 58), UDim2.new(0, 90, 0, 28), 18, true)
	local userIdBox = GmEmailWidgets.createTextBox(mainFrame, "输入玩家UserId", UDim2.new(0, 100, 0, 56), UDim2.new(0, 180, 0, 34), 18, false)
	local tagTitleBox = GmEmailWidgets.createTextBox(mainFrame, "邮件标签", UDim2.new(0, 300, 0, 56), UDim2.new(0, 280, 0, 34), 18, false)

	local currentPreview = rewardTemplate:Clone()
	currentPreview.Name = "CurrentPreview"
	currentPreview.Parent = mainFrame
	currentPreview.Position = UDim2.new(0, 1050, 0, 90)
	currentPreview.Size = UDim2.new(0, 130, 0, 130)
	currentPreview.Visible = false

	local contentTitleBox = GmEmailWidgets.createTextBox(
		mainFrame,
		"邮件内显示的小标题，多个用|分隔",
		UDim2.new(0, 20, 0, 100),
		UDim2.new(0, 600, 0, 34),
		18,
		false
	)
	local mailDescBox = GmEmailWidgets.createTextBox(
		mainFrame,
		"邮件正文内容，多个段落用|分隔",
		UDim2.new(0, 20, 0, 142),
		UDim2.new(0, 880, 0, 56),
		18,
		true
	)

	local tabFrame = GmEmailWidgets.createScrollFrame(mainFrame, UDim2.new(0, 16, 0, 246), UDim2.new(0, 110, 0, 388))
	local tabLayout = Instance.new("UIListLayout")
	tabLayout.Padding = UDim.new(0, 8)
	tabLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	tabLayout.SortOrder = Enum.SortOrder.LayoutOrder
	tabLayout.Parent = tabFrame
	GmEmailWidgets.bindCanvasSize(tabFrame, tabLayout, 20)

	local itemScrollHolder = Instance.new("Frame")
	itemScrollHolder.Position = UDim2.new(0, 140, 0, 246)
	itemScrollHolder.Size = UDim2.new(0, 760, 0, 388)
	itemScrollHolder.BackgroundColor3 = Color3.fromRGB(34, 34, 38)
	itemScrollHolder.BorderSizePixel = 0
	itemScrollHolder.Parent = mainFrame
	GmEmailWidgets.createCorner(itemScrollHolder, 8)
	GmEmailWidgets.createStroke(itemScrollHolder)

	local selectedRewardScroll = GmEmailWidgets.createScrollFrame(mainFrame, UDim2.new(0, 920, 0, 242), UDim2.new(0, 330, 0, 464))
	local selectedLayout = Instance.new("UIGridLayout")
	selectedLayout.CellSize = UDim2.new(0, 150, 0, 150)
	selectedLayout.CellPadding = UDim2.new(0, 8, 0, 8)
	selectedLayout.SortOrder = Enum.SortOrder.LayoutOrder
	selectedLayout.Parent = selectedRewardScroll
	GmEmailWidgets.bindCanvasSize(selectedRewardScroll, selectedLayout, 24)

	GmEmailWidgets.createLabel(mainFrame, "道具ID", UDim2.new(0, 20, 0, 642), UDim2.new(0, 80, 0, 24), 18, true)
	local itemIdBox = GmEmailWidgets.createTextBox(mainFrame, "选择或输入奖励ID", UDim2.new(0, 92, 0, 638), UDim2.new(0, 160, 0, 34), 18, false)
	GmEmailWidgets.createLabel(mainFrame, "数量", UDim2.new(0, 270, 0, 642), UDim2.new(0, 60, 0, 24), 18, true)
	local countBox = GmEmailWidgets.createTextBox(mainFrame, "数量", UDim2.new(0, 320, 0, 638), UDim2.new(0, 120, 0, 34), 18, false)
	countBox.Text = "1"

	local statusLabel = GmEmailWidgets.createLabel(mainFrame, "", UDim2.new(0, 20, 0, 804), UDim2.new(1, -40, 0, 36), 28, true)
	statusLabel.TextWrapped = true

	local addButton = GmEmailWidgets.createButton(mainFrame, "加", UDim2.new(0, 460, 0, 636), UDim2.new(0, 80, 0, 40), Color3.fromRGB(50, 150, 80), 20)
	local removeButton = GmEmailWidgets.createButton(mainFrame, "减", UDim2.new(0, 552, 0, 636), UDim2.new(0, 80, 0, 40), Color3.fromRGB(180, 80, 80), 20)
	local clearButton = GmEmailWidgets.createButton(mainFrame, "清空奖励", UDim2.new(0, 648, 0, 636), UDim2.new(0, 120, 0, 40), Color3.fromRGB(110, 110, 110), 20)
	local sendButton = GmEmailWidgets.createButton(mainFrame, "发送邮件", UDim2.new(0, 920, 0, 732), UDim2.new(0, 330, 0, 44), Color3.fromRGB(60, 120, 185), 22)

	return {
		mainFrame = mainFrame,
		userIdBox = userIdBox,
		tagTitleBox = tagTitleBox,
		contentTitleBox = contentTitleBox,
		mailDescBox = mailDescBox,
		tabFrame = tabFrame,
		itemScrollHolder = itemScrollHolder,
		selectedRewardScroll = selectedRewardScroll,
		selectedLayout = selectedLayout,
		itemIdBox = itemIdBox,
		countBox = countBox,
		statusLabel = statusLabel,
		currentPreview = currentPreview,
		rewardTemplate = rewardTemplate,
		addButton = addButton,
		removeButton = removeButton,
		clearButton = clearButton,
		sendButton = sendButton,
	}
end

--[[
	绑定选奖列表与发送按钮

	@param layout PanelLayout - 布局引用
	@return SendFlow - 供页签回调用的选中/状态接口
]]
local function _bindSendFlow(layout: PanelLayout): SendFlow
	local rewardIdList: { number } = {}
	local rewardCountList: { number } = {}
	local currentSelectId = 0
	local isSending = false
	local sendButtonNormalColor = layout.sendButton.BackgroundColor3

	local function setStatus(text: string, isError: boolean?)
		layout.statusLabel.Text = tostring(text or "")
		layout.statusLabel.TextColor3 = if isError
			then Color3.fromRGB(240, 120, 120)
			else Color3.fromRGB(200, 200, 200)
	end

	local function updatePreview()
		local previewId = tonumber(layout.itemIdBox.Text) or currentSelectId
		if not previewId or previewId <= 0 then
			layout.currentPreview.Visible = false
			return
		end
		layout.currentPreview.Visible = true
		GmEmailRewardSlots.setupRewardSlot(layout.currentPreview :: Frame, previewId, 1)
	end

	local function findRewardIndex(itemId: number): number?
		for index, rewardId in ipairs(rewardIdList) do
			if rewardId == itemId then
				return index
			end
		end
		return nil
	end

	local function setCurrentSelectId(itemId: number)
		currentSelectId = tonumber(itemId) or 0
		if currentSelectId > 0 then
			layout.itemIdBox.Text = tostring(currentSelectId)
		end
		updatePreview()
	end

	local function refreshSelected()
		for _, child in layout.selectedRewardScroll:GetChildren() do
			if child:IsA("GuiObject") and child ~= layout.selectedLayout then
				child:Destroy()
			end
		end

		for index, rewardId in ipairs(rewardIdList) do
			local rewardCount = rewardCountList[index] or 0
			local rewardItem = layout.rewardTemplate:Clone()
			rewardItem.Name = "Reward_" .. tostring(rewardId)
			rewardItem.LayoutOrder = index
			rewardItem.Size = UDim2.new(0, 150, 0, 150)
			rewardItem.Parent = layout.selectedRewardScroll
			GmEmailRewardSlots.setupRewardSlot(rewardItem :: Frame, rewardId, rewardCount)

			local clickMask = Instance.new("TextButton")
			clickMask.Size = UDim2.new(1, 0, 1, 0)
			clickMask.BackgroundTransparency = 1
			clickMask.Text = ""
			clickMask.Parent = rewardItem
			clickMask.MouseButton1Click:Connect(function()
				setCurrentSelectId(rewardId)
			end)
		end

		if #rewardIdList == 0 then
			setStatus("奖励列表为空")
		else
			setStatus("奖励列表已更新")
		end
	end

	local function changeRewardCount(delta: number)
		local itemId = tonumber(layout.itemIdBox.Text) or currentSelectId
		local count = tonumber(layout.countBox.Text)
		if not itemId or itemId <= 0 then
			setStatus("道具ID无效", true)
			return
		end
		if not count or count <= 0 then
			setStatus("数量无效", true)
			return
		end

		local rewardIndex = findRewardIndex(itemId)
		if delta > 0 then
			if rewardIndex then
				rewardCountList[rewardIndex] += count
			else
				table.insert(rewardIdList, itemId)
				table.insert(rewardCountList, count)
			end
		else
			if not rewardIndex then
				setStatus("奖励列表中没有该ID", true)
				return
			end
			rewardCountList[rewardIndex] -= count
			if rewardCountList[rewardIndex] <= 0 then
				table.remove(rewardIdList, rewardIndex)
				table.remove(rewardCountList, rewardIndex)
			end
		end

		setCurrentSelectId(itemId)
		refreshSelected()
	end

	local function restoreSendButton()
		isSending = false
		layout.sendButton.Active = true
		layout.sendButton.AutoButtonColor = true
		layout.sendButton.BackgroundColor3 = sendButtonNormalColor
	end

	layout.itemIdBox:GetPropertyChangedSignal("Text"):Connect(updatePreview)
	layout.addButton.MouseButton1Click:Connect(function()
		changeRewardCount(1)
	end)
	layout.removeButton.MouseButton1Click:Connect(function()
		changeRewardCount(-1)
	end)
	layout.clearButton.MouseButton1Click:Connect(function()
		table.clear(rewardIdList)
		table.clear(rewardCountList)
		refreshSelected()
	end)

	layout.sendButton.MouseButton1Click:Connect(function()
		if isSending then
			return
		end
		isSending = true
		layout.sendButton.Active = false
		layout.sendButton.AutoButtonColor = false
		layout.sendButton.BackgroundColor3 = Color3.fromRGB(70, 70, 78)

		local userId = tonumber(layout.userIdBox.Text)
		if not userId then
			setStatus("玩家ID无效", true)
			restoreSendButton()
			return
		end
		if #rewardIdList == 0 then
			setStatus("请先添加至少一个奖励", true)
			restoreSendButton()
			return
		end

		local emailData = {
			UserID = userId,
			RewardID = _cloneNumberArray(rewardIdList),
			RewardCount = _cloneNumberArray(rewardCountList),
			Ex_Data = {},
			TagTitle = tostring(layout.tagTitleBox.Text or ""),
			ContentTitle = tostring(layout.contentTitleBox.Text or ""),
			UpdateText = tostring(layout.mailDescBox.Text or ""),
		}

		setStatus("发送中...")
		layout.statusLabel.TextColor3 = Color3.fromRGB(255, 215, 120)

		local invokeOk, sendOk, errMsg = pcall(function()
			return NetWork.InvokeServer(NetMsg.DEBUG_EMAIL, EnumMgr.GmEmailOp.Send, emailData)
		end)
		if not invokeOk then
			setStatus(tostring(sendOk), true)
		elseif sendOk == true then
			setStatus("发送完成")
			layout.statusLabel.TextColor3 = Color3.fromRGB(120, 220, 150)
		elseif sendOk == EnumMgr.GmEmailErr.QueuedGrantFailed then
			setStatus("邮件已写入，但在线发放失败，目标重进后到账", true)
		elseif sendOk == EnumMgr.GmEmailErr.SyncRevertFailed then
			setStatus("邮件已写入，但同步标记回滚失败，不会自动补发", true)
		else
			setStatus(tostring(errMsg or sendOk or "发送失败"), true)
		end

		restoreSendButton()
	end)

	return {
		setStatus = setStatus,
		setCurrentSelectId = setCurrentSelectId,
		updatePreview = updatePreview,
		refreshSelected = refreshSelected,
	}
end

--[[
	填充 Item / GamePass 页签并绑定切换

	@param layout PanelLayout - 布局引用
	@param flow SendFlow - 选中与状态回调
	@return nil
]]
local function _fillRewardTabs(layout: PanelLayout, flow: SendFlow)
	local itemScrollMap: { [string]: ScrollingFrame } = {}
	local tabButtonMap: { [string]: TextButton } = {}

	local function setActiveTab(tabName: string)
		for currentTabName, scroll in itemScrollMap do
			scroll.Visible = currentTabName == tabName
		end
		for currentTabName, button in tabButtonMap do
			button.BackgroundColor3 = if currentTabName == tabName
				then Color3.fromRGB(60, 120, 185)
				else Color3.fromRGB(66, 66, 72)
		end
	end

	for index, tabEntry in ipairs(GM_MAIL_TAB_CONFIG_MAP) do
		local tabName = tabEntry.tabName
		local cfgName = tabEntry.cfgName
		local tabButton = GmEmailWidgets.createButton(layout.tabFrame, tabName, UDim2.new(), UDim2.new(1, 0, 0, 40), Color3.fromRGB(66, 66, 72), 18)
		tabButton.TextScaled = true
		tabButton.LayoutOrder = index
		tabButtonMap[tabName] = tabButton

		local itemScroll = GmEmailWidgets.createScrollFrame(layout.itemScrollHolder, UDim2.new(0, 10, 0, 10), UDim2.new(1, -20, 1, -20))
		itemScroll.Visible = false
		itemScrollMap[tabName] = itemScroll

		local gridLayout = Instance.new("UIGridLayout")
		gridLayout.CellSize = UDim2.new(0, 150, 0, 150)
		gridLayout.CellPadding = UDim2.new(0, 10, 0, 10)
		gridLayout.SortOrder = Enum.SortOrder.LayoutOrder
		gridLayout.Parent = itemScroll
		GmEmailWidgets.bindCanvasSize(itemScroll, gridLayout, 12)

		local cfgTable = cfgName and CfgFind.GetCfgByName(cfgName) or nil
		local cfgIds: { number } = {}
		if typeof(cfgTable) == "table" then
			for itemId in pairs(cfgTable) do
				if typeof(itemId) == "number" then
					table.insert(cfgIds, itemId)
				end
			end
		end
		table.sort(cfgIds, function(a, b)
			if tabName == "Item" then
				return a < b
			end
			return a > b
		end)

		for _, itemId in ipairs(cfgIds) do
			local rewardItem = layout.rewardTemplate:Clone()
			rewardItem.Name = tabName .. "_" .. tostring(itemId)
			rewardItem.LayoutOrder = itemId
			rewardItem.Parent = itemScroll
			GmEmailRewardSlots.setupRewardSlot(rewardItem :: Frame, itemId, 1)

			local clickMask = Instance.new("TextButton")
			clickMask.Size = UDim2.new(1, 0, 1, 0)
			clickMask.BackgroundTransparency = 1
			clickMask.Text = ""
			clickMask.Parent = rewardItem
			clickMask.MouseButton1Click:Connect(function()
				flow.setCurrentSelectId(itemId)
			end)
		end

		tabButton.MouseButton1Click:Connect(function()
			setActiveTab(tabName)
			if #cfgIds == 0 then
				flow.setStatus(tabName .. " 页签没有找到可用配置", true)
			else
				flow.setStatus("当前页签：" .. tabName)
			end
		end)
	end

	local firstTab = GM_MAIL_TAB_CONFIG_MAP[1]
	if firstTab then
		setActiveTab(firstTab.tabName)
		flow.setStatus("当前页签：" .. firstTab.tabName)
	end
end

-- ========================================
-- 公共函数
-- ========================================

--[[
	构建 GM 发邮件面板并返回显隐句柄

	@return GmMailPanelHandle - Show/Hide
]]
function GMEmail.create(): GmMailPanelHandle
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")
	local layout = _buildLayout(playerGui, _resolveRewardSlotTemplate())
	local flow = _bindSendFlow(layout)
	_fillRewardTabs(layout, flow)
	flow.updatePreview()
	flow.refreshSelected()
	return {
		Show = function()
			layout.mainFrame.Visible = true
		end,
		Hide = function()
			layout.mainFrame.Visible = false
		end,
	}
end

return GMEmail
