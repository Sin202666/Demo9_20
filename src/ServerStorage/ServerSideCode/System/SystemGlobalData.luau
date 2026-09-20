--[[
	Module: SystemGlobalData
	Description: 从 DataStore 拉取全局特殊数值并同步到 workspace Instance
	Author: Dev-Framework
	Created: 2026-07-03
	Last Modified: 2026-07-03

	功能：
	- 读取 Player Store 中的全局键（如 GameNextUpdateTime）
	- 同步到 workspace 上对应 NumberValue，供客户端/其他 System 读取

	调用关系：
	- UpdateManager 在 UpdateModule.Start 前调用 Init 注册定时刷新
	- 持久化读取经 SystemDataStore 统一网关

	示例：
	local SystemGlobalData = Utils.SystemGlobalData
	SystemGlobalData.Refresh()
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local InsMgr = Utils.InsMgr
local Log = Utils.Log
local SystemDataStore = Utils.SystemDataStore
local UpdateModule = Utils.UpdateModule

-- ========================================
-- 模块定义
-- ========================================
local SystemGlobalData = {}

-- ========================================
-- 常量定义
-- ========================================
local PLAYER_STORE = SystemDataStore.STORE.Player
local STORE_KEYS = SystemDataStore.Keys

local LOAD_STORE_OPTIONS = {
	maxTries = 1,
	retryIntervalSec = 0,
}

-- storeKey 与 workspace Instance 名称一致的全局数值配置
local GLOBAL_VALUE_ENTRIES = {
	{
		storeKey = STORE_KEYS.GLOBAL_GAME_NEXT_UPDATE,
		instanceName = STORE_KEYS.GLOBAL_GAME_NEXT_UPDATE,
		className = "NumberValue",
	},
}

-- ========================================
-- 私有变量
-- ========================================
local _initialized = false

-- ========================================
-- 公共函数
-- ========================================

--[[
	从 DataStore 拉取并刷新 workspace 上的全局特殊数值

	@return nil - 读取失败时将对应 Value 置 0 并 Log
]]
function SystemGlobalData.Refresh()
	for _, entry in pairs(GLOBAL_VALUE_ENTRIES) do
		local specialData: NumberValue = InsMgr.GetIns(entry.instanceName, entry.className, workspace)
		local success, data, loadErr = SystemDataStore.Get(PLAYER_STORE, entry.storeKey, LOAD_STORE_OPTIONS)

		if success and data then
			specialData.Value = data
		else
			if not success then
				Log.warn("SystemGlobalData.Refresh failed:", entry.storeKey, loadErr)
			end
			specialData.Value = 0
		end
	end
end

-- ========================================
-- 初始化
-- ========================================

--[[
	注册全局特殊数值定时刷新，由 UpdateManager 在 Start 前调用一次

	@return nil
]]
function SystemGlobalData.Init()
	if _initialized then
		return
	end
	_initialized = true

	UpdateModule.Register(UpdateModule.INTERVAL.SEC_120, function(_elapsed: number)
		SystemGlobalData.Refresh()
	end, { spawn = true, initialElapsed = UpdateModule.INTERVAL.SEC_120 })
end

return SystemGlobalData
