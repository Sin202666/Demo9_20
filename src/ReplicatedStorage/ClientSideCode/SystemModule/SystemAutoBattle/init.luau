--[[
	Module: SystemAutoBattle
	Description: 自动战斗客户端（收 Sync/结束、驱动 Scene 与 Session Bindable）
	Author: 程莘
	Created: 2026-09-22
	Last Modified: 2026-09-22

	功能：
	- OnSyncState：首包进场，后续快照刷 HUD；有 lastHit 时播攻击表现
	- OnBattleEnd：离场并通知 HUD
	- RequestStart / RequestAbort：发 Remote（Debug 入口）

	加载：
		local SystemAutoBattle = Utils.SystemAutoBattle
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local AutoBattleNet = Utils.AutoBattleNet
local Log = Utils.Log

local Scene = require(script.Scene)
local AttackFx = require(script.AttackFx)

local SystemAutoBattle = {}

local PHASE_FIGHTING = "Fighting"
local PHASE_ENDED = "Ended"

local _inited = false
local _snapshot: { [string]: any }? = nil
local _battleId: string? = nil

--[[
	广播本地 Session（HUD 订阅）
	@param snapshot table? - 快照
	@param endResult table? - 结束载荷
]]
local function _fireLocal(snapshot: { [string]: any }?, endResult: { [string]: any }?)
	AutoBattleNet.FireSessionChanged(snapshot, endResult)
end

--[[
	Manager 调用：客户端懒初始化
]]
function SystemAutoBattle.InitLocal()
	if _inited then
		return
	end
	_inited = true
	AttackFx.BindUnitResolver(function(side: string, slot: number): Model?
		return Scene.GetUnitModel(side, slot)
	end)
end

--[[
	请求开始自动战斗（C→S）
]]
function SystemAutoBattle.RequestStart()
	AutoBattleNet.ReqStart:FireServer()
end

--[[
	请求中止自动战斗（C→S）
]]
function SystemAutoBattle.RequestAbort()
	AutoBattleNet.ReqAbort:FireServer()
end

--[[
	收服务端 SyncState
	@param payload any - 快照表
]]
function SystemAutoBattle.OnSyncState(payload: any)
	if type(payload) ~= "table" then
		return
	end
	local battleId = payload.battleId
	if type(battleId) ~= "string" then
		return
	end

	_snapshot = payload
	local phase = payload.phase
	if phase == PHASE_FIGHTING then
		if _battleId ~= battleId then
			_battleId = battleId
			local ok = Scene.Enter(payload)
			if not ok then
				Log.warn("SystemAutoBattle: Scene.Enter 失败", battleId)
			end
		end
		if type(payload.lastHits) == "table" and #payload.lastHits > 0 then
			for i, hit in ipairs(payload.lastHits) do
				local delaySec = (i - 1) * 0.05
				if delaySec <= 0 then
					AttackFx.PlayFromLastHit(hit)
				else
					task.delay(delaySec, function()
						AttackFx.PlayFromLastHit(hit)
					end)
				end
			end
		elseif type(payload.lastHit) == "table" then
			AttackFx.PlayFromLastHit(payload.lastHit)
		end
		_fireLocal(payload, nil)
	elseif phase == PHASE_ENDED then
		_fireLocal(payload, nil)
	end
end

--[[
	收服务端 BattleEnd
	@param payload any - 结束载荷
]]
function SystemAutoBattle.OnBattleEnd(payload: any)
	if type(payload) ~= "table" then
		payload = {}
	end
	local snap = _snapshot
	if type(snap) == "table" then
		snap.phase = PHASE_ENDED
	end
	_fireLocal(snap, payload)
	AttackFx.Invalidate()
	Scene.Leave()
	_battleId = nil
	_snapshot = nil
	Log.print(
		string.format(
			"SystemAutoBattle: 战斗结束 winner=%s reason=%s",
			tostring(payload.winner),
			tostring(payload.reason)
		)
	)
end

--[[
	是否本地在战
	@return boolean - true 表示在战
]]
function SystemAutoBattle.IsLocalInBattle(): boolean
	return _battleId ~= nil and Scene.IsActive()
end

--[[
	获取最近快照（只读）
	@return table? - 快照
]]
function SystemAutoBattle.GetLocalSnapshot(): { [string]: any }?
	return _snapshot
end

return SystemAutoBattle
