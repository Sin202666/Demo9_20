--[[
	Module: SystemPlayerSkill
	Description: 服务端玩家组技能运行时（槽表、释放裁决、死亡打断；装备权威在 SystemSkill）
	Author: 林奥宇
	Created: 2026-08-31
	Last Modified: 2026-08-31

	功能：
	- Init：RegisterBindable BIND/UNBIND；钩 PlayerAdded Died / PlayerRemoving（须在脚本加载时由 Manager 同步调用）
	- OnRelease：存活 / 坐骑拒冲刺 / 飞行拒释 / 跨槽优先级 / 蓄力松键 / requestRelease
	- OnClientStop：只打断该玩家自己的施法
	- 拒释：SkillNet.ReleaseGroupSkill false + SystemCharacterMotion.FireRubberband

	与同类：
	- SystemSkill：只装备存档槽并 FireBindable BindGroupSkill；本模块持有 GroupSkillServer 槽表
	- GroupSkillServer：`ServerStorage/ServerSideCode/SystemSkillRuntime/GroupSkillServer`；CD / cast 生命周期；本模块做跨槽与门控
	- 不绑 Remote（RELEASE / CLIENT_STOP 由 PlayerSkillManager 转发）
	- 不调用 CombatWorld.Init 或其它模块 Init

	加载：
		local SystemPlayerSkill = Utils.SystemPlayerSkill
		SystemPlayerSkill.Init()
		SystemPlayerSkill.OnRelease(player, slotIndex, releaseData)
]]

local Class = require(game.ReplicatedFirst.AllSideCode.Class.Class)
local GetSkillData = require(game.ReplicatedStorage.ClientSideCode.SystemSkill.BaseSkill.GetSkillData)
local SkillReleaseCrossCheck = require(game.ServerStorage.ServerSideCode.SystemSkillRuntime.SkillReleaseCrossCheck)
local GroupSkillServer = require(game.ServerStorage.ServerSideCode.SystemSkillRuntime.GroupSkillServer)

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Players = Utils.Players
local HumanModule = Utils.HumanModule
local GetData = Utils.GetData
local NetWork = Utils.NetWork
local NetMsg = Utils.NetMsg
local SkillNet = Utils.SkillNet
local SkillSyncLog = Utils.SkillSyncLog
local SystemMount = Utils.SystemMount
local EnumMgr = Utils.EnumMgr
local Log = Utils.Log
local SystemCharacterMotion = Utils.SystemCharacterMotion

type GroupSkillServerT = typeof(Class.GroupSkillServer)
type GroupSkillInitData = typeof(Class.GroupSkillInitData)

local SystemPlayerSkill = {}

local SkillSlot = EnumMgr.SkillSlot
local Reject = EnumMgr.SkillReleaseReject

local _inited = false
local _playerSkill: { [string]: { [number]: GroupSkillServerT } } = {}
local _playerConns: { [Player]: { RBXScriptConnection } } = {}
local _globalConns: { RBXScriptConnection } = {}

-- ========================================
-- 私有
-- ========================================

--[[
	记录按玩家持有的连接，离场时一并 Disconnect
	@param player Player - 玩家
	@param conn RBXScriptConnection - 连接
]]
local function _addPlayerConn(player: Player, conn: RBXScriptConnection)
	local list = _playerConns[player]
	if not list then
		list = {}
		_playerConns[player] = list
	end
	table.insert(list, conn)
end

--[[
	断开并清空该玩家的 Died / CharacterAdded 连接
	@param player Player - 玩家
]]
local function _disconnectPlayerConns(player: Player)
	local list = _playerConns[player]
	if not list then
		return
	end
	for _, conn in list do
		conn:Disconnect()
	end
	_playerConns[player] = nil
end

--[[
	拒绝释放：同步日志 + 通知客户端失败 + 橡胶回弹
	@param player Player - 释放发起者
	@param slotIndex number - 技能槽 1～SkillSlot.MaxRuntime
	@param reason string - EnumMgr.SkillReleaseReject.*
]]
local function _rejectRelease(player: Player, slotIndex: number, reason: string)
	SkillSyncLog.log("?", "?", "?", "Server", "ReleaseGroupSkill", "rejected reason=" .. reason)
	SkillNet.ReleaseGroupSkill:FireClient(player, slotIndex, false)
	if SystemCharacterMotion and SystemCharacterMotion.FireRubberband then
		SystemCharacterMotion.FireRubberband(player, nil, nil, reason)
	end
end

