--[[
	Module: UISetMgr
	Description: 客户端 ScreenGui 自适应缩放：按设计分辨率 contain 根 UIScale，对非全屏弹窗二次适配，并对 Main 下一层 HUD 按 Mobie_Scale/PC_Scale 直写 Scale；UIStroke 按祖先 UIScale（跳过弹窗 AdaptScale 与 HUD 直写层）与设备配置适配粗细
	Author: 林奥宇
	Created: 2026-08-04
	Last Modified: 2026-09-15

	功能：
	- RegisterScreenGui / UnregisterScreenGui — 注册与注销 ScreenGui（幂等；含根 UIScale、弹窗二次适配、Main 下一层 HUD 直写）
	- RegisterLayerCollector / UnregisterLayerCollector — 注册 BillboardGui / SurfaceGui 的描边适配（不写 UIScale / Size / Adornee）
	- WatchPlayerGui — 自动注册 PlayerGui 内 BillboardGui / SurfaceGui（不自动 ScreenGui，不扫 workspace）
	- WatchTaggedCollectors — 监听 CollectionService 标签（默认 StrokeAdapt），注册 workspace 等处的 BillboardGui / SurfaceGui；先听后扫，标签到达后 defer 再注册以免子树未齐
	- Refresh / SetUserScale / GetRootScale — 强制刷新、用户倍率、查询根 Scale（后两者仅 ScreenGui；Refresh 的 Thickness 为异步分片）
	- UpdateUIStroke — Thickness = BaseThickness × 祖先 UIScale 积（跳过弹窗 AdaptScale 与 HUD 直写层）× ViewportContain(仅世界空间) × 屏幕档倍率 × 设备倍率，再按设备下限钳制

	与 UIanima 关系：
	- 弹窗目标倍率写入 UIScale.AdaptScale；弹出/收回动画应 tween 到该 Attribute（见 UIanima）
	- 刷新时若 Scale < ANIM_EPS（动画中）跳过该弹窗，保留已有 AdaptScale，避免 AbsoluteSize 塌缩误算
	- HUD（Main / ContentClip 直接子）：有 Mobie_Scale 或 PC_Scale 的名为 UIScale 的节点按字面倍率写 Scale（不用弹窗 1→0.98）；不因 Scale≈0 跳过
	- Thickness 不跟弹窗 Tween 逐帧刷新，只在 Register / Refresh / Stroke 入树时写入（弹窗/HUD 覆盖层已从祖先积剔除）

	描边启用条件（全部满足）：
	- StrokeAdapt 配置 Enabled 为 true（总开关，默认开；关掉则不改任何 Thickness）
	- 最近 LayerCollector 类型在 RootTypes（ScreenGui / BillboardGui / SurfaceGui）
	- stroke.Parent 类型在 ParentTypes（TextLabel / Frame 等）
	- SkipStrokeAdapt ~= true
	- 注册项 adaptStrokes 为 true（ScreenGui 可关；世界空间默认开）

	描边归属：一条 UIStroke 只属于最近 LayerCollector，避免 ScreenGui 扫描穿透嵌套世界空间 Gui。

	世界空间 Gui 约定：
	- PlayerGui 内 BillboardGui / SurfaceGui：WatchPlayerGui 自动注册（短视频底板即此结构）
	- workspace 等：给 BillboardGui / SurfaceGui（或其子节点、父级 Model/Part）打标签 StrokeAdapt；WatchTaggedCollectors 会解析到 Gui
	- 不要把标签打在 workspace 根或超大地图 Model 上（会监听整棵 DescendantAdded）
	- 禁止给 BillboardGui / SurfaceGui 写 UIScale / Size / Adornee / CFrame

	属性约定（Studio 资产兼容）：
	- Mobie_Scale / PC_Scale — 弹窗为占屏系数（Small 且值为 1 时改 0.98）；Main 下一层 HUD 为字面 Scale（拼写与现有资产一致）
	- AdaptScale — 本模块写入的适配目标 Scale（弹窗 contain 结果或 HUD 字面倍率）
	- BaseThickness — UpdateUIStroke 缓存的原始 Thickness（1K 设计值）
	- SkipStrokeAdapt — 为 true 时不纳入自动适配（固定像素描边）

	运行时约定：
	- Studio 只在设计分辨率（默认 1920×1021）设一版 Thickness
	- 运行时改设计粗细应写 BaseThickness，不要只改 Thickness
	- 新建 Stroke：先设设计 Thickness 再 Parent，或同帧内设完（入树后 defer 再快照）
	- UpdateUIStroke：自动适配会乘 ViewportContain 且剔除窗口层（弹窗 AdaptScale 与 Main 下一层 HUD 直写 UIScale）；直接调用时 uiScale 自行算好（不要预乘设备倍率，也不会自动跳过窗口层）
	- 屏幕档 / 设备倍率默认 1、下限默认 0；手柄热插拔不重刷描边
	- 分辨率变化：根 UIScale / 弹窗 AdaptScale / HUD 直写 Scale 立即写入；Thickness 分片写入，不要在 Refresh 返回后立刻把 Thickness 当最终值
	- 泵运行中分辨率再变：剩余条目用新倍率继续，队头走完后再补扫；单条入树仍立即 Apply
	- Thickness 变化不超过 ThicknessEps 时跳过写入
	- 世界空间 ViewportSize 经 RefreshStrokes 合入同一泵，不再额外 defer

	子模块：
	- StrokeAdapt — 白名单、倍率、下限、子树收集、世界空间 ViewportContain、视口监听；祖先积跳过弹窗 AdaptScale 与 HUD 直写层
	- StrokeRefreshPump — 描边分片队列 / 写入当下计算倍率 / Heartbeat 预算
	- TagWatch — PlayerGui / CollectionService 标签解析与注册

	加载方式：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local UISetMgr = Utils.UISetMgr

	示例：
		UISetMgr.RegisterScreenGui(screenGui, { syncTipsGui = true })
		UISetMgr.WatchPlayerGui(playerGui)
		UISetMgr.WatchTaggedCollectors()
		UISetMgr.RegisterLayerCollector(surfaceGui)
		UISetMgr.SetUserScale(screenGui, 0.9)
		UISetMgr.RegisterScreenGui(screenGui, { adaptStrokes = false })
]]

