--[[
	Module: DataCache
	Description: 玩家昵称与头像 URL 的运行时 Instance 缓存，减少 Roblox API 调用
	Author: 林奥宇
	Created: 2026-07-03
	Last Modified: 2026-08-31

	功能：
	- GetPlrName / GetPortrait：读 StringValue 缓存；未命中时同步 yield 拉 Roblox API 再写入
	- UpdatePortrait：缓存命中后按间隔异步刷新头像（先拉成功再写时间戳）
	- ClearCache：标记-清扫未使用条目（仅服务端 UpdateModule 定时触发）
	- Init(opts)：由 Manager 注入 cacheRoot / 是否清名字 / 是否注册清扫

	约束：
	- 仅展示用缓存，不写存档、不发奖、不绑 Remote、不写位姿
	- 模块内禁止 RunService:IsServer()；端差异由 Init 注入或 Utils.ServerStorage 是否存在决定
	- 客机在 ReplicatedStorage 下建 Folder 为本地实例（FilteringEnabled 不复制到其他端）
	- 首次 Get 会 yield（GetNameFromUserIdAsync / GetUserThumbnailAsync），勿放 Heartbeat 热路径
	- 不要从业务 System 互调 Init；UpdateManager 显式 Init，其余走惰性 _ensureInit
	- UpdateModule.Register 仅服务端生效，客机不清扫（排行榜 userId 集合有限）

	与同类：
	- 写榜权威在 SystemRank；本模块只给人名 / 头像 URL
	- 客户端 SystemRankManager 消费 GetPlrName / GetPortrait

	加载方式：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local DataCache = Utils.DataCache
		-- 服务端 UpdateManager：
		DataCache.Init({
			cacheRoot = ServerStorage,
			clearNameOnSweep = true,
			registerSweep = true,
		})
		-- 客户端：GetPlrName 时惰性 Init，根目录 ReplicatedStorage，不注册清扫

	使用示例：
		local name = DataCache.GetPlrName(userId)
		local portraitUrl = DataCache.GetPortrait(userId)
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Debris = Utils.Debris
local Players = Utils.Players
local ReplicatedStorage = Utils.ReplicatedStorage
local ServerStorage = Utils.ServerStorage
local InsMgr = Utils.InsMgr
local Log = Utils.Log
local UpdateModule = Utils.UpdateModule

-- ========================================
-- 模块定义
-- ========================================
local DataCache = {}

export type InitOpts = {
	cacheRoot: Instance?,
	clearNameOnSweep: boolean?,
	registerSweep: boolean?,
}

-- ========================================
-- 常量定义
-- ========================================
local CACHE_FOLDER_NAMES = {
	PLAYER_NAME = "玩家名字缓存",
	PLAYER_PORTRAIT = "玩家头像缓存",
}
table.freeze(CACHE_FOLDER_NAMES)

local PORTRAIT_UPDATE_INTERVAL = 3600
local CACHE_SWEEP_INTERVAL = UpdateModule.INTERVAL.SEC_300
local CACHE_SWEEP_INITIAL_ELAPSED = 200
local FALLBACK_NAME = "???"
local ATTR_USE = "use"
local ATTR_LAST_UPDATE = "T"
local ATTR_USE_MARKED = 1
local ATTR_USE_CLEARED = 0
local PORTRAIT_THUMBNAIL_TYPE = Enum.ThumbnailType.HeadShot
local PORTRAIT_THUMBNAIL_SIZE = Enum.ThumbnailSize.Size60x60

-- ========================================
-- 私有变量
-- ========================================
local _initialized = false
local _cacheRoot: Instance? = nil
local _clearNameCacheOnSweep = false

-- ========================================
-- 私有函数
-- ========================================

--[[
	确保模块已 Init；允许在 Manager 未显式 Init 时惰性初始化

	@return nil
]]
local function _ensureInit()
	if not _initialized then
		DataCache.Init()
	end
end

--[[
	userId 是否可作为缓存键（须为正数）

	@param userId any - 调用方传入的用户 ID
	@return boolean - true 表示可查 Roblox API / 作 Instance 名
]]
local function _isValidUserId(userId: any): boolean
	return type(userId) == "number" and userId > 0
end

--[[
	获取当前端缓存根目录下的子文件夹

	@param folderName string - 缓存文件夹 Instance 名称
	@return Folder - 缓存文件夹
]]
local function _getCacheFolder(folderName: string): Folder
	_ensureInit()
	return InsMgr.GetIns(folderName, "Folder", _cacheRoot :: Instance)
end

--[[
	按 userId 查找已有 StringValue 缓存条目

	@param folder Folder - 缓存文件夹
	@param userId number - Roblox 用户 ID
	@return StringValue? - 命中的条目；无或不为 StringValue 时为 nil
]]
local function _findCacheEntry(folder: Folder, userId: number): StringValue?
	local inst = folder:FindFirstChild(tostring(userId))
	if inst and inst:IsA("StringValue") then
		return inst
	end
	return nil
end

--[[
	标记缓存条目为本轮已使用

	@param cache StringValue - 缓存 StringValue 实例
	@return nil
]]
local function _addUseTag(cache: StringValue)
	cache:SetAttribute(ATTR_USE, ATTR_USE_MARKED)
end

--[[
	写入或复用 StringValue 缓存条目

	@param folder Folder - 缓存文件夹
	@param userId number - Roblox 用户 ID，用作 Instance.Name
	@param value string - 写入 Value 的字符串
	@param onCreate ((StringValue) -> ())? - 新建或覆盖后的钩子（如写头像时间戳）
	@return StringValue - 写入后的缓存条目
]]
local function _writeCacheEntry(
	folder: Folder,
	userId: number,
	value: string,
	onCreate: ((StringValue) -> ())?
): StringValue
	local entry = InsMgr.GetIns(tostring(userId), "StringValue", folder) :: StringValue
	entry.Value = value
	_addUseTag(entry)
	if onCreate then
		onCreate(entry)
	end
	return entry
end

--[[
	清扫未使用缓存：未标记 use 则销毁，已标记则清零待下轮判定

	@param cache StringValue - 缓存 StringValue 实例
	@return nil
]]
local function _delUnusedCache(cache: StringValue)
	if cache:GetAttribute(ATTR_USE) ~= ATTR_USE_MARKED then
		Debris:AddItem(cache, 0)
	else
		cache:SetAttribute(ATTR_USE, ATTR_USE_CLEARED)
	end
end

--[[
	从头像条目写入刷新时间戳

	@param entry StringValue - 头像缓存条目
	@return nil
]]
local function _stampPortraitTime(entry: StringValue)
	entry:SetAttribute(ATTR_LAST_UPDATE, os.time())
end

--[[
	从 Roblox API 拉取玩家昵称（会 yield）

	@param userId number - Roblox 用户 ID
	@return string - 昵称；失败或空时返回 FALLBACK_NAME
]]
local function _fetchPlrNameFromApi(userId: number): string
	local name = ""
	local success, err = pcall(function()
		name = Players:GetNameFromUserIdAsync(userId)
	end)

	if not success then
		Log.warn("DataCache._fetchPlrNameFromApi failed", userId, err)
		return FALLBACK_NAME
	end

	if name == "" then
		return FALLBACK_NAME
	end

	return name
end

--[[
	从 Roblox API 拉取玩家头像 URL（会 yield）

	@param userId number - Roblox 用户 ID
	@return string - 头像 rbxassetid URL；失败时返回空字符串
]]
local function _fetchPortraitFromApi(userId: number): string
	local avatarImage = ""
	local success, err = pcall(function()
		local image = Players:GetUserThumbnailAsync(
			userId,
			PORTRAIT_THUMBNAIL_TYPE,
			PORTRAIT_THUMBNAIL_SIZE
		)
		avatarImage = image or ""
	end)

	if not success then
		Log.warn("DataCache._fetchPortraitFromApi failed", userId, err)
	end

	return avatarImage
end

--[[
	遍历文件夹内 StringValue 并清扫未使用条目

	@param folder Folder - 缓存文件夹
	@return nil
]]
local function _sweepFolder(folder: Folder)
	for _, child in folder:GetChildren() do
		if child:IsA("StringValue") then
			_delUnusedCache(child)
		end
	end
end

-- ========================================
-- 公共函数
-- ========================================

--[[
	获取玩家名字（带缓存）

	@param userId number - Roblox 用户 ID；非正数时返回占位符
	@return string - 玩家昵称；无法获取时为 "???"
]]
function DataCache.GetPlrName(userId: number): string
	if not _isValidUserId(userId) then
		return FALLBACK_NAME
	end

	local plrNameCache = _getCacheFolder(CACHE_FOLDER_NAMES.PLAYER_NAME)
	local username = _findCacheEntry(plrNameCache, userId)
	if username then
		_addUseTag(username)
		return username.Value
	end

	local name = _fetchPlrNameFromApi(userId)
	if name ~= FALLBACK_NAME then
		_writeCacheEntry(plrNameCache, userId, name)
	end
	return name
end

--[[
	获取玩家头像 URL（带缓存）

	@param userId number - Roblox 用户 ID；非正数时返回空字符串
	@return string - HeadShot 60x60 头像 URL；失败时为空字符串
]]
function DataCache.GetPortrait(userId: number): string
	if not _isValidUserId(userId) then
		return ""
	end

	local portraitCache = _getCacheFolder(CACHE_FOLDER_NAMES.PLAYER_PORTRAIT)
	local portraitUrl = _findCacheEntry(portraitCache, userId)
	if portraitUrl then
		_addUseTag(portraitUrl)
		DataCache.UpdatePortrait(userId)
		return portraitUrl.Value
	end

	local avatarImage = _fetchPortraitFromApi(userId)
	if avatarImage ~= "" then
		_writeCacheEntry(portraitCache, userId, avatarImage, _stampPortraitTime)
	end
	return avatarImage
end

--[[
	检查头像缓存是否过期，过期则异步重新拉取并写回

	@param userId number - Roblox 用户 ID
	@return nil
]]
function DataCache.UpdatePortrait(userId: number)
	if not _isValidUserId(userId) then
		return
	end

	local portraitCache = _getCacheFolder(CACHE_FOLDER_NAMES.PLAYER_PORTRAIT)
	local portraitValue = _findCacheEntry(portraitCache, userId)
	if not portraitValue then
		return
	end

	local lastUpdateTime = portraitValue:GetAttribute(ATTR_LAST_UPDATE)
	if type(lastUpdateTime) ~= "number" then
		_stampPortraitTime(portraitValue)
		return
	end

	if os.time() - lastUpdateTime <= PORTRAIT_UPDATE_INTERVAL then
		return
	end

	task.spawn(function()
		local avatarImage = _fetchPortraitFromApi(userId)
		if avatarImage == "" then
			return
		end

		local currentValue = _findCacheEntry(portraitCache, userId)
		if currentValue then
			currentValue.Value = avatarImage
			_stampPortraitTime(currentValue)
			_addUseTag(currentValue)
		end
	end)
end

--[[
	清理本轮未使用的缓存条目

	@return nil
]]
function DataCache.ClearCache()
	_ensureInit()

	local portraitCache = _getCacheFolder(CACHE_FOLDER_NAMES.PLAYER_PORTRAIT)
	_sweepFolder(portraitCache)

	if _clearNameCacheOnSweep then
		local plrNameCache = _getCacheFolder(CACHE_FOLDER_NAMES.PLAYER_NAME)
		_sweepFolder(plrNameCache)
	end
end

-- ========================================
-- 初始化
-- ========================================

--[[
	初始化缓存根目录；服务端由 UpdateManager 注入并注册定时清扫

	@param opts InitOpts? - 可选配置：
		cacheRoot Instance? - 缓存 Folder 父级；缺省时服为 ServerStorage、客为 ReplicatedStorage
		clearNameOnSweep boolean? - true 时 ClearCache 同时清名字；缺省与是否存在 ServerStorage 一致
		registerSweep boolean? - true 时向 UpdateModule 注册清扫；缺省与是否存在 ServerStorage 一致
	@return nil
]]
function DataCache.Init(opts: InitOpts?)
	if _initialized then
		return
	end
	_initialized = true

	local initOpts = opts or {}
	if initOpts.cacheRoot then
		_cacheRoot = initOpts.cacheRoot
	elseif ServerStorage then
		_cacheRoot = ServerStorage
	else
		_cacheRoot = ReplicatedStorage
	end

	if initOpts.clearNameOnSweep ~= nil then
		_clearNameCacheOnSweep = initOpts.clearNameOnSweep
	else
		_clearNameCacheOnSweep = ServerStorage ~= nil
	end

	local shouldRegisterSweep
	if initOpts.registerSweep ~= nil then
		shouldRegisterSweep = initOpts.registerSweep
	else
		shouldRegisterSweep = ServerStorage ~= nil
	end

	if shouldRegisterSweep then
		UpdateModule.Register(CACHE_SWEEP_INTERVAL, function(_elapsed: number)
			DataCache.ClearCache()
		end, { spawn = true, initialElapsed = CACHE_SWEEP_INITIAL_ELAPSED })
	end
end

return DataCache
