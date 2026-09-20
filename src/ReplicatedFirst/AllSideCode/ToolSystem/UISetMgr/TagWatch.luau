--[[
	Module: UISetMgr/TagWatch
	Description: UISetMgr 世界空间 Gui 自动发现：PlayerGui 扫描与 CollectionService 标签解析并注册
	Author: 林奥宇
	Created: 2026-09-02
	Last Modified: 2026-09-02

	仅供同目录 init require(script.TagWatch)。业务请走 Utils.UISetMgr.WatchPlayerGui / WatchTaggedCollectors。

	功能：
	- WatchPlayerGui：自动注册 PlayerGui 内 BillboardGui / SurfaceGui（不自动 ScreenGui）
	- Watch：监听 TagName（默认 StrokeAdapt），先听后扫，标签到达后 defer 再注册以免子树未齐
	- 标签可打在 Gui 自身、其子节点、或父级 Model/Part；解析到 BillboardGui / SurfaceGui 后回调注册
	- 不要打在 workspace 根或超大地图 Model 上（会监听整棵 DescendantAdded）
	- 无 Parent 时等入树；标签移除时注销对应 Gui 并断开子树监听

	加载方式（仅 UISetMgr/init）：
		local TagWatch = require(script.TagWatch)
		TagWatch.WatchPlayerGui(playerGui, tryAutoRegister)
		TagWatch.Watch({ tryAutoRegister = ..., unregisterCollector = ... })
]]

-- ============================================================================
-- 服务 / 模块引用
-- ============================================================================

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local CollectionService = Utils.CollectionService
local Log = Utils.Log
local StrokeAdapt = require(script.Parent.StrokeAdapt)

-- ============================================================================
-- 模块定义
-- ============================================================================

local TagWatch = {}

-- ============================================================================
-- 类型 / 私有状态
-- ============================================================================

export type RegisterHooks = {
	tryAutoRegister: (Instance) -> (),
	unregisterCollector: (LayerCollector) -> (),
}

local _hooks: RegisterHooks? = nil
local _tagAddedConn: RBXScriptConnection? = nil
local _tagRemovedConn: RBXScriptConnection? = nil
local _taggedTreeConns: { [Instance]: RBXScriptConnection } = {}
local _playerGuiWatchConn: RBXScriptConnection? = nil
local _watchedPlayerGui: PlayerGui? = nil

-- ============================================================================
-- 私有函数
-- ============================================================================

--[[
	按 CollectionService 标签尝试注册；允许打在 Gui 自身、子节点或父级 Model/Part
	@param inst Instance - 带 StrokeAdapt 标签的实例
]]
local function _tryRegisterTaggedCollector(inst: Instance)
	local hooks = _hooks
	if not hooks then
		return
	end

	if inst:IsA("BillboardGui") or inst:IsA("SurfaceGui") then
		hooks.tryAutoRegister(inst)
		return
	end

	local ancestor: Instance? = inst.Parent
	while ancestor do
		if ancestor:IsA("BillboardGui") or ancestor:IsA("SurfaceGui") then
			hooks.tryAutoRegister(ancestor)
			return
		end
		ancestor = ancestor.Parent
	end

	local found = false
	for _, descendant in ipairs(inst:GetDescendants()) do
		if descendant:IsA("BillboardGui") or descendant:IsA("SurfaceGui") then
			found = true
			hooks.tryAutoRegister(descendant)
		end
	end
	if not found then
		if inst:IsA("GuiObject") or inst:IsA("UIBase") then
			Log.warn("[UISetMgr] 标签", StrokeAdapt.GetTagName(), "未找到 BillboardGui/SurfaceGui，当前为", inst.ClassName, inst:GetFullName())
		end
	end
	if _taggedTreeConns[inst] then
		return
	end
	_taggedTreeConns[inst] = inst.DescendantAdded:Connect(function(descendant)
		if not descendant:IsA("BillboardGui") and not descendant:IsA("SurfaceGui") then
			return
		end
		task.defer(function()
			local liveHooks = _hooks
			if not liveHooks then
				return
			end
			liveHooks.tryAutoRegister(descendant)
		end)
	end)
end

