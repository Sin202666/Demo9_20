--[[
	Module: CameraModule
	Description: 客户端相机控制与震动，支持优先级事件栈与辅助表现叠加
	Author: 林奥宇
	Created: 2026-01-01
	Last Modified: 2026-08-31

	功能：
	- 主相机事件：按优先级接管 Scriptable 相机与 FOV；栈空归还开镜前跟相机角度
	- 辅助事件：无主事件时叠加 CFrame / FOV 偏移；主事件生效期间 mute Helper
	- 相机震动：多层 Trauma + 方向 Impulse + 命名源 Sustain（见 ShakeRuntime）
	- ShiftLock 状态同步：MouseBehavior.LockCenter → LocalPlayer.IsShiftLocked
	- ShiftLock 开关键重绑：PlayerModule MouseLockController.BoundKeys
	  （默认 LeftControl，见 GameConfig.CharacterControl.ShiftLock键；与 CharacterControl 冲刺 LeftShift 分离）
	- CameraMode 栈：Default/ShiftLock/OTS/LockOn/Aim；引擎 ShiftLock 映射为栈源 Engine:MouseLock

	子模块：
	- CameraMode.luau          模式栈（PushMode/PopMode；基线 Helper 偏移）
	- ShakePresets.luau        震动类型预设
	- ShakeRuntime.luau        Trauma / Kick / Sustain 运行时
	- TraumaNoise.luau         Trauma 噪声采样
	- CameraShiftLock.luau     IsShiftLocked 同步与开关键重绑
	- CameraSettingShake.luau  Setting.Shake 监听
	- CameraHandoff.luau       开镜快照、轨道归还、FOV 退出过渡
	- CameraConfig.luau        GameConfig 数值读取与震动/FOV 常量
	- CameraShakeApi.luau      公开震动 API（Once/At/Impulse/Sustain）

	================================================================================
	使用说明
	================================================================================

	【引入方式】
	local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
	local CameraModule = Utils.CameraModule
	local EnumMgr = Utils.EnumMgr

	模块路径：ReplicatedStorage/ClientSideCode/SystemModule/CameraModule/
	通过 Utils.CameraModule 延迟加载，业务代码不要 require 长路径。

	【所有权约定】（强制）
	| 状态                         | 允许写入方                                      |
	|------------------------------|-------------------------------------------------|
	| CFrame / FieldOfView         | 仅 CameraModule（主事件 / Helper delta / 震动） |
	| CameraMinZoomDistance        | HatchCamera 抽蛋表现专用；禁止旁路写 CFrame     |
	| FOV 脉冲（冲刺等）           | CameraImpulse → AnimateFov 唯一 Helper          |

	业务代码只注册/注销事件与震动，不要自行 BindToRenderStep 写 CurrentCamera。

	【架构与调用链】
	StarterPlayerScripts/Manager/CameraManager.client.luau
	  → CameraModule.Init()（绑定 RenderStep，每帧更新相机）
	StarterCharacterScripts / 其他客户端业务
	  → EnableCameraEvent / EnableCameraHelperEvent / CameraShakeOnce / CameraShakeAt

	【运行环境】
	| API                              | 调用端     | 说明                                      |
	|----------------------------------|------------|-------------------------------------------|
	| Init / destroy                   | 仅 Manager | Init 由 CameraManager 启动时调用一次       |
	| Enable/DisableCameraEvent*       | 仅客户端   | Init 之后方可注册；服务端返回 NOT_CLIENT    |
	| FocusPlayer / CameraShake*       | 仅客户端   | FocusPlayer 用于角色晚到补救               |
	| GetCamera / GetShakePresets      | 仅客户端   | 只读查询；勿直接改写相机 CFrame/FOV         |
	| SetShakeScale / GetShakeScale    | 仅客户端   | 全局震动强度 0~1                          |

	【每帧渲染管线】（RenderPriority.Camera + 1）
	1. 主事件：priority 最高，同 priority 后注册（更大 Seq）胜出；可设 Scriptable + FOV
	2. 震动：ShakeRuntime（主事件 opts.suppressShake=true 时跳过）
	3. 辅助事件：仅无主事件时累计 helperOffset / fovDelta（按 Seq 升序）
	4. 合成：baseCF * shakeOffset * helperOffset → CFrame / FOV
	5. 主事件栈从有→无：一帧切回开镜前轨道（Classic look*zoom，不做 CFrame tween）；
	   下一帧同步 PlayerModule/Zoom 后交还 Custom（交还后不再硬写 CFrame）

	无活跃主事件且无辅助事件且无 FOV 过渡时，不写入 FieldOfView。
	仅有辅助事件时，以 GameConfig 默认 FOV 为基准，叠加 helper 的 fovDelta。

	【API 选择】
	| 场景                                   | 推荐 API                                      |
	|----------------------------------------|-----------------------------------------------|
	| 技能/过场完全接管相机                   | EnableCameraEvent（高 priority）              |
	| 运镜大招（动态 FOV、禁止震动抢戏）        | EnableCameraEvent(..., opts.suppressShake)    |
	| 奔跑 FOV、呼吸晃动、轻微镜头偏移        | EnableCameraHelperEvent                       |
	| 受击/近距瞬时镜头抖动                   | CameraShakeOnce(EnumMgr.CameraShakeType.*)    |
	| 爆炸等世界坐标、需距离衰减               | CameraShakeAt(type, worldPos, maxDistance?)   |
	| 带冲击方向的瞬时 kick                   | CameraShakeImpulse(type, worldDir, factor?)   |
	| 载具/蓄力等持续震动                     | CameraShakeSustain(sourceId, type) / Stop     |
	| 打断某次 Once/At/Impulse/某源 Sustain   | CameraShakeCancel(handle [, fadeOutTime])     |
	| 过场结束恢复开镜前状态                 | DisableCameraEvent（快照归还 + FOV 短过渡）   |
	| 角色晚到补救 / 显式跟角色               | FocusPlayer                                   |
	| 关闭或压低震动                          | SetShakeScale / 设置「屏幕震动」0~100 滑条    |
	| 产品相机模式（OTS/LockOn/Aim/ShiftLock） | PushMode / PopMode / GetActiveMode            |

	【CameraMode】
	业务只 Push/Pop，勿直接抢 EnableCameraEvent 做日常跟拍。
	引擎用户 ShiftLock → 自动 Push Engine:MouseLock；Animate 朝向仍读 IsShiftLocked。
	示例：
	CameraModule.PushMode("Skill:Aim", CameraModule.Mode.Aim)
	CameraModule.PopMode("Skill:Aim")

	【主事件 EnableCameraEvent】
	@param eventName  string   全局唯一名称；重复注册返回 DUPLICATE_EVENT
	@param priority   number   越大优先级越高；同优先级后注册者胜出
	@param fov        number?  回调未返回 FOV 时的回退基准（默认读 GameConfig）
	@param func       function(eventTime, dt) -> (CFrame?, number?)
	  - 第一返回非 nil CFrame 时接管 Scriptable；nil 则本帧不改 CFrame
	  - 第二返回 number 时为本帧绝对 FOV；nil 则用注册时的 fov / 默认 FOV
	@param opts       { suppressShake: boolean? }?
	  - suppressShake=true：该主事件胜出期间不叠加震动偏移（运镜大招用）

	示例 — 固定视角过场：
	CameraModule.EnableCameraEvent("BossIntro", 100, 70, function(t, dt)
		return CFrame.lookAt(Vector3.new(0, 10, 20), Vector3.zero)
	end)
	-- 结束：Disable 归还到 Enable 前快照（Type/Subject/CFrame + FOV 过渡）
	CameraModule.DisableCameraEvent("BossIntro")

	示例 — 动态 FOV + 禁震运镜：
	CameraModule.EnableCameraEvent("SpaceSkillCam", 120, 70, function(t, dt)
		local cf = KeyframeEval.EvalCFrame(camKeys, t)
		local fov = KeyframeEval.EvalNumber(fovKeys, t)
		return cf, fov
	end, { suppressShake = true })

	【辅助事件】
	主事件生效期间 Helper 被 mute（不叠加 CFrame/FOV），避免过场漏进奔跑 FOV。
	推荐别名：EnableCameraHelperEvent / DisableCameraHelperEvent。

	【默认 FOV / 震动配置】
	GameConfig.CameraModule：
	  默认视野角度、过场FOV过渡秒、震动最大位移/转角、Trauma*、噪声*、
	  Impulse*、PlayAt*

	【FocusPlayer】
	将 CameraSubject 设回本地角色 Humanoid，CameraType 恢复 Custom（不读开镜快照）。
	角色未生成时返回 false, CHARACTER_NOT_READY。
	主事件栈空时模块会按开镜前快照归还；本 API 供补救与显式跟角色。

	【返回值与错误码】
	除 Init 外，变更类 API 均返回 (boolean, string?[, number?])。
	| 错误码               | 含义                           |
	|----------------------|--------------------------------|
	| NOT_INITIALIZED      | 尚未 Init                      |
	| NOT_CLIENT           | 服务端误调用                     |
	| DUPLICATE_EVENT      | eventName 已存在                 |
	| EVENT_NOT_FOUND      | Disable / Cancel 时找不到目标    |
	| INVALID_SHAKE_TYPE   | 震动类型不在 1-8                 |
	| INVALID_ARGUMENT     | 参数类型/取值非法                |
	| LAYER_FULL           | 震动层已满且均为 Sustain           |
	| CHARACTER_NOT_READY  | FocusPlayer 时无角色/Humanoid    |

	【生命周期】
	- Init()：幂等；订阅 CurrentCamera 与 Setting.Shake；不强制写默认 FOV
	- destroy()：解绑 RenderStep / 连接，清空事件与震动
]]

