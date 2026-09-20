--[[
	Module: Preload
	Description: FirstPreload 资源统计与 ContentProvider 预加载，驱动 ReplicatedFirst 进度计数器
	Author: 中台组
	Created: 2024-01-01
	Last Modified: 2026-07-03

	功能：
	- StatResInfo：汇总静态 ID、预加载资源文件夹与 AnimationModule 配置表，写入「总资源数」
	- PreloadAssets / PreloadAnimations：顺序预热并在「已加载资源数」递增
	- StartLoadTimer：Heartbeat 累计「预加载时间」，达到 MAX_LOAD_TIME_SEC 后自动断开

	依赖：
	- Utils.InsMgr：ReplicatedFirst 下进度 NumberValue
	- Utils.AnimationModule.GetPreloadTable：动作 ID 列表
	- Utils.ContentProvider / Utils.Debris / Utils.RunService

	说明：
	- 与 ResRestore 不同，本模块同步递增计数供 LoadingUI 进度条使用
	- 静态资源 ID 见 DEFAULT_ASSET_IDS；运行时追加请放入 ReplicatedFirst「预加载资源文件夹」

	示例：
	```lua
	local Preload = require(script.Preload)
	local assetIds, animIds = Preload.StatResInfo()
	Preload.StartLoadTimer()
	task.spawn(function()
		Preload.PreloadAnimations(animIds)
	end)
	Preload.PreloadAssets(assetIds)
	```
]]

-- ============================================================================
-- 服务与依赖
-- ============================================================================

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local InsMgr = Utils.InsMgr
local AnimationModule = Utils.AnimationModule
local ContentProvider = Utils.ContentProvider
local Debris = Utils.Debris
local RunService = Utils.RunService
local ReplicatedFirst = Utils.ReplicatedFirst

-- ============================================================================
-- 模块定义
-- ============================================================================

local Preload = {}

-- ============================================================================
-- 常量
-- ============================================================================

local RES_FOLDER_NAME = "预加载资源文件夹"
local RES_TOTAL_NAME = "总资源数"
local RES_LOADED_NAME = "已加载资源数"
local RES_LOAD_TIME_NAME = "预加载时间"

local MAX_LOAD_TIME_SEC = 10
local PRELOAD_RETRY_DELAY_SEC = 0

-- 可按项目追加；亦可在 ReplicatedFirst「预加载资源文件夹」内放 StringValue 扩展
local DEFAULT_ASSET_IDS: { string } = {
	"rbxassetid://84526223762203",
	"rbxassetid://122648826068189",
	"rbxassetid://132396883034411",
	"rbxassetid://92508035964036",
	"rbxassetid://74633097373240",
	"rbxassetid://94591523886425",
	"rbxassetid://106820743396496",
	"rbxassetid://121284995814740",
	"rbxassetid://102862228008642",
	"rbxassetid://104815614918549",
	"rbxassetid://111801518447373",
	"rbxassetid://106983077535803",
	"rbxassetid://134628337304849",
	"rbxassetid://78650043561817",
	"rbxassetid://71591810622021",
	"rbxassetid://132311991102688",
	"rbxassetid://102668830890391",
}

-- ============================================================================
-- 私有变量
-- ============================================================================

local _resTotal: NumberValue = InsMgr.GetIns(RES_TOTAL_NAME, "NumberValue", ReplicatedFirst) :: NumberValue
local _resLoaded: NumberValue = InsMgr.GetIns(RES_LOADED_NAME, "NumberValue", ReplicatedFirst) :: NumberValue
local _resLoadTime: NumberValue = InsMgr.GetIns(RES_LOAD_TIME_NAME, "NumberValue", ReplicatedFirst) :: NumberValue
local _loadTimerConn: RBXScriptConnection? = nil

-- ============================================================================
-- 私有函数
-- ============================================================================

--[[
	对单个目标执行 PreloadAsync，失败时 defer 重试一次
	@param target Instance | string - ContentProvider 预加载目标
	@return nil - 无返回值
]]
local function _preloadOne(target: Instance | string)
	local success = pcall(function()
		ContentProvider:PreloadAsync({ target :: any })
	end)

	if not success then
		task.delay(PRELOAD_RETRY_DELAY_SEC, function()
			pcall(function()
				ContentProvider:PreloadAsync({ target :: any })
			end)
		end)
	end
end

--[[
	从 ReplicatedFirst 预加载资源文件夹收集 StringValue.Value
	@param assetIds { string } - 写入目标列表（原地追加）
	@return nil - 无返回值
]]
local function _appendFolderAssetIds(assetIds: { string })
	local resFolder = ReplicatedFirst:FindFirstChild(RES_FOLDER_NAME)
	if not resFolder then
		return
	end

	for _, child in resFolder:GetChildren() do
		if child:IsA("StringValue") and child.Value ~= "" then
			table.insert(assetIds, child.Value)
		end
	end
end

-- ============================================================================
-- 公共 API
-- ============================================================================

--[[
	统计待预加载资源并写入「总资源数」
	@return { string } - 普通资源 ID 列表（rbxassetid://...）
	@return { string } - 动作资源 ID 列表（rbxassetid://...）
]]
function Preload.StatResInfo(): ({ string }, { string })
	local assetIds: { string } = table.clone(DEFAULT_ASSET_IDS)
	_appendFolderAssetIds(assetIds)

	local animationIds = AnimationModule.GetPreloadTable()

	_resTotal.Value = #assetIds + #animationIds

	return assetIds, animationIds
end

--[[
	顺序预加载普通资源 ID 列表，每完成一项递增「已加载资源数」
	@param assetIds { string } - rbxassetid:// 格式资源 ID
	@return nil - 无返回值
]]
function Preload.PreloadAssets(assetIds: { string })
	for _, assetId in assetIds do
		_preloadOne(assetId)
		_resLoaded.Value += 1
	end
end

--[[
	顺序预加载动作资源，每完成一项递增「已加载资源数」；临时 Animation 实例随后销毁
	@param animationIds { string } - rbxassetid:// 格式动作 ID
	@return nil - 无返回值
]]
function Preload.PreloadAnimations(animationIds: { string })
	for _, animationId in animationIds do
		local animation = Instance.new("Animation")
		animation.AnimationId = animationId
		animation.Parent = ReplicatedFirst

		local success = pcall(function()
			ContentProvider:PreloadAsync({ animation }, function()
				Debris:AddItem(animation, 0)
			end)
		end)

		if not success then
			task.delay(PRELOAD_RETRY_DELAY_SEC, function()
				pcall(function()
					ContentProvider:PreloadAsync({ animation }, function()
						Debris:AddItem(animation, 0)
					end)
				end)
			end)
		end

		_resLoaded.Value += 1
	end
end

--[[
	启动预加载计时器，累计「预加载时间」至 MAX_LOAD_TIME_SEC 后自动断开
	@return nil - 无返回值
]]
function Preload.StartLoadTimer()
	if _loadTimerConn then
		return
	end

	_loadTimerConn = RunService.Heartbeat:Connect(function(deltaTime: number)
		_resLoadTime.Value += deltaTime

		if _resLoadTime.Value >= MAX_LOAD_TIME_SEC then
			if _loadTimerConn then
				_loadTimerConn:Disconnect()
				_loadTimerConn = nil
			end
		end
	end)
end

return Preload
