--[[
	Module: AirLean
	Description: ShiftLock 腾空（Jump/Fall）时按相机相对 MoveYaw 对 R6 RootJoint 做程序躯干 lean。
	Author: 林奥宇
	Created: 2026-07-29
	Last Modified: 2026-08-31

	使用：
	local airLean = AirLean.create({
	  character, hrp, setting, getMoveYaw, getAirPose, isGroundMovePose,
	  isShiftLocked, isSuppressed,
	})
	RunService.Stepped:Connect(function(_, dt) airLean.apply(dt) end) -- 须在动画写关节之后
	Gate / 销毁：airLean.reset() / airLean.destroy()

	本项目体型为 R6：写 HumanoidRootPart.RootJoint.C0，不写 R15 Waist。
	不改 HRP 偏航与移速；与 StrafeBlend（地面 Cardinal）隔离。
	落地交接：侧移落地时 Land 窗内仍跟 MoveYaw 保持 lean，待 isGroundMovePose（Walk/Run）后再放掉，
	避免 StrafeBlend 接手前先回正。
	无 RootJoint 时 no-op（一次性 warn）。
]]

local AirLean = {}

export type AirLeanDeps = {
	character: Model,
	hrp: BasePart,
	setting: any,
	getMoveYaw: () -> (number, number),
	-- Jump / Fall 时返回对应字符串，否则 nil
	getAirPose: () -> string?,
	-- 地面走跑视觉已就绪（Walk/Run），可安全放 lean
	isGroundMovePose: () -> boolean,
	isShiftLocked: () -> boolean,
	-- Gate suppressLoco 或 pauseBaseTracks
	isSuppressed: () -> boolean,
}

export type AirLeanController = {
	apply: (dt: number) -> (),
	reset: () -> (),
	destroy: () -> (),
}

--[[
	查找 R6 RootJoint（HRP 或 Torso 上名为 RootJoint 的 Motor6D）
	@param character Model - 角色
	@param hrp BasePart - HumanoidRootPart
	@return Motor6D? - RootJoint；找不到时 nil
]]
local function _findRootJoint(character: Model, hrp: BasePart): Motor6D?
	local onHrp = hrp:FindFirstChild("RootJoint")
	if onHrp and onHrp:IsA("Motor6D") then
		return onHrp
	end
	local torso = character:FindFirstChild("Torso")
	if torso and torso:IsA("BasePart") then
		local onTorso = torso:FindFirstChild("RootJoint")
		if onTorso and onTorso:IsA("Motor6D") then
			return onTorso
		end
	end
	return nil
end

