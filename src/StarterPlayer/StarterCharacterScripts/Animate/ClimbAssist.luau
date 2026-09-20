--[[
	Module: ClimbAssist
	Description: 攀爬接近辅助：以 HRP 为基准探测前方 Truss，在有移动意图朝梯子推进时
	  输出 suppressRunLean，供 GroundLocomotion 将 Run 视觉覆盖为 Walk，并抑制 AirLean，
	  避免跑姿/空中 lean 挤开梯子。Jump/Freefall 同样探测。
	  不替代引擎 Humanoid Climbing；不改 WalkSpeed / 不 PlatformStand。
	Author: 林奥宇
	Created: 2026-08-17
	Last Modified: 2026-08-31

	================================================================================
	使用说明
	================================================================================

	【何时用】
	- 本地玩家 Animate：Heartbeat 内先 update，再交给 GroundLocomotion 消费 suppressRunLean。
	- 不要用于自定义攀爬移动、空中砸梯、非 Truss 梯子（首版非目标）。

	【与兄弟模块】
	- GroundLocomotion：地面消费者；视觉 gait 覆盖，权威 _groundStable / Stop* 不改。
	- AirLean：空中消费者；suppressRunLean 时视为 suppressed，瞬时归零 RootJoint lean。
	- CharacterMotion：本模块不写电机。

	【标准加载】
	local ClimbAssist = require(script.Parent.ClimbAssist)
	local assist = ClimbAssist.create({
		character = character,
		humanoid = humanoid,
		hrp = hrp,
		setting = Setting,
		isLocoSuppressed = function() return false end,
	})
	-- Heartbeat:
	local state = assist.update(dt)
	-- state.suppressRunLean → GroundLocomotion deps.getSuppressRunLean

	【示例】
	assist.update(dt)
	if assist.getState().suppressRunLean then
		-- GroundLocomotion 内将 Run 视觉切 Walk（短 fade）
	end
]]

local Workspace = game:GetService("Workspace")

local ClimbAssist = {}

export type ClimbAssistState = {
	nearClimbable: boolean,
	climbNormal: Vector3?,
	suppressRunLean: boolean,
}

export type ClimbAssistDeps = {
	character: Model,
	humanoid: Humanoid,
	hrp: BasePart,
	setting: any,
	isLocoSuppressed: () -> boolean,
}

export type ClimbAssistController = {
	update: (dt: number) -> ClimbAssistState,
	getState: () -> ClimbAssistState,
	destroy: () -> (),
}

local EMPTY_STATE: ClimbAssistState = {
	nearClimbable = false,
	climbNormal = nil,
	suppressRunLean = false,
}

--[[
	读取 ClimbAssist 配置表（缺省用安全默认）
	@param setting any - AnimateSetting
	@return table - 配置字段表
]]
local function _cfg(setting: any): any
	local c = setting and setting.ClimbAssist
	if type(c) == "table" then
		return c
	end
	return {}
end

--[[
	数值配置，非法则回退 default
	@param cfg any - ClimbAssist 表
	@param key string - 键名
	@param default number - 默认值
	@return number - 合法数字；非法则 default
]]
local function _num(cfg: any, key: string, default: number): number
	local v = cfg[key]
	if type(v) == "number" and v == v then
		return v
	end
	return default
end

--[[
	实例或其祖先是否为 TrussPart
	@param inst Instance? - 射线命中实例
	@return (boolean, Instance?) - 是否可攀、命中的 Truss；非 Truss 时 false, nil
]]
local function _findTruss(inst: Instance?): (boolean, Instance?)
	local cur: Instance? = inst
	while cur do
		if cur:IsA("TrussPart") then
			return true, cur
		end
		cur = cur.Parent
	end
	return false, nil
end

--[[
	水平化方向向量；过小返回 nil
	@param v Vector3 - 原始方向
	@return Vector3? - 水平单位向量；过小返回 nil
]]
local function _flattenUnit(v: Vector3): Vector3?
	local flat = Vector3.new(v.X, 0, v.Z)
	if flat.Magnitude < 1e-4 then
		return nil
	end
	return flat.Unit
end