local ShakePresets = require(script.ShakePresets)
local ShakeRuntime = require(script.ShakeRuntime)
local CameraMode = require(script.CameraMode)
local CameraShiftLock = require(script.CameraShiftLock)
local CameraSettingShake = require(script.CameraSettingShake)
local CameraHandoff = require(script.CameraHandoff)
local CameraConfig = require(script.CameraConfig)
local CameraShakeApi = require(script.CameraShakeApi)
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local RunService = Utils.RunService
local Log = Utils.Log

local CameraModule = {}

export type ShakeTypeConfig = ShakePresets.ShakeTypeConfig
export type CameraPreMainSnapshot = CameraHandoff.CameraPreMainSnapshot
export type CameraPendingHandoff = CameraHandoff.CameraPendingHandoff

CameraModule.Mode = CameraMode.Mode
CameraModule.CameraModeAttribute = CameraMode.ATTRIBUTE_NAME
CameraModule.CameraModeEngineSource = CameraMode.ENGINE_SOURCE

-- ============================================================================
-- 错误码
-- ============================================================================

CameraModule.ERROR_CODE = table.freeze({
	DUPLICATE_EVENT = "DUPLICATE_EVENT",
	EVENT_NOT_FOUND = "EVENT_NOT_FOUND",
	NOT_INITIALIZED = "NOT_INITIALIZED",
	NOT_CLIENT = "NOT_CLIENT",
	INVALID_SHAKE_TYPE = "INVALID_SHAKE_TYPE",
	INVALID_ARGUMENT = "INVALID_ARGUMENT",
	LAYER_FULL = "LAYER_FULL",
	CHARACTER_NOT_READY = "CHARACTER_NOT_READY",
	SOURCE_NOT_FOUND = "SOURCE_NOT_FOUND",
})

