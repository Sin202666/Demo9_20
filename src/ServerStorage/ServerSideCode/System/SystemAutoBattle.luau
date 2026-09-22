--[[
	Module: SystemAutoBattle
	Description: 自动战斗服务端权威 Session（随机阵容、实时 CD、共享血池、胜负结算）
	Author: 程莘
	Created: 2026-09-22
	Last Modified: 2026-09-22

	功能：
	- TryStart / TryAbort；战斗 Session 唯一权威
	- 双方各有放回随机 6 个 animeConf 单位；总血池 = Σ Hp
	- 单位按 Cd 独立冷却，就绪对对方总血池造成 Atk 伤害
	- CombatWorld 注册 tick；SyncState / BattleEnd 经 AutoBattleNet 下发
	- 无奖励、不改存档、不进 EnemySim

	边界：
	- 不绑 Remote（PlayerAutoBattleManager 路由）
	- 不写客户端场景 / UI
	- 仅 Dev/Studio 且 GameConfig.自动战斗.启用 时允许开战

	加载：
		local SystemAutoBattle = Utils.SystemAutoBattle
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local AutoBattleNet = Utils.AutoBattleNet
local CfgFind = Utils.CfgFind
local CombatWorld = Utils.CombatWorld
local EnumMgr = Utils.EnumMgr
local Log = Utils.Log
local Players = Utils.Players
local RunService = Utils.RunService
local SystemGameConfig = Utils.SystemGameConfig
local WorldUtil = Utils.WorldUtil

local SystemAutoBattle = {}

local SERVER_TYPE_DEV = "Dev"
local PHASE_FIGHTING = "Fighting"
local PHASE_ENDED = "Ended"
local SIDE_MY = "My"
local SIDE_ENEMY = "Enemy"
local WINNER_MY = "My"
local WINNER_ENEMY = "Enemy"
local WINNER_ABORT = "Abort"
local CFG_ENABLED = { "自动战斗", "启用" }
local CFG_TEAM_SIZE = { "自动战斗", "每队人数" }
local CFG_SYNC_THROTTLE = { "自动战斗", "同步节流秒" }
local DEFAULT_TEAM_SIZE = 6
local TICK_ID_PREFIX = "AutoBattle:"

type UnitState = {
	slot: number,
	animeId: number,
	atk: number,
	hp: number,
	cd: number,
	nextReady: number,
}

type TeamState = {
	hp: number,
	maxHp: number,
	units: { UnitState },
}

type Session = {
	battleId: string,
	phase: string,
	my: TeamState,
	enemy: TeamState,
	lastHit: { side: string, slot: number, damage: number }?,
	pendingHits: { { side: string, slot: number, damage: number } },
	tickHandle: any?,
	lastSyncAt: number,
	now: number,
}

local _sessions: { [Player]: Session } = {}
local _inited = false
local _battleSerial = 0

--[[
	是否允许自动战斗（配置启用 + Dev/Studio）
	@return boolean - true 表示允许
]]
local function _isBattleAllowed(): boolean
	if SystemGameConfig.GetValue(CFG_ENABLED) == false then
		return false
	end
	if WorldUtil.GetServerType() == SERVER_TYPE_DEV then
		return true
	end
	return RunService:IsStudio()
end

--[[
	读取每队人数
	@return number - 每队人数（至少 1）
]]
local function _getTeamSize(): number
	local n = tonumber(SystemGameConfig.GetValue(CFG_TEAM_SIZE))
	if not n or n < 1 then
		return DEFAULT_TEAM_SIZE
	end
	return math.floor(n)
end

--[[
	读取同步节流秒
	@return number - 节流秒；0 表示每次命中都同步
]]
local function _getSyncThrottle(): number
	local n = tonumber(SystemGameConfig.GetValue(CFG_SYNC_THROTTLE))
	if not n or n < 0 then
		return 0
	end
	return n
end

--[[
	收集 animeConf 全部可用 ID
	@return { number } - ID 列表；无配置时为空表
]]
local function _collectAnimeIds(): { number }
	local conf = CfgFind.GetCfgByName("animeConf")
	local ids: { number } = {}
	if type(conf) ~= "table" then
		return ids
	end
	for id, row in pairs(conf) do
		local numId = tonumber(id)
		if numId and type(row) == "table" then
			table.insert(ids, numId)
		end
	end
	table.sort(ids)
	return ids
end

--[[
	由配置构建单位状态
	@param slot number - 站位 1..N
	@param animeId number - animeConf 主键
	@param now number - 当前仿真时间（秒）
	@return UnitState? - 单位；配置缺失返回 nil
]]
local function _makeUnit(slot: number, animeId: number, now: number): UnitState?
	local cfg = CfgFind.FindCfgByID(animeId, EnumMgr.ItemType.Anime)
	if type(cfg) ~= "table" then
		return nil
	end
	local atk = tonumber(cfg.Atk) or 0
	local hp = tonumber(cfg.Hp) or 0
	local cd = tonumber(cfg.Cd) or 1
	if cd <= 0 then
		cd = 1
	end
	return {
		slot = slot,
		animeId = animeId,
		atk = atk,
		hp = hp,
		cd = cd,
		nextReady = now + cd,
	}
end

--[[
	有放回随机抽队
	@param rng Random - 随机源
	@param pool { number } - animeId 池
	@param teamSize number - 人数
	@param now number - 仿真时间
	@return TeamState? - 队伍；池空或构建失败返回 nil
]]
local function _rollTeam(rng: Random, pool: { number }, teamSize: number, now: number): TeamState?
	if #pool < 1 then
		return nil
	end
	local units: { UnitState } = {}
	local maxHp = 0
	for slot = 1, teamSize do
		local animeId = pool[rng:NextInteger(1, #pool)]
		local unit = _makeUnit(slot, animeId, now)
		if not unit then
			return nil
		end
		table.insert(units, unit)
		maxHp += unit.hp
	end
	if maxHp <= 0 then
		maxHp = 1
	end
	return {
		hp = maxHp,
		maxHp = maxHp,
		units = units,
	}
end

--[[
	构建下发快照（不含仿真内部 nextReady）
	@param session Session - 会话
	@return table - SyncState 载荷
]]
local function _buildSnapshot(session: Session): { [string]: any }
	local function packTeam(team: TeamState): { [string]: any }
		local units = {}
		for _, u in ipairs(team.units) do
			table.insert(units, {
				slot = u.slot,
				animeId = u.animeId,
			})
		end
		return {
			hp = team.hp,
			maxHp = team.maxHp,
			units = units,
		}
	end
	return {
		battleId = session.battleId,
		phase = session.phase,
		my = packTeam(session.my),
		enemy = packTeam(session.enemy),
		lastHit = session.lastHit,
		lastHits = session.pendingHits,
	}
end

--[[
	向客户端同步快照
	@param player Player - 玩家
	@param session Session - 会话
]]
local function _sync(player: Player, session: Session)
	session.lastSyncAt = session.now
	local snapshot = _buildSnapshot(session)
	AutoBattleNet.SyncState:FireClient(player, snapshot)
	table.clear(session.pendingHits)
	session.lastHit = nil
end

--[[
	注销 CombatWorld tick
	@param session Session - 会话
]]
local function _unregisterTick(session: Session)
	local handle = session.tickHandle
	session.tickHandle = nil
	if handle and handle.Connected then
		handle:Disconnect()
	end
end

--[[
	结束战斗并通知客户端
	@param player Player - 玩家
	@param session Session - 会话
	@param winner string - My / Enemy / Abort
	@param reason string - 结束原因
]]
local function _endBattle(player: Player, session: Session, winner: string, reason: string)
	if session.phase == PHASE_ENDED then
		return
	end
	session.phase = PHASE_ENDED
	_unregisterTick(session)
	session.lastHit = nil
	table.clear(session.pendingHits)
	local snapshot = _buildSnapshot(session)
	local result = {
		battleId = session.battleId,
		winner = winner,
		reason = reason,
		myHp = session.my.hp,
		enemyHp = session.enemy.hp,
	}
	AutoBattleNet.SyncState:FireClient(player, snapshot)
	AutoBattleNet.BattleEnd:FireClient(player, result)
	_sessions[player] = nil
	Log.print(
		string.format(
			"SystemAutoBattle: 结束 battleId=%s player=%s winner=%s reason=%s",
			session.battleId,
			player.Name,
			winner,
			reason
		)
	)
end

--[[
	推进一侧队伍的攻击
	@param attacker TeamState - 进攻方
	@param defender TeamState - 防守方（扣血）
	@param attackerSide string - My / Enemy
	@param session Session - 会话
	@return boolean - 本帧是否产生至少一次命中
]]
local function _tickTeam(
	attacker: TeamState,
	defender: TeamState,
	attackerSide: string,
	session: Session
): boolean
	local hit = false
	local now = session.now
	for _, unit in ipairs(attacker.units) do
		while unit.nextReady <= now and defender.hp > 0 do
			local damage = unit.atk
			if damage < 0 then
				damage = 0
			end
			defender.hp = math.max(0, defender.hp - damage)
			unit.nextReady = unit.nextReady + unit.cd
			session.lastHit = {
				side = attackerSide,
				slot = unit.slot,
				damage = damage,
			}
			table.insert(session.pendingHits, session.lastHit)
			hit = true
			if defender.hp <= 0 then
				break
			end
		end
		if defender.hp <= 0 then
			break
		end
	end
	return hit
end

--[[
	单玩家战斗帧步进
	@param player Player - 玩家
	@param session Session - 会话
	@param dt number - 帧间隔秒
]]
local function _stepSession(player: Player, session: Session, dt: number)
	if session.phase ~= PHASE_FIGHTING then
		return
	end
	if dt < 0 then
		dt = 0
	end
	session.now += dt

	local hitMy = _tickTeam(session.my, session.enemy, SIDE_MY, session)
	local hitEnemy = false
	if session.enemy.hp > 0 then
		hitEnemy = _tickTeam(session.enemy, session.my, SIDE_ENEMY, session)
	end

	if session.enemy.hp <= 0 then
		_endBattle(player, session, WINNER_MY, "enemy_hp_zero")
		return
	end
	if session.my.hp <= 0 then
		_endBattle(player, session, WINNER_ENEMY, "my_hp_zero")
		return
	end

	if hitMy or hitEnemy then
		local throttle = _getSyncThrottle()
		if throttle <= 0 or (session.now - session.lastSyncAt) >= throttle then
			_sync(player, session)
		end
	end
end

--[[
	清理玩家 Session（断线 / 强制）
	@param player Player - 玩家
	@param reason string - 原因
]]
local function _clearPlayer(player: Player, reason: string)
	local session = _sessions[player]
	if not session then
		return
	end
	_endBattle(player, session, WINNER_ABORT, reason)
end

--[[
	尝试开始自动战斗
	@param player Player - 玩家
	@return boolean - 是否成功
	@return string? - 失败原因码
]]
function SystemAutoBattle.TryStart(player: Player): (boolean, string?)
	if not player or not player.Parent then
		return false, "INVALID_PLAYER"
	end
	if not _isBattleAllowed() then
		return false, "NOT_ALLOWED"
	end
	if _sessions[player] then
		return false, "ALREADY_IN_BATTLE"
	end

	local pool = _collectAnimeIds()
	if #pool < 1 then
		Log.warn("SystemAutoBattle: animeConf 为空，无法开战")
		return false, "NO_ANIME_CFG"
	end

	local teamSize = _getTeamSize()
	local seed = math.floor(os.clock() * 1000) + player.UserId
	local rng = Random.new(seed)
	local now = 0
	local myTeam = _rollTeam(rng, pool, teamSize, now)
	local enemyTeam = _rollTeam(rng, pool, teamSize, now)
	if not myTeam or not enemyTeam then
		Log.warn("SystemAutoBattle: 抽队失败 player=", player.Name)
		return false, "ROLL_FAILED"
	end

	_battleSerial += 1
	local battleId = string.format("%d_%d_%d", player.UserId, os.time(), _battleSerial)
	local session: Session = {
		battleId = battleId,
		phase = PHASE_FIGHTING,
		my = myTeam,
		enemy = enemyTeam,
		lastHit = nil,
		pendingHits = {},
		tickHandle = nil,
		lastSyncAt = 0,
		now = now,
	}
	_sessions[player] = session

	local tickId = TICK_ID_PREFIX .. tostring(player.UserId)
	session.tickHandle = CombatWorld.register(tickId, function(dt: number)
		local live = _sessions[player]
		if not live or live.battleId ~= battleId then
			return
		end
		_stepSession(player, live, dt)
	end, CombatWorld.Phase.Cooldown)

	_sync(player, session)
	Log.print(
		string.format(
			"SystemAutoBattle: 开战 battleId=%s player=%s myMax=%s enemyMax=%s",
			battleId,
			player.Name,
			tostring(myTeam.maxHp),
			tostring(enemyTeam.maxHp)
		)
	)
	return true, nil
end

--[[
	尝试中止自动战斗（Debug）
	@param player Player - 玩家
	@return boolean - 是否成功
	@return string? - 失败原因码
]]
function SystemAutoBattle.TryAbort(player: Player): (boolean, string?)
	if not player or not player.Parent then
		return false, "INVALID_PLAYER"
	end
	if not _isBattleAllowed() then
		return false, "NOT_ALLOWED"
	end
	local session = _sessions[player]
	if not session then
		return false, "NOT_IN_BATTLE"
	end
	_endBattle(player, session, WINNER_ABORT, "player_abort")
	return true, nil
end

--[[
	玩家是否在战斗中
	@param player Player - 玩家
	@return boolean - true 表示战斗中
]]
function SystemAutoBattle.IsInBattle(player: Player): boolean
	local session = _sessions[player]
	return session ~= nil and session.phase == PHASE_FIGHTING
end

--[[
	Manager 调用：绑定玩家离开清理
]]
function SystemAutoBattle.Init()
	if _inited then
		return
	end
	_inited = true
	Players.PlayerRemoving:Connect(function(player: Player)
		_clearPlayer(player, "player_removing")
	end)
end

return SystemAutoBattle