--[[
	创建空中 lean 控制器
	@param deps AirLeanDeps - 角色与查询回调
	@return AirLeanController - apply/reset/destroy
]]
function AirLean.create(deps: AirLeanDeps): AirLeanController
	local character = deps.character
	local hrp = deps.hrp
	local setting = deps.setting
	local cfg = (setting and setting.AirLean) or {}
	local enabled = cfg.ENABLE ~= false

	local maxRollDeg = if type(cfg.maxRollDegrees) == "number" then cfg.maxRollDegrees else 12
	local maxPitchDeg = if type(cfg.maxPitchDegrees) == "number" then cfg.maxPitchDegrees else 8
	local smoothRate = if type(cfg.smoothRate) == "number" then cfg.smoothRate else 10
	local zeroHold = if type(cfg.zeroInputHoldSec) == "number" then cfg.zeroInputHoldSec else 0.1
	local resetSmoothSec = if type(cfg.resetSmoothSec) == "number" then cfg.resetSmoothSec else 0.05
	local minMove = if type(cfg.minMoveMagnitude) == "number" then cfg.minMoveMagnitude else 0.01

	local _rootJoint: Motor6D? = nil
	local _baseC0: CFrame? = nil
	local _warnedMissing = false
	local _pitch = 0
	local _roll = 0
	local _heldPitch = 0
	local _heldRoll = 0
	local _zeroInputSince = 0
	local _destroyed = false
	local _wasDriving = false

	-- 尽早缓存 bind C0，避免首帧在已倾斜态采样
	do
		local joint = _findRootJoint(character, hrp)
		if joint then
			_rootJoint = joint
			_baseC0 = joint.C0
		end
	end

	--[[
		确保已缓存 RootJoint 与 bind C0
		@return boolean - 是否可用
	]]
	local function _ensureJoint(): boolean
		if _rootJoint and _rootJoint.Parent and _baseC0 then
			return true
		end
		local joint = _findRootJoint(character, hrp)
		if not joint then
			if not _warnedMissing then
				_warnedMissing = true
				warn("AirLean: 未找到 R6 RootJoint，空中 lean 禁用")
			end
			return false
		end
		_rootJoint = joint
		_baseC0 = joint.C0
		return true
	end

	--[[
		将当前 pitch/roll 写到 RootJoint.C0
	]]
	local function _writeC0()
		local joint = _rootJoint
		local base = _baseC0
		if not joint or not base or not joint.Parent then
			return
		end
		joint.C0 = base * CFrame.Angles(_pitch, 0, _roll)
	end

	--[[
		瞬时归零 lean（写回 baseC0）
	]]
	local function _resetInstant()
		_zeroInputSince = 0
		_heldPitch = 0
		_heldRoll = 0
		_wasDriving = false
		_pitch = 0
		_roll = 0
		if _rootJoint and _baseC0 and _rootJoint.Parent then
			_rootJoint.C0 = _baseC0
		end
	end

	--[[
		按 MoveYaw 平滑驱动 lean 目标并写 C0
		@param dt number - 帧间隔秒
		@param yawDeg number - 相机相对 MoveYaw（度）
		@param moveMag number - 水平 MoveDirection 模长
]]
	local function _driveLean(dt: number, yawDeg: number, moveMag: number)
		if not _ensureJoint() then
			return
		end

		local targetPitch = 0
		local targetRoll = 0

		if moveMag >= minMove then
			_zeroInputSince = 0
			local yawRad = math.rad(yawDeg)
			-- 右移正 yaw → 身体右倾（roll 负号按 R6 RootJoint 惯例，实机可调 max 符号）
			targetRoll = -math.sin(yawRad) * math.rad(maxRollDeg)
			targetPitch = math.cos(yawRad) * math.rad(maxPitchDeg)
			local speedScale = math.clamp(moveMag, 0, 1)
			targetPitch *= speedScale
			targetRoll *= speedScale
			_heldPitch = targetPitch
			_heldRoll = targetRoll
		else
			if _zeroInputSince <= 0 then
				_zeroInputSince = time()
			end
			if zeroHold > 0 and (time() - _zeroInputSince) < zeroHold then
				targetPitch = _heldPitch
				targetRoll = _heldRoll
			else
				targetPitch = 0
				targetRoll = 0
				_heldPitch = 0
				_heldRoll = 0
			end
		end

		local alpha = 1 - math.exp(-smoothRate * math.max(dt, 0))
		_pitch += (targetPitch - _pitch) * alpha
		_roll += (targetRoll - _roll) * alpha
		_writeC0()
		_wasDriving = true
	end

	--[[
		向 0 平滑或瞬时释放 lean
		@param dt number - 帧间隔秒
]]
	local function _releaseLean(dt: number)
		if math.abs(_pitch) <= 1e-5 and math.abs(_roll) <= 1e-5 then
			if _wasDriving then
				_resetInstant()
			end
			return
		end
		if resetSmoothSec <= 1e-4 then
			_resetInstant()
			return
		end
		local alpha = 1 - math.exp(-(1 / math.max(resetSmoothSec, 1e-4)) * math.max(dt, 0))
		_pitch += (0 - _pitch) * alpha
		_roll += (0 - _roll) * alpha
		if math.abs(_pitch) < 1e-4 and math.abs(_roll) < 1e-4 then
			_resetInstant()
		elseif _ensureJoint() then
			_writeC0()
		end
	end

	--[[
		每帧应用（Stepped，动画之后）
		@param dt number - 帧间隔
	]]
	local function apply(dt: number)
		if _destroyed or not enabled then
			return
		end
		if not character.Parent then
			return
		end

		local suppressed = deps.isSuppressed() == true
		local locked = deps.isShiftLocked() == true
		if suppressed or not locked then
			if _wasDriving or math.abs(_pitch) > 1e-5 or math.abs(_roll) > 1e-5 then
				_resetInstant()
			end
			return
		end

		local airPose = deps.getAirPose()
		local inAir = airPose == "Jump" or airPose == "Fall"
		local groundMove = deps.isGroundMovePose() == true
		local yawDeg, moveMag = deps.getMoveYaw()
		local hasIntent = moveMag >= minMove

		-- 腾空：正常 lean
		-- 落地未进 Walk/Run 且仍有意图（典型侧移落地 Land 窗）：保持 lean，等 Strafe/腿轨接手
		if inAir then
			_driveLean(dt, yawDeg, moveMag)
			return
		end

		if not groundMove and hasIntent and _wasDriving then
			_driveLean(dt, yawDeg, moveMag)
			return
		end

		-- 地面走跑已就绪，或无意图：放掉程序 lean，方向交给 StrafeBlend / 扇区轨
		_releaseLean(dt)
	end

	--[[
		销毁：瞬时归零并释放 RootJoint 引用
	]]
	local function destroy()
		_destroyed = true
		_resetInstant()
		_rootJoint = nil
		_baseC0 = nil
	end

	return {
		apply = apply,
		reset = _resetInstant,
		destroy = destroy,
	}
end

return AirLean