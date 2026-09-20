--[[
	Module: RequestRateLimit-Type
	Description: RequestRateLimit 类型声明（完整使用说明见 ToolSystem/RequestRateLimit.luau 文件头）
	Author: 林奥宇
	Created: 2026-07-01
	Last Modified: 2026-09-01
]]

local RequestRateLimit = {}

export type RateLimitEntry = {
	maxRequests: number,
	timeWindow: number,
}

export type CheatTypeThreshold = {
	severity: number,
	maxCount: number,
	maxSeverity: number,
	action: string,
}

export type CheatDetectionEntry = {
	enabled: boolean,
	cheatTypes: { string },
	thresholds: { [string]: CheatTypeThreshold },
	globalThresholds: {
		warnThreshold: { maxCount: number?, maxSeverity: number? },
		kickThreshold: { maxCount: number?, maxSeverity: number? },
	}?,
}

export type PlayerCheatRecord = {
	totalCount: number,
	totalSeverity: number,
	records: { [string]: { count: number, severity: number, lastTime: number } },
	warnCount: number,
	lastWarnTime: number,
}

--[[
	检测 payload 数据是否含 NaN、nil 等明显非法值
	@param data any - NetWork 中间件提取的 payload；nil 视为异常
	@return string? - 异常类型键；无异常返回 nil
]]
function RequestRateLimit.DetectDataAnomaly(data: any): string?
end

--[[
	检测短时间窗口内是否请求了过多不同 msgName（刷包模式）
	@param playerId number - 玩家 UserId
	@return boolean - true 表示请求模式异常
]]
function RequestRateLimit.DetectRequestPatternAnomaly(playerId: number): boolean
end

--[[
	累计异常并判断是否 warn/kick；踢出后返回 true 表示调用方应拒绝本次请求
	@param player Player - 目标玩家；须在线
	@param msgName string - 消息名称
	@param cheatType string - 异常类型键（与 NetWork 常量一致）
	@return boolean - true 表示已踢出、应拒绝后续处理；false 表示未踢出、可继续
]]
function RequestRateLimit.RecordCheatAndCheck(player: Player, msgName: string, cheatType: string): boolean
end

--[[
	滑动窗口频率检查；超限则拒绝并可选累计 rate_limit_exceeded
	@param player Player - 目标玩家
	@param msgName string - 消息名称（与 NetMsg 常量一致）
	@return boolean - true 表示允许继续；false 表示超限、已踢出或入参非法
]]
function RequestRateLimit.CheckRateLimit(player: Player, msgName: string): boolean
end

--[[
	注册或覆盖 msgName 的频率限制（启动期、仅服务端调用）
	@param msgName string - 消息名称（与 NetMsg 常量一致）
	@param config RateLimitEntry - maxRequests、timeWindow（秒）；内部深拷贝，调用方可丢弃原表
	@return nil
]]
function RequestRateLimit.SetRateLimitConfig(msgName: string, config: RateLimitEntry)
end

--[[
	注册或覆盖 msgName 的异常检测配置（启动期、仅服务端调用）
	@param msgName string - 消息名称（与 NetMsg 常量一致）
	@param config CheatDetectionEntry - enabled、cheatTypes、thresholds、globalThresholds；内部深拷贝
	@return nil
]]
function RequestRateLimit.SetCheatDetectionConfig(msgName: string, config: CheatDetectionEntry)
end

--[[
	查询 msgName 是否启用了异常检测
	@param msgName string - 消息名称
	@return boolean - true 表示已启用
]]
function RequestRateLimit.IsCheatDetectionEnabled(msgName: string): boolean
end

--[[
	获取玩家异常记录快照（深拷贝，不可篡改内部状态）
	@param player Player - 目标玩家
	@return PlayerCheatRecord? - 含 totalCount、totalSeverity、records、warnCount、lastWarnTime；无记录时 nil
]]
function RequestRateLimit.GetPlayerCheatRecord(player: Player): PlayerCheatRecord?
end

--[[
	清除玩家请求与异常记录（调试或 GM 用，仅服务端）
	@param player Player - 目标玩家
	@return nil
]]
function RequestRateLimit.ClearPlayerCheatRecord(player: Player)
end

--[[
	绑定玩家离开清理（服务端 NetWorkManager 启动时调用，幂等）
	@return nil
]]
function RequestRateLimit.Init()
end

return RequestRateLimit
