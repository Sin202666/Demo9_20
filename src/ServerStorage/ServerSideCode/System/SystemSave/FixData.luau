--[[
	Module: FixData
	Description: 玩家存档版本迁移（加载流程内执行，禁止写在业务 System.Init 中）
	Author: 林奥宇
	Created: 2026-07-03
	Last Modified: 2026-08-31

	功能：
	- 按存档内容执行一次性字段含义/结构迁移
	- 由 SystemSave 在结构补全后、PlayerData 同步前调用

	调用关系：
	- SystemSave._setPlayerStat 加载会话后调用 FixData.Run(plr, playerStat)
	- 禁止在 SystemSet.Init 等业务 Init 中编写迁移逻辑

	示例：
	local FixData = require(script.FixData)
	FixData.Run(player, sessionData[playerId])
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local SystemGameConfig = Utils.SystemGameConfig

-- ========================================
-- 模块定义
-- ========================================
local FixData = {}

-- ========================================
-- 常量定义
-- ========================================
local SETTING_KEY_BGM = "BGM"
local SETTING_KEY_EFFECT = "EFFECT"
local SETTING_KEY_SHAKE = "Shake"
local LEGACY_AUDIO_SCALE_KEYS = { SETTING_KEY_BGM, SETTING_KEY_EFFECT }
-- 旧框架主动样例 SkillDemoCast；槽 1 仍为该 ID 且配置默认已换时迁移
local LEGACY_ACTIVE_SAMPLE_SKILL_ID = 10000010

-- ========================================
-- 私有函数
-- ========================================

--[[
	旧档 BGM/EFFECT 为 0~1 比例时升级为 0~100 整数（100 等同旧 1 档满音量）
	@param settingData table - 玩家 Setting 存档表，可原地修改
	@return nil - 无返回值
]]
local function _migrateLegacyAudioSettingScale(settingData: { [string]: any })
	if not settingData then
		return
	end
	for _, key in ipairs(LEGACY_AUDIO_SCALE_KEYS) do
		local val = settingData[key]
		if type(val) == "number" and val > 0 and val <= 1 then
			settingData[key] = math.clamp(math.floor(val * 100 + 0.5), 0, 100)
		end
	end
end

--[[
	旧档「屏幕震动」为开关 0/1 时升级为 0~100 强度滑条（1→100，0 保持）
	@param settingData table - 玩家 Setting 存档表，可原地修改
	@return nil - 无返回值
]]
local function _migrateLegacyShakeSettingScale(settingData: { [string]: any })
	if not settingData then
		return
	end
	local val = settingData[SETTING_KEY_SHAKE]
	if type(val) == "number" and val > 0 and val <= 1 then
		settingData[SETTING_KEY_SHAKE] = math.clamp(math.floor(val * 100 + 0.5), 0, 100)
	end
end

--[[
	主动槽 1 仍为旧样例 SkillDemoCast 时迁移到 GameConfig 默认主动技能1ID
	@param playerStat table - 会话存档，可原地修改
	@return nil - 无返回值
]]
local function _migrateLegacyActiveSampleSkill(playerStat: { [string]: any })
	local skills = playerStat.skills
	if type(skills) ~= "table" then
		return
	end
	local slot1 = skills[1]
	if type(slot1) ~= "table" then
		return
	end
	local curId = slot1.skillID or 0
	if curId ~= LEGACY_ACTIVE_SAMPLE_SKILL_ID then
		return
	end
	local defaultId = SystemGameConfig.GetValue({ "技能系统", "默认主动技能1ID" }) or 0
	if type(defaultId) ~= "number" or defaultId <= 0 or defaultId == LEGACY_ACTIVE_SAMPLE_SKILL_ID then
		return
	end
	slot1.skillID = defaultId
	slot1.Power = slot1.Power or 1
	slot1.purity = slot1.purity or 1
end

-- ========================================
-- 公共 API
-- ========================================

--[[
	对玩家会话存档执行版本迁移
	@param plr Player - 玩家对象（预留扩展，当前迁移仅读写 playerStat）
	@param playerStat table - sessionData 中的存档表，可原地修改
	@return nil - 无返回值
]]
function FixData.Run(plr: Player, playerStat: any)
	if not playerStat then
		return
	end
	_migrateLegacyAudioSettingScale(playerStat.Setting)
	_migrateLegacyShakeSettingScale(playerStat.Setting)
	_migrateLegacyActiveSampleSkill(playerStat)
end

return FixData
