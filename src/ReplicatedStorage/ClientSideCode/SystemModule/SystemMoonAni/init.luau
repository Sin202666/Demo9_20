--[[
	Module: SystemMoonAni
	Description: 客户端 Moon Animator 2 过场播放封装，统一调用 Moon2Cutscene 并管理生命周期
	Author: 林奥宇
	Created: 2026-08-24
	Last Modified: 2026-08-25

	功能：
	- 解析并播放 Moon Animator 2 导出过场（StringValue）
	- 可选 map / replace / waitForObjects / 帧任务 / FPS
	- 可选锁定本地角色 Control（CharacterControl.TransferControlOwner）
	- 单例会话管理：Play / Stop / Wait / IsPlaying / destroy
	- 透传库级能力：Subtitle / Fade / Vignette

	依赖：
	- Moon2Cutscene：ReplicatedStorage/MoonAnimator2Script/Moon2Cutscene
	- 过场文件：ReplicatedStorage/MoonAnimator2Saves；场景模板：Assets/MoonAni
	- 同目录：MoonAniFile / MoonAniCamera / MoonAniLighting / MoonAniSession

	与其它模块边界：
	- 相机轨由 Moon2Cutscene 驱动；结束后优先 CameraModule.FocusPlayer
	- 角色接管走 CharacterControl；不绑 Remote / 不直接写业务 UI
	- 特效 UI 经 Moon2Cutscene Effects 透传
	- 单会话：库固定 RenderStep「cutscene_play」，禁止并发
	- 无需 Init；首次 Play 时自动 require Moon2Cutscene

	【标准加载】
	local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
	local SystemMoonAni = Utils.SystemMoonAni

	【示例 — 按文件名播放】
	local ok, handleOrErr = SystemMoonAni.Play("Intro", {
		lockCharacter = true,
		replace = { [1] = Players.LocalPlayer.Character },
	})
	if ok then
		SystemMoonAni.Wait(handleOrErr)
	end

	【示例 — 克隆模型并镜头对齐】
	local ok, handle = SystemMoonAni.Play("Intro", {
		mapCFrame = CFrame.new(0, 5, 20),
	})

	【示例 — 直接传入导出实例】
	local fileInst = ReplicatedStorage.MoonAnimator2Saves:FindFirstChild("Intro")
	local ok, handle = SystemMoonAni.Play(fileInst, { mapCFrame = CFrame.new(0, 5, 20) })

	【示例 — 帧任务 + 字幕】
	local ok, handle = SystemMoonAni.Play("BossIntro", {
		tasks = {
			[60] = function()
				SystemMoonAni.Subtitle("开战！")
			end,
		},
	})
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MoonAniFile = require(script.MoonAniFile)
local MoonAniCamera = require(script.MoonAniCamera)
local MoonAniLighting = require(script.MoonAniLighting)
local MoonAniSession = require(script.MoonAniSession)

local SystemMoonAni = {}

-- ============================================================================
-- 错误码
-- ============================================================================

SystemMoonAni.ERROR_CODE = table.freeze({
	NOT_CLIENT = "NOT_CLIENT",
	MOON2CUTSCENE_MISSING = "MOON2CUTSCENE_MISSING",
	INVALID_ARGUMENT = "INVALID_ARGUMENT",
	FILE_NOT_FOUND = "FILE_NOT_FOUND",
	MAP_NOT_FOUND = "MAP_NOT_FOUND",
	HANDLE_NOT_FOUND = "HANDLE_NOT_FOUND",
	ALREADY_PLAYING = "ALREADY_PLAYING",
	CREATE_FAILED = "CREATE_FAILED",
})

-- ============================================================================
-- 类型
-- ============================================================================

export type PlayOptions = {
	map: Instance?,
	mapName: string?,
	mapCFrame: CFrame?,
	mapPosition: Vector3?,
	mapParent: Instance?,
	replace: { [number]: Instance }?,
	waitForObjects: boolean?,
	lockCharacter: boolean?,
	restart: boolean?,
	fps: number?,
	tasks: { [number]: (...any) -> () }?,
	onEnded: ((cutscene: any) -> ())?,
}

export type CutsceneHandle = MoonAniSession.CutsceneHandle

-- ============================================================================
-- 私有状态与常量
-- ============================================================================

local _moonLib: any? = nil
local MOON_MODULE_NAME = "Moon2Cutscene"
local MOON_SCRIPT_ROOT_NAME = "MoonAnimator2Script"
local DEFAULT_WAIT_FOR_OBJECTS = false
local DEFAULT_LOCK_CHARACTER = true
local WAIT_OBJECTS_TIMEOUT_SEC = 5

-- ============================================================================
-- 私有函数
-- ============================================================================

--[[
	模块内警告输出

	@param ... any - warn 参数
	@return nil
]]
local function _warn(...: any)
	warn("[SystemMoonAni]", ...)
end

--[[
	解析 Moon2Cutscene 模块实例

	@return ModuleScript? - 可 require 的模块
]]
local function _resolveMoonModule(): ModuleScript?
	local child = script:FindFirstChild(MOON_MODULE_NAME)
	if child and child:IsA("ModuleScript") then
		return child
	end
	local scriptRoot = ReplicatedStorage:FindFirstChild(MOON_SCRIPT_ROOT_NAME)
	if not scriptRoot then
		return nil
	end
	local moonInst = scriptRoot:FindFirstChild(MOON_MODULE_NAME)
	if not moonInst then
		return nil
	end
	if moonInst:IsA("ModuleScript") then
		return moonInst
	end
	local initChild = moonInst:FindFirstChild("init")
	if initChild and initChild:IsA("ModuleScript") then
		return initChild
	end
	return nil
end

--[[
	懒加载 Moon2Cutscene

	@return boolean - 是否可用
	@return string? - 失败错误码
]]
local function _ensureMoonLib(): (boolean, string?)
	if RunService:IsServer() then
		return false, SystemMoonAni.ERROR_CODE.NOT_CLIENT
	end
	if _moonLib then
		return true, nil
	end
	local moonModule = _resolveMoonModule()
	if not moonModule then
		_warn("找不到 Moon2Cutscene（ReplicatedStorage/MoonAnimator2Script/Moon2Cutscene）")
		return false, SystemMoonAni.ERROR_CODE.MOON2CUTSCENE_MISSING
	end
	local ok, libOrErr = pcall(require, moonModule)
	if not ok then
		_warn("require Moon2Cutscene 失败:", libOrErr)
		return false, SystemMoonAni.ERROR_CODE.MOON2CUTSCENE_MISSING
	end
	_moonLib = libOrErr
	return true, nil
end

--[[
	输出 FILE_NOT_FOUND 诊断并返回错误码

	@param fileHint string - 查找名提示
	@return string - FILE_NOT_FOUND
]]
local function _failFileNotFound(fileHint: string): string
	local root = MoonAniFile.getSaveRoot()
	if not root then
		_warn(string.format("FILE_NOT_FOUND: %s（缺少 ReplicatedStorage/MoonAnimator2Saves）", fileHint))
	else
		_warn(string.format(
			"FILE_NOT_FOUND: %s（已在 %s 查找；需 StringValue/Folder）",
			fileHint,
			root:GetFullName()
		))
	end
	return SystemMoonAni.ERROR_CODE.FILE_NOT_FOUND
end

--[[
	创建 cutscene、注册会话并拍摄 Lighting 快照

	@param moonLib any - Moon2Cutscene 库
	@param playFile Instance - 播放用文件
	@param sceneMap Instance? - map
	@param spawnedMap Instance? - 克隆 map
	@param playFileClone Instance? - 偏移克隆文件
	@param fileHint string - 句柄提示
	@return any? - cutscene
	@return CutsceneHandle? - 句柄
	@return MoonAniSession.Session? - 会话
	@return string? - 失败错误码
]]
local function _createSession(
	moonLib: any,
	playFile: Instance,
	sceneMap: Instance?,
	spawnedMap: Instance?,
	playFileClone: Instance?,
	fileHint: string
): (any?, CutsceneHandle?, MoonAniSession.Session?, string?)
	local createOk, cutsceneOrErr = pcall(function()
		return moonLib.new(playFile, sceneMap, true)
	end)
	if not createOk or cutsceneOrErr == nil then
		MoonAniFile.destroySpawnedMap(spawnedMap)
		if playFileClone then
			playFileClone:Destroy()
		end
		_warn("Moon2Cutscene.new 失败:", cutsceneOrErr)
		return nil, nil, nil, SystemMoonAni.ERROR_CODE.CREATE_FAILED
	end

	local cutscene = cutsceneOrErr
	local handle = MoonAniSession.nextHandle(fileHint)
	local session: MoonAniSession.Session = {
		handle = handle,
		cutscene = cutscene,
		spawnedMap = spawnedMap,
		playFileClone = playFileClone,
		lightingSnapshot = MoonAniLighting.captureLightingSnapshot(),
	}
	MoonAniSession.register(session)
	return cutscene, handle, session, nil
end

--[[
	向 cutscene 注册 opts.tasks

	@param cutscene any - 实例
	@param tasks { [number]: (...any) -> () }? - 帧任务
	@return nil
]]
local function _registerPlayTasks(cutscene: any, tasks: { [number]: (...any) -> () }?)
	if not tasks then
		return
	end
	for frame, fn in pairs(tasks) do
		if type(frame) == "number" and type(fn) == "function" then
			local taskOk, taskErr = pcall(function()
				if cutscene.createTask then
					cutscene:createTask(frame, fn)
				elseif cutscene.task and cutscene.task.register then
					cutscene.task:register(frame, fn)
				else
					error("Moon2Cutscene 无 createTask/task.register")
				end
			end)
			if not taskOk then
				_warn(string.format("tasks frame=%s 失败: %s", tostring(frame), tostring(taskErr)))
			end
		end
	end
end

--[[
	应用 opts.replace

	@param cutscene any - 实例
	@param replace { [number]: Instance }? - 替换表
	@return nil
]]
local function _applyPlayReplace(cutscene: any, replace: { [number]: Instance }?)
	if not replace then
		return
	end
	for index, instance in pairs(replace) do
		if type(index) == "number" and typeof(instance) == "Instance" then
			local replaceOk, replaceErr = pcall(function()
				if cutscene.replace then
					cutscene:replace(index, instance)
				elseif cutscene.setObject then
					cutscene:setObject(index, instance)
				end
			end)
			if not replaceOk then
				_warn(string.format("replace index=%s 失败: %s", tostring(index), tostring(replaceErr)))
			end
		end
	end
end

--[[
	可选等待场景物体就绪

	@param cutscene any - 实例
	@param shouldWait boolean - 是否等待
	@return nil
]]
local function _waitForPlayObjects(cutscene: any, shouldWait: boolean)
	if not shouldWait or not cutscene.canFindObjects then
		return
	end
	local canFind, missing = cutscene:canFindObjects()
	if canFind then
		return
	end
	local deadline = os.clock() + WAIT_OBJECTS_TIMEOUT_SEC
	while os.clock() < deadline do
		canFind, missing = cutscene:canFindObjects()
		if canFind then
			return
		end
		task.wait()
	end
	_warn("waitForObjects 超时，仍有物体找不到，继续播放:", missing)
end

--[[
	配置并启动已创建的 cutscene（tasks/replace/锁/结束回调/play）

	@param cutscene any - 实例
	@param handle CutsceneHandle - 句柄
	@param session MoonAniSession.Session - 会话
	@param fileInst Instance - 原始过场文件
	@param opts PlayOptions - 选项
	@return boolean - 是否成功 play
	@return string? - 失败错误码
]]
local function _configureAndPlay(
	cutscene: any,
	handle: CutsceneHandle,
	session: MoonAniSession.Session,
	fileInst: Instance,
	opts: PlayOptions
): (boolean, string?)
	if type(opts.fps) == "number" then
		cutscene.FPS = opts.fps
	end
	_registerPlayTasks(cutscene, opts.tasks)
	_applyPlayReplace(cutscene, opts.replace)

	local shouldWaitObjects = if opts.waitForObjects == nil then DEFAULT_WAIT_FOR_OBJECTS else opts.waitForObjects
	_waitForPlayObjects(cutscene, shouldWaitObjects == true)

	local shouldLock = if opts.lockCharacter == nil then DEFAULT_LOCK_CHARACTER else opts.lockCharacter
	MoonAniSession.tryLockCharacter(session, handle, shouldLock == true)

	local durationSec = MoonAniFile.estimateDurationSec(fileInst, opts.fps)
	MoonAniSession.bindAutoEnd(
		handle,
		session,
		cutscene,
		durationSec,
		if type(opts.onEnded) == "function" then opts.onEnded else nil
	)

	local playOk, playErr = pcall(function()
		cutscene:play(opts.restart)
	end)
	if not playOk then
		_warn("play 失败:", playErr)
		MoonAniSession.destroy(handle, true)
		return false, SystemMoonAni.ERROR_CODE.CREATE_FAILED
	end
	return true, nil
end

-- ============================================================================
-- 公共 API
-- ============================================================================

--[[
	播放过场（单会话；已有会话时返回 ALREADY_PLAYING）

	@param file Instance | string - StringValue/Folder 或 Saves 下名称
	@param opts PlayOptions? - 播放选项
	@return boolean - 是否成功
	@return CutsceneHandle | string - 句柄或错误码
]]
function SystemMoonAni.Play(file: Instance | string, opts: PlayOptions?): (boolean, CutsceneHandle | string)
	local fileHint = if type(file) == "string" then file elseif typeof(file) == "Instance" then (file :: Instance).Name else tostring(file)

	local ready, readyErr = _ensureMoonLib()
	if not ready then
		_warn("Play 中止:", readyErr)
		return false, readyErr :: string
	end

	opts = opts or {}
	if MoonAniSession.hasAny() then
		_warn("Play 中止: ALREADY_PLAYING")
		return false, SystemMoonAni.ERROR_CODE.ALREADY_PLAYING
	end

	local fileInst = MoonAniFile.resolveFile(file)
	if not fileInst then
		return false, _failFileNotFound(fileHint)
	end

	local sceneMap, spawnedMap, mapErr = MoonAniFile.prepareSceneMap(opts, fileInst, SystemMoonAni.ERROR_CODE)
	if mapErr then
		_warn("Play 中止:", mapErr)
		return false, mapErr
	end

	local playFile, playFileClone = MoonAniCamera.prepareAlignedPlayFile(fileInst, sceneMap)
	local cutscene, handle, session, createErr = _createSession(
		_moonLib :: any,
		playFile,
		sceneMap,
		spawnedMap,
		playFileClone,
		fileHint
	)
	if createErr or not cutscene or not handle or not session then
		return false, createErr or SystemMoonAni.ERROR_CODE.CREATE_FAILED
	end

	local playOk, playErr = _configureAndPlay(cutscene, handle, session, fileInst, opts)
	if not playOk then
		return false, playErr :: string
	end
	return true, handle
end

--[[
	从过场文件读取场景模型名

	@param file Instance | string - 文件或名称
	@return string? - mapName
]]
function SystemMoonAni.GetMapName(file: Instance | string): string?
	local fileInst = MoonAniFile.resolveFile(file)
	if not fileInst then
		return nil
	end
	return MoonAniFile.inferMapNameFromFile(fileInst)
end

--[[
	停止指定或全部过场

	@param handle CutsceneHandle? - 句柄；nil 停止全部
	@return boolean - 是否至少停止一个
	@return string? - 失败错误码
]]
function SystemMoonAni.Stop(handle: CutsceneHandle?): (boolean, string?)
	local ready, readyErr = _ensureMoonLib()
	if not ready then
		return false, readyErr
	end
	if handle == nil then
		local any = MoonAniSession.hasAny()
		MoonAniSession.destroyAll(false)
		return any, nil
	end
	if not MoonAniSession.get(handle) then
		return false, SystemMoonAni.ERROR_CODE.HANDLE_NOT_FOUND
	end
	MoonAniSession.destroy(handle, false)
	return true, nil
end

--[[
	等待指定或当前唯一过场结束（yield）

	@param handle CutsceneHandle? - 句柄；nil 时等待唯一会话
	@return boolean - 是否成功进入等待
	@return string? - 失败错误码
]]
function SystemMoonAni.Wait(handle: CutsceneHandle?): (boolean, string?)
	local ready, readyErr = _ensureMoonLib()
	if not ready then
		return false, readyErr
	end

	local target = handle
	if target == nil then
		local only, tooMany = MoonAniSession.findSoleHandle()
		if tooMany then
			return false, SystemMoonAni.ERROR_CODE.INVALID_ARGUMENT
		end
		target = only
	end
	if not target then
		return true, nil
	end

	local session = MoonAniSession.get(target)
	if not session then
		return true, nil
	end
	local cutscene = session.cutscene
	if cutscene and cutscene.wait then
		cutscene:wait()
	end
	return true, nil
end

--[[
	查询是否正在播放（以 cutscene:isPlaying 为准）

	@param handle CutsceneHandle? - 指定句柄；nil 表示任意
	@return boolean - 是否在播
]]
function SystemMoonAni.IsPlaying(handle: CutsceneHandle?): boolean
	return MoonAniSession.isPlaying(handle)
end

--[[
	为已创建会话注册帧任务

	@param handle CutsceneHandle - 句柄
	@param frame number - 触发帧
	@param fn (...any) -> () - 回调
	@return boolean - 是否成功
	@return string? - 失败错误码
]]
function SystemMoonAni.RegisterTask(handle: CutsceneHandle, frame: number, fn: (...any) -> ()): (boolean, string?)
	local session = MoonAniSession.get(handle)
	if not session then
		return false, SystemMoonAni.ERROR_CODE.HANDLE_NOT_FOUND
	end
	if type(frame) ~= "number" or type(fn) ~= "function" then
		return false, SystemMoonAni.ERROR_CODE.INVALID_ARGUMENT
	end
	local cutscene = session.cutscene
	local ok, err = pcall(function()
		if cutscene.createTask then
			cutscene:createTask(frame, fn)
		elseif cutscene.task and cutscene.task.register then
			cutscene.task:register(frame, fn)
		else
			error("Moon2Cutscene 无 createTask/task.register")
		end
	end)
	if not ok then
		_warn("RegisterTask 失败:", err)
		return false, SystemMoonAni.ERROR_CODE.INVALID_ARGUMENT
	end
	return true, nil
end

--[[
	替换会话中指定 index 的动画对象

	@param handle CutsceneHandle - 句柄
	@param index number - Items 索引
	@param instance Instance - 替换目标
	@return boolean - 是否成功
	@return string? - 失败错误码
]]
function SystemMoonAni.ReplaceObject(handle: CutsceneHandle, index: number, instance: Instance): (boolean, string?)
	local session = MoonAniSession.get(handle)
	if not session then
		return false, SystemMoonAni.ERROR_CODE.HANDLE_NOT_FOUND
	end
	if type(index) ~= "number" or typeof(instance) ~= "Instance" then
		return false, SystemMoonAni.ERROR_CODE.INVALID_ARGUMENT
	end
	local cutscene = session.cutscene
	local ok, err = pcall(function()
		if cutscene.replace then
			cutscene:replace(index, instance)
		elseif cutscene.setObject then
			cutscene:setObject(index, instance)
		else
			error("Moon2Cutscene 无 replace/setObject")
		end
	end)
	if not ok then
		_warn("ReplaceObject 失败:", err)
		return false, SystemMoonAni.ERROR_CODE.INVALID_ARGUMENT
	end
	return true, nil
end

--[[
	获取底层 Moon2Cutscene 库

	@return any? - 库表
]]
function SystemMoonAni.GetLibrary(): any?
	if not _moonLib then
		_ensureMoonLib()
	end
	return _moonLib
end

--[[
	显示/清除字幕

	@param text string - 字幕文本；空串清除
	@param properties { [string]: any }? - 字体等属性（如 Font / TextSize / TextColor3）
	@return nil
]]
function SystemMoonAni.Subtitle(text: string, properties: { [string]: any }?)
	local ready = _ensureMoonLib()
	if not ready or not _moonLib then
		return
	end
	if _moonLib.subtitle then
		_moonLib.subtitle(text, properties)
	end
end

--[[
	创建淡入淡出（透传 Moon2Cutscene.fade）

	@param fadeInTime number? - 淡入秒
	@param stayTime number? - 停留秒
	@param fadeOutTime number? - 淡出秒
	@param color Color3? - 颜色
	@return ((() -> ())?, ScreenGui?) - 启动函数与 ScreenGui
]]
function SystemMoonAni.Fade(fadeInTime: number?, stayTime: number?, fadeOutTime: number?, color: Color3?): any
	local ready = _ensureMoonLib()
	if not ready or not _moonLib then
		return nil
	end
	if _moonLib.fade then
		return _moonLib.fade(fadeInTime, stayTime, fadeOutTime, color)
	end
	if _moonLib.createFadeFunction then
		return _moonLib.createFadeFunction(fadeInTime, stayTime, fadeOutTime, color)
	end
	if _moonLib.Fade then
		return _moonLib.Fade(fadeInTime, stayTime, fadeOutTime, color)
	end
	return nil
end

--[[
	创建暗角（透传 Moon2Cutscene.vignette）

	@param image string? - 可选贴图
	@return ((() -> ())?, ScreenGui?, ImageLabel?) - 销毁函数与 UI
]]
function SystemMoonAni.Vignette(image: string?): any
	local ready = _ensureMoonLib()
	if not ready or not _moonLib then
		return nil
	end
	if _moonLib.vignette then
		return _moonLib.vignette(image)
	end
	if _moonLib.createVignette then
		return _moonLib.createVignette(image)
	end
	return nil
end

--[[
	销毁模块：停止全部会话并清空状态

	@return nil
]]
function SystemMoonAni.destroy()
	MoonAniSession.destroyAll(false)
	_moonLib = nil
end

return SystemMoonAni
