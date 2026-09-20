local module = {}

--[[
	生成单个CDK
	@return string - 生成的CDK
]]
function module.GenerateSingleCDK(): string
end

--[[
	检查CDK是否唯一
	@param poolId string - 池ID
	@param cdk string - CDK字符串
	@return boolean - 池中不存在为 true
]]
function module.IsCDKUnique(poolId: string, cdk: string): boolean
end

--[[
	生成并打印CDK列表
	@param poolId string - 池ID
	@param count number - 生成数量
	@return boolean, {string}? - 是否成功，生成的CDK列表
]]
function module.GenerateAndPrintCDK(poolId: string, count: number): (boolean, { string }?)
end

--[[
	生成所有池的CDK
	@param countPerPool number? - 每个池生成的数量（可选）
	@return boolean - 是否成功
]]
function module.GenerateAllPoolsCDK(countPerPool: number?): boolean
end

--[[
	兑换CDK（CAS 标记已兑，不发奖）
	@param plr Player - 玩家对象
	@param code string - CDK代码
	@return boolean, {number}?, {number}?, string? - 成功为 true 与奖励 ID、数量、poolId
]]
function module.Redeem(plr: Player, code: string): (boolean, { number }?, { number }?, string?)
end

--[[
	入包失败后回滚本玩家刚写下的已兑标记
	@param plr Player - 原兑换玩家
	@param poolId string - Redeem 返回的池 ID
	@param code string - 同一 CDK
	@return boolean - 回滚成功为 true
]]
function module.RollbackRedeem(plr: Player, poolId: string, code: string): boolean
end

return module
