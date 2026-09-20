--!strict
--[[
	Module: SkillPreloadUtil
	Description: 技能相关资源预加载编排（解析技能配置、去重、批量预热）
	Author: 林奥宇
	Created: 2026-07-02
	Last Modified: 2026-09-01

	功能：
	- 按基础技能名 / 组技能名解析配置，收集 ResNameList、AnimateList、SoundList 并预热
	- 按动作名、音频名单独预热（不依赖技能配置模块）
	- 会话内去重，同一资源只触发一次 DeferPreload；仅成功回调才标记，失败可重试
	- 模型预热成功后 PartIcles:Preload(force) TexturePin，避免首次 AbsoluteEmit GPU redecode

	------------------------------------------------------------------------
	与 ResourceUtil / AnimationModule / ResRestore 的关系
	------------------------------------------------------------------------
	ResourceUtil     — 业务门面，推荐业务侧调用 Utils.ResourceUtil.PreloadSkill 等
	SkillPreloadUtil — 本模块，负责技能配置解析与预加载编排
	AnimationModule  — 动作名 → rbxassetid，供动作预热使用
	ResRestore       — DeferPreloadModel / DeferPreloadAnimationId / DeferPreloadSound
	PartIcles        — Preload(force) TexturePin，保贴图 GPU 常驻
	AssetPaths       — 解析 ModelRes/Skill 模型资源目录

	------------------------------------------------------------------------
	配置与资源路径（ReplicatedStorage 下）
	------------------------------------------------------------------------
	ClientSideCode/SystemSkill/SkillModule      — 基础技能 ModuleScript（按名 require）
	ClientSideCode/SystemSkill/GroupSkillModule — 组技能 ModuleScript；groupConfig.Skill 为
		{ { baseSkillName: string, ... }, ... } 条目表/数组
	ModelRes/Skill                              — 技能模型模板目录（AssetPaths.Shared）

	组/基础技能配置按名懒加载 ModuleScript（非顶部 require），仅限技能配置数据模块。

	------------------------------------------------------------------------
	去重键规则（模块级 _preloadedResources）
	------------------------------------------------------------------------
	model:{modelName}           — 技能模型名
	anim:rbxassetid://{id}      — 动作资源 ID 字符串
	sound:{soundName}           — SoundService 中 Sound.Name

	------------------------------------------------------------------------
	公共 API
	------------------------------------------------------------------------
	PreloadAnimations(animationNames) — 按动作名预热；非 table 则 Log.warn 后返回
	PreloadSounds(soundNames)         — 按音频名预热；非 table 则 Log.warn 后返回
	PreloadBaseSkill(baseSkillName)   — 单基础技能的模型/动作/音频
	PreloadSkill(skillName)           — 组技能：展开 Skill[].baseSkillName 后批量预热

	入参空串 / 缺目录 / 缺配置 / 缺资源：Log.warn 后跳过，不抛错。预热走 Defer，成功才去重。
	音频索引首次构建后，未命中时重建一次以覆盖延迟复制。

	------------------------------------------------------------------------
	加载方式
	------------------------------------------------------------------------
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local SkillPreloadUtil = Utils.SkillPreloadUtil
		-- 或优先：local ResourceUtil = Utils.ResourceUtil

	------------------------------------------------------------------------
	使用示例
	------------------------------------------------------------------------
	-- 【推荐】经 ResourceUtil 门面
	local ResourceUtil = Utils.ResourceUtil
	ResourceUtil.PreloadSkill("Meteor")
	ResourceUtil.PreloadBaseSkill("MagicMissile1")

	-- 【直接】按动作名 / 音频名预热
	SkillPreloadUtil.PreloadAnimations({ "魔法弹1", "普攻一段" })
	SkillPreloadUtil.PreloadSounds({ "通用受击", "技能释放" })
]]

-- ============================================================================
-- 服务与依赖
-- ============================================================================

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local ReplicatedStorage = Utils.ReplicatedStorage
local SoundService = Utils.SoundService

local AnimationModule = Utils.AnimationModule
local AssetPaths = Utils.AssetPaths
local Log = Utils.Log
local PartIcles = Utils.PartIcles
local ResRestore = Utils.ResRestore

-- ============================================================================
-- 模块定义
-- ============================================================================

local SkillPreloadUtil = {}

-- ============================================================================
-- 类型
-- ============================================================================

export type BaseSkillPreloadConfig = {
	ResNameList: { string }?,
	AnimateList: { string }?,
	SoundList: { string }?,
}

