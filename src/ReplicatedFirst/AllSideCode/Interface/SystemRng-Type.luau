local module = {}

--[[
	针对这个池子的保底数据 每个池子都有自己的保底数据
]]
export type PityData = {
	rngCount: number,          --累计抽取次数
	rarePity: {[number]: number}, --稀有度：已累计次数
	unitPity: {[number]: number}, --角色ID：已累计次数
}

--[[
	RNG系统配置表
]]
export type RngConfig = {
	poolName: string,
	pool: {[number]: number},
	weight: {[number]: number},
	cost: number, --抽取货币类型
	price: number, --抽取货币数量
}

--[[
	RNG系统对象
]]
export type RngSystem = {
	poolName: string,
	rarePity: {[number]: number}?,
	unitPity: {[number]: number}?,
	config: RngConfig,
	
	--[[
		更新保底配置
		@param rarePityPityConfig: {[number]: number}? - 稀有度保底配置表
		@param unitPityConfig: {[number]: number}? - 特定单位保底配置表
	]]
	updatePityConfig: (self: RngSystem, rarePityPityConfig: {[number]: number}?, unitPityConfig: {[number]: number}?) -> nil,
	
	--[[
		Roll取池子中的物品
		@param nowPityData: PityData - 针对这个池子的保底数据（会被修改）
		@return number? - 抽取结果（物品ID），触发保底时只返回此值
		@return PityData? - 更新后的保底数据（正常抽取时返回）
	]]
	roll: (self: RngSystem, nowPityData: PityData) -> (number?, PityData?),
}

--[[
	创建RNG对象
	@param config: RngConfig - 配置表
	@param rarePityPityConfig: {[number]: number}? - 稀有度保底配置表
	@param unitPityConfig: {[number]: number}? - 特定单位保底配置表
	@param reverseRarePityConfig: {[number]: number}? - 反向保底稀有度保底配置表（未使用）
	@param reverseUnitPityConfig: {[number]: number}? - 反向保底单位保底配置表（未使用）
	@return RngSystem - RNG系统对象
]]
function module.new(config: RngConfig, rarePityPityConfig: {[number]: number}?, unitPityConfig: {[number]: number}?, reverseRarePityConfig: {[number]: number}?, reverseUnitPityConfig: {[number]: number}?): RngSystem
end

--[[
    获取抽取货币类型和数量
    @param self: RngSystem - RNG系统对象
    @param rngCount: number - 抽取次数
    @return currencyType: string - 货币类型
    @return currencyAmount: number - 货币数量
]]
function module.getCurrency(self: RngSystem, rngCount: number):(string,number)
end

return module