-- ============================================================================
-- 常量
-- ============================================================================

local DEFAULT_FOV = CameraConfig.DEFAULT_FOV
local FOV_EXIT_BLEND_SEC = CameraConfig.FOV_EXIT_BLEND_SEC

local CAMERA_RENDER_STEP_NAME = "CameraModuleUpdate"
local CAMERA_RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 1

-- ============================================================================
-- 类型
-- ============================================================================

export type CameraEventOpts = {
	suppressShake: boolean?,
}

export type CameraEvent = {
	EventTime: number,
	EventName: string,
	EventPriority: number?,
	Fov: number?,
	Seq: number,
	SuppressShake: boolean?,
	Function: (time: number, dt: number?) -> (CFrame?, number?),
}

-- ============================================================================
-- 私有状态
-- ============================================================================

local _initialized = false
local _camera: Camera? = nil
local _cameraEvents: { [string]: CameraEvent } = {}
local _helperEvents: { [string]: CameraEvent } = {}
local _eventSeqCounter = 0
local _currentCameraConn: RBXScriptConnection? = nil

CameraHandoff.bind({
	getCamera = function()
		return _camera
	end,
	defaultFov = DEFAULT_FOV,
	fovExitBlendSec = FOV_EXIT_BLEND_SEC,
	errorCharacterNotReady = CameraModule.ERROR_CODE.CHARACTER_NOT_READY,
})

