--[[
	Module: SystemPlayerSkill
	Description: 客户端玩家组技能运行时（本地槽、旁观工厂、SynSkillEffect 路由；不写位移）
	Author: 林奥宇
	Created: 2026-08-31
	Last Modified: 2026-08-31

	功能：
	- Init：听「技能相关」Skill1/Skill2/Dash；CharacterAdded 重绑；他人离场清旁观表
	- OnSlotPressed：跨槽预打断后 onInputBegan（预测；服最终裁决）
	- OnReleaseAck / OnFixSkillTime / OnStopSkill / OnSynSkillEffect

	与同类：
	- PlayerSkillClientManager：CombatWorld.Init、SystemInput 绑定、Remote 转发、SYN_PLAYER_CFRAME→CharacterMotion
	- 本模块禁止调用 CharacterMotion / 写 CFrame / WalkSpeed
	- 不调用 CombatWorld.Init

	加载：
		local SystemPlayerSkill = Utils.SystemPlayerSkill
		SystemPlayerSkill.Init()
		SystemPlayerSkill.OnSlotPressed(slotIndex)
]]

local GetSkillData = require(game.ReplicatedStorage.ClientSideCode.SystemSkill.BaseSkill.GetSkillData)
local SkillEventConst = require(game.ReplicatedStorage.ClientSideCode.SystemSkill.BaseSkill.SkillEventConst)
local GroupSkillClient = require(game.ReplicatedStorage.ClientSideCode.SystemSkill.GroupSkill.GroupSkillClient)
local BaseSkillClient = require(game.ReplicatedStorage.ClientSideCode.SystemSkill.BaseSkill.BaseSkillClient)

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local CfgFind = Utils.CfgFind
local EnumMgr = Utils.EnumMgr
local HumanModule = Utils.HumanModule
local ResourceUtil = Utils.ResourceUtil
local LocalPlayer = Utils.LocalPlayer
local Players = Utils.Players
local SkillSyncLog = Utils.SkillSyncLog
local SystemGameConfig = Utils.SystemGameConfig
local Log = Utils.Log

local SystemPlayerSkill = {}

local SYNC = SkillEventConst.SyncEventType
local SkillSlot = EnumMgr.SkillSlot
local SkillFolder = EnumMgr.SkillFolder
local DASH_ENABLED = SystemGameConfig.GetValue({ "技能系统", "启用冲刺技能" }) ~= false

local _inited = false
local _localPlayerSkill: { [number]: any } = {}
local _skillSlotListenConnections: { RBXScriptConnection } = {}
local _lifecycleConns: { RBXScriptConnection } = {}
local _othersInstanceMap: { [number]: { [string]: any } } = {}

local MID_EVENT_TO_BASE_SKILL: { [string]: boolean } = {
	[SYNC.ProjectilePathConfirmed] = true,
	[SYNC.ProjectileHitConfirmed] = true,
	[SYNC.BaseSkillStateTransition] = true,
	[SYNC.ProximityStrikeWave] = true,
	[SYNC.SolarFlareMeteorShot] = true,
	[SYNC.HitConfirmed] = true,
}

-- ========================================
-- 私有
-- ========================================

--[[
	按技能配置 ID 解析 GroupSkill 脚本名
	@param skillID number - 技能配置 ID；≤0 返回 nil
	@return string? - cfg.ScriptName；无配置为 nil
]]
local function _resolveScriptName(skillID: number): string?
	if not skillID or skillID <= 0 then
		return nil
	end
	local cfg = CfgFind.FindCfgByID(skillID, EnumMgr.ItemType.Skill)
	return cfg and cfg.ScriptName or nil
end

--[[
	按槽位绑定/替换本地 GroupSkillClient
	@param skillID number - 技能配置 ID
	@param skillSlotIndex number - 槽位（Active1/2 或 Dash）
]]
local function _bindSkillByID(skillID: number, skillSlotIndex: number)
	local existing = _localPlayerSkill[skillSlotIndex]
	if existing and existing.destroy then
		local ok, err = pcall(function()
			existing:destroy()
		end)
		if not ok then
			Log.warn("[SystemPlayerSkill] destroy slot failed", skillSlotIndex, err)
		end
		_localPlayerSkill[skillSlotIndex] = nil
	end

	local skillName = _resolveScriptName(skillID)
	if not skillName then
		return
	end

	if ResourceUtil and ResourceUtil.PreloadSkill then
		local ok, err = pcall(function()
			ResourceUtil.PreloadSkill(skillName)
		end)
		if not ok then
			Log.warn("[SystemPlayerSkill] PreloadSkill failed", skillName, err)
		end
	end

	local obj = GroupSkillClient.new(
		skillName,
		skillSlotIndex,
		LocalPlayer.UserId,
		"Player",
		1,
		1,
		nil,
		skillID,
		nil
	)
	if obj then
		_localPlayerSkill[skillSlotIndex] = obj
	end
