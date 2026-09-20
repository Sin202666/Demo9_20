--[[
	Module: AnimateMotionHelpers
	Description: 角色动画辅助计算（缩放、动作速度倍率、相对方向、MoveYaw、Cardinal 权重）。
	Author: 林奥宇
	Created: 2026-07-03
	Last Modified: 2026-08-31

	使用：
	local helpers = AnimateMotionHelpers.create({ ... })
	local yaw, mag = helpers.getMoveYaw()
	local weights = helpers.getCardinalWeights(yaw)
	-- getRelativeMoveDirection 仍可用于 StrafeBlend.ENABLE=false 的扇区硬切降级
]]

local AnimateMotionHelpers = {}

export type MotionHelpersDeps = {
	character: Model,
	hrp: BasePart,
	humanoid: Humanoid,
	setting: any,
	userAnimateScaleRun: boolean,
	-- 可选：覆盖相对方向判定的「前方」基准（ShiftLock 下应传相机水平 LookVector）
	getReferenceLookVector: (() -> Vector3)?,
}

export type MotionHelpers = {
	getRigScale: () -> number,
	getRunAnimationSpeed: (walkspeed: number, posName: string) -> number,
	getRelativeMoveDirection: () -> string,
	getMoveYaw: () -> (number, number),
	getCardinalWeights: (yawDegrees: number) -> { Forward: number, Left: number, Right: number, Back: number },
}


