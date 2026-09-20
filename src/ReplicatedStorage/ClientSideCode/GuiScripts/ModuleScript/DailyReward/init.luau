--[[
	Module: DailyReward
	Description: 每日签到弹窗——Login 树展示；按 DailyWeekID 渲染格子、24h 冷却与 Remote 领取
	Author: 林奥宇
	Created: 2026-01-29
	Last Modified: 2026-09-04

	功能：
	- DailyWeekID 变化时重建小格克隆 + 第 7 天 BigTemp
	- updateUi：按 NextDailyID / LastDailyTime 刷新已领、可领、UnBg 冷却
	- openUi / closeUi：主界面显隐；可见时每秒刷新当前天冷却（closeUi 不 PopBack）
	- 领取：仅当前可领格 Btns.ClaimBtn.Btn → InvokeServer(CLAIM_DAILY_AWARD)，不传 dayId
	- 已领不藏 ClaimBtn，改 UnBg + Key「已领取」；领成功立刻按 dayId+1 刷新（不等 NumberValue 复制）
	- 领成功不关窗；半透明屏蔽层不关窗；Right 整栏隐藏

	模块关系：
	- 展示与发 Remote；结算权威在 SystemDailyAward（先写标志再入包，失败回滚）
	- 由 UIManager 按 Frame.Name 动态 require；关窗走 SHOW_LOCAL_UI false
	- 顶栏入口 TopBarManager；冷却与最大天数读 SystemGameConfig「每日签到」
	- AllUI：Login 结构节点索引（根名 DailyReward）

	约定：
	- ScreenGui.DailyReward 为 Login 树（Main._LoginFrame.SmallTemp._Temp / _BigTemp）
	- 数量前缀 "x"、倒计时走 SetRawText；天数 Key「签到天数」；标题 Key「每日签到标题」；已领 UnBg Key「已领取」；未来天 UnBg Key「未解锁」
	- UIManager 示例刷新载荷 { day = 1 } 不含存档字段，不得覆盖 LastDailyTime
	- 格子本体是 TextButton：Active=false，只绑内层 ClaimBtn.Btn

	加载（UIManager 动态 require）：
		local DailyReward = require(...ModuleScript.DailyReward)
		DailyReward:updateUi()
		DailyReward:openUi()
]]

-- ========================================
-- 服务引用
-- ========================================
local Workspace = game:GetService("Workspace")

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local CfgFind = Utils.CfgFind
local MathMgr = Utils.MathMgr
local EnumMgr = Utils.EnumMgr
local AddListen = Utils.AddListen
local UIMgr = Utils.UIMgr
local TimeTransfer = Utils.TimeTransfer
local PlayerData = Utils.PlayerData
local SystemGameConfig = Utils.SystemGameConfig
local NetMsg = Utils.NetMsg
local NetWork = Utils.NetWork
local LocalPlayer = Utils.LocalPlayer
local TranslationHelper = Utils.TranslationHelper
local Log = Utils.Log

local AllUI = require(script.AllUI)

-- ========================================
-- 模块定义
-- ========================================
local DailyReward = {}

-- ========================================
-- 常量定义
-- ========================================
local DAILY_INTERVAL_HOURS_PATH = { "每日签到", "每日奖励领取间隔" }
local MAX_DAILY_DAYS_PATH = { "每日签到", "每日签到最大天数" }

local STAT_LAST_DAILY_TIME = "LastDailyTime"
local STAT_NEXT_DAILY_ID = "NextDailyID"
local STAT_DAILY_WEEK_ID = "DailyWeekID"

local UI_NAME = "DailyReward"
local SECONDS_PER_HOUR = 3600
local CLAIM_REMAIN_INTERVAL_SEC = 1
local WAIT_CHILD_TIMEOUT = math.huge
local DEFAULT_MAX_DAILY_DAY = 7
local DEFAULT_INTERVAL_HOURS = 24
-- 第 7 天用 BigTemp，不进 SmallTemp 克隆
local SPECIAL_DAY_SLOT = 7
local TEMPLATE_SLOT_NAME = "_Temp"
local ASSET_ID_PREFIX = "rbxassetid://"

