--[[
	Module: BackpackLock
	Description: 仓库锁定模式 UI（单击切 lock；锁定全部/解锁全部由服扫包）
	Author: 林奥宇
	Created: 2026-09-04
	Last Modified: 2026-09-04

	流程：
	- 平常：仅显示「锁定状态」；隐藏锁定全部/解锁全部/回退
	- 进入锁定模式：隐藏页签与锁定状态；显示锁定全部/解锁全部/回退
	- 单击格子：发 BAG_LOCK_ITEMS 单条；不改 PlayerData
	- 锁定全部/解锁全部：只发 mode，不发 onlyID 全表
	- 回退或关闭仓库：退出模式（不撤销已发服变更）
	- V2 无炼金保护

	加载：
		local Lock = require(script.Parent.Lock)
		Lock.bind(uiRefs, hooks)
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local AllUI = require(script.Parent.AllUI)

local AddListen = Utils.AddListen
local EnumMgr = Utils.EnumMgr
local GetData = Utils.GetData
local NetMsg = Utils.NetMsg
local NetWork = Utils.NetWork
local TranslationHelper = Utils.TranslationHelper
local Log = Utils.Log

local BagCapacity = GetData.BagCapacity

local BackpackLock = {}

local lockUi: AllUI.LockUiRefs? = nil
local tabContainer: Frame? = nil
local active = false
local onModeChanged: (() -> ())? = nil
local onLockIntent: ((onlyID: number, wantLock: boolean) -> ())? = nil
local onLockAllIntent: ((wantLock: boolean) -> ())? = nil

-- ========================================
-- 私有函数
-- ========================================

--[[
	同步锁定区显隐

	@return nil
]]
local function _refreshChrome(): ()
	if not lockUi then
		return
	end
	if tabContainer then
		tabContainer.Visible = not active
	end
	lockUi.statusFrame.Visible = not active
	lockUi.lockAllFrame.Visible = active
	lockUi.unlockAllFrame.Visible = active
	lockUi.backFrame.Visible = active
	if lockUi.listLayout then
		lockUi.listLayout.HorizontalAlignment = if active
			then Enum.HorizontalAlignment.Left
			else Enum.HorizontalAlignment.Right
	end
end

--[[
	进入锁定模式

	@return nil
]]
local function _enterLockMode(): ()
	if active or not lockUi then
		return
	end
	active = true
	_refreshChrome()
	if onModeChanged then
		onModeChanged()
	end
end

--[[
	退出锁定模式

	@return nil
]]
local function _exitLockMode(): ()
	if not active then
		_refreshChrome()
		return
	end
	active = false
	_refreshChrome()
	if onModeChanged then
		onModeChanged()
	end
end

-- ========================================
-- 公共函数
-- ========================================

--[[
	是否处于锁定模式

	@return boolean - 锁定模式中为 true
]]
function BackpackLock.isActive(): boolean
	return active
end

--[[
	锁定模式下点击格子：切换 lock 意图（不写 PlayerData）

	@param onlyID number - Bag onlyID
	@param entry table? - 展示用条目
	@return boolean - 已处理为 true
]]
function BackpackLock.tryHandleSlotClick(onlyID: number, entry: any?): boolean
	if not active then
		return false
	end
	if onlyID <= 0 then
		return true
	end
	if type(entry) ~= "table" or not BagCapacity.IsFilterType(BagCapacity.Filter.Window, entry.tp) then
		return true
	end
	local locked = entry.lock == EnumMgr.BagLock.Locked or entry.lock == true
	local wantLock = not locked
	NetWork.FireServer(NetMsg.BAG_LOCK_ITEMS, {
		onlyID = onlyID,
		isLock = if wantLock then 1 else 0,
	})
	if onLockIntent then
		onLockIntent(onlyID, wantLock)
	end
	return true
end

--[[
	仓库关闭时退出锁定模式

	@return nil
]]
function BackpackLock.onWarehouseClosed(): ()
	if active then
		_exitLockMode()
	end
end

--[[
	绑定锁定区按钮

	@param uiRefs AllUI.BackpackUiRefs - UI 引用
	@param hooks { onModeChanged: () -> (), onLockIntent: (number, boolean) -> (), onLockAllIntent: (boolean) -> () } - 回调
	@return nil
]]
function BackpackLock.bind(
	uiRefs: AllUI.BackpackUiRefs,
	hooks: {
		onModeChanged: () -> (),
		onLockIntent: (number, boolean) -> (),
		onLockAllIntent: (boolean) -> (),
	}
): ()
	lockUi = uiRefs.lockUi
	tabContainer = uiRefs.tabContainer
	onModeChanged = hooks.onModeChanged
	onLockIntent = hooks.onLockIntent
	onLockAllIntent = hooks.onLockAllIntent
	active = false

	if not lockUi then
		Log.warn("[BackpackLock] lockUi missing, skip bind")
		return
	end

	local statusBtn = AllUI.findSlotButton(lockUi.statusFrame, "lock:status")
	if statusBtn then
		AddListen.AddMouseClick(statusBtn, function()
			_enterLockMode()
		end, lockUi.statusFrame)
	end

	local lockAllBtn = AllUI.findSlotButton(lockUi.lockAllFrame, "lock:lockAll")
	if lockAllBtn then
		AddListen.AddMouseClick(lockAllBtn, function()
			if not active then
				return
			end
			NetWork.FireServer(NetMsg.BAG_LOCK_ITEMS, { mode = EnumMgr.BagLockMode.LockAll })
			if onLockAllIntent then
				onLockAllIntent(true)
			end
		end, lockUi.lockAllFrame)
	end

	local unlockAllBtn = AllUI.findSlotButton(lockUi.unlockAllFrame, "lock:unlockAll")
	if unlockAllBtn then
		AddListen.AddMouseClick(unlockAllBtn, function()
			if not active then
				return
			end
			NetWork.FireServer(NetMsg.BAG_LOCK_ITEMS, { mode = EnumMgr.BagLockMode.UnlockAll })
			if onLockAllIntent then
				onLockAllIntent(false)
			end
		end, lockUi.unlockAllFrame)
	end

	local backBtn = AllUI.findSlotButton(lockUi.backFrame, "lock:back")
	if backBtn then
		AddListen.AddMouseClick(backBtn, function()
			_exitLockMode()
		end, lockUi.backFrame)
	end

	_refreshChrome()
	local statusLabel = lockUi.statusFrame:FindFirstChildWhichIsA("TextLabel", true)
	if statusLabel then
		TranslationHelper.SetText(statusLabel, "锁定状态")
	end
	local lockAllLabel = lockUi.lockAllFrame:FindFirstChildWhichIsA("TextLabel", true)
	if lockAllLabel then
		TranslationHelper.SetText(lockAllLabel, "锁定全部")
	end
	local unlockAllLabel = lockUi.unlockAllFrame:FindFirstChildWhichIsA("TextLabel", true)
	if unlockAllLabel then
		TranslationHelper.SetText(unlockAllLabel, "解锁全部")
	end
	local backLabel = lockUi.backFrame:FindFirstChildWhichIsA("TextLabel", true)
	if backLabel then
		TranslationHelper.SetText(backLabel, "回退")
	end
end

return BackpackLock