--[[
	创建动作辅助计算器
	@param deps MotionHelpersDeps - 角色引用与配置
	@return MotionHelpers - getRigScale/getRunAnimationSpeed/getRelativeMoveDirection/getMoveYaw/getCardinalWeights
]]
function AnimateMotionHelpers.create(deps: MotionHelpersDeps): MotionHelpers
	local character = deps.character
	local hrp = deps.hrp
	local humanoid = deps.humanoid
	local setting = deps.setting
	local userAnimateScaleRun = deps.userAnimateScaleRun
	local getReferenceLookVector = deps.getReferenceLookVector

	local _lastMoveDirection = "Forward"
	local _lastMoveYaw = 0
	local DIR_HYSTERESIS = setting.DIR_HYSTERESIS or 10
	local MOVE_MAG_EPS = setting.MOVE_INTENT_FOR_LOCO or 0.01
	local FWD_THRESH = 30
	local BACK_THRESH = 150

	--[[
		获取角色缩放比例
		@return number - 启用 UserAnimateScaleRun 时返回 Character:GetScale()，否则 1
	]]
	local function getRigScale(): number
		if userAnimateScaleRun then
			return character:GetScale()
		end
		return 1
	end

	--[[
		根据 WalkSpeed 计算 Walk/Run/Climb 动作播放倍率
		@param walkspeed number - Humanoid 当前移动速度
		@param posName string - "Walk" | "Run" | "Climb"
		@return number - AdjustSpeed 倍率
	]]
	local function getRunAnimationSpeed(walkspeed: number, posName: string): number
		local animationSpeed = 1
		local scale = getRigScale()
		if posName == "Walk" then
			animationSpeed = walkspeed / setting.WALK_ACTION_SCALE_SPEED / scale
		elseif posName == "Run" then
			animationSpeed = walkspeed / setting.RUN_ACTION_SCALE_SPEED / scale
		elseif posName == "Climb" then
			animationSpeed = walkspeed / setting.CLIMB_ACTION_SCALE_SPEED / scale
		end
		return animationSpeed
	end

	--[[
		取水平「前方」基准：优先外部回调（相机），否则角色 LookVector
		@return Vector3 - 水平单位向量；无效时返回零向量
	]]
	local function _getFlatLookBasis(): Vector3
		local lookVector: Vector3
		if getReferenceLookVector then
			lookVector = getReferenceLookVector()
		else
			lookVector = hrp:GetPivot().LookVector
		end
		local lookDir2D = Vector3.new(lookVector.X, 0, lookVector.Z)
		if lookDir2D.Magnitude < 1e-3 then
			return Vector3.zero
		end
		return lookDir2D.Unit
	end

	--[[
		夹角 + 迟滞算法，判断相对「前方基准」的移动方向
		ShiftLock 下前方基准应为相机，避免角色被 AutoRotate 转身后把后退判成前进。
		注意：必须先判 Back（大夹角），再判 Left/Right；否则 ±180° 的 S 键会被
		`angle >= 40 → Right` 抢先命中，永远进不了后走。
		@return string - "Forward" | "Left" | "Right" | "Back"
	]]
	local function getRelativeMoveDirection(): string
		local moveDirection = humanoid.MoveDirection
		local moveDir2D = Vector3.new(moveDirection.X, 0, moveDirection.Z)
		if moveDir2D.Magnitude < MOVE_MAG_EPS then
			return _lastMoveDirection
		end

		local lookDir2DNormalized = _getFlatLookBasis()
		if lookDir2DNormalized.Magnitude < 1e-3 then
			return _lastMoveDirection
		end

		local moveDir2DNormalized = moveDir2D.Unit
		local dot = math.clamp(moveDir2DNormalized:Dot(lookDir2DNormalized), -1, 1)
		local angle = math.acos(dot)
		local cross = moveDir2DNormalized:Cross(lookDir2DNormalized)
		local angleDegrees = math.deg(angle)
		if cross.Y < 0 then
			angleDegrees = -angleDegrees
		end

		local H = DIR_HYSTERESIS
		local direction = _lastMoveDirection
		local absAngle = math.abs(angleDegrees)

		if _lastMoveDirection == "Forward" then
			-- 先 Back：纯 S（~180°）不得被 Left/Right 的 ±40° 阈值吞掉
			if absAngle >= BACK_THRESH - H then
				direction = "Back"
			elseif angleDegrees >= FWD_THRESH + H then
				direction = "Right"
			elseif angleDegrees <= -(FWD_THRESH + H) then
				direction = "Left"
			end
		elseif _lastMoveDirection == "Right" then
			if absAngle >= BACK_THRESH - H then
				direction = "Back"
			elseif angleDegrees < FWD_THRESH - H then
				direction = "Forward"
			elseif angleDegrees <= -(FWD_THRESH + H) then
				direction = "Left"
			end
		elseif _lastMoveDirection == "Left" then
			if absAngle >= BACK_THRESH - H then
				direction = "Back"
			elseif angleDegrees > -(FWD_THRESH - H) then
				direction = "Forward"
			elseif angleDegrees >= FWD_THRESH + H then
				direction = "Right"
			end
		elseif _lastMoveDirection == "Back" then
			if absAngle <= FWD_THRESH + H then
				direction = "Forward"
			elseif absAngle < BACK_THRESH - H then
				if angleDegrees > 0 then
					direction = "Right"
				else
					direction = "Left"
				end
			end
		end

		_lastMoveDirection = direction
		return direction
	end

	--[[
		相对前方基准的带符号移动角（度）与水平移动模长。
		0=前，正=右，负=左，±180=后；无输入时返回上一帧 yaw 与 mag=0。
		@return number - moveYaw 度
		@return number - 水平 MoveDirection 模长
	]]
	local function getMoveYaw(): (number, number)
		local moveDirection = humanoid.MoveDirection
		local moveDir2D = Vector3.new(moveDirection.X, 0, moveDirection.Z)
		local mag = moveDir2D.Magnitude
		if mag < MOVE_MAG_EPS then
			return _lastMoveYaw, 0
		end

		local lookDir2DNormalized = _getFlatLookBasis()
		if lookDir2DNormalized.Magnitude < 1e-3 then
			return _lastMoveYaw, mag
		end

		local moveDir2DNormalized = moveDir2D.Unit
		local dot = math.clamp(moveDir2DNormalized:Dot(lookDir2DNormalized), -1, 1)
		local angleDegrees = math.deg(math.acos(dot))
		local cross = moveDir2DNormalized:Cross(lookDir2DNormalized)
		if cross.Y < 0 then
			angleDegrees = -angleDegrees
		end

		_lastMoveYaw = angleDegrees
		return angleDegrees, mag
	end

	--[[
		将 moveYaw 映射为四向 Cardinal 权重（相邻两向，smoothstep；和为 1）
		@param yawDegrees number - getMoveYaw 返回的带符号角
		@return { Forward: number, Left: number, Right: number, Back: number } - 相邻两向 smoothstep，和为 1
	]]
	local function getCardinalWeights(yawDegrees: number): { Forward: number, Left: number, Right: number, Back: number }
		local yaw = yawDegrees
		while yaw > 180 do
			yaw -= 360
		end
		while yaw < -180 do
			yaw += 360
		end
		-- -180 与 180 同为正后
		if yaw == -180 then
			yaw = 180
		end

		local w = { Forward = 0, Left = 0, Right = 0, Back = 0 }
		--[[
			Hermite smoothstep，把 0~1 线性 t 收成 S 曲线
			@param t number - 未 clamp 的插值参数
			@return number - [0,1]
		]]
		local function smoothstep(t: number): number
			t = math.clamp(t, 0, 1)
			return t * t * (3 - 2 * t)
		end
		if yaw >= 0 and yaw <= 90 then
			local t = smoothstep(yaw / 90)
			w.Forward = 1 - t
			w.Right = t
		elseif yaw > 90 and yaw <= 180 then
			local t = smoothstep((yaw - 90) / 90)
			w.Right = 1 - t
			w.Back = t
		elseif yaw < 0 and yaw >= -90 then
			local t = smoothstep((-yaw) / 90)
			w.Forward = 1 - t
			w.Left = t
		else
			-- (-180, -90)
			local t = smoothstep((-yaw - 90) / 90)
			w.Left = 1 - t
			w.Back = t
		end
		return w
	end

	return {
		getRigScale = getRigScale,
		getRunAnimationSpeed = getRunAnimationSpeed,
		getRelativeMoveDirection = getRelativeMoveDirection,
		getMoveYaw = getMoveYaw,
		getCardinalWeights = getCardinalWeights,
	}
end

return AnimateMotionHelpers
