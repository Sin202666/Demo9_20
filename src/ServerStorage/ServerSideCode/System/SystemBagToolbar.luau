--[[
	Module: SystemBagToolbar
	Description: 背包快捷栏拖拽 Remote（只调 SystemBag.SetEquip / SwapToolbarSlots，不写 PlayerData）
	Author: 林奥宇
	Created: 2026-09-04
	Last Modified: 2026-09-04

	功能：
	- BACKPACK_TOOLBAR_DRAG：栏内互换、栏→仓库卸下、仓库→栏装备
	- 校验 Filter.Toolbar；Pet/蛋/坐骑拖到栏由服拒绝
	- 不处理手持、不调 Mount/Pet 出战

	与 SystemBag 的关系：
	- 本模块不写 Bag.equip；唯一写口是 SystemBag.SetEquip
	- 不订阅入包、不回调 AddItems
	- Init 由 PlayerManager 调用一次；「背包UI.启用」= false 时不注册 Remote
	- ApplyBackpackDrag 同样自检开关

	配置（GameConfig.背包UI.启用）：
	- false：不注册 BACKPACK_TOOLBAR_DRAG；拖拽 API 拒绝。不关 SystemBag 库存写口

	加载方式（仅服务端）：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local SystemBagToolbar = Utils.SystemBagToolbar
		SystemBagToolbar.Init()

	使用示例：
		local ok, err = SystemBagToolbar.ApplyBackpackDrag(plr, from, to)
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local EnumMgr = Utils.EnumMgr
local GetData = Utils.GetData
local Log = Utils.Log
local NetMsg = Utils.NetMsg
local NetWork = Utils.NetWork
local RequestRateLimit = Utils.RequestRateLimit
local SystemBag = Utils.SystemBag
local SystemGameConfig = Utils.SystemGameConfig

local BagCapacity = GetData.BagCapacity
local BagView = GetData.BagView

local SystemBagToolbar = {}

-- ========================================
-- 常量定义
-- ========================================
local EQUIP_WAREHOUSE = 0
local RATE_DRAG_MAX = 12
local RATE_DRAG_WINDOW_SEC = 1
local ERROR_INVALID_PARAM = "INVALID_PARAM"
local ERROR_NOT_FOUND = "NOT_FOUND"
local BAG_UI_ENABLED_PATH = { "背包UI", "启用" }

export type BackpackDragZone = {
	zone: string,
	equipSlot: number?,
	onlyID: number?,
}

local _initialized = false

-- ========================================
-- 私有函数
-- ========================================

--[[
	解析栏槽（须 1~N）

	@param raw any - 客机 equipSlot
	@return number? - 合法槽；非法 nil
]]
local function _parseToolbarSlot(raw: any): number?
	local slot = math.floor(tonumber(raw) or 0)
	if not BagCapacity.IsToolbarEquipSlot(slot) then
		return nil
	end
	return slot
end

-- ========================================
-- 公共函数
-- ========================================

--[[
	背包 UI 开关（GameConfig「背包UI.启用」；缺键视为开）
	@return boolean - true 表示启用拖拽 Remote
]]
function SystemBagToolbar.IsEnabled(): boolean
	return SystemGameConfig.GetValue(BAG_UI_ENABLED_PATH) ~= false
end

--[[
	处理拖拽落点（栏内互换 / 卸下 / 装备）

	@param plr Player - 玩家对象
	@param from table - { zone, equipSlot?, onlyID? }
	@param to table - { zone, equipSlot?, onlyID? }
	@return boolean, string? - 成功 true；失败 false 与 INVALID_PARAM / NOT_FOUND / SetEquip 错误码
]]
function SystemBagToolbar.ApplyBackpackDrag(plr: Player, from: BackpackDragZone, to: BackpackDragZone): (boolean, string?)
	if not SystemBagToolbar.IsEnabled() then
		return false, ERROR_INVALID_PARAM
	end
	if not plr or type(from) ~= "table" or type(to) ~= "table" then
		return false, ERROR_INVALID_PARAM
	end

	local zoneToolbar = EnumMgr.BagDragZone.Toolbar
	local zoneWarehouse = EnumMgr.BagDragZone.Warehouse
	local fromZone = from.zone
	local toZone = to.zone

	if fromZone == zoneToolbar and toZone == zoneToolbar then
		local slotA = _parseToolbarSlot(from.equipSlot)
		local slotB = _parseToolbarSlot(to.equipSlot)
		if not slotA or not slotB then
			return false, ERROR_INVALID_PARAM
		end
		return SystemBag.SwapToolbarSlots(plr, slotA, slotB)
	end

	if fromZone == zoneToolbar and toZone == zoneWarehouse then
		local slot = _parseToolbarSlot(from.equipSlot)
		if not slot then
			return false, ERROR_INVALID_PARAM
		end
		local item = BagView.QueryToolbarSlot(plr, slot)
		if not item then
			return true
		end
		local onlyID = tonumber(item.onlyID) or 0
		if onlyID <= 0 then
			return false, ERROR_NOT_FOUND
		end
		return SystemBag.SetEquip(plr, onlyID, EQUIP_WAREHOUSE)
	end

	if fromZone == zoneWarehouse and toZone == zoneToolbar then
		local onlyID = tonumber(from.onlyID) or 0
		local slot = _parseToolbarSlot(to.equipSlot)
		if onlyID <= 0 or not slot then
			return false, ERROR_INVALID_PARAM
		end
		local item = SystemBag.GetItemByOnlyID(plr, onlyID)
		if type(item) ~= "table" then
			return false, ERROR_NOT_FOUND
		end
		if not BagCapacity.IsFilterType(BagCapacity.Filter.Toolbar, item.tp) then
			Log.warn("[SystemBagToolbar] refuse warehouse->toolbar non-toolbar", plr.UserId, item.tp)
			return false, ERROR_INVALID_PARAM
		end
		return SystemBag.SetEquip(plr, onlyID, slot)
	end

	return false, ERROR_INVALID_PARAM
end

--[[
	注册拖拽 Remote 与限频（幂等；由 PlayerManager.Init 调用）

	@return nil
]]
function SystemBagToolbar.Init(): ()
	if _initialized then
		return
	end
	if not SystemBagToolbar.IsEnabled() then
		return
	end
	_initialized = true

	if RequestRateLimit and RequestRateLimit.SetRateLimitConfig then
		RequestRateLimit.SetRateLimitConfig(NetMsg.BACKPACK_TOOLBAR_DRAG, {
			maxRequests = RATE_DRAG_MAX,
			timeWindow = RATE_DRAG_WINDOW_SEC,
		})
	end

	NetWork.RegisterServerRemoteEvent(NetMsg.BACKPACK_TOOLBAR_DRAG, function(player: Player, data: any)
		if not player or not player.Parent then
			return
		end
		if type(data) ~= "table" then
			return
		end
		local from = data.from
		local to = data.to
		if type(from) == "table" and type(to) == "table" then
			SystemBagToolbar.ApplyBackpackDrag(player, from, to)
		end
	end)
end

--[[
	兼容旧调用：转发 Init

	@return nil
]]
function SystemBagToolbar.RegisterNetWork(): ()
	SystemBagToolbar.Init()
end

return SystemBagToolbar
