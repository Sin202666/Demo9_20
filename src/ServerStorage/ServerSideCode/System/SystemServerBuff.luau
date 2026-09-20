--[[
	Module: SystemServerBuff
	Description: 从 DataStore 拉取服务器 BUFF 并同步到 workspace 目录树
	Author: Dev-Framework
	Created: 2026-07-03
	Last Modified: 2026-07-03

	功能：
	- 读取 Player Store 中 ServerBuff 键
	- 刷新 workspace.服务器BUFF 下 NumberValue 树，供客户端 BuffUpdate 等读取

	调用关系：
	- UpdateManager 在 UpdateModule.Start 前调用 Init 注册定时刷新
	- 持久化读取经 SystemDataStore 统一网关

	示例：
	local SystemServerBuff = Utils.SystemServerBuff
	SystemServerBuff.Refresh()
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
local SystemServerBuff = {}

-- ========================================
-- 常量定义
-- ========================================
local PLAYER_STORE = SystemDataStore.STORE.Player
local STORE_KEY_SERVER_BUFF = SystemDataStore.Keys.SERVER_BUFF
local WORKSPACE_BUFF_FOLDER_NAME = "服务器BUFF"

local LOAD_STORE_OPTIONS = {
	maxTries = 1,
	retryIntervalSec = 0,
}

-- ========================================
-- 私有变量
-- ========================================
local _initialized = false

-- ========================================
-- 公共函数
-- ========================================

--[[
	从 DataStore 拉取并刷新 workspace 上的服务器 BUFF

	@return nil - 读取失败时 Log 并提前返回
]]
function SystemServerBuff.Refresh()
	local serverBuffFolder: Folder = InsMgr.GetIns(WORKSPACE_BUFF_FOLDER_NAME, "Folder", workspace)

	local success, data, loadErr = SystemDataStore.Get(PLAYER_STORE, STORE_KEY_SERVER_BUFF, LOAD_STORE_OPTIONS)

	if not success then
		Log.warn("SystemServerBuff.Refresh failed:", loadErr)
		return
	end

	if not data then
		return
	end

	serverBuffFolder:ClearAllChildren()

	for _, buffEntry in pairs(data) do
		local buffName = buffEntry["BuffName"]
		local addPower = buffEntry["AddPower"]
		local endTime = buffEntry["EndTime"]
		local startTime = buffEntry["StartTime"]

		if buffName and addPower and endTime and startTime then
			local addBuffValue: NumberValue = InsMgr.GetIns(buffName, "NumberValue", serverBuffFolder)
			addBuffValue.Value = addPower

			local endTimeValue: NumberValue = InsMgr.GetIns("EndTime", "NumberValue", addBuffValue)
			endTimeValue.Value = endTime

			local startTimeValue: NumberValue = InsMgr.GetIns("StartTime", "NumberValue", addBuffValue)
			startTimeValue.Value = startTime
		end
	end
end

-- ========================================
-- 初始化
-- ========================================

--[[
	注册服务器 BUFF 定时刷新，由 UpdateManager 在 Start 前调用一次

	@return nil
]]
function SystemServerBuff.Init()
	if _initialized then
		return
	end
	_initialized = true

	SystemServerBuff.Refresh()

	UpdateModule.Register(UpdateModule.INTERVAL.SEC_120, function(_elapsed: number)
		SystemServerBuff.Refresh()
	end, { spawn = true, initialElapsed = UpdateModule.INTERVAL.SEC_120 })
end

return SystemServerBuff
