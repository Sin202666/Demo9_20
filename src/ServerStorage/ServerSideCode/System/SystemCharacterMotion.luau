--[[
	Module: SystemCharacterMotion
	Description: 服务端位移包络对账（能力位移窗观测 + 击退短窗可钳回）
	Author: 林奥宇
	Created: 2026-08-05
	Last Modified: 2026-09-01

	功能：
	- OpenWindow / CloseWindow：能力位移包络（仅观测，超距 warn+计数，不拉回）
	- OpenKnockbackWindow / CloseKnockbackWindow：击退短窗（超距 EnvelopeClamp 钳回）
	- FireKnockback：向所有者客户端下发 ApplyKnockback，并自动开击退窗
	- FireRubberband：拒释/打断橡胶回弹至服权威位（或显式 target）
	- Init / destroy：绑 PlayerRemoving；无窗时断开 Heartbeat

	与相关模块：
	- 位移仍由拥有者客户端 CharacterMotion 驱动（Compose Drive+Impulse）；本模块不跑 LinearVelocity、不写 HRP
	- maxDistance 取 CharacterMotion.Recipes（不信客户端上报）
	- 下发走 SkillNet.SynPlayerCFrame（NetMsg.SYN_PLAYER_CFRAME）；客户端 PlayerSkillClientManager 转发 CharacterMotion
	- 击退调用方：HitResolver.Knockback；拒释：SystemPlayerSkill._rejectRelease
	- 仅在技能正式确认后 OpenWindow；预测段不开窗
	- Travel/Rolling 结束应 CloseWindow

	关键默认（改手感须另开方案，勿与 CharacterMotion.DEFAULT_TWEEN_DURATION 混用）：
	- 能力窗长缺省 = recipe.tweenDuration（无配方时 0.7）+ DRIVE_END_BLEND_SEC + 0.10
	- 击退窗长缺省 = durationSec * 2 + 0.10；maxDist 下限 KNOCKBACK_ENVELOPE_MIN_DIST
	- 能力超距只观测：网络所有权在客户端时拉回拦不住作弊且误伤手感

	加载（仅服务端）：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local SystemCharacterMotion = Utils.SystemCharacterMotion
		SystemCharacterMotion.Init()

	示例：
		SystemCharacterMotion.OpenWindow(player, "Skill:NewRoll:" .. castId, "NewRoll", "Forward")
		SystemCharacterMotion.CloseWindow(player, sessionId)
		SystemCharacterMotion.FireKnockback(player, { id = "Knock:cast:0", direction = dir, speed = 40 })
		SystemCharacterMotion.FireRubberband(player, nil, nil, "MountDash")
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Players = Utils.Players
local RunService = Utils.RunService
local Log = Utils.Log
local SkillNet = Utils.SkillNet
local CharacterMotion = Utils.CharacterMotion

local Constants = CharacterMotion.Constants
local Recipes = CharacterMotion.Recipes

-- ========================================
-- 模块定义
-- ========================================
local SystemCharacterMotion = {}

type Window = {
	sessionId: string,
	player: Player,
	p0: Vector3,
	maxDist: number,
	expiresAt: number,
	kind: string,
	skillKey: string?,
	direction: string?,
	clamped: boolean,
	hrp: BasePart,
}

type KnockbackPayload = {
	id: string,
	direction: Vector3?,
	planarVelocity: Vector3?,
	speed: number?,
	durationSec: number?,
	decay: string?,
	massScale: number?,
	collisionPolicy: string?,
	airMultiplier: number?,
	interruptDrive: boolean?,
	maxDistance: number?,
	composeCap: number?,
}

-- ========================================
-- 常量定义
-- ========================================
-- 与客户端 PlayerSkillClientManager 分支字符串对齐，勿改值
local SYNC_KIND = table.freeze({
	ENVELOPE_CLAMP = "EnvelopeClamp",
	APPLY_KNOCKBACK = "ApplyKnockback",
	REJECT_RUBBERBAND = "RejectRubberband",
})
local WINDOW_KIND = table.freeze({
	ABILITY = "Ability",
	KNOCKBACK = "Knockback",
})
local DIR_FORWARD = "Forward"
-- 无配方时包络上限（stud）；有 Recipes 时走 maxDistance / GetMaxDistanceCap
local FALLBACK_ABILITY_MAX_DIST = 40
-- 能力窗缺省 tween；与历史实现一致，不是 Constants.DEFAULT_TWEEN_DURATION(0.4)
local FALLBACK_TWEEN_DURATION = 0.7
-- 窗尾余量（秒）：能力默认窗、击退默认/下发窗共用
local WINDOW_TAIL_SEC = 0.10
local KNOCKBACK_WATCH_MUL = 2

-- ========================================
-- 私有变量
-- ========================================
-- 能力位移与击退分表，避免互相覆盖
local _abilityWindows: { [Player]: Window } = {}
local _knockbackWindows: { [Player]: Window } = {}
local _heartbeat: RBXScriptConnection? = nil
local _playerRemoving: RBXScriptConnection? = nil
local _violationCounts: { [number]: number } = {}
local _inited = false

-- ========================================
-- 私有函数
-- ========================================

--[[
	玩家是否仍在 Players 下
	@param player any - 待校验对象
	@return boolean - 在线 Player 为 true
]]
local function _isLivePlayer(player: any): boolean
	return typeof(player) == "Instance" and player:IsA("Player") and player:IsDescendantOf(Players)
end

--[[
	取当前角色 HumanoidRootPart
	@param player Player - 玩家
	@return BasePart? - 有效 HRP；角色缺失或类型不对时 nil
]]
local function _findHrp(player: Player): BasePart?
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		return hrp
	end
	return nil
end

--[[
	无包络窗时断开 Heartbeat，避免空转
]]
local function _maybeStopHeartbeat()
	if next(_abilityWindows) ~= nil or next(_knockbackWindows) ~= nil then
		return
	end
	if _heartbeat then
		_heartbeat:Disconnect()
		_heartbeat = nil
	end
end

--[[
	离场清理该玩家的窗与违规计数
	@param player Player - 正在离开的玩家
]]
local function _clearPlayer(player: Player)
	_abilityWindows[player] = nil
	_knockbackWindows[player] = nil
	_violationCounts[player.UserId] = nil
	_maybeStopHeartbeat()
end

--[[
	幂等绑定 PlayerRemoving。可由 Init 或首次开窗/下发触发。
]]
local function _ensureInit()
	if _inited then
		return
	end
	_inited = true
	_playerRemoving = Players.PlayerRemoving:Connect(_clearPlayer)
end

--[[
	检查单个包络窗：能力仅观测；击退超距经 SynPlayerCFrame 钳回客户端
	@param player Player - 玩家
	@param win Window - 窗（含开窗时缓存的 HRP）
	@param now number - os.clock
	@param store { [Player]: Window } - 所属表（到期或离场时清除）
]]
local function _tickWindow(player: Player, win: Window, now: number, store: { [Player]: Window })
	if not player.Parent then
		store[player] = nil
		return
	end
	if now >= win.expiresAt then
		store[player] = nil
		return
	end
	local hrp = win.hrp
	if not (hrp.Parent and hrp:IsA("BasePart")) then
		return
	end
	local flat = Vector3.new(hrp.Position.X - win.p0.X, 0, hrp.Position.Z - win.p0.Z)
	local limit = win.maxDist * Constants.ENVELOPE_SLACK
	if flat.Magnitude <= limit or win.clamped then
		return
	end

	win.clamped = true
	local uid = player.UserId
	_violationCounts[uid] = (_violationCounts[uid] or 0) + 1
	local isAbility = win.kind == WINDOW_KIND.ABILITY
	Log.warn(
		"[SystemCharacterMotion]",
		if isAbility then "envelope exceed (observe)" else "envelope clamp",
		win.kind,
		uid,
		string.format("dist=%.1f limit=%.1f count=%d", flat.Magnitude, limit, _violationCounts[uid])
	)

	-- 能力位移：网络所有权在客户端，拉回无效且伤手感；只记观测
	if isAbility then
		return
	end

	local dir = if flat.Magnitude > Constants.PLANAR_EPS then flat.Unit else Vector3.new(0, 0, 0)
	local target = Vector3.new(win.p0.X + dir.X * limit, hrp.Position.Y, win.p0.Z + dir.Z * limit)
	SkillNet.SynPlayerCFrame:FireClient(player, {
		kind = SYNC_KIND.ENVELOPE_CLAMP,
		targetPos = target,
		durationSec = Constants.RUBBERBAND_DEFAULT_SEC,
		sessionId = win.sessionId,
	})
end

--[[
	有窗才 Connect Heartbeat；无窗时由 _maybeStopHeartbeat 断开。
]]
local function _ensureHeartbeat()
	if _heartbeat then
		return
	end
	_heartbeat = RunService.Heartbeat:Connect(function()
		local now = os.clock()
		for player, win in pairs(_abilityWindows) do
			_tickWindow(player, win, now, _abilityWindows)
		end
		for player, win in pairs(_knockbackWindows) do
			_tickWindow(player, win, now, _knockbackWindows)
		end
		_maybeStopHeartbeat()
	end)
end

--[[
	能力窗缺省时长
	@param recipe table? - Recipes.Get 结果；可无 tweenDuration
	@param durationSec number? - 调用方显式窗长
	@return number - 秒；显式正数优先，否则 tween + 衔步 + 窗尾
]]
local function _abilityWatchSec(recipe: any, durationSec: number?): number
	if type(durationSec) == "number" and durationSec > 0 then
		return durationSec
	end
	local td = if recipe and type(recipe.tweenDuration) == "number" then recipe.tweenDuration else FALLBACK_TWEEN_DURATION
	return td + Constants.DRIVE_END_BLEND_SEC + WINDOW_TAIL_SEC
end

--[[
	击退监视窗时长。显式正数视为已算好的窗长（FireKnockback 会先乘倍率再传入）。
	@param durationSec number? - 监视窗秒；缺省 = 默认击退 duration * 倍率 + 窗尾
	@return number - 秒
]]
local function _knockbackWatchSec(durationSec: number?): number
	if type(durationSec) == "number" and durationSec > 0 then
		return durationSec
	end
	return Constants.DEFAULT_KNOCKBACK_DURATION * KNOCKBACK_WATCH_MUL + WINDOW_TAIL_SEC
end

-- ========================================
-- 公共函数
-- ========================================

--[[
	开能力位移包络窗（正式技能确认后；仅观测，不拉回）
	@param player Player - 玩家；须在线且有 HRP
	@param sessionId string - 会话 id（Close 时按此匹配）
	@param skillKey string - Recipes 键，如 NewRoll
	@param direction string? - Forward|Left|Right|Back；不可信或缺失时用各向 max
	@param durationSec number? - 窗长；默认 tweenDuration + DRIVE_END_BLEND_SEC + WINDOW_TAIL_SEC
	@return boolean - 已写入能力窗为 true
]]
function SystemCharacterMotion.OpenWindow(
	player: Player,
	sessionId: string,
	skillKey: string,
	direction: string?,
	durationSec: number?
): boolean
	_ensureInit()
	if not _isLivePlayer(player) or type(sessionId) ~= "string" or type(skillKey) ~= "string" then
		return false
	end
	local hrp = _findHrp(player)
	if not hrp then
		return false
	end

	local recipe = nil
	if type(direction) == "string" then
		recipe = Recipes.Get(skillKey, direction)
	end
	local maxDist = if recipe and type(recipe.maxDistance) == "number"
		then recipe.maxDistance
		else Recipes.GetMaxDistanceCap(skillKey)
	if maxDist <= 0 then
		maxDist = FALLBACK_ABILITY_MAX_DIST
	end

	_abilityWindows[player] = {
		sessionId = sessionId,
		player = player,
		p0 = hrp.Position,
		maxDist = maxDist,
		expiresAt = os.clock() + _abilityWatchSec(recipe, durationSec),
		kind = WINDOW_KIND.ABILITY,
		skillKey = skillKey,
		direction = direction or DIR_FORWARD,
		clamped = false,
		hrp = hrp,
	}
	_ensureHeartbeat()
	return true
end

--[[
	开击退短包络窗（与能力位移窗分离）
	@param player Player - 受击玩家；须在线且有 HRP
	@param sessionId string - 击退会话 id（如 Knock:castId:hitIndex）
	@param maxDist number - 水平位移上限估算；非正数时用 KNOCKBACK_ENVELOPE_MIN_DIST
	@param durationSec number? - 窗长；默认击退 duration * 2 + 窗尾
	@return boolean - 已写入击退窗为 true
]]
function SystemCharacterMotion.OpenKnockbackWindow(
	player: Player,
	sessionId: string,
	maxDist: number,
	durationSec: number?
): boolean
	_ensureInit()
	if not _isLivePlayer(player) or type(sessionId) ~= "string" then
		return false
	end
	local hrp = _findHrp(player)
	if not hrp then
		return false
	end
	local dist = maxDist
	if type(dist) ~= "number" or dist <= 0 then
		dist = Constants.KNOCKBACK_ENVELOPE_MIN_DIST
	end
	dist = math.max(dist, Constants.KNOCKBACK_ENVELOPE_MIN_DIST)
	_knockbackWindows[player] = {
		sessionId = sessionId,
		player = player,
		p0 = hrp.Position,
		maxDist = dist,
		expiresAt = os.clock() + _knockbackWatchSec(durationSec),
		kind = WINDOW_KIND.KNOCKBACK,
		clamped = false,
		hrp = hrp,
	}
	_ensureHeartbeat()
	return true
end

--[[
	关闭能力位移包络窗
	@param player Player - 玩家
	@param sessionId string? - 会话 id；传入且与当前窗不符则不关
	@return boolean - 已清除为 true；无窗或 session 不匹配为 false
]]
function SystemCharacterMotion.CloseWindow(player: Player, sessionId: string?): boolean
	local win = player and _abilityWindows[player]
	if not win then
		return false
	end
	if type(sessionId) == "string" and win.sessionId ~= sessionId then
		return false
	end
	_abilityWindows[player] = nil
	_maybeStopHeartbeat()
	return true
end

--[[
	关闭击退包络窗
	@param player Player - 玩家
	@param sessionId string? - 会话 id；传入且与当前窗不符则不关
	@return boolean - 已清除为 true；无窗或 session 不匹配为 false
]]
function SystemCharacterMotion.CloseKnockbackWindow(player: Player, sessionId: string?): boolean
	local win = player and _knockbackWindows[player]
	if not win then
		return false
	end
	if type(sessionId) == "string" and win.sessionId ~= sessionId then
		return false
	end
	_knockbackWindows[player] = nil
	_maybeStopHeartbeat()
	return true
end

--[[
	向受击所有者客户端下发击退（客户端 CharacterMotion.ApplyKnockback）
	@param player Player - 受击玩家；须在线
	@param payload table - KnockbackPayload：id 必填；direction|planarVelocity、speed?、durationSec?、decay?、massScale?、collisionPolicy?、airMultiplier?、interruptDrive?、maxDistance?、composeCap?
	@return boolean - 已 FireClient 为 true
]]
function SystemCharacterMotion.FireKnockback(player: Player, payload: KnockbackPayload): boolean
	_ensureInit()
	if not _isLivePlayer(player) or type(payload) ~= "table" or type(payload.id) ~= "string" then
		return false
	end
	local out = {
		kind = SYNC_KIND.APPLY_KNOCKBACK,
		id = payload.id,
		direction = payload.direction,
		planarVelocity = payload.planarVelocity,
		speed = payload.speed,
		durationSec = payload.durationSec or Constants.DEFAULT_KNOCKBACK_DURATION,
		decay = payload.decay or Constants.DEFAULT_KNOCKBACK_DECAY,
		massScale = payload.massScale,
		collisionPolicy = payload.collisionPolicy or Constants.DEFAULT_KNOCKBACK_COLLISION,
		airMultiplier = payload.airMultiplier,
		interruptDrive = payload.interruptDrive,
		maxDistance = payload.maxDistance,
		composeCap = payload.composeCap,
	}
	SkillNet.SynPlayerCFrame:FireClient(player, out)

	local speed = if type(out.speed) == "number" then out.speed else 0
	if typeof(out.planarVelocity) == "Vector3" then
		local flat = Vector3.new(out.planarVelocity.X, 0, out.planarVelocity.Z)
		speed = math.max(speed, flat.Magnitude)
	end
	local dur = out.durationSec
	local maxDist = math.max(
		Constants.KNOCKBACK_ENVELOPE_MIN_DIST,
		speed * dur * Constants.KNOCKBACK_ENVELOPE_DIST_FACTOR
	)
	SystemCharacterMotion.OpenKnockbackWindow(player, out.id, maxDist, dur * KNOCKBACK_WATCH_MUL + WINDOW_TAIL_SEC)
	return true
end

--[[
	拒释/打断：向客户端下发橡胶回弹至当前服权威位（或显式 target）
	@param player Player - 玩家；须在线
	@param targetPos Vector3? - 目标位置；非 Vector3 时用当前 HRP
	@param durationSec number? - 插值时长；默认 RUBBERBAND_DEFAULT_SEC
	@param reason string? - 原因标记（客户端可不消费）
	@return boolean - 已 FireClient 为 true
]]
function SystemCharacterMotion.FireRubberband(player: Player, targetPos: Vector3?, durationSec: number?, reason: string?): boolean
	_ensureInit()
	if not _isLivePlayer(player) then
		return false
	end
	local pos = targetPos
	if typeof(pos) ~= "Vector3" then
		local hrp = _findHrp(player)
		if hrp then
			pos = hrp.Position
		else
			return false
		end
	end
	SkillNet.SynPlayerCFrame:FireClient(player, {
		kind = SYNC_KIND.REJECT_RUBBERBAND,
		targetPos = pos,
		durationSec = durationSec or Constants.RUBBERBAND_DEFAULT_SEC,
		reason = reason,
	})
	return true
end

-- ========================================
-- 初始化
-- ========================================

--[[
	绑 PlayerRemoving，幂等。可由 Manager 启动时调用；未调用时首次开窗/下发会惰性执行。
]]
function SystemCharacterMotion.Init()
	_ensureInit()
end

--[[
	断开 Heartbeat / PlayerRemoving 并清空窗表。关服或热重载时调用。
]]
function SystemCharacterMotion.destroy()
	if _heartbeat then
		_heartbeat:Disconnect()
		_heartbeat = nil
	end
	if _playerRemoving then
		_playerRemoving:Disconnect()
		_playerRemoving = nil
	end
	table.clear(_abilityWindows)
	table.clear(_knockbackWindows)
	table.clear(_violationCounts)
	_inited = false
end

return SystemCharacterMotion
