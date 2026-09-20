--[[
	Module: TextFilter
	Description: 评论官方文本过滤封装（FilterStringAsync + Broadcast）
	Author: 林奥宇
	Created: 2026-08-13
	Last Modified: 2026-08-13
]]

local TextService = game:GetService("TextService")

local TextFilter = {}

--[[
	过滤为全服可展示文案
	@param text string - 原始文本
	@param userId number - 发言者 UserId
	@return string? - 过滤后文本；失败返回 nil
]]
function TextFilter.FilterForBroadcast(text: string, userId: number): string?
	local ok, filterResult = pcall(function()
		return TextService:FilterStringAsync(text, userId)
	end)
	if not ok or not filterResult then
		return nil
	end
	local ok2, filtered = pcall(function()
		return filterResult:GetNonChatStringForBroadcastAsync()
	end)
	if not ok2 or typeof(filtered) ~= "string" or filtered == "" then
		return nil
	end
	return filtered
end

return TextFilter
