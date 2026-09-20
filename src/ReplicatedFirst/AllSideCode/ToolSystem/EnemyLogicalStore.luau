--[[
	Module: EnemyLogicalStore
	Description: 逻辑怪纯数据权威表（cframe + bboxSize；无伤害用 Part）
	Author: 林奥宇
	Created: 2026-08-12
	Last Modified: 2026-09-01

	功能：
	- put / get / remove / forEach / count：运行时 LogicalRecord
	- setCFrame：更新权威位姿并标脏（供 L2 Sync）；唯一位姿写原语
	- setCombatReady / setHp：战斗门控与生命
	- bboxSize：配表优先、Extents 兜底（由 SystemEnemy 创建时写入）

	模块关系：
	- 位姿写口只经 setCFrame：LogicEntityMotion.integrate、LogicalDisplace.step、LogicalAirborne.step
	- RangerAi / LogicalPathFollow / LogicalMoveCommand 只写 entity 意图，不调 setCFrame
	- 客户端 SystemLogicalEnemy 只插值 LocalMonster，禁止 mutate 本表

	约束：
	- 仅服务端写入；AllSide 无 IsServer 门禁，靠调用约定（与 EnemySim 同类）
	- get / forEach 返回活记录：调用方禁止当只读快照改无关字段；位姿只经 setCFrame，生命只经 setHp
	- 不持有 LocalMonster；不进 CombatWorld（由 EnemySim 批处理读本表）

	加载：
		local EnemyLogicalStore = Utils.EnemyLogicalStore
		local rec = EnemyLogicalStore.get(id)
		EnemyLogicalStore.setCFrame(id, cf)
]]

local EnemyLogicalStore = {}

--============================================================================--
-- 类型 / 私有表
--============================================================================--

export type LogicalRecord = {
	id: number,
	cfgId: number,
	cframe: CFrame,
	bboxSize: Vector3,
	allowedPlayerIds: { number },
	allowedSet: { [number]: true },
	combatReady: boolean,
	hp: number,
	maxHp: number,
	modelName: string,
	ai: string,
	dirtyTransform: boolean,
	alive: boolean,
	entity: any?,
}

local byId: { [number]: LogicalRecord } = {}

--============================================================================--
-- 公共 API
--============================================================================--

--[[
	写入一条逻辑怪记录
	@param record LogicalRecord - 完整记录（活引用，随后 get 仍指向同一表）
]]
function EnemyLogicalStore.put(record: LogicalRecord)
	byId[record.id] = record
end

--[[
	按 id 查询活记录（不是深拷贝；位姿请走 setCFrame，生命请走 setHp）
	@param id number - 运行时 id
	@return LogicalRecord? - 活记录；不存在则 nil
]]
function EnemyLogicalStore.get(id: number): LogicalRecord?
	return byId[id]
end

--[[
	移除记录
	@param id number - 运行时 id
	@return LogicalRecord? - 被移除的活记录（调用方仍可读最后一帧）
]]
function EnemyLogicalStore.remove(id: number): LogicalRecord?
	local rec = byId[id]
	byId[id] = nil
	return rec
end

--[[
	遍历全部活记录（回调内禁止当只读快照改无关字段）
	@param fn (LogicalRecord) -> () - 回调，参数为活记录
]]
function EnemyLogicalStore.forEach(fn: (LogicalRecord) -> ())
	for _, rec in pairs(byId) do
		fn(rec)
	end
end

--[[
	当前记录数
	@return number - 条数
]]
function EnemyLogicalStore.count(): number
	local n = 0
	for _ in pairs(byId) do
		n += 1
	end
	return n
end

--[[
	更新逻辑 CFrame 并标脏（本表唯一位姿写原语）
	@param id number - 运行时 id
	@param cf CFrame - 新位姿
]]
function EnemyLogicalStore.setCFrame(id: number, cf: CFrame)
	local rec = byId[id]
	if not rec then
		return
	end
	rec.cframe = cf
	rec.dirtyTransform = true
	local entity = rec.entity
	if type(entity) == "table" then
		entity.pos = cf.Position
	end
end

--[[
	设置战斗就绪
	@param id number - 运行时 id
	@param ready boolean - 是否可受击
]]
function EnemyLogicalStore.setCombatReady(id: number, ready: boolean)
	local rec = byId[id]
	if not rec then
		return
	end
	rec.combatReady = ready == true
end

--[[
	设置当前生命（夹到 [0, maxHp]）
	@param id number - 运行时 id
	@param hp number - 新生命
]]
function EnemyLogicalStore.setHp(id: number, hp: number)
	local rec = byId[id]
	if not rec then
		return
	end
	local v = tonumber(hp) or 0
	rec.hp = math.clamp(v, 0, rec.maxHp)
end

--[[
	清空（仅测试 / 关卡卸载）
]]
function EnemyLogicalStore.clearForTests()
	table.clear(byId)
end

return EnemyLogicalStore