end

--[[
	监听技能 Folder 下指定 NumberValue，绑定槽位并在 Value 变化时重绑
	@param skillFolder Folder - 本地玩家技能 Folder（Instance.Name = SkillFolder.Name）
	@param valueName string - 槽位 NumberValue 名（SkillFolder.Skill1 / Skill2 / Dash）
	@param slotIndex number - 技能槽索引（SkillSlot.Active1 / Active2 / Dash）
]]
local function _watchSlot(skillFolder: Folder, valueName: string, slotIndex: number)
	local nv = skillFolder:FindFirstChild(valueName) or skillFolder:WaitForChild(valueName, 30)
	if not nv or not nv:IsA("NumberValue") then
		return
	end
	_bindSkillByID(nv.Value, slotIndex)
	table.insert(
		_skillSlotListenConnections,
		nv:GetPropertyChangedSignal("Value"):Connect(function()
			_bindSkillByID(nv.Value, slotIndex)
		end)
	)
end

--[[
	监听本地玩家技能 Folder 的槽位 NumberValue 并绑定
]]
local function _listenSkillFolder()
	for _, conn in _skillSlotListenConnections do
		conn:Disconnect()
	end
	table.clear(_skillSlotListenConnections)

	local skillFolder: Folder = LocalPlayer:WaitForChild(SkillFolder.Name, math.huge) :: Folder
	_watchSlot(skillFolder, SkillFolder.Skill1, SkillSlot.Active1)
	_watchSlot(skillFolder, SkillFolder.Skill2, SkillSlot.Active2)
	if DASH_ENABLED then
		_watchSlot(skillFolder, SkillFolder.Dash, SkillSlot.Dash)
	end
end

--[[
	旁观其它角色 BaseSkillStarted：创建 BaseSkillClient 仅作表现同步
	@param skillInputData table - 含 characterId/characterType/skillName/skillCastId/releaseCF/targetCF/moveDirectionStr/skillID/mpTp/skillPower/skillPurity/baseSkillInstanceId/activeBaseSkillIndex/trackTargetId/skillTargetData
]]
local function _processOthersBaseSkillStarted(skillInputData: any)
	local character = GetSkillData.getCharacter(skillInputData.characterType, skillInputData.characterId)
	if not character then
		return
	end
	local castId = skillInputData.skillCastId
	local baseSkillInstanceId = skillInputData.baseSkillInstanceId or (castId and (castId .. "_B1") or nil)
	if not castId or not baseSkillInstanceId then
		return
	end

	local charId = skillInputData.characterId
	if not _othersInstanceMap[charId] then
		_othersInstanceMap[charId] = {}
	end
	local charMap = _othersInstanceMap[charId]
	local instance = charMap[castId]
	if not instance then
		charMap[castId] = {
			skillCastId = castId,
			baseSkills = {},
			baseSkillMap = {},
			skillInputData = {
				releaseCF = skillInputData.releaseCF,
				targetCF = skillInputData.targetCF,
				moveDirectionStr = skillInputData.moveDirectionStr,
			},
		}
		instance = charMap[castId]
	end
	if instance.baseSkillMap[baseSkillInstanceId] then
		return
	end

	local ok, bs = pcall(function()
		local freeSkill = BaseSkillClient.new(
			skillInputData.skillName,
			skillInputData.characterId,
			skillInputData.characterType,
			skillInputData.skillPower or 1,
			skillInputData.skillPurity or 1,
			{
				skillID = skillInputData.skillID,
				mpTp = skillInputData.mpTp,
			}
		)
		if freeSkill and freeSkill.setSkillInputData then
			freeSkill:setSkillInputData(
				skillInputData.characterId,
				skillInputData.characterType,
				skillInputData.releaseCF,
				skillInputData.targetCF,
				skillInputData.moveDirectionStr,
				skillInputData.skillCastId,
				baseSkillInstanceId,
				skillInputData.activeBaseSkillIndex or 1,
				skillInputData.trackTargetId,
				skillInputData.skillTargetData
			)
		end
		return freeSkill
	end)
	if not ok or not bs then
		SkillSyncLog.log(skillInputData.skillName, castId, baseSkillInstanceId, "Client", "ObserverCreateFailed", tostring(bs))
		return
	end
	instance.baseSkillMap[baseSkillInstanceId] = bs
	table.insert(instance.baseSkills, bs)
	if bs.skillStart then
		bs:skillStart()
	end
