--[[
	Module: PlayerAimSync
	Description: 玩家手动瞄准服缓冲（校验采样、未自瞄时冻结落点；客上报走 NetWork）
	Author: 林奥宇
	Created: 2026-08-31
	Last Modified: 2026-08-31

	功能：
	- OnSample：校验后写入按 UserId 的瞄准缓冲（玩家在线 / Vector3 / 持武 / HRP / 水平距）
	- getOrFreezeManualAimCF：未自瞄时从服缓冲冻结 skillRunData.manualAimSnapshotCF
	- isAutoAimActiveForSkill：trackTargetId / skillTargetData 可解析则为自瞄
	- Init：只钩 Players.PlayerRemoving 清缓冲（禁止 Register Remote）
	- clearServerBuffer / getServerBufferedAimCFrame：缓冲读写

	与同类：
	- 瞄准通道由 PlayerSkillManager Register NetMsg.PLAYER_AIM_SAMPLE 转发 OnSample
	- 客文件仍在 ClientSideCode BaseSkill（SkillModule refreshAimSnapshot / 自瞄查询）
	- 瞄准点不得作为命中或发奖证据；不采用 clientTime 做结算
	- 不写 CFrame / WalkSpeed / Store.cframe；不进 CombatWorld

	加载方式：
		local PlayerAimSync = Utils.PlayerAimSync
		PlayerAimSync.Init()
		PlayerAimSync.OnSample(player, pos, clientTime)
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Players = Utils.Players
local HumanModule = Utils.HumanModule

local BaseSkillFolder = game.ReplicatedStorage.ClientSideCode.SystemSkill.BaseSkill
local GetSkillData = require(BaseSkillFolder.GetSkillData)
local BaseSkillTargetFind = require(BaseSkillFolder.BaseSkillTargetFind)
local ProjectileObjectTracking = require(
	game.ReplicatedStorage.ClientSideCode.SystemSkill.SkillModule._Templates.Projectile.ProjectileObjectTracking
)

local PlayerAimSync = {}

local MAX_BUFFER_AGE_SEC = 0.15
local DEFAULT_MAX_AIM_HORIZONTAL_STUDS = 200

local _serverBufferByUserId: { [number]: { pos: Vector3, serverTime: number } } = {}
local _inited = false

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
	水平 XZ 距离
	@param a Vector3 - 点 A
	@param b Vector3 - 点 B
	@return number - XZ 平面距离
]]
local function _horizontalDistanceXZ(a: Vector3, b: Vector3): number
	local dx = a.X - b.X
	local dz = a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

--[[
	校验后写入瞄准缓冲
	@param player Player - 上报玩家
	@param pos Vector3 - 瞄准落点
	@param _clientTime number? - 客户端时间；本切片不用于结算
]]
local function _validateAndRecordSample(player: Player, pos: Vector3, _clientTime: number?)
	if typeof(pos) ~= "Vector3" then
		return
	end
	if not _isPlayerHoldingWeapon(player) then
		return
	end
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not hrp or not hrp:IsA("BasePart") then
		return
	end
	if _horizontalDistanceXZ(hrp.Position, pos) > DEFAULT_MAX_AIM_HORIZONTAL_STUDS then
		return
	end
	_serverBufferByUserId[player.UserId] = {
		pos = pos,
		serverTime = workspace:GetServerTimeNow(),
	}
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
	读取未过期的服瞄准缓冲
	@param userId number - 玩家 UserId
	@return CFrame? - 缓冲落点；过期或无则为 nil
]]
function PlayerAimSync.getServerBufferedAimCFrame(userId: number): CFrame?
	local entry = _serverBufferByUserId[userId]
	if not entry then
		return nil
	end
	if workspace:GetServerTimeNow() - entry.serverTime > MAX_BUFFER_AGE_SEC then
		return nil
	end
	return CFrame.new(entry.pos)
end

--[[
	未自瞄：冻结一次手动瞄准快照到 skillRunData.manualAimSnapshotCF（只读服缓冲）
	@param baseSkill any - BaseSkillServer 实例
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

	local cf: CFrame? = nil
	if baseSkill.characterType == "Player" then
		cf = PlayerAimSync.getServerBufferedAimCFrame(baseSkill.characterId)
	end

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
	清除该玩家瞄准缓冲（离场或显式清理）
	@param userId number - 玩家 UserId
]]
function PlayerAimSync.clearServerBuffer(userId: number)
	_serverBufferByUserId[userId] = nil
end

--[[
	瞄准采样入站（由 PlayerSkillManager Register 转发）
	@param player Player - 上报玩家
	@param pos any - 瞄准落点（须为 Vector3）
	@param clientTime any? - 客户端时间；不用于结算
]]
function PlayerAimSync.OnSample(player: Player, pos: any, clientTime: any?)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return
	end
	if not player.Parent then
		return
	end
	_validateAndRecordSample(player, pos, clientTime)
end

--[[
	只钩 PlayerRemoving 清缓冲。禁止 Register Remote / 调用其它模块 Init。
]]
function PlayerAimSync.Init()
	if _inited then
		return
	end
	_inited = true
	Players.PlayerRemoving:Connect(function(player: Player)
		PlayerAimSync.clearServerBuffer(player.UserId)
	end)
end

return PlayerAimSync
