--[[
	Module: AnimateFov
	Description: 奔跑 sprint FOV + 技能冲刺脉冲（同一 Helper；进出 Gate / 取消脉冲连续交接，禁止硬切 0）。
	Author: 林奥宇
	Created: 2026-07-03
	Last Modified: 2026-08-31

	使用：
	local fovCtrl = AnimateFov.create({ ... })
	CameraImpulse.bind(character, {
		playFovPulse = fovCtrl.playDashImpulse,
		cancelFovPulse = fovCtrl.cancelDashImpulse,
		isFovPulseActive = fovCtrl.isDashActive,
	})
	角色销毁时 CameraImpulse.unbind(character)；fovCtrl.destroy()

	输出恒为 _speedFov + _dashFov（抑制时也如此）。
	抑制边沿：sprint 用 resumeSpeed 缓收，不瞬时清零。
	cancelDashImpulse：优先把 dash 残量 handoff 进 sprint，再按意图爬向 Max/Min；否则短 fade 收 dash。
	技能侧经 Utils.CameraImpulse.emit（勿再 require Animate 子模块注册平行 Helper）。
]]

local AnimateFov = {}

export type DashImpulseOpts = {
	addFov: number?,
	riseSec: number?,
	downSec: number?,
}

export type AnimateFovDeps = {
	character: Model,
	cameraModule: any,
	runService: RunService,
	tweenService: TweenService,
	setting: any,
	getPlayerRunSpeed: () -> number,
	getExpectedWalkSpeed: () -> number,
	getHasMoveIntent: () -> boolean,
	shouldSuppressSprintFov: (() -> boolean)?,
	shouldReleaseSprintFov: (() -> boolean)?,
}

export type AnimateFovController = {
	playDashImpulse: (opts: DashImpulseOpts?) -> (),
	cancelDashImpulse: () -> (),
	isDashActive: () -> boolean,
	destroy: () -> (),
}

local HELPER_NAME = "移速影响相机FOV"
local HELPER_RETRY_SEC = 0.5
local HELPER_RETRY_MAX = 10

