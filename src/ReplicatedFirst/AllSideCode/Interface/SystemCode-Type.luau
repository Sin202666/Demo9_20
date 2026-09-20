--[[
	Module: SystemCode-Type
	Description: SystemCode IDE 类型桩（实现以 Server SystemCode 为准）
	Author: 林奥宇
	Created: 2026-07-03
	Last Modified: 2026-09-01
]]

local SystemCode = {}

--[[
	兑换兑换码
	@param _plr Player - 发起兑换的玩家
	@param codeStr string - 用户输入的兑换码字符串
	@return boolean - 兑换成功为 true
	@return string? - 失败时为 EnumMgr.CodeErr；成功为 nil
]]
function SystemCode.RedeemCode(_plr: Player, codeStr: string): (boolean, string?)
end

--[[
	注册兑换码相关 RemoteFunction（幂等）
]]
function SystemCode.RegisterNetWork()
end

return SystemCode