-- ============================================================================
-- 常量
-- ============================================================================

local LOG_PREFIX = "[SkillPreloadUtil]"

local SKILL_CONFIG_CLIENT_FOLDER = "ClientSideCode"
local SKILL_CONFIG_ROOT = "SystemSkill"
local SKILL_MODULE_FOLDER = "SkillModule"
local GROUP_SKILL_MODULE_FOLDER = "GroupSkillModule"
local SKILL_MODEL_RES_PATH = "ModelRes/Skill"

local PRELOAD_KEY_MODEL = "model:"
local PRELOAD_KEY_ANIM = "anim:"
local PRELOAD_KEY_SOUND = "sound:"
local ANIM_ASSET_PREFIX = "rbxassetid://"

-- ============================================================================
-- 私有变量
-- ============================================================================

-- 已预加载资源记录表，避免重复预加载（key 格式见文件头「去重键规则」）
local _preloadedResources: { [string]: boolean } = {}

-- SoundService 名称索引懒加载缓存
local _soundByNameCache: { [string]: Sound }? = nil

-- 音频未命中后是否已重建过索引（只重建一次，避免缺失名反复 GetDescendants）
local _soundIndexRebuildAttempted = false

-- 命中后缓存；Parent 断开则下次重解析（覆盖首次未复制）
local _systemSkillFolder: Folder? = nil
local _skillResFolder: Instance? = nil

-- ============================================================================
-- 私有函数
-- ============================================================================

--[[
	判断是否为非空字符串
	@param value any - 待检查值
	@return boolean - 是否为非空 string
]]
local function _isNonEmptyString(value: any): boolean
	return type(value) == "string" and value ~= ""
end

--[[
	判断资源是否已预加载
	@param key string - 去重键，如 "model:FireBall"
	@return boolean - 是否已预加载
]]
local function _isPreloaded(key: string): boolean
	return _preloadedResources[key] == true
end

--[[
	标记资源预加载完成
	@param key string - 去重键
]]
local function _markPreloaded(key: string)
	_preloadedResources[key] = true
end

--[[
	检查 AnimationModule 是否可用于动作 ID 解析
	@param context string - 调用上下文标识，写入日志
	@return boolean - 是否可用
]]
local function _ensureAnimationModule(context: string): boolean
	if AnimationModule and AnimationModule.GetAnimID then
		return true
	end
	Log.warn(LOG_PREFIX, context, "AnimationModule 不可用")
	return false
end

--[[
	对字符串列表去重（保持首次出现顺序）
	@param names { string } - 原始名称列表
	@return { string } - 去重后的新列表
]]
local function _dedupeStrings(names: { string }): { string }
	local seen: { [string]: boolean } = {}
	local result: { string } = {}
	for _, name in names do
		if not seen[name] then
			seen[name] = true
			table.insert(result, name)
		end
	end
	return result
end

--[[
	把配置里的名称列表追加到输出（跳过非 string / 空串）
	@param source { string }? - 配置字段，如 ResNameList；nil 时不追加
	@param dest { string } - 输出列表
]]
local function _appendNamedList(source: { string }?, dest: { string })
	if not source then
		return
	end
	for _, name in source do
		if _isNonEmptyString(name) then
			table.insert(dest, name)
		end
	end
end

--[[
	从基础技能配置收集预加载列表
	@param baseConfig BaseSkillPreloadConfig - 基础技能配置，含 ResNameList / AnimateList / SoundList
	@param modelNames { string } - 模型名输出列表
	@param animationNames { string } - 动作名输出列表
	@param soundNames { string } - 音频名输出列表
]]
local function _appendBaseSkillLists(
	baseConfig: BaseSkillPreloadConfig,
	modelNames: { string },
	animationNames: { string },
	soundNames: { string }
)
	_appendNamedList(baseConfig.ResNameList, modelNames)
	_appendNamedList(baseConfig.AnimateList, animationNames)
	_appendNamedList(baseConfig.SoundList, soundNames)
end

--[[
	获取 SoundService 中名称到 Sound 的索引（模块级懒加载缓存）
	@return { [string]: Sound } - 音频名称索引；重名保留首次出现
]]
local function _getSoundNameIndex(): { [string]: Sound }
	if _soundByNameCache then
		return _soundByNameCache
	end

	local soundByName: { [string]: Sound } = {}
	for _, sound in SoundService:GetDescendants() do
		if sound:IsA("Sound") and soundByName[sound.Name] == nil then
			soundByName[sound.Name] = sound
		end
	end
	_soundByNameCache = soundByName
	return soundByName
