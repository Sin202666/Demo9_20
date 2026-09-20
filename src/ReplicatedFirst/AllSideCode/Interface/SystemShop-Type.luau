local module = {}

--[[
	根据商品ID重置购买记录
	@param _plr Player - 目标玩家
	@param goodsID number - itemshopdataConf 商品 ID
	@return boolean, string? - 成功 true；失败 false 与 ShopErr
]]
function module.ResetItemByID(_plr: Player, goodsID: number): (boolean, string?)
end

--[[
	清空所有购买记录
	@param _plr Player - 目标玩家
	@return boolean, string? - 成功 true；失败 false 与 ShopErr
]]
function module.ResetAll(_plr: Player): (boolean, string?)
end

--[[
	初始化玩家 GamePass 值（创建 NumberValue 并恢复已购买的 GamePass）
	@param _plr Player - 目标玩家
]]
function module.InitValue(_plr: Player)
end

--[[
	初始化玩家商店数据（查询 Roblox 拥有并补发）
	@param _plr Player - 目标玩家
]]
function module.Init(_plr: Player)
end

--[[
	GamePass 发奖：先入包再写拥有
	@param _plr Player - 目标玩家
	@param passID number - GamePass 资产 ID
	@return boolean, string? - 成功 true；失败 false 与 ShopErr
]]
function module.BuyGamePassSuc(_plr: Player, passID: number): (boolean, string?)
end

return module
