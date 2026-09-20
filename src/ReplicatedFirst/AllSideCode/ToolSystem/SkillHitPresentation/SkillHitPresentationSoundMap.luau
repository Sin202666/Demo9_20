--[[
	Module: SkillHitPresentation/SkillHitPresentationSoundMap
	Description: 技能/怪物受击音效键名映射表；同一键可配置多条音效并随机抽取一条
	Author: 林奥宇
	Created: 2026-08-17
	Last Modified: 2026-09-01

	维护：键名为 hitboxConfig.SoundName 或 enemyConf.InjuredSound；值为 SoundModule SoundName 列表。
	未知键按原键名兜底（兼容尚未入表的配置）。映射表 freeze，禁止运行时改条目。

	加载：服 System 经 ToolSystem 容器 require；Profile 同目录 require。不单独挂 Utils 键。
]]

local SkillHitPresentationSoundMap = {}

local SOUND_MAP: { [string]: { string } } = table.freeze({
	["通用受击"] = table.freeze({ "受击-通用" }),
	["受击音效-通用"] = table.freeze({ "受击-通用" }),
	["受击-通用"] = table.freeze({ "受击-通用" }),
	["音效-命中敌人"] = table.freeze({ "受击-通用" }), -- 旧键兼容
	["受击-哥布林1"] = table.freeze({ "受击-通用" }),
})

--[[
	去重追加一条已解析音效名
	@param result { string } - 待播放列表
	@param seen { [string]: boolean } - 已加入的 SoundName
	@param key string? - 配置键名；空则跳过
]]
local function _addUniqueSound(result: { string }, seen: { [string]: boolean }, key: string?)
	local picked = SkillHitPresentationSoundMap.pickSound(key)
	if picked and not seen[picked] then
		seen[picked] = true
		table.insert(result, picked)
	end
end

--[[
	从映射表随机解析一条音效名
	@param soundKey string? - 配置键名；空串或未知键时按原键名兜底
	@return string? - SoundModule SoundName；无法解析时 nil
]]
function SkillHitPresentationSoundMap.pickSound(soundKey: string?): string?
	if typeof(soundKey) ~= "string" or soundKey == "" then
		return nil
	end

	local candidates = SOUND_MAP[soundKey]
	if not candidates or #candidates == 0 then
		return soundKey
	end

	if #candidates == 1 then
		return candidates[1]
	end

	return candidates[math.random(1, #candidates)]
end

--[[
	解析技能 + 怪物受击音效（各随机一条，去重后返回）
	@param skillSoundKey string? - hitboxConfig.SoundName / 预设 soundKey
	@param monsterSoundKey string? - enemyConf.InjuredSound
	@return { string } - 待播放音效名列表（0~2 条）
]]
function SkillHitPresentationSoundMap.resolveHitSounds(skillSoundKey: string?, monsterSoundKey: string?): { string }
	local result: { string } = {}
	local seen: { [string]: boolean } = {}

	_addUniqueSound(result, seen, skillSoundKey)
	_addUniqueSound(result, seen, monsterSoundKey)

	return result
end

return SkillHitPresentationSoundMap
