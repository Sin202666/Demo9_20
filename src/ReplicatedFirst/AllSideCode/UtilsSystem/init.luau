--[[
	Module: UtilsSystem
	Description: 框架统一模块访问入口，延迟加载、循环引用检测、通信对象索引
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-09-01

	使用方法：
	  local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

	  -- Services 可以立即访问（不会造成循环引用）
	  local Players = Utils.Players
	  local TweenService = Utils.TweenService

	  -- 模块使用延迟加载（第一次访问时才加载，避免循环引用）
	  local Log = Utils.Log
	  local CfgFind = Utils.CfgFind

	  -- 独立模块：非延迟加载（启动时即 require，见 EAGER_LOAD_WHITELIST）
	  local NetMsg = Utils.NetMsg
	  local EnumMgr = Utils.EnumMgr

	  -- 通信统一走 NetWork（推荐）
	  local NetWork = Utils.NetWork
	  NetWork.FireServer(NetMsg.SOME_MSG, payload)

	  -- 旧通信对象表（仅供 NetWork 内部使用，业务请勿直接访问）
	  local myEvent = Utils.Event.EventName
	  local myRemoteEvent = Utils.RemoteEvent.EventName

	  -- 服务器端模块（仅在服务器端可用；ModuleScript 名即 Utils 键名）
	  if RunService:IsServer() then
	    local SystemSave = Utils.SystemSave
	    local SystemBag = Utils.SystemBag
	  end

	  -- 客户端系统模块（双端可用；SystemModule 下 ModuleScript 或 Folder/init）
	  local DataCache = Utils.DataCache

	延迟加载：按需 require + _loadedModules 缓存 + _loadingModules 循环检测。
	非延迟白名单（EAGER_LOAD_WHITELIST）：纯数据/常量、无 Utils 依赖、无副作用；新增须经框架评审。
	循环引用：检测到加载中重复访问时 warn，并降级为直接路径 require（pcall）。
	动态 System 键首次 miss 不 warn（避免误访问属性时刷屏）。
	路径注册表见同目录 ModuleRegistry；业务不要直接 require 该子模块。
]]

-- ============================================================================
-- 服务引用
-- ============================================================================