-- ============================================================================
-- 服务 / 模块引用
-- ============================================================================

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local GuiService = Utils.GuiService
local Log = Utils.Log
local StrokeAdapt = require(script.StrokeAdapt)
local TagWatch = require(script.TagWatch)

-- ============================================================================
-- 模块定义
-- ============================================================================

local UISetMgr = {}

-- ============================================================================
-- 常量
-- ============================================================================

local DEFAULT_DESIGN_SIZE = StrokeAdapt.GetDesignSize()
local DEFAULT_USER_SCALE = 1
local ANIM_EPS = 0.01
local SCALE_EPS = 1e-4
local MOBILE_SCALE_ATTR = "Mobie_Scale"
local PC_SCALE_ATTR = "PC_Scale"
local ADAPT_SCALE_ATTR = "AdaptScale"
local TIPS_GUI_NAME = "TipsGui"
local MAIN_FRAME_NAME = "Main"
local CONTENT_CLIP_NAME = "ContentClip"
local UI_SCALE_CHILD_NAME = "UIScale"
local MOBILE_SCALE_ONE_FALLBACK = 0.98

-- ============================================================================
-- 类型 / 私有状态
-- ============================================================================

export type RegisterOptions = {
	designSize: Vector2?,
	userScale: number?,
	adaptPopups: boolean?,
	syncTipsGui: boolean?,
	adaptStrokes: boolean?,
}

export type LayerRegisterOptions = {
	adaptStrokes: boolean?,
}

type ResolvedOptions = {
	designSize: Vector2,
	userScale: number,
	adaptPopups: boolean,
	syncTipsGui: boolean,
	adaptStrokes: boolean,
}

type GuiEntry = {
	collector: LayerCollector,
	rootScale: UIScale?,
	designSize: Vector2,
	userScale: number,
	adaptPopups: boolean,
	syncTipsGui: boolean,
	adaptStrokes: boolean,
	tipsScale: UIScale?,
	strokes: { [UIStroke]: boolean },
	strokeRootsBound: { [Instance]: boolean },
	connections: { RBXScriptConnection },
	refreshScheduled: boolean,
}

local _entries: { [LayerCollector]: GuiEntry } = {}
local _refreshWorldSpaceStrokes: () -> () = function() end

-- ============================================================================
-- 私有函数
-- ============================================================================

