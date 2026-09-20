--[[
	Module: CharacterControl-Type
	Description: Utils.CharacterControl 类型桩（IDE 补全；实现以 ToolSystem/CharacterControl 为准）
	Author: 林奥宇
	Created: 2026-08-05
	Last Modified: 2026-09-01

	完整使用说明见 ToolSystem/CharacterControl/init.luau 文件头。
	业务只经 Utils.CharacterControl.GetForCharacter；仅 CharacterManager 调用 Create。
]]

local CharacterControl = {}

export type IntentSnapshot = {
	moveAxis: Vector3,
	moveMagnitude: number,
	jumpPressed: boolean,
	jumpHeld: boolean,
	sprintHeld: boolean,
	crouchHeld: boolean,
	interactPressed: boolean,
}

export type LockChannels = {
	Move: boolean,
	Jump: boolean,
	Sprint: boolean,
	Look: boolean,
	Interact: boolean,
}

export type MovePolicy = "SpeedOnly" | "DisableControls"

export type LockMaskSpec = {
	Move: boolean?,
	Jump: boolean?,
	Sprint: boolean?,
	Look: boolean?,
	Interact: boolean?,
	MovePolicy: MovePolicy?,
}

export type GaitMode = "Walk" | "Run"
export type SprintInputMode = "Toggle" | "Hold"

export type MoveSpeedBind = {
	pushModifier: (ownerId: string, spec: { mul: number?, add: number?, hardLock: boolean? }) -> (),
	popModifier: (ownerId: string) -> (),
}

export type CreateOptions = {
	moveSpeedBind: MoveSpeedBind,
	localPlayer: Player?,
	enabled: boolean?,
}

export type CharacterControlInstance = {
	GetIntent: (self: CharacterControlInstance) -> IntentSnapshot,
	GetMode: (self: CharacterControlInstance) -> GaitMode,
	PushLock: (self: CharacterControlInstance, sourceId: string, mask: LockMaskSpec) -> (),
	PopLock: (self: CharacterControlInstance, sourceId: string) -> boolean,
	GetLockMask: (self: CharacterControlInstance) -> LockChannels,
	TransferControlOwner: (self: CharacterControlInstance, ownerId: string, mask: LockMaskSpec?) -> (),
	ReleaseControlOwner: (self: CharacterControlInstance, ownerId: string) -> boolean,
	SuppressJump: (self: CharacterControlInstance, durationSec: number, reason: string?) -> (),
	ClearJumpBuffer: (self: CharacterControlInstance) -> (),
	destroy: (self: CharacterControlInstance) -> (),
	Character: Model,
}

--[[
	创建角色级 Control（仅本地 CharacterManager）
	@param character Model - 角色模型
	@param options CreateOptions? - 须含 moveSpeedBind；可选 localPlayer / enabled
	@return CharacterControlInstance? - 实例；禁用或失败时为 nil
]]
function CharacterControl.Create(character: Model, options: CreateOptions?): CharacterControlInstance?
	return nil
end

--[[
	查询已 Create 实例
	@param character Model - 角色模型
	@return CharacterControlInstance? - 已创建实例；未 Create 为 nil
]]
function CharacterControl.GetForCharacter(character: Model): CharacterControlInstance?
	return nil
end

return CharacterControl
