--[[
	Module: SystemOnlineAward-Type
	Description: SystemOnlineAward 类型声明（完整使用说明见 ServerSideCode/System/SystemOnlineAward.luau）
	Author: 林奥宇
	Created: 2026-09-04
	Last Modified: 2026-09-04
]]

local M = {}

--[[
	在线奖励总开关（GameConfig「在线奖励.启用」；缺键视为开）
	@return boolean - true 表示启用
]]
function M.IsEnabled(): boolean
end

--[[
	玩家入服：本轮从 0 开始（不继承离线前进度），刷新红点
	@param plr Player - 目标玩家
	@return nil
]]
function M.Init(plr: Player)
end

--[[
	全员累加在线秒数
	@param dt number - 增量秒
	@return nil
]]
function M.AddOnlineTime(dt: number)
end

--[[
	给指定玩家增加在线秒（GM）
	@param plr Player - 目标玩家
	@param sec number - 增加秒数
	@return boolean - 成功为 true
]]
function M.AddOnlineSeconds(plr: Player, sec: number): boolean
end

--[[
	领取指定档位在线奖励；本轮全领完则重置
	@param plr Player - 目标玩家
	@param tierId any - 档位 confId
	@return boolean - 成功为 true
]]
function M.ClaimOnlineReward(plr: Player, tierId: any): boolean
end

--[[
	是否有可领在线奖励
	@param plr Player - 目标玩家
	@return boolean - 有可领为 true
]]
function M.HasClaimable(plr: Player): boolean
end

--[[
	付费：将本轮未达标且未领的档位标记 Unlock=1；已领不变；幂等；功能关闭时 false
	@param plr Player - 目标玩家
	@return boolean - 成功为 true
]]
function M.UnlockAllClaimable(plr: Player): boolean
end

--[[
	GM：重置在线奖励本轮进度
	@param plr Player - 目标玩家
	@return nil
]]
function M.ResetOnlineAward(plr: Player)
end

--[[
	注册 CLAIM_ONLINE_AWARD RemoteFunction
	@return nil
]]
function M.RegisterNetWork()
end

return M