--[[
	确保已监听视口变化（ScreenGui 走 AbsoluteSize；世界空间描边走相机 ViewportSize）
]]
local function _ensureViewportListener()
	StrokeAdapt.EnsureViewportListener({
		onDisplaySizeChanged = function()
			UISetMgr.Refresh(nil)
		end,
		onWorldSpaceViewportChanged = function()
			_refreshWorldSpaceStrokes()
		end,
	})
end

--[[
	若全局已无注册项则断开视口与相机监听
]]
local function _maybeDisconnectViewportListener()
	if next(_entries) ~= nil then
		return
	end
	StrokeAdapt.DisconnectViewportListener()
end

--[[
	查找 ScreenGui 上的根 UIScale（优先名称为 UIScale 的子节点）
	@param screenGui ScreenGui - 目标 ScreenGui
	@return UIScale? - 根 UIScale，不存在时 nil
]]
local function _findRootUIScale(screenGui: ScreenGui): UIScale?
	return StrokeAdapt.FindChildUIScale(screenGui)
end

--[[
	查找与 ScreenGui 同级的 TipsGui
	@param entry GuiEntry - 注册项
	@return ScreenGui? - TipsGui；缺失或类型不符时 nil
]]
local function _findTipsGui(entry: GuiEntry): ScreenGui?
	if not entry.collector:IsA("ScreenGui") then
		return nil
	end
	local parent = entry.collector.Parent
	if not parent then
		return nil
	end
	local tipsGui = parent:FindFirstChild(TIPS_GUI_NAME)
	if tipsGui and tipsGui:IsA("ScreenGui") then
		return tipsGui
	end
	return nil
end

--[[
	在 Parent 下查找 TipsGui 的 UIScale 并缓存
	@param entry GuiEntry - 注册项
]]
local function _tryBindTipsScale(entry: GuiEntry)
	if not entry.syncTipsGui then
		return
	end
	local tipsGui = _findTipsGui(entry)
	if not tipsGui then
		return
	end
	entry.tipsScale = StrokeAdapt.FindChildUIScale(tipsGui)
end

--[[
	把 GuiEntry 收成 StrokeAdapt 宿主（isAdaptEnabled / isLive 读 entry 实时值）
	@param entry GuiEntry - 注册项
	@return StrokeAdapt.StrokeHost - 描边宿主
]]
local function _toStrokeHost(entry: GuiEntry): StrokeAdapt.StrokeHost
	return {
		isAdaptEnabled = function()
			return entry.adaptStrokes
		end,
		strokes = entry.strokes,
		strokeRootsBound = entry.strokeRootsBound,
		connections = entry.connections,
		isLive = function()
			return _entries[entry.collector] == entry
		end,
	}
end

--[[
	确保已绑定 Stroke 子树：ScreenGui 含 TipsGui；世界空间只绑自身
	@param entry GuiEntry - 注册项
]]
local function _ensureStrokeTreesBound(entry: GuiEntry)
	if not StrokeAdapt.IsEnabled() then
		return
	end
	if not entry.adaptStrokes then
		return
	end
	if not StrokeAdapt.IsRootTypeEnabled(entry.collector.ClassName) then
		return
	end
	local host = _toStrokeHost(entry)
	StrokeAdapt.BindStrokeTree(host, entry.collector)
	if entry.syncTipsGui then
		local tipsGui = _findTipsGui(entry)
		if tipsGui then
			StrokeAdapt.BindStrokeTree(host, tipsGui)
		end
	end
end

--[[
	写入 adaptStrokes；关闭时清描边缓存（已绑的 DescendantAdded 靠 isAdaptEnabled 早退）
	@param entry GuiEntry - 注册项
	@param adaptStrokes boolean - 是否自动适配描边
]]
local function _setAdaptStrokes(entry: GuiEntry, adaptStrokes: boolean)
	entry.adaptStrokes = adaptStrokes
	if adaptStrokes then
		_ensureStrokeTreesBound(entry)
	else
		table.clear(entry.strokes)
	end
end

--[[
	仅刷新描边（BillboardGui / SurfaceGui 唯一刷新路径；不写 UIScale）
	@param entry GuiEntry - 注册项
]]
local function _refreshLayerStrokesNow(entry: GuiEntry)
	if not entry.collector.Parent then
		return
	end
	StrokeAdapt.RefreshStrokes(_toStrokeHost(entry))
end

--[[
	只刷新已注册的世界空间描边（相机 ViewportSize 变化；ScreenGui 走 AbsoluteSize）
	多次 Schedule 由 StrokeRefreshPump 合并，此处立即入队即可
]]
_refreshWorldSpaceStrokes = function()
	for _, entry in pairs(_entries) do
		if not entry.collector:IsA("ScreenGui") then
			_refreshLayerStrokesNow(entry)
		end
	end
