--[[
	Module: SystemDataStore
	Description: 服务端统一 DataStore 读写网关，提供重试、日志与 Store 实例缓存
	Author: 林奥宇
	Created: 2026-07-03
	Last Modified: 2026-08-31

	功能：
	- 按 StoreRegistry 注册表解析并缓存 DataStore / GlobalDataStore 实例
	- 统一 Get / Set / Update / Remove / GetOrdered / SetOrdered
	- 可配置重试与间隔，失败统一 Log

	调用关系：
	- SystemSave、SystemEmail、DebugManager 等领域模块通过本模块访问 DataStore
	- 禁止业务 System 直接使用 DataStoreService；所有 Store 读写统一经本模块

	示例：
	local SystemDataStore = Utils.SystemDataStore
	local ok, data = SystemDataStore.Get(SystemDataStore.STORE.Player, "Player123")
	local saved, err = SystemDataStore.Set(SystemDataStore.STORE.Player, "Player123", playerData)
]]

-- ========================================
-- 服务引用
-- ========================================
local DataStoreService = game:GetService("DataStoreService")

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Log = Utils.Log
local SystemGameConfig = Utils.SystemGameConfig

local StoreRegistry = require(script.StoreRegistry)
local StoreKeys = require(script.StoreKeys)

-- ========================================
-- 模块定义
-- ========================================
local SystemDataStore = {}

-- ========================================
-- 类型与常量
-- ========================================
export type DataStoreRequestOptions = {
	maxTries: number?,
	retryIntervalSec: number?,
}

local DEFAULT_MAX_TRIES = 3
local DEFAULT_RETRY_INTERVAL_SEC = 2

-- ========================================
-- 私有变量
-- ========================================
local _dataStoreCache: { [string]: GlobalDataStore | DataStore } = {}
local _orderedStoreCache: { [string]: OrderedDataStore } = {}

-- 对外暴露 Store ID 与键名工具
SystemDataStore.STORE = StoreRegistry.STORE
SystemDataStore.Keys = StoreKeys

-- ========================================
-- 私有函数
-- ========================================

--[[
	合并调用方 options 与默认值

	@param options DataStoreRequestOptions? - 调用方选项
	@return number, number - maxTries 与 retryIntervalSec
]]
local function _resolveOptions(options: DataStoreRequestOptions?): (number, number)
	local maxTries = DEFAULT_MAX_TRIES
	local retryIntervalSec = DEFAULT_RETRY_INTERVAL_SEC
	if options then
		if options.maxTries then
			maxTries = options.maxTries
		end
		if options.retryIntervalSec then
			retryIntervalSec = options.retryIntervalSec
		end
	end
	return maxTries, retryIntervalSec
end

--[[
	解析 Store 注册项的实际 DataStore 名称

	@param entry table - 注册配置，含 kind / name / nameFromConfig
	@return string? - 解析后的 Store 名称；无法解析时 nil
]]
local function _resolveStoreName(entry: { kind: string, name: string?, nameFromConfig: string? }): string?
	if entry.name then
		return entry.name
	end
	if entry.nameFromConfig then
		return SystemGameConfig.GetValue(entry.nameFromConfig)
	end
	return nil
end

--[[
	获取已注册的标准 Store 实例（懒加载缓存）

	@param storeId string - StoreRegistry.STORE 中的逻辑 ID
	@return GlobalDataStore | DataStore? - Store 实例；未注册或解析失败时 nil
]]
local function _getRegisteredStore(storeId: string): (GlobalDataStore | DataStore)?
	local cached = _dataStoreCache[storeId]
	if cached then
		return cached
	end

	local entry = StoreRegistry.ENTRIES[storeId]
	if not entry then
		Log.warn("SystemDataStore: unknown storeId", storeId)
		return nil
	end

	local store: GlobalDataStore | DataStore
	if entry.kind == "GlobalDataStore" then
		store = DataStoreService:GetGlobalDataStore()
	else
		local storeName = _resolveStoreName(entry)
		if not storeName or storeName == "" then
			Log.warn("SystemDataStore: unresolved store name", storeId)
			return nil
		end
		store = DataStoreService:GetDataStore(storeName)
	end

	_dataStoreCache[storeId] = store
	return store
