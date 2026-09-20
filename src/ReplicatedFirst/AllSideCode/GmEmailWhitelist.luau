--[[
	Module: GmEmailWhitelist
	Description: GM 发邮件面板 UserId 白名单（客户端门禁 + 服务端二次校验）
	Author: 林奥宇
	Created: 2026-08-11
	Last Modified: 2026-08-18

	用法：
	- 线上（含 Dev/Test/正式服）：须在下方写入 [userId] = true
	- Studio：默认仅白名单可用。将 GM_EMAIL_ALLOW_IN_STUDIO 改为 true 后，Studio 内任意玩家可用（仅本地开发）

	加载方式：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local GmEmailWhitelist = Utils.GmEmailWhitelist
		if GmEmailWhitelist.IsAllowed(player.UserId) then
			-- ...
		end

	客户端门禁脚本可直接 require 本模块（避免非白名单玩家加载 UtilsSystem）。
]]

local RunService = game:GetService("RunService")

local GmEmailWhitelist = {
	GM_EMAIL_ALLOW_IN_STUDIO = false,
	[7521918720] = true, -- 李一丹
	[7330532450] = true, -- 贾进宝
	[10748969534] = true, -- 田雪瑶
	-- [123456789] = true,
}

--[[
	判断 UserId 是否允许使用 GM 发邮件

	@param userId number - 玩家 UserId
	@return boolean - true 表示允许
]]
function GmEmailWhitelist.IsAllowed(userId: number): boolean
	if GmEmailWhitelist.GM_EMAIL_ALLOW_IN_STUDIO and RunService:IsStudio() then
		return true
	end
	return GmEmailWhitelist[tonumber(userId) or -1] == true
end

return GmEmailWhitelist
