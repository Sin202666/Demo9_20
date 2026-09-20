--[[
	Module: Contract
	Description: SequenceManager 纯逻辑 + 轻量客户端集成契约自检
	Author: 林奥宇
	Created: 2026-07-31
	Last Modified: 2026-09-01

	覆盖：
	- PingPong / Forward / Reverse ResolveSeekPhase 与 DirectionForSeekFrame
	- 图集几何 ValidateSheetGeometry
	- 帧序号连续性 AreFrameIndicesContiguous
	- 客户端（有 LocalPlayer 时）：StopSequence(nil) 幂等；Sync onFrame 内 Stop → ABORTED 且无假成功 handle

	Studio / QA：
		local ok, failures = SequenceManager:RunContractSelfTest()
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local Log = Utils.Log
local RunService = Utils.RunService
local Players = Utils.Players

local Types = require(script.Parent.Types)
local PlaybackLifecycle = require(script.Parent.PlaybackLifecycle)
local Catalog = require(script.Parent.Catalog)
local PlaybackControl = require(script.Parent.PlaybackControl)
local Playback = require(script.Parent.Playback)

type PlaybackState = Types.PlaybackState
type SeekPhase = Types.SeekPhase

local Contract = {}

--[[
	构造最小假状态（仅相位相关字段）
	@param playMode Types.PlayModeValue - Forward / PingPong
	@param rangeStart number - 区间起点
	@param rangeEnd number - 区间终点
	@param frameStep number - 每帧秒数
	@param loop boolean - 是否循环
	@return Types.PlaybackState - 假状态
]]
local function _mockState(
	playMode: Types.PlayModeValue,
	rangeStart: number,
	rangeEnd: number,
	frameStep: number,
	loop: boolean
): PlaybackState
	return {
		id = 0,
		presentId = "0",
		sequenceName = "ContractMock",
		destroyConnection = nil,
		kind = Types.SequenceKind.Images,
		frames = {},
		sheet = nil,
		frameCount = rangeEnd,
		rangeStart = rangeStart,
		rangeEnd = rangeEnd,
		currentFrame = rangeStart,
		elapsed = 0,
		stopTime = 0,
		frameStep = frameStep,
		speed = 1,
		paused = false,
		loop = loop,
		loopInterval = 0,
		stopPolicy = Types.StopPolicy.HideClear,
		playMode = playMode,
		presentMode = Types.PresentMode.Swap,
		crossfadeSec = 0,
		layerTransparency = 0,
		crossfading = false,
		crossfadeElapsed = 0,
		activeIsA = true,
		bufferA = nil,
		bufferB = nil,
		clones = nil,
		nowShow = nil,
		direction = 1,
		forceVisible = true,
		callbackMode = Types.CallbackMode.Sync,
		playedTime = 0,
		savedImage = "",
		savedVisible = false,
		savedRectOffset = Vector2.zero,
		savedRectSize = Vector2.zero,
		savedTransparency = 0,
		savedImageColor = Color3.new(1, 1, 1),
		onComplete = nil,
		onLoop = nil,
		onFrame = nil,
		markers = nil,
	}
end

--[[
	断言相位
	@param label string - 用例名
	@param phase Types.SeekPhase - 实际
	@param frame number - 期望帧
	@param direction number - 期望方向
	@param failures { string } - 失败列表（写入）
]]
local function _expectPhase(
	label: string,
	phase: SeekPhase,
	frame: number,
	direction: number,
	failures: { string }
): ()
	if phase.frame ~= frame or phase.direction ~= direction then
		table.insert(
			failures,
			string.format(
				"%s: got frame=%s dir=%s, want frame=%s dir=%s",
				label,
				tostring(phase.frame),
				tostring(phase.direction),
				tostring(frame),
				tostring(direction)
			)
		)
	end
end

--[[
	客户端轻量集成（无资源目录依赖：用临构图集）
	@param failures { string } - 失败列表
]]
local function _runClientIntegration(failures: { string }): ()
	if not RunService:IsClient() then
		return
	end
	local localPlayer = Players.LocalPlayer
	if not localPlayer then
		return
	end

	local stopOk, stopErr = PlaybackControl.StopSequence(nil)
	if not stopOk or stopErr ~= nil then
		table.insert(failures, "StopSequence(nil) should return true, nil (no-op)")
	end

	local playerGui = localPlayer:FindFirstChild(Types.PLAYER_GUI_NAME)
	if not playerGui then
		return
	end

	local host = Instance.new("ScreenGui")
	host.Name = "SequenceContractTestGui"
	host.ResetOnSpawn = false
	host.Enabled = false
	host.Parent = playerGui

	local label = Instance.new("ImageLabel")
	label.Name = "ContractTarget"
	label.Size = UDim2.fromOffset(1, 1)
	label.BackgroundTransparency = 1
	label.Visible = false
	label.Parent = host

	local playOk, playErr, handle = Playback.PlaySequence(label, "ContractInlineSheet", {
		fps = 30,
		loop = false,
		forceVisible = false,
		stopPolicy = Types.StopPolicy.Keep,
		callbackMode = Types.CallbackMode.Sync,
		sheet = {
			imageId = "rbxassetid://0",
			cellWidth = 1,
			cellHeight = 1,
			columns = 1,
			frameCount = 1,
		},
		onFrame = function()
			Playback.StopSequence(label, Types.StopPolicy.Keep)
		end,
	})

	if playOk then
		table.insert(failures, "PlaySequence Sync-Stop should not report success without active playback")
	elseif playErr ~= Types.ErrorCode.ABORTED then
		table.insert(
			failures,
			string.format("PlaySequence Sync-Stop err want ABORTED got %s", tostring(playErr))
		)
	end
	if handle ~= nil then
		table.insert(failures, "PlaySequence Sync-Stop must not return a handle")
	end

	-- 正常播放成功必须带 handle
	local ok2, err2, handle2 = Playback.PlaySequence(label, "ContractInlineSheet", {
		fps = 12,
		loop = false,
		forceVisible = false,
		stopPolicy = Types.StopPolicy.Keep,
		sheet = {
			imageId = "rbxassetid://0",
			cellWidth = 1,
			cellHeight = 1,
			columns = 1,
			frameCount = 2,
		},
	})
	if not ok2 or handle2 == nil then
		table.insert(
			failures,
			string.format("PlaySequence success must include handle (ok=%s err=%s)", tostring(ok2), tostring(err2))
		)
	else
		Playback.StopHandle(handle2, Types.StopPolicy.Keep)
	end

	host:Destroy()
end

--[[
	纯逻辑契约：Seek 相位 / 图集几何 / 帧连续性 / ErrorCode
	@param failures { string } - 失败列表（写入）
]]
local function _runPureLogicTests(failures: { string }): ()
	-- PingPong 区间 1..4，frameStep=1（整数秒，避免 0.1 浮点取整误差）
	local ping = _mockState(Types.PlayMode.PingPong, 1, 4, 1, true)
	_expectPhase("pp t0", PlaybackLifecycle.ResolveSeekPhase(ping, 0), 1, 1, failures)
	_expectPhase("pp t1", PlaybackLifecycle.ResolveSeekPhase(ping, 1), 2, 1, failures)
	_expectPhase("pp t3", PlaybackLifecycle.ResolveSeekPhase(ping, 3), 4, -1, failures)
	_expectPhase("pp t4", PlaybackLifecycle.ResolveSeekPhase(ping, 4), 3, -1, failures)
	_expectPhase("pp t5", PlaybackLifecycle.ResolveSeekPhase(ping, 5), 2, -1, failures)
	_expectPhase("pp t6", PlaybackLifecycle.ResolveSeekPhase(ping, 6), 1, 1, failures)

	local fwd = _mockState(Types.PlayMode.Forward, 1, 3, 1, true)
	_expectPhase("fwd loop t3", PlaybackLifecycle.ResolveSeekPhase(fwd, 3), 1, 1, failures)

	local dirState = _mockState(Types.PlayMode.PingPong, 1, 5, 1, true)
	dirState.direction = 1
	if PlaybackLifecycle.DirectionForSeekFrame(dirState, 5) ~= -1 then
		table.insert(failures, "DirectionForSeekFrame end should be -1")
	end
	if PlaybackLifecycle.DirectionForSeekFrame(dirState, 1) ~= 1 then
		table.insert(failures, "DirectionForSeekFrame start should be 1")
	end
	dirState.direction = -1
	if PlaybackLifecycle.DirectionForSeekFrame(dirState, 3) ~= -1 then
		table.insert(failures, "DirectionForSeekFrame mid should keep direction")
	end

	local phase = PlaybackLifecycle.ResolveSeekPhase(ping, 4)
	if PlaybackLifecycle.FrameFromTime(ping, 4) ~= phase.frame then
		table.insert(failures, "FrameFromTime must match ResolveSeekPhase.frame")
	end

	local geoOk, geoMsg = Catalog.ValidateSheetGeometry(4, 8, 1)
	if geoOk then
		table.insert(failures, "ValidateSheetGeometry should fail when rows < needed")
	elseif not geoMsg then
		table.insert(failures, "ValidateSheetGeometry fail should include message")
	end
	geoOk = Catalog.ValidateSheetGeometry(4, 8, 2)
	if not geoOk then
		table.insert(failures, "ValidateSheetGeometry should pass when rows >= needed")
	end
	geoOk = Catalog.ValidateSheetGeometry(4, 8, nil)
	if not geoOk then
		table.insert(failures, "ValidateSheetGeometry should pass when rows omitted")
	end

	local rev = _mockState(Types.PlayMode.Reverse, 1, 4, 1, true)
	_expectPhase("rev t0", PlaybackLifecycle.ResolveSeekPhase(rev, 0), 4, -1, failures)
	_expectPhase("rev t1", PlaybackLifecycle.ResolveSeekPhase(rev, 1), 3, -1, failures)
	_expectPhase("rev t3", PlaybackLifecycle.ResolveSeekPhase(rev, 3), 1, -1, failures)
	_expectPhase("rev t4", PlaybackLifecycle.ResolveSeekPhase(rev, 4), 4, -1, failures)
	if PlaybackLifecycle.DirectionForSeekFrame(rev, 2) ~= -1 then
		table.insert(failures, "DirectionForSeekFrame Reverse should be -1")
	end

	-- 帧序号连续性（目录硬拒绝空洞的前置契约）
	if not Catalog.AreFrameIndicesContiguous({ 1, 2, 3 }) then
		table.insert(failures, "AreFrameIndicesContiguous 1,2,3 should pass")
	end
	if not Catalog.AreFrameIndicesContiguous({ 2, 3, 4 }) then
		table.insert(failures, "AreFrameIndicesContiguous 2,3,4 should pass")
	end
	if Catalog.AreFrameIndicesContiguous({ 1, 2, 4 }) then
		table.insert(failures, "AreFrameIndicesContiguous 1,2,4 should fail")
	end
	if Catalog.AreFrameIndicesContiguous({ 1, 3 }) then
		table.insert(failures, "AreFrameIndicesContiguous 1,3 should fail")
	end
	if Types.ErrorCode.FRAME_GAP ~= "FRAME_GAP"
		or Types.ErrorCode.ABORTED ~= "ABORTED"
		or Types.ErrorCode.EMPTY_SEQUENCE ~= "EMPTY_SEQUENCE"
	then
		table.insert(failures, "ErrorCode FRAME_GAP/ABORTED/EMPTY_SEQUENCE missing")
	end
end

--[[
	运行全部契约；失败不抛错；始终向 Output 打印摘要
	@return boolean - true 全部通过
	@return { string } - 失败说明列表（通过时为空表）
]]
function Contract.RunSelfTest(): (boolean, { string })
	local failures: { string } = {}
	_runPureLogicTests(failures)
	_runClientIntegration(failures)

	local passed = #failures == 0
	if passed then
		print("[SequenceManager] ContractSelfTest PASS")
		Log.print("[SequenceManager] ContractSelfTest PASS")
	else
		warn("[SequenceManager] ContractSelfTest FAIL count=", #failures)
		for _, msg in ipairs(failures) do
			warn("[SequenceManager]  ", msg)
		end
		Log.warn("[SequenceManager] ContractSelfTest FAIL", #failures, table.concat(failures, " | "))
	end

	return passed, failures
end

return Contract
