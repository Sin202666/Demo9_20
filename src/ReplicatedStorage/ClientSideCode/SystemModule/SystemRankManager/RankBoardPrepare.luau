--[[
	Module: RankBoardPrepare
	Description: 客户端排行榜就绪等待（场景 / RankTemp）与热挂载监听
	Author: 林奥宇
	Created: 2026-09-01
	Last Modified: 2026-09-01

	职责（相对 init / Bind / Refresh）：
	- 等待 workspace.场景、Shared RankTemp（含等服务端克隆到 RS.Assets）
	- connectSceneRankWatches：监听各世界「功能/排行榜」晚到的 Rank_*（不限大厅）
	- 不克隆格子、不刷分数（Bind / Refresh 负责）

	由 SystemRankManager 内部 require(script.RankBoardPrepare)；业务请走 Utils.SystemRankManager。
	完整展示流程见同目录 init.luau 文件头。
]]

-- ========================================
-- 服务引用
-- ========================================
local Workspace = game:GetService("Workspace")

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local ReplicatedStorage = Utils.ReplicatedStorage
local AssetPaths = Utils.AssetPaths
local RankConfig = Utils.RankConfig

local RankBoardPrepare = {}

-- ========================================
-- 常量定义
-- ========================================
local SCENE_FOLDER_NAME = "场景"
local FEATURE_FOLDER_NAME = "功能"

-- ========================================
-- 私有函数
-- ========================================

--[[
	从 ReplicatedStorage（Shared）解析 RankTemp 模板

	@return Frame? - 模板 Frame；未找到或类型不符时 nil
]]
local function _resolveSharedRankTemp(): Frame?
	for _, path in RankConfig.RANK_TEMP_PATHS do
		local inst = AssetPaths.Resolve(path, AssetPaths.Scope.Shared)
		if inst and inst:IsA("Frame") then
			return inst
		end
	end
	return nil
end

--[[
	在 Assets 下按 catalog/排行榜/RankTemp 取已存在的 Frame（不等待）

	@param assets Instance - ReplicatedStorage.Assets
	@return Frame? - 已复制到位的模板；尚未出现时 nil
]]
local function _findRankTempUnderAssets(assets: Instance): Frame?
	for _, catalogName in RankConfig.RANK_TEMP_SHARED_CATALOGS do
		local catalog = assets:FindFirstChild(catalogName)
		if not catalog then
			continue
		end
		local rankFolder = catalog:FindFirstChild(RankConfig.RANK_TEMP_FOLDER_NAME)
		if not rankFolder then
			continue
		end
		local temp = rankFolder:FindFirstChild(RankConfig.RANK_TEMP_NAME)
		if temp and temp:IsA("Frame") then
			return temp
		end
	end
	return nil
end

--[[
	等待直子节点

	@param parent Instance? - 父节点
	@param childName string - 子实例 Name
	@param timeoutSec number - WaitForChild 超时秒数
	@return Instance? - 子实例；父为空或超时则 nil
]]
local function _waitChild(parent: Instance?, childName: string, timeoutSec: number): Instance?
	if not parent then
		return nil
	end
	local child = parent:FindFirstChild(childName)
	if child then
		return child
	end
	return parent:WaitForChild(childName, timeoutSec)
end

-- 热挂载会话状态（connectSceneRankWatches 单次调用内共享）
type SceneRankWatchState = {
	connections: { RBXScriptConnection },
	watchedRankFolders: { [Instance]: boolean },
	watchedFeatures: { [Instance]: boolean },
	onChanged: () -> (),
}

--[[
	对「排行榜」文件夹挂 ChildAdded（幂等）

	@param state SceneRankWatchState - 本轮热挂载状态
	@param rankFolder Instance - 功能/排行榜
	@return () - 无返回值
]]
local function _watchRankFolder(state: SceneRankWatchState, rankFolder: Instance)
	if state.watchedRankFolders[rankFolder] then
		return
	end
	state.watchedRankFolders[rankFolder] = true
	table.insert(
		state.connections,
		rankFolder.ChildAdded:Connect(function()
			state.onChanged()
		end)
	)
end

--[[
	对「功能」文件夹挂监听：已有排行榜立即 watch，晚到的排行榜再挂

	@param state SceneRankWatchState - 本轮热挂载状态
	@param feature Instance - 世界下的功能文件夹
	@return () - 无返回值
]]
local function _tryWatchFeature(state: SceneRankWatchState, feature: Instance)
	if state.watchedFeatures[feature] then
		return
	end
	state.watchedFeatures[feature] = true
	local rankFolder = feature:FindFirstChild(RankConfig.RANK_TEMP_FOLDER_NAME)
	if rankFolder then
		_watchRankFolder(state, rankFolder)
	end
	table.insert(
		state.connections,
		feature.ChildAdded:Connect(function(child)
			if child.Name == RankConfig.RANK_TEMP_FOLDER_NAME then
				_watchRankFolder(state, child)
				state.onChanged()
			end
		end)
	)
