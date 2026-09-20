--[[
	Module: ObjectPoolManager
	Description: 客户端对象池管理器，启动时初始化池并定期清理空闲实例
	Author: 中台组 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-07-03

	功能：
	- 启动时调用 ObjectPoolUtil.Init()，创建 ReplicatedStorage.ObjectPool 并重建空闲索引
	- Heartbeat 累计计时，按间隔调用 ObjectPoolUtil.clearIdleObjects()

	依赖：
	- Utils.ObjectPoolUtil：借还/清理实现见 ToolSystem/ObjectPoolUtil.luau

	说明：
	- CLEAR_INTERVAL 取 ObjectPoolUtil.CLEAR_IDLE_TIME，勿再抄写秒数
	- 业务借还请用 ObjectPoolUtil / ResourceUtil / AssetAcquire，勿直接操作池文件夹
]]

local RunService = game:GetService("RunService")

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local ObjectPoolUtil = Utils.ObjectPoolUtil

-- ========================================
-- 常量
-- ========================================
local CLEAR_INTERVAL = ObjectPoolUtil.CLEAR_IDLE_TIME

-- ========================================
-- 私有变量
-- ========================================
local _elapsedTime = 0

-- ========================================
-- 私有函数
-- ========================================

--[[
	Heartbeat 回调：累计计时并触发空闲对象清理
	@param deltaTime number - 距上一帧间隔（秒）
	@return nil - 无返回值
]]
local function _onHeartbeat(deltaTime: number)
	_elapsedTime += deltaTime

	if _elapsedTime >= CLEAR_INTERVAL then
		_elapsedTime = 0
		ObjectPoolUtil.clearIdleObjects()
	end
end

-- ========================================
-- 初始化
-- ========================================
ObjectPoolUtil.Init()
RunService.Heartbeat:Connect(_onHeartbeat)