-- ============================================================================
-- 服务端空壳（避免误加载时绑定渲染步）
-- ============================================================================

if not RunService:IsClient() then
	function CameraModule.Init()
		return false, CameraModule.ERROR_CODE.NOT_CLIENT
	end

	function CameraModule.destroy()
	end

	function CameraModule.GetCamera()
		return nil
	end

	function CameraModule.GetShakePresets()
		return nil
	end

	function CameraModule.EnableCameraEvent()
		return false, CameraModule.ERROR_CODE.NOT_CLIENT
	end

	function CameraModule.DisableCameraEvent()
		return false, CameraModule.ERROR_CODE.NOT_CLIENT
	end

	function CameraModule.FocusPlayer()
		return false, CameraModule.ERROR_CODE.NOT_CLIENT
	end

	function CameraModule.EnableCameraEvent_Helper()
		return false, CameraModule.ERROR_CODE.NOT_CLIENT
	end

	function CameraModule.DisableCameraEvent_Helper()
		return false, CameraModule.ERROR_CODE.NOT_CLIENT
	end

	function CameraModule.EnableCameraHelperEvent()
		return false, CameraModule.ERROR_CODE.NOT_CLIENT
	end

	function CameraModule.DisableCameraHelperEvent()
		return false, CameraModule.ERROR_CODE.NOT_CLIENT
	end

	function CameraModule.CameraShakeOnce()
		return false, CameraModule.ERROR_CODE.NOT_CLIENT
	end

	function CameraModule.CameraShakeAt()
		return false, CameraModule.ERROR_CODE.NOT_CLIENT
	end

	function CameraModule.CameraShakeImpulse()
		return false, CameraModule.ERROR_CODE.NOT_CLIENT
	end

	function CameraModule.CameraShakeSustain()
		return false, CameraModule.ERROR_CODE.NOT_CLIENT
	end

	function CameraModule.CameraShakeStop()
		return false, CameraModule.ERROR_CODE.NOT_CLIENT
	end

	function CameraModule.CameraShakeCancel()
		return false, CameraModule.ERROR_CODE.NOT_CLIENT
	end

	function CameraModule.SetShakeScale()
		return false, CameraModule.ERROR_CODE.NOT_CLIENT
	end

	function CameraModule.GetShakeScale()
		return 0
	end

	function CameraModule.StopAllShakes()
		return false, CameraModule.ERROR_CODE.NOT_CLIENT
	end

	function CameraModule.PushMode()
		return false, CameraModule.ERROR_CODE.NOT_CLIENT
	end

	function CameraModule.PopMode()
		return false, CameraModule.ERROR_CODE.NOT_CLIENT
	end

	function CameraModule.GetActiveMode()
		return "Default"
	end

	return CameraModule
end

-- ============================================================================
-- 私有函数
-- ============================================================================