local CHILD_ICON = "Icon"
local CHILD_VIEWPORT = "ViewportFrame"
local CHILD_DAY = "Day"
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

local intervalHours = tonumber(SystemGameConfig.GetValue(DAILY_INTERVAL_HOURS_PATH)) or DEFAULT_INTERVAL_HOURS
local maxDailyDay = tonumber(SystemGameConfig.GetValue(MAX_DAILY_DAYS_PATH)) or DEFAULT_MAX_DAILY_DAY
if maxDailyDay < 1 then
	maxDailyDay = DEFAULT_MAX_DAILY_DAY
end

local DAILY_COOLDOWN_SEC: number = intervalHours * SECONDS_PER_HOUR
local MAX_DAILY_REWARD_DAY: number = maxDailyDay

-- ========================================
-- 私有变量
-- ========================================
local UI: Frame = AllUI.UIRoot
local Temp: TextButton = AllUI.Temp
local BigTemp: TextButton = AllUI.BigTemp
local SmallTemp: Frame = Temp.Parent :: Frame
local ExitFrame: Frame = AllUI.Exit
local TitleLabel: TextLabel = AllUI.Title
local RightFrame: Frame = AllUI.Right

local _signVt: { [number]: GuiObject } = {}
local _lastDailyTime = 0
local _nextDailyId = 0
local _claimPending = false
local _bigClaimBound = false
local _remainThread: thread? = nil
local _countdownToken = 0
local _connections: { RBXScriptConnection } = {}

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
	@param slot GuiObject - Temp / BigTemp / 克隆
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
	@param iconId number | string - 配置表 Icon / BtnIcon
	@return string - rbxassetid:// 完整串
]]
local function _toAssetUri(iconId: number | string): string
	return ASSET_ID_PREFIX .. tostring(iconId)
end

--[[
	取格子直接子 GuiObject
	@param slot GuiObject - 格子
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
	取 Btns.ClaimBtn 容器
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
	当前冷却剩余秒；从未领取或已过冷却为 0
	@return number - 剩余秒（≥0）
]]
local function _getCooldownRemainSec(): number
	if _lastDailyTime <= 0 then
		return 0
	end
	local remain = DAILY_COOLDOWN_SEC - (Workspace:GetServerTimeNow() - _lastDailyTime)
	if remain < 0 then
		return 0
	end
	return remain
end

--[[
	从玩家缓存或调用方载荷读取签到字段；载荷缺字段时不覆盖缓存
	@param uiData table? - UIManager 传入的刷新表；可缺 NextDailyID / LastDailyTime
	@return number - 下一可领天数（缺省 0，已领判定为 day < 该值）
	@return number - LastDailyTime；载荷与缓存都缺时为当前 _lastDailyTime
]]
local function _readSignSnapshot(uiData: any?): (number, number)
	local plrData = PlayerData.GetPlrData(LocalPlayer)
	local nextDailyId: number? = nil
	local lastDailyTime: number? = nil

	if type(uiData) == "table" then
		nextDailyId = tonumber(uiData[STAT_NEXT_DAILY_ID])
		lastDailyTime = tonumber(uiData[STAT_LAST_DAILY_TIME])
	end
	if type(plrData) == "table" then
		if nextDailyId == nil then
			nextDailyId = tonumber(plrData[STAT_NEXT_DAILY_ID])
		end
		if lastDailyTime == nil then
			lastDailyTime = tonumber(plrData[STAT_LAST_DAILY_TIME])
		end
	end

	return nextDailyId or 0, lastDailyTime or _lastDailyTime
end