end

--[[
	读取弹窗设备初始倍率（Small 屏用 Mobie_Scale，否则 PC_Scale）
	@param popScale UIScale - 弹窗 UIScale
	@return number - 初始倍率，默认 1
]]
local function _getInitScale(popScale: UIScale): number
	local initScale = 1
	if GuiService.ViewportDisplaySize == Enum.DisplaySize.Small then
		local mobileScale = popScale:GetAttribute(MOBILE_SCALE_ATTR)
		if typeof(mobileScale) == "number" then
			if mobileScale == 1 then
				initScale = MOBILE_SCALE_ONE_FALLBACK
			else
				initScale = mobileScale
			end
		end
	else
		local pcScale = popScale:GetAttribute(PC_SCALE_ATTR)
		if typeof(pcScale) == "number" then
			initScale = pcScale
		end
	end
	return initScale
end

--[[
	是否为全屏比例 Frame（跳过二次适配）
	@param frame Frame - 子 Frame
	@return boolean - Size 的 Scale 均为 1 时 true
]]
local function _isFullScreenFrame(frame: Frame): boolean
	return frame.Size.X.Scale == 1 and frame.Size.Y.Scale == 1
end

--[[
	对单个弹窗 Frame 计算并应用 AdaptScale
	@param entry GuiEntry - 所属 ScreenGui 注册项
	@param frame Frame - 弹窗根 Frame
	@param nowSize Vector2 - ScreenGui.AbsoluteSize
]]
local function _adaptPopupFrame(entry: GuiEntry, frame: Frame, nowSize: Vector2)
	local popScaleInst = StrokeAdapt.FindChildUIScale(frame)
	if not popScaleInst then
		return
	end
	local popScale: UIScale = popScaleInst

	if _isFullScreenFrame(frame) then
		return
	end

	local currentScale = popScale.Scale
	-- 动画中 AbsoluteSize 会塌缩，跳过以免污染 AdaptScale；保留上次写入值供 UIanima 使用
	if currentScale < ANIM_EPS then
		return
	end

	local safeScale = math.max(math.abs(currentScale), SCALE_EPS)
	-- AbsoluteSize 已含当前 PopScale；除回当前 Scale 得到未缩放参考尺寸，避免叠乘
	local unscaledX = frame.AbsoluteSize.X / safeScale
	local unscaledY = frame.AbsoluteSize.Y / safeScale
	if unscaledX <= SCALE_EPS or unscaledY <= SCALE_EPS then
		return
	end

	local initScale = _getInitScale(popScale)
	local scaleX = (nowSize.X * initScale) / unscaledX
	local scaleY = (nowSize.Y * initScale) / unscaledY
	local adaptScale = math.min(scaleX, scaleY)

	popScale:SetAttribute(ADAPT_SCALE_ATTR, adaptScale)
	popScale.Scale = adaptScale
end

--[[
	UIScale 是否带设备倍率属性（有其一即可，作为 HUD 直写 opt-in）
	@param uiScale UIScale - 待检测节点
	@return boolean - Mobie_Scale 或 PC_Scale 为 number 时 true
]]
local function _hasHudDeviceScaleAttr(uiScale: UIScale): boolean
	local mobileScale = uiScale:GetAttribute(MOBILE_SCALE_ATTR)
	local pcScale = uiScale:GetAttribute(PC_SCALE_ATTR)
	return typeof(mobileScale) == "number" or typeof(pcScale) == "number"
end

--[[
	读取 HUD 字面设备倍率（Small 用 Mobie_Scale，否则 PC_Scale；不用弹窗 1→0.98）
	@param uiScale UIScale - HUD 根 UIScale
	@return number - 字面倍率；缺对应属性时为 1
]]
local function _getHudDeviceScale(uiScale: UIScale): number
	if GuiService.ViewportDisplaySize == Enum.DisplaySize.Small then
		local mobileScale = uiScale:GetAttribute(MOBILE_SCALE_ATTR)
		if typeof(mobileScale) == "number" then
			return mobileScale
		end
		return 1
	end
	local pcScale = uiScale:GetAttribute(PC_SCALE_ATTR)
	if typeof(pcScale) == "number" then
		return pcScale
	end
	return 1
end

