--[[
	Module: CharacterControl.SprintMode
	Description: Walk/Run 模式机；支持一键切换（Toggle）与长按奔跑（Hold）；经 CMS Modifier 声明奔跑加成，不写 WalkSpeed。
	Author: 林奥宇
	Created: 2026-08-05
	Last Modified: 2026-09-01

	输入模式（settingConf.RunMode / SetInputMode）：
	- Toggle（默认）：冲刺键按下边沿翻转 Run↔Walk；松键不改步态。
	- Hold：按住冲刺键为 Run，松开为 Walk。

	进场默认奔跑（spawnInRunMode）：
	- Toggle：Create 后 toggleOn=true（不按键即为 Run）；首次按下边沿会翻转为 Walk。
	- Hold：Create 后 defaultRun=true；首次松开冲刺键后清除闩，此后仅 sprintHeld 维持 Run。
]]

local Constants = require(script.Parent.Constants)

export type GaitMode = "Walk" | "Run"
export type SprintInputMode = "Toggle" | "Hold"

export type MoveSpeedBind = {
	pushModifier: (ownerId: string, spec: { mul: number?, add: number?, hardLock: boolean? }) -> (),
	popModifier: (ownerId: string) -> (),
}

export type SprintModeDeps = {
	moveSpeedBind: MoveSpeedBind,
	runSpeedAdd: number,
	spawnInRunMode: boolean,
	inputMode: SprintInputMode?,
}

export type SprintModeController = {
	Update: (self: SprintModeController, sprintHeld: boolean, lockSprint: boolean) -> (),
	SetInputMode: (self: SprintModeController, inputMode: SprintInputMode) -> (),
	GetInputMode: (self: SprintModeController) -> SprintInputMode,
	GetMode: (self: SprintModeController) -> GaitMode,
	destroy: (self: SprintModeController) -> (),
}

local SprintMode = {}

-- ========================================
-- 私有函数
-- ========================================

--[[
	归一化输入模式；非法或空视为 Toggle（与 setting 默认一键切换对齐）
	@param mode any - 候选模式字符串
	@return SprintInputMode - 「Toggle」或「Hold」
]]
local function _normalizeInputMode(mode: any): SprintInputMode
	if mode == "Hold" then
		return "Hold"
	end
	return "Toggle"
end

-- ========================================
-- 公共工厂
-- ========================================

--[[
	创建 Sprint 模式机
	@param deps SprintModeDeps - CMS Bind、奔跑加成、进场默认、输入模式
	@return SprintModeController - Update / SetInputMode / GetMode / destroy
]]
function SprintMode.create(deps: SprintModeDeps): SprintModeController
	local bind = deps.moveSpeedBind
	local runAdd = if type(deps.runSpeedAdd) == "number" then deps.runSpeedAdd else 0
	local inputMode: SprintInputMode = _normalizeInputMode(deps.inputMode)
	local defaultRun = deps.spawnInRunMode == true
	-- Toggle 闩：与进场默认奔跑对齐；Hold 下仅作语义占位，由 defaultRun + sprintHeld 驱动
	local toggleOn = defaultRun
	local prevSprintHeld = false
	local gait: GaitMode = if defaultRun then "Run" else "Walk"
	local sprintModifierActive = false
	local destroyed = false

	--[[
		同步 Control:Sprint Modifier
		@param wantRun boolean - 是否要奔跑加成
	]]
	local function _syncModifier(wantRun: boolean)
		if not bind then
			return
		end
		if wantRun then
			if not sprintModifierActive then
				bind.pushModifier(Constants.OwnerSprint, { add = runAdd })
				sprintModifierActive = true
			end
		else
			if sprintModifierActive then
				bind.popModifier(Constants.OwnerSprint)
				sprintModifierActive = false
			end
		end
	end

	--[[
		应用 wantRun 到步态与 Modifier
		@param wantRun boolean - 本帧是否应奔跑
	]]
	local function _applyWantRun(wantRun: boolean)
		if wantRun then
			gait = "Run"
			_syncModifier(true)
		else
			gait = "Walk"
			_syncModifier(false)
		end
	end

	-- 进场立刻对齐奔跑 Modifier
	_syncModifier(defaultRun)

	local controller = {} :: SprintModeController

	--[[
		切换一键/长按输入模式（设置变更时调用）
		@param newMode SprintInputMode - 「Toggle」或「Hold」
	]]
	function controller:SetInputMode(newMode: SprintInputMode)
		if destroyed then
			return
		end
		local normalized = _normalizeInputMode(newMode)
		if inputMode == normalized then
			return
		end
		inputMode = normalized
		if inputMode == "Toggle" then
			-- 从当前步态同步闩，避免切模式后突然掉速/加速
			toggleOn = gait == "Run"
			defaultRun = false
		else
			-- Hold：丢弃 Toggle 闩；若键未按住则回到 Walk（不再保留幽灵 Run）
			toggleOn = false
			defaultRun = false
		end
	end

	--[[
		当前输入模式
		@return SprintInputMode - 「Toggle」或「Hold」
	]]
	function controller:GetInputMode(): SprintInputMode
		return inputMode
	end

	--[[
		每帧更新步态
		@param sprintHeld boolean - Intent 冲刺按住
		@param lockSprint boolean - LockMask.Sprint 是否锁定
	]]
	function controller:Update(sprintHeld: boolean, lockSprint: boolean)
		if destroyed then
			return
		end

		local held = sprintHeld == true
		local rising = held and not prevSprintHeld
		local falling = (not held) and prevSprintHeld
		prevSprintHeld = held

		local wantRun = false
		if inputMode == "Toggle" then
			-- 锁 Sprint 期间不翻转，避免解锁后步态与玩家预期相反
			if rising and not lockSprint then
				toggleOn = not toggleOn
			end
			wantRun = (not lockSprint) and toggleOn
		else
			if falling then
				-- 松开冲刺：放弃进场默认奔跑闩，此后走 Hold 语义
				defaultRun = false
			end
			wantRun = (not lockSprint) and (held or defaultRun)
		end

		_applyWantRun(wantRun)
	end

	--[[
		当前步态
		@return GaitMode - 「Walk」或「Run」
	]]
	function controller:GetMode(): GaitMode
		return gait
	end

	--[[
		弹出 Sprint Modifier
	]]
	function controller:destroy()
		if destroyed then
			return
		end
		destroyed = true
		_syncModifier(false)
	end

	return controller
end

return SprintMode
