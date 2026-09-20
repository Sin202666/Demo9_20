--!strict
--[[
	Module: SystemRankManager
	Description: 客户端排行榜 SurfaceGui 展示，只读 workspace 榜单缓存
	Author: 林奥宇
	Created: 2026-06-30
	Last Modified: 2026-09-01

	功能：
	- Init：等待 workspace.场景 与 Shared RankTemp 后按场景约定填 Main / MyRank
	- UpdateRank：从 workspace.排行榜缓存 读 SystemRank 发布的榜单并刷新格子
	- IsReady / OnBoardsReady：其它客户端 UI 等榜板绑完
	- GetTop3UserIds / GetCacheEntries：只读 workspace 镜像（解码后的副本）
	- destroy：断开刷新与场景监听并作废进行中的等待（格子保留；再次 Init 会重绑 Heartbeat）

	子模块：
	- RankBoardPrepare：场景 / RankTemp / 可映射榜板等待；connectSceneRankWatches 热挂载
	- RankBoardBind：克隆格子、表头文案、控件引用
	- RankBoardRefresh：读缓存、按 UserId 去重拉名/头像、刷新格子

	场景约定：
		workspace.场景/<世界>/功能/排行榜/Rank_N_Gold
			Board/SurfaceGui/Content/{Main, MyRank, 排行榜-排名, 排行榜-数量, 排行榜-玩家}
			title/SurfaceGui/{RankTitle, Icon}（文案/图片按榜写入；RankTitle 用 RANK_TITLE_GRADIENT → 彩虹 ColorScroll）
		Board 模型名 = Rank_ + 写榜键（Rank_N_Gold → 排行榜缓存/N_Gold）
		RankTemp 子节点：Frame / Username / Rank / Number / Portrait / BG

	与相关模块：
	- 写榜与前 3 名 NumberValue：仅服务端 SystemRank（ServerStateSync）
	- 本模块只读缓存、只写本地 SurfaceGui / Image；不写 Store、不写 workspace 权威镜像
	- 玩家名 / 头像走 DataCache.GetPlrName / GetPortrait（可能 yield，按 UserId 去重后 spawn）
	- 时长榜分数用 TimeTransfer.GetRankDurationParts + SetText("排行榜时长")
	- RankTemp 只从 ReplicatedStorage 解析（Scope.Shared）。服务端 SystemRank 会把
	  ServerStorage 模板克隆到 RS.Assets.UI/排行榜

	端侧 / 调用约束：
	- 仅客户端；Init 由 RankManager 调用，幂等；禁止服务端调用
	- 定时刷新用客户端 Heartbeat 累计，禁止 UpdateModule.Register（仅服务端生效）
	- 场景 / RankTemp 未就绪时异步等待；超时后 Log.warn，再次 Init 可重试
	- 热挂载监听 场景 各世界「功能/排行榜」，不限于大厅

	加载方式：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local SystemRankManager = Utils.SystemRankManager

	使用示例：
		SystemRankManager.Init()
		SystemRankManager.OnBoardsReady(function()
			local top = SystemRankManager.GetTop3UserIds(RankConfig.RANK_GOLD_NAME)
		end)
		SystemRankManager.UpdateRank()
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local LocalPlayer = Utils.LocalPlayer
local RunService = Utils.RunService
local RankConfig = Utils.RankConfig
local UpdateModule = Utils.UpdateModule
local Log = Utils.Log

local RankBoardPrepare = require(script.RankBoardPrepare)
local RankBoardBind = require(script.RankBoardBind)
local RankBoardRefresh = require(script.RankBoardRefresh)

type RankBoardRef = RankBoardBind.RankBoardRef

-- ========================================
-- 模块定义
-- ========================================
local SystemRankManager = {}

-- ========================================
-- 常量定义
-- ========================================
local CLIENT_REFRESH_INTERVAL = UpdateModule.INTERVAL.SEC_30
local SCENE_WAIT_SEC = 30
local RANK_TEMP_WAIT_SEC = 30

-- ========================================
-- 私有变量
-- ========================================
local _boardsReady = false
local _preparing = false
local _prepareGeneration = 0
local _allWorldFolder: Instance? = nil
local _rankTemp: Frame? = nil
local _boardRefs: { RankBoardRef } = {}
local _refreshConnection: RBXScriptConnection? = nil
local _folderWatchConnections: { RBXScriptConnection } = {}
local _refreshElapsed = 0
local _readyCallbacks: { () -> () } = {}
local _watchBindScheduled = false

-- ========================================
-- 私有函数
-- ========================================

--[[
	当前准备代数是否已作废（destroy 或新一轮 Init）

	@param generation number - 启动等待时记录的代数
	@return boolean - true 表示应放弃本次准备
]]
local function _isPrepareAborted(generation: number): boolean
	return generation ~= _prepareGeneration
end

--[[
	本地玩家 UserId；未知时 0

	@return number - UserId；无 LocalPlayer 时 0
]]
local function _localUserId(): number
	return if LocalPlayer then LocalPlayer.UserId else 0
end

--[[
	初始化排行榜 UI 并缓存格子引用

	@return () - 无返回值；缺场景或模板时由调用方先校验
]]
local function _initializeRankBoards()
	if not _allWorldFolder or not _rankTemp then
		return
	end

	table.clear(_boardRefs)
	local built = RankBoardBind.initializeRankBoards(
		_allWorldFolder,
		_rankTemp,
		RankBoardRefresh.applyPlaceholder,
		function(widgets)
			RankBoardRefresh.applyMyRankUnranked(widgets, if LocalPlayer then LocalPlayer.UserId else nil)
		end
	)
	table.move(built, 1, #built, 1, _boardRefs)
end

--[[
	刷新所有已配置排行榜的 SurfaceGui

	@return () - 无返回值
]]
local function _refreshAllRankDisplays()
	RankBoardRefresh.refreshAll(_boardRefs, _localUserId())
end

--[[
	断开场景热挂载连接

	@return () - 无返回值
]]
local function _disconnectFolderWatches()
	for _, conn in _folderWatchConnections do
		conn:Disconnect()
	end
	table.clear(_folderWatchConnections)
end

--[[
	首次绑出格子时置就绪并触发 OnBoardsReady 回调

	@return () - 无返回值
]]
local function _markBoardsReady()
	if _boardsReady then
		return
	end
	_boardsReady = true
	local callbacks = _readyCallbacks
	table.clear(_readyCallbacks)
	for _, callback in callbacks do
		task.defer(callback)
	end
end

--[[
	等待场景与 RankTemp 后克隆格子。destroy / 新一轮 Init 会作废本次等待。
	热挂载监听 场景 各世界排行榜文件夹，不限于大厅。

	@param generation number - 启动时的准备代数
	@return () - 无返回值
]]
local function _prepareRankBoards(generation: number)
	--[[
		本轮准备结束时清除 _preparing（仅当前代数有效）

		@return () - 无返回值
	]]
	local function finishPreparing()
		if generation == _prepareGeneration then
			_preparing = false
		end
	end

	--[[
		场景树变化后尝试绑板（task.defer 合并同帧多次 ChildAdded）

		@return () - 无返回值
	]]
	local function scheduleBindFromWatch()
		if _isPrepareAborted(generation) or not _rankTemp or not _allWorldFolder then
			return
		end
		if _watchBindScheduled then
			return
		end
		_watchBindScheduled = true
		task.defer(function()
			_watchBindScheduled = false
			if _isPrepareAborted(generation) or not _rankTemp or not _allWorldFolder then
				return
			end
			_initializeRankBoards()
			if #_boardRefs > 0 then
				_markBoardsReady()
				task.defer(_refreshAllRankDisplays)
			end
		end)
	end

	_allWorldFolder = RankBoardPrepare.waitForScene(SCENE_WAIT_SEC)
	if _isPrepareAborted(generation) then
		finishPreparing()
		return
	end

	_rankTemp = RankBoardPrepare.resolveSharedRankTemp()
	if not _rankTemp then
		_rankTemp = RankBoardPrepare.waitForSharedRankTemp(RANK_TEMP_WAIT_SEC)
	end
	if _isPrepareAborted(generation) then
		finishPreparing()
		return
	end

	if not _allWorldFolder then
		Log.warn("[SystemRankManager] workspace.场景 未就绪，跳过格子初始化")
	end
	if not _rankTemp then
		Log.warn("[SystemRankManager] RankTemp 未在 ReplicatedStorage 找到（ModelRes/排行榜 或 UI/排行榜），跳过格子初始化")
	end
	if not _allWorldFolder or not _rankTemp then
		finishPreparing()
		return
	end

	_initializeRankBoards()
	_disconnectFolderWatches()
	local watches = RankBoardPrepare.connectSceneRankWatches(_allWorldFolder, scheduleBindFromWatch)
	table.move(watches, 1, #watches, #_folderWatchConnections + 1, _folderWatchConnections)

	if #_boardRefs > 0 then
		_markBoardsReady()
		task.defer(_refreshAllRankDisplays)
	end
	finishPreparing()
end

--[[
	客户端 Heartbeat：累计满间隔后刷新榜面

	@param dt number - 本帧间隔（秒）
	@return () - 无返回值
]]
local function _onHeartbeat(dt: number)
	_refreshElapsed += dt
	if _refreshElapsed < CLIENT_REFRESH_INTERVAL then
		return
	end
	_refreshElapsed -= CLIENT_REFRESH_INTERVAL
	_refreshAllRankDisplays()
end

-- ========================================
-- 公共函数
-- ========================================

--[[
	从 workspace 缓存刷新排行榜显示。
	无缓存或尚未 Init 出格子时静默 no-op。不写前 3 名 NumberValue。

	@return () - 无返回值
]]
function SystemRankManager.UpdateRank()
	_refreshAllRankDisplays()
end

--[[
	榜板是否已绑定出至少一块板

	@return boolean - 已就绪为 true
]]
function SystemRankManager.IsReady(): boolean
	return _boardsReady
end

--[[
	榜板就绪后回调。若已就绪则 task.defer 立即调用。

	@param callback () -> () - 就绪回调
	@return () - 无返回值
]]
function SystemRankManager.OnBoardsReady(callback: () -> ())
	if type(callback) ~= "function" then
		return
	end
	if _boardsReady then
		task.defer(callback)
		return
	end
	table.insert(_readyCallbacks, callback)
end

--[[
	读 workspace「前3名玩家」UserId（新表）。

	@param rankName string - 写榜键
	@return {number} - 最多 3 个 UserId；未登记或无镜像为空表
]]
function SystemRankManager.GetTop3UserIds(rankName: string): { number }
	return RankBoardRefresh.getTop3UserIds(rankName)
end

--[[
	读 workspace 排行榜缓存并解码分数（新表）。

	@param rankName string - 写榜键
	@return { { userId: number, score: number } } - 解码后的条目；无缓存为空表
]]
function SystemRankManager.GetCacheEntries(rankName: string): { { userId: number, score: number } }
	return RankBoardRefresh.getCacheEntries(rankName)
end

--[[
	断开定时刷新连接并作废进行中的场景 / RankTemp 等待。
	格子与引用保留；再次 Init 会重绑 Heartbeat，未就绪时会重试等待。

	@return () - 无返回值
]]
function SystemRankManager.destroy()
	_prepareGeneration += 1
	_preparing = false
	_disconnectFolderWatches()
	table.clear(_readyCallbacks)
	if _refreshConnection then
		_refreshConnection:Disconnect()
		_refreshConnection = nil
	end
	_refreshElapsed = 0
end

-- ========================================
-- 初始化
-- ========================================

--[[
	初始化客户端排行榜格子与 Heartbeat 定时刷新。
	由 RankManager 调用。格子未就绪时再次调用会重试等待；已就绪则只补绑连接。
	禁止服务端调用。

	@return () - 无返回值
]]
function SystemRankManager.Init()
	if not _boardsReady and not _preparing then
		_preparing = true
		_prepareGeneration += 1
		local generation = _prepareGeneration
		task.spawn(function()
			_prepareRankBoards(generation)
		end)
	end

	if not _refreshConnection then
		_refreshConnection = RunService.Heartbeat:Connect(_onHeartbeat)
	end
end

return SystemRankManager
