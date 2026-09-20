--[[
	Module: SystemSkill
	Description: 玩家技能槽装备权威（无药水/精炼；默认冲刺 NewRoll）
	Author: 林奥宇
	Created: 2026-07-29
	Last Modified: 2026-08-31

	功能：
	- Init：补齐存档槽、默认 dashSkill / 默认主动技能1~2、写技能镜像 Folder、BindGroupSkill
	- EquipSkill / UnequipSkill：按 skillID 装备/卸下；成功 true，失败 false + EnumMgr.SkillErr
	- GetEquippedSkills：查询当前装备（返回 skills 深拷贝，勿写回原存档）
	- IsEnabled / IsDashEnabled：读 GameConfig「技能系统」门控

	槽位（EnumMgr.SkillSlot）：1..MAX=主动技能，3=冲刺，4=普攻，5=格挡（一期冲刺 + 主动样例）
	镜像 Instance.Name 一律 EnumMgr.SkillFolder，勿改语义。

	配置（GameConfig.技能系统）：
	- 启用：false 时 Init / Equip 不跑玩家技能
	- 启用冲刺技能：false 时不绑定冲刺槽（依赖「启用」）
	- 默认主动技能1ID：空槽 1 时自动装备（快捷键 e）
	- 默认主动技能2ID：空槽 2 时自动装备（快捷键 r）

	边界：
	- 旧样例 SkillDemoCast(10000010) → 默认主动技能1 的迁移只在 FixData.Run，禁止写在 Init
	- Init 只做结构补全与空槽默认装备，不是版本迁移
	- 释放裁决 / 旁观工厂不在本模块，见 SystemPlayerSkill
	- ChangePlrData 失败：Equip/Unequip 返回 SaveFailed 且不绑运行时；Init 仍用内存槽绑定本会话

	调用关系：
	- PlayerManager 入服调用 Init(plr)，须晚于 SystemPlayerSkill.Init()
	- 运行时绑定经 Bindable BIND_GROUP_SKILL / UNBIND_GROUP_SKILL（SystemPlayerSkill 收）

	加载（仅服务端）：
		local SystemSkill = Utils.SystemSkill

	示例：
		SystemSkill.Init(player)
		local ok, err = SystemSkill.EquipSkill(player, skillId, EnumMgr.SkillSlot.Active1)
		if not ok then
			-- err 为 EnumMgr.SkillErr.*
		end
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local SystemSave = Utils.SystemSave
local PlayerData = Utils.PlayerData
local CfgFind = Utils.CfgFind
local EnumMgr = Utils.EnumMgr
local Log = Utils.Log
local SystemGameConfig = Utils.SystemGameConfig
local InsMgr = Utils.InsMgr
local NetWork = Utils.NetWork
local NetMsg = Utils.NetMsg
local Copy = Utils.Copy

-- ========================================
-- 模块定义
-- ========================================
local SystemSkill = {}

-- ========================================
-- 常量定义
-- ========================================
local globalConfig = SystemGameConfig.Get()
local skillConfig = globalConfig and globalConfig["技能系统"]
local MAX_SKILL_COUNT = (skillConfig and skillConfig["玩家可掌握技能数"]) or 2
local DEFAULT_DASH_SKILL_ID = (skillConfig and skillConfig["默认冲刺技能ID"]) or 10000002
local DEFAULT_NORMAL_ATTACK_ID = (skillConfig and skillConfig["默认普攻技能ID"]) or 0
local DEFAULT_BLOCK_SKILL_ID = (skillConfig and skillConfig["默认格挡技能ID"]) or 0
local DEFAULT_ACTIVE_SKILL_1_ID = (skillConfig and skillConfig["默认主动技能1ID"]) or 0
local DEFAULT_ACTIVE_SKILL_2_ID = (skillConfig and skillConfig["默认主动技能2ID"]) or 0
local DEFAULT_SKILL_POWER = 1
local DEFAULT_SKILL_PURITY = 1

local SkillSlot = EnumMgr.SkillSlot
local SkillFolder = EnumMgr.SkillFolder
local SkillErr = EnumMgr.SkillErr
local DASH_SLOT_INDEX = SkillSlot.Dash
local MAX_RUNTIME_SLOT = SkillSlot.MaxRuntime

type SkillSlotPersist = {
	skillID: number?,
	Power: number?,
	purity: number?,
	Magic: any?,
	mpTp: string?,
}

type DedicatedSlotSpec = {
	stat: string,
	valueName: string,
	needDash: boolean?,
}

local DEDICATED_SLOTS: { [number]: DedicatedSlotSpec } = {
	[SkillSlot.Dash] = { stat = "dashSkill", valueName = SkillFolder.Dash, needDash = true },
	[SkillSlot.NormalAttack] = { stat = "normalAtk", valueName = SkillFolder.NormalAtk },
	[SkillSlot.Block] = { stat = "blockSkill", valueName = SkillFolder.Block },
}

-- ========================================
-- 私有函数
-- ========================================

--[[
	校验玩家是否在线有效
	@param plr any - 待校验对象
	@return boolean - 在线 Player 为 true
]]
local function _validatePlayer(plr: any): boolean
	return plr ~= nil and typeof(plr) == "Instance" and plr:IsA("Player") and plr.Parent ~= nil
end

--[[
	写入存档字段
	@param plr Player - 玩家
	@param key string - 存档顶层键（skills / dashSkill / normalAtk / blockSkill）
	@param value any - 新值；skills 为 { [number]: SkillSlotPersist }
	@return boolean - ChangePlrData 是否成功
]]
local function _changeStat(plr: Player, key: string, value: any): boolean
	local ok = PlayerData.ChangePlrData(plr, key, value)
	if not ok then
		Log.warn("SystemSkill: ChangePlrData 失败", key, plr.Name)
		return false
	end
	return true
end

--[[
	解析 skillID → GroupSkillModule 名（ScriptName）
	@param skillID number - 技能配置 ID
	@return string? - ScriptName；无效为 nil
]]
local function _resolveGroupSkillName(skillID: number): string?
	if not skillID or skillID <= 0 then
		return nil
	end
	local skillCfg = CfgFind.FindCfgByID(skillID, EnumMgr.ItemType.Skill)
	if not skillCfg then
		return nil
	end
	local scriptName = skillCfg.ScriptName
	if type(scriptName) ~= "string" or scriptName == "" then
		return nil
	end
	return scriptName
end

--[[
	主动槽镜像 NumberValue 名
	@param slotIndex number - 1..MAX_SKILL_COUNT
	@return string - SkillFolder.Skill1 / Skill2，或 SkillPrefix+序号
]]
local function _activeSlotValueName(slotIndex: number): string
	if slotIndex == SkillSlot.Active1 then
		return SkillFolder.Skill1
	end
	if slotIndex == SkillSlot.Active2 then
		return SkillFolder.Skill2
	end
	return SkillFolder.SkillPrefix .. tostring(slotIndex)
end

--[[
	获取或创建玩家技能镜像文件夹
	@param plr Player - 玩家
	@return Folder - 玩家下 SkillFolder.Name 文件夹
]]
local function _getSkillFolder(plr: Player): Folder
	return InsMgr.GetIns(SkillFolder.Name, "Folder", plr) :: Folder
end

--[[
	更新技能槽 NumberValue（客户端监听绑定）
	@param plr Player - 玩家
	@param slotName string - SkillFolder 槽位名
	@param skillID number - 技能 ID；缺省当 0
]]
local function _updateSkillSlotValue(plr: Player, slotName: string, skillID: number)
	local skillFolder = _getSkillFolder(plr)
	local slotValue: NumberValue = InsMgr.GetIns(slotName, "NumberValue", skillFolder) :: NumberValue
	slotValue.Value = skillID or 0
end

--[[
	确保 CD 时间戳槽位存在
	@param plr Player - 玩家
]]
local function _ensureCooldownSlots(plr: Player)
	local folder = InsMgr.GetIns(SkillFolder.CooldownName, "Folder", plr) :: Folder
	for i = 1, MAX_RUNTIME_SLOT do
		InsMgr.GetIns(SkillFolder.SlotPrefix .. tostring(i), "NumberValue", folder)
	end
end

--[[
	构建空主动技能槽表
	@return { [number]: SkillSlotPersist } - 1..MAX 每槽为空表
]]
local function _buildEmptySkills(): { [number]: SkillSlotPersist }
	local skills = {}
	for i = 1, MAX_SKILL_COUNT do
		skills[i] = {}
	end
	return skills
end

--[[
	补齐 skills 槽位数（原地填缺槽；非 table 则新建）
	@param skills any - 存档 skills；期望 { [number]: { skillID?, Power?, purity?, Magic?, mpTp? } }
	@return { [number]: SkillSlotPersist } - 补齐后的槽表
	@return boolean - 是否发生结构变更
]]
local function _ensureSkillSlots(skills: any): ({ [number]: SkillSlotPersist }, boolean)
	if type(skills) ~= "table" then
		return _buildEmptySkills(), true
	end
	local changed = false
	for i = 1, MAX_SKILL_COUNT do
		if type(skills[i]) ~= "table" then
			skills[i] = {}
			changed = true
		end
	end
	return skills, changed
end

--[[
	绑定或解绑运行时组技能
	@param plr Player - 玩家
	@param slotIndex number - 运行时槽位 1..5
	@param skillID number? - 技能 ID；nil/0 解绑
]]
local function _bindSkillSlot(plr: Player, slotIndex: number, skillID: number?)
	local groupSkillName = skillID and _resolveGroupSkillName(skillID) or nil
	if groupSkillName and skillID and skillID > 0 then
		local skillPower, skillPurity, skillMagic, mpTp = DEFAULT_SKILL_POWER, DEFAULT_SKILL_PURITY, nil, nil
		if slotIndex >= 1 and slotIndex <= MAX_SKILL_COUNT then
			local plrData = SystemSave.GetStat(plr)
			local skillData = plrData and plrData.skills and plrData.skills[slotIndex]
			if skillData and skillData.skillID == skillID then
				skillPower = skillData.Power or DEFAULT_SKILL_POWER
				skillPurity = skillData.purity or DEFAULT_SKILL_PURITY
				skillMagic = skillData.Magic
				if type(skillData.mpTp) == "string" and skillData.mpTp ~= "" then
					mpTp = skillData.mpTp
				end
			end
		end
		NetWork.FireBindable(NetMsg.BIND_GROUP_SKILL, plr, groupSkillName, slotIndex, skillPower, skillPurity, skillMagic, skillID, mpTp)
	else
		NetWork.FireBindable(NetMsg.UNBIND_GROUP_SKILL, plr, slotIndex)
	end
end

--[[
	补齐 dashSkill / normalAtk / blockSkill 缺省（空槽默认装备，非版本迁移）
	@param plr Player - 玩家
	@param plrData table - 会话存档（字段 skills / dashSkill / normalAtk / blockSkill）
	@param dashEnabled boolean - 冲刺门控
]]
local function _ensureSpecialSlotDefaults(plr: Player, plrData: any, dashEnabled: boolean)
	if plrData.normalAtk == nil then
		local id = DEFAULT_NORMAL_ATTACK_ID or 0
		if _changeStat(plr, "normalAtk", id) then
			plrData.normalAtk = id
		end
	end

	if dashEnabled then
		if plrData.dashSkill == nil or plrData.dashSkill == 0 then
			if DEFAULT_DASH_SKILL_ID and DEFAULT_DASH_SKILL_ID > 0 then
				if _changeStat(plr, "dashSkill", DEFAULT_DASH_SKILL_ID) then
					plrData.dashSkill = DEFAULT_DASH_SKILL_ID
				end
			elseif plrData.dashSkill == nil then
				if _changeStat(plr, "dashSkill", 0) then
					plrData.dashSkill = 0
				end
			end
		end
	elseif plrData.dashSkill == nil then
		if _changeStat(plr, "dashSkill", 0) then
			plrData.dashSkill = 0
		end
	end

	if plrData.blockSkill == nil then
		local id = DEFAULT_BLOCK_SKILL_ID or 0
		if _changeStat(plr, "blockSkill", id) then
			plrData.blockSkill = id
		end
	end
end

--[[
	补齐主动槽表；空槽 1/2 填默认样例（版本迁移见 FixData）
	@param plr Player - 玩家
	@param plrData table - 会话存档（字段 skills；写入后指向补齐表）
]]
local function _ensureActiveSkills(plr: Player, plrData: any)
	local wasEmpty = not plrData.skills or next(plrData.skills) == nil
	local skills, slotsChanged = _ensureSkillSlots(plrData.skills)
	local filled = false

	if type(DEFAULT_ACTIVE_SKILL_1_ID) == "number" and DEFAULT_ACTIVE_SKILL_1_ID > 0 then
		local slot1 = skills[1]
		if type(slot1) == "table" then
			local curId = slot1.skillID or 0
			if curId == 0 then
				slot1.skillID = DEFAULT_ACTIVE_SKILL_1_ID
				slot1.Power = slot1.Power or DEFAULT_SKILL_POWER
				slot1.purity = slot1.purity or DEFAULT_SKILL_PURITY
				filled = true
				Log.print("SystemSkill.Init: 已填充默认主动技能1", DEFAULT_ACTIVE_SKILL_1_ID, plr.Name)
			end
		end
	end

	if type(DEFAULT_ACTIVE_SKILL_2_ID) == "number" and DEFAULT_ACTIVE_SKILL_2_ID > 0 and MAX_SKILL_COUNT >= 2 then
		local slot2 = skills[2]
		if type(slot2) == "table" then
			local curId = slot2.skillID or 0
			if curId == 0 then
				slot2.skillID = DEFAULT_ACTIVE_SKILL_2_ID
				slot2.Power = slot2.Power or DEFAULT_SKILL_POWER
				slot2.purity = slot2.purity or DEFAULT_SKILL_PURITY
				filled = true
				Log.print("SystemSkill.Init: 已填充默认主动技能2", DEFAULT_ACTIVE_SKILL_2_ID, plr.Name)
			end
		end
	end

	plrData.skills = skills
	if wasEmpty or slotsChanged or filled then
		_changeStat(plr, "skills", skills)
		if wasEmpty then
			Log.print("SystemSkill.Init: 已初始化技能槽结构，玩家:", plr.Name)
		end
	end
end

--[[
	写镜像 NumberValue 并绑定运行时组技能
	@param plr Player - 玩家
	@param plrData table - 已补齐的会话存档（读取 skills / dashSkill / normalAtk / blockSkill）
	@param dashEnabled boolean - 冲刺门控
]]
local function _syncRuntimeBindings(plr: Player, plrData: any, dashEnabled: boolean)
	_ensureCooldownSlots(plr)
	_getSkillFolder(plr)

	for i = 1, MAX_SKILL_COUNT do
		local skillData = plrData.skills and plrData.skills[i]
		local skillID = skillData and skillData.skillID or 0
		_updateSkillSlotValue(plr, _activeSlotValueName(i), skillID)
		_bindSkillSlot(plr, i, skillID)
	end

	local dashSkillID = if dashEnabled then (plrData.dashSkill or 0) else 0
	_updateSkillSlotValue(plr, SkillFolder.Dash, dashSkillID)
	_bindSkillSlot(plr, DASH_SLOT_INDEX, if dashEnabled then dashSkillID else nil)

	local normalAtkID = plrData.normalAtk or 0
	_updateSkillSlotValue(plr, SkillFolder.NormalAtk, normalAtkID)
	_bindSkillSlot(plr, SkillSlot.NormalAttack, normalAtkID)

	local blockSkillID = plrData.blockSkill or 0
	_updateSkillSlotValue(plr, SkillFolder.Block, blockSkillID)
	_bindSkillSlot(plr, SkillSlot.Block, blockSkillID)
end

--[[
	装备冲刺/普攻/格挡专用槽
	@param plr Player - 玩家
	@param skillID number - 技能配置 ID
	@param spec DedicatedSlotSpec - 存档键与镜像名
	@param slotIndex number - SkillSlot.Dash / NormalAttack / Block
	@return boolean - 是否成功
	@return string? - 失败时 EnumMgr.SkillErr
]]
local function _equipDedicated(plr: Player, skillID: number, spec: DedicatedSlotSpec, slotIndex: number): (boolean, string?)
	if spec.needDash and not SystemSkill.IsDashEnabled() then
		Log.warn("SystemSkill.EquipSkill: 冲刺技能未启用")
		return false, SkillErr.DashDisabled
	end
	if not _changeStat(plr, spec.stat, skillID) then
		return false, SkillErr.SaveFailed
	end
	_updateSkillSlotValue(plr, spec.valueName, skillID)
	_bindSkillSlot(plr, slotIndex, skillID)
	return true
end

--[[
	卸下冲刺/普攻/格挡专用槽
	@param plr Player - 玩家
	@param spec DedicatedSlotSpec - 存档键与镜像名
	@param slotIndex number - SkillSlot.Dash / NormalAttack / Block
	@return boolean - 是否成功
	@return string? - 失败时 EnumMgr.SkillErr
]]
local function _unequipDedicated(plr: Player, spec: DedicatedSlotSpec, slotIndex: number): (boolean, string?)
	if not _changeStat(plr, spec.stat, 0) then
		return false, SkillErr.SaveFailed
	end
	_updateSkillSlotValue(plr, spec.valueName, 0)
	_bindSkillSlot(plr, slotIndex, nil)
	return true
end

-- ========================================
-- 公共函数
-- ========================================

--[[
	玩家技能系统总开关（GameConfig.技能系统.启用）
	@return boolean - true 表示启用
]]
function SystemSkill.IsEnabled(): boolean
	return SystemGameConfig.GetValue({ "技能系统", "启用" }) ~= false
end

--[[
	冲刺技能开关（总开关开启且「启用冲刺技能」不为 false）
	@return boolean - true 表示启用冲刺槽
]]
function SystemSkill.IsDashEnabled(): boolean
	if not SystemSkill.IsEnabled() then
		return false
	end
	return SystemGameConfig.GetValue({ "技能系统", "启用冲刺技能" }) ~= false
end

--[[
	装备技能到主动槽（1..MAX）或写入冲刺/普攻/格挡专用字段
	@param plr Player - 玩家
	@param skillID number - 技能配置 ID
	@param slotIndex number - 1..MAX 主动；或 SkillSlot.Dash / NormalAttack / Block
	@return boolean - 是否成功
	@return string? - 失败时 EnumMgr.SkillErr.*
]]
function SystemSkill.EquipSkill(plr: Player, skillID: number, slotIndex: number): (boolean, string?)
	if not _validatePlayer(plr) then
		Log.warn("SystemSkill.EquipSkill: 参数错误")
		return false, SkillErr.InvalidPlayer
	end
	if type(skillID) ~= "number" or type(slotIndex) ~= "number" then
		Log.warn("SystemSkill.EquipSkill: 参数错误")
		return false, SkillErr.InvalidParam
	end
	if not SystemSkill.IsEnabled() then
		Log.warn("SystemSkill.EquipSkill: 技能系统未启用")
		return false, SkillErr.Disabled
	end

	local skillCfg = CfgFind.FindCfgByID(skillID, EnumMgr.ItemType.Skill)
	if not skillCfg then
		Log.warn("SystemSkill.EquipSkill: 技能配置不存在", skillID)
		return false, SkillErr.ConfigNotFound
	end

	local plrData = SystemSave.GetStat(plr)
	if not plrData then
		return false, SkillErr.NoData
	end

	if slotIndex >= 1 and slotIndex <= MAX_SKILL_COUNT then
		plrData.skills = plrData.skills or _buildEmptySkills()
		plrData.skills, _ = _ensureSkillSlots(plrData.skills)
		plrData.skills[slotIndex] = {
			skillID = skillID,
			purity = DEFAULT_SKILL_PURITY,
			Power = DEFAULT_SKILL_POWER,
		}
		if not _changeStat(plr, "skills", plrData.skills) then
			return false, SkillErr.SaveFailed
		end
		_updateSkillSlotValue(plr, _activeSlotValueName(slotIndex), skillID)
		_bindSkillSlot(plr, slotIndex, skillID)
		return true
	end

	local spec = DEDICATED_SLOTS[slotIndex]
	if spec then
		return _equipDedicated(plr, skillID, spec, slotIndex)
	end

	Log.warn("SystemSkill.EquipSkill: 槽位非法", slotIndex)
	return false, SkillErr.InvalidSlot
end

--[[
	卸下指定槽位技能
	@param plr Player - 玩家
	@param slotIndex number - 槽位索引
	@return boolean - 是否成功
	@return string? - 失败时 EnumMgr.SkillErr.*
]]
function SystemSkill.UnequipSkill(plr: Player, slotIndex: number): (boolean, string?)
	if not _validatePlayer(plr) then
		return false, SkillErr.InvalidPlayer
	end
	if type(slotIndex) ~= "number" then
		return false, SkillErr.InvalidParam
	end
	if not SystemSkill.IsEnabled() then
		return false, SkillErr.Disabled
	end
	local plrData = SystemSave.GetStat(plr)
	if not plrData then
		return false, SkillErr.NoData
	end

	if slotIndex >= 1 and slotIndex <= MAX_SKILL_COUNT then
		plrData.skills = plrData.skills or _buildEmptySkills()
		plrData.skills[slotIndex] = {}
		if not _changeStat(plr, "skills", plrData.skills) then
			return false, SkillErr.SaveFailed
		end
		_updateSkillSlotValue(plr, _activeSlotValueName(slotIndex), 0)
		_bindSkillSlot(plr, slotIndex, nil)
		return true
	end

	local spec = DEDICATED_SLOTS[slotIndex]
	if spec then
		return _unequipDedicated(plr, spec, slotIndex)
	end

	return false, SkillErr.InvalidSlot
end

--[[
	获取当前装备的普攻 ID 与主动技能槽列表（skills 为深拷贝，不可用于写回原存档）
	@param plr Player - 玩家
	@return number - 普攻技能 ID
	@return { [number]: SkillSlotPersist } - skills 槽表深拷贝；无存档时为空表
]]
function SystemSkill.GetEquippedSkills(plr: Player): (number, { [number]: SkillSlotPersist })
	local plrData = SystemSave.GetStat(plr)
	if not plrData then
		return 0, {}
	end
	local skills = plrData.skills
	if type(skills) ~= "table" then
		return plrData.normalAtk or 0, {}
	end
	return plrData.normalAtk or 0, Copy.deepCopy(skills)
end

-- ========================================
-- 初始化
-- ========================================

--[[
	初始化玩家技能数据结构与运行时绑定
	@param plr Player - 玩家对象
]]
function SystemSkill.Init(plr: Player)
	if not _validatePlayer(plr) then
		return
	end
	if not SystemSkill.IsEnabled() then
		return
	end

	local plrData = SystemSave.GetStat(plr)
	if not plrData then
		return
	end

	local dashEnabled = SystemSkill.IsDashEnabled()
	_ensureSpecialSlotDefaults(plr, plrData, dashEnabled)
	_ensureActiveSkills(plr, plrData)
	_syncRuntimeBindings(plr, plrData, dashEnabled)
end

return SystemSkill
