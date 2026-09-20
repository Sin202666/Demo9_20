--[[
	Module: LocoStyle-Type
	Description: Utils.LocoStyle 类型桩（实现以 ToolSystem/LocoStyle 为准）
	Author: 林奥宇
	Created: 2026-08-05
	Last Modified: 2026-09-01
]]

local module = {}

--[[
	风格栈优先级（与 LocoStyle.Priority 一致）
]]
module.Priority = {
	Base = 0,
	Equip = 10,
	Transform = 50,
	Level = 100,
}

export type LocoStyleController = {
	Apply: (self: LocoStyleController, styleId: string) -> boolean,
	SetBaseStyle: (self: LocoStyleController, styleId: string) -> boolean,
	PushStyle: (self: LocoStyleController, source: string, styleId: string, priority: number?) -> boolean,
	PopStyle: (self: LocoStyleController, source: string) -> boolean,
	Reset: (self: LocoStyleController) -> boolean,
	GetActiveStyleId: (self: LocoStyleController) -> string,
	GetAppliedStyleId: (self: LocoStyleController) -> string?,
	FlushPending: (self: LocoStyleController) -> (),
	destroy: (self: LocoStyleController) -> (),
}

--[[
	创建角色级控制器（仅 Animate/init）
	@param character Model - 角色
	@param deps table - { animate: any, arbiter: any, resyncAfterBaseUnpause: () -> (), footStepMarkersFor: ((slot: string) -> { [string]: (string) -> () })? }
	@return LocoStyleController - 角色级控制器（重复 Create 返回已有实例）
]]
function module.Create(character: Model, deps: {
	animate: any,
	arbiter: any,
	resyncAfterBaseUnpause: () -> (),
	footStepMarkersFor: ((slot: string) -> { [string]: (string) -> () })?,
}): LocoStyleController
	return nil :: any
end

--[[
	查询已 Create 实例；未创建返回 nil
	@param character Model - 角色
	@return LocoStyleController? - 已 Create 的实例；未创建为 nil
]]
function module.GetForCharacter(character: Model): LocoStyleController?
	return nil
end

return module
