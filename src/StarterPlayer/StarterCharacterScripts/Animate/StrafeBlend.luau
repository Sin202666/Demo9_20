--[[
	Module: StrafeBlend
	Description: ShiftLock 下 Cardinal 双轨方向混合（连续 MoveYaw → 权重 → Animate.setStrafeBlend）。
	Author: 林奥宇
	Created: 2026-07-28
	Last Modified: 2026-08-31

	使用：
	local blend = StrafeBlend.create({ animate, setting, getMoveYaw, getCardinalWeights,
	  getRunAnimationSpeed, isShiftLocked, isLocoSuppressed, getGroundStable, getMoveSpeed })
	Heartbeat: blend.update(dt)
	Gate/离锁: blend.shutdown()
	角色销毁: blend.destroy()

	ENABLE=false 时本模块 no-op（由 GroundLocomotion 扇区硬切降级）。

	跳变抑制要点：
	- 平滑 yaw 再映射权重，避免前↔后对立向直接插值；大折角（≥135°）直接 snap
	- 换键瞬间 MoveDirection 归零时短 hold 并保持上一方向，勿 shutdown 恢复 Forward
	- 重新激活时按当前 yaw snap 权重，勿从 Forward=1 慢混过去
]]

local StrafeBlend = {}

export type StrafeBlendDeps = {
	animate: any,
	setting: any,
	getMoveYaw: () -> (number, number),
	getCardinalWeights: (yawDegrees: number) -> { Forward: number, Left: number, Right: number, Back: number },
	getRunAnimationSpeed: (walkspeed: number, posName: string) -> number,
	isShiftLocked: () -> boolean,
	isLocoSuppressed: () -> boolean,
	getGroundStable: () -> string,
	-- 须同时满足「稳定 Walk/Run + 无 Jump/Stop/衔接」；缺省时仅用 getGroundStable（不推荐）
	canStrafeBlend: (() -> boolean)?,
	getMoveSpeed: () -> number,
}


export type StrafeBlendController = {
	update: (dt: number) -> (),
	shutdown: () -> (),
	destroy: () -> (),
	isEnabled: () -> boolean,
}

