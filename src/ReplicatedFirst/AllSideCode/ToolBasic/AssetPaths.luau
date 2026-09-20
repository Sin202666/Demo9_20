--!strict
--[[
	Module: AssetPaths
	Description: 解析 ReplicatedStorage / ServerStorage 下 Assets 目录及旧版路径（含路径查找缓存，非业务状态）
	Author: 林奥宇
	Created: 2026-07-01
	Last Modified: 2026-08-31

	功能：
	- 按 Scope 定位 Assets 根目录
	- 解析 catalog 与相对路径
	- 迁移期兼容 RS/SS 根下的旧 ModelRes 目录

	------------------------------------------------------------------------
	目录约定
	------------------------------------------------------------------------
	新路径（推荐）：
		ReplicatedStorage/Assets/{catalog}/...
		ServerStorage/Assets/{catalog}/...

	相对路径格式（API 入参）：
		"{catalog}/{子路径...}"
		示例："ModelRes/Pet/Cat1"、"UI/Tips/BGTemp"、"Hatch/BoxModel"

	一级 catalog 常见值：ModelRes、UI、Hatch、Sequence、Tips 等（见 AssetRegistry.Catalog）

	迁移期旧路径（自动兜底，无需改调用代码）：
		ReplicatedStorage.ModelRes  →  ReplicatedStorage.Assets.ModelRes
		ServerStorage.ModelRes      →  ServerStorage.Assets.ModelRes

	------------------------------------------------------------------------
	Scope 说明（AssetPaths.Scope）
	------------------------------------------------------------------------
	Shared（默认）— 仅查 ReplicatedStorage，双端可见资源用这个。
	Server         — 仅查 ServerStorage；客户端无 ServerStorage，恒返回 nil。
	Auto           — 服务端：先 SS 后 RS；客户端：等同 Shared。

	非法 scope 会 Log.warn 一次并回退为 Shared。

	------------------------------------------------------------------------
	何时使用本模块
	------------------------------------------------------------------------
	需要 Clone / Restore / 对象池时 → 用 ResourceUtil 或 AssetAcquire（它们内部调 AssetPaths）。
	仅需定位模板 Instance、遍历目录、ClearAssert 等 → 可直接用本模块。

	加载方式：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local AssetPaths = Utils.AssetPaths

	------------------------------------------------------------------------
	使用示例
	------------------------------------------------------------------------
	-- 解析双端模型模板（不 Clone）
	local petTemplate = AssetPaths.Resolve("ModelRes/Pet/Cat1")
	-- 等价：AssetPaths.Resolve("ModelRes/Pet/Cat1", AssetPaths.Scope.Shared)

	-- 解析仅服务端 UI 模板
	local rankTemp = AssetPaths.Resolve("ModelRes/排行榜/RankTemp", AssetPaths.Scope.Server)

	-- 只取一级 catalog 目录
	local modelResFolder = AssetPaths.GetCatalog("ModelRes")

	-- 取 Assets 根（少见，多用于批量遍历）
	local assetsRoot = AssetPaths.GetAssetsRoot(AssetPaths.Scope.Shared)

	-- Studio 热重载资源后清缓存
	AssetPaths.ClearCache()

	------------------------------------------------------------------------
	返回值与缓存
	------------------------------------------------------------------------
	- 所有查询 API 未找到时返回 nil，不抛错。返回的是 DataModel 模板引用，不是配置表拷贝；
	  需要 Clone 时请用 AssetAcquire.Get 或 ResourceUtil.Get。
	- 模块缓存查找结果（含「未命中」），避免重复 FindFirstChild。
	- 资源在运行时增删改后，需调用 ClearCache() 再解析。ClearCache 不清「非法 scope 已警告」标记。
	- 详细迁移清单见 docs/ASSETS_MIGRATION.md
]]

