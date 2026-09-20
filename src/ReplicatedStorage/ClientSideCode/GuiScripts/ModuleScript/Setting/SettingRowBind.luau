--[[
	Module: SettingRowBind
	Description: 设置页各行 UI 绑定（Toggle / 滑条 / 下拉 / 输入 / 称号 / 兑换码）
	Author: 林奥宇
	Created: 2026-07-03
	Last Modified: 2026-08-31

	功能：
	- create(opts) 返回 Binder：按 TempType 绑一行，并延迟绑定 player.Setting NumberValue
	- 称号下拉随 Bag 同步重建；兑换码走 REDEEM_CODE，其它项走 SETTING_CHANGE
	- 不直写存档；变更只经 opts.pushSettingChange / InvokeServer

	与 Setting/init：
	- init 构建分类块后调用 bind*；openUi 时 flushDeferredNvBinds
	- 下拉互斥与 ZIndex 走 SettingDropdown

	加载：
	local SettingRowBind = require(script.SettingRowBind)
	local binder = SettingRowBind.create(opts)
	binder.bindToggleRow(v, row, showName)

	opts.pushSettingChange(showName, setValue) 由 init 注入，内部 InvokeServer(SETTING_CHANGE)。
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Log = Utils.Log

local SettingDropdown = require(script.Parent.SettingDropdown)

local SettingRowBind = {}

-- ========================================
-- 类型
-- ========================================

export type CreateOptions = {
	module: any,
	settingConf: { [any]: any },
	dropdownState: SettingDropdown.State,
	UIMgr: any,
	AddListen: any,
	CfgFind: any,
	TranslationHelper: any,
	TipsModule: any,
	NetWork: any,
	NetMsg: any,
	LocalPlayer: Player,
	EnumMgr: any,
	PlayerData: any,
	SlideBar: any,
	pushSettingChange: (showName: string, setValue: number) -> (),
}

export type Binder = {
	bindToggleRow: (v: any, row: Frame, showName: string) -> (),
	bindSliderRow: (v: any, row: Frame, showName: string) -> (),
	bindChooseRow: (v: any, row: Frame, showName: string, catSec: Frame) -> (),
	bindEquipTitleRow: (row: Frame, showName: string, catSec: Frame) -> (),
	bindCodeRow: (v: any, row: Frame, showName: string) -> (),
	flushDeferredNvBinds: () -> (),
	getEquipTitleRebuild: () -> (() -> ())?,
	registerBagSync: () -> (),
	collectVisibleRows: () -> { { id: number, v: any } },
}

-- ========================================
-- 常量
-- ========================================
local SETTING_KEY_HIDE_UI = "HideUI"
local SETTING_KEY_BGM = "BGM"
local SETTING_KEY_EFFECT = "EFFECT"
local SETTING_KEY_SHAKE = "Shake"
local SETTING_KEY_CODE = "Code"
local SETTING_KEY_EQUIP_TITLE = "EquipTitle"
local REDEEM_CODE_MAX_LEN = 50

-- ========================================
-- 公共函数
-- ========================================

--[[
	创建设置行绑定器（一次会话一个，持有延迟 NV 队列与称号 rebuild）
	@param opts CreateOptions - 依赖与共享状态（settingConf / dropdownState / pushSettingChange）
	@return Binder - 行绑定 API
]]
function SettingRowBind.create(opts: CreateOptions): Binder
	local uiModule = opts.module
	local dropdownState = opts.dropdownState
	local UIMgr = opts.UIMgr
	local AddListen = opts.AddListen
	local CfgFind = opts.CfgFind
	local TranslationHelper = opts.TranslationHelper
	local TipsModule = opts.TipsModule
	local NetWork = opts.NetWork
	local NetMsg = opts.NetMsg
	local LocalPlayer = opts.LocalPlayer
	local EnumMgr = opts.EnumMgr
	local PlayerData = opts.PlayerData
	local SlideBar = opts.SlideBar
	local pushSettingChange = opts.pushSettingChange
	local settingConf = opts.settingConf

	local titleItemTp = EnumMgr.ItemType.Title
	local equipTitleRebuild: (() -> ())? = nil
	local bagSyncRegistered = false
	local deferredNvBinds: { { showName: string, bindFn: (nv: NumberValue) -> () } } = {}

	--[[
		取 player.Setting 下对应 NumberValue
		@param showName string - settingConf.ShowName / NumberValue.Name
		@return NumberValue? - 不存在或类型不对时 nil
	]]
	local function _getSettingNumberValue(showName: string): NumberValue?
		local folder = LocalPlayer:FindFirstChild("Setting")
		if not folder then
			return nil
		end
		local nv = folder:FindFirstChild(showName)
		if nv and nv:IsA("NumberValue") then
			return nv
		end
		return nil
	end

	--[[
		NV 已就绪则立刻 bind；否则推进延迟队列等 flush
		@param showName string - settingConf.ShowName
		@param bindFn (NumberValue) -> () - 绑监听的回调
		@return nil - 无返回值
	]]
	local function _bindNumberValue(showName: string, bindFn: (nv: NumberValue) -> ())
		local nv = _getSettingNumberValue(showName)
		if nv then
			bindFn(nv)
			return
		end
		table.insert(deferredNvBinds, { showName = showName, bindFn = bindFn })
	end

	--[[
		收集 isShow==1 的配置行，按 SetType 再按 id 排序
		@return {{id: number, v: any}} - v 为 settingConf 行
	]]
	local function _collectVisibleRows(): { { id: number, v: any } }
		local rows: { { id: number, v: any } } = {}
		for id, v in pairs(settingConf) do
			if v.isShow == 1 then
				table.insert(rows, { id = id :: number, v = v })
			end
		end
		table.sort(rows, function(a, b)
			local stA = a.v.SetType or 0
			local stB = b.v.SetType or 0
			if stA ~= stB then
				return stA < stB
			end
			return a.id < b.id
		end)
		return rows
	end

	--[[
		已拥有称号 id 列表（含 0=无）
		@return {number} - 0 在首，其余按 id 升序；缺 Bag 时仅 {0}
	]]
	local function _collectOwnedTitleIds(): { number }
		local entries: { number } = {}
		local bag = PlayerData.GetPlrDataByKey(LocalPlayer, "Bag")
		if type(bag) == "table" then
			local seen: { [number]: boolean } = {}
			for _, item in pairs(bag) do
				if type(item) == "table" and item.tp == titleItemTp then
					local id = tonumber(item.id)
					if id and not seen[id] then
						seen[id] = true
						table.insert(entries, id)
					end
				end
			end
		end
		table.sort(entries)
		local titleIds: { number } = { 0 }
		for _, id in ipairs(entries) do
			table.insert(titleIds, id)
		end
		return titleIds
	end

	--[[
		把称号选项文案写到标签（0 / 未知走「无」，其余走配置 ZhName）
		@param label TextLabel - 目标标签
		@param titleId number - 称号物品 id；0 表示未装备
		@return nil - 无返回值
	]]
	local function _applyTitleOptionText(label: TextLabel, titleId: number)
		if titleId == 0 then
			TranslationHelper.SetText(label, "无")
			return
		end
		local cfg = CfgFind.FindCfgByID(titleId, titleItemTp)
		if cfg and cfg.ZhName then
			TranslationHelper.SetText(label, cfg.ZhName)
			return
		end
		TranslationHelper.SetText(label, "无")
	end

	--[[
		按当前装备值刷新下拉标题，并套称号样式
		@param val number - EquipTitle NumberValue
		@param titleName TextLabel? - SortName；nil 时跳过
		@return nil - 无返回值
	]]
	local function _syncEquipTitleDisplay(val: number, titleName: TextLabel?)
		if not titleName then
			return
		end
		_applyTitleOptionText(titleName, val)
		UIMgr.ApplyTitleTextByTitleId(titleName, val)
	end

	--[[
		给输入框写 Placeholder（ZhDes[1] 或「在此输入」）
		@param v any - settingConf 行，可读 ZhDes
		@param row Frame - 含 Input/TextBox 的行
		@return nil - 无 TextBox 时跳过
	]]
	local function _bindInputRow(v: any, row: Frame)
		local inputFrame = row:FindFirstChild("Input") :: Frame?
		local textBox = inputFrame and inputFrame:FindFirstChildOfClass("TextBox")
		if not textBox then
			return
		end
		if type(v.ZhDes) == "table" and type(v.ZhDes[1]) == "string" and v.ZhDes[1] ~= "" then
			TranslationHelper.SetText(textBox, v.ZhDes[1])
		else
			TranslationHelper.SetText(textBox, "在此输入")
		end
	end

	--[[
		绑定开关行（ZhDes[1]/[2] 为关/开文案 Key）
		@param v any - settingConf 行
		@param row Frame - Toggle 模板克隆
		@param showName string - settingConf.ShowName
		@return nil - 无 State 时跳过
	]]
	local function bindToggleRow(v: any, row: Frame, showName: string)
		local state = row:FindFirstChild("State") :: Frame?
		if not state then
			return
		end
		local offHalf = state:FindFirstChild("OFF") :: GuiObject?
		local onHalf = state:FindFirstChild("ON") :: GuiObject?
		local offBtn = offHalf and offHalf:FindFirstChild("Button") :: ImageButton?
		local onBtn = onHalf and onHalf:FindFirstChild("Button") :: ImageButton?
		local offTxt = offHalf and offHalf:FindFirstChild("ShowText")
		local onTxt = onHalf and onHalf:FindFirstChild("ShowText")

		local hasZhDes = type(v.ZhDes) == "table" and v.ZhDes[1] and v.ZhDes[2]
		if offTxt and offTxt:IsA("TextLabel") then
			if hasZhDes then
				TranslationHelper.SetText(offTxt, v.ZhDes[1])
			else
				TranslationHelper.SetText(offTxt, "关闭")
			end
		elseif offTxt and offTxt:IsA("TextButton") then
			if hasZhDes then
				offTxt.Text = TranslationHelper.TranslateByKey(v.ZhDes[1])
			else
				offTxt.Text = TranslationHelper.TranslateByKey("关闭")
			end
		end
		if onTxt and onTxt:IsA("TextLabel") then
			if hasZhDes then
				TranslationHelper.SetText(onTxt, v.ZhDes[2])
			else
				TranslationHelper.SetText(onTxt, "开启")
			end
		elseif onTxt and onTxt:IsA("TextButton") then
			if hasZhDes then
				onTxt.Text = TranslationHelper.TranslateByKey(v.ZhDes[2])
			else
				onTxt.Text = TranslationHelper.TranslateByKey("开启")
			end
		end

		local function onHideUiClose()
			if showName == SETTING_KEY_HIDE_UI then
				uiModule:closeUi()
			end
		end

		if offBtn then
			AddListen.AddMouseCLick(offBtn, function()
				onHideUiClose()
				pushSettingChange(showName, 0)
			end, offHalf)
		end
		if onBtn then
			AddListen.AddMouseCLick(onBtn, function()
				onHideUiClose()
				pushSettingChange(showName, 1)
			end, onHalf)
		end

		_bindNumberValue(showName, function(nv: NumberValue)
			AddListen.NumValueAdd(nv, function(_num: number)
				if offHalf then
					offHalf.Visible = _num == 0
				end
				if onHalf then
					onHalf.Visible = _num == 1
				end
			end)
		end)
	end

	--[[
		绑定滑动条行，并把 range / 步进写到 Attribute 供 SlideBar 读取
		@param v any - settingConf 行，可读 range / isPecent
		@param row Frame - TempBar 克隆
		@param showName string - settingConf.ShowName
		@return nil - 无「滑动条」节点时跳过
	]]
	local function bindSliderRow(v: any, row: Frame, showName: string)
		local barFolder = row:FindFirstChild("滑动条") :: Frame?
		if not barFolder then
			return
		end
		local r = v.range
		if type(r) == "table" and r[1] ~= nil and r[2] ~= nil then
			barFolder:SetAttribute("SliderMin", r[1] :: number)
			barFolder:SetAttribute("SliderMax", r[2] :: number)
		end
		barFolder:SetAttribute("SliderStep", 1)
		if showName == SETTING_KEY_BGM or showName == SETTING_KEY_EFFECT or showName == SETTING_KEY_SHAKE then
			barFolder:SetAttribute("SliderLabelMode", "audio01")
		end
		if v.isPecent == 1 then
			row:SetAttribute("SliderIsPercent", true)
		end
		_bindNumberValue(showName, function(nv: NumberValue)
			SlideBar.Bind(barFolder, row, nv, pushSettingChange, showName)
		end)
	end

	--[[
		绑定普通下拉（选项文案来自 v.ZhDes 数组）
		@param v any - settingConf 行
		@param row Frame - TempChoose 克隆
		@param showName string - settingConf.ShowName
		@param catSec Frame - 所属 Cat_，用于展开时抬 ZIndex
		@return nil - 缺节点或 ZhDes 为空时跳过
	]]
	local function bindChooseRow(v: any, row: Frame, showName: string, catSec: Frame)
		local sortFrame = row:FindFirstChild("SortFrame") :: Frame?
		if not sortFrame then
			return
		end
		local scrollSort = sortFrame:FindFirstChild("ScrollSort") :: ScrollingFrame?
		local sortTitle = sortFrame:FindFirstChild("SortTitle") :: Frame?
		if not scrollSort or not sortTitle then
			return
		end
		local titleBtn = sortTitle:FindFirstChild("Btn") :: ImageButton?
		local titleName = sortTitle:FindFirstChild("SortName") :: TextLabel?
		local sortTemp = scrollSort:FindFirstChild("SortTemp") :: Frame?
		if not sortTemp or not titleBtn then
			return
		end
		if type(v.ZhDes) ~= "table" then
			return
		end

		sortTemp.Visible = false
		local optionCount = 0
		for idx, lab in ipairs(v.ZhDes) do
			if type(lab) == "string" then
				optionCount += 1
				local i = idx - 1
				local item = sortTemp:Clone()
				item.Visible = true
				item.Parent = scrollSort
				item.Name = "Opt_" .. tostring(i)
				local itemBtn = item:FindFirstChild("Btn") :: ImageButton?
				local itemName = item:FindFirstChild("SortName") :: TextLabel?
				if itemName then
					TranslationHelper.SetText(itemName, v.ZhDes[idx])
				end
				if itemBtn then
					AddListen.AddMouseCLick(itemBtn, function()
						if titleName then
							TranslationHelper.SetText(titleName, v.ZhDes[idx])
						end
						pushSettingChange(showName, i)
						SettingDropdown.closeAny(dropdownState)
					end, item)
				end
			end
		end
		if optionCount == 0 then
			return
		end
		SettingDropdown.layoutScrollSort(UIMgr, sortFrame, scrollSort)
		local szInit = scrollSort.Size
		scrollSort.Size = UDim2.new(szInit.X.Scale, szInit.X.Offset, 0, 0)
		scrollSort.Visible = false
		AddListen.AddMouseCLick(titleBtn, function()
			if scrollSort.Visible then
				SettingDropdown.closeAny(dropdownState)
				return
			end
			SettingDropdown.closeAny(dropdownState)
			scrollSort.Visible = true
			SettingDropdown.layoutScrollSort(UIMgr, sortFrame, scrollSort)
			SettingDropdown.syncCatZIndex(dropdownState, catSec)
			dropdownState.openDropdownScroll = scrollSort
		end, sortTitle)

		_bindNumberValue(showName, function(nv: NumberValue)
			AddListen.NumValueAdd(nv, function(val: number)
				if titleName and type(v.ZhDes[val + 1]) == "string" then
					TranslationHelper.SetText(titleName, v.ZhDes[val + 1])
				end
				SettingDropdown.layoutScrollSort(UIMgr, sortFrame, scrollSort)
			end)
		end)
	end

	--[[
		在 NV 就绪后搭建称号下拉（选项随背包变化 rebuild）
		@param nv NumberValue - EquipTitle
		@param row Frame - TempChoose 克隆
		@param showName string - 一般为 EquipTitle
		@param catSec Frame - 所属 Cat_
		@return nil - 缺节点时跳过
	]]
	local function _setupEquipTitleRow(nv: NumberValue, row: Frame, showName: string, catSec: Frame)
		local sortFrame = row:FindFirstChild("SortFrame") :: Frame?
		if not sortFrame then
			return
		end
		local scrollSort = sortFrame:FindFirstChild("ScrollSort") :: ScrollingFrame?
		local sortTitle = sortFrame:FindFirstChild("SortTitle") :: Frame?
		if not scrollSort or not sortTitle then
			return
		end
		local titleBtn = sortTitle:FindFirstChild("Btn") :: ImageButton?
		local titleName = sortTitle:FindFirstChild("SortName") :: TextLabel?
		local sortTemp = scrollSort:FindFirstChild("SortTemp") :: Frame?
		if not sortTemp or not titleBtn then
			return
		end

		local function rebuild()
			if dropdownState.openDropdownScroll == scrollSort then
				dropdownState.openDropdownScroll = nil
			end
			SettingDropdown.clearDynamicChildren(scrollSort, sortTemp)
			local titleIds = _collectOwnedTitleIds()
			sortTemp.Visible = false
			for idx, tid in ipairs(titleIds) do
				local item = sortTemp:Clone()
				item.Visible = true
				item.Parent = scrollSort
				item.Name = "Opt_" .. tostring(idx)
				local itemBtn = item:FindFirstChild("Btn") :: ImageButton?
				local itemName = item:FindFirstChild("SortName") :: TextLabel?
				if itemName then
					_applyTitleOptionText(itemName, tid)
					UIMgr.ApplyTitleTextByTitleId(itemName, tid)
				end
				if itemBtn then
					AddListen.AddMouseCLick(itemBtn, function()
						if titleName then
							_applyTitleOptionText(titleName, tid)
							UIMgr.ApplyTitleTextByTitleId(titleName, tid)
						end
						pushSettingChange(showName, tid)
						SettingDropdown.closeAny(dropdownState)
					end, item)
				end
			end
			SettingDropdown.layoutScrollSort(UIMgr, sortFrame, scrollSort)
			scrollSort.Visible = false
			local sz = scrollSort.Size
			scrollSort.Size = UDim2.new(sz.X.Scale, sz.X.Offset, 0, 0)
			SettingDropdown.syncCatZIndex(dropdownState, nil)
			_syncEquipTitleDisplay(nv.Value, titleName)
		end

		rebuild()
		equipTitleRebuild = rebuild

		AddListen.NumValueAdd(nv, function(val: number)
			_syncEquipTitleDisplay(val, titleName)
			if scrollSort.Visible then
				SettingDropdown.layoutScrollSort(UIMgr, sortFrame, scrollSort)
			end
		end)

		AddListen.AddMouseCLick(titleBtn, function()
			if scrollSort.Visible then
				SettingDropdown.closeAny(dropdownState)
				return
			end
			rebuild()
			SettingDropdown.closeAny(dropdownState)
			scrollSort.Visible = true
			SettingDropdown.layoutScrollSort(UIMgr, sortFrame, scrollSort)
			SettingDropdown.syncCatZIndex(dropdownState, catSec)
			dropdownState.openDropdownScroll = scrollSort
		end, sortTitle)
	end

	--[[
		绑定称号行；NV 未就绪时进延迟队列
		@param row Frame - TempChoose 克隆
		@param showName string - EquipTitle
		@param catSec Frame - 所属 Cat_
		@return nil - 无返回值
	]]
	local function bindEquipTitleRow(row: Frame, showName: string, catSec: Frame)
		local nv = _getSettingNumberValue(showName)
		if nv then
			_setupEquipTitleRow(nv, row, showName, catSec)
		else
			_bindNumberValue(showName, function(nvBound: NumberValue)
				_setupEquipTitleRow(nvBound, row, showName, catSec)
			end)
		end
	end

	--[[
		绑定兑换码行（ShowName==Code 才走 REDEEM_CODE；其它 Input 只写 hint）
		@param v any - settingConf 行
		@param row Frame - TempInput 克隆
		@param showName string - settingConf.ShowName
		@return nil - 无按钮时仅写 hint
	]]
	local function bindCodeRow(v: any, row: Frame, showName: string)
		if showName ~= SETTING_KEY_CODE then
			_bindInputRow(v, row)
			return
		end
		local inputFrame = row:FindFirstChild("Input") :: Frame?
		local textBox = inputFrame and inputFrame:FindFirstChildOfClass("TextBox")
		local btnFrame = row:FindFirstChild("BtnFrame") :: Frame?
		local btn = btnFrame and (btnFrame:FindFirstChild("Btn") or btnFrame:FindFirstChild("Button")) :: ImageButton?
		if textBox then
			textBox.Text = ""
			if type(v.ZhDes) == "table" and type(v.ZhDes[1]) == "string" and v.ZhDes[1] ~= "" then
				TranslationHelper.SetText(textBox, v.ZhDes[1])
			else
				TranslationHelper.SetText(textBox, "在此输入")
			end
		end
		if btn then
			AddListen.AddMouseCLick(btn, function()
				local t = (textBox and textBox.Text) or ""
				if string.len(t) > 0 and string.len(t) < REDEEM_CODE_MAX_LEN then
					local ok, result = pcall(function()
						return NetWork.InvokeServer(NetMsg.REDEEM_CODE, string.upper(t))
					end)
					if ok and result then
						if textBox then
							textBox.Text = ""
						end
					elseif not ok then
						Log.warn("[Setting] REDEEM_CODE failed:", result)
						TipsModule.ErrorTips(LocalPlayer, "兑换失败，请稍后重试", nil)
					end
				else
					TipsModule.ErrorTips(LocalPlayer, "兑换码不能为空", nil)
				end
			end, btnFrame)
		end
	end

	--[[
		把延迟队列里已出现的 NumberValue 补绑上
		@return nil - 无 Setting 文件夹时跳过
	]]
	local function flushDeferredNvBinds()
		local folder = LocalPlayer:FindFirstChild("Setting")
		if not folder then
			return
		end
		local i = 1
		while i <= #deferredNvBinds do
			local entry = deferredNvBinds[i]
			local nv = folder:FindFirstChild(entry.showName)
			if nv and nv:IsA("NumberValue") then
				entry.bindFn(nv)
				table.remove(deferredNvBinds, i)
			else
				i += 1
			end
		end
	end

	--[[
		监听 Bag 同步以重建称号下拉（幂等）
		@return nil - 已注册时直接 return
	]]
	local function registerBagSync()
		if bagSyncRegistered then
			return
		end
		bagSyncRegistered = true
		PlayerData.ListenClientSync(function(key: string | { string }?, _value: any)
			if key == nil or key == "Bag" or (type(key) == "table" and key[1] == "Bag") then
				if equipTitleRebuild then
					equipTitleRebuild()
				end
			end
		end)
	end

	return {
		bindToggleRow = bindToggleRow,
		bindSliderRow = bindSliderRow,
		bindChooseRow = bindChooseRow,
		bindEquipTitleRow = bindEquipTitleRow,
		bindCodeRow = bindCodeRow,
		flushDeferredNvBinds = flushDeferredNvBinds,
		getEquipTitleRebuild = function(): (() -> ())?
			return equipTitleRebuild
		end,
		registerBagSync = registerBagSync,
		collectVisibleRows = _collectVisibleRows,
	}
end

return SettingRowBind