--[[
	创建方向混合控制器
	@param deps StrafeBlendDeps - 动画与查询回调
	@return StrafeBlendController - update/shutdown/destroy/isEnabled
]]
function StrafeBlend.create(deps: StrafeBlendDeps): StrafeBlendController
	local cfg = (deps.setting and deps.setting.StrafeBlend) or {}
	local enabled = cfg.ENABLE ~= false
	local yawSmoothRate = (type(cfg.YAW_SMOOTH_RATE) == "number" and cfg.YAW_SMOOTH_RATE) or 12
	-- 兼容旧 WEIGHT_SMOOTH_RATE：作次级权重软化；<=0 表示关闭，完全跟 yaw
	local weightSmoothRate = (type(cfg.WEIGHT_SMOOTH_RATE) == "number" and cfg.WEIGHT_SMOOTH_RATE) or 0
	local minMove = (type(cfg.MIN_MOVE_MAGNITUDE) == "number" and cfg.MIN_MOVE_MAGNITUDE) or 0.01
	local zeroHold = (type(cfg.ZERO_INPUT_HOLD_SEC) == "number" and cfg.ZERO_INPUT_HOLD_SEC) or 0.1
	local markerMin = (type(cfg.MARKER_LEADER_WEIGHT) == "number" and cfg.MARKER_LEADER_WEIGHT) or 0.55
	local phaseSync = cfg.PHASE_SYNC ~= false
	local weightEps = (type(cfg.WEIGHT_EPSILON) == "number" and cfg.WEIGHT_EPSILON) or 0.02
	local trackFade = (type(cfg.TRACK_FADE) == "number" and cfg.TRACK_FADE) or 0.14
	local weightFade = (type(cfg.WEIGHT_FADE) == "number" and cfg.WEIGHT_FADE) or 0.1
	local debugPrintWeights = cfg.debugPrintWeights == true
	local debugInterval = 0.25

	local _smoothed = { Forward = 1, Left = 0, Right = 0, Back = 0 }
	local _smoothedYaw = 0
	local _hasSmoothedYaw = false
	local _zeroInputSince = 0
	local _active = false
	local _lastDebugPrintClock = 0

	--[[
		带符号最短路径角插值
		@param fromDeg number - 当前角度
		@param toDeg number - 目标角度
		@param alpha number - 0~1 插值系数
		@return number - 插值后角度（可超出 ±180，供连续积分）
]]
	local function _lerpAngleDeg(fromDeg: number, toDeg: number, alpha: number): number
		local diff = (toDeg - fromDeg + 180) % 360 - 180
		return fromDeg + diff * alpha
	end

	--[[
		将角度归一到 (-180, 180]
		@param yaw number - 任意度数
		@return number - 归一后角度；-180 映射为 180
]]
	local function _wrapYaw(yaw: number): number
		local y = yaw
		while y > 180 do
			y -= 360
		end
		while y <= -180 do
			y += 360
		end
		if y == -180 then
			y = 180
		end
		return y
	end

	--[[
		复制 cardinal 权重表
		@param src any - { Forward/Left/Right/Back: number }；缺键当 0
		@return { Forward: number, Left: number, Right: number, Back: number } - 新表，不共享引用
]]
	local function _copyWeights(src: any): any
		return {
			Forward = src.Forward or 0,
			Left = src.Left or 0,
			Right = src.Right or 0,
			Back = src.Back or 0,
		}
	end

	--[[
		向目标权重软化（可选；主平滑已在 yaw）
		@param target any - 目标 cardinal 权重表
		@param dt number - 帧间隔秒
]]
	local function _lerpWeights(target: any, dt: number)
		if weightSmoothRate <= 0 then
			_smoothed = _copyWeights(target)
			return
		end
		local alpha = 1 - math.exp(-weightSmoothRate * math.max(dt, 0))
		for _, key in ipairs({ "Forward", "Left", "Right", "Back" }) do
			local cur = _smoothed[key] or 0
			local dst = target[key] or 0
			_smoothed[key] = cur + (dst - cur) * alpha
		end
		local sum = _smoothed.Forward + _smoothed.Left + _smoothed.Right + _smoothed.Back
		if sum > 1e-4 then
			_smoothed.Forward /= sum
			_smoothed.Left /= sum
			_smoothed.Right /= sum
			_smoothed.Back /= sum
		end
	end

	--[[
		应用当前平滑权重到 Animate
		@param stable string - Walk | Run
		@param speedScale number - AdjustSpeed 倍率
]]
	local function _applyBlend(stable: string, speedScale: number)
		deps.animate:setStrafeBlend(stable, _smoothed, speedScale, {
			markerMinWeight = markerMin,
			phaseSync = phaseSync,
			weightEpsilon = weightEps,
			trackFade = trackFade,
			weightFade = weightFade,
		})
	end

	--[[
		结束方向混合
		@param restoreGait boolean? - 是否恢复前向单轨；缺省为 BasePos 仍是 Walk/Run 时恢复。
		  换键空隙超时停步须传 false，否则会先闪一下向前走。
	]]
	local function shutdown(restoreGait: boolean?)
		_active = false
		_hasSmoothedYaw = false
		_zeroInputSince = 0
		_smoothed = { Forward = 1, Left = 0, Right = 0, Back = 0 }
		local basePos = deps.animate.BasePos
		local canRestore = basePos == "Walk" or basePos == "Run"
		local doRestore = if restoreGait == nil then canRestore else (restoreGait and canRestore)
		deps.animate:clearStrafeBlend(trackFade, doRestore)
	end

	--[[
		是否允许本帧混合（优先 canStrafeBlend，避免 Jump/Stop* 期间仍叠方向轨）
		@return boolean - true 表示本帧允许方向混合
]]
	local function _allowed(): boolean
		if deps.isLocoSuppressed() or not deps.isShiftLocked() then
			return false
		end
		if deps.canStrafeBlend then
			return deps.canStrafeBlend()
		end
		local stable = deps.getGroundStable()
		return stable == "Walk" or stable == "Run"
	end

	--[[
		每帧更新方向混合
		@param dt number - 帧间隔
	]]
	local function update(dt: number)
		if not enabled then
			return
		end
		if not _allowed() then
			if _active then
				shutdown()
			end
			-- 勿在未激活时每帧 clear：会把正常 Walk/Run 单轨误停掉
			return
		end

		local stable = deps.getGroundStable()
		if stable ~= "Walk" and stable ~= "Run" then
			shutdown(false)
			return
		end

		local speed = deps.getMoveSpeed()
		local speedScale = deps.getRunAnimationSpeed(speed, stable)
		local yaw, moveMag = deps.getMoveYaw()

		-- 换键间隙：保持上一方向混合，切勿 shutdown 恢复 Forward（否则左→右会先闪前向）
		if moveMag < minMove then
			if _active then
				if _zeroInputSince <= 0 then
					_zeroInputSince = time()
				end
				if zeroHold > 0 and (time() - _zeroInputSince) < zeroHold then
					_applyBlend(stable, speedScale)
					return
				end
				-- 超时仍无输入：真停步，不恢复前向单轨
				shutdown(false)
			end
			return
		end
		_zeroInputSince = 0

		local yawAlpha = 1 - math.exp(-yawSmoothRate * math.max(dt, 0))
		if not _active or not _hasSmoothedYaw then
			-- 首次/重新激活：跟当前输入 snap，避免从 Forward=1 混向侧移造成闪一下
			_smoothedYaw = yaw
			_hasSmoothedYaw = true
			local snapTarget = deps.getCardinalWeights(_wrapYaw(yaw))
			_smoothed = _copyWeights(snapTarget)
		else
			-- 左↔右 / 前↔后 等大折角：最短弧≈180°，插值会短暂经过另一轴；直接 snap
			local shortest = (yaw - _smoothedYaw + 180) % 360 - 180
			if math.abs(shortest) >= 135 then
				_smoothedYaw = yaw
				_smoothed = _copyWeights(deps.getCardinalWeights(_wrapYaw(yaw)))
			else
				_smoothedYaw = _lerpAngleDeg(_smoothedYaw, yaw, yawAlpha)
				local target = deps.getCardinalWeights(_wrapYaw(_smoothedYaw))
				_lerpWeights(target, dt)
			end
		end

		_applyBlend(stable, speedScale)
		_active = true

		if debugPrintWeights then
			local now = time()
			if now - _lastDebugPrintClock >= debugInterval then
				_lastDebugPrintClock = now
				print(string.format(
					"[StrafeBlend] %s yaw=%.0f F=%.2f R=%.2f B=%.2f L=%.2f",
					stable,
					_wrapYaw(_smoothedYaw),
					_smoothed.Forward or 0,
					_smoothed.Right or 0,
					_smoothed.Back or 0,
					_smoothed.Left or 0
				))
			end
		end
	end

	--[[
		销毁：shutdown 并恢复前向单轨（角色移除时由入口调用）
	]]
	local function destroy()
		shutdown()
	end

	return {
		update = update,
		shutdown = shutdown,
		destroy = destroy,
		isEnabled = function()
			return enabled
		end,
	}
end

return StrafeBlend
