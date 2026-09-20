--[[
	Module: SystemFeedback-Type
	Description: SystemFeedback 类型声明（完整使用说明见 ServerSideCode/System/SystemFeedback.luau 文件头）
	Author: 林奥宇
	Created: 2026-07-03
	Last Modified: 2026-09-01
]]

local SystemFeedback = {}

--[[
	提交玩家反馈
	@param plr Player - 提交玩家
	@param comment string - 反馈正文（允许含首尾空白，内部会去掉）
	@return boolean - 提交成功为 true（Webhook 已投递）；失败为 false
]]
function SystemFeedback.SubmitFeedback(plr: Player, comment: string): boolean
end

--[[
	注册反馈相关 RemoteFunction，并配置限频
	@return nil - 无返回值
]]
function SystemFeedback.RegisterNetWork()
end

return SystemFeedback