--[[
	对 Main 下一层非弹窗 Frame 按 Mobie_Scale/PC_Scale 直写 Scale（含全屏 HUD，如 Backpack）
	@param frame Frame - HUD 扫描根的直接子 Frame
]]
local function _adaptHudFrame(frame: Frame)
	local inst = frame:FindFirstChild(UI_SCALE_CHILD_NAME)
	if not inst or not inst:IsA("UIScale") then
		return
	end
	local uiScale = inst :: UIScale
	if not _hasHudDeviceScaleAttr(uiScale) then
		return
	end
	local hudScale = _getHudDeviceScale(uiScale)
	uiScale:SetAttribute(ADAPT_SCALE_ATTR, hudScale)
	if math.abs(uiScale.Scale - hudScale) > SCALE_EPS then
		uiScale.Scale = hudScale
	end
end

--[[
	扫描 Main 直接子 Frame，以及 ContentClip 的直接子 Frame（Backpack 在 Main 下，不一定在 Clip 内）
	@param screenGui ScreenGui - 已注册 ScreenGui
]]
local function _adaptHudFrames(screenGui: ScreenGui)
	local main = screenGui:FindFirstChild(MAIN_FRAME_NAME)
	if not main or not main:IsA("Frame") then
		return
	end
	for _, child in ipairs(main:GetChildren()) do
		if child:IsA("Frame") then
			_adaptHudFrame(child)
		end
	end
	local clip = main:FindFirstChild(CONTENT_CLIP_NAME)
	if clip and clip:IsA("Frame") then
		for _, child in ipairs(clip:GetChildren()) do
			if child:IsA("Frame") then
				_adaptHudFrame(child)
			end
		end
	end
end

--[[
	立即刷新 ScreenGui：根 contain Scale、弹窗 AdaptScale、HUD 直写、描边
	@param entry GuiEntry - ScreenGui 注册项
]]
local function _refreshScreenGuiNow(entry: GuiEntry)
	local screenGui = entry.collector
	if not screenGui:IsA("ScreenGui") then
		return
	end
	if not screenGui.Parent then
		return
	end

	local rootScale = entry.rootScale or _findRootUIScale(screenGui)
	entry.rootScale = rootScale
	if not rootScale then
		Log.warn("[UISetMgr] ScreenGui 缺少 UIScale:", screenGui:GetFullName())
		return
	end

	local nowSize = screenGui.AbsoluteSize
	if nowSize.X <= 0 or nowSize.Y <= 0 then
		return
	end

	local design = entry.designSize
	local scaleX = nowSize.X / design.X
	local scaleY = nowSize.Y / design.Y
	local rootUiScale = math.min(scaleX, scaleY) * entry.userScale
	rootScale.Scale = rootUiScale

	if entry.syncTipsGui then
		if not entry.tipsScale or not entry.tipsScale.Parent then
			_tryBindTipsScale(entry)
		end
		if entry.tipsScale then
			entry.tipsScale.Scale = rootUiScale
		end
	end

	if entry.adaptPopups then
		for _, child in ipairs(screenGui:GetChildren()) do
			if child:IsA("Frame") and child.Name ~= MAIN_FRAME_NAME then
				_adaptPopupFrame(entry, child, nowSize)
			end
		end
		_adaptHudFrames(screenGui)
	end

	StrokeAdapt.RefreshStrokes(_toStrokeHost(entry))
end

--[[
	按类型分路刷新：ScreenGui 写根 Scale；世界空间只刷描边
	@param entry GuiEntry - 注册项
]]
local function _refreshEntryNow(entry: GuiEntry)
	if entry.collector:IsA("ScreenGui") then
		_refreshScreenGuiNow(entry)
		return
	end
	_refreshLayerStrokesNow(entry)
end

--[[
	防抖调度刷新（合并同帧多次 AbsoluteSize 变化；仅 ScreenGui）
	@param entry GuiEntry - 注册项
]]
local function _scheduleRefresh(entry: GuiEntry)
	if entry.refreshScheduled then
		return
	end
	entry.refreshScheduled = true
	task.defer(function()
		entry.refreshScheduled = false
		if _entries[entry.collector] ~= entry then
			return
		end
		_refreshEntryNow(entry)
	end)
end

--[[
	断开并清空注册项的所有连接
	@param entry GuiEntry - 注册项
]]
local function _disconnectEntry(entry: GuiEntry)
	for _, conn in ipairs(entry.connections) do
		conn:Disconnect()
	end
	table.clear(entry.connections)
