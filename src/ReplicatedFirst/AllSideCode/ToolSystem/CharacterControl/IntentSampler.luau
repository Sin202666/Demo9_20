--[[
	Module: CharacterControl.IntentSampler
	Description: 设备输入 → IntentSnapshot；gameProcessed 时仍采样 Jump/Sprint/Interact（由 LockMask 决定是否生效）。
	Author: 林奥宇
	Created: 2026-08-05
	Last Modified: 2026-09-01
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local UserInputService = Utils.UserInputService
local Log = Utils.Log

export type IntentSnapshot = {
	moveAxis: Vector3,
	moveMagnitude: number,
	jumpPressed: boolean,
	jumpHeld: boolean,
	sprintHeld: boolean,
	crouchHeld: boolean,
	interactPressed: boolean,
}

export type IntentSamplerOpts = {
	sprintKey: Enum.KeyCode,
	gamepadSprintKey: Enum.KeyCode?,
	interactKey: Enum.KeyCode,
	gamepadInteractKey: Enum.KeyCode?,
}

export type IntentSampler = {
	Sample: (self: IntentSampler, humanoid: Humanoid) -> IntentSnapshot,
	destroy: (self: IntentSampler) -> (),
}

local IntentSampler = {}

-- ========================================
-- 公共 / 私有
-- ========================================

--[[
	解析 KeyCode 名
	@param name string - 如 LeftShift；空或非法则回退
	@param fallback Enum.KeyCode - 解析失败时使用的键
	@return Enum.KeyCode - 解析得到的键或 fallback
]]
function IntentSampler.resolveKeyCode(name: string?, fallback: Enum.KeyCode): Enum.KeyCode
	if type(name) ~= "string" or name == "" then
		return fallback
	end
	local ok, key = pcall(function()
		return (Enum.KeyCode :: any)[name]
	end)
	if ok and typeof(key) == "EnumItem" and key.EnumType == Enum.KeyCode then
		return key
	end
	Log.warn("[CharacterControl.IntentSampler] 未知键名，回退:", name)
	return fallback
end

--[[
	是否为跳跃相关输入
	@param input InputObject - 本次输入对象
	@return boolean - Space 或手柄 ButtonA 时为 true
]]
local function _isJumpInput(input: InputObject): boolean
	if input.KeyCode == Enum.KeyCode.Space then
		return true
	end
	if input.KeyCode == Enum.KeyCode.ButtonA then
		return true
	end
	return false
end

-- ========================================
-- 公共工厂
-- ========================================

--[[
	创建采样器
	@param opts IntentSamplerOpts - 冲刺/交互键配置
	@return IntentSampler - 可 Sample / destroy 的采样器实例
]]
function IntentSampler.create(opts: IntentSamplerOpts): IntentSampler
	local sprintKey = opts.sprintKey
	local gamepadSprintKey = opts.gamepadSprintKey
	local interactKey = opts.interactKey
	local gamepadInteractKey = opts.gamepadInteractKey

	local jumpHeld = false
	local sprintHeld = false
	local jumpPressedEdge = false
	local interactPressedEdge = false
	local connections: { RBXScriptConnection } = {}
	local destroyed = false

	--[[
		标记跳跃按下边沿
	]]
	local function _noteJumpPressed()
		jumpPressedEdge = true
		jumpHeld = true
	end

	--[[
		是否冲刺键
		@param key Enum.KeyCode - 待判定键码
		@return boolean - 匹配键盘或手柄冲刺键时为 true
	]]
	local function _isSprintKey(key: Enum.KeyCode): boolean
		return key == sprintKey or (gamepadSprintKey ~= nil and key == gamepadSprintKey)
	end

	--[[
		是否交互键
		@param key Enum.KeyCode - 待判定键码
		@return boolean - 匹配键盘或手柄交互键时为 true
	]]
	local function _isInteractKey(key: Enum.KeyCode): boolean
		return key == interactKey or (gamepadInteractKey ~= nil and key == gamepadInteractKey)
	end

	table.insert(
		connections,
		UserInputService.InputBegan:Connect(function(input: InputObject, _gameProcessed: boolean)
			if destroyed then
				return
			end
			-- 故意忽略 gameProcessed：UI 吞键时仍采样，由 LockMask 决定是否生效
			if _isJumpInput(input) then
				_noteJumpPressed()
				return
			end
			if _isSprintKey(input.KeyCode) then
				sprintHeld = true
				return
			end
			if _isInteractKey(input.KeyCode) then
				interactPressedEdge = true
			end
		end)
	)

	table.insert(
		connections,
		UserInputService.InputEnded:Connect(function(input: InputObject, _gameProcessed: boolean)
			if destroyed then
				return
			end
			if _isJumpInput(input) then
				jumpHeld = false
				return
			end
			if _isSprintKey(input.KeyCode) then
				sprintHeld = false
			end
		end)
	)

	-- 触控/移动端跳跃请求（与 Space 并列产生边沿）
	table.insert(
		connections,
		UserInputService.JumpRequest:Connect(function()
			if destroyed then
				return
			end
			_noteJumpPressed()
		end)
	)

	local sampler = {} :: IntentSampler

	--[[
		采样一帧 Intent；消费 jumpPressed / interactPressed 边沿
		@param humanoid Humanoid - 本地角色 Humanoid
		@return IntentSnapshot - 本帧意图快照（新表）
	]]
	function sampler:Sample(humanoid: Humanoid): IntentSnapshot
		local moveAxis = Vector3.zero
		if humanoid and humanoid.Parent then
			local md = humanoid.MoveDirection
			moveAxis = Vector3.new(md.X, 0, md.Z)
		end
		local mag = moveAxis.Magnitude
		local pressed = jumpPressedEdge
		jumpPressedEdge = false
		local interactPressed = interactPressedEdge
		interactPressedEdge = false
		return {
			moveAxis = moveAxis,
			moveMagnitude = mag,
			jumpPressed = pressed,
			jumpHeld = jumpHeld,
			sprintHeld = sprintHeld,
			crouchHeld = false, -- Phase3 Crouch/Slide
			interactPressed = interactPressed,
		}
	end

	--[[
		断开输入连接
	]]
	function sampler:destroy()
		if destroyed then
			return
		end
		destroyed = true
		for _, conn in ipairs(connections) do
			conn:Disconnect()
		end
		table.clear(connections)
	end

	return sampler
end

return IntentSampler
