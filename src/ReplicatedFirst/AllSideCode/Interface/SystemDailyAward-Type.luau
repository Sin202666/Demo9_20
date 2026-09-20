local M = {}

--[[
	每日签到总开关（GameConfig「每日签到.启用」；缺键视为开）
	@return boolean - true 表示启用
]]
function M.IsEnabled(): boolean
end

--[[
	检测玩家是否满足每日签到领取条件；满足则添加签到红点
	@param plr Player - 目标玩家
	@return boolean - 是否应显示可领取红点
]]
function M.CheckDailyAward(plr: Player): boolean
end

--[[
	领取玩家当前可领的每日签到奖励
	@param plr Player - 目标玩家
	@return boolean - 领取并入包成功为 true
	@return string? - 失败时为 EnumMgr.DailyAwardErr；成功为 nil
]]
function M.GetDailyAward(plr: Player): (boolean, string?)
end

--[[
	玩家入服时立即执行一次签到冷却检测
	@param plr Player - 刚完成数据加载的玩家
]]
function M.Init(plr: Player)
end

--[[
	注册每日签到相关 RemoteFunction
]]
function M.RegisterNetWork()
end

return M
