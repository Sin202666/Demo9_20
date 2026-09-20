--[[
	Module: SkillActionLock
	Description: 技能动作占闸（多 holder 的 BlendPolicy 聚合 → 直调 ActionArbiter.Acquire/Release）
	Author: Dev-Framework
	Created: 2026-07-28
	Last Modified: 2026-07-31

	多 SkillAction（Animation / DashStyleRoll 等）重叠时：
	- turn_On(character, blendPolicy?)：登记 holder；聚合后 Acquire/刷新（ownerId = Bridge:SkillActionLock）
	- turn_Off(character, holderId?)：移除 holder；空则 Release，否则刷新聚合
	- forceRelease(character)：清空该角色全部 holder 并放闸（Init/硬取消兜底，防孤儿占闸卡死 loco）

	聚合：suppressLoco / pauseBaseTracks 对所有 holder 的 ExpandBlendPolicy 做 OR；
	facingOwner 取最后一个非 nil 声明（无则 Animate）。

	缺省 blendPolicy = Override（兼容翻滚/旧技能冻腿）。
	soft-merge：Action.Init 必须先 Off/Stop 再清标志，禁止只清 _actionLockHeld 留下孤儿 holder。
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local ActionArbiter = Utils.ActionArbiter

local module = {}

local DEFAULT_POLICY = "Override"

local _holders: { [Instance]: { { id: number, policy: string } } } = {}
local _tokens: { [Instance]: string } = {}
local _cleanupConns: { [Instance]: RBXScriptConnection } = {}
local _holderSeq = 0

--[[
	解析计数键与是否允许占闸（仅本地玩家角色 / NPC；他人玩家跳过）
	@param character Model - 技能主体
	@return (Instance?, Model?) - countKey, character；无效则双 nil
]]
local function _resolveTargets(character: Model): (Instance?, Model?)
	if not character then
		return nil, nil
	end
	local plr = Players:GetPlayerFromCharacter(character)
	if plr then
		local localPlayer = Players.LocalPlayer
		if plr == localPlayer then
			return localPlayer, character
		end
		return nil, nil
	end
	return character, character
end

--[[
	聚合 holders → Acquire 字段
	@param holders { { id, policy } }
	@return (boolean, boolean, string) - suppress, pause, facingOwner
]]
local function _aggregatePolicies(holders: { { id: number, policy: string } }): (boolean, boolean, string)
	local orSuppress = false
	local orPause = false
	local facing: string? = nil
	for _, h in ipairs(holders) do
		local expanded = ActionArbiter.ExpandBlendPolicy(h.policy)
		orSuppress = orSuppress or (expanded.suppressLoco == true)
		orPause = orPause or (expanded.pauseBaseTracks == true)
		if expanded.facingOwner ~= nil then
			facing = expanded.facingOwner
		end
	end
	return orSuppress, orPause, facing or ActionArbiter.FacingOwner.Animate
end

--[[
	按当前 holders 刷新或释放闸
	@param countKey Instance
	@param character Model
]]
local function _refreshGate(countKey: Instance, character: Model)
	local holders = _holders[countKey]
	local arbiter = ActionArbiter.GetForCharacter(character)
	if not arbiter then
		_tokens[countKey] = nil
		return
	end

	if not holders or #holders == 0 then
		local token = _tokens[countKey]
		_tokens[countKey] = nil
		if type(token) == "string" and token ~= "" then
			arbiter:Release(token)
		end
		-- 兜底：清掉同 owner 残留（token 丢失 / 双路径 Acquire）
		arbiter:ReleaseByOwner(ActionArbiter.BridgeOwnerId.SkillActionLock)
		return
	end

	local suppressLoco, pauseBaseTracks, facingOwner = _aggregatePolicies(holders)
	local token = arbiter:Acquire({
		ownerId = ActionArbiter.BridgeOwnerId.SkillActionLock,
		priority = ActionArbiter.Priority.Skill,
		suppressLoco = suppressLoco,
		pauseBaseTracks = pauseBaseTracks,
		facingOwner = facingOwner :: any,
		cameraOwner = ActionArbiter.CameraOwner.Default,
		reason = "SkillActionLock",
	})
	_tokens[countKey] = token
end

--[[
	强制清零并放闸，断开清理监听
	@param countKey Instance
	@param character Model
]]
local function _forceClear(countKey: Instance, character: Model)
	_holders[countKey] = nil
	local conn = _cleanupConns[countKey]
	if conn then
		conn:Disconnect()
		_cleanupConns[countKey] = nil
	end
	_refreshGate(countKey, character)
end

--[[
	角色销毁时清闸
	@param countKey Instance
	@param character Model
]]
local function _ensureCleanup(countKey: Instance, character: Model)
	if _cleanupConns[countKey] then
		return
	end
	_cleanupConns[countKey] = character.AncestryChanged:Connect(function(_child: Instance, parent: Instance?)
		if parent == nil then
			_forceClear(countKey, character)
		end
	end)
end

--[[
	当前是否仍持有动作闸；供 soft-merge adopt
	@param character Model - 技能主体
	@return boolean
]]
function module.isHeld(character: Model): boolean
	if not character then
		return false
	end
	local countKey = _resolveTargets(character)
	if not countKey then
		return false
	end
	local holders = _holders[countKey]
	return holders ~= nil and #holders > 0
end

--[[
	开启动作锁（登记 holder 并刷新聚合闸）
	@param character Model - 技能主体
	@param blendPolicy string? - Override/Overlay/FacingOnly/React；默认 Override
	@return number? - holderId，供 turn_Off；他人角色/非客户端返回 nil
]]
function module.turn_On_Action_Lock(character: Model, blendPolicy: string?): number?
	if not character then
		return nil
	end
	if not RunService:IsClient() then
		return nil
	end

	local countKey, charModel = _resolveTargets(character)
	if not countKey or not charModel then
		return nil
	end

	local policy = blendPolicy
	if type(policy) ~= "string" or policy == "" then
		policy = DEFAULT_POLICY
	end

	_holderSeq += 1
	local holderId = _holderSeq
	local list = _holders[countKey]
	if not list then
		list = {}
		_holders[countKey] = list
	end
	table.insert(list, { id = holderId, policy = policy })
	_ensureCleanup(countKey, charModel)
	_refreshGate(countKey, charModel)
	return holderId
end

--[[
	关闭动作锁（移除 holder；空则放闸，否则刷新聚合）
	@param character Model - 技能主体
	@param holderId number? - turn_On 返回值；nil 时移除最后一个（兼容旧调用）
]]
function module.turn_Off_Action_Lock(character: Model, holderId: number?)
	if not character then
		return
	end
	if not RunService:IsClient() then
		return
	end

	local countKey, charModel = _resolveTargets(character)
	if not countKey or not charModel then
		return
	end

	local list = _holders[countKey]
	if not list or #list == 0 then
		-- 无 holder 仍兜底放闸，避免 token/标志不同步卡死 loco
		_refreshGate(countKey, charModel)
		return
	end

	local removed = false
	if type(holderId) == "number" then
		for i = #list, 1, -1 do
			if list[i].id == holderId then
				table.remove(list, i)
				removed = true
				break
			end
		end
		-- holderId 未命中：不误删其它 holder，但仍刷新快照
		if not removed then
			_refreshGate(countKey, charModel)
			return
		end
	else
		table.remove(list, #list)
		removed = true
	end

	if #list == 0 then
		_holders[countKey] = nil
		local conn = _cleanupConns[countKey]
		if conn then
			conn:Disconnect()
			_cleanupConns[countKey] = nil
		end
	end
	_refreshGate(countKey, charModel)
end

--[[
	清空该角色全部技能闸 holder 并放闸（Init / 硬取消兜底）
	@param character Model - 技能主体
]]
function module.forceRelease(character: Model)
	if not character then
		return
	end
	if not RunService:IsClient() then
		return
	end
	local countKey, charModel = _resolveTargets(character)
	if not countKey or not charModel then
		return
	end
	_forceClear(countKey, charModel)
end

return module