end

--[[
	获取 OrderedDataStore 实例（懒加载缓存）

	@param orderedStoreName string - OrderedDataStore 名称
	@return OrderedDataStore? - Store 实例
]]
local function _getOrderedStore(orderedStoreName: string): OrderedDataStore?
	local cached = _orderedStoreCache[orderedStoreName]
	if cached then
		return cached
	end

	local store = DataStoreService:GetOrderedDataStore(orderedStoreName)
	_orderedStoreCache[orderedStoreName] = store
	return store
end

--[[
	带重试执行 DataStore 操作

	@param operationName string - 操作名，用于 Log
	@param storeId string - 逻辑 Store ID 或 Ordered Store 名称
	@param key string - DataStore 键
	@param executor () -> any - 实际操作
	@param options DataStoreRequestOptions? - 重试选项
	@return boolean, any?, any? - 成功标志、结果、错误信息
]]
local function _executeWithRetry(
	operationName: string,
	storeId: string,
	key: string,
	executor: () -> any,
	options: DataStoreRequestOptions?
): (boolean, any?, any?)
	local maxTries, retryIntervalSec = _resolveOptions(options)
	local lastErr: any

	for tries = 1, maxTries do
		local ok, result = pcall(executor)
		if ok then
			return true, result, nil
		end

		lastErr = result
		if tries < maxTries then
			task.wait(retryIntervalSec)
		end
	end

	Log.warn(string.format("SystemDataStore.%s failed:", operationName), storeId, key, lastErr)
	return false, nil, lastErr
end

-- ========================================
-- 公共函数
-- ========================================

--[[
	构建玩家存档 DataStore 键

	@param userId number - 玩家 UserId
	@return string - 格式 "Player{userId}"
]]
function SystemDataStore.BuildPlayerKey(userId: number): string
	return StoreKeys.BuildPlayerKey(userId)
end

--[[
	解析玩家存档 DataStore 键，与 BuildPlayerKey 对称

	@param key string - DataStore 键，须为 "Player{userId}"
	@return number? - 解析出的 UserId；格式非法时为 nil
]]
function SystemDataStore.ParsePlayerKey(key: string): number?
	return StoreKeys.ParsePlayerKey(key)
end

--[[
	从标准 Store 读取数据

	@param storeId string - StoreRegistry.STORE 逻辑 ID
	@param key string - DataStore 键
	@param options DataStoreRequestOptions? - 重试选项；加载场景可设 maxTries = 1
	@return boolean, any?, string? - 成功标志、数据（无存档时为 nil）、错误信息
]]
function SystemDataStore.Get(
	storeId: string,
	key: string,
	options: DataStoreRequestOptions?
): (boolean, any?, string?)
	local store = _getRegisteredStore(storeId)
	if not store then
		return false, nil, "UNKNOWN_STORE"
	end

	return _executeWithRetry("Get", storeId, key, function()
		return store:GetAsync(key)
	end, options)
end

--[[
	向标准 Store 写入数据

	@param storeId string - StoreRegistry.STORE 逻辑 ID
	@param key string - DataStore 键
	@param value any - 可序列化的写入值
	@param options DataStoreRequestOptions? - 重试选项
	@return boolean, string? - 成功标志、错误信息
]]
function SystemDataStore.Set(
	storeId: string,
	key: string,
	value: any,
	options: DataStoreRequestOptions?
): (boolean, string?)
	local store = _getRegisteredStore(storeId)
	if not store then
		return false, "UNKNOWN_STORE"
	end

	local ok, _, err = _executeWithRetry("Set", storeId, key, function()
		store:SetAsync(key, value)
	end, options)
	return ok, err
end

