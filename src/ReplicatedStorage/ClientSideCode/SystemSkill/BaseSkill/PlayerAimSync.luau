--[[
	Module: PlayerAimSync
	Description: 玩家手动瞄准客户端（持武 10Hz 上报落点；自瞄不发包）
	Author: 林奥宇
	Created: 2026-08-31
	Last Modified: 2026-09-01

	功能：
	- initClient：持武且非自瞄时经 SkillNet.PlayerAimSample:FireServer 上报
	- destroyClient：断开 Heartbeat / PlayerRemoving，离场或脚本销毁时调用
	- refreshAimSnapshot：清 manualAimSnapshotCF 再调实例 getTargetCF（SkillModule 用）
	- isAutoAimActiveForSkill：trackTargetId / skillTargetData 可解析则为自瞄
	- getOrFreezeManualAimCF：未自瞄时只读客本地 CF 冻结快照（服缓冲在 ServerSideCode.System）
	- getClientBufferedAimCFrame：最近一次本地瞄准 CF

	与同类：
	- 服写口在 Utils.PlayerAimSync（ServerSideCode.System）；本文件给 SkillModule 相对 require 与 BaseSkillClient
	- Fire 只经 SkillNet.PlayerAimSample；禁止 Instance.new RemoteEvent
	- 瞄准点不得作为命中或发奖证据

	加载方式：
		local PlayerAimSync = require(script.Parent.Parent.BaseSkill.PlayerAimSync)
		PlayerAimSync.refreshAimSnapshot(baseSkill)
		PlayerAimSync.initClient()
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local RunService = Utils.RunService
local Players = Utils.Players
local HumanModule = Utils.HumanModule
local SkillNet = Utils.SkillNet

local GetSkillData = require(script.Parent.GetSkillData)
local BaseSkillTargetFind = require(script.Parent.BaseSkillTargetFind)
local ProjectileObjectTracking = require(
	game.ReplicatedStorage.ClientSideCode.SystemSkill.SkillModule._Templates.Projectile.ProjectileObjectTracking
)

local PlayerAimSync = {}

local SAMPLE_INTERVAL = 0.05

local _clientLocalAimCF: CFrame? = nil
local _clientAccumulator = 0
local _clientLoopConnected = false
local _heartbeatConn: RBXScriptConnection? = nil
local _playerRemovingConn: RBXScriptConnection? = nil

--[[
	玩家是否存活且持武
	@param player Player - 玩家
	@return boolean - 持武为 true
]]
local function _isPlayerHoldingWeapon(player: Player): boolean
	if not HumanModule.IsPlrCharAlive(player) then
		return false
	end
	local itemType = HumanModule.GetHeldItemType(player)
	return itemType == "Weapon"
end

--[[
	当前技能是否走自瞄（trackTargetId / skillTargetData 可解析）
	@param baseSkill any - BaseSkill 实例
	@return boolean - 可解析出自瞄落点则为 true
]]
function PlayerAimSync.isAutoAimActiveForSkill(baseSkill: any): boolean
	if not baseSkill then
		return false
	end
	if baseSkill.skillTargetData then
		local cf = BaseSkillTargetFind.findTarget(baseSkill.skillTargetData)
		if cf then
			return true
		end
	end
	local input = baseSkill.skillInputData
	if input and input.trackTargetId ~= nil and input.trackTargetId ~= "" then
		local pos = ProjectileObjectTracking.getWorldPositionByTrackTargetId(input.trackTargetId)
		if pos then
			return true
		end
	end
	return false
end

--[[
	最近一次本地瞄准 CF（initClient 采样写入）
	@return CFrame? - 本地瞄准；尚未采样则为 nil
]]
function PlayerAimSync.getClientBufferedAimCFrame(): CFrame?
	return _clientLocalAimCF
end

--[[
	进入 ProjectileFlying 等节点前：清除手动瞄准快照并重新 getTargetCF（前摇结束后再采一次落点）
	@param baseSkill any - BaseSkill 实例（须有 getTargetCF）
	@return CFrame - getTargetCF 结果；无方法时为单位 CFrame
]]
function PlayerAimSync.refreshAimSnapshot(baseSkill: any): CFrame
	if baseSkill and baseSkill.skillRunData then
		baseSkill.skillRunData.manualAimSnapshotCF = nil
	end
	if baseSkill and type(baseSkill.getTargetCF) == "function" then
		return baseSkill:getTargetCF()
	end
	return CFrame.new()
end

--[[
	未自瞄：冻结一次手动瞄准快照到 skillRunData.manualAimSnapshotCF（只读客本地 CF）
	@param baseSkill any - BaseSkillClient 实例
	@return CFrame - 冻结后的目标 CFrame
]]
function PlayerAimSync.getOrFreezeManualAimCF(baseSkill: any): CFrame
	if baseSkill.characterType == "Mirror" then
		local cf = baseSkill.skillInputData and baseSkill.skillInputData.targetCF or CFrame.new()
		local runData = baseSkill.skillRunData
		if runData then
			runData.manualAimSnapshotCF = cf
		end
		return cf
	end
	local runData = baseSkill.skillRunData
	if not runData then
		return baseSkill.skillInputData and baseSkill.skillInputData.targetCF or CFrame.new()
	end
	if runData.manualAimSnapshotCF then
		return runData.manualAimSnapshotCF
	end

	local cf: CFrame? = PlayerAimSync.getClientBufferedAimCFrame()

	if not cf and baseSkill.skillInputData and baseSkill.skillInputData.targetCF then
		cf = baseSkill.skillInputData.targetCF
	end

	if not cf then
		cf = CFrame.new()
	end

	local skillModule = baseSkill.skillModule
	local limit = skillModule and skillModule.skillDistanceLimit
	if limit and baseSkill.skillInputData and baseSkill.skillInputData.releaseCF then
		cf = GetSkillData.getLimitedTargetCF(baseSkill.skillInputData.releaseCF, cf, limit)
	end

	runData.manualAimSnapshotCF = cf
	if baseSkill.skillInputData then
		baseSkill.skillInputData.targetCF = cf
	end
	return cf
end

--[[
	断开瞄准采样循环。离场 / 脚本销毁时调用；可重入。

	@return nil
]]
function PlayerAimSync.destroyClient()
	if _heartbeatConn then
		_heartbeatConn:Disconnect()
		_heartbeatConn = nil
	end
	if _playerRemovingConn then
		_playerRemovingConn:Disconnect()
		_playerRemovingConn = nil
	end
	_clientLoopConnected = false
	_clientAccumulator = 0
	_clientLocalAimCF = nil
end

--[[
	启动持武瞄准采样循环。无 LocalPlayer 时直接返回（避免服侧误调）。
	Fire 只经 SkillNet.PlayerAimSample。离场走 destroyClient。

	@return nil
]]
function PlayerAimSync.initClient()
	if _clientLoopConnected then
		return
	end
	local localPlayer = Players.LocalPlayer
	if not localPlayer then
		return
	end
	_clientLoopConnected = true

	_heartbeatConn = RunService.Heartbeat:Connect(function(dt: number)
		if not HumanModule.IsPlrCharAlive(localPlayer) then
			return
		end
		if not _isPlayerHoldingWeapon(localPlayer) then
			return
		end
		if GetSkillData.isLocalPlayerAutoAimActive() then
			return
		end

		_clientAccumulator += dt
		if _clientAccumulator < SAMPLE_INTERVAL then
			return
		end
		_clientAccumulator = 0

		local aimCF = GetSkillData.getLocalPlayerManualAimCFrame()
		if not aimCF then
			return
		end
		_clientLocalAimCF = aimCF

		SkillNet.PlayerAimSample:FireServer(aimCF.Position, workspace:GetServerTimeNow())
	end)

	_playerRemovingConn = Players.PlayerRemoving:Connect(function(player: Player)
		if player == localPlayer then
			PlayerAimSync.destroyClient()
		end
	end)
end

return PlayerAimSync