end

--[[
	从注册表移除 LayerCollector 并断开监听
	@param collector LayerCollector - 已注册根
]]
local function _unregisterCollector(collector: LayerCollector)
	local entry = _entries[collector]
	if not entry then
		return
	end
	_disconnectEntry(entry)
	table.clear(entry.strokes)
	table.clear(entry.strokeRootsBound)
	_entries[collector] = nil
	_maybeDisconnectViewportListener()
end

--[[
	合并 RegisterScreenGui 选项与默认值
	@param options RegisterOptions? - 调用方选项
	@return ResolvedOptions - 已填默认值的选项
]]
local function _resolveOptions(options: RegisterOptions?): ResolvedOptions
	local opts = options or {}
	return {
		designSize = opts.designSize or DEFAULT_DESIGN_SIZE,
		userScale = if opts.userScale ~= nil then opts.userScale else DEFAULT_USER_SCALE,
		adaptPopups = if opts.adaptPopups ~= nil then opts.adaptPopups else true,
		syncTipsGui = if opts.syncTipsGui ~= nil then opts.syncTipsGui else false,
		adaptStrokes = if opts.adaptStrokes ~= nil then opts.adaptStrokes else true,
	}
end

--[[
	自动注册一个世界空间 Gui（已注册或未在白名单则跳过）
	@param inst Instance - BillboardGui 或 SurfaceGui
]]
local function _tryAutoRegisterCollector(inst: Instance)
	if not StrokeAdapt.IsWatchableCollector(inst) then
		return
	end
	local collector = inst :: LayerCollector
	if _entries[collector] then
		return
	end
	UISetMgr.RegisterLayerCollector(collector)
end

--[[
	监听 HUD 扫描容器的直接子 Frame 入树（Main / ContentClip）
	@param entry GuiEntry - ScreenGui 注册项
	@param container Instance - Main 或 ContentClip
]]
local function _bindHudChildAdded(entry: GuiEntry, container: Instance)
	if not container:IsA("Frame") then
		return
	end
	table.insert(entry.connections, container.ChildAdded:Connect(function(child)
		if not entry.adaptPopups or not child:IsA("Frame") then
			return
		end
		if child.Name == CONTENT_CLIP_NAME then
			_bindHudChildAdded(entry, child)
		end
		_scheduleRefresh(entry)
	end))
end

--[[
	给已有 Main / ContentClip 绑一层 ChildAdded
	@param entry GuiEntry - ScreenGui 注册项
	@param screenGui ScreenGui - 所属 ScreenGui
]]
local function _bindHudScanListeners(entry: GuiEntry, screenGui: ScreenGui)
	if not entry.adaptPopups then
		return
	end
	local main = screenGui:FindFirstChild(MAIN_FRAME_NAME)
	if not main then
		return
	end
	_bindHudChildAdded(entry, main)
	local clip = main:FindFirstChild(CONTENT_CLIP_NAME)
	if clip then
		_bindHudChildAdded(entry, clip)
	end
end

--[[
	绑定 ScreenGui 的 AbsoluteSize / 弹窗 ChildAdded / HUD 一层 / TipsGui / Ancestry 监听
	@param entry GuiEntry - 新建的 ScreenGui 注册项
]]
local function _bindScreenGuiListeners(entry: GuiEntry)
	local screenGui = entry.collector
	if not screenGui:IsA("ScreenGui") then
		return
	end

	table.insert(entry.connections, screenGui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		_scheduleRefresh(entry)
	end))

	table.insert(entry.connections, screenGui.ChildAdded:Connect(function(child)
		if not entry.adaptPopups or not child:IsA("Frame") then
			return
		end
		if child.Name == MAIN_FRAME_NAME then
			_bindHudScanListeners(entry, screenGui)
		end
		_scheduleRefresh(entry)
	end))

	_bindHudScanListeners(entry, screenGui)

	local parent = screenGui.Parent
	if parent and entry.syncTipsGui then
		table.insert(entry.connections, parent.ChildAdded:Connect(function(child)
			if child.Name == TIPS_GUI_NAME and child:IsA("ScreenGui") then
				_tryBindTipsScale(entry)
				if entry.adaptStrokes then
					StrokeAdapt.BindStrokeTree(_toStrokeHost(entry), child)
				end
				_scheduleRefresh(entry)
			end
		end))
	end

	table.insert(entry.connections, screenGui.AncestryChanged:Connect(function(_, newParent)
		if newParent == nil then
			UISetMgr.UnregisterScreenGui(screenGui)
		end
	end))
