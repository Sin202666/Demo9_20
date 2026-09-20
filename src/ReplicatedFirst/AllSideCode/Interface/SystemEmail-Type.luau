local SystemEmail = {}

--[[
	打印玩家 DS 邮件信息（调试用）
	@param userID number | string - 玩家 UserId
	@return nil
]]
function SystemEmail.PrintPlrEmail(userID: number | string)
end

--[[
	运营侧写入离线邮件到 Email DataStore；目标在线则立即入包
	@param emailData table - UserID:number；RewardID:{number}；RewardCount:{number}（等长，每项数量≥1）；TagTitle/ContentTitle/UpdateText:string?；Ex_Data 仅允许 {IsGift=1, PassID=number}，其它键丢弃
	@return boolean, string? - 失败 false 与错误码；写入成功 true；在线入包未完成且会补发时为 EnumMgr.GmEmailErr.QueuedGrantFailed；已同步但回滚失败为 EnumMgr.GmEmailErr.SyncRevertFailed
]]
function SystemEmail.GivePlrEmail(emailData: any): (boolean, string?)
	return false, nil
end

--[[
	玩家入服时自动发放 DS / 老存档邮件奖励（入包；药水参数不生效）
	@param plr Player - 刚完成数据加载的玩家
	@return nil
]]
function SystemEmail.Init(plr: Player)
end

return SystemEmail
