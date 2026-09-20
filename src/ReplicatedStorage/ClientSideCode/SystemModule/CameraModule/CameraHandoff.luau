--[[
	Module: CameraModule.CameraHandoff
	Description: 开镜快照、轨道归还、FOV 退出过渡（由 CameraModule/init 调用，业务勿直接 require）
	Author: 林奥宇
	Created: 2026-08-18
	Last Modified: 2026-08-31

	功能：
	- 首个主事件启用前记录 Type/Subject/FOV/Classic look*zoom
	- 栈空：一帧切回开镜轨道，下一帧同步 Zoom 后交还 Custom
	- FOV 短过渡（过场FOV过渡秒）
	- FocusPlayer 回退：Custom + 本地 Humanoid（不读开镜快照）

	与 init：模块加载后 bind(deps)；Init/destroy 调 reset()。RenderStep 经本模块读写 pending / scriptableOwned。
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Players = Utils.Players
local Log = Utils.Log

local CameraHandoff = {}

export type CameraPreMainSnapshot = {
	cameraType: Enum.CameraType,
	cameraSubject: Instance?,
	fieldOfView: number,
	lookVector: Vector3,
	orbitDistance: number,
	hasOrbit: boolean,
	cframe: CFrame,
}

export type CameraPendingHandoff = {
	lookVector: Vector3,
	distance: number,
	hasOrbit: boolean,
	fallbackCF: CFrame,
	subject: Instance?,
	restoreCameraType: Enum.CameraType,
	targetFov: number,
	armed: boolean,
}

export type HandoffDeps = {
	getCamera: () -> Camera?,
	defaultFov: number,
	fovExitBlendSec: number,
	errorCharacterNotReady: string,
}

local SUBJECT_FOCUS_HEIGHT = 1.5
local MIN_ORBIT_DISTANCE = 0.5
local DEFAULT_ORBIT_DISTANCE = 12.5
local ORBIT_FOCUS_EPS = 1e-3
local PLAYER_CAM_CACHE_SEC = 2

local _getCamera: (() -> Camera?)? = nil
local DEFAULT_FOV = 60
local FOV_EXIT_BLEND_SEC = 0.15
local ERROR_CHARACTER_NOT_READY = "CHARACTER_NOT_READY"

local _scriptableOwnedByMain = false
local _fovExitRemaining: number? = nil
local _fovExitDuration: number? = nil
local _fovExitFrom: number? = nil
local _fovExitTo: number? = nil
local _preMainSnapshot: CameraPreMainSnapshot? = nil
local _pendingHandoff: CameraPendingHandoff? = nil
local _cachedPlayerCamController: any = nil
local _cachedPlayerCamControllerAt = 0
local _cachedZoomController: any = nil

--[[
	注入相机取值与配置常量（init 在客户端路径调用一次）
	@param deps HandoffDeps - getCamera / 默认 FOV / 过渡秒 / 角色未就绪错误码
	@return () - 无返回值
]]
function CameraHandoff.bind(deps: HandoffDeps)
	_getCamera = deps.getCamera
	DEFAULT_FOV = deps.defaultFov
	FOV_EXIT_BLEND_SEC = deps.fovExitBlendSec
	ERROR_CHARACTER_NOT_READY = deps.errorCharacterNotReady
end

--[[
	当前 CurrentCamera（bind 后）
	@return Camera? - bind 后的 CurrentCamera；未 bind 为 nil
]]
local function _cameraNow(): Camera?
	if _getCamera then
		return _getCamera()
	end
	return nil
end

--[[
	取消 FOV 退出过渡
	@return () - 无返回值
]]
function CameraHandoff.cancelFovExitBlend()
	_fovExitRemaining = nil
	_fovExitDuration = nil
	_fovExitFrom = nil
	_fovExitTo = nil
end

--[[
	清空快照 / 交接 / FOV 过渡 / Scriptable 占用（Init 与 destroy 共用）
	@return () - 无返回值
]]
function CameraHandoff.reset()
	_scriptableOwnedByMain = false
	_preMainSnapshot = nil
	_pendingHandoff = nil
	CameraHandoff.cancelFovExitBlend()
end

--[[
	主事件是否已接管 Scriptable
	@return boolean - 主事件已接管 Scriptable 时为 true
]]
function CameraHandoff.isScriptableOwnedByMain(): boolean
	return _scriptableOwnedByMain
end

--[[
	设置主事件 Scriptable 占用
	@param owned boolean - 是否由主事件占用
	@return () - 无返回值
]]
function CameraHandoff.setScriptableOwnedByMain(owned: boolean)
	_scriptableOwnedByMain = owned
end

--[[
	当前延迟交还状态
	@return CameraPendingHandoff? - 内部交接表；无交接为 nil（仅本模块与 init 合成器用）
]]
function CameraHandoff.getPendingHandoff(): CameraPendingHandoff?
	return _pendingHandoff
end

--[[
	清空延迟交还
	@return () - 无返回值
]]
function CameraHandoff.clearPendingHandoff()
	_pendingHandoff = nil
end

--[[
	FOV 退出目标（无过渡时 nil）
	@return number? - 过渡终点 FOV；无过渡为 nil
]]
function CameraHandoff.getFovExitTo(): number?
	return _fovExitTo
end

--[[
	FOV 退出过渡是否进行中
	@return boolean - 退出过渡进行中为 true
]]
function CameraHandoff.hasFovExitBlend(): boolean
	return _fovExitRemaining ~= nil and _fovExitDuration ~= nil and _fovExitFrom ~= nil
end

--[[
	推进 FOV 退出过渡一帧
	@param dt number - 帧间隔
	@param blendTargetFov number - 过渡终点 FOV
	@return number, boolean - 本帧 FOV；过渡是否仍在进行（刚结束为 false，已写入终点）
]]
function CameraHandoff.tickFovExitBlend(dt: number, blendTargetFov: number): (number, boolean)
	local remaining = _fovExitRemaining
	local duration = _fovExitDuration
	local fromFov = _fovExitFrom
	if remaining == nil or duration == nil or fromFov == nil then
		return blendTargetFov, false
	end
	remaining -= dt
	if remaining <= 0 then
		CameraHandoff.cancelFovExitBlend()
		return blendTargetFov, false
	end
	_fovExitRemaining = remaining
	local a = 1 - math.clamp(remaining / duration, 0, 1)
	local x = math.clamp(a, 0, 1)
	local smooth = x * x * (3 - 2 * x)
	return fromFov + (blendTargetFov - fromFov) * smooth, true
end

--[[
	取与 ClassicCamera GetSubjectPosition 接近的焦点。
	@param subject Instance? - CameraSubject；Humanoid / BasePart / Model
	@return Vector3? - 焦点世界坐标；无效 subject 为 nil
]]
function CameraHandoff.getSubjectFocus(subject: Instance?): Vector3?
	if subject == nil or subject.Parent == nil then
		return nil
	end
	if subject:IsA("Humanoid") then
		local humanoid = subject
		local root = humanoid.RootPart
		if not root then
			return nil
		end
		-- 对齐 BaseCamera.GetSubjectPosition：本地偏移转世界，避免姿态倾斜时焦点偏差
		local heightOffset = Vector3.new(0, SUBJECT_FOCUS_HEIGHT, 0)
		if humanoid.RigType == Enum.HumanoidRigType.R15 and humanoid.AutomaticScalingEnabled then
			heightOffset = heightOffset + Vector3.new(0, (root.Size.Y / 2) - 1, 0)
		end
		local localOffset = heightOffset + humanoid.CameraOffset
		return root.Position + root.CFrame:VectorToWorldSpace(localOffset)
	end
	if subject:IsA("BasePart") then
		return subject.Position
	end
	if subject:IsA("Model") then
		local pp = subject.PrimaryPart
		if pp then
			return pp.Position
		end
		return subject:GetPivot().Position
	end
	return nil
end

--[[
	提取 ClassicCamera 风格 look + zoom。
	@param camCF CFrame - 当前相机 CFrame
	@param focus Vector3 - 轨道焦点
	@return Vector3 - 开镜 look 方向（单位向量）
	@return number - 轨道距离；焦点重合时退回 MIN_ORBIT_DISTANCE
]]
local function _extractOrbit(camCF: CFrame, focus: Vector3): (Vector3, number)
	local toFocus = focus - camCF.Position
	local distance = toFocus.Magnitude
	if distance < ORBIT_FOCUS_EPS then
		return camCF.LookVector, MIN_ORBIT_DISTANCE
	end
	return toFocus.Unit, distance
end

--[[
	ClassicCamera 公式：lookAt(focus - look*zoom, focus)。
	@param focus Vector3 - 轨道焦点
	@param lookVector Vector3 - 开镜 look 方向
	@param distance number - 轨道距离
	@return CFrame - ClassicCamera 公式算出的世界 CFrame
]]
local function _buildOrbitCFrame(focus: Vector3, lookVector: Vector3, distance: number): CFrame
	local zoom = math.max(distance, MIN_ORBIT_DISTANCE)
	local look = lookVector.Unit
	-- 与 ClassicCamera 一致：CFrame.new(focus - zoom*look, focus)
	return CFrame.new(focus - look * zoom, focus)
end

--[[
	解析退出/硬锁目标世界 CFrame。
	@param lookVector Vector3 - 开镜 look 方向
	@param distance number - 轨道距离
	@param hasOrbit boolean - 快照是否含有效轨道
	@param fallbackCF CFrame - 无法重建轨道时的世界 CFrame
	@param subject Instance? - 用于取焦点的 CameraSubject
	@return CFrame - 目标世界 CFrame
	@return number - 同步给 Zoom 的距离（至少 MIN_ORBIT_DISTANCE）
]]
function CameraHandoff.resolveOrbitWorldCF(
	lookVector: Vector3,
	distance: number,
	hasOrbit: boolean,
	fallbackCF: CFrame,
	subject: Instance?
): (CFrame, number)
	local camera = _cameraNow()
	if hasOrbit then
		local focus = CameraHandoff.getSubjectFocus(subject) or CameraHandoff.getSubjectFocus(camera and camera.CameraSubject)
		if focus then
			return _buildOrbitCFrame(focus, lookVector, distance), math.max(distance, MIN_ORBIT_DISTANCE)
		end
	end
	return fallbackCF, math.max(distance, MIN_ORBIT_DISTANCE)
end

--[[
	释放 ZoomController 弹簧到当前 goal，避免交还 Custom 后距离再弹一下。
	@return () - 无返回值
]]
local function _tryReleaseZoomSpring()
	if _cachedZoomController == nil then
		local localPlayer = Players.LocalPlayer
		if not localPlayer then
			return
		end
		local playerScripts = localPlayer:FindFirstChild("PlayerScripts")
		local pmScript = playerScripts and playerScripts:FindFirstChild("PlayerModule")
		local camFolder = pmScript and pmScript:FindFirstChild("CameraModule")
		local zoomScript = camFolder and camFolder:FindFirstChild("ZoomController")
		if not zoomScript then
			return
		end
		-- PlayerModule 在 StarterPlayerScripts，ReplicatedFirst 加载期不可 require；仅交接时惰性缓存
		local okZoom, zoomMod = pcall(require, zoomScript)
		if okZoom and type(zoomMod) == "table" then
			_cachedZoomController = zoomMod
		elseif not okZoom then
			Log.warn("CameraHandoff: ZoomController require 失败", zoomMod)
		end
	end
	local zoomMod = _cachedZoomController
	if zoomMod and type(zoomMod.ReleaseSpring) == "function" then
		pcall(function()
			zoomMod.ReleaseSpring()
		end)
	end
end

--[[
	同步默认 PlayerModule 缩放/位姿，并抑制 Follow 自动回正。
	@param distance number - 要写入 PlayerModule 的缩放距离
	@param camCF CFrame - 当前世界 CFrame
	@param focus Vector3? - 焦点；nil 时不同步 lastCameraFocus
	@return () - 无返回值
]]
function CameraHandoff.trySyncPlayerModuleOrbit(distance: number, camCF: CFrame, focus: Vector3?)
	local now = os.clock()
	local controller = _cachedPlayerCamController
	if controller == nil or (now - _cachedPlayerCamControllerAt) > PLAYER_CAM_CACHE_SEC then
		local localPlayer = Players.LocalPlayer
		if not localPlayer then
			return
		end
		local playerScripts = localPlayer:FindFirstChild("PlayerScripts")
		if not playerScripts then
			return
		end
		local pmScript = playerScripts:FindFirstChild("PlayerModule")
		if not pmScript then
			return
		end
		-- 同上：PlayerModule 实例在玩家脚本树，不能放文件顶 require
		local okPm, playerModule = pcall(require, pmScript)
		if not okPm or not playerModule or type(playerModule.GetCameras) ~= "function" then
			if not okPm then
				Log.warn("CameraHandoff: PlayerModule require 失败", playerModule)
			end
			return
		end
		local okCams, cams = pcall(function()
			return playerModule:GetCameras()
		end)
		if not okCams or type(cams) ~= "table" then
			return
		end
		controller = (cams :: any).activeCameraController
		if controller == nil then
			controller = _cachedPlayerCamController
		end
		if controller == nil then
			return
		end
		_cachedPlayerCamController = controller
		_cachedPlayerCamControllerAt = now
	end
	pcall(function()
		local c = controller :: any
		if type(c.SetCameraToSubjectDistance) == "function" then
			c:SetCameraToSubjectDistance(distance)
		end
		if c.currentSubjectDistance ~= nil then
			c.currentSubjectDistance = distance
		end
		c.lastCameraTransform = camCF
		if focus then
			c.lastCameraFocus = CFrame.new(focus)
			c.lastSubjectPosition = focus
		end
		c.lastUserPanCamera = tick()
		c.lastUpdate = tick()
		c.resetCameraAngle = false
	end)
	_tryReleaseZoomSpring()
end

--[[
	开镜前快照：主事件首次接管 Scriptable 前记录 Type/Subject/FOV/轨道，供栈空归还
	@return () - 无返回值
]]
function CameraHandoff.capturePreMainSnapshot()
	local camera = _cameraNow()
	if not camera or _preMainSnapshot ~= nil then
		return
	end
	local subject = camera.CameraSubject
	local focus = CameraHandoff.getSubjectFocus(subject)
	local lookVector = camera.CFrame.LookVector
	local distance = DEFAULT_ORBIT_DISTANCE
	local hasOrbit = false
	if focus then
		lookVector, distance = _extractOrbit(camera.CFrame, focus)
		hasOrbit = true
	end
	_preMainSnapshot = {
		cameraType = camera.CameraType,
		cameraSubject = subject,
		fieldOfView = camera.FieldOfView,
		lookVector = lookVector,
		orbitDistance = math.max(distance, MIN_ORBIT_DISTANCE),
		hasOrbit = hasOrbit,
		cframe = camera.CFrame,
	}
	-- 开镜前仍是 Custom，此时缓存控制器；进入 Scriptable 后 active 会变 nil
	_cachedPlayerCamController = nil
	_cachedPlayerCamControllerAt = 0
	CameraHandoff.trySyncPlayerModuleOrbit(math.max(distance, MIN_ORBIT_DISTANCE), camera.CFrame, focus)
end

--[[
	开始 FOV 退出短过渡。
	@param fromFov number - 离开主事件时的 FOV
	@param toFov number? - 目标 FOV；nil 则用默认视野
	@return () - 无返回值
]]
local function _beginFovExitBlend(fromFov: number, toFov: number?)
	local camera = _cameraNow()
	local duration = math.max(0, FOV_EXIT_BLEND_SEC)
	local target = if type(toFov) == "number" then toFov else DEFAULT_FOV
	if duration <= 0 then
		CameraHandoff.cancelFovExitBlend()
		if camera then
			camera.FieldOfView = target
		end
		return
	end
	_fovExitFrom = fromFov
	_fovExitTo = target
	_fovExitDuration = duration
	_fovExitRemaining = duration
end

--[[
	将相机恢复为跟随本地角色（Custom + Humanoid Subject）
	@return boolean, string? - 是否成功 / 错误码
]]
function CameraHandoff.restoreFollowCamera(): (boolean, string?)
	local camera = _cameraNow()
	local localPlayer = Players.LocalPlayer
	if not localPlayer then
		return false, ERROR_CHARACTER_NOT_READY
	end
	local character = localPlayer.Character
	if not character then
		return false, ERROR_CHARACTER_NOT_READY
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or not camera then
		return false, ERROR_CHARACTER_NOT_READY
	end
	if camera.CameraSubject ~= humanoid then
		camera.CameraSubject = humanoid
	end
	camera.CameraType = Enum.CameraType.Custom
	_scriptableOwnedByMain = false
	return true
end

--[[
	按开镜快照一帧切回轨道（不做 CFrame tween），并登记下一帧交还 Custom。
	@param snap CameraPreMainSnapshot
	@return () - 无返回值
]]
local function _snapToPreMainThenHandoff(snap: CameraPreMainSnapshot)
	local camera = _cameraNow()
	if not camera then
		return
	end

	local subject = snap.cameraSubject
	if subject ~= nil and subject.Parent ~= nil then
		if camera.CameraSubject ~= subject then
			camera.CameraSubject = subject
		end
	else
		local localPlayer = Players.LocalPlayer
		local character = localPlayer and localPlayer.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid and camera.CameraSubject ~= humanoid then
			camera.CameraSubject = humanoid
		end
		subject = camera.CameraSubject
	end

	_pendingHandoff = nil
	CameraHandoff.cancelFovExitBlend()

	local finalCF, dist = CameraHandoff.resolveOrbitWorldCF(
		snap.lookVector,
		snap.orbitDistance,
		snap.hasOrbit,
		snap.cframe,
		subject
	)
	local focus = CameraHandoff.getSubjectFocus(subject) or CameraHandoff.getSubjectFocus(camera.CameraSubject)
	local targetFov = snap.fieldOfView
	local restoreType = snap.cameraType or Enum.CameraType.Custom

	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = finalCF
	if focus then
		camera.Focus = CFrame.new(focus)
	end
	camera.FieldOfView = targetFov
	CameraHandoff.trySyncPlayerModuleOrbit(dist, finalCF, focus)

	_pendingHandoff = {
		lookVector = snap.lookVector,
		distance = snap.orbitDistance,
		hasOrbit = snap.hasOrbit,
		fallbackCF = finalCF,
		subject = subject,
		restoreCameraType = restoreType,
		targetFov = targetFov,
		armed = false,
	}
	_scriptableOwnedByMain = false
end

--[[
	交还 Custom：钉开镜轨道并同步 Zoom 后切回，之后不再写 CFrame。
	@param handoff CameraPendingHandoff
	@return CFrame, number - 本帧应写入的 CFrame / FOV
]]
function CameraHandoff.applyPendingHandoff(handoff: CameraPendingHandoff): (CFrame, number)
	local camera = _cameraNow()
	local finalCF, dist = CameraHandoff.resolveOrbitWorldCF(
		handoff.lookVector,
		handoff.distance,
		handoff.hasOrbit,
		handoff.fallbackCF,
		handoff.subject
	)
	local focus = CameraHandoff.getSubjectFocus(handoff.subject) or CameraHandoff.getSubjectFocus(camera and camera.CameraSubject)
	if camera then
		camera.CameraType = Enum.CameraType.Scriptable
		camera.CFrame = finalCF
		if focus then
			camera.Focus = CFrame.new(focus)
		end
		camera.FieldOfView = handoff.targetFov
	end
	CameraHandoff.trySyncPlayerModuleOrbit(dist, finalCF, focus)
	if camera then
		camera.CameraType = handoff.restoreCameraType
	end
	_cachedPlayerCamController = nil
	_cachedPlayerCamControllerAt = 0
	CameraHandoff.trySyncPlayerModuleOrbit(dist, finalCF, focus)
	_pendingHandoff = nil
	_scriptableOwnedByMain = false
	return finalCF, handoff.targetFov
end

--[[
	按开镜前快照归还跟相机（无快照时回退 restoreFollowCamera）
	@return boolean - 是否已启动归还/交接
	@return string? - 失败时错误码；成功为 nil
]]
local function _restorePreMainCamera(): (boolean, string?)
	local snap = _preMainSnapshot
	local camera = _cameraNow()
	if not snap or not camera then
		return CameraHandoff.restoreFollowCamera()
	end
	_snapToPreMainThenHandoff(snap)
	return true
end

--[[
	主事件栈空时启动退出过渡（Scriptable 内完成，再交还跟相机）
	@return () - 无返回值
]]
function CameraHandoff.onMainEventsBecameEmpty()
	if _pendingHandoff ~= nil then
		return
	end
	if not _scriptableOwnedByMain and _preMainSnapshot == nil then
		return
	end
	local camera = _cameraNow()
	local fromFov = if camera then camera.FieldOfView else DEFAULT_FOV
	if _preMainSnapshot and camera then
		_restorePreMainCamera()
	else
		CameraHandoff.restoreFollowCamera()
		_beginFovExitBlend(fromFov, DEFAULT_FOV)
	end
	_preMainSnapshot = nil
end

return CameraHandoff