-- ============================================================================
-- 服务引用 / 模块引用
-- ============================================================================

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local ReplicatedStorage = Utils.ReplicatedStorage
local Log = Utils.Log
-- Utils.ServerStorage 仅服务端直接挂字段；客户端走 __index 会误查模块名，故 rawget
local ServerStorage = rawget(Utils, "ServerStorage")

-- ============================================================================
-- 模块定义
-- ============================================================================

local AssetPaths = {}

-- ============================================================================
-- 常量定义
-- ============================================================================

local ASSETS_ROOT_NAME = "Assets"
local PATH_SEGMENT_PATTERN = "[^/]+"
local CATALOG_CACHE_SEP = ":"

AssetPaths.ASSETS_ROOT_NAME = ASSETS_ROOT_NAME

AssetPaths.Scope = table.freeze({
	Shared = "Shared",
	Server = "Server",
	Auto = "Auto",
})

-- 迁移期：曾直接放在 RS/SS 根下的 catalog
local LEGACY_ROOT_CATALOGS: { [string]: boolean } = table.freeze({
	ModelRes = true,
})

-- ============================================================================
-- 私有变量
-- ============================================================================

-- cache 中 false 表示「已查找但未命中」，与「未缓存」区分
type CacheEntry = Folder | false

local _assetsRootCache: { [string]: CacheEntry } = {}
local _catalogCache: { [string]: CacheEntry } = {}
local _warnedInvalidScopes: { [string]: boolean } = {}

-- ============================================================================
-- 私有函数
-- ============================================================================

--[[
	校验并规范化 scope，非法值回退 Shared
	@param scope string? - 调用方传入的作用域；nil 视为 Shared
	@return string - Shared / Server / Auto 之一
]]
local function _normalizeScope(scope: string?): string
	local value = scope or AssetPaths.Scope.Shared
	if value == AssetPaths.Scope.Shared
		or value == AssetPaths.Scope.Server
		or value == AssetPaths.Scope.Auto then
		return value
	end
	if not _warnedInvalidScopes[value] then
		_warnedInvalidScopes[value] = true
		Log.warn(`[AssetPaths] 非法 scope "{value}"，已回退为 Shared`)
	end
	return AssetPaths.Scope.Shared
end

--[[
	从缓存条目读取 Folder 结果
	@param entry CacheEntry? - 缓存条目；nil 表示尚未写入缓存
	@return Folder? - 命中且存在时为 Folder；未命中或未缓存时为 nil
	@return boolean - true 表示已查过（含负缓存）；false 表示尚未缓存
]]
local function _readFolderCache(entry: CacheEntry?): (Folder?, boolean)
	if entry == nil then
		return nil, false
	end
	if entry == false then
		return nil, true
	end
	return entry, true
end

--[[
	拼接 catalog 缓存键
	@param scope string - 作用域（Shared / Server）
	@param catalog string - catalog 名称
	@return string - 缓存键
]]
local function _makeCatalogCacheKey(scope: string, catalog: string): string
	return scope .. CATALOG_CACHE_SEP .. catalog
end

--[[
	在指定根下查找 Assets 文件夹
	@param root Instance - ReplicatedStorage 或 ServerStorage
	@return Folder? - Assets 根目录；不存在或类型不是 Folder 时 nil
]]
local function _findAssetsRootUnder(root: Instance): Folder?
	local assets = root:FindFirstChild(ASSETS_ROOT_NAME)
	if assets and assets:IsA("Folder") then
		return assets
	end
	return nil
end

--[[
	迁移期：在 RS/SS 根下查找旧 catalog（如 ModelRes）
	@param root Instance - 存储根
	@param catalog string - catalog 名
	@return Folder? - 旧目录；非白名单 catalog 或不存在时 nil
]]
local function _findLegacyCatalogUnder(root: Instance, catalog: string): Folder?
	if not LEGACY_ROOT_CATALOGS[catalog] then
		return nil
	end
	local legacy = root:FindFirstChild(catalog)
	if legacy and legacy:IsA("Folder") then
		return legacy
	end
	return nil