--[[
	标签移除：注销 Gui；非 Gui 则停子树监听并注销无自身标签的子 Gui
	@param inst Instance - 刚去掉 StrokeAdapt 标签的实例
]]
local function _onTaggedRemoved(inst: Instance)
	local treeConn = _taggedTreeConns[inst]
	if treeConn then
		treeConn:Disconnect()
		_taggedTreeConns[inst] = nil
	end
	local hooks = _hooks
	if not hooks then
		return
	end
	if inst:IsA("BillboardGui") or inst:IsA("SurfaceGui") then
		hooks.unregisterCollector(inst)
		return
	end
	local tagName = StrokeAdapt.GetTagName()
	for _, descendant in ipairs(inst:GetDescendants()) do
		if descendant:IsA("BillboardGui") or descendant:IsA("SurfaceGui") then
			if not CollectionService:HasTag(descendant, tagName) then
				hooks.unregisterCollector(descendant)
			end
		end
	end
end

--[[
	标签信号可能早于 Parent / 子树就绪：本帧 defer 后再注册，仍无 Parent 则等入树
	@param inst Instance - GetTagged 或 GetInstanceAddedSignal 给出的实例
]]
local function _scheduleTaggedRegister(inst: Instance)
	task.defer(function()
		if inst.Parent then
			_tryRegisterTaggedCollector(inst)
			return
		end
		local ancestryConn: RBXScriptConnection? = nil
		local destroyingConn: RBXScriptConnection? = nil
		local function disconnectWait()
			if ancestryConn then
				ancestryConn:Disconnect()
				ancestryConn = nil
			end
			if destroyingConn then
				destroyingConn:Disconnect()
				destroyingConn = nil
			end
		end
		ancestryConn = inst.AncestryChanged:Connect(function(_, parent)
			if not parent then
				return
			end
			disconnectWait()
			_tryRegisterTaggedCollector(inst)
		end)
		-- Parent 长期为 nil 时靠 Destroying 拆掉等待连接，避免野实例泄漏
		destroyingConn = inst.Destroying:Connect(disconnectWait)
	end)
end

-- ============================================================================
-- 公共函数（仅 UISetMgr/init 使用）
-- ============================================================================

--[[
	监听 PlayerGui，自动注册其中的 BillboardGui / SurfaceGui（幂等；不自动 ScreenGui）
	@param playerGui PlayerGui - 本地玩家 PlayerGui
	@param tryAutoRegister (Instance) -> () - 发现 BillboardGui/SurfaceGui 时的注册回调
]]
function TagWatch.WatchPlayerGui(playerGui: PlayerGui, tryAutoRegister: (Instance) -> ())
	if not playerGui or not playerGui:IsA("PlayerGui") then
		Log.warn("[UISetMgr] WatchPlayerGui 参数无效")
		return
	end
	if _watchedPlayerGui == playerGui and _playerGuiWatchConn then
		return
	end
	if _playerGuiWatchConn then
		_playerGuiWatchConn:Disconnect()
		_playerGuiWatchConn = nil
	end
	_watchedPlayerGui = playerGui

	_playerGuiWatchConn = playerGui.DescendantAdded:Connect(function(descendant)
		if not descendant:IsA("BillboardGui") and not descendant:IsA("SurfaceGui") then
			return
		end
		task.defer(function()
			tryAutoRegister(descendant)
		end)
	end)

	for _, inst in ipairs(playerGui:GetDescendants()) do
		if inst:IsA("BillboardGui") or inst:IsA("SurfaceGui") then
			tryAutoRegister(inst)
		end
	end
end

--[[
	监听 CollectionService 标签并注册 BillboardGui / SurfaceGui（幂等）
	@param hooks RegisterHooks - tryAutoRegister / unregisterCollector，须指向 UISetMgr 实时函数
]]
function TagWatch.Watch(hooks: RegisterHooks)
	if _tagAddedConn then
		return
	end
	_hooks = hooks
	local tagName = StrokeAdapt.GetTagName()
	-- 先听后扫：流送中途 GetTagged 与 Added 之间会漏实例
	_tagAddedConn = CollectionService:GetInstanceAddedSignal(tagName):Connect(_scheduleTaggedRegister)
	_tagRemovedConn = CollectionService:GetInstanceRemovedSignal(tagName):Connect(_onTaggedRemoved)
	for _, inst in ipairs(CollectionService:GetTagged(tagName)) do
		_scheduleTaggedRegister(inst)
	end
end

return TagWatch