--[[
	校验模块是否已在客户端完成 Init
	@return boolean - 已 Init 且 CurrentCamera 可用时为 true
]]
local function _isReady(): boolean
	return _initialized and _camera ~= nil
end

--[[
	是否存在已注册的辅助表现事件
	@return boolean - 至少注册了一个 Helper 时为 true
]]
local function _hasHelperEvents(): boolean
	return next(_helperEvents) ~= nil
end

--[[
	刷新 CurrentCamera 引用并同步到 ShakeRuntime
	@return () - 无返回值
]]
local function _refreshCurrentCamera()
	_camera = workspace.CurrentCamera
	ShakeRuntime.SetCamera(_camera)
end

--[[
	订阅 workspace.CurrentCamera 变化
	@return () - 无返回值
]]
local function _bindCurrentCamera()
	if _currentCameraConn then
		_currentCameraConn:Disconnect()
		_currentCameraConn = nil
	end
	_refreshCurrentCamera()
	_currentCameraConn = workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(_refreshCurrentCamera)
end

--[[
	分配事件注册序号
	@return number - 单调递增的事件序号
]]
local function _nextEventSeq(): number
	_eventSeqCounter += 1
	return _eventSeqCounter
end

--[[
	查找当前帧优先级最高的主相机事件（同 priority 取更大 Seq）
	@param dt number - 帧间隔
	@return CameraEvent? - 本帧胜出的主事件；栈空为 nil
]]
local function _findHighestPriorityEvent(dt: number): CameraEvent?
	local maxPriority = -math.huge
	local bestSeq = -math.huge
	local topEvent: CameraEvent? = nil

	for _, event in pairs(_cameraEvents) do
		event.EventTime += dt
		local priority = event.EventPriority or 0
		local seq = event.Seq or 0
		if priority > maxPriority or (priority == maxPriority and seq > bestSeq) then
			topEvent = event
			maxPriority = priority
			bestSeq = seq
		end
	end

	return topEvent
end

--[[
	按 Seq 升序累计辅助表现偏移
	@param dt number - 帧间隔
	@return CFrame, number - 辅助 CFrame 偏移与 FOV 增量
]]
local function _accumulateHelperOffset(dt: number): (CFrame, number)
	local list: { CameraEvent } = {}
	for _, event in pairs(_helperEvents) do
		table.insert(list, event)
	end
	table.sort(list, function(a, b)
		return (a.Seq or 0) < (b.Seq or 0)
	end)

	local helperOffset = CFrame.new()
	local fovDelta = 0
	for _, event in ipairs(list) do
		event.EventTime += dt
		local cf, fovOffset = event.Function(event.EventTime, dt)
		if cf then
			helperOffset *= cf
		end
		if fovOffset then
			fovDelta += fovOffset
		end
	end
	return helperOffset, fovDelta
end

