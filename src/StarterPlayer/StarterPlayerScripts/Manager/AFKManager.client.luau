--[[
	Module: AFKManager
	Description: 挂机管理器（客户端），检测玩家长时间无输入后请求服务端传送
	Author: 林奥宇
	Created: 2026-07-03
	Last Modified: 2026-09-01

	功能：
	- 监听 LocalPlayer.Idled，超过 GameConfig.AFK.挂机超时秒 后 FireServer AFK_MOVE（单次；恢复操作后重置）
	- 空闲低于 GameConfig.AFK.空闲重置秒 时清除已上报标记，允许再次触发
	- 配置非法或 ≤0 时回落缺省（超时 18 分钟、重置 60 秒）并 Log.warn

	与 AFKManager.server / SystemTeleport / PlayerManager 关系：
	- 本脚本仅上报 AFK 事件；传送、限频与重试由服务端 AFKManager → SystemTeleport 执行
	- 挂机重连复位（TeleportData.afkRestore）由服端采集、PlayerManager 落地；客户端不写位姿

	加载方式：
	- 本文件是 StarterPlayerScripts LocalScript，客户端自动运行
	- 不是 Utils 模块，禁止 require；不要写 Utils.AFKManager

	配置（GameConfig.AFK）：
	- 挂机超时秒：连续无输入达到该秒数后上报；缺省 60*18
	- 空闲重置秒：idleTime 低于该值时清除已上报标记；缺省 60

	约定：
	- 启动即绑定 Idled，无 Init() / 模块表
	- 不校验空闲真实性（客上报不可信）；服端限频 60 秒 1 次并再校验在线/传送中
	- 会话结束随 LocalScript 销毁自动断开 Idled 连接

	示例：
	- 玩家无输入超过挂机超时秒 → FireServer(NetMsg.AFK_MOVE) 一次
	- 玩家恢复操作使 idleTime 低于空闲重置秒 → 清除标记，可再次上报
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local Log = Utils.Log
local LocalPlayer = Utils.LocalPlayer
local NetMsg = Utils.NetMsg
local NetWork = Utils.NetWork
local SystemGameConfig = Utils.SystemGameConfig

-- ============================================================================
-- 常量
-- ============================================================================

local DEFAULT_AFK_TIME = 60 * 18
local DEFAULT_IDLE_RESET = 60
local CONFIG_PATH_TIMEOUT = table.freeze({ "AFK", "挂机超时秒" })
local CONFIG_PATH_IDLE_RESET = table.freeze({ "AFK", "空闲重置秒" })

-- ============================================================================
-- 私有变量
-- ============================================================================

local _afkRequested = false
local _afkTime = DEFAULT_AFK_TIME
local _idleResetThreshold = DEFAULT_IDLE_RESET

-- ============================================================================
-- 私有函数
-- ============================================================================

--[[
	读取 GameConfig 正数；非法或 ≤0 时回落缺省并打日志
	@param path {string} - SystemGameConfig.GetValue 嵌套键，如 {"AFK", "挂机超时秒"}
	@param fallback number - 配置缺失或非法时使用的正数缺省
	@return number - 有效正数配置，或 fallback
]]
local function _getConfigNumber(path: { string }, fallback: number): number
	local value = SystemGameConfig.GetValue(path)
	if typeof(value) == "number" and value > 0 then
		return value
	end
	Log.warn("AFKManager: 配置非法，使用缺省", table.concat(path, "."), value, fallback)
	return fallback
end

--[[
	Idled 回调：超时后单次上报 AFK_MOVE，玩家恢复输入后允许再次触发
	@param idleTime number - 引擎给出的连续无输入秒数
	@return nil - 无返回值；非 number 或已上报则直接返回
]]
local function _onIdled(idleTime: number)
	if typeof(idleTime) ~= "number" then
		return
	end
	if idleTime > _afkTime then
		if _afkRequested then
			return
		end
		_afkRequested = true
		NetWork.FireServer(NetMsg.AFK_MOVE)
	elseif idleTime < _idleResetThreshold then
		_afkRequested = false
	end
end

-- ============================================================================
-- 初始化
-- ============================================================================

_afkTime = _getConfigNumber(CONFIG_PATH_TIMEOUT, DEFAULT_AFK_TIME)
_idleResetThreshold = _getConfigNumber(CONFIG_PATH_IDLE_RESET, DEFAULT_IDLE_RESET)
LocalPlayer.Idled:Connect(_onIdled)
