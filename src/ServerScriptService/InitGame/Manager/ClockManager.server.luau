--[[
	Module: ClockManager
	Description: 服务端时钟管理器，发布权威逻辑时刻、TimeSlot 与 LightingBaseline
	Author: 林奥宇
	Created: 2026-01-26
	Last Modified: 2026-09-01

	功能：
	- 规定 1 天有多少秒、有哪些时间段（白天/黑夜等）
	- Lighting.ClockAuthority（NumberValue）：权威逻辑时刻 [0, 24)；不写 Lighting.ClockTime
	- Lighting.TimeSlot：逻辑段（Day / Night），供语义消费
	- Lighting.LightingBaseline：权威天气配置名；客户端只消费不掷骰
	- 进入 Night 时服务端从夜晚天气变体中随机选一；同段内不重掷
	- 视觉 ClockTime 由客户端监听 ClockAuthority 后经 CLOCK_CHANGE 写入

	模块关系：
	- 本脚本是 ClockAuthority / TimeSlot / LightingBaseline 的唯一写者
	- 客户端 ClockManager 只读上述 Instance，转 Bindable（不掷骰、不写权威）
	- LightingManager / SystemLightingWeather 消费 CLOCK_CHANGE 与 LIGHTING_BASELINE_CHANGE，写视觉 Lighting.ClockTime
	- 时钟规则留在本 Manager（Lighting 文档指定的权威发布者）；下沉 SystemClock 须另开方案（结构 §1.8）

	加载方式：
	- InitGame/Manager 自动运行的 Script，不经 Utils 引用
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

	时间段匹配（半开区间 [Min, Max)）：
	- 条件：normalized >= Min and normalized < Max（Max=24 合法，覆盖至日界）
	- 段名按字典序匹配，避免 pairs 顺序导致重叠配置时结果不稳定
	- 默认 Day=[6,18)，Night=[0,6)∪[18,24)；6→Day、18→Night，边界不双命中

	配置（GameConfig.Clock）：
	- 启用：false 时本 Manager 不运行，不创建 ClockAuthority / TimeSlot / LightingBaseline
	- 时间流动：false 时仅设置初始权威时刻与段，不随 Heartbeat 推进
	- 初始时钟时间 / 一天秒数 / 更新间隔秒 / 时间段 / 白天天气名 / 夜晚天气变体

	典型用法：
	- Clock.启用 = false：关闭整个时钟系统
	- Clock.时间流动 = false：权威停在初始时刻（适合固定昼夜场景）

	生命周期：Heartbeat 为服务器会话级连接，不解绑（可接受）
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local InsMgr = Utils.InsMgr
local SystemGameConfig = Utils.SystemGameConfig
local Lighting = Utils.Lighting
local RunService = Utils.RunService
local Log = Utils.Log

-- ========================================
-- 常量
-- ========================================

local CLOCK_HOURS = 24
local CLOCK_TIME_MIN = 0
local SLOT_DAY = "Day"
local SLOT_NIGHT = "Night"
local INST_CLOCK_AUTHORITY = "ClockAuthority"
local INST_TIME_SLOT = "TimeSlot"
local INST_LIGHTING_BASELINE = "LightingBaseline"
local CLASS_NUMBER_VALUE = "NumberValue"
local CLASS_STRING_VALUE = "StringValue"

if SystemGameConfig.GetValue({ "Clock", "启用" }) == false then
	return
end

local DEFAULT_ORIGINAL_CLOCK_TIME = 17
local DEFAULT_SECONDS_PER_DAY = 3600
local DEFAULT_UPDATE_INTERVAL = 0.2
local DEFAULT_DAY_LIGHTING_NAME = "Day"
local DEFAULT_NIGHT_VARIANTS = table.freeze({ "Night_1", "Night_2" })
local DEFAULT_TIME_SLOT_CONFIG = table.freeze({
	[SLOT_DAY] = table.freeze({
		table.freeze({ Min = 6, Max = 18 }),
	}),
	[SLOT_NIGHT] = table.freeze({
		table.freeze({ Min = 0, Max = 6 }),
		table.freeze({ Min = 18, Max = 24 }),
	}),
})

-- ========================================
-- 私有函数（配置规范化）
-- ========================================

--[[
	读取正数配置，非法时打日志并回退默认值
	@param path {string} - SystemGameConfig 路径段，如 { "Clock", "一天秒数" }
	@param fallback number - 非法或缺失时使用的正数默认值
	@return number - 有效正数
]]
local function _getConfigNumber(path: { string }, fallback: number): number
	local value = SystemGameConfig.GetValue(path)
	if typeof(value) == "number" and value > 0 then
		return value
	end
	Log.warn("ClockManager: 配置非法，使用默认值", table.concat(path, "."), value, fallback)
	return fallback
end

--[[
	冻结时间段配置（浅层：区间表 → 区间数组 → 段名表），防止运行期被改写
	@param config {[string]: {{Min: number, Max: number}}} - 已规范化的时间段表
	@return {[string]: {{Min: number, Max: number}}} - 冻结后的同一张表
]]
local function _freezeTimeSlotConfig(
	config: { [string]: { { Min: number, Max: number } } }
): { [string]: { { Min: number, Max: number } } }
	for _, ranges in config do
		for index, range in ranges do
			ranges[index] = table.freeze(range)
		end
		table.freeze(ranges)
	end
	return table.freeze(config)
end

--[[
	规范化时间段配置：仅保留 Min < Max 的半开区间 [Min, Max)（Max=24 合法）
	@param raw any - GameConfig.Clock.时间段；期望 {[string]: {{Min: number, Max: number}}}，段名为 Day/Night 等
	@return {[string]: {{Min: number, Max: number}}} - 可用时间段表；非法则返回默认表
]]
local function _normalizeTimeSlotConfig(raw: any): { [string]: { { Min: number, Max: number } } }
	if typeof(raw) ~= "table" then
		Log.warn("ClockManager: 时间段配置不是表，使用默认值")
		return DEFAULT_TIME_SLOT_CONFIG
	end

	local result: { [string]: { { Min: number, Max: number } } } = {}
	local hasAny = false
	for timeSlotName, ranges in raw do
		if typeof(timeSlotName) == "string" and typeof(ranges) == "table" then
			local normalizedRanges = {}
			for _, range in ranges do
				if typeof(range) == "table"
					and typeof(range.Min) == "number"
					and typeof(range.Max) == "number"
					and range.Min < range.Max
				then
					table.insert(normalizedRanges, { Min = range.Min, Max = range.Max })
				end
			end
			if #normalizedRanges > 0 then
				result[timeSlotName] = normalizedRanges
				hasAny = true
			end
		end
	end

	if not hasAny then
		Log.warn("ClockManager: 时间段配置无有效区间，使用默认值")
		return DEFAULT_TIME_SLOT_CONFIG
	end
	return _freezeTimeSlotConfig(result)
end

--[[
	规范化夜晚天气变体列表
	@param raw any - GameConfig.Clock.夜晚天气变体；期望非空 string 数组（LightingConfig 名）
	@return {string} - 非空配置名数组；非法则返回默认变体
]]
local function _normalizeNightVariants(raw: any): { string }
	if typeof(raw) ~= "table" then
		Log.warn("ClockManager: 夜晚天气变体不是表，使用默认值")
		return DEFAULT_NIGHT_VARIANTS
	end
	local result = {}
	for _, name in raw do
		if typeof(name) == "string" and name ~= "" then
			table.insert(result, name)
		end
	end
	if #result == 0 then
		Log.warn("ClockManager: 夜晚天气变体为空，使用默认值")
		return DEFAULT_NIGHT_VARIANTS
	end
	return table.freeze(result)
end

--[[
	将逻辑时钟规范到 [0, CLOCK_HOURS)
	@param t number - 原始时钟（可越界或为负）
	@return number - 规范后的时钟，范围 [0, 24)
]]
local function _normalizeClockModulo(t: number): number
	local r = t % CLOCK_HOURS
	if r < 0 then
		r += CLOCK_HOURS
	end
	return r
end

--[[
	按字典序收集时间段名，保证重叠配置时匹配结果稳定
	@param config {[string]: {{Min: number, Max: number}}} - 已规范化的时间段表
	@return {string} - 升序段名数组
]]
local function _buildSortedSlotNames(config: { [string]: { { Min: number, Max: number } } }): { string }
	local names = {}
	for name in config do
		table.insert(names, name)
	end
	table.sort(names)
	return table.freeze(names)
end

-- ========================================
-- 运行配置（启用后读取）
-- ========================================

local ORIGINAL_CLOCK_TIME = DEFAULT_ORIGINAL_CLOCK_TIME
do
	local value = SystemGameConfig.GetValue({ "Clock", "初始时钟时间" })
	if typeof(value) == "number" and value >= CLOCK_TIME_MIN and value <= CLOCK_HOURS then
		ORIGINAL_CLOCK_TIME = value
	else
		Log.warn("ClockManager: 初始时钟时间非法，使用默认值", value, DEFAULT_ORIGINAL_CLOCK_TIME)
	end
end

local SECONDS_PER_DAY = _getConfigNumber({ "Clock", "一天秒数" }, DEFAULT_SECONDS_PER_DAY)
local UPDATE_INTERVAL = _getConfigNumber({ "Clock", "更新间隔秒" }, DEFAULT_UPDATE_INTERVAL)
local TIME_FLOW_ENABLED = SystemGameConfig.GetValue({ "Clock", "时间流动" }) ~= false
local TIME_SLOT_CONFIG = _normalizeTimeSlotConfig(SystemGameConfig.GetValue({ "Clock", "时间段" }))
local TIME_SLOT_NAMES = _buildSortedSlotNames(TIME_SLOT_CONFIG)
local NIGHT_VARIANTS = _normalizeNightVariants(SystemGameConfig.GetValue({ "Clock", "夜晚天气变体" }))

local DAY_LIGHTING_NAME = DEFAULT_DAY_LIGHTING_NAME
do
	local value = SystemGameConfig.GetValue({ "Clock", "白天天气名" })
	if typeof(value) == "string" and value ~= "" then
		DAY_LIGHTING_NAME = value
	else
		Log.warn("ClockManager: 白天天气名非法，使用默认值", value, DEFAULT_DAY_LIGHTING_NAME)
	end
end

-- ========================================
-- 权威 Instance（本脚本唯一写者）
-- ========================================

local clockAuthority = InsMgr.GetIns(INST_CLOCK_AUTHORITY, CLASS_NUMBER_VALUE, Lighting) :: NumberValue
local timeSlotInst = InsMgr.GetIns(INST_TIME_SLOT, CLASS_STRING_VALUE, Lighting) :: StringValue
local lightingBaseline = InsMgr.GetIns(INST_LIGHTING_BASELINE, CLASS_STRING_VALUE, Lighting) :: StringValue

-- ========================================
-- 私有状态
-- ========================================

local _lastLogicalSlot: string? = nil
local _logicalClock = _normalizeClockModulo(ORIGINAL_CLOCK_TIME)
local _missingSlotWarned = false
local _heartbeatConn: RBXScriptConnection? = nil

-- ========================================
-- 私有函数（权威发布）
-- ========================================

--[[
	根据权威逻辑时刻获取对应时间段名称（半开区间 [Min, Max)）
	段名按字典序扫描，重叠区间取排序后的第一个命中
	@param time number - 权威时钟，范围 0–24
	@return string? - 时间段名称（如 "Day"、"Night"），无匹配时 nil
]]
local function _getTimeSlot(time: number): string?
	local normalized = _normalizeClockModulo(time)
	for _, timeSlotName in TIME_SLOT_NAMES do
		local timeSlotVt = TIME_SLOT_CONFIG[timeSlotName]
		if not timeSlotVt then
			continue
		end
		for _, timeRange in timeSlotVt do
			if normalized >= timeRange.Min and normalized < timeRange.Max then
				return timeSlotName
			end
		end
	end
	return nil
end

--[[
	按逻辑段解析权威天气配置名；进入 Night 时随机选变体
	@param logicalSlot string - Day / Night 等逻辑段名
	@param previousSlot string? - 上一次逻辑段；同段不重掷
	@return string - LightingConfig 名
]]
local function _resolveBaselineName(logicalSlot: string, previousSlot: string?): string
	if logicalSlot == SLOT_NIGHT then
		if previousSlot == SLOT_NIGHT and lightingBaseline.Value ~= "" then
			return lightingBaseline.Value
		end
		local idx = math.random(1, #NIGHT_VARIANTS)
		return NIGHT_VARIANTS[idx]
	end
	if logicalSlot == SLOT_DAY then
		return DAY_LIGHTING_NAME
	end
	-- 未知逻辑段：与段名同名的配置（若存在）
	return logicalSlot
end

--[[
	发布权威逻辑时刻（不写 Lighting.ClockTime）
	@param clockTime number - 逻辑时刻，内部会规范到 [0, 24)
	@return nil - 无返回值
]]
local function _publishClockAuthority(clockTime: number)
	_logicalClock = _normalizeClockModulo(clockTime)
	clockAuthority.Value = _logicalClock
end

--[[
	应用当前权威时刻对应的 TimeSlot 与 LightingBaseline（不推进时钟）
	无匹配段时只告警一次，避免 Heartbeat 刷屏
]]
local function _syncTimeSlotFromClock()
	local timeSlot = _getTimeSlot(_logicalClock)
	if not timeSlot then
		if not _missingSlotWarned then
			_missingSlotWarned = true
			Log.warn("ClockManager: 当前时刻未匹配任何时间段", _logicalClock)
		end
		return
	end

	timeSlotInst.Value = timeSlot
	if timeSlot ~= _lastLogicalSlot then
		lightingBaseline.Value = _resolveBaselineName(timeSlot, _lastLogicalSlot)
		_lastLogicalSlot = timeSlot
	end
end

--[[
	初始化时钟：写入权威时刻、TimeSlot、LightingBaseline；若开启时间流动则挂 Heartbeat 推进
	Heartbeat 为会话级连接，存于 _heartbeatConn，不解绑
]]
local function _initClock()
	_lastLogicalSlot = nil
	_publishClockAuthority(ORIGINAL_CLOCK_TIME)
	_syncTimeSlotFromClock()

	if not TIME_FLOW_ENABLED then
		return
	end

	local elapsedSec = 0
	_heartbeatConn = RunService.Heartbeat:Connect(function(dt)
		elapsedSec += dt
		if elapsedSec >= UPDATE_INTERVAL then
			_publishClockAuthority(_logicalClock + elapsedSec * CLOCK_HOURS / SECONDS_PER_DAY)
			_syncTimeSlotFromClock()
			elapsedSec = 0
		end
	end)
end

_initClock()