end

--[[
	按名称查找 Sound；首次未命中时重建一次索引（覆盖延迟复制）
	@param soundName string - Sound.Name
	@return Sound? - 命中的实例；仍无则为 nil
]]
local function _findSoundByName(soundName: string): Sound?
	local index = _getSoundNameIndex()
	local sound = index[soundName]
	if sound then
		return sound
	end
	if _soundIndexRebuildAttempted then
		return nil
	end
	_soundIndexRebuildAttempted = true
	_soundByNameCache = nil
	index = _getSoundNameIndex()
	return index[soundName]
end

--[[
	按动作名称列表预热动作资源
	@param animationNames { string } - 动作名称列表
	@param logContext string - AnimationModule 不可用时的日志上下文
]]
local function _preloadAnimationsByNames(animationNames: { string }, logContext: string)
	if not _ensureAnimationModule(logContext) then
		return
	end

	for _, animName in animationNames do
		if not _isNonEmptyString(animName) then
			continue
		end

		local animId = AnimationModule.GetAnimID(animName)
		if not animId then
			continue
		end

		local animIdStr = ANIM_ASSET_PREFIX .. tostring(animId)
		local key = PRELOAD_KEY_ANIM .. animIdStr
		if _isPreloaded(key) then
			continue
		end

		ResRestore.DeferPreloadAnimationId(animIdStr, function()
			_markPreloaded(key)
		end)
	end
end

--[[
	按音频名称列表预热 SoundService 中的 Sound
	@param soundNames { string } - 音频名称列表
]]
local function _preloadSoundsByNames(soundNames: { string })
	for _, soundName in soundNames do
		if not _isNonEmptyString(soundName) then
			continue
		end

		local key = PRELOAD_KEY_SOUND .. soundName
		if _isPreloaded(key) then
			continue
		end

		local sound = _findSoundByName(soundName)
		if not sound then
			Log.warn(LOG_PREFIX, "未找到音频:", soundName)
			continue
		end

		ResRestore.DeferPreloadSound(sound, function()
			_markPreloaded(key)
		end)
	end
end

--[[
	模型 ContentProvider 预热成功后：TexturePin 保 GPU 常驻（force=true 覆盖全部 PE/Trail）。
	@param model Model - 已 Restore 的技能模板
]]
local function _pinModelTextures(model: Model)
	if not PartIcles or type(PartIcles.Preload) ~= "function" then
		return
	end
	-- force=true：原生 PE 无 PreloadTexture 属性也会 pin（技能 Burst 常用原生 PE）
	local ok, err = pcall(function()
		PartIcles:Preload(model, true)
	end)
	if not ok then
		Log.warn(LOG_PREFIX, "PartIcles:Preload 失败", model, err)
	end
end

--[[
	执行资源预加载（模型、动作、音频）
	@param modelNamesToPreload { string } - 模型名称列表
	@param animationNamesToPreload { string } - 动作名称列表
	@param soundNamesToPreload { string } - 音频名称列表
	@param skillResFolder Instance - 技能模型资源目录
]]
local function _executePreload(
	modelNamesToPreload: { string },
	animationNamesToPreload: { string },
	soundNamesToPreload: { string },
	skillResFolder: Instance
)
	for _, modelName in modelNamesToPreload do
		local key = PRELOAD_KEY_MODEL .. modelName
		if _isPreloaded(key) then
			continue
		end

		local model = skillResFolder:FindFirstChild(modelName)
		if not (model and model:IsA("Model")) then
			Log.warn(LOG_PREFIX, "未找到技能模型:", modelName)
			continue
		end

		ResRestore.DeferPreloadModel(model, function()
			_pinModelTextures(model)
			_markPreloaded(key)
		end)
	end

	_preloadAnimationsByNames(animationNamesToPreload, "PreloadSkill/PreloadBaseSkill")
	_preloadSoundsByNames(soundNamesToPreload)
end

