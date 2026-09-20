--[[
	Module: CharacterControl.JumpPolicy
	Description: 跳跃 Buffer / Coyote / Suppress；经 SetStateEnabled 禁跳，不改 Animate Land 门闩。
	Author: 林奥宇
	Created: 2026-08-05
	Last Modified: 2026-09-01
]]

local Constants = require(script.Parent.Constants)

export type JumpPolicyDeps = {
	humanoid: Humanoid,
	bufferSec: number,
	coyoteSec: number,
}

export type JumpPolicyController = {
	Update: (self: JumpPolicyController, jumpPressed: boolean, lockJump: boolean) -> (),
	SuppressJump: (self: JumpPolicyController, durationSec: number, reason: string?) -> (),
	ClearJumpBuffer: (self: JumpPolicyController) -> (),
	destroy: (self: JumpPolicyController) -> (),
}

local JumpPolicy = {}

-- ========================================
-- 私有函数
-- ========================================

--[[
	是否视为贴地（可正常起跳）
	@param humanoid Humanoid - 目标 Humanoid
	@return boolean - Running/Climbing/Landed/Swimming 或非空中 FloorMaterial 时为 true
]]
local function _isGrounded(humanoid: Humanoid): boolean
	if not humanoid or not humanoid.Parent then
		return false
	end
	local state = humanoid:GetState()
	if state == Enum.HumanoidStateType.Running
		or state == Enum.HumanoidStateType.Climbing
		or state == Enum.HumanoidStateType.Landed
		or state == Enum.HumanoidStateType.Swimming
	then
		return true
	end
	if state == Enum.HumanoidStateType.Freefall or state == Enum.HumanoidStateType.Jumping then
		return false
	end
	return humanoid.FloorMaterial ~= Enum.Material.Air
end

-- ========================================
-- 公共工厂
-- ========================================

--[[
	创建跳跃策略
	@param deps JumpPolicyDeps - humanoid 与 buffer/coyote 秒数
	@return JumpPolicyController - Update / SuppressJump / ClearJumpBuffer / destroy
]]
function JumpPolicy.create(deps: JumpPolicyDeps): JumpPolicyController
	local humanoid = deps.humanoid
	local bufferSec = if type(deps.bufferSec) == "number" then math.max(0, deps.bufferSec) else Constants.DefaultJumpBufferSec
	local coyoteSec = if type(deps.coyoteSec) == "number" then math.max(0, deps.coyoteSec) else Constants.DefaultCoyoteSec

	local bufferExpire = 0
	local leaveGroundClock = 0
	local wasGrounded = _isGrounded(humanoid)
	local jumpDisabled = false
	local suppressEntries: { { expire: number, reason: string? } } = {}
	local destroyed = false

	--[[
		是否仍有未过期 Suppress
		@param now number - 当前 os.clock 时间戳
		@return boolean - 存在未过期条目时为 true（并压缩表）
	]]
	local function _hasActiveSuppress(now: number): boolean
		local any = false
		local write = 1
		for i = 1, #suppressEntries do
			local e = suppressEntries[i]
			if e.expire > now then
				suppressEntries[write] = e
				write += 1
				any = true
			end
		end
		for i = write, #suppressEntries do
			suppressEntries[i] = nil
		end
		return any
	end

	--[[
		同步 Jumping 状态机开关
		@param disabled boolean - true 禁止跳跃状态
	]]
	local function _setJumpDisabled(disabled: boolean)
		if jumpDisabled == disabled then
			return
		end
		jumpDisabled = disabled
		if humanoid and humanoid.Parent then
			humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, not disabled)
		end
	end

	--[[
		郊狼窗内？
		@param now number - 当前 os.clock
		@param grounded boolean - 本帧是否贴地
		@return boolean - 离地后仍在 coyoteSec 内为 true
	]]
	local function _inCoyote(now: number, grounded: boolean): boolean
		if grounded then
			return false
		end
		if leaveGroundClock <= 0 then
			return false
		end
		return (now - leaveGroundClock) <= coyoteSec
	end

	--[[
		当前可否起跳（贴地或郊狼）
		@param now number - 当前 os.clock
		@param grounded boolean - 本帧是否贴地
		@return boolean - 允许起跳时为 true
	]]
	local function _canJump(now: number, grounded: boolean): boolean
		return grounded or _inCoyote(now, grounded)
	end

	--[[
		强制触发一次跳跃（郊狼/缓冲消费）；调用前须未禁跳
	]]
	local function _forceJump()
		if not humanoid or not humanoid.Parent then
			return
		end
		humanoid.Jump = true
	end

	local controller = {} :: JumpPolicyController

	--[[
		每帧更新
		@param jumpPressed boolean - 本帧跳跃边沿
		@param lockJump boolean - LockMask.Jump 是否锁定
	]]
	function controller:Update(jumpPressed: boolean, lockJump: boolean)
		if destroyed or not humanoid or not humanoid.Parent then
			return
		end

		local now = os.clock()
		local suppressActive = _hasActiveSuppress(now)
		local blockJump = lockJump == true or suppressActive
		_setJumpDisabled(blockJump)

		local grounded = _isGrounded(humanoid)
		if wasGrounded and not grounded then
			leaveGroundClock = now
		elseif grounded then
			leaveGroundClock = 0
		end
		wasGrounded = grounded

		if blockJump then
			bufferExpire = 0
			return
		end

		if jumpPressed then
			if _canJump(now, grounded) then
				-- 贴地：引擎默认 Controls 通常已处理；郊狼离地需强制跳
				if not grounded then
					_forceJump()
				end
				bufferExpire = 0
			else
				bufferExpire = now + bufferSec
			end
		end

		if bufferExpire > 0 and now <= bufferExpire and _canJump(now, grounded) then
			_forceJump()
			bufferExpire = 0
		elseif bufferExpire > 0 and now > bufferExpire then
			bufferExpire = 0
		end
	end

	--[[
		开启限时禁跳
		@param durationSec number - 时长（秒）；≤0 或非数忽略
		@param reason string? - 调试用原因
	]]
	function controller:SuppressJump(durationSec: number, reason: string?)
		if destroyed then
			return
		end
		if type(durationSec) ~= "number" or durationSec ~= durationSec or durationSec <= 0 then
			return
		end
		table.insert(suppressEntries, {
			expire = os.clock() + durationSec,
			reason = reason,
		})
	end

	--[[
		清空跳跃缓冲
	]]
	function controller:ClearJumpBuffer()
		bufferExpire = 0
	end

	--[[
		恢复 Jumping 并使能
	]]
	function controller:destroy()
		if destroyed then
			return
		end
		destroyed = true
		table.clear(suppressEntries)
		bufferExpire = 0
		_setJumpDisabled(false)
	end

	return controller
end

return JumpPolicy