--[[
	中断该玩家所有槽位进行中的施法
	@param player Player - 玩家
]]
local function _interruptAllCastsForPlayer(player: Player)
	local vt = _playerSkill[player.Name]
	if not vt then
		return
	end
	for slotIndex = 1, SkillSlot.MaxRuntime do
		local gs = vt[slotIndex]
		if gs and gs.interruptAllRunningCasts then
			gs:interruptAllRunningCasts()
		end
	end
end

--[[
	角色死亡时挂钩打断（含当前角色与后续 CharacterAdded）
	@param player Player - 玩家
]]
local function _hookPlayerSkillInterruptOnDied(player: Player)
	_addPlayerConn(player, player.CharacterAdded:Connect(function(character: Model)
		local hum = character:WaitForChild("Humanoid", 30)
		if not hum then
			return
		end
		_addPlayerConn(player, hum.Died:Connect(function()
			_interruptAllCastsForPlayer(player)
		end))
	end))
	local existing = player.Character
	if existing then
		local hum = existing:FindFirstChildWhichIsA("Humanoid")
		if hum then
			_addPlayerConn(player, hum.Died:Connect(function()
				_interruptAllCastsForPlayer(player)
			end))
		end
	end
end

--[[
	绑定组技能到槽位
	@param player Player - 目标玩家
	@param skillName string - GroupSkill 脚本名
	@param skillSlotIndex number - 槽位 1～SkillSlot.MaxRuntime
	@param skillID number? - 技能配置 ID
	@param skillPower number? - 技能强度
	@param skillPurity number? - 技能纯度
	@param skillMagic number? - 技能魔力
	@param mpTp string? - MP 类型
]]
local function _bindSkill(
	player: Player,
	skillName: string,
	skillSlotIndex: number,
	skillID: number?,
	skillPower: number?,
	skillPurity: number?,
	skillMagic: number?,
	mpTp: string?
)
	if not _playerSkill[player.Name] then
		_playerSkill[player.Name] = {}
	elseif _playerSkill[player.Name][skillSlotIndex] then
		Log.warn("玩家技能组已经绑定:", player.Name, skillSlotIndex)
		return
	end

	if skillSlotIndex < 1 or skillSlotIndex > SkillSlot.MaxRuntime then
		Log.warn("技能栏位索引不合法:", skillSlotIndex)
		return
	end

	local initData: GroupSkillInitData = {
		characterType = "Player",
		characterId = player.UserId,
		skillName = skillName,
		slotIndex = skillSlotIndex,
		skillID = skillID,
		skillPower = skillPower,
		skillPurity = skillPurity,
		skillMagic = skillMagic,
		mpTp = mpTp,
	}
	local groupSkill = GroupSkillServer.new(initData)
	if groupSkill then
		_playerSkill[player.Name][skillSlotIndex] = groupSkill
	else
		Log.warn("绑定技能组失败:", player.Name, skillName, skillSlotIndex)
	end
end

--[[
	解绑槽位组技能并 destroy
	@param player Player - 目标玩家
	@param skillSlotIndex number - 槽位索引
]]
local function _unbindSkill(player: Player, skillSlotIndex: number)
	if _playerSkill[player.Name] and _playerSkill[player.Name][skillSlotIndex] then
		_playerSkill[player.Name][skillSlotIndex]:destroy()
		_playerSkill[player.Name][skillSlotIndex] = nil
	end
end

--[[
	Bindable BIND_GROUP_SKILL：先解绑再绑定
	@param player Player - 目标玩家
	@param skillName string - GroupSkill 脚本名
	@param skillSlotIndex number - 槽位
	@param skillPower number? - 技能强度
	@param skillPurity number? - 技能纯度
	@param skillMagic number? - 技能魔力
	@param skillID number? - 技能配置 ID
	@param mpTp string? - MP 类型
]]
local function _onBindGroupSkill(
	player: Player,
	skillName: string,
	skillSlotIndex: number,
	skillPower: number?,
	skillPurity: number?,
	skillMagic: number?,
	skillID: number?,
	mpTp: string?
)
	_unbindSkill(player, skillSlotIndex)
	_bindSkill(player, skillName, skillSlotIndex, skillID, skillPower, skillPurity, skillMagic, mpTp)
end

--[[
	Bindable UNBIND_GROUP_SKILL：解绑指定槽
	@param player Player - 目标玩家
	@param skillSlotIndex number - 槽位索引 1～SkillSlot.MaxRuntime
]]
local function _onUnbind(player: Player, skillSlotIndex: number)
	_unbindSkill(player, skillSlotIndex)
end