--[[
	创建攀爬接近辅助控制器
	@param deps ClimbAssistDeps - 角色与门闩回调
	@return ClimbAssistController - update/getState/destroy
]]
function ClimbAssist.create(deps: ClimbAssistDeps): ClimbAssistController
	local character = deps.character
	local humanoid = deps.humanoid
	local hrp = deps.hrp
	local setting = deps.setting

	local _state: ClimbAssistState = {
		nearClimbable = false,
		climbNormal = nil,
		suppressRunLean = false,
	}
	local _suppressStartedAt = 0
	local _probeAccum = 0
	local _rayParams = RaycastParams.new()
	_rayParams.FilterType = Enum.RaycastFilterType.Exclude
	_rayParams.FilterDescendantsInstances = { character }
	_rayParams.IgnoreWater = true

	--[[
		清空邻近/抑制状态
	]]
	local function _clear()
		_state.nearClimbable = false
		_state.climbNormal = nil
		_state.suppressRunLean = false
		_suppressStartedAt = 0
	end

	--[[
		当前 Humanoid 状态是否禁止探测（游泳/已攀爬/物理异常等）
		Jump/Freefall 允许探测，便于空中贴梯触发引擎 Climbing。
		@return boolean - true 表示应 clear、本帧不探测
]]
	local function _shouldGateOut(): boolean
		if deps.isLocoSuppressed() then
			return true
		end
		if humanoid.PlatformStand then
			return true
		end
		local st = humanoid:GetState()
		if st == Enum.HumanoidStateType.Climbing
			or st == Enum.HumanoidStateType.Swimming
			or st == Enum.HumanoidStateType.Flying
			or st == Enum.HumanoidStateType.Physics
			or st == Enum.HumanoidStateType.Ragdoll
			or st == Enum.HumanoidStateType.PlatformStanding
		then
			return true
		end
		return false
	end

	--[[
		是否处于腾空（Jump/Freefall 或脚下无地面）
		@return boolean - true 表示 Jump/Freefall 或 FloorMaterial=Air
]]
	local function _isAirborne(): boolean
		local st = humanoid:GetState()
		if st == Enum.HumanoidStateType.Jumping or st == Enum.HumanoidStateType.Freefall then
			return true
		end
		return humanoid.FloorMaterial == Enum.Material.Air
	end

	--[[
		沿水平方向从原点发射，穿透装饰后找 Truss
		@param origin Vector3 - 射线起点
		@param dir Vector3 - 水平单位方向
		@param maxDist number - 最大距离
		@param penetrateTimes number - 非 Truss 穿透次数
		@param penetrateStep number - 每次穿透前进距离
		@return (Vector3?, number?) - 表面法线、命中距离；未命中为 nil
	]]
	local function _rayForTruss(
		origin: Vector3,
		dir: Vector3,
		maxDist: number,
		penetrateTimes: number,
		penetrateStep: number
	): (Vector3?, number?)
		local remain = maxDist
		local from = origin
		local traveledTotal = 0
		local hops = math.max(0, math.floor(penetrateTimes))
		for _ = 0, hops do
			if remain <= 1e-3 then
				break
			end
			local result = Workspace:Raycast(from, dir * remain, _rayParams)
			if not result then
				return nil, nil
			end
			local segment = (result.Position - from).Magnitude
			traveledTotal += segment
			local isTruss = _findTruss(result.Instance)
			if isTruss then
				return result.Normal, traveledTotal
			end
			traveledTotal += penetrateStep
			remain -= segment + penetrateStep
			from = result.Position + dir * penetrateStep
		end
		return nil, nil
	end

	--[[
		在髋/胸两高度探测前方 Truss；取更近的一次命中
		@param dir Vector3 - 水平单位方向
		@param maxDist number - 探测距离
		@return (boolean, Vector3?) - 是否邻近、表面法线
	]]
	local function _probe(dir: Vector3, maxDist: number): (boolean, Vector3?)
		local cfg = _cfg(setting)
		local hipY = _num(cfg, "HIP_Y_OFFSET", 0.5)
		local chestY = _num(cfg, "CHEST_Y_OFFSET", 1.2)
		local normalYMax = _num(cfg, "NORMAL_Y_MAX", 0.35)
		local penTimes = _num(cfg, "DECOR_PENETRATE_TIMES", 2)
		local penStep = _num(cfg, "DECOR_PENETRATE_STEP", 0.08)
		local base = hrp.Position
		local bestDist = math.huge
		local bestNormal: Vector3? = nil

		for _, yOff in ipairs({ hipY, chestY }) do
			local origin = base + Vector3.new(0, yOff, 0)
			local normal, hitDist = _rayForTruss(origin, dir, maxDist, penTimes, penStep)
			if normal and hitDist and math.abs(normal.Y) <= normalYMax then
				local flatN = _flattenUnit(normal)
				if flatN and hitDist < bestDist then
					bestDist = hitDist
					bestNormal = flatN
				end
			end
		end

		if bestNormal then
			return true, bestNormal
		end
		return false, nil
	end

	--[[
		每帧更新探测与抑制状态
		@param dt number - 帧间隔
		@return ClimbAssistState - 当前状态（模块内表，调用方勿长期缓存可变引用做写回）
	]]
	local function update(dt: number): ClimbAssistState
		local cfg = _cfg(setting)
		if cfg.ENABLE == false then
			_clear()
			return _state
		end
		if character.Parent == nil or hrp.Parent == nil then
			_clear()
			return _state
		end
		if _shouldGateOut() then
			_clear()
			return _state
		end

		-- 抑制中每帧探测；否则可按间隔降频
		local interval = _num(cfg, "PROBE_INTERVAL_SEC", 0)
		if not _state.suppressRunLean and interval > 0 then
			_probeAccum += dt
			if _probeAccum < interval then
				return _state
			end
			_probeAccum = 0
		else
			_probeAccum = 0
		end

		local enterDist = _num(cfg, "PROBE_ENTER", 3.5)
		local exitDist = _num(cfg, "PROBE_EXIT", 4.5)
		if exitDist < enterDist then
			exitDist = enterDist
		end
		local probeDist = if _state.nearClimbable then exitDist else enterDist

		local move = humanoid.MoveDirection
		local moveIntentMin = _num(cfg, "MOVE_INTENT_MIN", 0.01)
		local hasMoveIntent = move.Magnitude >= moveIntentMin
		local probeDir = _flattenUnit(move)
		if not probeDir then
			probeDir = _flattenUnit(hrp.CFrame.LookVector)
		end
		if not probeDir then
			_clear()
			return _state
		end

		local near, normal = _probe(probeDir, probeDist)
		_state.nearClimbable = near
		_state.climbNormal = if near then normal else nil

		local wantSuppress = false
		if near and normal then
			local approachDot = _num(cfg, "APPROACH_DOT", 0.35)
			local toward = (-normal)
			local airborne = _isAirborne()
			if hasMoveIntent and move.Unit:Dot(toward) >= approachDot then
				wantSuppress = true
			elseif airborne then
				-- 空中可用水平速度朝梯子推进作为意图（跳向/砸向梯子时 MoveDirection 可能不足）
				local velMin = _num(cfg, "AIR_VEL_INTENT_MIN", 2)
				local horiz = Vector3.new(hrp.AssemblyLinearVelocity.X, 0, hrp.AssemblyLinearVelocity.Z)
				if horiz.Magnitude >= velMin and horiz.Unit:Dot(toward) >= approachDot then
					wantSuppress = true
				end
			end
		end

		local maxSuppress = _num(cfg, "MAX_SUPPRESS_SEC", 0.45)
		if _isAirborne() then
			local airMax = _num(cfg, "AIR_MAX_SUPPRESS_SEC", 0.9)
			if airMax > maxSuppress then
				maxSuppress = airMax
			end
		end
		if wantSuppress then
			if not _state.suppressRunLean then
				_suppressStartedAt = time()
			end
			if maxSuppress > 0 and _suppressStartedAt > 0 and (time() - _suppressStartedAt) > maxSuppress then
				_state.suppressRunLean = false
			else
				_state.suppressRunLean = true
			end
		else
			_state.suppressRunLean = false
			_suppressStartedAt = 0
		end

		return _state
	end

	--[[
		只读当前状态（与上次 update 结果相同表引用；热路径零分配，调用方勿写回字段）
		@return ClimbAssistState - nearClimbable / climbNormal / suppressRunLean
]]
	local function getState(): ClimbAssistState
		return _state
	end

	--[[
		销毁：清空状态（连接由 Animate 生命周期统一管）
	]]
	local function destroy()
		_clear()
	end

	return {
		update = update,
		getState = getState,
		destroy = destroy,
	}
end

return ClimbAssist