--[[
	创建 FOV 控制器并注册 CameraModule Helper
	@param deps AnimateFovDeps - 相机模块与移速/意图查询
	@return AnimateFovController - playDashImpulse/cancelDashImpulse/isDashActive/destroy
]]
function AnimateFov.create(deps: AnimateFovDeps): AnimateFovController
	local cameraModule = deps.cameraModule
	local runService = deps.runService
	local tweenService = deps.tweenService
	local setting = deps.setting
	local fovCfg = setting.Fov or {}

	local runThreshold = setting.RUN_LOCOMOTION_WALKSPEED_THRESHOLD
	if type(runThreshold) ~= "number" or runThreshold ~= runThreshold then
		runThreshold = 16
	end

	local FOV_SPRINT_ENTER_SPEED = fovCfg.sprintEnterSpeed
	if type(FOV_SPRINT_ENTER_SPEED) ~= "number" or FOV_SPRINT_ENTER_SPEED ~= FOV_SPRINT_ENTER_SPEED then
		FOV_SPRINT_ENTER_SPEED = runThreshold
	end
	local FOV_SPRINT_EXIT_SPEED = fovCfg.sprintExitSpeed or 0.01
	local FOV_SPRINT_MIN_HOLD = fovCfg.sprintMinHold or 0.35
	local FOV_SPRINT_RESUME_DELAY = fovCfg.sprintResumeDelay or 0
	local MAX_CHANGE_FOV = fovCfg.maxChangeFov or 8
	local FOV_CHANGE_SPEED = fovCfg.changeSpeed or 30
	local FOV_RESUME_SPEED = fovCfg.resumeSpeed or 15

	local DASH_ADD = fovCfg.dashImpulseAddFov
	if type(DASH_ADD) ~= "number" or DASH_ADD ~= DASH_ADD then
		DASH_ADD = 6
	end
	local DASH_RISE = fovCfg.dashImpulseRiseSec
	if type(DASH_RISE) ~= "number" or DASH_RISE ~= DASH_RISE or DASH_RISE <= 0 then
		DASH_RISE = 0.5
	end
	local DASH_DOWN = fovCfg.dashImpulseDownSec
	if type(DASH_DOWN) ~= "number" or DASH_DOWN ~= DASH_DOWN or DASH_DOWN <= 0 then
		DASH_DOWN = 0.5
	end
	local DASH_CANCEL_FADE = fovCfg.dashCancelFadeSec
	if type(DASH_CANCEL_FADE) ~= "number" or DASH_CANCEL_FADE ~= DASH_CANCEL_FADE or DASH_CANCEL_FADE < 0 then
		DASH_CANCEL_FADE = 0.15
	end

	local _speedFov = 0
	local _dashFov = 0
	local _dashActive = false
	local _fovChangeConn: RBXScriptConnection? = nil
	local _dashConn: RBXScriptConnection? = nil
	local _nowFovState = "Min"
	local _fovSprintEnteredClock: number? = nil
	local _fovResumeAfterClock: number? = nil
	local _sprintFovSuppressed = false
	local _helperRegistered = false
	local _destroyed = false
	local _retryThread: thread? = nil

	--[[
		读取 ExpectedWalkSpeed；非法或缺失时返回 0
		@return number - 非负期望移速
	]]
	local function _readExpected(): number
		if not deps.getExpectedWalkSpeed then
			return 0
		end
		local e = deps.getExpectedWalkSpeed()
		if type(e) == "number" and e == e and e >= 0 then
			return e
		end
		return 0
	end

	--[[
		当前是否有移动意图（WASD / 摇杆）
		@return boolean - deps.getHasMoveIntent 为 true
	]]
	local function _hasMoveIntent(): boolean
		if deps.getHasMoveIntent then
			return deps.getHasMoveIntent() == true
		end
		return false
	end

	--[[
		当前可见 FOV 增量（sprint + dash，下限 0）
		@return number - 加到相机 FOV 的增量
	]]
	local function _visibleFov(): number
		return math.max(0, _speedFov + _dashFov)
	end

	--[[
		停止 sprint FOV 缓动连接
	]]
	local function _stopSprintTween()
		if _fovChangeConn then
			_fovChangeConn:Disconnect()
			_fovChangeConn = nil
		end
	end

	--[[
		停止 dash 脉冲缓动连接
	]]
	local function _stopDashTween()
		if _dashConn then
			_dashConn:Disconnect()
			_dashConn = nil
		end
	end

	--[[
		仅销毁用：硬清；运行时禁止走此路径做出入交接
	]]
	local function _hardZeroAll()
		_stopSprintTween()
		_stopDashTween()
		_speedFov = 0
		_dashFov = 0
		_dashActive = false
		_nowFovState = "Min"
		_fovSprintEnteredClock = nil
		_fovResumeAfterClock = nil
	end

	--[[
		将 _speedFov 从当前值缓动到 target（Sine Out）
		@param target number - 目标 sprint FOV
		@param speed number - 单位 FOV/秒
	]]
	local function _tweenSpeedFovTo(target: number, speed: number)
		_stopSprintTween()
		local startFov = _speedFov
		local span = target - startFov
		if math.abs(span) <= 1e-4 or speed <= 1e-4 then
			_speedFov = target
			return
		end
		local changeTime = math.abs(span) / speed
		local totalTime = 0
		_fovChangeConn = runService.Heartbeat:Connect(function(dt)
			totalTime += dt
			local percent = tweenService:GetValue(
				math.clamp(totalTime / changeTime, 0, 1),
				Enum.EasingStyle.Sine,
				Enum.EasingDirection.Out
			)
			_speedFov = startFov + percent * span
			if percent >= 1 then
				_speedFov = target
				_stopSprintTween()
			end
		end)
	end

	--[[
		将 sprint 通道缓动到满开 FOV
	]]
	local function _setSpeedFov()
		_tweenSpeedFovTo(MAX_CHANGE_FOV, FOV_CHANGE_SPEED)
	end

	--[[
		将 sprint 通道缓动回收到 0
	]]
	local function _resumeSpeedFov()
		_tweenSpeedFovTo(0, FOV_RESUME_SPEED)
	end

	--[[
		抑制边沿：sprint 缓收（不硬切）；输出仍含 sprint 残量 + dash
	]]
	local function _onSuppressEnter()
		_fovSprintEnteredClock = nil
		_fovResumeAfterClock = nil
		_nowFovState = "Min"
		if _speedFov > 1e-4 then
			_resumeSpeedFov()
		else
			_stopSprintTween()
		end
	end

	--[[
		解抑制：以当前可见 FOV 为 sprint 起点，再按意图爬向 Max/Min
	]]
	local function _onSuppressExit()
		local visible = _visibleFov()
		_stopDashTween()
		_dashFov = 0
		_dashActive = false
		_speedFov = visible
		_fovResumeAfterClock = nil

		local actual = deps.getPlayerRunSpeed()
		local expected = _readExpected()
		local moving = _hasMoveIntent()
		local effectiveEnter = if moving then math.max(actual, expected) else actual
		local releaseByLoco = deps.shouldReleaseSprintFov ~= nil and deps.shouldReleaseSprintFov() == true
		local wantSprint = effectiveEnter > FOV_SPRINT_ENTER_SPEED and not releaseByLoco and actual >= FOV_SPRINT_EXIT_SPEED

		if wantSprint then
			_nowFovState = "Max"
			_fovSprintEnteredClock = time()
			_setSpeedFov()
		else
			_nowFovState = "Min"
			_fovSprintEnteredClock = nil
			_resumeSpeedFov()
		end
	end

	--[[
		播放前冲脉冲：从当前可见增量起跳，避免先掉再涨
		@param opts DashImpulseOpts? - addFov/riseSec/downSec；nil 用 Setting.Fov 默认
]]
	local function playDashImpulse(opts: DashImpulseOpts?)
		if _destroyed then
			return
		end
		local o = opts or {}
		local addFov = if type(o.addFov) == "number" and o.addFov == o.addFov then o.addFov else DASH_ADD
		local riseSec = if type(o.riseSec) == "number" and o.riseSec == o.riseSec and o.riseSec > 0 then o.riseSec else DASH_RISE
		local downSec = if type(o.downSec) == "number" and o.downSec == o.downSec and o.downSec > 0 then o.downSec else DASH_DOWN
		if addFov <= 1e-4 then
			return
		end

		-- 把当前可见量收到 dash 通道，sprint 归零（连续，无输出空洞）
		local startDash = _visibleFov()
		_stopSprintTween()
		_stopDashTween()
		_speedFov = 0
		_nowFovState = "Min"
		_fovSprintEnteredClock = nil
		_fovResumeAfterClock = nil
		_dashFov = startDash
		_dashActive = true

		local peak = math.max(addFov, startDash)
		local totalTime = 0
		_dashConn = runService.Heartbeat:Connect(function(dt)
			if _destroyed then
				_stopDashTween()
				_dashFov = 0
				_dashActive = false
				return
			end
			totalTime += dt
			if totalTime <= riseSec then
				local percentRise = tweenService:GetValue(
					math.clamp(totalTime / riseSec, 0, 1),
					Enum.EasingStyle.Quad,
					Enum.EasingDirection.Out
				)
				_dashFov = startDash + (peak - startDash) * percentRise
			else
				local percentDown = tweenService:GetValue(
					math.clamp((totalTime - riseSec) / downSec, 0, 1),
					Enum.EasingStyle.Quad,
					Enum.EasingDirection.In
				)
				_dashFov = peak - peak * percentDown
				if percentDown >= 1 then
					_dashFov = 0
					_dashActive = false
					_stopDashTween()
				end
			end
		end)
	end

	--[[
		取消脉冲：残量并入 sprint 通道后按意图/抑制态缓动，禁止硬切 0
	]]
	local function cancelDashImpulse()
		if _destroyed then
			_hardZeroAll()
			return
		end
		local dashLeft = _dashFov
		_stopDashTween()
		_dashActive = false
		_speedFov = _speedFov + dashLeft
		_dashFov = 0

		local wantSuppress = deps.shouldSuppressSprintFov ~= nil and deps.shouldSuppressSprintFov() == true
		if wantSuppress or _sprintFovSuppressed then
			-- 仍在 Gate：合并后短收 sprint，输出连续；解抑制时再按意图爬升
			_nowFovState = "Min"
			_fovSprintEnteredClock = nil
			_fovResumeAfterClock = nil
			local fadeSpeed = FOV_RESUME_SPEED
			if DASH_CANCEL_FADE > 1e-4 and _speedFov > 1e-4 then
				fadeSpeed = _speedFov / DASH_CANCEL_FADE
			end
			_tweenSpeedFovTo(0, fadeSpeed)
			return
		end

		local actual = deps.getPlayerRunSpeed()
		local expected = _readExpected()
		local moving = _hasMoveIntent()
		local effectiveEnter = if moving then math.max(actual, expected) else actual
		local releaseByLoco = deps.shouldReleaseSprintFov ~= nil and deps.shouldReleaseSprintFov() == true
		local wantSprint = effectiveEnter > FOV_SPRINT_ENTER_SPEED and not releaseByLoco and actual >= FOV_SPRINT_EXIT_SPEED

		if wantSprint then
			_nowFovState = "Max"
			_fovSprintEnteredClock = time()
			_fovResumeAfterClock = nil
			_setSpeedFov()
		else
			_nowFovState = "Min"
			_fovSprintEnteredClock = nil
			_fovResumeAfterClock = nil
			_resumeSpeedFov()
		end
	end

	--[[
		CameraModule Helper：按移速/意图更新 sprint，并返回 (零位移, FOV 增量)
		@param _eventTime number - Helper 时钟（未使用）
		@param _dt number? - 帧间隔（未使用）
		@return CFrame - 恒为 identity（本 Helper 不改相机位姿）
		@return number - 可见 FOV 增量
	]]
	local function _onHelper(_eventTime: number, _dt: number?): (CFrame, number)
		local wantSuppress = deps.shouldSuppressSprintFov ~= nil and deps.shouldSuppressSprintFov() == true
		if wantSuppress then
			if not _sprintFovSuppressed then
				_sprintFovSuppressed = true
				_onSuppressEnter()
			end
			-- 抑制期间仍输出 sprint 残量 + dash，避免硬掉到仅 dash
			return CFrame.new(), _visibleFov()
		end
		if _sprintFovSuppressed then
			_sprintFovSuppressed = false
			_onSuppressExit()
			return CFrame.new(), _visibleFov()
		end

		local now = time()
		local actual = deps.getPlayerRunSpeed()
		local expected = _readExpected()
		local moving = _hasMoveIntent()
		local effectiveEnter = if moving then math.max(actual, expected) else actual

		if _nowFovState == "Max" then
			local releaseByLoco = deps.shouldReleaseSprintFov ~= nil and deps.shouldReleaseSprintFov() == true
			local wantExit = actual < FOV_SPRINT_EXIT_SPEED or releaseByLoco
			if not wantExit then
				_fovResumeAfterClock = nil
			else
				local enteredAt = _fovSprintEnteredClock or now
				if (now - enteredAt) >= FOV_SPRINT_MIN_HOLD and _fovResumeAfterClock == nil then
					_fovResumeAfterClock = now + FOV_SPRINT_RESUME_DELAY
				end
			end

			if _fovResumeAfterClock ~= nil and now >= _fovResumeAfterClock then
				_nowFovState = "Min"
				_resumeSpeedFov()
				_fovSprintEnteredClock = nil
				_fovResumeAfterClock = nil
			end
		elseif _nowFovState == "Min" then
			_fovResumeAfterClock = nil
			if effectiveEnter > FOV_SPRINT_ENTER_SPEED then
				_nowFovState = "Max"
				_setSpeedFov()
				_fovSprintEnteredClock = now
			end
		end

		return CFrame.new(), _visibleFov()
	end

	--[[
		向 CameraModule 注册「移速影响相机FOV」Helper；DUPLICATE 时先 Disable 再重试
		@return boolean - 是否已注册成功
	]]
	local function _tryRegisterHelper(): boolean
		if _helperRegistered or _destroyed then
			return _helperRegistered
		end
		pcall(function()
			cameraModule.DisableCameraEvent_Helper(HELPER_NAME)
		end)
		pcall(function()
			cameraModule.DisableCameraEvent_Helper("冲刺影响相机FOV")
		end)
		local ok, err = cameraModule.EnableCameraEvent_Helper(HELPER_NAME, _onHelper)
		if ok then
			_helperRegistered = true
			return true
		end
		if err == "DUPLICATE_EVENT" then
			cameraModule.DisableCameraEvent_Helper(HELPER_NAME)
			ok, err = cameraModule.EnableCameraEvent_Helper(HELPER_NAME, _onHelper)
			if ok then
				_helperRegistered = true
				return true
			end
		end
		return false
	end

	if not _tryRegisterHelper() then
		_retryThread = task.spawn(function()
			for _ = 1, HELPER_RETRY_MAX do
				if _destroyed or _helperRegistered then
					return
				end
				task.wait(HELPER_RETRY_SEC)
				if _tryRegisterHelper() then
					return
				end
			end
			if not _destroyed and not _helperRegistered then
				warn("AnimateFov: 注册移速影响相机FOV 失败（CameraModule 可能未 Init）")
			end
		end)
	end

	--[[
		销毁：停缓动、注销 Helper；重试协程靠 _destroyed 自退出
	]]
	local function destroy()
		_destroyed = true
		if _retryThread then
			pcall(task.cancel, _retryThread)
			_retryThread = nil
		end
		_hardZeroAll()
		if _helperRegistered then
			pcall(function()
				cameraModule.DisableCameraEvent_Helper(HELPER_NAME)
			end)
			_helperRegistered = false
		end
	end

	return {
		playDashImpulse = playDashImpulse,
		cancelDashImpulse = cancelDashImpulse,
		isDashActive = function()
			return _dashActive == true
		end,
		destroy = destroy,
	}
end

return AnimateFov
