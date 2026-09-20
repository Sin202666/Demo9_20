local module = {}

export type DataStoreRequestOptions = {
	maxTries: number?,
	retryIntervalSec: number?,
}

--[[
	构建玩家存档 DataStore 键
	@param userId number - 玩家 UserId
	@return string - 格式 "Player{userId}"
]]
function module.BuildPlayerKey(userId: number): string
end

--[[
	从标准 Store 读取数据
	@param storeId string - StoreRegistry.STORE 逻辑 ID
	@param key string - DataStore 键
	@param options DataStoreRequestOptions? - 重试选项
	@return boolean, any?, string? - 成功标志、数据、错误信息
]]
function module.Get(storeId: string, key: string, options: module.DataStoreRequestOptions?): (boolean, any?, string?)
end

--[[
	向标准 Store 写入数据
	@param storeId string - StoreRegistry.STORE 逻辑 ID
	@param key string - DataStore 键
	@param value any - 可序列化的写入值
	@param options DataStoreRequestOptions? - 重试选项
	@return boolean, string? - 成功标志、错误信息
]]
function module.Set(storeId: string, key: string, value: any, options: module.DataStoreRequestOptions?): (boolean, string?)
end

--[[
	原子更新标准 Store 中的数据
	@param storeId string - StoreRegistry.STORE 逻辑 ID
	@param key string - DataStore 键
	@param transform (any?) -> any - 变换函数
	@param options DataStoreRequestOptions? - 重试选项
	@return boolean, any?, string? - 成功标志、UpdateAsync 返回值、错误信息
]]
function module.Update(
	storeId: string,
	key: string,
	transform: (any?) -> any,
	options: module.DataStoreRequestOptions?
): (boolean, any?, string?)
end

--[[
	从标准 Store 删除键
	@param storeId string - StoreRegistry.STORE 逻辑 ID
	@param key string - DataStore 键
	@param options DataStoreRequestOptions? - 重试选项
	@return boolean, string? - 成功标志、错误信息
]]
function module.Remove(storeId: string, key: string, options: module.DataStoreRequestOptions?): (boolean, string?)
end

--[[
	从 OrderedDataStore 读取数值
	@param orderedStoreName string - OrderedDataStore 名称
	@param key string - 键名
	@param options DataStoreRequestOptions? - 重试选项
	@return boolean, number?, string? - 成功标志、数值、错误信息
]]
function module.GetOrdered(
	orderedStoreName: string,
	key: string,
	options: module.DataStoreRequestOptions?
): (boolean, number?, string?)
end

--[[
	向 OrderedDataStore 写入数值
	@param orderedStoreName string - OrderedDataStore 名称
	@param key string - 键名
	@param value number - 写入数值
	@param options DataStoreRequestOptions? - 重试选项
	@return boolean, string? - 成功标志、错误信息
]]
function module.SetOrdered(
	orderedStoreName: string,
	key: string,
	value: number,
	options: module.DataStoreRequestOptions?
): (boolean, string?)
end

export type SortedRankEntry = any

--[[
	从 OrderedDataStore 拉取排序榜单页
	@param orderedStoreName string - OrderedDataStore 名称
	@param ascending boolean - 是否升序
	@param pageSize number - 每页条数
	@param minValue number? - 最低分值过滤
	@param options DataStoreRequestOptions? - 重试选项
	@return boolean, {SortedRankEntry}?, string? - 成功标志、榜单条目、错误信息
]]
function module.GetSortedOrdered(
	orderedStoreName: string,
	ascending: boolean,
	pageSize: number,
	minValue: number?,
	options: module.DataStoreRequestOptions?
): (boolean, { module.SortedRankEntry }?, string?)
end

return module