local RunService = game:GetService("RunService")
local IS_SERVER = RunService:IsServer()
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local TeleportService = game:GetService("TeleportService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local SoundService = game:GetService("SoundService")
local GamepadService = game:GetService("GamepadService")
local TextChatService = game:GetService("TextChatService")
local TweenService = game:GetService("TweenService")
local CollectionService = game:GetService("CollectionService")
local ScriptContext = game:GetService("ScriptContext")
local HttpService = game:GetService("HttpService")
local ContentProvider = game:GetService("ContentProvider")
local Lighting = game:GetService("Lighting")
local CoreGui = game:GetService("CoreGui")
local StarterGui = game:GetService("StarterGui")
local StarterPack = game:GetService("StarterPack")
local Selection = game:GetService("Selection")
local ChangeHistoryService = game:GetService("ChangeHistoryService")

local ServerStorage: Instance? = nil
if IS_SERVER then
	ServerStorage = game:GetService("ServerStorage")
end

-- ============================================================================
-- 模块引用
-- ============================================================================

local AllSideCode = ReplicatedFirst.AllSideCode
local Interface = require(AllSideCode.Interface)
local ModuleRegistry = require(script.ModuleRegistry)

type Utils = Interface.Utils

-- ============================================================================
-- 模块定义
-- ============================================================================

local UtilsSystem: Utils = {}

-- ============================================================================
-- 常量定义
-- ============================================================================

local MSG_FOLDER_NAME = "Msg"
local EVENT_FOLDER_NAME = "Event"
local REMOTE_EVENT_FOLDER_NAME = "RemoteEvent"
local REMOTE_FUNCTION_FOLDER_NAME = "RemoteFunction"
local FUNCTION_FOLDER_NAME = "Function"
-- Msg 未及时同步时用 WaitForChild 二次拉取的超时（秒）
local MSG_REPLICATION_FALLBACK_TIMEOUT_SEC = 15

type EagerLoadScope = "ToolBasic" | "ToolSystem"

type EagerLoadEntry = {
	scope: EagerLoadScope,
	name: string,
}

-- 准入条件（全部满足才可加入）：
--   1. 纯数据/常量表，无 require 其他 Utils 模块
--   2. 无副作用：无 Init、无事件绑定、无 RunService 分支逻辑
--   3. 无循环引用风险
-- 新增条目须经框架评审，不得随意扩容。
local EAGER_LOAD_WHITELIST: { EagerLoadEntry } = {
	{ scope = "ToolBasic", name = "NetMsg" },
	{ scope = "ToolSystem", name = "EnumMgr" },
}

-- ============================================================================
-- 私有变量
-- ============================================================================

local _toolPath: Instance = AllSideCode:FindFirstChild("ToolBasic") :: Instance
local _systemPath: Instance = AllSideCode:FindFirstChild("ToolSystem") :: Instance

local _serverSystemPath: Instance? = nil
local _serverStoragePath: Instance? = ServerStorage
if IS_SERVER and ServerStorage then
	local serverSideCode = ServerStorage:FindFirstChild("ServerSideCode")
	if serverSideCode then
		_serverSystemPath = serverSideCode:FindFirstChild("System") :: Instance?
	end
end

local _registries = ModuleRegistry.Create({
	toolPath = _toolPath,
	systemPath = _systemPath,
	allSideCode = AllSideCode,
	serverSystemPath = _serverSystemPath,
	serverStoragePath = _serverStoragePath,
	isServer = IS_SERVER,
	replicatedStorage = ReplicatedStorage,
})
local _toolModules = _registries.toolModules
local _systemModules = _registries.systemModules
local _serverRootModules = _registries.serverRootModules

local EAGER_LOAD_REGISTRIES: { [EagerLoadScope]: { [string]: () -> Instance? } } = {
	ToolBasic = _toolModules,
	ToolSystem = _systemModules,
}

local _loadedModules: { [string]: any } = {}
local _loadingModules: { [string]: boolean } = {}

-- ============================================================================
-- 私有函数
-- ============================================================================

--[[
	pcall require，失败时 warn 并返回 nil

	@param moduleScript Instance - 待 require 的 ModuleScript
	@param name string - 注册键名，用于 warn
	@param categoryLabel string - 日志分类（如「工具模块」）
	@return any? - require 结果；失败时 nil
]]
local function _pcallRequire(moduleScript: Instance, name: string, categoryLabel: string): any?
	local success, result = pcall(require, moduleScript)
	if success then
		return result
	end
	warn("加载" .. categoryLabel .. "失败:", name, result)
	return nil
end

--[[
	循环引用降级：pcall 直接 require 解析路径，不写入缓存（模块可能尚未完成初始化）

	@param getPath (() -> Instance?)? - 路径解析闭包
	@param name string - 注册键名
	@param categoryLabel string - 日志分类
	@return any? - require 结果；路径缺失或 require 失败时 nil
]]
local function _requireCircularFallback(
	getPath: (() -> Instance?)?,
	name: string,
	categoryLabel: string
): any?
	if not getPath then
		return nil
	end
	local circularPath = getPath()
	if not circularPath then
		return nil
	end
	return _pcallRequire(circularPath, name, categoryLabel .. "（循环降级）")
end

--[[
	通用延迟加载：缓存命中、循环引用降级、pcall require、写入 _loadedModules

	@param name string - 模块注册键名
	@param categoryLabel string - 日志分类（如「工具模块」），用于 warn 前缀
	@param getModulePath (() -> Instance?)? - 正常路径解析；nil 表示 registry 无条目
	@param resolveCircularPath (() -> Instance?)? - 循环引用时的直接 require 路径
	@param warnIfNotRegistered boolean - registry 无条目时是否 warn
	@param warnIfPathMissing boolean - 实例路径不存在时是否 warn
	@return any? - require 结果；失败或不存在时 nil
]]
local function _loadModule(
	name: string,
	categoryLabel: string,
	getModulePath: (() -> Instance?)?,
	resolveCircularPath: (() -> Instance?)?,
	warnIfNotRegistered: boolean,
	warnIfPathMissing: boolean
): any?
	if _loadedModules[name] then
		return _loadedModules[name]
	end

	if _loadingModules[name] then
		warn("检测到潜在的循环引用，模块正在加载中:", name)
		local circularResult = _requireCircularFallback(resolveCircularPath, name, categoryLabel)
		if circularResult ~= nil then
			return circularResult
		end
		return _requireCircularFallback(getModulePath, name, categoryLabel)
	end

	if not getModulePath then
		if warnIfNotRegistered then
			warn(categoryLabel .. "不存在:", name)
		end
		return nil
	end

	local modulePath = getModulePath()
	if not modulePath then
		if warnIfPathMissing then
			warn(categoryLabel .. "路径不存在:", name)
		end
		return nil
	end

	_loadingModules[name] = true
	local result = _pcallRequire(modulePath, name, categoryLabel)
	_loadingModules[name] = nil

	if result ~= nil then
		_loadedModules[name] = result
	end
	return result
end

--[[
	延迟加载 ToolBasic 注册模块

	@param name string - _toolModules 注册键名
	@return any? - require 结果；失败或不存在时 nil
]]
local function _loadToolModule(name: string): any?
	-- 导表 ConfigInstance 经 ConfigPrepare 做键名 remap + freeze，生成物文件本身不改逻辑
	if name == "ConfigInstance" then
		if _loadedModules[name] then
			return _loadedModules[name]
		end
		if _loadingModules[name] then
			warn("检测到潜在的循环引用，模块正在加载中:", name)
			local preparePath = ModuleRegistry.ResolveModuleScript(_toolPath:FindFirstChild("ConfigPrepare"))
			if preparePath then
				local Prepare = _pcallRequire(preparePath, name, "工具模块（循环降级）")
				if Prepare then
					return Prepare.Get()
				end
			end
			return nil
		end
		local preparePath = ModuleRegistry.ResolveModuleScript(_toolPath:FindFirstChild("ConfigPrepare"))
		if not preparePath then
			warn("加载工具模块失败: ConfigPrepare 不存在")
			return nil
		end
		_loadingModules[name] = true
		local Prepare = _pcallRequire(preparePath, "ConfigPrepare", "工具模块")
		_loadingModules[name] = nil
		if not Prepare then
			return nil
		end
		local result = Prepare.Get()
		_loadedModules[name] = result
		return result
	end

	local registryFn = _toolModules[name]
	local function resolvePath(): Instance?
		if not registryFn then
			return nil
		end
		return registryFn()
	end
	return _loadModule(name, "工具模块", registryFn and resolvePath or nil, resolvePath, true, true)
end

--[[
	延迟加载 ToolSystem 注册模块

	@param name string - _systemModules 注册键名
	@return any? - require 结果；失败或不存在时 nil
]]
local function _loadSystemModule(name: string): any?
	local registryFn = _systemModules[name]
	local function resolvePath(): Instance?
		if not registryFn then
			return nil
		end
		return registryFn()
	end
	return _loadModule(name, "业务模块", registryFn and resolvePath or nil, resolvePath, true, true)
end

--[[
	按白名单在启动时立即 require 独立模块，写入 UtilsSystem 表与 _loadedModules 缓存

	白名单条目必须在对应 registry 中已注册，否则 warn 并跳过
]]
local function _eagerLoadWhitelistedModules(): ()
	for _, entry in EAGER_LOAD_WHITELIST do
		local registry = EAGER_LOAD_REGISTRIES[entry.scope]
		if not registry then
			warn("[UtilsSystem] 非延迟白名单 scope 无效:", entry.scope, entry.name)
			continue
		end

		local getModulePath = registry[entry.name]
		if not getModulePath then
			warn("[UtilsSystem] 非延迟白名单模块未注册:", entry.scope, entry.name)
			continue
		end

		local modulePath = getModulePath()
		if not modulePath then
			warn("[UtilsSystem] 非延迟白名单模块路径不存在:", entry.scope, entry.name)
			continue
		end

		local result = _pcallRequire(modulePath, entry.name, "非延迟白名单模块")
		if result == nil then
			continue
		end

		_loadedModules[entry.name] = result
		UtilsSystem[entry.name] = result
	end
end

--[[
	延迟加载 ServerStorage 根目录注册模块（仅服务端）

	@param name string - _serverRootModules 注册键名
	@return any? - require 结果；非服务端、失败或不存在时 nil
]]
local function _loadServerRootModule(name: string): any?
	if not IS_SERVER then
		warn("ServerStorage 根模块仅在服务器端可用:", name)
		return nil
	end

	local registryFn = _serverRootModules[name]
	local function resolvePath(): Instance?
		if not registryFn then
			return nil
		end
		return registryFn()
	end

	return _loadModule(name, "ServerStorage 根模块", registryFn and resolvePath or nil, resolvePath, true, true)
end

--[[
	延迟加载 ServerStorage.ServerSideCode.System 下模块（仅服务端）

	@param name string - System 目录下模块名，与 Utils 键名一致
	@return any? - require 结果；非服务端、失败或不存在时 nil
]]
local function _loadServerSystemModule(name: string): any?
	if not IS_SERVER then
		warn("服务器端模块仅在服务器端可用:", name)
		return nil
	end
	if not _serverSystemPath then
		warn("服务器端系统路径不存在")
		return nil
	end

	local function resolvePath(): Instance?
		return ModuleRegistry.ResolveModuleScript(_serverSystemPath:FindFirstChild(name))
	end

	return _loadModule(name, "服务器端系统模块", resolvePath, resolvePath, false, false)
end

--[[
	懒解析 ClientSideCode.SystemModule 根目录，避免 ReplicatedFirst 阶段 ClientSideCode 尚未复制

	@return Instance? - SystemModule 文件夹；不存在时 nil
]]
local function _getClientSystemPath(): Instance?
	local clientSideCode = ReplicatedStorage:FindFirstChild("ClientSideCode")
	if not clientSideCode then
		return nil
	end
	return clientSideCode:FindFirstChild("SystemModule") :: Instance?
end

--[[
	解析 ClientSideCode.SystemModule 下的模块实例

	@param parent Instance? - SystemModule 根目录
	@param name string - 模块名（SystemTask）或 Folder 名（SystemGuide → init）
	@return ModuleScript? - 可 require 的 ModuleScript；不存在时 nil
]]
local function _getClientSystemModuleScript(parent: Instance?, name: string): ModuleScript?
	if not parent then
		return nil
	end
	return ModuleRegistry.ResolveModuleScript(parent:FindFirstChild(name))
end

--[[
	延迟加载 ClientSideCode.SystemModule 下模块（双端可用）

	@param name string - SystemModule 下模块名或 Folder 名
	@return any? - require 结果；失败或不存在时 nil
]]
local function _loadClientSystemModule(name: string): any?
	local clientSysPath = _getClientSystemPath()
	if not clientSysPath then
		warn("客户端系统路径不存在")
		return nil
	end

	local function resolvePath(): Instance?
		return _getClientSystemModuleScript(clientSysPath, name)
	end

	return _loadModule(
		name,
		"客户端系统模块",
		resolvePath,
		function()
			return _getClientSystemModuleScript(_getClientSystemPath(), name)
		end,
		false,
		false
	)
end

--[[
	从 ReplicatedStorage.Msg 获取指定子文件夹（FindFirstChild + 超时 WaitForChild）

	@param subFolderName string - Msg 子文件夹名（Event / RemoteEvent 等）
	@return Instance? - 子文件夹；超时或不存在时 nil
]]
local function _getMsgSubFolder(subFolderName: string): Instance?
	local msgFolder = ReplicatedStorage:FindFirstChild(MSG_FOLDER_NAME)
	if not msgFolder then
		msgFolder = ReplicatedStorage:WaitForChild(MSG_FOLDER_NAME, MSG_REPLICATION_FALLBACK_TIMEOUT_SEC)
	end
	if not msgFolder then
		return nil
	end
	local targetFolder = msgFolder:FindFirstChild(subFolderName)
	if not targetFolder then
		targetFolder = msgFolder:WaitForChild(subFolderName, MSG_REPLICATION_FALLBACK_TIMEOUT_SEC)
	end
	return targetFolder
end

--[[
	当查找表里没有某个键对应的实例时，再次从 ReplicatedStorage.Msg.<subFolder> 读取并补齐

	@param lookupTable { [string]: Instance? } - 通信对象查找表（原地写入）
	@param subFolderName string - Msg 子文件夹名
]]
local function _tryMergeMissingMsgChildrenIntoLookup(
	lookupTable: { [string]: Instance? },
	subFolderName: string
): ()
	local targetFolder = _getMsgSubFolder(subFolderName)
	if not targetFolder then
		return
	end
	for _, child in targetFolder:GetChildren() do
		if rawget(lookupTable, child.Name) == nil then
			rawset(lookupTable, child.Name, child :: Instance?)
		end
	end
end

--[[
	为 Msg 下发的查找表挂 __index：首次访问不到的键时再尝试从未同步的子文件夹补齐

	@param lookupTable { [string]: Instance? } - 通信对象查找表
	@param subFolderName string - Msg 子文件夹名
	@return { [string]: Instance? } - 挂载元表后的 lookupTable（同一引用）
]]
local function _attachLazyMsgLookupSync(
	lookupTable: { [string]: Instance? },
	subFolderName: string
): { [string]: Instance? }
	setmetatable(lookupTable :: any, {
		__index = function(t: any, key: any): Instance?
			if typeof(key) ~= "string" then
				return nil
			end
			local existing = rawget(t, key)
			if existing ~= nil then
				return existing
			end
			_tryMergeMissingMsgChildrenIntoLookup(t, subFolderName)
			return rawget(t, key)
		end,
	})
	return lookupTable
end

--[[
	创建 Msg 子文件夹通信对象查找表（启动时预索引已有子项）

	@param folderName string - Msg 子文件夹名（Event / RemoteEvent / RemoteFunction / Function）
	@return { [string]: Instance? } - 名称到 Instance 的查找表；文件夹未就绪时为空表
]]
local function _createEventTable(folderName: string): { [string]: Instance? }
	local eventTable: { [string]: Instance? } = {}
	local targetFolder = _getMsgSubFolder(folderName)
	if not targetFolder then
		return eventTable
	end
	for _, child in targetFolder:GetChildren() do
		eventTable[child.Name] = child
	end
	return eventTable
end

--[[
	成功加载后写入 UtilsSystem 原表，后续访问不再走 __index

	@param self Utils - UtilsSystem 表
	@param key string - Utils 访问键
	@param result any? - require 结果
	@return any? - 原样返回 result
]]
local function _rememberResolved(self: Utils, key: string, result: any?): any?
	if result ~= nil and _loadedModules[key] ~= nil then
		rawset(self :: any, key, result)
	end
	return result
end

-- ============================================================================
-- 通信对象访问接口
-- ============================================================================

UtilsSystem.Event = _attachLazyMsgLookupSync(_createEventTable(EVENT_FOLDER_NAME), EVENT_FOLDER_NAME)
UtilsSystem.RemoteEvent = _attachLazyMsgLookupSync(_createEventTable(REMOTE_EVENT_FOLDER_NAME), REMOTE_EVENT_FOLDER_NAME)
UtilsSystem.RemoteFunction =
	_attachLazyMsgLookupSync(_createEventTable(REMOTE_FUNCTION_FOLDER_NAME), REMOTE_FUNCTION_FOLDER_NAME)
UtilsSystem.Function = _attachLazyMsgLookupSync(_createEventTable(FUNCTION_FOLDER_NAME), FUNCTION_FOLDER_NAME)

-- ============================================================================
-- Services（立即挂到 UtilsSystem，不会造成循环引用）
-- ============================================================================

UtilsSystem.ReplicatedStorage = ReplicatedStorage
UtilsSystem.ReplicatedFirst = ReplicatedFirst
UtilsSystem.Debris = Debris
UtilsSystem.Players = Players
UtilsSystem.MarketplaceService = MarketplaceService
UtilsSystem.RunService = RunService
UtilsSystem.TeleportService = TeleportService
UtilsSystem.UserInputService = UserInputService
UtilsSystem.GuiService = GuiService
UtilsSystem.SoundService = SoundService
UtilsSystem.GamepadService = GamepadService
UtilsSystem.TextChatService = TextChatService
UtilsSystem.TweenService = TweenService
UtilsSystem.CollectionService = CollectionService
UtilsSystem.ScriptContext = ScriptContext
UtilsSystem.HttpService = HttpService
UtilsSystem.ContentProvider = ContentProvider
UtilsSystem.Lighting = Lighting
UtilsSystem.CoreGui = CoreGui
UtilsSystem.StarterGui = StarterGui
UtilsSystem.StarterPack = StarterPack
UtilsSystem.Selection = Selection
UtilsSystem.ChangeHistoryService = ChangeHistoryService

if IS_SERVER and ServerStorage then
	UtilsSystem.ServerStorage = ServerStorage
end

if not IS_SERVER and Players then
	UtilsSystem.LocalPlayer = Players.LocalPlayer
end

-- ============================================================================
-- 非延迟白名单模块（启动时加载）
-- ============================================================================

_eagerLoadWhitelistedModules()

-- ============================================================================
-- 延迟加载元表
-- ============================================================================

setmetatable(UtilsSystem, {
	__index = function(self, key)
		if typeof(key) ~= "string" then
			return nil
		end

		if _loadedModules[key] then
			return _rememberResolved(self, key, _loadedModules[key])
		end

		if _toolModules[key] then
			return _rememberResolved(self, key, _loadToolModule(key))
		end

		if _systemModules[key] then
			return _rememberResolved(self, key, _loadSystemModule(key))
		end

		if IS_SERVER and _serverRootModules[key] then
			return _rememberResolved(self, key, _loadServerRootModule(key))
		end

		-- 动态服务端 System：排在显式 registry 之后，避免名称冲突
		if IS_SERVER and _serverSystemPath then
			local resolved = ModuleRegistry.ResolveModuleScript(_serverSystemPath:FindFirstChild(key))
			if resolved then
				return _rememberResolved(self, key, _loadServerSystemModule(key))
			end
		end

		-- 客户端 SystemModule：排在 Tool / ToolSystem / ServerSystem 之后
		local clientSysPath = _getClientSystemPath()
		if clientSysPath and _getClientSystemModuleScript(clientSysPath, key) then
			return _rememberResolved(self, key, _loadClientSystemModule(key))
		end

		return nil
	end,
})

return UtilsSystem
