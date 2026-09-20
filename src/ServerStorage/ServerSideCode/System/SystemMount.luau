--[[
	Module: SystemMount
	Description: 坐骑/载具服务端权威 Session（拥有校验、Enter/Exit、ForceExit、Sync）
	Author: 林奥宇
	Created: 2026-08-27
	Last Modified: 2026-09-01

	功能：
	- TryEnter / TryExit / ForceExit；MountSession 唯一权威
	- 开发期白名单：HasMount 对样例 mountConf 行默认 true（存档拥有见坐骑系统开发说明 §9.2/§9.3，须另开方案）
	- PlayerAdded / Removing / 死亡 / 换角：清理或 ForceExit
	- MountNet.SyncState / ForceExit 下发客户端

	边界：
	- 不绑 Remote（PlayerMountManager 路由）
	- 不写 Humanoid.WalkSpeed / 不生成客户端表现模型
	- Phase 1 仅落地规则 P0；禁区/战斗锁后续迭代

	加载：
		local SystemMount = Utils.SystemMount
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local CfgFind = Utils.CfgFind
local EnumMgr = Utils.EnumMgr
local HumanModule = Utils.HumanModule
local Log = Utils.Log
local MountNet = Utils.MountNet
local NetMsg = Utils.NetMsg
local Players = Utils.Players
local RequestRateLimit = Utils.RequestRateLimit

local SystemMount = {}

type Session = {
	state: string,
	mountId: number?,
	locomotionType: string?,
	speedMul: number?,
	cdUntil: number,
}

local _sessions: { [Player]: Session } = {}
local _equippedMountId: { [Player]: number } = {}
local _inited = false

local DEV_DEFAULT_MOUNT_ID = 6001001
local _deathConns: { [Player]: RBXScriptConnection } = {}

--[[
	是否拥有该坐骑。Phase 1 为配置白名单（行存在即拥有）；接 SystemSave 拥有表须另开方案（§9.2）。
	@param _player Player - 玩家（Phase 1 不参与判定；预留商城/存档接线）
	@param mountId number - mountConf 主键
	@return boolean - 是否拥有
]]
function SystemMount.HasMount(_player: Player, mountId: number): boolean
	local cfg = CfgFind.GetMountCfg(mountId)
	return cfg ~= nil
end

--[[
	获取当前装备坐骑 ID（未设置时返回开发默认）
	@param player Player - 玩家
	@return number? - 装备 mountId；玩家无效时 nil
]]
function SystemMount.GetEquippedMountId(player: Player): number?
	if not player.Parent then
		return nil
	end
	return _equippedMountId[player] or DEV_DEFAULT_MOUNT_ID
end

--[[
	获取 Session 快照（只读副本）
	@param player Player - 玩家
	@return table? - MountSessionSnapshot；无 Session 时 Idle 快照
]]
function SystemMount.GetSession(player: Player): { [string]: any }?
	local session = _sessions[player]
	if not session then
		return {
			state = EnumMgr.MountSessionState.Idle,
			mountId = nil,
			locomotionType = nil,
			speedMul = nil,
			serverTime = os.time(),
			cdUntil = 0,
		}
	end
	return {
		state = session.state,
		mountId = session.mountId,
		locomotionType = session.locomotionType,
		speedMul = session.speedMul,
		serverTime = os.time(),
		cdUntil = session.cdUntil,
	}
end

--[[
	是否处于 Active 骑乘/载具态
	@param player Player - 玩家
	@return boolean - true 表示 Active
]]
function SystemMount.IsActive(player: Player): boolean
	local session = _sessions[player]
	return session ~= nil and session.state == EnumMgr.MountSessionState.Active
end

--[[
	构建 Sync 载荷
	@param player Player - 玩家
	@return table - MountSyncPayload
]]
local function _buildSyncPayload(player: Player): { [string]: any }
	return {
		session = SystemMount.GetSession(player),
		serverTime = os.time(),
	}
end

--[[
	向客户端同步 Session
	@param player Player - 玩家
]]
local function _syncToClient(player: Player)
	if not player.Parent then
		return
	end
	MountNet.SyncState:FireClient(player, _buildSyncPayload(player))
end

--[[
	确保玩家 Session 表存在
	@param player Player - 玩家
	@return Session - 会话
]]
local function _ensureSession(player: Player): Session
	local session = _sessions[player]
	if session then
		return session
	end
	local newSession: Session = {
		state = EnumMgr.MountSessionState.Idle,
		mountId = nil,
		locomotionType = nil,
		speedMul = nil,
		cdUntil = 0,
	}
	_sessions[player] = newSession
	return newSession
end

--[[
	读取 mount 配置并解析 GroundMount 速度倍率
	@param mountId number - mountConf 主键
	@return (table?, number?) - 配置副本与 speedMul（非 Ground 可为 nil）
]]
local function _resolveMountCfg(mountId: number): ({ [string]: any }?, number?)
	local cfg = CfgFind.GetMountCfg(mountId)
	if not cfg then
		return nil, nil
	end
	local locomotionType = cfg.LocomotionType
	local speedMul: number? = nil
	if locomotionType == EnumMgr.MountLocomotionType.GroundMount then
		local mul = tonumber(cfg.SpeedMul)
		speedMul = if mul and mul > 0 then mul else 1
	end
	return cfg, speedMul
end

--[[
	校验玩家可执行骑乘变更
	@param player Player - 玩家
	@return (boolean, string?) - 是否通过、错误码
]]
local function _validatePlayerAlive(player: Player): (boolean, string?)
	if not player or not player.Parent then
		return false, EnumMgr.MountErr.InvalidState
	end
	if not HumanModule.IsPlrCharAlive(player) then
		return false, EnumMgr.MountErr.InvalidState
	end
	return true, nil
end

--[[
	请求进入骑乘/载具
	@param player Player - 玩家
	@param mountId number - mountConf 主键
	@return (boolean, string?) - 是否成功、错误码
]]
function SystemMount.TryEnter(player: Player, mountId: number): (boolean, string?)
	local aliveOk, aliveErr = _validatePlayerAlive(player)
	if not aliveOk then
		return false, aliveErr
	end

	local numId = tonumber(mountId)
	if not numId or numId <= 0 then
		return false, EnumMgr.MountErr.InvalidMountId
	end

	if not SystemMount.HasMount(player, numId) then
		return false, EnumMgr.MountErr.NotOwned
	end

	local cfg, speedMul = _resolveMountCfg(numId)
	if not cfg then
		return false, EnumMgr.MountErr.ConfigMissing
	end

	local locomotionType = cfg.LocomotionType
	if type(locomotionType) ~= "string" or locomotionType == "" then
		return false, EnumMgr.MountErr.ConfigMissing
	end

	-- Phase 1 仅实现 GroundMount Driver
	if locomotionType ~= EnumMgr.MountLocomotionType.GroundMount then
		return false, EnumMgr.MountErr.InvalidState
	end

	local session = _ensureSession(player)
	if session.state == EnumMgr.MountSessionState.Active then
		return false, EnumMgr.MountErr.AlreadyActive
	end

	local now = os.clock()
	if session.cdUntil > now then
		return false, EnumMgr.MountErr.Cooldown
	end

	session.state = EnumMgr.MountSessionState.Active
	session.mountId = numId
	session.locomotionType = locomotionType
	session.speedMul = speedMul
	_equippedMountId[player] = numId

	_syncToClient(player)
	return true, EnumMgr.MountErr.Ok
end

--[[
	请求离开骑乘/载具
	@param player Player - 玩家
	@param reason string? - MountForceExitReason；默认 PlayerRequest
	@return (boolean, string?) - 是否成功、错误码
]]
function SystemMount.TryExit(player: Player, reason: string?): (boolean, string?)
	if not player or not player.Parent then
		return false, EnumMgr.MountErr.InvalidState
	end

	local session = _sessions[player]
	if not session or session.state ~= EnumMgr.MountSessionState.Active then
		return false, EnumMgr.MountErr.NotActive
	end

	local exitReason = if type(reason) == "string" and reason ~= ""
		then reason
		else EnumMgr.MountForceExitReason.PlayerRequest
	if exitReason ~= EnumMgr.MountForceExitReason.PlayerRequest then
		Log.print("[SystemMount] TryExit", player.Name, exitReason)
	end

	local cfg = session.mountId and CfgFind.GetMountCfg(session.mountId)
	local cdSec = if cfg then tonumber(cfg.SummonCd) or 0 else 0

	session.state = EnumMgr.MountSessionState.Idle
	session.mountId = nil
	session.locomotionType = nil
	session.speedMul = nil
	session.cdUntil = if cdSec > 0 then os.clock() + cdSec else 0

	_syncToClient(player)
	return true, EnumMgr.MountErr.Ok
end

--[[
	强制离开（静默 Fail + Log；仍 Sync）
	@param player Player - 玩家
	@param reason string - MountForceExitReason
]]
function SystemMount.ForceExit(player: Player, reason: string)
	if not player or not player.Parent then
		return
	end
	local session = _sessions[player]
	if not session or session.state ~= EnumMgr.MountSessionState.Active then
		return
	end

	local mountId = session.mountId
	local cfg = mountId and CfgFind.GetMountCfg(mountId)
	local cdSec = if cfg then tonumber(cfg.SummonCd) or 0 else 0

	session.state = EnumMgr.MountSessionState.Idle
	session.mountId = nil
	session.locomotionType = nil
	session.speedMul = nil
	session.cdUntil = if cdSec > 0 then os.clock() + cdSec else 0

	Log.print("[SystemMount] ForceExit", player.Name, reason, mountId)

	_syncToClient(player)
	MountNet.ForceExit:FireClient(player, {
		reason = reason,
		mountId = mountId,
	})
end

--[[
	设置装备坐骑（非 Active 时）
	@param player Player - 玩家
	@param mountId number - mountConf 主键
	@return (boolean, string?) - 是否成功、错误码
]]
function SystemMount.SetEquipped(player: Player, mountId: number): (boolean, string?)
	if not player or not player.Parent then
		return false, EnumMgr.MountErr.InvalidState
	end
	if SystemMount.IsActive(player) then
		return false, EnumMgr.MountErr.AlreadyActive
	end
	local numId = tonumber(mountId)
	if not numId or not SystemMount.HasMount(player, numId) then
		return false, EnumMgr.MountErr.NotOwned
	end
	_equippedMountId[player] = numId
	return true, EnumMgr.MountErr.Ok
end

--[[
	清理玩家 Session
	@param player Player - 玩家
]]
local function _clearPlayer(player: Player)
	local deathConn = _deathConns[player]
	if deathConn then
		deathConn:Disconnect()
		_deathConns[player] = nil
	end
	_sessions[player] = nil
	_equippedMountId[player] = nil
end

--[[
	玩家死亡时 ForceExit
	@param player Player - 玩家
]]
local function _hookDeath(player: Player, character: Model)
	local prev = _deathConns[player]
	if prev then
		prev:Disconnect()
		_deathConns[player] = nil
	end
	local hum = character:FindFirstChildWhichIsA("Humanoid")
	if not hum then
		return
	end
	_deathConns[player] = hum.Died:Connect(function()
		SystemMount.ForceExit(player, EnumMgr.MountForceExitReason.Death)
	end)
end

--[[
	Manager-only：注册限频、Player 生命周期
]]
function SystemMount.Init()
	if _inited then
		return
	end
	_inited = true

	if RequestRateLimit and RequestRateLimit.SetRateLimitConfig then
		RequestRateLimit.SetRateLimitConfig(NetMsg.MOUNT_REQ_ENTER, {
			maxRequests = 4,
			timeWindow = 1,
		})
		RequestRateLimit.SetRateLimitConfig(NetMsg.MOUNT_REQ_EXIT, {
			maxRequests = 4,
			timeWindow = 1,
		})
	end

	Players.PlayerAdded:Connect(function(player: Player)
		_equippedMountId[player] = DEV_DEFAULT_MOUNT_ID
		_ensureSession(player)

		player.CharacterAdded:Connect(function(character: Model)
			SystemMount.ForceExit(player, EnumMgr.MountForceExitReason.Respawn)
			_hookDeath(player, character)
		end)

		local char = player.Character
		if char then
			_hookDeath(player, char)
		end
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		_clearPlayer(player)
	end)

	for _, plr in Players:GetPlayers() do
		task.defer(function()
			_equippedMountId[plr] = DEV_DEFAULT_MOUNT_ID
			_ensureSession(plr)
			local char = plr.Character
			if char then
				_hookDeath(plr, char)
			end
		end)
	end
end

return SystemMount