--[[
	获取技能配置根目录 SystemSkill
	@return Folder? - SystemSkill 实例，不存在时为 nil
]]
local function _getSystemSkillFolder(): Folder?
	if _systemSkillFolder and _systemSkillFolder.Parent then
		return _systemSkillFolder
	end
	local clientSideCode = ReplicatedStorage:FindFirstChild(SKILL_CONFIG_CLIENT_FOLDER)
	local systemSkill = clientSideCode and (clientSideCode :: Instance):FindFirstChild(SKILL_CONFIG_ROOT)
	if systemSkill and systemSkill:IsA("Folder") then
		_systemSkillFolder = systemSkill
		return systemSkill
	end
	return nil
end

--[[
	解析技能模型资源目录
	@return Instance? - ModelRes/Skill 目录，不存在时为 nil
]]
local function _getSkillResFolder(): Instance?
	if _skillResFolder and _skillResFolder.Parent then
		return _skillResFolder
	end
	_skillResFolder = AssetPaths.Resolve(SKILL_MODEL_RES_PATH, AssetPaths.Scope.Shared)
	return _skillResFolder
end

--[[
	按名懒加载技能配置 ModuleScript（配置按技能名动态查找，无法顶部 require）
	@param moduleScript ModuleScript - 技能配置脚本
	@param context string - 日志上下文（如 PreloadBaseSkill）
	@param skillName string - 技能名
	@return any? - ModuleScript 导出值（基础技能为 BaseSkillPreloadConfig，组技能为含 Skill 的表）；失败或空为 nil
]]
local function _safeRequireModule(moduleScript: ModuleScript, context: string, skillName: string): any?
	local ok, result = pcall(require, moduleScript)
	if not ok then
		Log.warn(LOG_PREFIX, context, "加载技能配置失败:", skillName, result)
		return nil
	end
	if not result then
		Log.warn(LOG_PREFIX, context, "技能配置为空:", skillName)
		return nil
	end
	return result
end

--[[
	把 require 结果收成基础技能预加载配置
	@param value any - ModuleScript 导出值
	@param context string - 日志上下文
	@param skillName string - 技能名
	@return BaseSkillPreloadConfig? - 表形态配置；非表时 nil
]]
local function _asBaseSkillConfig(value: any, context: string, skillName: string): BaseSkillPreloadConfig?
	if type(value) ~= "table" then
		Log.warn(LOG_PREFIX, context, "技能配置不是表:", skillName)
		return nil
	end
	return value :: BaseSkillPreloadConfig
end

--[[
	加载基础技能配置并追加三类资源名
	@param baseSkillFolder Instance - SkillModule 目录
	@param baseSkillName string - 基础技能模块名
	@param modelNames { string } - 模型名输出
	@param animationNames { string } - 动作名输出
	@param soundNames { string } - 音频名输出
	@param context string - 日志上下文
	@return boolean - 是否成功追加（缺模块/加载失败为 false）
]]
local function _collectBaseSkillLists(
	baseSkillFolder: Instance,
	baseSkillName: string,
	modelNames: { string },
	animationNames: { string },
	soundNames: { string },
	context: string
): boolean
	local baseSkillModule = baseSkillFolder:FindFirstChild(baseSkillName)
	if not baseSkillModule or not baseSkillModule:IsA("ModuleScript") then
		Log.warn(LOG_PREFIX, context, "未找到基础技能配置:", baseSkillName)
		return false
	end

	local result = _safeRequireModule(baseSkillModule, context, baseSkillName)
	if not result then
		return false
	end
	local config = _asBaseSkillConfig(result, context, baseSkillName)
	if not config then
		return false
	end

	_appendBaseSkillLists(config, modelNames, animationNames, soundNames)
	return true
end

-- ============================================================================
-- 公共 API
-- ============================================================================

--[[
	预加载动作资源（按动作名称）
	通过 AnimationModule 将动作名称转换为 ID 后预加载，已预加载过的不会重复加载
	@param animationNames { string } - 动作名称数组（如 {"魔法弹1", "普攻一段"}）；非 table 则跳过
	@return nil - 无返回值
]]
function SkillPreloadUtil.PreloadAnimations(animationNames: { string })
	if type(animationNames) ~= "table" then
		Log.warn(LOG_PREFIX, "PreloadAnimations 需要 string 数组")
		return
	end
	_preloadAnimationsByNames(animationNames, "PreloadAnimations")
end

--[[
	预加载音频资源（按音频名称）
	在 SoundService 中按名称查找 Sound 实例后预加载，完成后恢复资源 ID
	已预加载过的不会重复加载
	@param soundNames { string } - 音频名称数组（如 {"通用受击", "技能释放"}）；非 table 则跳过
	@return nil - 无返回值
]]
function SkillPreloadUtil.PreloadSounds(soundNames: { string })
	if type(soundNames) ~= "table" then
		Log.warn(LOG_PREFIX, "PreloadSounds 需要 string 数组")
		return
	end
	_preloadSoundsByNames(soundNames)