end

--[[
	按 segments 从 startIndex 起逐级 FindFirstChild
	@param root Instance - 起始节点
	@param segments {string} - 路径分段
	@param startIndex number - 起始下标（含），1-based
	@return Instance? - 目标实例；中途缺失子节点时 nil
]]
local function _traversePath(root: Instance, segments: { string }, startIndex: number): Instance?
	local current: Instance = root
	for i = startIndex, #segments do
		local segment = segments[i]
		if segment ~= "" then
			local child = current:FindFirstChild(segment)
			if not child then
				return nil
			end
			current = child
		end
	end
	return current
end

--[[
	读取或填充指定 scope 的 Assets 根缓存
	@param scopeLabel string - AssetPaths.Scope.Shared 或 Server
	@param storageRoot Instance - ReplicatedStorage 或 ServerStorage
	@return Folder? - Assets 根目录；不存在时 nil（写入负缓存）
]]
local function _getCachedAssetsRoot(scopeLabel: string, storageRoot: Instance): Folder?
	local cachedFolder, isCached = _readFolderCache(_assetsRootCache[scopeLabel])
	if isCached then
		return cachedFolder
	end
	local root = _findAssetsRootUnder(storageRoot)
	_assetsRootCache[scopeLabel] = root or false
	return root
end

--[[
	在指定 scope 的存储根下解析 catalog
	@param catalog string - 一级目录名
	@param storageRoot Instance - RS 或 SS
	@param scopeLabel string - 用于缓存键的 scope（Shared / Server）
	@return Folder? - catalog 目录；不存在时 nil（写入负缓存）
]]
local function _resolveCatalogUnderStorage(catalog: string, storageRoot: Instance, scopeLabel: string): Folder?
	local cacheKey = _makeCatalogCacheKey(scopeLabel, catalog)
	local cachedFolder, isCached = _readFolderCache(_catalogCache[cacheKey])
	if isCached then
		return cachedFolder
	end

	local resolved: Folder? = nil
	local assetsRoot = _findAssetsRootUnder(storageRoot)
	if assetsRoot then
		local folder = assetsRoot:FindFirstChild(catalog)
		if folder and folder:IsA("Folder") then
			resolved = folder
		end
	end

	if not resolved then
		resolved = _findLegacyCatalogUnder(storageRoot, catalog)
	end

	_catalogCache[cacheKey] = resolved or false
	return resolved
end

-- ============================================================================
-- 公共 API
-- ============================================================================

--[[
	获取 Assets 根目录（ReplicatedStorage.Assets 或 ServerStorage.Assets）

	@param scope string? - AssetPaths.Scope.Shared / Server / Auto，默认 Shared
	@return Folder? - Assets 根 Folder；不存在或客户端查 Server 时返回 nil

	示例：
		local root = AssetPaths.GetAssetsRoot()                      -- RS.Assets
		local serverRoot = AssetPaths.GetAssetsRoot(AssetPaths.Scope.Server)
]]
function AssetPaths.GetAssetsRoot(scope: string?): Folder?
	local scopeValue = _normalizeScope(scope)

	if scopeValue == AssetPaths.Scope.Shared then
		return _getCachedAssetsRoot(AssetPaths.Scope.Shared, ReplicatedStorage)
	end

	if scopeValue == AssetPaths.Scope.Server then
		if not ServerStorage then
			return nil
		end
		return _getCachedAssetsRoot(AssetPaths.Scope.Server, ServerStorage)
	end

	-- Auto：有 ServerStorage 时优先 SS，否则 RS（客户端无 SS，等同 Shared）
	if ServerStorage then
		local serverRoot = _getCachedAssetsRoot(AssetPaths.Scope.Server, ServerStorage)
		if serverRoot then
			return serverRoot
		end
	end
	return _getCachedAssetsRoot(AssetPaths.Scope.Shared, ReplicatedStorage)
