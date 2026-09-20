--[[
	Module: SkillReleaseCrossCheck
	Description: 组技能释放交叉检查（按 characterId 的 active 登记；仅服运行时）
	Author: 林奥宇
	Created: 2026-07-29
	Last Modified: 2026-08-31

	框架触发（勿改）：GroupSkillServer.requestRelease 校验通过后 -> runAll(ctx)

	业务 SkillModule 接入见 SkillCommon.beginCrossCheck（首次调用自动 registerProvider）。
	范例：SkillModule/Fluorescence1.luau

	本文件在 SystemSkillRuntime，与 GroupSkillServer 同迁。无双端业务分支。
]]

export type OtherGroupSkillReleaseContext = {
	characterId: number,
	characterType: string,
	incomingGroupSkillName: string,
	incomingSlotIndex: number?,
}

export type SkillReleaseCrossCheckFn = (ctx: OtherGroupSkillReleaseContext) -> ()

export type SkillReleaseCrossCheckProvider = {
	checkOnOtherGroupSkillRelease: SkillReleaseCrossCheckFn,
}

export type ActiveSessionHandle = any

type ActiveEntry = {
	handle: ActiveSessionHandle,
	provider: SkillReleaseCrossCheckProvider,
}

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Log = Utils.Log

local registeredProviders: { [SkillReleaseCrossCheckProvider]: boolean } = {}
local activeByCharacterId: { [number]: { ActiveEntry } } = {}

local SkillReleaseCrossCheck = {}

--[[
	取出 provider 的检查函数
	@param provider SkillReleaseCrossCheckProvider - 已登记的 provider
	@return SkillReleaseCrossCheckFn? - 检查函数；缺失则为 nil
]]
local function _getCheckFn(provider: SkillReleaseCrossCheckProvider): SkillReleaseCrossCheckFn?
	local fn = provider.checkOnOtherGroupSkillRelease
	if type(fn) == "function" then
		return fn
	end
	return nil
end

--[[
	按末位交换删除 list[index]
	@param list { ActiveEntry } - 该角色的 active 列表
	@param index number - 待删下标
]]
local function _removeEntryAt(list: { ActiveEntry }, index: number)
	local last = #list
	if index < last then
		list[index] = list[last]
	end
	list[last] = nil
end

--[[
	按 sessionHandle 查找下标
	@param list { ActiveEntry } - 该角色的 active 列表
	@param handle ActiveSessionHandle - 会话句柄（通常为 BaseSkillServer 实例）
	@return number? - 1-based 下标；未找到则为 nil
]]
local function _findEntryIndex(list: { ActiveEntry }, handle: ActiveSessionHandle): number?
	for i, entry in ipairs(list) do
		if entry.handle == handle then
			return i
		end
	end
	return nil
end

--[[
	模块级一次登记 provider；require 本模块的 SkillModule 在 return 前调用。
	同 module table 重复调用安全。
	@param provider SkillReleaseCrossCheckProvider - 须含 checkOnOtherGroupSkillRelease
]]
function SkillReleaseCrossCheck.registerProvider(provider: SkillReleaseCrossCheckProvider)
	if registeredProviders[provider] then
		return
	end
	if _getCheckFn(provider) == nil then
		Log.warn("[SkillReleaseCrossCheck] registerProvider 跳过：缺少 checkOnOtherGroupSkillRelease")
		return
	end
	registeredProviders[provider] = true
end

--[[
	实例级开始：该角色有一次进行中的、需被检查的技能实例。
	sessionHandle 推荐 BaseSkillServer 实例；与 unregisterActive 必须配对。
	@param characterId number - 角色 UserId 或 NPC id
	@param sessionHandle ActiveSessionHandle - 会话句柄
	@param provider SkillReleaseCrossCheckProvider - 检查提供者
]]
function SkillReleaseCrossCheck.registerActive(
	characterId: number,
	sessionHandle: ActiveSessionHandle,
	provider: SkillReleaseCrossCheckProvider
)
	if type(characterId) ~= "number" or sessionHandle == nil then
		return
	end
	if not registeredProviders[provider] then
		SkillReleaseCrossCheck.registerProvider(provider)
	end
	if not registeredProviders[provider] then
		return
	end

	local list = activeByCharacterId[characterId]
	if not list then
		list = {}
		activeByCharacterId[characterId] = list
	end

	local existing = _findEntryIndex(list, sessionHandle)
	if existing then
		_removeEntryAt(list, existing)
	end

	table.insert(list, {
		handle = sessionHandle,
		provider = provider,
	})
end

--[[
	实例级结束：onEndServer / 卸槽 destroy 后必须调用；漏调会导致 runAll 空跑或逻辑错误。
	@param characterId number - 角色 UserId 或 NPC id
	@param sessionHandle ActiveSessionHandle - 与 registerActive 配对的句柄
]]
function SkillReleaseCrossCheck.unregisterActive(characterId: number, sessionHandle: ActiveSessionHandle)
	if type(characterId) ~= "number" or sessionHandle == nil then
		return
	end
	local list = activeByCharacterId[characterId]
	if not list then
		return
	end
	local index = _findEntryIndex(list, sessionHandle)
	if not index then
		return
	end
	_removeEntryAt(list, index)
	if #list == 0 then
		activeByCharacterId[characterId] = nil
	end
end

--[[
	玩家离场兜底（SystemPlayerSkill PlayerRemoving 已调用）。
	@param characterId number - 角色 UserId
]]
function SkillReleaseCrossCheck.clearCharacter(characterId: number)
	if type(characterId) ~= "number" then
		return
	end
	activeByCharacterId[characterId] = nil
end

--[[
	调试：该 character 是否仍有 active 会话。
	@param characterId number - 角色 UserId 或 NPC id
	@return boolean - 仍有 active 则为 true
]]
function SkillReleaseCrossCheck.hasActiveForCharacter(characterId: number): boolean
	local list = activeByCharacterId[characterId]
	return list ~= nil and #list > 0
end

--[[
	框架专用：该玩家即将 release 其它组技能时，只遍历 ctx.characterId 的 active 列表。
	@param ctx OtherGroupSkillReleaseContext - 即将释放的组技能上下文
]]
function SkillReleaseCrossCheck.runAll(ctx: OtherGroupSkillReleaseContext)
	if type(ctx.characterId) ~= "number" then
		return
	end
	local list = activeByCharacterId[ctx.characterId]
	if not list or #list == 0 then
		return
	end

	for i = #list, 1, -1 do
		local entry = list[i]
		if entry then
			local checkFn = _getCheckFn(entry.provider)
			if checkFn then
				checkFn(ctx)
			end
		end
	end
end

return SkillReleaseCrossCheck
