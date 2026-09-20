--[[
	Module: ClockManager
	Description: 客户端时钟管理器，消费服端权威时刻与 LightingBaseline
	Author: 林奥宇
	Created: 2026-01-23
	Last Modified: 2026-09-01

	功能：
	- 监听 Lighting.LightingBaseline，触发 LIGHTING_BASELINE_CHANGE（天气基线）
	- 监听 Lighting.ClockAuthority，触发 CLOCK_CHANGE（客户端写入视觉 Lighting.ClockTime）
	- 不再本地 random 夜晚变体；不写权威值；不直写 Lighting.ClockTime
	- 不与技能/副本 lease 抢槽：有更高 lease 时只更新世界基线，释放后自动 reconcile
	- 依赖服务端 ClockManager 创建并更新 ClockAuthority / LightingBaseline

	模块关系：
	- 服务端 ClockManager：唯一写 ClockAuthority / TimeSlot / LightingBaseline
	- 本脚本：只读 Instance → Bindable；不掷骰、不写权威
	- LightingManager / SystemLightingWeather：消费 Bindable，写视觉钟与天气通道
	- AddListen.NumValueAdd 注册时会立即回调当前值，覆盖 LightingManager 启动兜底之后的后续变化

	加载方式：
	- StarterPlayerScripts/Manager 自动运行的 LocalScript，不经 Utils 引用
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

	配置（GameConfig.Clock）：
	- 启用：false 时本 Manager 不运行，避免 WaitForChild 永久阻塞
	- 光照切换秒：Baseline 变化时天气过渡时长（非法则回退 5）
	- ClockAuthority / LightingBaseline 等待超时 30s：超时则 Log.warn 并降级退出（不注册监听）

	典型用法：
	- Clock.启用 = false：与服端一并关闭，本脚本直接 return
	- 权威每 UPDATE_INTERVAL 推进时，CLOCK_CHANGE 以 transitionTime=0 连续跟写视觉钟

	生命周期：Value 监听为客户端会话级连接，不解绑（可接受）
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local SystemGameConfig = Utils.SystemGameConfig
local Log = Utils.Log
local AddListen = Utils.AddListen
local NetMsg = Utils.NetMsg
local NetWork = Utils.NetWork
local Lighting = Utils.Lighting

-- ========================================
-- 常量
-- ========================================

local WAIT_TIMEOUT_SEC = 30
local DEFAULT_LIGHTING_TRANSITION = 5
local CLOCK_FOLLOW_TRANSITION_SEC = 0
local INST_LIGHTING_BASELINE = "LightingBaseline"
local INST_CLOCK_AUTHORITY = "ClockAuthority"

if SystemGameConfig.GetValue({ "Clock", "启用" }) == false then
	return
end

-- ========================================
-- 运行配置
-- ========================================

local LIGHTING_TRANSITION_SEC = SystemGameConfig.GetValue({ "Clock", "光照切换秒" })
if typeof(LIGHTING_TRANSITION_SEC) ~= "number" or LIGHTING_TRANSITION_SEC < 0 then
	Log.warn("ClockManager: 光照切换秒非法，使用默认值", LIGHTING_TRANSITION_SEC, DEFAULT_LIGHTING_TRANSITION)
	LIGHTING_TRANSITION_SEC = DEFAULT_LIGHTING_TRANSITION
end

-- ========================================
-- 等待服端权威 Instance
-- ========================================

local lightingBaselineInst = Lighting:WaitForChild(INST_LIGHTING_BASELINE, WAIT_TIMEOUT_SEC)
if not lightingBaselineInst or not lightingBaselineInst:IsA("StringValue") then
	Log.warn("ClockManager: 等待 LightingBaseline 超时，时钟/基线监听降级关闭", WAIT_TIMEOUT_SEC)
	return
end

local clockAuthorityInst = Lighting:WaitForChild(INST_CLOCK_AUTHORITY, WAIT_TIMEOUT_SEC)
if not clockAuthorityInst or not clockAuthorityInst:IsA("NumberValue") then
	Log.warn("ClockManager: 等待 ClockAuthority 超时，时钟/基线监听降级关闭", WAIT_TIMEOUT_SEC)
	return
end

local lightingBaseline: StringValue = lightingBaselineInst
local clockAuthority: NumberValue = clockAuthorityInst

-- ========================================
-- 私有函数
-- ========================================

--[[
	LightingBaseline 变化：转发天气基线（过渡秒来自配置）
	@param baselineName string - 服端发布的 LightingConfig 名
	@return nil - 无返回值
]]
local function _onLightingBaselineChanged(baselineName: string)
	if typeof(baselineName) ~= "string" or baselineName == "" then
		return
	end
	NetWork.FireBindable(NetMsg.LIGHTING_BASELINE_CHANGE, baselineName, LIGHTING_TRANSITION_SEC)
end

--[[
	ClockAuthority 变化：连续跟写视觉钟（transitionTime=0，由 LightingManager → setClockTime）
	@param clockTime number - 服端权威逻辑时刻
	@return nil - 无返回值
]]
local function _onClockAuthorityChanged(clockTime: number)
	if typeof(clockTime) ~= "number" then
		return
	end
	NetWork.FireBindable(NetMsg.CLOCK_CHANGE, clockTime, CLOCK_FOLLOW_TRANSITION_SEC)
end

-- ========================================
-- 事件绑定（会话级）
-- ========================================

local _baselineConn = AddListen.NumValueAdd(lightingBaseline, _onLightingBaselineChanged)
local _clockConn = AddListen.NumValueAdd(clockAuthority, _onClockAuthorityChanged)
