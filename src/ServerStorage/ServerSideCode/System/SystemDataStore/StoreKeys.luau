--[[
	Module: StoreKeys
	Description: SystemDataStore 常用键名与玩家键构建工具
	Author: 林奥宇
	Created: 2026-07-03
	Last Modified: 2026-08-31
]]

-- ========================================
-- 模块定义
-- ========================================
local StoreKeys = {}

-- ========================================
-- 常量定义
-- ========================================
StoreKeys.PLAYER_PREFIX = "Player"
StoreKeys.SERVER_BUFF = "ServerBuff"
StoreKeys.GLOBAL_GAME_NEXT_UPDATE = "GameNextUpdateTime"

-- Email Store 键名：tostring(userId)
-- PurchaseHistory Store 键名："{playerId}_{purchaseId}"

-- ========================================
-- 公共函数
-- ========================================

--[[
	构建玩家存档 DataStore 键

	@param userId number - 玩家 UserId
	@return string - 格式 "Player{userId}"
]]
function StoreKeys.BuildPlayerKey(userId: number): string
	return StoreKeys.PLAYER_PREFIX .. tostring(userId)
end

--[[
	解析玩家存档 DataStore 键，与 BuildPlayerKey 对称

	@param key string - DataStore 键，须为 "Player{userId}"
	@return number? - 解析出的 UserId；前缀不匹配或非整数时为 nil
]]
function StoreKeys.ParsePlayerKey(key: string): number?
	if type(key) ~= "string" then
		return nil
	end
	local prefix = StoreKeys.PLAYER_PREFIX
	if string.sub(key, 1, #prefix) ~= prefix then
		return nil
	end
	local userId = tonumber(string.sub(key, #prefix + 1))
	if type(userId) ~= "number" or userId ~= math.floor(userId) then
		return nil
	end
	return userId
end

return StoreKeys