--[[
	原子更新标准 Store 中的数据

	@param storeId string - StoreRegistry.STORE 逻辑 ID
	@param key string - DataStore 键
	@param transform (any?) -> any - 接收旧值、返回新值的变换函数
	@param options DataStoreRequestOptions? - 重试选项
	@return boolean, any?, string? - 成功标志、UpdateAsync 返回值、错误信息
]]
function SystemDataStore.Update(
	storeId: string,
	key: string,
	transform: (any?) -> any,
	options: DataStoreRequestOptions?
): (boolean, any?, string?)
	local store = _getRegisteredStore(storeId)
	if not store then
		return false, nil, "UNKNOWN_STORE"
	end

	return _executeWithRetry("Update", storeId, key, function()
		return store:UpdateAsync(key, transform)
	end, options)
end

--[[
	从标准 Store 删除键

	@param storeId string - StoreRegistry.STORE 逻辑 ID
	@param key string - DataStore 键
	@param options DataStoreRequestOptions? - 重试选项
	@return boolean, string? - 成功标志、错误信息
]]
function SystemDataStore.Remove(
	storeId: string,
	key: string,
	options: DataStoreRequestOptions?
): (boolean, string?)
	local store = _getRegisteredStore(storeId)
	if not store then
		return false, "UNKNOWN_STORE"
	end

	local ok, _, err = _executeWithRetry("Remove", storeId, key, function()
		store:RemoveAsync(key)
	end, options)
	return ok, err
end

--[[
	从 OrderedDataStore 读取数值

	@param orderedStoreName string - OrderedDataStore 名称
	@param key string - 键名
	@param options DataStoreRequestOptions? - 重试选项
	@return boolean, number?, string? - 成功标志、数值、错误信息
]]
function SystemDataStore.GetOrdered(
	orderedStoreName: string,
	key: string,
	options: DataStoreRequestOptions?
): (boolean, number?, string?)
	local store = _getOrderedStore(orderedStoreName)
	if not store then
		return false, nil, "UNKNOWN_ORDERED_STORE"
	end

	local ok, value, err = _executeWithRetry("GetOrdered", orderedStoreName, key, function()
		return store:GetAsync(key)
	end, options)
	if not ok then
		return false, nil, err
	end
	if value == nil then
		return true, nil, nil
	end
	return true, value, nil
end

--[[
	向 OrderedDataStore 写入数值

	@param orderedStoreName string - OrderedDataStore 名称
	@param key string - 键名
	@param value number - 写入数值
	@param options DataStoreRequestOptions? - 重试选项
	@return boolean, string? - 成功标志、错误信息
]]
function SystemDataStore.SetOrdered(
	orderedStoreName: string,
	key: string,
	value: number,
	options: DataStoreRequestOptions?
): (boolean, string?)
	local store = _getOrderedStore(orderedStoreName)
	if not store then
		return false, "UNKNOWN_ORDERED_STORE"
	end

	local ok, _, err = _executeWithRetry("SetOrdered", orderedStoreName, key, function()
		store:SetAsync(key, value)
	end, options)
	return ok, err
end

export type SortedRankEntry = any

--[[
	从 OrderedDataStore 拉取排序榜单页

	@param orderedStoreName string - OrderedDataStore 名称
	@param ascending boolean - 是否升序
	@param pageSize number - 每页条数
	@param minValue number? - 最低分值过滤，默认 1
	@param options DataStoreRequestOptions? - 重试选项
	@return boolean, {SortedRankEntry}?, string? - 成功标志、{{userId, score}, ...}、错误信息
]]
function SystemDataStore.GetSortedOrdered(
	orderedStoreName: string,
	ascending: boolean,
	pageSize: number,
	minValue: number?,
	options: DataStoreRequestOptions?
): (boolean, { SortedRankEntry }?, string?)
	local store = _getOrderedStore(orderedStoreName)
	if not store then
		return false, nil, "UNKNOWN_ORDERED_STORE"
	end

	local filterMin = minValue or 1
	local ok, pageData, err = _executeWithRetry("GetSortedOrdered", orderedStoreName, "page", function()
		local pages = store:GetSortedAsync(ascending, pageSize, filterMin)
		local currentPage = pages:GetCurrentPage()
		local entries: { SortedRankEntry } = {}
		for _, entry in ipairs(currentPage) do
			table.insert(entries, { entry.key, entry.value })
		end
		return entries
	end, options)

	if not ok then
		return false, nil, err
	end
	return true, pageData, nil
end

return SystemDataStore
