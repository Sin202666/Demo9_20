--[[
	Module: SystemInput-Type
	Description: SystemInput IDE 类型桩（实现以 Client SystemModule/SystemInput 为准）
	Author: 林奥宇
	Created: 2026-08-27
	Last Modified: 2026-09-04
]]

local module = {}

module.ActionIds = {
	MountToggle = "Mount.Toggle",
	SkillDash = "Skill.Dash",
	BagToggle = "Bag.Toggle",
}

module.Phase = {
	Started = "Started",
	Ended = "Ended",
}

module.ContextIds = {
	Gameplay = "Gameplay",
	UIModal = "UI.Modal",
}

module.Scheme = {
	KeyboardMouse = "KeyboardMouse",
	Gamepad = "Gamepad",
	Touch = "Touch",
}

function module.SkillSlotActionId(slotIndex: number): string
end

function module.ToolbarSlotActionId(slotIndex: number): string
end

function module.Init()
end

function module.destroy()
end

function module.Destroy()
end

function module.SetEnabled(enabled: boolean)
end

function module.IsEnabled(): boolean
end

function module.GetActiveScheme(): string
end

function module.SetActiveScheme(scheme: string, lock: boolean?): (boolean, string?)
end

function module.IsSchemeLocked(): boolean
end

function module.PushContext(contextId: string, opts: {
	priority: number?,
	consume: boolean?,
	suppressLower: boolean?,
	actions: { string }?,
}?): string
end

function module.PopContext(token: string): boolean
end

function module.HasContext(contextId: string): boolean
end

function module.GetActiveContexts(): { { id: string, priority: number, token: string } }
end

function module.OnAction(
	actionId: string,
	callback: (phase: string, value: number?, meta: { [string]: any }?) -> ()
): { Disconnect: (self: any) -> () }
end

function module.IsActionActive(actionId: string): boolean
end

function module.GetActionValue(actionId: string): number
end

function module.SetBinding(actionId: string, keyCode: Enum.KeyCode, scheme: string?): (boolean, string?)
end

function module.GetBindings(scheme: string?): { { actionId: string, keyCode: Enum.KeyCode, scheme: string } }
end

function module.FindConflict(scheme: string, keyCode: Enum.KeyCode, exceptActionId: string?): string?
end

function module.RegisterDefaultProvider(provider: (scheme: string?) -> ())
end

function module.ResetBindingsToDefault(scheme: string?, save: boolean?): boolean
end

function module.LoadSavedBindings(): boolean
end

function module.SaveBindings(): boolean
end

function module.BeginRebindCapture(
	actionId: string,
	scheme: string,
	onDone: (boolean, Enum.KeyCode?, string?) -> ()
): (boolean, string?)
end

function module.CancelRebindCapture()
end

function module.IsRebindCapturing(): boolean
end

function module.SetDebugOverlay(enabled: boolean)
end

return module