--[[
	无主事件时：交接钉帧 / 交还 Custom / 辅助偏移与 FOV 过渡
	@param dt number - 帧间隔
	@param camera Camera - 当前相机
	@param baseCF CFrame - 进入本段时的相机 CFrame
	@return CFrame - 本帧基准 CFrame
	@return number - 本帧 FOV
	@return boolean - 是否写入 FieldOfView
	@return boolean - 是否抑制震动
	@return CFrame - 辅助 CFrame 偏移
]]
local function _composeWithoutMainEvent(
	dt: number,
	camera: Camera,
	baseCF: CFrame
): (CFrame, number, boolean, boolean, CFrame)
	local outFov = DEFAULT_FOV
	local shouldSetFov = false
	local suppressShake = false
	local helperOffset = CFrame.new()

	if CameraHandoff.isScriptableOwnedByMain() and CameraHandoff.getPendingHandoff() == nil then
		CameraHandoff.onMainEventsBecameEmpty()
	end

	local pendingHandoff = CameraHandoff.getPendingHandoff()
	if pendingHandoff then
		suppressShake = true
		local handoff = pendingHandoff
		if not handoff.armed then
			handoff.armed = true
			camera.CameraType = Enum.CameraType.Scriptable
			local nailCF = CameraHandoff.resolveOrbitWorldCF(
				handoff.lookVector,
				handoff.distance,
				handoff.hasOrbit,
				handoff.fallbackCF,
				handoff.subject
			)
			baseCF = nailCF
			outFov = handoff.targetFov
			shouldSetFov = true
			local focus = CameraHandoff.getSubjectFocus(handoff.subject) or CameraHandoff.getSubjectFocus(camera.CameraSubject)
			if focus then
				camera.Focus = CFrame.new(focus)
			end
			CameraHandoff.trySyncPlayerModuleOrbit(handoff.distance, nailCF, focus)
		else
			local handoffCF, handoffFov = CameraHandoff.applyPendingHandoff(handoff)
			baseCF = handoffCF
			outFov = handoffFov
			shouldSetFov = true
		end
		return baseCF, outFov, shouldSetFov, suppressShake, helperOffset
	end

	local fovDelta = 0
	helperOffset, fovDelta = _accumulateHelperOffset(dt)
	local helperTargetFov = DEFAULT_FOV + fovDelta
	local blendTargetFov = if CameraHandoff.getFovExitTo() ~= nil then CameraHandoff.getFovExitTo() else helperTargetFov

	if CameraHandoff.hasFovExitBlend() then
		outFov = CameraHandoff.tickFovExitBlend(dt, blendTargetFov)
		shouldSetFov = true
	elseif _hasHelperEvents() then
		outFov = helperTargetFov
		shouldSetFov = true
	end
	return baseCF, outFov, shouldSetFov, suppressShake, helperOffset
end

--[[
	渲染步：主事件 → 震动 →（无主事件时）辅助偏移
	@param dt number - 帧间隔
	@return () - 无返回值
]]
local function _onRenderStep(dt: number)
	if not _camera then
		return
	end

	local shouldSetFov = false
	local outFov = DEFAULT_FOV
	local baseCF = _camera.CFrame
	local helperOffset = CFrame.new()

	local topEvent = _findHighestPriorityEvent(dt)
	local suppressShake = false
	if topEvent then
		CameraHandoff.clearPendingHandoff()
		CameraHandoff.cancelFovExitBlend()
		local cf, dynamicFov = topEvent.Function(topEvent.EventTime, dt)
		if cf then
			_camera.CameraType = Enum.CameraType.Scriptable
			baseCF = cf
			CameraHandoff.setScriptableOwnedByMain(true)
		end
		if typeof(dynamicFov) == "number" then
			outFov = dynamicFov
		else
			outFov = topEvent.Fov or DEFAULT_FOV
		end
		shouldSetFov = true
		suppressShake = topEvent.SuppressShake == true
	else
		baseCF, outFov, shouldSetFov, suppressShake, helperOffset = _composeWithoutMainEvent(dt, _camera, baseCF)
	end

	local shakeOffset = if suppressShake then CFrame.new() else ShakeRuntime.ComputeOffset(dt)
	_camera.CFrame = baseCF * shakeOffset * helperOffset
	if shouldSetFov then
		_camera.FieldOfView = outFov
	end
end

-- ============================================================================
-- 客户端实现
-- ============================================================================

--[[
	初始化相机模块，绑定渲染步（由 CameraManager 调用）
	@return boolean, string? - 是否成功 / 错误码
]]
function CameraModule.Init(): (boolean, string?)
	if _initialized then
		return true
	end

	ShakeRuntime.Reset()
	_bindCurrentCamera()
	CameraSettingShake.bind()
	CameraHandoff.reset()
	_eventSeqCounter = 0
	RunService:BindToRenderStep(CAMERA_RENDER_STEP_NAME, CAMERA_RENDER_PRIORITY, _onRenderStep)
	_initialized = true
	CameraMode.bind({
		enableHelper = function(eventName: string, func: (number, number?) -> (CFrame?, number?))
			return CameraModule.EnableCameraEvent_Helper(eventName, func)
		end,
		disableHelper = function(eventName: string)
			return CameraModule.DisableCameraEvent_Helper(eventName)
		end,
	})
	CameraShiftLock.bind()
	return true