--[[
	玩家离场：先 destroy 各槽 GroupSkillServer，再断连接、清跨检
	@param player Player - 离场玩家
]]
local function _onPlayerRemoving(player: Player)
	for slotIndex = 1, SkillSlot.MaxRuntime do
		_unbindSkill(player, slotIndex)
	end
	_playerSkill[player.Name] = nil
	_disconnectPlayerConns(player)
	if SkillReleaseCrossCheck.clearCharacter then
		SkillReleaseCrossCheck.clearCharacter(player.UserId)
	end
end

-- ========================================
-- 公共
-- ========================================

--[[
	释放请求（由 Manager Remote 转发）。覆盖 identity；方向取服端角色。
	@param player Player - 释放发起者（NetWork 注入，可信）
	@param slotIndex number - 技能槽
	@param releaseData any - 客上报输入表（table；非 table 时不覆盖字段）。字段：skillButtonPhase string?（"up" 为松键）；characterId number / characterType string / moveDirectionStr string 由服覆盖为 UserId / "Player" / 角色朝向，不以客值为准
]]
function SystemPlayerSkill.OnRelease(player: Player, slotIndex: number, releaseData: any)
	if not _playerSkill[player.Name] then
		Log.warn("玩家技能组不存在:", player.Name)
		return
	end

	if GetData.GetIsFly and GetData.GetIsFly(player) then
		_rejectRelease(player, slotIndex, Reject.Flying)
		return
	end

	local groupSkillVt = _playerSkill[player.Name]
	local groupSkill = groupSkillVt[slotIndex]
	if not groupSkill then
		Log.warn("技能未绑定:", slotIndex)
		return
	end

	if not HumanModule.IsPlrCharAlive(player) then
		_rejectRelease(player, slotIndex, Reject.Dead)
		return
	end

	if slotIndex == SkillSlot.Dash then
		if SystemMount and SystemMount.IsActive and SystemMount.IsActive(player) then
			_rejectRelease(player, slotIndex, Reject.MountActive)
			return
		end
	end

	local groupSkillInputData = releaseData :: any
	local isHoldSkillButtonRelease = type(releaseData) == "table" and (releaseData :: any).skillButtonPhase == "up"
	if type(releaseData) == "table" then
		local rInput = releaseData :: any
		rInput.characterId = player.UserId
		rInput.characterType = "Player"
		if player.Character then
			rInput.moveDirectionStr = GetSkillData.getCharacterDirectionStr(player.Character)
		end
	end

	if isHoldSkillButtonRelease then
		local mod = groupSkill.groupSkillModule and groupSkill.groupSkillModule.Data
		if mod and mod.sustainActiveUntilSkillButtonRelease == true then
			groupSkill:onInputRequest("buttonUp", groupSkillInputData)
		end
		return
	end

	if not groupSkill:hasPhase1Incomplete() then
		local incomingPri = groupSkill:getInterruptionPriority()
		for otherSlot, otherGs in pairs(groupSkillVt) do
			if type(otherSlot) == "number" and otherGs ~= groupSkill and otherGs:hasPhase1Incomplete() then
				if incomingPri <= otherGs:getInterruptionPriority() then
					_rejectRelease(player, slotIndex, Reject.InterruptionPriority)
					return
				end
			end
		end
		for otherSlot, otherGs in pairs(groupSkillVt) do
			if type(otherSlot) == "number" and otherGs ~= groupSkill and otherGs:hasPhase1Incomplete() then
				otherGs:interruptCrossSlotCast()
			end
		end
	end

	if groupSkill:hasPhase1Incomplete() then
		groupSkill:onInputRequest(groupSkillInputData)
		return
	end
	groupSkill:requestRelease(groupSkillInputData)
end

--[[
	客户端请求停止施法（只影响该 player）
	@param player Player - 发起者
	@param _skillName string - 技能名（现网未用，保留签名）
]]
function SystemPlayerSkill.OnClientStop(player: Player, _skillName: string)
	_interruptAllCastsForPlayer(player)
end

--[[
	Manager 脚本加载时同步调用一次。注册 Bindable 与玩家生命周期。不调 CombatWorld.Init。
]]
function SystemPlayerSkill.Init()
	if _inited then
		return
	end
	_inited = true

	NetWork.RegisterBindableEvent(NetMsg.BIND_GROUP_SKILL, _onBindGroupSkill)
	NetWork.RegisterBindableEvent(NetMsg.UNBIND_GROUP_SKILL, _onUnbind)

	table.insert(_globalConns, Players.PlayerAdded:Connect(_hookPlayerSkillInterruptOnDied))
	table.insert(_globalConns, Players.PlayerRemoving:Connect(_onPlayerRemoving))
	for _, plr in Players:GetPlayers() do
		task.defer(_hookPlayerSkillInterruptOnDied, plr)
	end
end

return SystemPlayerSkill
