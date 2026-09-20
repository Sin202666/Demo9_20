--[[
	Module: UIManager
	Description: 客户端本地 UI 事件路由（Remote / Bindable → ScreenGui 弹窗与 GuiScripts 模块）
	Author: 林奥宇
	Created: 2026-01-19
	Last Modified: 2026-09-04

	功能：
	- 监听 SHOW_LOCAL_UI / REFRESH_LOCAL_UI，驱动 ScreenGui / ScreenGui_Full 下同名 Frame 显隐
	- 按 uiName 惰性 require GuiScripts/ModuleScript 对应模块，调用 updateUi / openUi / closeUi
	- GameConfig 门控：DailyReward←每日签到.启用、OnlineAward←在线奖励.启用；关闭则忽略 SHOW/REFRESH 并强制藏帧
	- 可选 PopUp / PopBack 动画（Utils.UIanima）；openUi 后刷新背景模糊（Utils.UIMgr）

	加载方式：
	- 本文件是 StarterPlayerScripts LocalScript，客户端自动运行并注册事件
	- 不是 Utils 模块，禁止 require；不要写 Utils.UIManager / 模块表 / Init()

	约定：
	- ScreenGui 或 ScreenGui_Full 下须存在与 uiName 同名的 Frame；ModuleScript 可选，无则仅做显隐与动画
	- SHOW_LOCAL_UI Bindable：isShow 为 nil 时按当前 Visible 取反；Remote 须显式传 isShow（nil 只刷新已显示弹窗）
	- REFRESH_LOCAL_UI：仅当弹窗已 Visible 时调用 updateUi（isShow 固定为 nil）
	- isAnim 默认 true；false 时直接改 Visible / UIScale，关闭时同步刷新模糊
	- GuiScripts 按名惰性 require（无法在文件顶列举全部弹窗模块）；加载失败会记入缺失表，避免反复 pcall

	排队（QUEUEABLE_UI_NAMES）：
	- 把 uiName 写入常量后启用同屏排队；未写入的弹窗时序不变
	- 显示中或 PopBack 占用中再次打开会把 uiData 入队（超出 QUEUE_MAX 丢最旧）
	- 关窗：PopBack 完成（无动画则 defer）后自动取队首打开；占用锁避免与 Tween 抢同一 Frame
	- 仍可用 isShow=true 且 uiData=nil 手动出队（兜底）

	依赖：
	- Utils.NetWork / NetMsg：事件注册
	- Utils.UIanima / UIMgr：弹窗动画与模糊
	- ReplicatedStorage.ClientSideCode.GuiScripts.ModuleScript：各 UI 业务脚本

	示例：
	```lua
	NetWork.FireBindable(NetMsg.SHOW_LOCAL_UI, "UpdateLog")
	NetWork.FireClient(player, NetMsg.SHOW_LOCAL_UI, "关服提示", nil, true)
	NetWork.FireBindable(NetMsg.REFRESH_LOCAL_UI, "DailyReward", { day = 1 })
	```
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local NetMsg = Utils.NetMsg
local NetWork = Utils.NetWork
local UIanima = Utils.UIanima
local UIMgr = Utils.UIMgr
local Log = Utils.Log
local LocalPlayer = Utils.LocalPlayer
local ReplicatedStorage = Utils.ReplicatedStorage
local SystemGameConfig = Utils.SystemGameConfig

-- ========================================
-- 常量
-- ========================================
-- PlayerGui / ScreenGui / GuiScripts 为本 Manager 硬依赖，缺失则无法路由
local WAIT_GUI_FOREVER = math.huge
local DEFAULT_PLAY_ANIM = true
local VISIBLE_SCALE = 1
local HIDDEN_SCALE = 0

-- 写入 uiName 后启用同屏排队；AwardPop 关窗后自动出队，其它弹窗不进表
local QUEUEABLE_UI_NAMES: { string } = table.freeze({ "AwardPop" })
local QUEUE_MAX = 16

-- 功能开关：uiName → GameConfig 路径；缺键视为开。只做路由门控，不写结算
local FEATURE_UI_GATES: { [string]: { string } } = table.freeze({
	DailyReward = { "每日签到", "启用" },
	OnlineAward = { "在线奖励", "启用" },
})

-- ========================================
-- 私有变量
-- ========================================
local _playerGui: PlayerGui = LocalPlayer:WaitForChild("PlayerGui", WAIT_GUI_FOREVER) :: PlayerGui
local _screenGui: ScreenGui = _playerGui:WaitForChild("ScreenGui", WAIT_GUI_FOREVER) :: ScreenGui
local _screenGuiFull: ScreenGui? = _playerGui:FindFirstChild("ScreenGui_Full") :: ScreenGui?
local _moduleScriptFolder: Folder = ReplicatedStorage:WaitForChild("ClientSideCode")
	:WaitForChild("GuiScripts")
	:WaitForChild("ModuleScript", WAIT_GUI_FOREVER) :: Folder

local _queueableUi: { [string]: { any } } = {}
local _closingUi: { [string]: boolean } = {}
local _queueResumeToken: { [string]: number } = {}
for _, queuedName in QUEUEABLE_UI_NAMES do
	_queueableUi[queuedName] = {}
	_queueResumeToken[queuedName] = 0
end

local _uiFrameCache: { [string]: Frame } = {}
local _uiModuleCache: { [string]: any } = {}
local _uiModuleLoadFailed: { [string]: boolean } = {}

-- ========================================
-- 私有函数
-- ========================================

--[[
	校验弹窗名是否为非空字符串（Remote 载荷不可信）
	@param uiName any - SHOW_LOCAL_UI / REFRESH_LOCAL_UI 第一个参数
	@return boolean - true 表示可作为 Frame / ModuleScript 名
]]
local function _isValidUiName(uiName: any): boolean
	return type(uiName) == "string" and uiName ~= ""
end

--[[
	功能开关是否允许打开该弹窗（未列入 FEATURE_UI_GATES 的恒为开）
	@param uiName string - 弹窗名
	@return boolean - true 表示可开
]]
local function _isFeatureUiEnabled(uiName: string): boolean
	local path = FEATURE_UI_GATES[uiName]
	if not path then
		return true
	end
	return SystemGameConfig.GetValue(path) ~= false
end

--[[
	将 isAnim 规范为 boolean；nil 时用 DEFAULT_PLAY_ANIM
	@param isAnim any - 调用方传入的动画开关；非 boolean 视为默认
	@return boolean - 是否播放 PopUp / PopBack
]]
local function _resolvePlayAnim(isAnim: any): boolean
	if type(isAnim) == "boolean" then
		return isAnim
	end
	return DEFAULT_PLAY_ANIM
end

--[[
	无动画时同步显隐，并复位 UIScale，避免下次 PopUp 从错误 Scale 起步
	@param popUiFrame Frame - 弹窗根 Frame
	@param visible boolean - true 显示且 Scale=VISIBLE_SCALE；false 隐藏且 Scale=HIDDEN_SCALE
	@return nil
]]
local function _setFrameVisibleNoAnim(popUiFrame: Frame, visible: boolean)
	popUiFrame.Visible = visible
	local uiScale = popUiFrame:FindFirstChildOfClass("UIScale")
	if uiScale then
		uiScale.Scale = if visible then VISIBLE_SCALE else HIDDEN_SCALE
	end
end

--[[
	查找 ScreenGui / ScreenGui_Full 下与 uiName 同名的弹窗 Frame（命中后缓存）
	@param uiName string - Frame.Name，与 ModuleScript 名一致
	@param warnIfMissing boolean? - true 时在未找到时 Log.warn
	@return Frame? - 弹窗根 Frame；不存在或类型不符时 nil
]]
local function _findPopUiFrame(uiName: string, warnIfMissing: boolean?): Frame?
	local cached = _uiFrameCache[uiName]
	if cached and cached.Parent then
		return cached
	end
	_uiFrameCache[uiName] = nil

	local popUi = _screenGui:FindFirstChild(uiName)
	if popUi and popUi:IsA("Frame") then
		_uiFrameCache[uiName] = popUi
		return popUi
	end

	if not _screenGuiFull then
		_screenGuiFull = _playerGui:FindFirstChild("ScreenGui_Full") :: ScreenGui?
	end
	if _screenGuiFull then
		popUi = _screenGuiFull:FindFirstChild(uiName)
		if popUi and popUi:IsA("Frame") then
			_uiFrameCache[uiName] = popUi
			return popUi
		end
	end

	if warnIfMissing then
		Log.warn("没有这个弹窗:", uiName)
	end
	return nil
end

--[[
	按 uiName 惰性加载并缓存 GuiScripts ModuleScript（名称与 Frame 一致）
	require 失败会记入 _uiModuleLoadFailed，避免同一坏模块反复 pcall
	@param uiName string - ModuleScript.Name
	@return any? - require 成功返回模块表；无脚本或加载失败时 nil
]]
local function _loadUiModule(uiName: string): any?
	if _uiModuleLoadFailed[uiName] then
		return nil
	end

	local cached = _uiModuleCache[uiName]
	if cached ~= nil then
		return cached
	end

	local uiModuleScript = _moduleScriptFolder:FindFirstChild(uiName)
	if not uiModuleScript or not uiModuleScript:IsA("ModuleScript") then
		return nil
	end

	local success, loadedModule = pcall(require, uiModuleScript :: ModuleScript)
	if not success then
		_uiModuleLoadFailed[uiName] = true
		Log.warn("加载 UI 模块失败:", uiName, loadedModule)
		return nil
	end

	_uiModuleCache[uiName] = loadedModule
	return loadedModule
end

--[[
	调用 GuiScripts updateUi（无该函数时跳过）
	@param updateUiModel any - 已加载的 UI 模块表
	@param uiData any? - 传给 updateUi 的业务数据
	@param ... any - 透传给 updateUi 的额外参数
	@return nil
]]
local function _invokeUpdateUi(updateUiModel: any, uiData: any?, ...)
	if updateUiModel and type(updateUiModel.updateUi) == "function" then
		updateUiModel:updateUi(uiData, ...)
	end
end

--[[
	排队弹窗是否占用中（正在显示或 PopBack 未结束）
	@param uiName string - 弹窗名
	@param popUiFrame Frame - 弹窗根 Frame
	@return boolean - 占用中为 true
]]
local function _isQueueBusy(uiName: string, popUiFrame: Frame): boolean
	return _queueableUi[uiName] ~= nil and (popUiFrame.Visible or _closingUi[uiName] == true)
end

--[[
	uiData 入队；超出 QUEUE_MAX 丢掉最旧一条
	@param uiName string - 已启用排队的弹窗名
	@param uiData any? - 待展示数据
	@return nil
]]
local function _enqueueUi(uiName: string, uiData: any?)
	local queue = _queueableUi[uiName]
	if not queue then
		return
	end
	if #queue >= QUEUE_MAX then
		table.remove(queue, 1)
		Log.warn("UI 排队已满，丢弃最旧:", uiName)
	end
	table.insert(queue, uiData)
end

--[[
	打开弹窗：先 updateUi，再 PopUp 或无动画显示，最后 openUi 并刷新模糊
	显示中或关闭动画占用中且已启用排队时改为入队，不打断当前弹窗
	@param uiName string - 弹窗名称（用于排队键）
	@param popUiFrame Frame - 弹窗根 Frame
	@param updateUiModel any? - 已加载的 UI 模块表
	@param uiData any? - 传给 updateUi 的业务数据
	@param playAnim boolean - 是否播放 PopUp
	@param ... any - 透传给 updateUi 的额外参数
	@return nil - 入队时提前 return
]]
local function _openUi(uiName: string, popUiFrame: Frame, updateUiModel: any?, uiData: any?, playAnim: boolean, ...)
	if _isQueueBusy(uiName, popUiFrame) then
		_enqueueUi(uiName, uiData)
		return
	end

	_invokeUpdateUi(updateUiModel, uiData, ...)

	if playAnim then
		UIanima.PopUp(popUiFrame)
	else
		_setFrameVisibleNoAnim(popUiFrame, true)
	end

	if updateUiModel and type(updateUiModel.openUi) == "function" then
		updateUiModel:openUi()
		UIMgr.UpdateBlurVisible()
	end
end

--[[
	关窗占用结束：清锁后若队列非空则打开队首
	@param uiName string - 弹窗名
	@param token number - 本次关闭代数；过期回调直接 return
	@return nil
]]
local function _onHideCompleted(uiName: string, token: number)
	if _queueResumeToken[uiName] ~= token then
		return
	end
	_closingUi[uiName] = false

	local queue = _queueableUi[uiName]
	if not queue or #queue == 0 then
		return
	end
	local nextData = table.remove(queue, 1)
	local popUiFrame = _findPopUiFrame(uiName, false)
	if not popUiFrame then
		return
	end
	_openUi(uiName, popUiFrame, _loadUiModule(uiName), nextData, DEFAULT_PLAY_ANIM)
end

--[[
	关闭弹窗：动画走 PopBack（Tween 结束后隐藏并刷新模糊）；无动画则立即隐藏
	排队弹窗在 PopBack 完成后自动出队；占用锁防止关窗动画期间再开抢 Frame
	@param uiName string - 弹窗名
	@param popUiFrame Frame - 弹窗根 Frame
	@param updateUiModel any? - 已加载的 UI 模块表
	@param playAnim boolean - 是否播放 PopBack
	@return nil
]]
local function _hideUi(uiName: string, popUiFrame: Frame, updateUiModel: any?, playAnim: boolean)
	local isQueueable = _queueableUi[uiName] ~= nil
	local token = 0
	if isQueueable then
		_closingUi[uiName] = true
		token = (_queueResumeToken[uiName] or 0) + 1
		_queueResumeToken[uiName] = token
	end

	if playAnim then
		if isQueueable then
			UIanima.PopBack(popUiFrame, function()
				_onHideCompleted(uiName, token)
			end)
		else
			UIanima.PopBack(popUiFrame)
		end
	else
		_setFrameVisibleNoAnim(popUiFrame, false)
		UIMgr.UpdateBlurVisible()
		if isQueueable then
			task.defer(function()
				_onHideCompleted(uiName, token)
			end)
		end
	end
	if updateUiModel and type(updateUiModel.closeUi) == "function" then
		updateUiModel:closeUi()
	end
end

--[[
	仅刷新已显示弹窗的数据；不可见时不调用 updateUi
	@param popUiFrame Frame - 弹窗根 Frame
	@param updateUiModel any? - 已加载的 UI 模块表
	@param uiData any? - 传给 updateUi 的业务数据
	@param ... any - 透传给 updateUi 的额外参数
	@return nil
]]
local function _refreshUi(popUiFrame: Frame, updateUiModel: any?, uiData: any?, ...)
	if popUiFrame.Visible then
		_invokeUpdateUi(updateUiModel, uiData, ...)
	end
end

--[[
	显隐弹窗并驱动对应 ModuleScript 生命周期
	@param uiName string - 弹窗与 ModuleScript 名称
	@param uiData any? - 传给 updateUi 的业务数据；排队 UI 在 isShow=true 且 uiData=nil 时也可手动取队首
	@param isShow boolean? - true 打开、false 关闭、nil 仅刷新已显示弹窗；非 boolean 且非 nil 时拒绝
	@param isAnim boolean? - 是否播放 PopUp/PopBack；默认 DEFAULT_PLAY_ANIM
	@param warnIfMissing boolean? - 找不到 Frame 时是否 Log.warn
	@param ... any - 透传给 updateUi 的额外参数
	@return nil - isShow 非法、弹窗不存在或排队取数为空时 return
]]
local function _showUi(uiName: string, uiData: any?, isShow: boolean?, isAnim: boolean?, warnIfMissing: boolean?, ...)
	if not _isFeatureUiEnabled(uiName) then
		local gatedFrame = _findPopUiFrame(uiName, false)
		if gatedFrame then
			_setFrameVisibleNoAnim(gatedFrame, false)
		end
		return
	end

	if isShow ~= nil and type(isShow) ~= "boolean" then
		Log.warn("SHOW_LOCAL_UI isShow 非法:", uiName, isShow)
		return
	end

	local playAnim = _resolvePlayAnim(isAnim)

	if _queueableUi[uiName] and uiData == nil and isShow == true then
		uiData = table.remove(_queueableUi[uiName], 1)
		if uiData == nil then
			return
		end
	end

	local popUiFrame = _findPopUiFrame(uiName, warnIfMissing)
	if not popUiFrame then
		return
	end

	local updateUiModel = _loadUiModule(uiName)

	if isShow == false then
		_hideUi(uiName, popUiFrame, updateUiModel, playAnim)
		return
	end

	if isShow == true then
		_openUi(uiName, popUiFrame, updateUiModel, uiData, playAnim, ...)
		return
	end

	_refreshUi(popUiFrame, updateUiModel, uiData, ...)
end

--[[
	SHOW_LOCAL_UI Bindable 回调：isShow 为 nil 时按当前 Visible 取反
	@param uiName any - 弹窗名称
	@param uiData any? - updateUi 数据
	@param isShow boolean? - 显式显隐；nil 时切换
	@param isAnim boolean? - 是否播放动画；默认 true
	@param ... any - 透传给 updateUi
	@return nil - 名称非法或弹窗不存在时 Log.warn 并 return
]]
local function _onShowLocalUI(uiName: any, uiData: any?, isShow: boolean?, isAnim: boolean?, ...)
	if not _isValidUiName(uiName) then
		Log.warn("SHOW_LOCAL_UI uiName 非法:", uiName)
		return
	end

	local popUiFrame = _findPopUiFrame(uiName, true)
	if not popUiFrame then
		return
	end

	if isShow == nil then
		_showUi(uiName, uiData, not popUiFrame.Visible, isAnim, false, ...)
	else
		_showUi(uiName, uiData, isShow, isAnim, false, ...)
	end
end

--[[
	REFRESH_LOCAL_UI Bindable 回调：弹窗已显示时刷新数据
	@param uiName any - 弹窗名称
	@param uiData any? - updateUi 数据
	@param isAnim boolean? - 是否播放动画；本事件不传 isShow，固定为 nil
	@param ... any - 透传给 updateUi
	@return nil - 名称非法或弹窗不存在时 Log.warn 并 return
]]
local function _onRefreshLocalUI(uiName: any, uiData: any?, isAnim: boolean?, ...)
	if not _isValidUiName(uiName) then
		Log.warn("REFRESH_LOCAL_UI uiName 非法:", uiName)
		return
	end
	_showUi(uiName, uiData, nil, isAnim, true, ...)
end

--[[
	SHOW_LOCAL_UI Remote 回调：服务端须显式传 isShow；失败静默 + Log，不向调用方抛错
	@param uiName any - 弹窗名称
	@param uiData any? - updateUi 数据
	@param isShow boolean? - 显式显隐
	@param isAnim boolean? - 是否播放动画；默认 true
	@param ... any - 透传给 updateUi
	@return nil - 名称非法或弹窗不存在时静默 return（与 Remote 惯例一致）
]]
local function _onShowLocalUIRemote(uiName: any, uiData: any?, isShow: boolean?, isAnim: boolean?, ...)
	if not _isValidUiName(uiName) then
		Log.warn("SHOW_LOCAL_UI Remote uiName 非法:", uiName)
		return
	end
	_showUi(uiName, uiData, isShow, isAnim, false, ...)
end

-- ========================================
-- 初始化（LocalScript 启动即绑定，无对外 Init）
-- ========================================
for gatedName in FEATURE_UI_GATES do
	if not _isFeatureUiEnabled(gatedName) then
		local gatedFrame = _findPopUiFrame(gatedName, false)
		if gatedFrame then
			_setFrameVisibleNoAnim(gatedFrame, false)
		end
	end
end

NetWork.RegisterBindableEvent(NetMsg.REFRESH_LOCAL_UI, _onRefreshLocalUI)
NetWork.RegisterBindableEvent(NetMsg.SHOW_LOCAL_UI, _onShowLocalUI)
NetWork.RegisterClientRemoteEvent(NetMsg.SHOW_LOCAL_UI, _onShowLocalUIRemote)