end

--[[
	获取一级 catalog 目录（如 ModelRes、UI）

	解析顺序：{存储根}/Assets/{catalog} → 迁移期 {存储根}/{catalog}（仅 ModelRes）

	@param catalog string - 一级目录名，如 "ModelRes"、"UI"；非字符串或空串返回 nil
	@param scope string? - AssetPaths.Scope.Shared / Server / Auto，默认 Shared
	@return Folder? - catalog 目录；不存在时返回 nil

	示例：
		local ui = AssetPaths.GetCatalog("UI")
		local serverUi = AssetPaths.GetCatalog("UI", AssetPaths.Scope.Server)
]]
function AssetPaths.GetCatalog(catalog: string, scope: string?): Folder?
	if type(catalog) ~= "string" or catalog == "" then
		return nil
	end

	local scopeValue = _normalizeScope(scope)

	if scopeValue == AssetPaths.Scope.Auto then
		if ServerStorage then
			local serverCatalog = _resolveCatalogUnderStorage(catalog, ServerStorage, AssetPaths.Scope.Server)
			if serverCatalog then
				return serverCatalog
			end
		end
		return _resolveCatalogUnderStorage(catalog, ReplicatedStorage, AssetPaths.Scope.Shared)
	end

	if scopeValue == AssetPaths.Scope.Server then
		if not ServerStorage then
			return nil
		end
		return _resolveCatalogUnderStorage(catalog, ServerStorage, AssetPaths.Scope.Server)
	end

	return _resolveCatalogUnderStorage(catalog, ReplicatedStorage, AssetPaths.Scope.Shared)
end

--[[
	按相对路径解析资源实例（最常用 API）

	路径以 catalog 开头，用 "/" 分段，支持中文目录名。
	先定位 catalog，再逐级 FindFirstChild。

	@param relativePath string - 如 "ModelRes/Pet/Cat1"、"UI/Tips/BGTemp"；非字符串或空串返回 nil
	@param scope string? - AssetPaths.Scope.Shared / Server / Auto，默认 Shared
	@return Instance? - 目标实例；路径无效或未找到时返回 nil

	示例：
		local template = AssetPaths.Resolve("ModelRes/Skill/Meteor")
		local bg = AssetPaths.Resolve("UI/Tips/BGTemp")
		local rank = AssetPaths.Resolve("ModelRes/排行榜/RankTemp", AssetPaths.Scope.Server)

	注意：返回的是模板引用，需要 Clone 时请用 AssetAcquire.Get 或 ResourceUtil.Get。
]]
function AssetPaths.Resolve(relativePath: string, scope: string?): Instance?
	if type(relativePath) ~= "string" or relativePath == "" then
		return nil
	end

	local scopeValue = _normalizeScope(scope)
	local segments: { string } = {}
	for segment in string.gmatch(relativePath, PATH_SEGMENT_PATTERN) do
		table.insert(segments, segment)
	end
	if #segments == 0 then
		return nil
	end

	local catalogName = segments[1]
	local catalog = AssetPaths.GetCatalog(catalogName, scopeValue)
	if not catalog then
		return nil
	end

	if #segments == 1 then
		return catalog
	end

	return _traversePath(catalog, segments, 2)
end

--[[
	清除路径查找缓存

	适用场景：Studio 热重载、运行时动态增删 Assets 子目录后需重新解析。
	不影响已 Clone 出去的实例，也不重置非法 scope 的「已警告」标记。

	@return () - 无返回值

	示例：
		AssetPaths.ClearCache()
		local fresh = AssetPaths.Resolve("ModelRes/Pet/Cat1")
]]
function AssetPaths.ClearCache()
	table.clear(_assetsRootCache)
	table.clear(_catalogCache)
end

return table.freeze(AssetPaths)
