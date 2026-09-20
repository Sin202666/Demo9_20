--[[
	Module: SkillHitPresentation/SkillHitPresentationClient
	Description: 客户端技能命中表现（FXUtil.PlayEffect + 3D 受击音效）
	Author: 林奥宇
	Created: 2026-08-17
	Last Modified: 2026-09-01

	能力：
	- handleIncoming：处理 NetMsg.SKILL_HIT_PRESENTATION 合并包，逐条播特效与音效
	- 命中特效走 PlayEffect usePool（类型 3）；3D 受击音经 SoundInstance 池化宿主/Sound
	- 不写位姿/速度；不结算伤害；payload 缺字段时静默跳过该条

	由 SkillHitPresentation 门面在客机转发。EnemyManager 注册 Remote 后调用门面。

	加载：
		SkillHitPresentation.handleIncoming(payload)
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local FXUtil = Utils.FXUtil
local SoundModule = Utils.SoundModule

local SkillHitPresentationClient = {}

local HIT_EFFECT_EMIT_TIME = 4
local HIT_EFFECT_TYPE = 3
local DEFAULT_TARGET_SCALE = 1

--[[
	播放单条命中表现
	@param entry table - { effectName: string, soundNames: { string }, hitPos: Vector3, targetScale: number? }；缺字段则跳过
]]
local function _playEntry(entry: { effectName: string, soundNames: { string }, hitPos: Vector3, targetScale: number? })
	local effectName = entry.effectName
	local hitPos = entry.hitPos
	if typeof(effectName) ~= "string" or effectName == "" or typeof(hitPos) ~= "Vector3" then
		return
	end

	local targetScale = entry.targetScale
	if typeof(targetScale) ~= "number" or targetScale <= 0 then
		targetScale = DEFAULT_TARGET_SCALE
	end

	FXUtil.PlayEffect(effectName, CFrame.new(hitPos), HIT_EFFECT_EMIT_TIME, HIT_EFFECT_TYPE, nil, targetScale, {
		usePool = true,
	})

	local soundNames = entry.soundNames
	if type(soundNames) ~= "table" then
		return
	end

	for _, soundName in soundNames do
		if typeof(soundName) == "string" and soundName ~= "" then
			SoundModule:PlaySoundLocal({
				SoundName = soundName,
				Is2D = false,
				PlayPosition = hitPos,
			})
		end
	end
end

--[[
	处理 NetMsg.SKILL_HIT_PRESENTATION 下行（AOE 合并包）
	@param payload { table } - { effectName: string, soundNames: { string }, hitPos: Vector3, targetScale: number? }[]
]]
function SkillHitPresentationClient.handleIncoming(payload: { any })
	if type(payload) ~= "table" then
		return
	end

	for _, entry in payload do
		if type(entry) == "table" then
			_playEntry(entry)
		end
	end
end

return SkillHitPresentationClient
