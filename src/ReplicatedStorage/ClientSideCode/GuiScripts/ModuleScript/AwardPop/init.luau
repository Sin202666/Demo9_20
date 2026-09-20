--[[
	Module: AwardPop
	Description: 通用发奖展示弹窗——物品列表与魔力/金币可同屏；只展示，不发奖
	Author: 林奥宇
	Created: 2026-09-04
	Last Modified: 2026-09-04

	功能：
	- updateUi：按 uiData 克隆货币格与物品格；模板常隐
	- Exit / AwardBtn：经 UIManager 关闭（SHOW_LOCAL_UI false），PopBack 由 UIManager 负责
	- 同类 AwardID 合并数量；魔力/金币各最多一格

	模块关系：
	- 由 UIManager 按 Frame.Name「AwardPop」动态 require；已加入排队，关窗后自动出下一包
	- 格子走 UIMgr.SetAward；货币数量 SetRawText（"+" 与数字不翻译）
	- 现网：SystemDailyAward / SystemOnlineAward / TipsModule.ShowAwardPop / SystemBuyRoblox

	约定：
	- ScreenGui.AwardPop；节点见 AllUI
	- uiData：AwardID({number}?)、Count({number}? 与 AwardID 下标对齐)、magic(number?)、coin(number?)
	- 确认键不领奖、不改背包；发奖权威在服务端

	打开：
		NetWork.FireClient(player, NetMsg.SHOW_LOCAL_UI, "AwardPop", {
			AwardID = { 2001 },
			Count = { 1 },
			magic = 10,
			coin = 100,
		}, true)
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local AddListen = Utils.AddListen
local CfgFind = Utils.CfgFind
local InsMgr = Utils.InsMgr
local Log = Utils.Log
local MathMgr = Utils.MathMgr
local NetMsg = Utils.NetMsg
local NetWork = Utils.NetWork
local TranslationHelper = Utils.TranslationHelper
local UIMgr = Utils.UIMgr

local AllUI = require(script.AllUI)

-- ========================================
-- 模块定义
-- ========================================
local AwardPop = {}

-- ========================================
-- 常量定义
-- ========================================
local UI_NAME = "AwardPop"
local HIDE_MAIN_UI_NAME = "隐藏主界面"
local NUN_NAME = "Nun"
local INNER_FRAME_NAME = "Frame"
local PLUS_PREFIX = "+"

local TEMPLATE_MAGIC = "_MagicAward"
local TEMPLATE_MONEY = "_MoneyAward"
local TEMPLATE_ITEM = "_Temp"

local CLONE_MAGIC = "MagicAwardItem"
local CLONE_MONEY = "MoneyAwardItem"

local LAYOUT_MAGIC = 1
local LAYOUT_COIN = 2
local LAYOUT_ITEM_BASE = 10

-- ========================================
-- 私有变量
-- ========================================
local UI: Frame = AllUI.UIRoot
local _listenersBound = false

-- ========================================
-- 私有函数
-- ========================================

--[[
	从按钮外层 Frame 取可点击子节点：优先 Btn / Button，否则首个 GuiButton
	@param btnFrame Instance? - AllUI.Exit / AwardBtn 等容器
	@return GuiButton? - 找不到时 nil
]]
local function _findButton(btnFrame: Instance?): GuiButton?
	if not btnFrame then
		return nil
	end
	local named = btnFrame:FindFirstChild("Btn") or btnFrame:FindFirstChild("Button")
	if named and named:IsA("GuiButton") then
		return named
	end
	local anyButton = btnFrame:FindFirstChildWhichIsA("GuiButton")
	if anyButton and anyButton:IsA("GuiButton") then
		return anyButton
	end
	return nil
end

--[[
	经 UIManager 关闭本窗（PopBack 由 UIManager 播放）
	@return nil
]]
local function _requestClose(): nil
	NetWork.FireBindable(NetMsg.SHOW_LOCAL_UI, UI_NAME, nil, false, true)
	return nil
end

--[[
	给容器绑定点击；找不到 GuiButton 时打日志
	@param frame Instance? - 按钮外层
	@param onClick () -> () - 点击回调
	@param warnName string - 缺失时日志用的节点名
	@return nil
]]
local function _bindClick(frame: Instance?, onClick: () -> (), warnName: string): nil
	local btn = _findButton(frame)
	if not btn then
		Log.warn("AwardPop: 按钮缺失", warnName)
		return nil
	end
	local scaleTarget: GuiObject = if frame and frame:IsA("GuiObject") then frame else btn
	AddListen.AddMouseClick(btn, onClick, scaleTarget)
	return nil
end

--[[
	绑定 Exit / AwardBtn（只绑一次）
	@return nil
]]
local function _ensureListeners(): nil
	if _listenersBound then
		return nil
	end
	_listenersBound = true
	_bindClick(AllUI.Exit, _requestClose, "Exit")
	_bindClick(AllUI.AwardBtn, _requestClose, "AwardBtn")
	return nil
end

--[[
	确保弹窗带「隐藏主界面」标记（Prefab 可能只有「背景模糊」）
	@return nil
]]
local function _ensureHideMainMarker(): nil
	local marker = InsMgr.GetIns(HIDE_MAIN_UI_NAME, "BoolValue", UI) :: BoolValue
	marker.Value = true
	return nil
end

--[[
	隐藏三份模板，避免算进 CanvasSize
	@return nil
]]
local function _hideTemplates(): nil
	local magicTemp = AllUI.MagicAward
	if magicTemp and magicTemp:IsA("GuiObject") then
		magicTemp.Visible = false
	end
	local moneyTemp = AllUI.MoneyAward
	if moneyTemp and moneyTemp:IsA("GuiObject") then
		moneyTemp.Visible = false
	end
	local itemTemp = AllUI.Temp
	if itemTemp and itemTemp:IsA("GuiObject") then
		itemTemp.Visible = false
	end
	return nil
end

--[[
	清掉 Scroll 里除三份模板外的克隆格
	须同步 Destroy：Debris 延到帧末，同帧 SetUIlistSize 会把旧格算进 CanvasSize
	@return nil
]]
local function _clearClones(): nil
	local scroll = AllUI.Scroll
	if not scroll then
		return nil
	end
	for _, child in ipairs(scroll:GetChildren()) do
		local name = child.Name
		if name ~= TEMPLATE_MAGIC and name ~= TEMPLATE_MONEY and name ~= TEMPLATE_ITEM then
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
	end
	return nil
end

--[[
	克隆货币模板并写入 "+" 数量
	@param template Instance? - _MagicAward / _MoneyAward
	@param amount number - 展示数量；<=0 不克隆
	@param cloneName string - 克隆体 Name
	@param layoutOrder number - LayoutOrder
	@param warnName string - 模板缺失时日志名
	@return nil
]]
local function _cloneCurrency(
	template: Instance?,
	amount: number,
	cloneName: string,
	layoutOrder: number,
	warnName: string
): nil
	if amount <= 0 then
		return nil
	end
	local scroll = AllUI.Scroll
	if not template or not template:IsA("GuiObject") or not scroll then
		Log.warn("AwardPop: 货币模板缺失", warnName)
		return nil
	end
	local clone = template:Clone()
	clone.Name = cloneName
	clone.Visible = true
	if clone:IsA("GuiObject") then
		(clone :: GuiObject).LayoutOrder = layoutOrder
	end
	clone.Parent = scroll
	local nun = clone:FindFirstChild(NUN_NAME)
	if nun and nun:IsA("TextLabel") then
		TranslationHelper.SetRawText(nun, PLUS_PREFIX .. MathMgr.getNumStr(amount))
	else
		Log.warn("AwardPop: 数量节点缺失", warnName, NUN_NAME)
	end
	return nil
end

--[[
	合并 AwardID/Count 为 id→数量
	@param awardIds { [any]: any } - uiData.AwardID
	@param counts { [any]: any } - uiData.Count
	@return { [number]: number } - 合并后的数量表
]]
local function _mergeAwards(awardIds: { [any]: any }, counts: { [any]: any }): { [number]: number }
	local itemCountById: { [number]: number } = {}
	for index, rawId in pairs(awardIds) do
		local id = tonumber(rawId)
		local count = tonumber(counts[index])
		if id and count then
			itemCountById[id] = (itemCountById[id] or 0) + count
		end
	end
	return itemCountById
end

--[[
	取 SetAward 目标 Frame：优先子节点 Frame，否则自身须为 Frame
	@param clone Instance - 物品克隆体
	@return Frame? - 可 SetAward 的格子
]]
local function _findAwardFrame(clone: Instance): Frame?
	local inner = clone:FindFirstChild(INNER_FRAME_NAME)
	if inner and inner:IsA("Frame") then
		return inner
	end
	if clone:IsA("Frame") then
		return clone
	end
	return nil
end

--[[
	按合并结果克隆物品格
	@param itemCountById { [number]: number } - 物品 ID → 数量
	@return nil
]]
local function _cloneItems(itemCountById: { [number]: number }): nil
	local template = AllUI.Temp
	local scroll = AllUI.Scroll
	if not template or not template:IsA("GuiObject") or not scroll then
		Log.warn("AwardPop: 物品模板缺失")
		return nil
	end

	local order = LAYOUT_ITEM_BASE
	for id, count in pairs(itemCountById) do
		if not CfgFind.FindCfgByID(id) then
			continue
		end
		local clone = template:Clone()
		clone.Name = tostring(id)
		clone.Visible = true
		if clone:IsA("GuiObject") then
			(clone :: GuiObject).LayoutOrder = order
		end
		clone.Parent = scroll
		order += 1

		local awardFrame = _findAwardFrame(clone)
		if awardFrame then
			UIMgr.SetAward(awardFrame, id, count)
		else
			Log.warn("AwardPop: 物品格无法 SetAward", id)
		end
	end
	return nil
end

--[[
	按可见子项重算 Scroll 的 CanvasSize（List 或 Grid）
	@return nil
]]
local function _refreshCanvas(): nil
	local scroll = AllUI.Scroll
	if not scroll or not scroll:IsA("ScrollingFrame") then
		return nil
	end
	UIMgr.SetUIlistSize(scroll)
	UIMgr.SetUIGridLayoutSize(scroll)
	return nil
end

-- ========================================
-- 公共函数
-- ========================================

--[[
	按奖励数据刷新货币格与物品列表
	@param uiData any? - AwardID/Count 下标对齐；magic/coin >0 时各克隆一格；非 table 时只清格
	@return nil
]]
function AwardPop:updateUi(uiData: any?)
	_hideTemplates()
	_clearClones()
	if type(uiData) ~= "table" then
		_refreshCanvas()
		return
	end

	local magic = math.floor(tonumber(uiData.magic) or 0)
	local coin = math.floor(tonumber(uiData.coin) or 0)
	_cloneCurrency(AllUI.MagicAward, magic, CLONE_MAGIC, LAYOUT_MAGIC, TEMPLATE_MAGIC)
	_cloneCurrency(AllUI.MoneyAward, coin, CLONE_MONEY, LAYOUT_COIN, TEMPLATE_MONEY)

	local awardIds = uiData.AwardID
	local counts = uiData.Count
	if type(awardIds) == "table" and type(counts) == "table" then
		local merged = _mergeAwards(awardIds, counts)
		if next(merged) then
			_cloneItems(merged)
		end
	end

	_refreshCanvas()
end

--[[
	打开钩子：绑按钮、藏主界面、刷新模糊（显隐由 UIManager PopUp 驱动）
	@return nil
]]
function AwardPop:openUi()
	_ensureListeners()
	_ensureHideMainMarker()
	UIMgr.SetMainUIVisible(false)
	UIMgr.UpdateBlurVisible()
end

--[[
	关闭钩子：先 Visible=false，再按标记恢复主界面
	@return nil
]]
function AwardPop:closeUi()
	UI.Visible = false
	UIMgr.SetMainUIVisible(nil)
	UIMgr.UpdateBlurVisible()
end

_hideTemplates()

return AwardPop