--[[
	刷新单格领取态（已领 UnBg「已领取」 / 可领 / 冷却 UnBg / 未来天 UnBg「未解锁」）
	@param slot GuiObject - 格子
	@param dayId number - 天数
	@return nil
]]
local function _refreshSlotState(slot: GuiObject, dayId: number)
	local canClaimMark = _child(slot, CHILD_CAN_CLAIM)
	local claimedMark = _child(slot, CHILD_HAS_CLAIMED)
	local claimRoot = _getClaimBtnRoot(slot)
	local bg = if claimRoot then claimRoot:FindFirstChild(CHILD_BG) else nil
	local unBg = if claimRoot then claimRoot:FindFirstChild(CHILD_UN_BG) else nil
	local unBgText = if unBg and unBg:IsA("GuiObject") then unBg:FindFirstChild(CHILD_UN_BG_TEXT) else nil

	local function _setClaimVisual(showCanClaim: boolean, showClaimed: boolean, showClaimBtn: boolean, useBg: boolean)
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
			unBg.Visible = showClaimBtn and not useBg
		end
	end

	if dayId < _nextDailyId then
		_setClaimVisual(false, false, true, false)
		if unBgText and unBgText:IsA("TextLabel") then
			TranslationHelper.SetText(unBgText, "已领取")
		end
		return
	end

	if dayId == _nextDailyId then
		local remain = _getCooldownRemainSec()
		if remain > 0 then
			_setClaimVisual(false, false, true, false)
			if unBgText and unBgText:IsA("TextLabel") then
				TranslationHelper.SetRawText(unBgText, TimeTransfer.FormatTime(remain))
			end
			return
		end
		_setClaimVisual(true, false, true, true)
		return
	end

	_setClaimVisual(false, false, true, false)
	if unBgText and unBgText:IsA("TextLabel") then
		TranslationHelper.SetText(unBgText, "未解锁")
	end
end

--[[
	刷新全部已建格子状态
	@return nil
]]
local function _refreshAllSlotStates()
	for dayIndex = 1, MAX_DAILY_REWARD_DAY do
		local slot = _signVt[dayIndex]
		if slot then
			_refreshSlotState(slot, dayIndex)
		end
	end
end

--[[
	填充格子静态内容（名/数量/第 N 天/图标）
	@param slot GuiObject - 格子
	@param dayIndex number - 天数
	@param dailyCfg table - CfgFind.GetDailyAward 行（AwardID / CountID / BtnIcon）
	@return nil
]]
local function _fillAwardSlot(slot: GuiObject, dayIndex: number, dailyCfg: { [string]: any })
	local awardId = tonumber(dailyCfg.AwardID)
	local awardCfg = awardId and CfgFind.FindCfgByID(awardId) or nil

	local dayLabel = _child(slot, CHILD_DAY)
	if dayLabel then
		TranslationHelper.SetText(dayLabel, "签到天数", { tostring(dayIndex) })
	end

	local nameLabel = _child(slot, CHILD_NAME)
	if nameLabel and awardCfg and awardCfg.ZhName then
		TranslationHelper.SetText(nameLabel, awardCfg.ZhName)
		local xyd = awardCfg.xyd
		if xyd then
			UIMgr.AddGradientColor(tostring(xyd), nameLabel, true)
		end
	end

	local countLabel = _child(slot, CHILD_COUNT)
	if countLabel and countLabel:IsA("TextLabel") then
		local countId = tonumber(dailyCfg.CountID) or 0
		if countId > 1 then
			countLabel.Visible = true
			TranslationHelper.SetRawText(countLabel, "x" .. MathMgr.getNumStr(countId))
		else
			countLabel.Visible = false
		end
	end

	local isPet = awardId ~= nil and CfgFind.FindCfgByID(awardId, EnumMgr.ItemType.Pet) ~= nil
	local viewport = _child(slot, CHILD_VIEWPORT)
	local icon = _child(slot, CHILD_ICON)
	if viewport and icon then
		if isPet then
			viewport.Visible = true
			icon.Visible = false
		else
			viewport.Visible = false
			icon.Visible = true
			if icon:IsA("ImageLabel") then
				local iconId = dailyCfg.BtnIcon or (awardCfg and awardCfg.Icon)
				if iconId then
					icon.Image = _toAssetUri(iconId)
				end
			end
		end
	end

	slot.LayoutOrder = dayIndex
	slot.Name = tostring(dayIndex)
end