end

--[[
	对单个世界挂「功能」监听

	@param state SceneRankWatchState - 本轮热挂载状态
	@param world Instance - 场景下的世界 Model/Folder
	@return () - 无返回值
]]
local function _watchWorld(state: SceneRankWatchState, world: Instance)
	if not (world:IsA("Model") or world:IsA("Folder")) then
		return
	end
	local feature = world:FindFirstChild(FEATURE_FOLDER_NAME)
	if feature then
		_tryWatchFeature(state, feature)
	end
	table.insert(
		state.connections,
		world.ChildAdded:Connect(function(child)
			if child.Name == FEATURE_FOLDER_NAME then
				_tryWatchFeature(state, child)
				state.onChanged()
			end
		end)
	)
end

-- ========================================
-- 公共函数
-- ========================================

--[[
	等待直子节点

	@param parent Instance? - 父节点
	@param childName string - 子实例 Name
	@param timeoutSec number - WaitForChild 超时秒数
	@return Instance? - 子实例；父为空或超时则 nil
]]
function RankBoardPrepare.waitChild(parent: Instance?, childName: string, timeoutSec: number): Instance?
	return _waitChild(parent, childName, timeoutSec)
end

--[[
	从 ReplicatedStorage 解析 RankTemp（不等待）

	@return Frame? - 模板；未找到时 nil
]]
function RankBoardPrepare.resolveSharedRankTemp(): Frame?
	return _resolveSharedRankTemp()
end

--[[
	等待 workspace.场景 复制到位

	@param timeoutSec number - WaitForChild 超时秒数
	@return Instance? - 场景根；超时未到则 nil
]]
function RankBoardPrepare.waitForScene(timeoutSec: number): Instance?
	local folder = Workspace:FindFirstChild(SCENE_FOLDER_NAME)
	if folder then
		return folder
	end
	return Workspace:WaitForChild(SCENE_FOLDER_NAME, timeoutSec)
end

--[[
	等待 Shared RankTemp：先解析，再等 Assets/UI/排行榜（服务端克隆目标）

	@param timeoutSec number - 单段 WaitForChild 超时秒数
	@return Frame? - 模板 Frame；超时未到则 nil
]]
function RankBoardPrepare.waitForSharedRankTemp(timeoutSec: number): Frame?
	local found = _resolveSharedRankTemp()
	if found then
		return found
	end

	local assets = ReplicatedStorage:FindFirstChild(AssetPaths.ASSETS_ROOT_NAME)
	if not assets then
		assets = ReplicatedStorage:WaitForChild(AssetPaths.ASSETS_ROOT_NAME, timeoutSec)
	end
	if not assets then
		return nil
	end

	found = _findRankTempUnderAssets(assets)
	if found then
		return found
	end

	local ui = assets:FindFirstChild("UI")
	if not ui then
		ui = assets:WaitForChild("UI", timeoutSec)
	end
	if not ui then
		return _findRankTempUnderAssets(assets)
	end

	local rankFolder = ui:FindFirstChild(RankConfig.RANK_TEMP_FOLDER_NAME)
	if not rankFolder then
		rankFolder = ui:WaitForChild(RankConfig.RANK_TEMP_FOLDER_NAME, timeoutSec)
	end
	if not rankFolder then
		return _findRankTempUnderAssets(assets)
	end

	local temp = rankFolder:FindFirstChild(RankConfig.RANK_TEMP_NAME)
	if not temp then
		temp = rankFolder:WaitForChild(RankConfig.RANK_TEMP_NAME, timeoutSec)
	end
	if temp and temp:IsA("Frame") then
		return temp
	end
	return _findRankTempUnderAssets(assets)
end

--[[
	监听 场景 下各世界「功能/排行榜」及新世界加入，用于晚到的 Rank_* 板。
	同一 Feature / 排行榜文件夹只挂一次。

	@param scene Instance - workspace.场景
	@param onChanged () -> () - 结构可能变化时回调（调用方自行防重入）
	@return { RBXScriptConnection } - 须由调用方在 destroy 时全部 Disconnect
]]
function RankBoardPrepare.connectSceneRankWatches(scene: Instance, onChanged: () -> ()): { RBXScriptConnection }
	local state: SceneRankWatchState = {
		connections = {},
		watchedRankFolders = {},
		watchedFeatures = {},
		onChanged = onChanged,
	}

	for _, world in scene:GetChildren() do
		_watchWorld(state, world)
	end
	table.insert(
		state.connections,
		scene.ChildAdded:Connect(function(child)
			_watchWorld(state, child)
			state.onChanged()
		end)
	)
	return state.connections
end

return RankBoardPrepare
