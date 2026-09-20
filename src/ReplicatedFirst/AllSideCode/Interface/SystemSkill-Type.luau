--[[
	Module: SystemSkill-Type
	Description: SystemSkill 类型桩（装备权威 API；与服实现签名对齐）
	Author: 林奥宇
	Created: 2026-07-29
	Last Modified: 2026-08-31
]]

local module = {}

function module.IsEnabled(): boolean
	return true
end

function module.IsDashEnabled(): boolean
	return true
end

function module.Init(_plr: Player): () end

function module.EquipSkill(_plr: Player, skillID: number, slotIndex: number): (boolean, string?)
	return false, "INVALID_PARAM"
end

function module.UnequipSkill(_plr: Player, slotIndex: number): (boolean, string?)
	return false, "INVALID_PARAM"
end

function module.GetEquippedSkills(_plr: Player): (number, any)
	return 0, {}
end

return module
