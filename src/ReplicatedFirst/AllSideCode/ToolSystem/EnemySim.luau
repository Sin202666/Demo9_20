--[[
	Module: EnemySim
	Description: 逻辑怪批处理仿真（CombatWorld.Phase.EnemySim；禁止每怪 Heartbeat）
	Author: 林奥宇
	Created: 2026-08-12
	Last Modified: 2026-08-28

	功能：
	- Init：向 CombatWorld 注册唯一 EnemySim tick（Phase=15）；不调用其它模块 Init
	- add / remove：按逻辑怪 id 加入/移出批处理集合
	- step：LogicalAirborne → LogicalDisplace →（锁窗冻结命令计时）→ Command.tick → Ranger（仅 Auto）→ PathFollow.tick → applyDesired → integrate → flushCompute → Sync.tick（20Hz）
	- destroy：从 CombatWorld 注销（测试用；Shutdown 为别名）

	约束：
	- 禁止每怪 Heartbeat；AI/位移/受击击退/浮空只走本批处理
	- 击退与移速锁定尾窗、浮空/落地硬直内不跑 Ranger / 不 tick 命令超时
	- 浮空期间不走 LogicEntityMotion.integrate（禁贴地）
	- 锁窗保留 _driveMode / _desiredPos；clearGoal 只清积分点
	- Init 内禁止 CombatWorld.Init / EnemyLogicalSync.Init（结构 §3.5）；由 UpdateManager 先调

	加载：
		local EnemySim = Utils.EnemySim
		-- 启动链（UpdateManager，怪物系统启用时）：
		--   CombatWorld.Init() → EnemyLogicalSync.Init() → SystemEnemy.Init() → EnemySim.Init（只 register）
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local RunService = Utils.RunService
local CombatWorld = Utils.CombatWorld
local EnemyLogicalStore = Utils.EnemyLogicalStore
local EnemyLogicalSync = Utils.EnemyLogicalSync
local RangerAi = Utils.RangerAi
local LogicalMoveCommand = Utils.LogicalMoveCommand
local LogicalPathFollow = Utils.LogicalPathFollow
local LogicEntityMotion = Utils.LogicEntityMotion
local LogicalDisplace = Utils.LogicalDisplace
local LogicalAirborne = Utils.LogicalAirborne

local EnemySim = {}

local TICK_ID = "EnemySim:Batch"
local _worldHandle: any = nil
local _aliveIds: { [number]: boolean } = {}
local _idList: { number } = {}
local _listDirty = false

-- ========================================
-- 私有函数
-- ========================================

--[[
	重建有序 id 列表
]]
local function _rebuildIdList()
	table.clear(_idList)
	for id, on in pairs(_aliveIds) do
		if on then
			table.insert(_idList, id)
		end
	end
	_listDirty = false
end

--[[
	确保 id 列表最新
]]
local function _ensureIdList()
	if _listDirty then
		_rebuildIdList()
	end
end

-- ========================================
-- 公共函数
-- ========================================

--[[
	向 CombatWorld 注册批处理 tick（幂等）。不调用其它模块 Init。
	须由 Manager 先完成 CombatWorld.Init、EnemyLogicalSync.Init、SystemEnemy.Init（UpdateManager）。
	客机早退，避免 AllSide 被误调时挂上仿真。
]]
function EnemySim.Init()
	if not RunService:IsServer() then
		return
	end
	if _worldHandle then
		return
	end
	_worldHandle = CombatWorld.register(TICK_ID, function(deltaTime: number)
		EnemySim.step(deltaTime)
	end, CombatWorld.Phase.EnemySim)
end

--[[
	从 CombatWorld 注销（幂等；一般仅测试）
]]
function EnemySim.destroy()
	if _worldHandle then
		_worldHandle:Disconnect()
		_worldHandle = nil
	end
end

--- 测试别名，等同 destroy
EnemySim.Shutdown = EnemySim.destroy

--[[
	加入批处理
	@param id number - 逻辑怪运行时 id
]]
function EnemySim.add(id: number)
	local n = tonumber(id)
	if not n then
		return
	end
	if _aliveIds[n] then
		return
	end
	_aliveIds[n] = true
	_listDirty = true
end

--[[
	移出批处理
	@param id number - 逻辑怪运行时 id
]]
function EnemySim.remove(id: number)
	local n = tonumber(id)
	if not n then
		return
	end
	local rec = EnemyLogicalStore.get(n)
	if rec then
		LogicalPathFollow.invalidate(rec)
	end
	if not _aliveIds[n] then
		return
	end
	_aliveIds[n] = nil
	_listDirty = true
end

--[[
	是否在批处理中
	@param id number - 逻辑怪运行时 id
	@return boolean - 该 id 是否在批处理集合中
]]
function EnemySim.has(id: number): boolean
	return _aliveIds[tonumber(id) or 0] == true
end

--[[
	当前批处理数量
	@return number - 当前批处理存活数量
]]
function EnemySim.getCount(): number
	local n = 0
	for _, on in pairs(_aliveIds) do
		if on then
			n += 1
		end
	end
	return n
end

--[[
	一帧批处理（由 CombatWorld Phase.EnemySim 驱动）
	@param deltaTime number - 帧间隔秒
]]
function EnemySim.step(deltaTime: number)
	_ensureIdList()
	for i = 1, #_idList do
		local id = _idList[i]
		if not _aliveIds[id] then
			continue
		end
		local rec = EnemyLogicalStore.get(id)
		if not rec or not rec.alive then
			_aliveIds[id] = nil
			_listDirty = true
			continue
		end
		-- 浮空优先：积分 Y/水平，跳过贴地 integrate（对照鬼泣5 Launch/Juggle）
		if LogicalAirborne and LogicalAirborne.step and LogicalAirborne.step(rec, deltaTime) then
			continue
		end
		-- 受击位移窗：只步进击退，跳过 AI/普通 integrate（对照 RP18）
		if LogicalDisplace and LogicalDisplace.step and LogicalDisplace.step(rec, deltaTime) then
			continue
		end
		-- 浮空落地硬直 / 击退尾窗：禁止追击与命令计时（保留 _driveMode / _desiredPos）
		local airLocked = LogicalAirborne and LogicalAirborne.isAirLocked and LogicalAirborne.isAirLocked(rec)
		local moveLocked = LogicalDisplace and LogicalDisplace.isMoveLocked and LogicalDisplace.isMoveLocked(rec)
		if airLocked or moveLocked then
			local entity = rec.entity
			if type(entity) == "table" then
				local prevMove = entity.moveState
				LogicEntityMotion.clearGoal(entity)
				entity._chaseMode = nil
				if prevMove ~= "idle" then
					entity.moveState = "idle"
					rec.dirtyTransform = true
				end
			end
			continue
		end
		local entity = rec.entity
		local prevMove = if type(entity) == "table" then entity.moveState else nil
		LogicalMoveCommand.tick(rec, deltaTime)
		if not LogicalMoveCommand.shouldSkipAi(rec) and RangerAi.isRanger(rec) then
			RangerAi.step(rec, deltaTime)
		end
		LogicalPathFollow.tick(rec, deltaTime)
		LogicalMoveCommand.applyDesired(rec)
		LogicEntityMotion.integrate(rec, deltaTime)
		-- moveState 变化也要标脏，否则站停后客户端仍播走/跑
		if type(entity) == "table" and entity.moveState ~= prevMove then
			rec.dirtyTransform = true
		end
	end
	LogicalPathFollow.flushCompute()
	EnemyLogicalSync.tick(deltaTime)
end

return EnemySim