end

--[[
	销毁相机模块，解绑渲染步并清空事件
	@return () - 无返回值
]]
function CameraModule.destroy()
	if not _initialized then
		return
	end

	CameraShiftLock.destroy()
	if _currentCameraConn then
		_currentCameraConn:Disconnect()
		_currentCameraConn = nil
	end
	CameraSettingShake.destroy()
	RunService:UnbindFromRenderStep(CAMERA_RENDER_STEP_NAME)
	CameraMode.destroy()
	table.clear(_cameraEvents)
	table.clear(_helperEvents)
	CameraHandoff.reset()
	ShakeRuntime.Reset()
	_initialized = false
end

--[[
	获取当前相机引用（只读访问，勿直接改写相机状态）
	@return Camera? - 当前 CurrentCamera；未 Init 或服务端为 nil。勿直接改写 CFrame/FOV
]]
function CameraModule.GetCamera(): Camera?
	return _camera
end

--[[
	获取震动类型配置表（只读）
	@return { [number]: ShakeTypeConfig } - 冻结预设表；调用方勿改写
]]
function CameraModule.GetShakePresets()
	return ShakePresets.GetAll()
end

-- ============================================================================
-- 公开 API — 主相机事件
-- ============================================================================

--[[
	启用相机事件控制（主事件）
	@param eventName string - 事件唯一名称
	@param priority number - 事件优先级（数字越大优先级越高；同级后注册胜出）
	@param fov number? - 回调未返回 FOV 时的回退视野角度
	@param func (number, number?) -> (CFrame?, number?) - 每帧变换；第二返回值为本帧绝对 FOV
	@param opts CameraEventOpts? - suppressShake 等；运镜大招建议 { suppressShake = true }
	@return boolean, string? - 是否成功 / 错误码
]]
function CameraModule.EnableCameraEvent(
	eventName: string,
	priority: number,
	fov: number?,
	func: (number, number?) -> (CFrame?, number?),
	opts: CameraEventOpts?
): (boolean, string?)
	if not _isReady() then
		return false, CameraModule.ERROR_CODE.NOT_INITIALIZED
	end
	if _cameraEvents[eventName] then
		return false, CameraModule.ERROR_CODE.DUPLICATE_EVENT
	end

	CameraHandoff.cancelFovExitBlend()
	if next(_cameraEvents) == nil then
		CameraHandoff.clearPendingHandoff()
		CameraHandoff.capturePreMainSnapshot()
	end
	_cameraEvents[eventName] = {
		Function = func,
		EventName = eventName,
		EventTime = 0,
		EventPriority = priority,
		Fov = fov,
		Seq = _nextEventSeq(),
		SuppressShake = if opts then opts.suppressShake == true else false,
	}
	return true
end

--[[
	禁用相机事件控制；若为主事件栈最后一项则按开镜前快照归还
	@param eventName string - 要禁用的事件名称
	@return boolean, string? - 是否成功 / 错误码
]]
function CameraModule.DisableCameraEvent(eventName: string): (boolean, string?)
	if not _isReady() then
		return false, CameraModule.ERROR_CODE.NOT_INITIALIZED
	end
	if not _cameraEvents[eventName] then
		return false, CameraModule.ERROR_CODE.EVENT_NOT_FOUND
	end

	_cameraEvents[eventName] = nil
	if next(_cameraEvents) == nil then
		CameraHandoff.onMainEventsBecameEmpty()
	end
	return true
end

--[[
	将相机视角聚焦到玩家身上，恢复跟随角色
	@return boolean, string? - 是否成功 / 错误码
]]
function CameraModule.FocusPlayer(): (boolean, string?)
	if not _isReady() then
		return false, CameraModule.ERROR_CODE.NOT_INITIALIZED
	end
	return CameraHandoff.restoreFollowCamera()
end

-- ============================================================================
-- 公开 API — 辅助表现事件
-- ============================================================================

