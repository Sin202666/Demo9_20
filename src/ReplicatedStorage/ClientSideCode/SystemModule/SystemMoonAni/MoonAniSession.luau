--[[
	Module: MoonAniSession
	Description: SystemMoonAni 会话管理：创建/销毁、自动结束、角色锁、相机归还
	Author: 林奥宇
	Created: 2026-08-25
	Last Modified: 2026-08-25

	功能：
	- 单例会话表与句柄分配
	- 结束回调 + isPlaying/时长兜底清理
	- CharacterControl 锁释放；相机 FocusPlayer / Custom 回退
	- 清理 spawnedMap / playFileClone / Lighting 快照

	仅由 SystemMoonAni/init 通过 require(script.MoonAniSession) 使用。
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local MoonAniFile = require(script.Parent.MoonAniFile)
local MoonAniLighting = require(script.Parent.MoonAniLighting)

local MoonAniSession = {}

export type CutsceneHandle = string

export type Session = {
	handle: CutsceneHandle,
	cutscene: any,
	spawnedMap: Instance?,
	playFileClone: Instance?,
	ownerId: string?,
	character: Model?,
	endedConnDisconnect: (() -> ())?,
	lightingSnapshot: MoonAniLighting.LightingSnapshot?,
}

local OWNER_PREFIX = "Cutscene:"
local END_HOLD_SEC = 0.25
local START_PLAYING_GRACE_SEC = 2
local DURATION_PAD_SEC = 1

local _sessions: { [CutsceneHandle]: Session } = {}
local _handleSeq = 0

-- Utils 延迟访问：避免经 Utils.__index 加载 SystemMoonAni 时在 metamethod 内 yield
local _utils: any = nil
local _characterControl: any = nil
local _cameraModule: any = nil

--[[
	模块内警告输出

	@param ... any - warn 参数
	@return nil
]]
local function _warn(...: any)
	warn("[SystemMoonAni]", ...)
end

--[[
	延迟获取 Utils

	@return any - UtilsSystem
]]
local function _getUtils(): any
	if not _utils then
		_utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
	end
	return _utils
end

--[[
	延迟获取 CharacterControl

	@return any? - CharacterControl 模块
]]
local function _getCharacterControl(): any?
	if not _characterControl then
		_characterControl = _getUtils().CharacterControl
	end
	return _characterControl
end

--[[
	延迟获取 CameraModule

	@return any? - CameraModule
]]
local function _getCameraModule(): any?
	if _cameraModule == nil then
		local ok, mod = pcall(function()
			return _getUtils().CameraModule
		end)
		_cameraModule = if ok then mod else false
	end
	return if _cameraModule then _cameraModule else nil
end

--[[
	生成唯一会话句柄

	@param fileHint string - 文件名提示
	@return CutsceneHandle - 会话句柄
]]
function MoonAniSession.nextHandle(fileHint: string): CutsceneHandle
	_handleSeq += 1
	return string.format("MoonAni:%s:%d", fileHint, _handleSeq)
end

--[[
	是否存在任意会话

	@return boolean - 有会话为 true
]]
function MoonAniSession.hasAny(): boolean
	return next(_sessions) ~= nil
end

--[[
	获取会话

	@param handle CutsceneHandle - 句柄
	@return Session? - 会话
]]
function MoonAniSession.get(handle: CutsceneHandle): Session?
	return _sessions[handle]
end

--[[
	枚举当前全部句柄（拷贝列表，便于边遍历边销毁）

	@return { CutsceneHandle } - 句柄列表
]]
function MoonAniSession.listHandles(): { CutsceneHandle }
	local handles = {}
	for h in pairs(_sessions) do
		table.insert(handles, h)
	end
	return handles
end

--[[
	若仅有一个会话则返回其句柄

	@return CutsceneHandle? - 唯一句柄；0 个或多个时 nil
	@return boolean - 是否因「多于一个」而失败
]]
function MoonAniSession.findSoleHandle(): (CutsceneHandle?, boolean)
	local only: CutsceneHandle? = nil
	for h in pairs(_sessions) do
		if only then
			return nil, true
		end
		only = h
	end
	return only, false
end

--[[
	过场结束后将相机恢复为跟随本地角色

	@return nil
]]
local function _restoreFollowCamera()
	local cameraModule = _getCameraModule()
	if cameraModule and type(cameraModule.FocusPlayer) == "function" then
		local ok, focusedOrErr = pcall(function()
			return cameraModule.FocusPlayer()
		end)
		if ok and focusedOrErr ~= false then
			return
		end
	end

	local camera = Workspace.CurrentCamera
	local localPlayer = Players.LocalPlayer
	local character = localPlayer and localPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not camera or not humanoid then
		return
	end
	camera.CameraSubject = humanoid
	camera.CameraType = Enum.CameraType.Custom
end

--[[
	释放角色 Transfer 锁（若曾锁定）

	@param session Session - 会话
	@return nil
]]
local function _releaseCharacterLock(session: Session)
	local ownerId = session.ownerId
	local character = session.character
	session.ownerId = nil
	session.character = nil
	if not ownerId or not character then
		return
	end
	local characterControl = _getCharacterControl()
	if not characterControl then
		return
	end
	local ctrl = characterControl.GetForCharacter(character)
	if ctrl then
		ctrl:ReleaseControlOwner(ownerId)
	end
end

--[[
	清理并移除会话（不调用 cutscene:destroy）

	@param handle CutsceneHandle - 会话句柄
	@return Session? - 被移除的会话
]]
local function _removeSession(handle: CutsceneHandle): Session?
	local session = _sessions[handle]
	if not session then
		return nil
	end
	_sessions[handle] = nil
	if session.endedConnDisconnect then
		session.endedConnDisconnect()
		session.endedConnDisconnect = nil
	end
	_releaseCharacterLock(session)
	_restoreFollowCamera()
	MoonAniFile.destroySpawnedMap(session.spawnedMap)
	if session.playFileClone then
		session.playFileClone:Destroy()
		session.playFileClone = nil
	end
	return session
end

--[[
	销毁底层 cutscene 并清理会话

	@param handle CutsceneHandle - 会话句柄
	@param shouldReset boolean - 是否在 destroy 前 reset
	@return nil
]]
function MoonAniSession.destroy(handle: CutsceneHandle, shouldReset: boolean)
	local session = _removeSession(handle)
	if not session then
		return
	end
	local cutscene = session.cutscene
	local lightingSnapshot = session.lightingSnapshot
	if cutscene then
		local ok, err = pcall(function()
			if shouldReset and cutscene.reset then
				cutscene:reset()
			end
			if cutscene.stop then
				cutscene:stop()
			end
			if cutscene.destroy then
				cutscene:destroy()
			end
		end)
		if not ok then
			_warn(string.format("destroy session 失败 handle=%s err=%s", handle, tostring(err)))
		end
	end
	MoonAniLighting.restoreLightingSnapshot(lightingSnapshot)
end

--[[
	销毁全部会话

	@param shouldReset boolean - 是否 reset
	@return nil
]]
function MoonAniSession.destroyAll(shouldReset: boolean)
	for _, h in ipairs(MoonAniSession.listHandles()) do
		MoonAniSession.destroy(h, shouldReset)
	end
end

--[[
	注册会话到表

	@param session Session - 会话
	@return nil
]]
function MoonAniSession.register(session: Session)
	_sessions[session.handle] = session
end

--[[
	可选锁定本地角色 Control

	@param session Session - 会话
	@param handle CutsceneHandle - 句柄
	@param shouldLock boolean - 是否锁定
	@return nil
]]
function MoonAniSession.tryLockCharacter(session: Session, handle: CutsceneHandle, shouldLock: boolean)
	if not shouldLock then
		return
	end
	local characterControl = _getCharacterControl()
	local localPlayer = Players.LocalPlayer
	local character = localPlayer and localPlayer.Character
	if not characterControl or not character then
		return
	end
	local ctrl = characterControl.GetForCharacter(character)
	if ctrl then
		local ownerId = OWNER_PREFIX .. handle
		ctrl:TransferControlOwner(ownerId)
		session.ownerId = ownerId
		session.character = character
	end
end

--[[
	结束兜底监视：未见播放 / 已停播保持 / 超时

	@param handle CutsceneHandle - 句柄
	@param session Session - 会话
	@param cutscene any - cutscene
	@param durationSec number - 预估时长
	@param finishedFlag { value: boolean } - 与 finishOnce 共享的结束标记
	@param finishOnce (string?) -> () - 结束触发器
	@return nil
]]
local function _spawnEndWatchdog(
	handle: CutsceneHandle,
	session: Session,
	cutscene: any,
	durationSec: number,
	finishedFlag: { value: boolean },
	finishOnce: (string?) -> ()
)
	task.spawn(function()
		local startAt = os.clock()
		local seenPlaying = false
		local stoppedSince: number? = nil
		local maxWaitSec = math.max(durationSec, 1) + DURATION_PAD_SEC

		while _sessions[handle] == session and not finishedFlag.value do
			task.wait()
			local playing = false
			pcall(function()
				playing = cutscene:isPlaying() == true
			end)
			if playing then
				seenPlaying = true
				stoppedSince = nil
			elseif seenPlaying then
				if stoppedSince == nil then
					stoppedSince = os.clock()
				elseif os.clock() - (stoppedSince :: number) >= END_HOLD_SEC then
					finishOnce(nil)
					return
				end
			elseif os.clock() - startAt > START_PLAYING_GRACE_SEC then
				finishOnce("未进入播放")
				return
			end
			if os.clock() - startAt >= maxWaitSec then
				pcall(function()
					if cutscene.stop then
						cutscene:stop()
					end
				end)
				finishOnce("超时")
				return
			end
		end
	end)
end

--[[
	绑定会话自动结束：优先 ended/onEnd，并按时长 + isPlaying 兜底

	@param handle CutsceneHandle - 会话句柄
	@param session Session - 会话
	@param cutscene any - Moon2Cutscene 实例
	@param durationSec number - 预估时长（秒）
	@param onEnded ((cutscene: any) -> ())? - 业务结束回调
	@return nil
]]
function MoonAniSession.bindAutoEnd(
	handle: CutsceneHandle,
	session: Session,
	cutscene: any,
	durationSec: number,
	onEnded: ((cutscene: any) -> ())?
)
	local finishedFlag = { value = false }

	local function finishOnce(_reason: string?)
		if finishedFlag.value then
			return
		end
		finishedFlag.value = true
		task.defer(function()
			if type(onEnded) == "function" then
				local ok, err = pcall(onEnded, cutscene)
				if not ok then
					_warn("onEnded 回调失败:", err)
				end
			end
			if _sessions[handle] then
				MoonAniSession.destroy(handle, false)
			elseif cutscene and cutscene.stop then
				pcall(function()
					cutscene:stop()
				end)
			end
		end)
	end

	local disconnect: (() -> ())? = nil
	if type(cutscene.ended) == "function" then
		disconnect = cutscene:ended(function()
			finishOnce(nil)
		end)
	elseif cutscene.task and type(cutscene.task.onEnd) == "function" then
		disconnect = cutscene.task:onEnd(function()
			finishOnce(nil)
		end)
	end
	if type(disconnect) == "function" then
		session.endedConnDisconnect = disconnect
	end

	_spawnEndWatchdog(handle, session, cutscene, durationSec, finishedFlag, finishOnce)
end

--[[
	判断 cutscene 是否仍在播放

	@param cutscene any? - Moon2Cutscene 实例
	@return boolean - 是否在播
]]
function MoonAniSession.cutsceneIsPlaying(cutscene: any?): boolean
	if not cutscene or type(cutscene.isPlaying) ~= "function" then
		return false
	end
	local ok, playing = pcall(function()
		return cutscene:isPlaying() == true
	end)
	return ok and playing == true
end

--[[
	是否有仍在播放的会话

	@param handle CutsceneHandle? - 指定句柄；nil 表示任意
	@return boolean - 是否在播
]]
function MoonAniSession.isPlaying(handle: CutsceneHandle?): boolean
	if handle then
		local session = _sessions[handle]
		if not session then
			return false
		end
		return MoonAniSession.cutsceneIsPlaying(session.cutscene)
	end
	for _, session in pairs(_sessions) do
		if MoonAniSession.cutsceneIsPlaying(session.cutscene) then
			return true
		end
	end
	return false
end

return MoonAniSession
