--[[
	Module: EnemyLogicalSync
	Description: 逻辑怪白名单定向同步（SPAWN / TRANSFORM 20Hz / STATE / DEATH）
	Author: 林奥宇
	Created: 2026-08-12
	Last Modified: 2026-08-28

	功能：
	- spawnToWhitelist：创建后即时 SPAWN（含 hp/maxHp，供客 Humanoid 通用血条）
	- tick：固定 20Hz 下发 dirty TRANSFORM（由 EnemySim.step 调用；对齐客机插值缓冲）
	- pushState：扣血后即时下发 HP / CombatReady（客写 LocalMonster.Humanoid）
	- death：DEATH 后由门面移除 Store（客户端 Destroy）
	- allowedPlayerIds 为空：向全员 FireClient（L1 全开约定）

	加载：
		local EnemyLogicalSync = Utils.EnemyLogicalSync
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local NetWork = Utils.NetWork
local NetMsg = Utils.NetMsg
local EnemyLogicalTypes = Utils.EnemyLogicalTypes
local EnemyLogicalStore = Utils.EnemyLogicalStore

local EnemyLogicalSync = {}

-- 20Hz：客机 ~100ms 插值缓冲可稳定落在两包之间；10Hz+短缓冲会频繁外推导致回拉抖动
local TRANSFORM_INTERVAL = 0.05
local _accum = 0
local _inited = false

--[[
	解析下发目标：有白名单用白名单；空则全员
	@param allowedPlayerIds { number }? - UserId 列表；空/nil 表示全员
	@return { Player } - 当前在线的下发目标
]]
local function _resolveTargets(allowedPlayerIds: { number }?): { Player }
	local result: { Player } = {}
	if type(allowedPlayerIds) == "table" and #allowedPlayerIds > 0 then
		for _, userId in ipairs(allowedPlayerIds) do
			local plr = Players:GetPlayerByUserId(userId)
			if plr then
				table.insert(result, plr)
			end
		end
		return result
	end
	for _, plr in ipairs(Players:GetPlayers()) do
		table.insert(result, plr)
	end
	return result
end

--[[
	向目标列表 FireClient
	@param targets { Player } - 下发目标列表
	@param msgName string - NetMsg 消息名
	@param payload any - Remote 载荷
]]
local function _fireTargets(targets: { Player }, msgName: string, payload: any)
	for _, plr in ipairs(targets) do
		NetWork.FireClient(plr, msgName, payload)
	end
end

--[[
	构建 SPAWN payload
	@param rec any - LogicalRecord
	@return table - SPAWN 载荷（id / cfgId / 位姿 / hp / moveState / t）
]]
local function _buildSpawnPayload(rec: any): any
	local px, py, pz, lx, ly, lz = EnemyLogicalTypes.packCFrame(rec.cframe)
	local moveState = "idle"
	local entity = rec.entity
	if type(entity) == "table" and type(entity.moveState) == "string" and entity.moveState ~= "" then
		moveState = entity.moveState
	end
	return {
		id = rec.id,
		cfgId = rec.cfgId,
		posX = px,
		posY = py,
		posZ = pz,
		lookX = lx,
		lookY = ly,
		lookZ = lz,
		combatReady = rec.combatReady,
		hp = rec.hp,
		maxHp = rec.maxHp,
		allowedPlayerIds = rec.allowedPlayerIds,
		moveState = moveState,
		t = Workspace:GetServerTimeNow(),
	}
end

--[[
	构建 TRANSFORM payload
	@param rec any - LogicalRecord
	@return table - TRANSFORM 载荷（id / 位姿 / moveState / t）
]]
local function _buildTransformPayload(rec: any): any
	local px, py, pz, lx, ly, lz = EnemyLogicalTypes.packCFrame(rec.cframe)
	local moveState = "idle"
	local entity = rec.entity
	if type(entity) == "table" and type(entity.moveState) == "string" and entity.moveState ~= "" then
		moveState = entity.moveState
	end
	return {
		id = rec.id,
		posX = px,
		posY = py,
		posZ = pz,
		lookX = lx,
		lookY = ly,
		lookZ = lz,
		moveState = moveState,
		t = Workspace:GetServerTimeNow(),
	}
end

--[[
	幂等 Init（L2 无独立 Heartbeat；节流在 tick）
]]
function EnemyLogicalSync.Init()
	if not RunService:IsServer() then
		return
	end
	_inited = true
	_accum = 0
end

--[[
	创建后向白名单/全员下发 SPAWN
	@param rec any - LogicalRecord
]]
function EnemyLogicalSync.spawnToWhitelist(rec: any)
	if not rec then
		return
	end
	local targets = _resolveTargets(rec.allowedPlayerIds)
	_fireTargets(targets, NetMsg.ENEMY_LOGICAL_SPAWN, _buildSpawnPayload(rec))
	rec.dirtyTransform = false
end

--[[
	下发 HP / CombatReady 等轻量状态（供客 Humanoid 血条）
	@param rec any - LogicalRecord
]]
function EnemyLogicalSync.pushState(rec: any)
	if not rec then
		return
	end
	local targets = _resolveTargets(rec.allowedPlayerIds)
	_fireTargets(targets, NetMsg.ENEMY_LOGICAL_STATE, {
		id = rec.id,
		combatReady = rec.combatReady,
		hp = rec.hp,
		maxHp = rec.maxHp,
	})
end

--[[
	下发 DEATH（客户端 Destroy）
	@param rec any - LogicalRecord
]]
function EnemyLogicalSync.death(rec: any)
	if not rec then
		return
	end
	local targets = _resolveTargets(rec.allowedPlayerIds)
	_fireTargets(targets, NetMsg.ENEMY_LOGICAL_DEATH, {
		id = rec.id,
	})
end

--[[
	20Hz 脏 Transform 刷新（由 EnemySim.step 调用）
	@param deltaTime number - 帧间隔
]]
function EnemyLogicalSync.tick(deltaTime: number)
	if not _inited then
		return
	end
	_accum += deltaTime
	if _accum < TRANSFORM_INTERVAL then
		return
	end
	-- 保留余量，避免帧率不整除时相位漂移把实际频率压低
	_accum -= TRANSFORM_INTERVAL
	if _accum > TRANSFORM_INTERVAL then
		_accum = 0
	end

	EnemyLogicalStore.forEach(function(rec)
		if not rec.alive or not rec.dirtyTransform then
			return
		end
		local targets = _resolveTargets(rec.allowedPlayerIds)
		_fireTargets(targets, NetMsg.ENEMY_LOGICAL_TRANSFORM, _buildTransformPayload(rec))
		rec.dirtyTransform = false
	end)
end

return EnemyLogicalSync