--[[
	启用摄像机辅助表现事件，与主规则相机样式叠加（主事件期间 mute）
	@param eventName string - 事件唯一名称
	@param func function - 相机变换函数，返回 CFrame 偏移与 FOV 增量
	@return boolean, string? - 是否成功 / 错误码
]]
function CameraModule.EnableCameraEvent_Helper(
	eventName: string,
	func: (number, number?) -> (CFrame?, number?)
): (boolean, string?)
	if not _isReady() then
		return false, CameraModule.ERROR_CODE.NOT_INITIALIZED
	end
	if _helperEvents[eventName] then
		return false, CameraModule.ERROR_CODE.DUPLICATE_EVENT
	end

	_helperEvents[eventName] = {
		Function = func,
		EventName = eventName,
		EventTime = 0,
		Seq = _nextEventSeq(),
	}
	return true
end

--[[
	禁用摄像机辅助表现事件
	@param eventName string - 事件唯一名称
	@return boolean, string? - 是否成功 / 错误码
]]
function CameraModule.DisableCameraEvent_Helper(eventName: string): (boolean, string?)
	if not _isReady() then
		return false, CameraModule.ERROR_CODE.NOT_INITIALIZED
	end
	if not _helperEvents[eventName] then
		return false, CameraModule.ERROR_CODE.EVENT_NOT_FOUND
	end

	_helperEvents[eventName] = nil
	return true
end

-- 推荐别名，与 EnableCameraEvent_Helper / DisableCameraEvent_Helper 同一实现
CameraModule.EnableCameraHelperEvent = CameraModule.EnableCameraEvent_Helper
CameraModule.DisableCameraHelperEvent = CameraModule.DisableCameraEvent_Helper

-- ============================================================================
-- 公开 API — 相机震动（实现见 CameraShakeApi）
-- ============================================================================

CameraShakeApi.bind({
	isReady = _isReady,
	errorCode = CameraModule.ERROR_CODE,
	logWarn = Log.warn,
})
CameraModule.CameraShakeOnce = CameraShakeApi.CameraShakeOnce
CameraModule.CameraShakeAt = CameraShakeApi.CameraShakeAt
CameraModule.CameraShakeImpulse = CameraShakeApi.CameraShakeImpulse
CameraModule.CameraShakeSustain = CameraShakeApi.CameraShakeSustain
CameraModule.CameraShakeStop = CameraShakeApi.CameraShakeStop
CameraModule.CameraShakeCancel = CameraShakeApi.CameraShakeCancel
CameraModule.SetShakeScale = CameraShakeApi.SetShakeScale
CameraModule.GetShakeScale = CameraShakeApi.GetShakeScale
CameraModule.StopAllShakes = CameraShakeApi.StopAllShakes

--[[
	压入相机模式（OTS/LockOn/Aim/ShiftLock）；空栈为 Default
	@param sourceId string - 稳定来源 ID
	@param mode string - CameraModule.Mode.*
	@param priority number? - 缺省按模式默认优先级
	@return boolean, string? - 是否成功 / 错误码
]]
function CameraModule.PushMode(sourceId: string, mode: string, priority: number?): (boolean, string?)
	if not _initialized then
		return false, CameraModule.ERROR_CODE.NOT_INITIALIZED
	end
	return CameraMode.PushMode(sourceId, mode :: any, priority)
end

--[[
	弹出相机模式来源
	@param sourceId string - 与 PushMode 对应
	@return boolean, string? - 是否成功 / 错误码
]]
function CameraModule.PopMode(sourceId: string): (boolean, string?)
	if not _initialized then
		return false, CameraModule.ERROR_CODE.NOT_INITIALIZED
	end
	return CameraMode.PopMode(sourceId)
end

--[[
	当前优胜相机模式名（栈空为 Default）
	@return string - "Default" | "ShiftLock" | "OTS" | "LockOn" | "Aim"
]]
function CameraModule.GetActiveMode(): string
	return CameraMode.GetActiveMode()
end

return CameraModule
