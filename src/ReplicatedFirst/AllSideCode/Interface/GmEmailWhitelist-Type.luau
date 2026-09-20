local GmEmailWhitelist = {
	GM_EMAIL_ALLOW_IN_STUDIO = false,
}

--[[
	判断 UserId 是否允许使用 GM 发邮件
	@param userId number - 玩家 UserId
	@return boolean - true 表示允许
]]
function GmEmailWhitelist.IsAllowed(userId: number): boolean
	return false
end

return GmEmailWhitelist
