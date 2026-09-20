--[[
	同角色 + 同 action 类型（actionInfo.action）的互斥登记。
	当 actionInfo.allowParallelTracks == false 时，本实例 Start 前会 Over 掉仍登记中的旧实例；
	任意实例进入 Over 时若仍为登记持有者则释放槽位（由 SkillActionControl:Over 调用 releaseIfOwner）。
]]

-- [Model] = { [actionKey: string] = actionInstance }，弱键避免角色销毁后长期占用
local lastByCharacter = {}
setmetatable(lastByCharacter, { __mode = "k" })

local function actionKey(action: any): string?
	local info = action.actionInfo
	if not info or not info.action then
		return nil
	end
	return tostring(info.action)
end

local function isExclusive(action: any): boolean
	return action.actionInfo ~= nil and action.actionInfo.allowParallelTracks == false
end

--[[
	在 Action 即将 Start 时调用：结束同角色、同类型的旧登记实例，再登记本实例
]]
local function beforeStart(action: any)
	if not isExclusive(action) then
		return
	end
	local character = action.baseSkill and action.baseSkill.character
	local key = actionKey(action)
	if not character or not key then
		return
	end

	local map = lastByCharacter[character]
	local prev = map and map[key]
	if prev and prev ~= action then
		prev:Over(0)
	end

	map = lastByCharacter[character] or {}
	lastByCharacter[character] = map
	map[key] = action
end

--[[
	进入 Over 时调用：若当前仍登记为本实例则释放（新实例已 preempt 时 map 已指向新实例，此处不会误清）
]]
local function releaseIfOwner(action: any)
	if not isExclusive(action) then
		return
	end
	local character = action.baseSkill and action.baseSkill.character
	local key = actionKey(action)
	if not character or not key then
		return
	end
	local map = lastByCharacter[character]
	if not map or map[key] ~= action then
		return
	end
	map[key] = nil
	if next(map) == nil then
		lastByCharacter[character] = nil
	end
end

return {
	isExclusive = isExclusive,
	beforeStart = beforeStart,
	releaseIfOwner = releaseIfOwner,
}
