--[[
	Module: OnlineAward
	Description: 在线奖励弹窗——按 onlineawardConf 克隆 Temp；ClaimAll 付费解锁未达标档
	Author: 林奥宇
	Created: 2026-09-04
	Last Modified: 2026-09-04

	功能：
	- Temp 与签到小格一致（无 Day）：ClaimBtn.Btn 领取；可领 Bg / 未达时长 UnBg 倒计时；已领隐藏 ClaimBtn
	- Count：按配置数量展示（无重生倍率）
	- ClaimAll：OnlyTag=OnlineAwardClaimAll；购买后本轮未达标未领档写 Unlock，变为可领；已领不变；仍逐个点领
	- 本轮全领完由服务端重置，客户端随 OnlineBox 同步刷新
	- 领取：InvokeServer(CLAIM_ONLINE_AWARD, tierId)
	- 进度仅本会话：离服清空，未领作废；文案「在线奖励提示」与此一致

	模块关系：
	- 展示与发 Remote；结算权威在 SystemOnlineAward
	- 由 UIManager 按 Frame.Name 动态 require；关窗走 SHOW_LOCAL_UI false
	- 顶栏入口 TopBarManager

	约定：
	- ScreenGui.OnlineAward；节点见 AllUI
	- 存档键 OnlineBox（会话内同步用）：OnlineSeconds / [tierId]={ State=1已领 | Unlock=1付费可领 }

	加载（UIManager 动态 require）：
		local OnlineAward = require(...ModuleScript.OnlineAward)
		OnlineAward:updateUi()
		OnlineAward:openUi()
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local AddListen = Utils.AddListen
local CfgFind = Utils.CfgFind
local Log = Utils.Log
local MathMgr = Utils.MathMgr
local NetMsg = Utils.NetMsg
local NetWork = Utils.NetWork
local PlayerData = Utils.PlayerData
local SystemBuyRoblox = Utils.SystemBuyRoblox
local TimeTransfer = Utils.TimeTransfer
local TranslationHelper = Utils.TranslationHelper
local UIMgr = Utils.UIMgr
local LocalPlayer = Utils.LocalPlayer

local AllUI = require(script.AllUI)

-- ========================================
-- 模块定义
-- ========================================
local OnlineAward = {}

-- ========================================
-- 常量定义
-- ========================================
local SAVE_KEY_ONLINE = "OnlineBox"
local CLAIM_ALL_ONLY_TAG = "OnlineAwardClaimAll"
local UI_NAME = "OnlineAward"
local ASSET_ID_PREFIX = "rbxassetid://"
local TEMPLATE_SLOT_NAME = "_Temp"
local CHILD_ICON = "Icon"
local CHILD_VIEWPORT = "ViewportFrame"
local CHILD_NAME = "Name"
local CHILD_COUNT = "Count"
local CHILD_CAN_CLAIM = "可领取"
local CHILD_HAS_CLAIMED = "已领取"
local CHILD_BTNS = "Btns"
local CHILD_CLAIM_BTN = "ClaimBtn"
local CHILD_BTN = "Btn"
local CHILD_BG = "Bg"
local CHILD_UN_BG = "UnBg"
local CHILD_UN_BG_TEXT = "Text"
local CHILD_EXIT_BTN = "Btn"
local CHILD_EXIT_SCALE = "Frame"
local CHILD_PRICE = "Price"
local CHILD_PRICE_NUM = "PriceNum"

-- ========================================
-- 私有变量
-- ========================================
local UI: Frame = AllUI.UIRoot
local OnlineScroll: ScrollingFrame = AllUI.OnlineScroll
local Temp: TextButton = AllUI.Temp
local ClaimAllFrame: Frame = AllUI.ClaimAll
local ExitFrame: Frame = AllUI.Exit

local _built = false
local _claiming = false
local _listening = false
local _countdownToken = 0
local _anchorSec = 0
local _anchorClock = 0
local _connections: { RBXScriptConnection } = {}

Temp.Visible = false

-- ========================================
-- 私有函数
-- ========================================

--[[
	记录需在 destroy 时断开的连接
	@param conn RBXScriptConnection? - 单条连接
	@return nil
]]
local function _trackConnection(conn: RBXScriptConnection?)
	if conn then
		table.insert(_connections, conn)
	end
end

--[[
	记录 AddMouseClick 返回的连接表
	@param conns {RBXScriptConnection}? - 点击连接数组
	@return nil
]]
local function _trackConnections(conns: { RBXScriptConnection }?)
	if not conns then
		return
	end
	for _, conn in conns do
		_trackConnection(conn)
	end
end

--[[
	格子本体是 TextButton：禁止整格点击，只走内层 ClaimBtn.Btn
	@param slot GuiObject - Temp / 克隆
	@return nil
]]
local function _disableSlotButton(slot: GuiObject)
	if slot:IsA("GuiButton") then
		slot.Active = false
		slot.AutoButtonColor = false
	end
end

--[[
	按配置路径拼 rbxassetid
	@param iconId number | string - 配置表 Icon
	@return string - rbxassetid:// 完整串
]]
local function _toAssetUri(iconId: number | string): string
	return ASSET_ID_PREFIX .. tostring(iconId)
end

--[[
	取格子直接子 GuiObject
	@param slot GuiObject - Temp 克隆
	@param childName string - 子节点名
	@return GuiObject? - 子节点
]]
local function _child(slot: GuiObject, childName: string): GuiObject?
	local node = slot:FindFirstChild(childName)
	if node and node:IsA("GuiObject") then
		return node
	end
	return nil
end

--[[
	取 ClaimBtn 容器（Btns.ClaimBtn）
	@param slot GuiObject - 格子
	@return Frame? - ClaimBtn
]]
local function _getClaimBtnRoot(slot: GuiObject): Frame?
	local btns = slot:FindFirstChild(CHILD_BTNS)
	if not btns then
		return nil
	end
	local claimBtn = btns:FindFirstChild(CHILD_CLAIM_BTN)
	if claimBtn and claimBtn:IsA("Frame") then
		return claimBtn
	end
	return nil
end

--[[
	取可点击领取按钮 Btns.ClaimBtn.Btn
	@param slot GuiObject - 格子
	@return GuiButton? - ImageButton / TextButton
]]
local function _getClaimClickBtn(slot: GuiObject): GuiButton?
	local claimRoot = _getClaimBtnRoot(slot)
	if not claimRoot then
		return nil
	end
	local btn = claimRoot:FindFirstChild(CHILD_BTN)
	if btn and btn:IsA("GuiButton") then
		return btn
	end
	return nil
end

--[[
	在 Frame 内找第一个 GuiButton（Exit / ClaimAll）
	@param frame GuiObject - 容器
	@return GuiButton?
]]
local function _findButtonInFrame(frame: GuiObject): GuiButton?
	local named = frame:FindFirstChild(CHILD_BTN)
	if named and named:IsA("GuiButton") then
		return named
	end
	if frame:IsA("GuiButton") then
		return frame
	end
	for _, desc in frame:GetDescendants() do
		if desc:IsA("GuiButton") then
			return desc
		end
	end
	return nil
end

--[[
	按上次同步锚点推算当前在线秒（仅展示，领取仍以服为准）
	@param onlineData table? - OnlineBox
	@return number - 估算秒数
]]
local function _estimateOnlineSeconds(onlineData: { [any]: any }?): number
	local synced = tonumber(onlineData and onlineData.OnlineSeconds) or 0
	if _anchorClock <= 0 then
		return synced
	end
	return _anchorSec + math.max(0, os.clock() - _anchorClock)
end

--[[
	用存档刷新本地秒数锚点
	@param onlineData table? - OnlineBox
	@return nil
]]
local function _refreshTimeAnchor(onlineData: { [any]: any }?)
	_anchorSec = tonumber(onlineData and onlineData.OnlineSeconds) or 0
	_anchorClock = os.clock()
end

--[[
	构造带本地推算秒数的 OnlineBox 视图（供可领判定；不改存档引用）
	@param onlineData table? - OnlineBox
	@return table - 含估算 OnlineSeconds 的浅表
]]
local function _onlineView(onlineData: { [any]: any }?): { [any]: any }
	local view: { [any]: any } = {}
	if type(onlineData) == "table" then
		for k, v in pairs(onlineData) do
			view[k] = v
		end
	end
	view.OnlineSeconds = _estimateOnlineSeconds(onlineData)
	return view
end

--[[
	是否仍有「未达时长、未 Unlock、未领」的档（ClaimAll 展示用）
	@param onlineData table? - OnlineBox
	@return boolean - 仍有待付费解锁档为 true
]]
local function _hasLockedUnclaimed(onlineData: { [any]: any }?): boolean
	local seconds = _estimateOnlineSeconds(onlineData)
	local list = CfgFind.GetOnlineAwardList()
	for _, cfg in ipairs(list) do
		local tierId = tonumber(cfg.id) or 0
		if tierId > 0 and not CfgFind.IsOnlineTierClaimed(onlineData, tierId) then
			local need = tonumber(cfg.OnlinTime) or 0
			local tierData = onlineData and onlineData[tostring(tierId)]
			local unlocked = type(tierData) == "table" and tonumber(tierData.Unlock) == 1
			if seconds < need and not unlocked then
				return true
			end
		end
	end
	return false
end

--[[
	填充格子数量
	@param slot GuiObject - 格子
	@param cfg table - onlineawardConf 行
	@return nil
]]
local function _fillSlotCount(slot: GuiObject, cfg: { [string]: any })
	local baseCount = tonumber(cfg.CountID) or 1
	local countLabel = _child(slot, CHILD_COUNT)
	if not countLabel or not countLabel:IsA("TextLabel") then
		return
	end
	if baseCount > 1 then
		countLabel.Visible = true
		TranslationHelper.SetRawText(countLabel, "x" .. MathMgr.getNumStr(baseCount))
	else
		countLabel.Visible = false
	end
end

--[[
	填充格子静态内容（名/数量/图标；无 Day）
	@param slot GuiObject - 格子
	@param cfg table - onlineawardConf 行
	@return nil
]]
local function _fillSlotStatic(slot: GuiObject, cfg: { [string]: any })
	local awardId = tonumber(cfg.AwardID) or 0
	local itemCfg = CfgFind.FindCfgByID(awardId)

	local nameLabel = _child(slot, CHILD_NAME)
	if nameLabel and itemCfg and itemCfg.ZhName then
		TranslationHelper.SetText(nameLabel, itemCfg.ZhName)
		local xyd = itemCfg.xyd
		if xyd then
			UIMgr.AddGradientColor(tostring(xyd), nameLabel, true)
		end
	end

	_fillSlotCount(slot, cfg)

	local viewport = _child(slot, CHILD_VIEWPORT)
	local icon = _child(slot, CHILD_ICON)
	if viewport and icon then
		viewport.Visible = false
		icon.Visible = true
		if icon:IsA("ImageLabel") then
			local iconId = cfg.Icon
			if (iconId == nil or iconId == "") and itemCfg then
				iconId = itemCfg.Icon
			end
			if iconId and iconId ~= "" then
				icon.Image = _toAssetUri(iconId)
			end
		end
	end
end

--[[
	刷新单格领取态：可领取/已领取标记 + ClaimBtn（已领隐藏）
	@param slot GuiObject - 格子
	@param cfg table - 配置行
	@param onlineData table? - OnlineBox
	@return nil
]]
local function _refreshSlotState(slot: GuiObject, cfg: { [string]: any }, onlineData: { [any]: any }?)
	local canClaimMark = _child(slot, CHILD_CAN_CLAIM)
	local claimedMark = _child(slot, CHILD_HAS_CLAIMED)
	local claimRoot = _getClaimBtnRoot(slot)
	local bg = if claimRoot then claimRoot:FindFirstChild(CHILD_BG) else nil
	local unBg = if claimRoot then claimRoot:FindFirstChild(CHILD_UN_BG) else nil
	local unBgText = if unBg and unBg:IsA("GuiObject") then unBg:FindFirstChild(CHILD_UN_BG_TEXT) else nil

	local view = _onlineView(onlineData)
	local tierId = tonumber(cfg.id) or 0
	local claimed = CfgFind.IsOnlineTierClaimed(onlineData, tierId)
	local canClaim = CfgFind.IsOnlineTierClaimable(view, cfg)

	local function _setClaimVisual(showCanClaim: boolean, showClaimed: boolean, useBg: boolean, showClaimBtn: boolean)
		if canClaimMark then
			canClaimMark.Visible = showCanClaim
		end
		if claimedMark then
			claimedMark.Visible = showClaimed
		end
		if claimRoot then
			claimRoot.Visible = showClaimBtn
		end
		if bg and bg:IsA("GuiObject") then
			bg.Visible = useBg
		end
		if unBg and unBg:IsA("GuiObject") then
			unBg.Visible = not useBg
		end
	end

	if claimed then
		_setClaimVisual(false, true, false, false)
		return
	end

	if canClaim then
		_setClaimVisual(true, false, true, true)
		return
	end

	_setClaimVisual(false, false, false, true)
	if unBgText and unBgText:IsA("TextLabel") then
		local need = tonumber(cfg.OnlinTime) or 0
		local remain = math.max(0, need - (tonumber(view.OnlineSeconds) or 0))
		TranslationHelper.SetRawText(unBgText, TimeTransfer.FormatTimeS(remain))
	end
end

--[[
	刷新 ClaimAll 显隐与价格
	@param onlineData table? - OnlineBox
	@return nil
]]
local function _refreshClaimAllBtn(onlineData: { [any]: any }?)
	if not ClaimAllFrame then
		return
	end
	local show = _hasLockedUnclaimed(onlineData) and CfgFind.FindCfgByOnlyTag(CLAIM_ALL_ONLY_TAG) ~= nil
	ClaimAllFrame.Visible = show
	if not show then
		return
	end
	local shopCfg = CfgFind.FindCfgByOnlyTag(CLAIM_ALL_ONLY_TAG)
	local price = shopCfg and tonumber(shopCfg.price)
	local priceFrame = ClaimAllFrame:FindFirstChild(CHILD_PRICE)
	local priceNum = if priceFrame then priceFrame:FindFirstChild(CHILD_PRICE_NUM) else nil
	if price and priceNum and priceNum:IsA("TextLabel") then
		UIMgr.SetRbPrice(priceNum, price, false)
	end
end

--[[
	刷新全部档位状态与 ClaimAll
	@return nil
]]
local function _refreshAll()
	local onlineData = PlayerData.GetPlrDataByKey(LocalPlayer, SAVE_KEY_ONLINE)
	local list = CfgFind.GetOnlineAwardList()
	for _, cfg in ipairs(list) do
		local tierId = tonumber(cfg.id) or 0
		local slot = OnlineScroll:FindFirstChild(tostring(tierId))
		if slot and slot:IsA("GuiObject") then
			_fillSlotCount(slot, cfg)
			_refreshSlotState(slot, cfg, onlineData)
		end
	end
	_refreshClaimAllBtn(onlineData)
end

--[[
	点击领取（仅可领态响应）
	@param tierId number - 档位
	@return nil
]]
local function _onClaimClick(tierId: number)
	local onlineData = PlayerData.GetPlrDataByKey(LocalPlayer, SAVE_KEY_ONLINE)
	local cfg = CfgFind.GetOnlineAward(tierId)
	if not cfg then
		return
	end
	cfg.id = tierId
	if not CfgFind.IsOnlineTierClaimable(_onlineView(onlineData), cfg) then
		return
	end
	if _claiming then
		return
	end
	_claiming = true
	local ok = NetWork.InvokeServer(NetMsg.CLAIM_ONLINE_AWARD, tierId)
	_claiming = false
	if ok then
		local fresh = PlayerData.GetPlrDataByKey(LocalPlayer, SAVE_KEY_ONLINE)
		_refreshTimeAnchor(fresh)
		_refreshAll()
	end
end

--[[
	绑定 ClaimBtn.Btn 点击
	@param slot GuiObject - 格子
	@param tierId number - 档位
	@return nil
]]
local function _bindClaimClick(slot: GuiObject, tierId: number)
	local btn = _getClaimClickBtn(slot)
	if not btn then
		Log.warn("[OnlineAward] ClaimBtn.Btn 缺失", tierId)
		return
	end
	_trackConnections(AddListen.AddMouseClick(btn, function()
		_onClaimClick(tierId)
	end, btn))
end

--[[
	构建滚动列表
	@return nil
]]
local function _buildList()
	if _built then
		return
	end
	_built = true

	_disableSlotButton(Temp)

	for _, child in OnlineScroll:GetChildren() do
		if child:IsA("GuiObject") and child.Name ~= TEMPLATE_SLOT_NAME and child ~= Temp then
			child:Destroy()
		end
	end

	local list = CfgFind.GetOnlineAwardList()
	for _, cfg in ipairs(list) do
		local tierId = tonumber(cfg.id) or 0
		if tierId > 0 then
			local clone = Temp:Clone()
			clone.Name = tostring(tierId)
			clone.LayoutOrder = tierId
			clone.Visible = true
			clone.Parent = OnlineScroll
			_disableSlotButton(clone)
			_fillSlotStatic(clone, cfg)
			_bindClaimClick(clone, tierId)
		end
	end

	UIMgr.SetUIlistSize(OnlineScroll)
end

--[[
	界面可见时每秒刷新倒计时
	@return nil
]]
local function _startCountdownLoop()
	_countdownToken += 1
	local token = _countdownToken
	task.spawn(function()
		while token == _countdownToken and UI.Visible do
			_refreshAll()
			task.wait(1)
		end
	end)
end

-- ========================================
-- 公共函数
-- ========================================

--[[
	UIManager 刷新
	@param _uiData any?
	@return nil
]]
function OnlineAward:updateUi(_uiData)
	_buildList()
	_refreshTimeAnchor(PlayerData.GetPlrDataByKey(LocalPlayer, SAVE_KEY_ONLINE))
	_refreshAll()
end

--[[
	打开界面
	@return nil
]]
function OnlineAward:openUi()
	UIMgr.SetMainUIVisible(false)
	UI.Visible = true
	UIMgr.UpdateBlurVisible()
	_buildList()
	_refreshTimeAnchor(PlayerData.GetPlrDataByKey(LocalPlayer, SAVE_KEY_ONLINE))
	_refreshAll()
	_startCountdownLoop()

	if not _listening then
		_listening = true
		PlayerData.ListenClientSync(function(key: string | { string }?, _value: any)
			if not UI.Visible then
				return
			end
			local root = if type(key) == "table" then key[1] else key
			if root == nil or root == SAVE_KEY_ONLINE then
				_refreshTimeAnchor(PlayerData.GetPlrDataByKey(LocalPlayer, SAVE_KEY_ONLINE))
				_refreshAll()
			end
		end)
	end
end

--[[
	关闭界面
	须先 Visible=false，再 SetMainUIVisible(nil)；否则 PopBack 期间仍 Visible，
	自动判断会扫到本窗「背景模糊」继续藏主界面
	@return nil
]]
function OnlineAward:closeUi()
	_countdownToken += 1
	UI.Visible = false
	UIMgr.SetMainUIVisible(nil)
	UIMgr.UpdateBlurVisible()
end

--[[
	断开点击监听并停倒计时
	@return nil
]]
function OnlineAward:destroy()
	AddListen.DisconnectAll(_connections)
	_countdownToken += 1
end

-- ========================================
-- 事件绑定（UIManager 动态 require 时执行；无 Init）
-- ========================================
local exitBtn = _findButtonInFrame(ExitFrame)
if exitBtn then
	local scaleTarget = ExitFrame:FindFirstChild(CHILD_EXIT_SCALE)
	local scaleBtn: GuiObject = if scaleTarget and scaleTarget:IsA("GuiObject") then scaleTarget else ExitFrame
	_trackConnections(AddListen.AddMouseClick(exitBtn, function()
		NetWork.FireBindable(NetMsg.SHOW_LOCAL_UI, UI_NAME, nil, false)
	end, scaleBtn))
else
	Log.warn("[OnlineAward] Exit 按钮缺失")
end

local claimAllBtn = _findButtonInFrame(ClaimAllFrame)
if claimAllBtn then
	_trackConnections(AddListen.AddMouseClick(claimAllBtn, function()
		local onlineData = PlayerData.GetPlrDataByKey(LocalPlayer, SAVE_KEY_ONLINE)
		if not _hasLockedUnclaimed(onlineData) then
			return
		end
		SystemBuyRoblox.BuyRobloxByOnlyTag(LocalPlayer, CLAIM_ALL_ONLY_TAG)
	end, ClaimAllFrame))
else
	Log.warn("[OnlineAward] ClaimAll 按钮缺失")
end

local titleLabel = UI:FindFirstChild("在线奖励标题", true)
if titleLabel and titleLabel:IsA("TextLabel") then
	TranslationHelper.SetText(titleLabel, "在线奖励标题")
end
local tipLabel = UI:FindFirstChild("在线奖励提示", true)
if tipLabel and tipLabel:IsA("TextLabel") then
	TranslationHelper.SetText(tipLabel, "在线奖励提示")
end

return OnlineAward
