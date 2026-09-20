--[[
	Module: CharacterControl.Constants
	Description: CharacterControl 通道名、Modifier ownerId、默认键位与时长常量。
	Author: 林奥宇
	Created: 2026-08-05
	Last Modified: 2026-09-01
]]

local Constants = {}

-- ========================================
-- Modifier / 通道
-- ========================================

Constants.OwnerSprint = "Control:Sprint"
Constants.OwnerLockMove = "Control:Lock:Move"

Constants.Channel = table.freeze({
	Move = "Move",
	Jump = "Jump",
	Sprint = "Sprint",
	Look = "Look",
	Interact = "Interact",
})

-- Move 锁策略：SpeedOnly=仅 CMS 冻速；DisableControls=冻速 + ControlModule:Disable
Constants.MovePolicySpeedOnly = "SpeedOnly"
Constants.MovePolicyDisableControls = "DisableControls"
Constants.DefaultPushMovePolicy = Constants.MovePolicySpeedOnly
Constants.DefaultTransferMovePolicy = Constants.MovePolicyDisableControls

-- LocalPlayer Attribute：Look / Interact 锁聚合结果（供 Animate / 交互系统只读）
Constants.AttrLookLocked = "IsControlLookLocked"
Constants.AttrInteractLocked = "IsControlInteractLocked"

-- TransferControlOwner 未传 mask 时的全通道锁
Constants.FullLockMask = table.freeze({
	Move = true,
	Jump = true,
	Sprint = true,
	Look = true,
	Interact = true,
})

-- ========================================
-- 键位 / 时长 / 设置
-- ========================================

-- 默认冲刺键（可被 GameConfig.CharacterControl.冲刺键 覆盖）
Constants.DefaultSprintKeyName = "LeftShift"
Constants.DefaultSprintKey = Enum.KeyCode.LeftShift
Constants.DefaultGamepadSprintKey = Enum.KeyCode.ButtonL3
-- 默认交互键（可被 GameConfig.CharacterControl.交互键 覆盖）
Constants.DefaultInteractKeyName = "E"
Constants.DefaultInteractKey = Enum.KeyCode.E
Constants.DefaultGamepadInteractKey = Enum.KeyCode.ButtonX

Constants.DefaultJumpBufferSec = 0.12
Constants.DefaultCoyoteSec = 0.08
Constants.DefaultLandSuppressSec = 0

-- settingConf.ShowName；0=一键切换(Toggle)，1=长按奔跑(Hold)；缺省按 Toggle
Constants.SettingRunMode = "RunMode"
Constants.RunModeToggle = 0
Constants.RunModeHold = 1

-- 与 GameConfig.CharacterMoveSpeed 缺省对齐（配置缺失时回退）
Constants.DefaultWalkSpeed = 16
Constants.DefaultRunSpeed = 22

Constants.HumanoidWaitSec = 5
Constants.SettingFolderWaitSec = 30
Constants.RunModeWaitSec = 10

return table.freeze(Constants)