end

-- ============================================================================
-- 公共 API
-- ============================================================================

--[[
	注册 ScreenGui 自适应缩放（幂等：已注册则更新选项并立即刷新，不重复绑监听）
	@param screenGui ScreenGui - 目标 ScreenGui（需已有 UIScale 子节点）
	@param options RegisterOptions? - designSize / userScale / adaptPopups（弹窗 contain + Main 下一层 HUD 直写） / syncTipsGui / adaptStrokes
]]
function UISetMgr.RegisterScreenGui(screenGui: ScreenGui, options: RegisterOptions?)
	if not screenGui or not screenGui:IsA("ScreenGui") then
		Log.warn("[UISetMgr] RegisterScreenGui 参数无效")
		return
	end

	local resolved = _resolveOptions(options)
	local existing = _entries[screenGui]
	if existing then
		existing.designSize = resolved.designSize
		existing.userScale = resolved.userScale
		existing.adaptPopups = resolved.adaptPopups
		existing.syncTipsGui = resolved.syncTipsGui
		existing.rootScale = _findRootUIScale(screenGui)
		if resolved.syncTipsGui then
			_tryBindTipsScale(existing)
		else
			existing.tipsScale = nil
		end
		_setAdaptStrokes(existing, resolved.adaptStrokes)
		_refreshEntryNow(existing)
		return
	end

	local entry: GuiEntry = {
		collector = screenGui,
		rootScale = _findRootUIScale(screenGui),
		designSize = resolved.designSize,
		userScale = resolved.userScale,
		adaptPopups = resolved.adaptPopups,
		syncTipsGui = resolved.syncTipsGui,
		adaptStrokes = resolved.adaptStrokes,
		tipsScale = nil,
		strokes = {},
		strokeRootsBound = {},
		connections = {},
		refreshScheduled = false,
	}

	if resolved.syncTipsGui then
		_tryBindTipsScale(entry)
	end

	_bindScreenGuiListeners(entry)
	_entries[screenGui] = entry
	_ensureStrokeTreesBound(entry)
	_ensureViewportListener()
	_refreshEntryNow(entry)
end

--[[
	注销 ScreenGui：断开监听并从注册表移除
	@param screenGui ScreenGui - 已注册的 ScreenGui
]]
function UISetMgr.UnregisterScreenGui(screenGui: ScreenGui)
	if not screenGui then
		return
	end
	_unregisterCollector(screenGui)
end

--[[
	注册 BillboardGui / SurfaceGui 的描边适配（幂等；不写 UIScale / Size / Adornee）
	@param gui LayerCollector - BillboardGui 或 SurfaceGui
	@param options LayerRegisterOptions? - adaptStrokes，默认 true
]]
function UISetMgr.RegisterLayerCollector(gui: LayerCollector, options: LayerRegisterOptions?)
	if not gui then
		Log.warn("[UISetMgr] RegisterLayerCollector 参数无效")
		return
	end
	if gui:IsA("ScreenGui") then
		Log.warn("[UISetMgr] RegisterLayerCollector 拒绝 ScreenGui，请用 RegisterScreenGui")
		return
	end
	if not gui:IsA("BillboardGui") and not gui:IsA("SurfaceGui") then
		Log.warn("[UISetMgr] RegisterLayerCollector 仅接受 BillboardGui 或 SurfaceGui")
		return
	end
	if not StrokeAdapt.IsRootTypeEnabled(gui.ClassName) then
		return
	end

	local adaptStrokes = true
	if options and options.adaptStrokes ~= nil then
		adaptStrokes = options.adaptStrokes
	end

	local existing = _entries[gui]
	if existing then
		_setAdaptStrokes(existing, adaptStrokes)
		_refreshLayerStrokesNow(existing)
		return
	end

	local entry: GuiEntry = {
		collector = gui,
		rootScale = nil,
		designSize = DEFAULT_DESIGN_SIZE,
		userScale = DEFAULT_USER_SCALE,
		adaptPopups = false,
		syncTipsGui = false,
		adaptStrokes = adaptStrokes,
		tipsScale = nil,
		strokes = {},
		strokeRootsBound = {},
		connections = {},
		refreshScheduled = false,
	}

	table.insert(entry.connections, gui.AncestryChanged:Connect(function(_, newParent)
		if newParent ~= nil then
			return
		end
		-- 流送/改父可能同帧先 nil 再挂上；下一拍仍无 Parent 才注销，避免标签仍在却不再注册
		task.defer(function()
			if _entries[gui] ~= entry then
				return
			end
			if gui.Parent == nil then
				UISetMgr.UnregisterLayerCollector(gui)
			end
		end)
	end))

	_entries[gui] = entry
	_ensureStrokeTreesBound(entry)
	_ensureViewportListener()
	_refreshLayerStrokesNow(entry)
