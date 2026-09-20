--[[
	Module: NPCCosmeticHit
	Description: 逻辑怪「仅表现」受击动画服写口（Nearby 下行；客播轨在 ToolSystem stub）
	Author: 林奥宇
	Created: 2026-08-17
	Last Modified: 2026-08-31

	能力：
	- tryPlayLogical：读 enemyConf.animHitName，写 rec CD，Nearby FireClient(NPC_COSMETIC_HIT)
	- handleIncoming：服 no-op（客侧 ToolSystem 实现）
	- 短 CD 防刷；不进 CombatWorld；不做完整 Hurt 硬直；不写位姿/速度

	与同类：
	- 权威通知仅本文件。Utils.NPCCosmeticHit 服务端优先加载本模块；客户端回落 ToolSystem 播轨
	- 由 SystemEnemy.Hit 在 Despawn 前调用；不并入 SystemEnemy 函数体
	- 不绑 Remote（经 NetWork.FireClient）；无 Init

	加载：
		local NPCCosmeticHit = Utils.NPCCosmeticHit
		NPCCosmeticHit.tryPlayLogical(rec, realDmg, skillId)
]]

local Workspace = game:GetService("Workspace")

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Players = Utils.Players
local NetWork = Utils.NetWork
local NetMsg = Utils.NetMsg
local CfgFind = Utils.CfgFind

local NPCCosmeticHit = {}

local DEFAULT_NOTIFY_RANGE_STUDS = 100
local DEFAULT_COSMETIC_HIT_CD = 0.3
local DEFAULT_FADE_TIME = 0.08
local DEFAULT_ANIM_SPEED = 1

--[[
	逻辑怪扣血后尝试下发 cosmetic 受击轨（须在 Despawn 前调用）
	@param rec table - LogicalRecord（含 id/cfgId；可写 _lastCosmeticHitAnimServerTime）
	@param realDmg number - 实际伤害；≤0 不下发
	@param skillId number? - 技能 ID；可进 payload.skillid
]]
function NPCCosmeticHit.tryPlayLogical(rec: any, realDmg: number, skillId: number?)
	if type(rec) ~= "table" or realDmg <= 0 then
		return
	end
	if typeof(rec.id) ~= "number" or typeof(rec.cfgId) ~= "number" then
		return
	end

	local cfg = CfgFind.GetCfgByNameAndID("enemyConf", rec.cfgId)
	if not cfg then
		return
	end
	if cfg.hitstunDisabled == 1 then
		return
	end

	local animName = cfg.animHitName
	if typeof(animName) ~= "string" or animName == "" then
		return
	end

	local now = Workspace:GetServerTimeNow()
	local last = rec._lastCosmeticHitAnimServerTime
	if typeof(last) == "number" and (now - last) < DEFAULT_COSMETIC_HIT_CD then
		return
	end
	rec._lastCosmeticHitAnimServerTime = now

	local hitPos = nil
	if typeof(rec.cframe) == "CFrame" then
		hitPos = rec.cframe.Position
	end

	local payload = {
		monsterId = tostring(rec.id),
		animName = animName,
		fadeTime = DEFAULT_FADE_TIME,
		speed = DEFAULT_ANIM_SPEED,
		skillid = skillId,
	}

	for _, plr in Players:GetPlayers() do
		local character = plr.Character
		local hrp = character and character:FindFirstChild("HumanoidRootPart")
		if hrp and hrp:IsA("BasePart") then
			if hitPos == nil or (hrp.Position - hitPos).Magnitude <= DEFAULT_NOTIFY_RANGE_STUDS then
				NetWork.FireClient(plr, NetMsg.NPC_COSMETIC_HIT, payload)
			end
		end
	end
end

--[[
	客户端播轨入口；服 no-op
	@param _payload table - { monsterId: string, animName: string, fadeTime: number?, speed: number?, skillid: number? }
]]
function NPCCosmeticHit.handleIncoming(_payload: any)
end

return NPCCosmeticHit
