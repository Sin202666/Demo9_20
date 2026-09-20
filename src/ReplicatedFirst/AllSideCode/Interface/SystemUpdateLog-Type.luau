local SystemUpdateLog = {}

--[[
	玩家入服时弹出未读最新公告
	@param plr Player - 刚完成存档加载的玩家
	@return nil - 无返回值
]]
function SystemUpdateLog.Init(plr: Player)
end

--[[
	标记指定更新公告为已读
	@param plr Player - 玩家对象
	@param updateId number | string - updatelogConf 索引（number 或可 tonumber 的 string）
	@return boolean - true 表示本次标记成功
	@return string? - 失败时为 EnumMgr.UpdateLogErr.*
]]
function SystemUpdateLog.ReadUpdateLog(plr: Player, updateId: number | string): (boolean, string?)
end

--[[
	注册公告已读 RemoteEvent 并配置限频（幂等）
	@return nil - 无返回值
]]
function SystemUpdateLog.RegisterNetWork()
end

return SystemUpdateLog
