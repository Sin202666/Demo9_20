--[[
	Module: Setting
	Description: 游戏设置全屏 UI（UIManager 驱动 openUi/closeUi/updateUi）
	Author: 林奥宇
	Created: 2026-01-01
	Last Modified: 2026-08-31

	功能：
	- 按 settingConf 动态生成 Toggle / 滑动条 / 下拉 / 输入 / 称号 / 兑换码行
	- 控制分类提供「键位设置」入口 → KeybindPanel（SystemInput 重绑）
	- 设置变更经 NetWork.InvokeServer(SETTING_CHANGE) 写服务端 SystemSet
	- 兑换码经 NetWork.InvokeServer(REDEEM_CODE) 走 SystemCode
	- 称号下拉背包刷新经 PlayerData.ListenClientSync（NetMsg.PLAYER_DATA_SYNC）
	- player.Setting 未就绪时延迟绑定 NumberValue，openUi 时 flushDeferredNvBinds

	子模块：
	- AllUI：UI 节点索引
	- SlideBar：横向滑动条拖拽
	- SettingDropdown：下拉 ZIndex / 布局
	- SettingRowBind：各行绑定逻辑
	- KeybindPanel：键位重绑面板

	依赖：
	- 服务端 SystemSet.Init 创建 player.Setting 下 NumberValue
	- ScreenGui 下须存在 Setting Frame（与 ModuleScript 同名）
	- 不直写存档 / 不结算奖励；权威在 SystemSet / SystemCode

	加载（UIManager 动态 require）：
	local Setting = require(...ModuleScript.Setting)
	Setting:openUi()

	示例：
	local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
	Utils.NetWork.FireBindable(Utils.NetMsg.SHOW_LOCAL_UI, "Setting", nil, true, true)
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local CfgFind = Utils.CfgFind
local AddListen = Utils.AddListen
local Log = Utils.Log
local UIMgr = Utils.UIMgr
local TranslationHelper = Utils.TranslationHelper
local EnumMgr = Utils.EnumMgr
local PlayerData = Utils.PlayerData
local TipsModule = Utils.TipsModule
local NetWork = Utils.NetWork
local NetMsg = Utils.NetMsg
local LocalPlayer = Utils.LocalPlayer

local AllUI = require(script.AllUI)
local SlideBar = require(script.SlideBar)
local SettingDropdown = require(script.SettingDropdown)
local SettingRowBind = require(script.SettingRowBind)
local KeybindPanel = require(script.KeybindPanel)

local Setting = {}

-- ========================================
-- 常量
-- ========================================
local settingConf = CfgFind.GetCfgByName("settingConf") or {}
local TEMP_TYPE = EnumMgr.SettingTempType
local SETTING_KEY_EQUIP_TITLE = "EquipTitle"
local KEYBIND_ENTRY_LAYOUT_ORDER = 9999
local TEMPLATE_CHILD_NAMES = {
	_Temp = true,
	_TempBar = true,
	_TempChoose = true,
	_TempInput = true,
}

-- ========================================
-- 私有变量
-- ========================================
local UI = AllUI.UIRoot
local ScrollingFrame: ScrollingFrame = AllUI.ScrollingFrame
local SecondFrameTpl: Frame = AllUI.SecondFrame
local TempTpl: Frame = AllUI.Temp
local TempBarTpl: Frame = AllUI.TempBar
local TempChooseTpl: Frame = AllUI.TempChoose
local TempInputTpl: Frame = AllUI.TempInput
local TabTempTpl: Frame = AllUI.TabTemp
local TopTab: Frame = AllUI.TopTab

local dropdownState: SettingDropdown.State = {
	categoryToSecondFrame = {},
	openDropdownScroll = nil,
}
local tabEntries: { { frame: Frame, setType: number } } = {}
local orderedCats: { number } = {}

-- ========================================
-- 私有函数
-- ========================================

--[[
	上送设置变更到服务端 SystemSet
	@param showName string - settingConf.ShowName
	@param setValue number - 写入值
	@return nil - Invoke 失败或业务拒绝时 Tips，不向玩家展示内部 err
]]
local function _pushSettingChange(showName: string, setValue: number)
	local ok, result = pcall(function()
		return NetWork.InvokeServer(NetMsg.SETTING_CHANGE, showName, setValue)
	end)
	if not ok then
		Log.warn("[Setting] SETTING_CHANGE failed:", showName, result)
		TipsModule.ErrorTips(LocalPlayer, "设置保存失败，请稍后重试", nil)
		return
	end
	if result == false then
		TipsModule.ErrorTips(LocalPlayer, "设置保存失败", nil)
	end
end

local rowBinder = SettingRowBind.create({
	module = Setting,
	settingConf = settingConf,
	dropdownState = dropdownState,
	UIMgr = UIMgr,
	AddListen = AddListen,
	CfgFind = CfgFind,
	TranslationHelper = TranslationHelper,
	TipsModule = TipsModule,
	NetWork = NetWork,
	NetMsg = NetMsg,
	LocalPlayer = LocalPlayer,
	EnumMgr = EnumMgr,
	PlayerData = PlayerData,
	SlideBar = SlideBar,
	pushSettingChange = _pushSettingChange,
})

rowBinder.registerBagSync()

--[[
	按 SetType 写分类标题（Key 必须是调用处字面量）
	@param label TextLabel - Title 或 TabName
	@param setType number - settingConf.SetType / EnumMgr.SettingCategory
	@return nil - 未识别时回退「设置」
]]
local function _applyCategoryTitle(label: TextLabel, setType: number)
	if setType == EnumMgr.SettingCategory.Special then
		TranslationHelper.SetText(label, "特殊功能")
	elseif setType == EnumMgr.SettingCategory.Sound then
		TranslationHelper.SetText(label, "声音")
	elseif setType == EnumMgr.SettingCategory.Display then
		TranslationHelper.SetText(label, "显示")
	elseif setType == EnumMgr.SettingCategory.Control then
		TranslationHelper.SetText(label, "控制")
	elseif setType == EnumMgr.SettingCategory.Other then
		TranslationHelper.SetText(label, "其他")
	else
		TranslationHelper.SetText(label, "设置")
	end
end

--[[
	切换顶栏 Tab 选中态
	@param setType number - 当前选中分类 SetType
	@return nil - 无返回值
]]
local function _setTabSelected(setType: number)
	for _, e in ipairs(tabEntries) do
		local tab = e.frame
		local sel = e.setType == setType
		local chooseBg = tab:FindFirstChild("ChooseBg") :: GuiObject?
		local defaultBg = tab:FindFirstChild("DefaultBg") :: GuiObject?
		if chooseBg then
			chooseBg.Visible = sel
		end
		if defaultBg then
			defaultBg.Visible = not sel
		end
	end
end

--[[
	滚动列表定位到指定分类块
	@param target Frame - Cat_ 分类 Frame
	@return nil - 目标已销毁时跳过
]]
local function _scrollToSecondFrame(target: Frame)
	task.defer(function()
		task.wait()
		if not target.Parent or not target:IsDescendantOf(ScrollingFrame) then
			return
		end
		local relY = target.AbsolutePosition.Y - ScrollingFrame.AbsolutePosition.Y + ScrollingFrame.CanvasPosition.Y
		local maxScroll = math.max(0, ScrollingFrame.AbsoluteCanvasSize.Y - ScrollingFrame.AbsoluteWindowSize.Y)
		ScrollingFrame.CanvasPosition = Vector2.new(0, math.clamp(relY, 0, maxScroll))
	end)
end

--[[
	隐藏编辑器用的行/分类模板
	@return nil - 无返回值
]]
local function _hideTemplates()
	SecondFrameTpl.Visible = false
	TabTempTpl.Visible = false
	TempTpl.Visible = false
	TempBarTpl.Visible = false
	TempChooseTpl.Visible = false
	TempInputTpl.Visible = false
end

--[[
	按 TempType 绑一行（称号走专用下拉）
	@param v any - settingConf 行
	@param newRow Frame - 已克隆的行
	@param showName string - settingConf.ShowName
	@param sec Frame - 所属 Cat_
	@return nil - 无返回值
]]
local function _bindRowByTempType(v: any, newRow: Frame, showName: string, sec: Frame)
	local tt = v.TempType or TEMP_TYPE.Toggle
	if tt == TEMP_TYPE.Slider then
		rowBinder.bindSliderRow(v, newRow, showName)
		return
	end
	if tt == TEMP_TYPE.Choose then
		if showName == SETTING_KEY_EQUIP_TITLE then
			rowBinder.bindEquipTitleRow(newRow, showName, sec)
		else
			rowBinder.bindChooseRow(v, newRow, showName, sec)
		end
		return
	end
	if tt == TEMP_TYPE.Input then
		rowBinder.bindCodeRow(v, newRow, showName)
		return
	end
	rowBinder.bindToggleRow(v, newRow, showName)
end

--[[
	克隆一个分类块并填充可见行
	@param setType number - settingConf.SetType
	@param catRows {{id: number, v: any}} - 该分类下的配置行
	@param secLayoutOrder number - 当前已用 LayoutOrder
	@return number - 写入后的 LayoutOrder
]]
local function _createCategorySection(
	setType: number,
	catRows: { { id: number, v: any } },
	secLayoutOrder: number
): number
	local sec = SecondFrameTpl:Clone()
	sec.Visible = true
	sec.Name = "Cat_" .. tostring(setType)
	secLayoutOrder += 1
	sec.LayoutOrder = secLayoutOrder
	sec.Parent = ScrollingFrame

	local titleFrame = sec:FindFirstChild("TitleFrame") :: Frame?
	if titleFrame then
		local titleLbl = titleFrame:FindFirstChild("Title") :: TextLabel?
		if titleLbl then
			_applyCategoryTitle(titleLbl, setType)
		end
	end

	for _, child in sec:GetChildren() do
		if TEMPLATE_CHILD_NAMES[child.Name] then
			child:Destroy()
		end
	end

	dropdownState.categoryToSecondFrame[setType] = sec

	local maxRowIdInCat = 0
	for _, e in ipairs(catRows) do
		if e.id > maxRowIdInCat then
			maxRowIdInCat = e.id
		end
	end
	local rowOrder = 0
	for _, entry in ipairs(catRows) do
		local v = entry.v
		local tt = v.TempType or TEMP_TYPE.Toggle
		rowOrder += 1

		local tpl: Frame
		if tt == TEMP_TYPE.Slider then
			tpl = TempBarTpl
		elseif tt == TEMP_TYPE.Choose then
			tpl = TempChooseTpl
		elseif tt == TEMP_TYPE.Input then
			tpl = TempInputTpl
		else
			tpl = TempTpl
		end

		local newRow = tpl:Clone()
		newRow.Visible = true
		newRow.Name = v.ShowName
		newRow.LayoutOrder = rowOrder
		newRow.ZIndex = maxRowIdInCat - entry.id + 1
		newRow.Parent = sec

		local titleLbl = newRow:FindFirstChild("Title") :: TextLabel?
		if titleLbl then
			TranslationHelper.SetText(titleLbl, v.ZhName)
		end
		_bindRowByTempType(v, newRow, v.ShowName, sec)
	end

	UIMgr.SetUIlistSize_New(sec)
	return secLayoutOrder
end

--[[
	按 settingConf 构建分类块、设置行与顶栏 Tab（模块加载时执行一次）
	@return nil - 无返回值
]]
local function _buildSettingUI()
	_hideTemplates()

	local rows = rowBinder.collectVisibleRows()
	local byCat: { [number]: { { id: number, v: any } } } = {}
	table.clear(orderedCats)
	local seenCat: { [number]: boolean } = {}
	for _, r in ipairs(rows) do
		local st = r.v.SetType or 1
		if not byCat[st] then
			byCat[st] = {}
		end
		table.insert(byCat[st], r)
		if not seenCat[st] then
			seenCat[st] = true
			table.insert(orderedCats, st)
		end
	end

	local secLayoutOrder = 0
	for _, setType in ipairs(orderedCats) do
		secLayoutOrder = _createCategorySection(setType, byCat[setType] or {}, secLayoutOrder)
	end

	SettingDropdown.closeAny(dropdownState)
	UIMgr.SetUIlistSize_New(ScrollingFrame)

	for _, setType in ipairs(orderedCats) do
		local tab = TabTempTpl:Clone()
		tab.Visible = true
		tab.Name = "Tab_" .. tostring(setType)
		tab.Parent = TopTab
		local tabNameLbl = tab:FindFirstChild("TabName") :: TextLabel?
		if tabNameLbl then
			_applyCategoryTitle(tabNameLbl, setType)
		end
		local btn = tab:FindFirstChild("Btn") :: ImageButton?
		if btn then
			AddListen.AddMouseCLick(btn, function()
				_setTabSelected(setType)
				local target = dropdownState.categoryToSecondFrame[setType]
				if target then
					_scrollToSecondFrame(target)
				end
			end, tab)
		end
		table.insert(tabEntries, { frame = tab, setType = setType })
	end
	UIMgr.SetUIlistSize_New(TopTab)

	if #orderedCats > 0 then
		_setTabSelected(orderedCats[1])
	end

	rowBinder.flushDeferredNvBinds()
end

--[[
	在「控制」分类末尾插入键位设置入口行
	@return nil - 无可用分类块时跳过
]]
local function _injectKeybindEntry()
	local controlType = EnumMgr.SettingCategory.Control
	local sec = dropdownState.categoryToSecondFrame[controlType]
	if not sec then
		if #orderedCats == 0 then
			return
		end
		sec = dropdownState.categoryToSecondFrame[orderedCats[1]]
	end
	if not sec then
		return
	end

	local row = TempTpl:Clone()
	row.Visible = true
	row.Name = "KeybindEntry"
	row.LayoutOrder = KEYBIND_ENTRY_LAYOUT_ORDER
	row.Parent = sec

	local titleLbl = row:FindFirstChild("Title") :: TextLabel?
	if titleLbl then
		TranslationHelper.SetText(titleLbl, "键位设置")
	end

	local btn = row:FindFirstChild("Btn") :: GuiButton?
		or row:FindFirstChildWhichIsA("GuiButton", true)
	if btn then
		AddListen.AddMouseCLick(btn, function()
			KeybindPanel.Open()
		end, row)
	else
		local clickCatch = Instance.new("TextButton")
		clickCatch.Name = "KeybindOpen"
		clickCatch.Size = UDim2.fromScale(1, 1)
		clickCatch.BackgroundTransparency = 1
		clickCatch.Text = ""
		clickCatch.ZIndex = 5
		clickCatch.Parent = row
		AddListen.AddMouseCLick(clickCatch, function()
			KeybindPanel.Open()
		end, row)
	end

	UIMgr.SetUIlistSize_New(sec)
end

_buildSettingUI()
_injectKeybindEntry()

local exitFrame = AllUI.Exit
local BtnClose = exitFrame and (exitFrame:FindFirstChild("Btn") or exitFrame:FindFirstChild("Button")) :: ImageButton?
if BtnClose then
	AddListen.AddMouseCLick(BtnClose, function()
		Setting:closeUi()
	end, BtnClose.Parent)
end

-- ========================================
-- 公共函数
-- ========================================

--[[
	UIManager 刷新入口（当前无动态数据需求，预留）
	@param _data any? - UIManager 传入的打开参数；当前忽略
	@return nil - 无返回值
]]
function Setting:updateUi(_data: any?)
end

--[[
	打开设置全屏 UI，并补绑尚未就绪的 Setting NumberValue
	@return nil - UIRoot 缺失时打日志并 return
]]
function Setting:openUi()
	if not UI then
		Log.warn("[Setting] UIRoot missing in openUi")
		return
	end
	UIMgr.SetMainUIVisible(false)
	UI.Visible = true
	UIMgr.UpdateBlurVisible()
	rowBinder.flushDeferredNvBinds()
	task.defer(function()
		task.wait()
		local rebuild = rowBinder.getEquipTitleRebuild()
		if rebuild then
			rebuild()
		end
		for _, setType in ipairs(orderedCats) do
			local sec = dropdownState.categoryToSecondFrame[setType]
			if sec then
				UIMgr.SetUIlistSize_New(sec)
			end
		end
		UIMgr.SetUIlistSize_New(ScrollingFrame)
	end)
end

--[[
	关闭设置全屏 UI（同时关键位面板与下拉、取消滑条拖拽）
	@return nil - UIRoot 缺失时打日志并 return
]]
function Setting:closeUi()
	if not UI then
		Log.warn("[Setting] UIRoot missing in closeUi")
		return
	end
	KeybindPanel.Close()
	SettingDropdown.closeAny(dropdownState)
	SlideBar.CancelActive()
	UIMgr.SetMainUIVisible(true)
	UI.Visible = false
	UIMgr.UpdateBlurVisible()
end

return Setting