end

--[[
	预加载基础技能资源
	根据基础技能名称直接查找配置，预加载其 ResNameList、AnimateList、SoundList
	@param baseSkillName string - 基础技能名称（如 "MagicMissile1"、"Meteor1"）
	@return nil - 无返回值
]]
function SkillPreloadUtil.PreloadBaseSkill(baseSkillName: string)
	if not _isNonEmptyString(baseSkillName) then
		Log.warn(LOG_PREFIX, "PreloadBaseSkill 技能名无效")
		return
	end

	local systemSkill = _getSystemSkillFolder()
	local baseSkillFolder = systemSkill and systemSkill:FindFirstChild(SKILL_MODULE_FOLDER)
	local skillResFolder = _getSkillResFolder()

	if not baseSkillFolder or not skillResFolder then
		Log.warn(LOG_PREFIX, "PreloadBaseSkill 技能配置或资源目录不存在:", baseSkillName)
		return
	end

	local modelNamesToPreload: { string } = {}
	local animationNamesToPreload: { string } = {}
	local soundNamesToPreload: { string } = {}

	if not _collectBaseSkillLists(
		baseSkillFolder,
		baseSkillName,
		modelNamesToPreload,
		animationNamesToPreload,
		soundNamesToPreload,
		"PreloadBaseSkill"
	) then
		return
	end

	_executePreload(
		_dedupeStrings(modelNamesToPreload),
		_dedupeStrings(animationNamesToPreload),
		_dedupeStrings(soundNamesToPreload),
		skillResFolder
	)
end

--[[
	预加载技能资源
	根据组技能名称查找配置，收集所有基础技能的 ResNameList、AnimateList、SoundList 并预加载
	组技能配置 groupConfig.Skill 为条目表/数组，每项须含 baseSkillName: string 指向基础技能模块名
	@param skillName string - 组技能名称（如 "Meteor"、"Tornado"）
	@return nil - 无返回值
]]
function SkillPreloadUtil.PreloadSkill(skillName: string)
	if not _isNonEmptyString(skillName) then
		Log.warn(LOG_PREFIX, "PreloadSkill 技能名无效")
		return
	end

	local systemSkill = _getSystemSkillFolder()
	local groupSkillFolder = systemSkill and systemSkill:FindFirstChild(GROUP_SKILL_MODULE_FOLDER)
	local baseSkillFolder = systemSkill and systemSkill:FindFirstChild(SKILL_MODULE_FOLDER)
	local skillResFolder = _getSkillResFolder()

	if not groupSkillFolder or not baseSkillFolder or not skillResFolder then
		Log.warn(LOG_PREFIX, "PreloadSkill 技能配置或资源目录不存在:", skillName)
		return
	end

	local groupSkillModule = groupSkillFolder:FindFirstChild(skillName)
	if not groupSkillModule or not groupSkillModule:IsA("ModuleScript") then
		Log.warn(LOG_PREFIX, "PreloadSkill 未找到组技能配置:", skillName)
		return
	end

	local groupResult = _safeRequireModule(groupSkillModule, "PreloadSkill", skillName)
	if type(groupResult) ~= "table" or type(groupResult.Skill) ~= "table" then
		Log.warn(LOG_PREFIX, "PreloadSkill 组技能配置无效或缺少 Skill 字段:", skillName)
		return
	end

	local modelNamesToPreload: { string } = {}
	local animationNamesToPreload: { string } = {}
	local soundNamesToPreload: { string } = {}

	for _, skillEntry in pairs(groupResult.Skill) do
		if type(skillEntry) ~= "table" then
			continue
		end
		local baseSkillName = skillEntry.baseSkillName
		if not _isNonEmptyString(baseSkillName) then
			continue
		end

		_collectBaseSkillLists(
			baseSkillFolder,
			baseSkillName,
			modelNamesToPreload,
			animationNamesToPreload,
			soundNamesToPreload,
			"PreloadSkill"
		)
	end

	_executePreload(
		_dedupeStrings(modelNamesToPreload),
		_dedupeStrings(animationNamesToPreload),
		_dedupeStrings(soundNamesToPreload),
		skillResFolder
	)
end

return SkillPreloadUtil
