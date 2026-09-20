--[[
	Module: SystemLightingCustomState-Type
	Description: SystemLightingCustomState 类型声明（完整说明见 SystemModule 实现）
	Author: 中台组 林奥宇
	Created: 2026-07-03
	Last Modified: 2026-08-04

	合法创建：SystemLightingWeather.createForOwner("SystemLightingWeather")。
	业务 Utils.SystemLightingCustomState.new 恒返回 nil（硬闸门）。
	业务勿直接 setState；仅经 LightingManager Bindable → Weather。
	Weather 专用写入：tryApplyWinningOverlay / applyAllWinningOverlays。
	内部克隆不外泄。
]]

local SystemLightingCustomState = {}

export type OverlayApplyResult = "applied" | "held" | "none"

export type OverlayBatchSummary = {
	hasHeld: boolean,
	heldMessage: string?,
	skipReason: string?,
	overlayTop: string?,
}

export type LightingApplyTarget = {
	applyEffectFromInstance: (
		self: LightingApplyTarget,
		effectInstance: Instance,
		transitionTime: number
	) -> (boolean, string),
}

-- 仅 Weather 应持有并调用；业务走 LIGHT_CUSTOM_CHANGE
export type CustomStateMachine = {
	setState: (self: CustomStateMachine, stateName: string, newState: boolean) -> boolean,
	hasState: (self: CustomStateMachine, stateName: string) -> boolean,
	isStateActive: (self: CustomStateMachine, stateName: string) -> boolean,
	getStateClassName: (self: CustomStateMachine, stateName: string) -> string?,
	getOverlayTopNames: (self: CustomStateMachine) -> string?,
	tryApplyWinningOverlay: (
		self: CustomStateMachine,
		lightingSystem: LightingApplyTarget,
		className: string,
		transitionTime: number
	) -> (OverlayApplyResult, string?),
	applyAllWinningOverlays: (
		self: CustomStateMachine,
		lightingSystem: LightingApplyTarget,
		transitionTime: number
	) -> OverlayBatchSummary,
	destroy: (self: CustomStateMachine) -> (),
}

function SystemLightingCustomState.createForOwner(ownerKey: string): CustomStateMachine?
end

function SystemLightingCustomState.new(): CustomStateMachine?
end

function SystemLightingCustomState.setState(self: CustomStateMachine, stateName: string, newState: boolean): boolean
end

function SystemLightingCustomState.hasState(self: CustomStateMachine, stateName: string): boolean
end

function SystemLightingCustomState.isStateActive(self: CustomStateMachine, stateName: string): boolean
end

function SystemLightingCustomState.getStateClassName(self: CustomStateMachine, stateName: string): string?
end

function SystemLightingCustomState.getOverlayTopNames(self: CustomStateMachine): string?
end

function SystemLightingCustomState.tryApplyWinningOverlay(
	self: CustomStateMachine,
	lightingSystem: LightingApplyTarget,
	className: string,
	transitionTime: number
): (OverlayApplyResult, string?)
end

function SystemLightingCustomState.applyAllWinningOverlays(
	self: CustomStateMachine,
	lightingSystem: LightingApplyTarget,
	transitionTime: number
): OverlayBatchSummary
end

function SystemLightingCustomState.destroy(self: CustomStateMachine)
end

return SystemLightingCustomState