--[[
	领取点击：仅当前可领天响应；Remote 不传 dayId；成功立刻切已领样式，不关窗
	@param dayId number - 被点击的天数
	@return nil
]]
local function _onClaimClick(dayId: number)
	if _claimPending then
		return
	end
	if dayId ~= _nextDailyId then
		return
	end
	if _getCooldownRemainSec() > 0 then
		return
	end

	_claimPending = true
	local ok = NetWork.InvokeServer(NetMsg.CLAIM_DAILY_AWARD) == true
	_claimPending = false
	if ok then
		-- Invoke 返回时 PlayerData / NumberValue 可能尚未复制，按本格已领立刻推进，避免仍显示可领
		DailyReward:updateUi({
			[STAT_NEXT_DAILY_ID] = dayId + 1,
			[STAT_LAST_DAILY_TIME] = Workspace:GetServerTimeNow(),
		})
	end
end

--[[
	绑定 ClaimBtn.Btn 点击
	@param slot GuiObject - 格子
	@param dayId number - 天数
	@param track boolean - true 时记入 _connections（BigTemp 常驻）；克隆格随 Destroy 断开
	@return nil
]]
local function _bindClaimClick(slot: GuiObject, dayId: number, track: boolean)
	local btn = _getClaimClickBtn(slot)
	if not btn then
		Log.warn("DailyReward: ClaimBtn.Btn 缺失", dayId)
		return
	end
	local conns = AddListen.AddMouseClick(btn, function()
		_onClaimClick(dayId)
	end, btn)
	if track then
		_trackConnections(conns)
	end
end

--[[
	取第 dayIndex 天的格子：1~6 克隆 _Temp；第 7 天用 BigTemp
	@param dayIndex number - 1..MAX_DAILY_REWARD_DAY
	@return GuiObject? - 可填充的格子；模板缺失时为 nil
]]
local function _resolveSlotFrame(dayIndex: number): GuiObject?
	if dayIndex == SPECIAL_DAY_SLOT then
		return BigTemp
	end
	if not Temp or not SmallTemp then
		return nil
	end
	local clone = Temp:Clone()
	clone.Name = tostring(dayIndex)
	clone.LayoutOrder = dayIndex
	clone.Visible = true
	_disableSlotButton(clone)
	clone.Parent = SmallTemp
	return clone
end

--[[
	清掉 SmallTemp 中数字名克隆（保留 _Temp / 布局），再按当前轮次重建 _signVt
	@param weekId number - DailyWeekID
	@return nil
]]
local function _rebuildAwardSlots(weekId: number)
	if not SmallTemp then
		Log.warn("DailyReward: SmallTemp 缺失，跳过重建")
		return
	end

	for _, child in SmallTemp:GetChildren() do
		if child:IsA("GuiObject") then
			local numericName = tonumber(child.Name)
			if numericName and child.Name ~= TEMPLATE_SLOT_NAME then
				child:Destroy()
			end
		end
	end
	table.clear(_signVt)
	BigTemp.Visible = false

	for dayIndex = 1, MAX_DAILY_REWARD_DAY do
		local dailyCfg = CfgFind.GetDailyAward(weekId, dayIndex)
		if not dailyCfg then
			continue
		end
		local slot = _resolveSlotFrame(dayIndex)
		if not slot then
			Log.warn("DailyReward: 格子节点缺失", dayIndex)
			continue
		end
		_fillAwardSlot(slot, dayIndex, dailyCfg)
		if dayIndex == SPECIAL_DAY_SLOT then
			slot.Visible = true
			_disableSlotButton(slot)
			if not _bigClaimBound then
				_bindClaimClick(slot, dayIndex, true)
				_bigClaimBound = true
			end
		else
			_bindClaimClick(slot, dayIndex, true)
		end
		_signVt[dayIndex] = slot
	end

	DailyReward:updateUi()
end

--[[
	UI 可见时每秒刷格子冷却态；关闭后循环自行退出
	@return nil
]]
local function _runClaimRemainLoop()
	local token = _countdownToken
	while token == _countdownToken and UI.Visible do
		_refreshAllSlotStates()
		task.wait(CLAIM_REMAIN_INTERVAL_SEC)
	end
	_remainThread = nil
end

--[[
	Visible 变为 true 时启动倒计时协程（已在跑则不重复 spawn）
	@return nil
]]
local function _onUiVisibleChanged()
	if not UI.Visible then
		return
	end
	if _remainThread then
		return
	end
	_remainThread = task.spawn(_runClaimRemainLoop)