end

--[[
	从单次施法 runtime 表按 baseSkillInstanceId 取 BaseSkillClient
	@param runtime table? - instanceMap[castId] 或旁观 charMap[castId]；含 baseSkillMap / baseSkills
	@param baseId string - baseSkillInstanceId
	@return any? - BaseSkillClient；找不到为 nil
]]
local function _findFromRuntime(runtime: any, baseId: string): any?
	if not runtime then
		return nil
	end
	if runtime.baseSkillMap and runtime.baseSkillMap[baseId] then
		return runtime.baseSkillMap[baseId]
	end
	if type(runtime.baseSkills) == "table" then
		for _, bs in runtime.baseSkills do
			if bs and bs.baseSkillInstanceId == baseId then
				return bs
			end
		end
	end
	return nil
end

--[[
	按 skillCastId + baseSkillInstanceId 查找本侧运行中的 BaseSkillClient（本地槽 + 旁观实例）
	@param payload table - SynSkillEffect 中途事件（含 skillCastId/baseSkillInstanceId/characterId）
	@return any? - BaseSkillClient；找不到为 nil
]]
local function _findBaseSkillClient(payload: any): any?
	if type(payload) ~= "table" then
		return nil
	end
	local castId = payload.skillCastId
	local baseId = payload.baseSkillInstanceId
	if type(castId) ~= "string" or castId == "" or type(baseId) ~= "string" or baseId == "" then
		return nil
	end

	for _, groupSkill in pairs(_localPlayerSkill) do
		if groupSkill and groupSkill.instanceMap then
			local found = _findFromRuntime(groupSkill.instanceMap[castId], baseId)
			if found then
				return found
			end
		end
	end

	local charId = payload.characterId
	if charId ~= nil and _othersInstanceMap[charId] then
		local found = _findFromRuntime(_othersInstanceMap[charId][castId], baseId)
		if found then
			return found
		end
	end

	for _, charMap in pairs(_othersInstanceMap) do
		if type(charMap) == "table" then
			local found = _findFromRuntime(charMap[castId], baseId)
			if found then
				return found
			end
		end
	end

	return nil
end

-- ========================================
-- 公共
-- ========================================

--[[
	本地按下技能槽：跨槽优先级预打断后 onInputBegan（预测；服最终裁决）
	@param slotIndex number - 技能槽索引
]]
function SystemPlayerSkill.OnSlotPressed(slotIndex: number)
	if not HumanModule.IsPlrCharAlive(LocalPlayer) then
		return
	end
	local skillGroup = _localPlayerSkill[slotIndex]
	if not skillGroup then
		return
	end

	-- 与服务端跨槽裁决对齐：本地先打断低优先级槽，再预测/发包，避免共用 AnimationTrack 被旧技能 OnOver 误停
	if not skillGroup:shouldBypassCooldownForLocalPress() then
		local incomingPri = skillGroup.getInterruptionPriority and skillGroup:getInterruptionPriority() or 50
		for otherSlot, otherGs in pairs(_localPlayerSkill) do
			if otherSlot ~= slotIndex and otherGs and otherGs.hasPhase1Incomplete and otherGs:hasPhase1Incomplete() then
				local otherPri = otherGs.getInterruptionPriority and otherGs:getInterruptionPriority() or 50
				if incomingPri <= otherPri then
					return
				end
			end
		end
		for otherSlot, otherGs in pairs(_localPlayerSkill) do
			if otherSlot ~= slotIndex and otherGs and otherGs.hasPhase1Incomplete and otherGs:hasPhase1Incomplete() then
				if otherGs.interruptAllCastingForCrossSlot then
					otherGs:interruptAllCastingForCrossSlot()
				end
			end
		end
	end

	local characterCF, selectCF = GetSkillData.getLocalPlayerSkillInputData()
	local moveDir = LocalPlayer.Character and GetSkillData.getCharacterDirectionStr(LocalPlayer.Character) or "Forward"
	if skillGroup.updateSkillInput then
		skillGroup:updateSkillInput(characterCF, selectCF)
	end
	if skillGroup.skillInputData then
		skillGroup.skillInputData.moveDirectionStr = moveDir
		skillGroup.skillInputData.characterId = LocalPlayer.UserId
		skillGroup.skillInputData.characterType = "Player"
	end
	skillGroup:onInputBegan()
end

