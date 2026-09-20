--[[
	Module: MountAnimSets
	Description: 坐骑 AnimSet → Idle/Run/Jump 槽位映射（Animation.luau 逻辑名）
	Author: 林奥宇
	Created: 2026-08-27
	Last Modified: 2026-08-28

	能力：
	- 与 mountConf.AnimSet 对齐；槽非法或未知集返回 nil
	- 不播轨、不持有角色状态；播轨由 MountPresentation 负责

	加载：
		local MountAnimSets = require(script.Parent.MountAnimSets)
		local name = MountAnimSets.ResolveAnimName("MountUnicorn", "Idle")
]]

local MountAnimSets = {}

MountAnimSets.SLOT_ORDER = table.freeze({
	"Idle",
	"Run",
	"Jump",
})

local Sets: { [string]: { [string]: string } } = {
	MountUnicorn = {
		Idle = "Mount_Unicorn_Idle",
		Run = "Mount_Unicorn_Run",
		Jump = "Mount_Unicorn_Jump",
	},
}

--[[
	是否已注册 AnimSet
	@param animSet string - mountConf.AnimSet
	@return boolean - 已注册
]]
function MountAnimSets.HasSet(animSet: string): boolean
	if type(animSet) ~= "string" or animSet == "" then
		return false
	end
	return Sets[animSet] ~= nil
end

--[[
	解析 AnimSet 在指定槽的 Animation 逻辑名
	@param animSet string - mountConf.AnimSet
	@param slot string - Idle / Run / Jump
	@return string? - Animation.luau 逻辑名；未知集或槽返回 nil
]]
function MountAnimSets.ResolveAnimName(animSet: string, slot: string): string?
	if type(animSet) ~= "string" or animSet == "" then
		return nil
	end
	if type(slot) ~= "string" or slot == "" then
		return nil
	end
	local set = Sets[animSet]
	if not set then
		return nil
	end
	local name = set[slot]
	if type(name) ~= "string" or name == "" then
		return nil
	end
	return name
end

--[[
	列出 AnimSet 全部槽逻辑名（去重），供预热
	@param animSet string - mountConf.AnimSet
	@return { string } - 逻辑名列表
]]
function MountAnimSets.ListAnimNames(animSet: string): { string }
	local names: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, slot in ipairs(MountAnimSets.SLOT_ORDER) do
		local animName = MountAnimSets.ResolveAnimName(animSet, slot)
		if animName and not seen[animName] then
			seen[animName] = true
			table.insert(names, animName)
		end
	end
	return names
end

return MountAnimSets