end

--[[
	注销 BillboardGui / SurfaceGui 描边适配
	@param gui LayerCollector - 已注册的世界空间 Gui
]]
function UISetMgr.UnregisterLayerCollector(gui: LayerCollector)
	if not gui then
		return
	end
	if gui:IsA("ScreenGui") then
		Log.warn("[UISetMgr] UnregisterLayerCollector 请改用 UnregisterScreenGui")
		return
	end
	_unregisterCollector(gui)
end

--[[
	监听 PlayerGui，自动注册其中的 BillboardGui / SurfaceGui（幂等；不自动 ScreenGui）
	@param playerGui PlayerGui - 本地玩家 PlayerGui
]]
function UISetMgr.WatchPlayerGui(playerGui: PlayerGui)
	TagWatch.WatchPlayerGui(playerGui, _tryAutoRegisterCollector)
end

--[[
	监听 CollectionService 标签，注册 BillboardGui / SurfaceGui（含 workspace；幂等）
]]
function UISetMgr.WatchTaggedCollectors()
	TagWatch.Watch({
		tryAutoRegister = _tryAutoRegisterCollector,
		unregisterCollector = UISetMgr.UnregisterLayerCollector,
	})
end

--[[
	强制刷新；gui 为 nil 时刷新全部已注册项。
	ScreenGui 立即写根 Scale / 弹窗 AdaptScale / HUD 直写 Scale；Thickness 异步分片，返回后不要立刻当最终值。
	@param gui LayerCollector? - 指定根；nil 表示全部
]]
function UISetMgr.Refresh(gui: LayerCollector?)
	if gui then
		local entry = _entries[gui]
		if entry then
			_refreshEntryNow(entry)
		end
		return
	end
	for _, entry in pairs(_entries) do
		_refreshEntryNow(entry)
	end
end

--[[
	设置单个 ScreenGui 的用户倍率（乘在根 contain Scale 上）并立即刷新
	@param screenGui ScreenGui - 已注册的 ScreenGui
	@param userScale number - 用户倍率，通常 0~1 或 0.75~1
]]
function UISetMgr.SetUserScale(screenGui: ScreenGui, userScale: number)
	if not screenGui or not screenGui:IsA("ScreenGui") then
		Log.warn("[UISetMgr] SetUserScale：需要 ScreenGui")
		return
	end
	local entry = _entries[screenGui]
	if not entry then
		Log.warn("[UISetMgr] SetUserScale：未注册", screenGui:GetFullName())
		return
	end
	entry.userScale = userScale
	_refreshEntryNow(entry)
end

--[[
	查询已注册 ScreenGui 当前根 UIScale.Scale
	@param screenGui ScreenGui - 已注册的 ScreenGui
	@return number? - 根 Scale；未注册或无 UIScale 时 nil
]]
function UISetMgr.GetRootScale(screenGui: ScreenGui): number?
	if not screenGui or not screenGui:IsA("ScreenGui") then
		return nil
	end
	local entry = _entries[screenGui]
	if not entry then
		return nil
	end
	local root = entry.rootScale or _findRootUIScale(screenGui)
	if not root then
		return nil
	end
	return root.Scale
end

--[[
	按祖先 UIScale 积更新 UIStroke 粗细；内部再乘屏幕档/设备倍率并钳下限。
	自动 Refresh 路径异步分片且已剔除窗口层（弹窗 AdaptScale 与 HUD 直写）；本函数本身同步写入（值未变则跳过）。
	@param obj UIStroke - 目标描边
	@param uiScale number - 祖先 UIScale 积（不要预乘设备倍率）；直接调用不会再乘 ViewportContain、也不会跳过窗口层
]]
function UISetMgr.UpdateUIStroke(obj: UIStroke, uiScale: number)
	StrokeAdapt.UpdateUIStroke(obj, uiScale)
end

return UISetMgr