--[[
	服侧释放回执：否决时清预测
	@param slotIndex number - 技能槽
	@param accepted boolean - 是否接受
]]
function SystemPlayerSkill.OnReleaseAck(slotIndex: number, accepted: boolean)
	local groupSkill = _localPlayerSkill[slotIndex]
	if not groupSkill then
		return
	end
	if accepted == false and groupSkill.clearPresentationPredict then
		groupSkill:clearPresentationPredict(true)
	end
end

--[[
	服侧校正技能时间
	@param slotIndex number - 技能槽
	@param serverTime number - 服时间
	@param _unused any? - 保留
	@param skillCastId string? - 施法 id
]]
function SystemPlayerSkill.OnFixSkillTime(slotIndex: number, serverTime: number, _unused: any?, skillCastId: string?)
	local groupSkill = _localPlayerSkill[slotIndex]
	if groupSkill and groupSkill.fixSkillTime then
		groupSkill:fixSkillTime(serverTime, nil, skillCastId)
	end
end

--[[
	停技能：本地全槽 requestStop，或销毁旁观 BaseSkillClient
	@param payload table - { characterId: number, skillCastId: string?, reason: string? }
]]
function SystemPlayerSkill.OnStopSkill(payload: any)
	if type(payload) ~= "table" then
		return
	end
	local charId = payload.characterId
	local castId = payload.skillCastId
	if charId == LocalPlayer.UserId then
		for _, groupSkill in _localPlayerSkill do
			if groupSkill.requestStop then
				groupSkill:requestStop(payload)
			end
		end
		return
	end
	local charMap = _othersInstanceMap[charId]
	if not charMap or not castId then
		return
	end
	local instance = charMap[castId]
	if not instance then
		return
	end
	for _, bs in instance.baseSkills or {} do
		if bs and bs.destroy then
			local ok, err = pcall(function()
				bs:destroy(payload.reason or "Finished", true)
			end)
			if not ok then
				Log.warn("[SystemPlayerSkill] observer destroy failed", castId, err)
			end
		end
	end
	charMap[castId] = nil
end

--[[
	SynSkillEffect：本地 createInstance / 旁观工厂 / 中途 handleServerEvent
	@param payload table - 含 eventType/characterId/characterType/slotIndex/groupSkillName/skillCastId 等
]]
function SystemPlayerSkill.OnSynSkillEffect(payload: any)
	if type(payload) ~= "table" then
		return
	end
	local eventType = payload.eventType
	if eventType == SYNC.BaseSkillStarted or eventType == "BaseSkillStarted" then
		local isLocal = payload.characterType == "Player" and payload.characterId == LocalPlayer.UserId
		if isLocal and payload.slotIndex then
			local groupSkill = _localPlayerSkill[payload.slotIndex]
			if groupSkill and groupSkill.skillName == payload.groupSkillName and groupSkill.createInstanceFromServerStart then
				groupSkill:createInstanceFromServerStart(payload)
			end
		else
			_processOthersBaseSkillStarted(payload)
		end
		return
	end
	if payload.characterId == LocalPlayer.UserId and payload.slotIndex then
		local groupSkill = _localPlayerSkill[payload.slotIndex]
		if groupSkill and eventType == SYNC.BaseSkillDerived and groupSkill.applyDerivedToInstance then
			groupSkill:applyDerivedToInstance(payload.skillCastId, payload)
			return
		end
	end

	if type(eventType) == "string" and MID_EVENT_TO_BASE_SKILL[eventType] then
		local baseSkill = _findBaseSkillClient(payload)
		if baseSkill and baseSkill.handleServerEvent then
			baseSkill:handleServerEvent(payload)
		else
			SkillSyncLog.log(
				payload.skillName or "?",
				payload.skillCastId or "?",
				payload.baseSkillInstanceId or "?",
				"Client",
				"MidEventNoBaseSkill",
				tostring(eventType)
			)
		end
	end
end

--[[
	Manager 脚本加载时同步调用。听技能 Folder；不调 CombatWorld.Init。
]]
function SystemPlayerSkill.Init()
	if _inited then
		return
	end
	_inited = true

	table.insert(
		_lifecycleConns,
		LocalPlayer.CharacterAdded:Connect(function()
			task.defer(_listenSkillFolder)
		end)
	)
	table.insert(
		_lifecycleConns,
		Players.PlayerRemoving:Connect(function(player: Player)
			_othersInstanceMap[player.UserId] = nil
		end)
	)

	task.spawn(function()
		LocalPlayer:WaitForChild(SkillFolder.Name, math.huge)
		_listenSkillFolder()
	end)

	SkillSyncLog.log("SystemPlayerSkill", "?", "?", "Client", "Init", "dash=" .. tostring(DASH_ENABLED))
end

return SystemPlayerSkill
