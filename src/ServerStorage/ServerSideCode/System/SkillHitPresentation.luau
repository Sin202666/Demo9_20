--[[
	Module: SkillHitPresentation
	Description: 玩家技能命中逻辑怪时的受击特效与音效服写口（AOE 合并包 + Nearby；客播轨在 ToolSystem stub）
	Author: 林奥宇
	Created: 2026-08-17
	Last Modified: 2026-09-01

	能力：
	- resolveProfile / resolveHitboxEntry：转发 ToolSystem Profile（只读副本）
	- beginBatch / accumulateFromLogical / flushBatch：同一次 Hitbox.check 多目标合并为一包；realDmg>0 且 Nearby 100 stud
	- handleIncoming：服 no-op（客侧 ToolSystem 实现）
	- skipPresentation / suppressPresentation / DoT 固定伤时不下发（含怪物受击音）

	与同类：
	- 只做 FX/音效通知，不写位姿/速度/WalkSpeed；受击轨走 NPCCosmeticHit
	- 权威通知仅本文件。Utils.SkillHitPresentation 服务端优先加载本模块；客户端回落 ToolSystem 播轨
	- 由 SystemEnemy.Hit 在 Despawn 前调用；不并入 SystemEnemy / HitResolver 函数体
	- 不绑 Remote（经 NetWork.FireClient SKILL_HIT_PRESENTATION）；无 Init；不进 CombatWorld；不写存档
	- Profile / SoundMap 仍在 ToolSystem 目录，本文件经 Utils.ReplicatedFirst 解析容器后 require 子脚本

	加载：
		local SkillHitPresentation = Utils.SkillHitPresentation
		SkillHitPresentation.beginBatch(attackerUserId)
		SkillHitPresentation.accumulateFromLogical(id, cfgId, realDmg, hitData)
		SkillHitPresentation.flushBatch()
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Players = Utils.Players
local NetWork = Utils.NetWork
local NetMsg = Utils.NetMsg
local CfgFind = Utils.CfgFind
local ReplicatedFirst = Utils.ReplicatedFirst

local presentationFolder = ReplicatedFirst.AllSideCode.ToolSystem:FindFirstChild("SkillHitPresentation")
local SkillHitPresentationProfile = require(presentationFolder:FindFirstChild("SkillHitPresentationProfile"))
local SkillHitPresentationSoundMap = require(presentationFolder:FindFirstChild("SkillHitPresentationSoundMap"))

local SkillHitPresentation = {}

-- ============================================================================
-- 常量
-- ============================================================================

local DEFAULT_NOTIFY_RANGE_STUDS = 100
local DEFAULT_EFFECT_NAME = "受击效果"
local DEFAULT_TARGET_SCALE = 1
local ENEMY_CONF_NAME = "enemyConf"

export type HitPresentationEntry = {
	effectName: string,
	soundNames: { string },
	hitPos: Vector3,
	targetScale: number,
}

type ActiveBatch = {
	attackerUserId: number?,
	entries: { HitPresentationEntry },
}

-- ============================================================================
-- 私有变量
-- ============================================================================

local _activeBatch: ActiveBatch? = nil

-- ============================================================================
-- 私有函数
-- ============================================================================

--[[
	读取 enemyConf.InjuredSound；空串时不播怪物受击音
	@param cfgId number - 敌人配置 ID
	@return string? - InjuredSound 键名
]]
local function _resolveInjuredSoundByCfgId(cfgId: number): string?
	local cfg = CfgFind.GetCfgByNameAndID(ENEMY_CONF_NAME, cfgId)
	if not cfg then
		return nil
	end
	local injuredSound = cfg.InjuredSound
	if typeof(injuredSound) ~= "string" or injuredSound == "" then
		return nil
	end
	return injuredSound
end

--[[
	从 hitData.hitPresentation 构建条目
	@param cfgId number - 敌人配置 ID
	@param hitData table - {
		hitPresentation: {
			effectName: string?,
			skillSoundKey: string?,
			hitPos: Vector3,
			suppressPresentation: boolean?,
		}?,
	}
	@return HitPresentationEntry? - 有效条目；缺 hitPos / 被抑制时 nil
]]
local function _buildEntryFromHitData(cfgId: number, hitData: any): HitPresentationEntry?
	local pres = hitData and hitData.hitPresentation
	if type(pres) ~= "table" then
		return nil
	end

	local hitPos = pres.hitPos
	if typeof(hitPos) ~= "Vector3" then
		return nil
	end

	if pres.suppressPresentation == true then
		return nil
	end

	local effectName = pres.effectName
	if typeof(effectName) ~= "string" or effectName == "" then
		effectName = DEFAULT_EFFECT_NAME
	end

	local soundNames = SkillHitPresentationSoundMap.resolveHitSounds(
		pres.skillSoundKey,
		_resolveInjuredSoundByCfgId(cfgId)
	)

	return {
		effectName = effectName,
		soundNames = soundNames,
		hitPos = hitPos,
		targetScale = DEFAULT_TARGET_SCALE,
	}
end

--[[
	按玩家 Nearby 过滤后合并下发
	@param entries { HitPresentationEntry } - 待下发条目
	@param _attackerUserId number? - 攻击者 UserId（预留；当前不按攻击者排除）
]]
local function _dispatchEntries(entries: { HitPresentationEntry }, _attackerUserId: number?)
	if #entries == 0 then
		return
	end

	for _, plr in Players:GetPlayers() do
		local character = plr.Character
		if character then
			local hrp = character:FindFirstChild("HumanoidRootPart")
			if hrp and hrp:IsA("BasePart") then
				local playerPos = hrp.Position
				local payload = {}

				for _, entry in entries do
					if (playerPos - entry.hitPos).Magnitude <= DEFAULT_NOTIFY_RANGE_STUDS then
						table.insert(payload, {
							effectName = entry.effectName,
							soundNames = entry.soundNames,
							hitPos = entry.hitPos,
							targetScale = entry.targetScale,
						})
					end
				end

				if #payload > 0 then
					NetWork.FireClient(plr, NetMsg.SKILL_HIT_PRESENTATION, payload)
				end
			end
		end
	end
end

-- ============================================================================
-- 公共函数
-- ============================================================================

--[[
	解析命中表现预设（只读副本）
	@param profileName string - SkillHitPresentationConfig 键名
	@return ResolvedProfile? - { effectName: string, soundKey: string, skipPresentation: boolean? }；无效为 nil
]]
function SkillHitPresentation.resolveProfile(profileName: string)
	return SkillHitPresentationProfile.resolve(profileName)
end

--[[
	从 hitbox 条目解析命中表现（HitPresentationProfile 优先，否则 EffectName 当预设键，再回退通用受击）
	@param hitboxEntry table? - { HitPresentationProfile: string?, EffectName: string? }；nil 时回退通用受击
	@return ResolvedProfile - { effectName: string, soundKey: string, skipPresentation: boolean? }
]]
function SkillHitPresentation.resolveHitboxEntry(hitboxEntry: any)
	return SkillHitPresentationProfile.resolveHitboxEntry(hitboxEntry)
end

--[[
	开始一次 Hitbox.check 批（同批多目标合并为一包）
	@param attackerUserId number? - 攻击者 UserId；nil 时仍可累积
]]
function SkillHitPresentation.beginBatch(attackerUserId: number?)
	_activeBatch = {
		attackerUserId = attackerUserId,
		entries = {},
	}
end

--[[
	结束当前批并 Nearby 下发；无条目时不发包
]]
function SkillHitPresentation.flushBatch()
	local batch = _activeBatch
	_activeBatch = nil
	if not batch or #batch.entries == 0 then
		return
	end
	_dispatchEntries(batch.entries, batch.attackerUserId)
end

--[[
	逻辑怪扣血后累积/下发命中表现（批模式写入当前批，非批立即下发）
	@param logicalId number - 运行时 id（日志/扩展预留；本函数未读）
	@param cfgId number - enemyConf id
	@param realDmg number - 实际伤害；≤0 忽略
	@param hitData table - {
		hitPresentation: {
			effectName: string?,
			skillSoundKey: string?,
			hitPos: Vector3,
			suppressPresentation: boolean?,
		}?,
		skillDotFixedDamage: number?,
		attackerPlayerId: number?,
	}
]]
function SkillHitPresentation.accumulateFromLogical(
	logicalId: number,
	cfgId: number,
	realDmg: number,
	hitData: any
)
	if realDmg <= 0 or typeof(cfgId) ~= "number" then
		return
	end
	-- DoT 固定伤走独立表现，避免与瞬时命中包叠播
	if type(hitData) == "table" and type(hitData.skillDotFixedDamage) == "number" then
		return
	end

	local entry = _buildEntryFromHitData(cfgId, hitData)
	if not entry then
		return
	end

	if _activeBatch then
		table.insert(_activeBatch.entries, entry)
		return
	end

	_dispatchEntries({ entry }, hitData and hitData.attackerPlayerId)
end

--[[
	客户端播表现入口；服 no-op
	@param _payload { table } - { effectName: string, soundNames: { string }, hitPos: Vector3, targetScale: number? }[]；服忽略
]]
function SkillHitPresentation.handleIncoming(_payload: { any })
end

return SkillHitPresentation