end

--[[
	停止倒计时协程
	@return nil
]]
local function _stopRemainLoop()
	_countdownToken += 1
	if _remainThread then
		task.cancel(_remainThread)
		_remainThread = nil
	end
end

--[[
	绑定关闭、标题、Right 隐藏、存档 Value 与 Visible
	@return nil
]]
local function _bindUiEvents()
	RightFrame.Visible = false
	Temp.Visible = false
	_disableSlotButton(Temp)
	_disableSlotButton(BigTemp)
	TranslationHelper.SetText(TitleLabel, "每日签到标题")

	local exitBtn = ExitFrame:FindFirstChild(CHILD_EXIT_BTN)
	if exitBtn and exitBtn:IsA("GuiButton") then
		local scaleTarget = ExitFrame:FindFirstChild(CHILD_EXIT_SCALE)
		local scaleBtn: GuiObject = if scaleTarget and scaleTarget:IsA("GuiObject") then scaleTarget else ExitFrame
		_trackConnections(AddListen.AddMouseClick(exitBtn, function()
			NetWork.FireBindable(NetMsg.SHOW_LOCAL_UI, UI_NAME, nil, false)
		end, scaleBtn))
	else
		Log.warn("DailyReward: Exit.Btn 缺失")
	end

	local weekValue = LocalPlayer:WaitForChild(STAT_DAILY_WEEK_ID, WAIT_CHILD_TIMEOUT)
	if weekValue and weekValue:IsA("ValueBase") then
		_trackConnection(AddListen.NumValueAdd(weekValue, function(weekId)
			local numWeek = tonumber(weekId)
			if not numWeek then
				return
			end
			_rebuildAwardSlots(numWeek)
		end))
	end

	local nextValue = LocalPlayer:WaitForChild(STAT_NEXT_DAILY_ID, WAIT_CHILD_TIMEOUT)
	if nextValue and nextValue:IsA("ValueBase") then
		_trackConnection(AddListen.NumValueAdd(nextValue, function()
			DailyReward:updateUi()
		end))
	end

	local lastValue = LocalPlayer:WaitForChild(STAT_LAST_DAILY_TIME, WAIT_CHILD_TIMEOUT)
	if lastValue and lastValue:IsA("ValueBase") then
		_trackConnection(AddListen.NumValueAdd(lastValue, function()
			DailyReward:updateUi()
		end))
	end

	_trackConnection(UI:GetPropertyChangedSignal("Visible"):Connect(_onUiVisibleChanged))
	_onUiVisibleChanged()
end

-- ========================================
-- 公共函数
-- ========================================

--[[
	刷新已领取 / 可领 / UnBg 与内部 LastDailyTime、NextDailyID
	@param uiData table? - 可含 NextDailyID / LastDailyTime；缺字段或 { day = 1 } 时回退 PlayerData
	@return nil
]]
function DailyReward:updateUi(uiData: any?)
	local nextDailyId, lastDailyTime = _readSignSnapshot(uiData)
	_nextDailyId = nextDailyId
	_lastDailyTime = lastDailyTime
	_refreshAllSlotStates()
end

--[[
	打开 UI（主界面隐藏）；立刻刷一次格子态并启动冷却循环
	@return nil
]]
function DailyReward:openUi()
	UIMgr.SetMainUIVisible(false)
	_refreshAllSlotStates()
	_onUiVisibleChanged()
end

--[[
	关闭 UI：停倒计时、先藏窗再按模糊标记恢复主界面（PopBack 由 UIManager 负责）
	@return nil
]]
function DailyReward:closeUi()
	_stopRemainLoop()
	UI.Visible = false
	UIMgr.SetMainUIVisible(nil)
	UIMgr.UpdateBlurVisible()
end

--[[
	断开点击 / 存档 Value / Visible 监听并停倒计时协程
	@return nil
]]
function DailyReward:destroy()
	AddListen.DisconnectAll(_connections)
	_stopRemainLoop()
end

-- ========================================
-- 事件绑定（UIManager 动态 require 时执行；无 Init）
-- ========================================
_bindUiEvents()

return DailyReward
