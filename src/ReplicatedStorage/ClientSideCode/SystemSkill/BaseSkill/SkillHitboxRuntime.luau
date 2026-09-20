--[[
	Hitbox 运行时（技能宿主组件）
	职责：hitbox 创建、启停、销毁、索引映射
	命中检测与回调由 BaseSkill tick 驱动，本模块只管理 hitbox 实例生命周期

	调用方：BaseSkillServer / BaseSkillClient 在 start 时 spawn，_finish/skillEnd 时 destroyAll
	兼容：Data.hitbox[index] 仍暴露，内部由 instances 存储
]]

local Hitbox = require(script.Parent.Hitbox)
local HitPolicy = require(script.Parent.HitPolicy)

local SkillHitboxRuntime = {}

--[[
	创建 Hitbox 运行时
	@param skillInstance table 技能实例（提供 skillName, skillModule, skillInputData/combatSeed）
	@return table hitboxRuntime { owner, instances = { [HitboxIndex] = Hitbox } }
]]
function SkillHitboxRuntime.create(skillInstance)
	return {
		owner = skillInstance,
		instances = {},
	}
end

--[[
	根据 hitboxConfig 创建并注册所有 hitbox
	@param hitboxRuntime table 由 create 返回
	@param inputData table 含 characterId, characterType, combatSeed
]]
function SkillHitboxRuntime.spawnAll(hitboxRuntime, inputData)
	local skillInstance = hitboxRuntime.owner
	local hitboxConfig = skillInstance.skillModule.hitboxConfig or {}
	for _, hitboxData in hitboxConfig do
		local fullHitboxData = {
			hitboxOwnerType = inputData.characterType,
			hitboxOwnerId = inputData.characterId,
			hitboxIndex = hitboxData.HitboxIndex,
			PartName = hitboxData.PartName,
			collisionGroup = hitboxData.CollisionGroup,
			ActiveRange = hitboxData.ActiveRange or NumberRange.new(0, 0),
			EffectName = hitboxData.EffectName,
			SoundName = hitboxData.SoundName,
			PhysicsEffectName = hitboxData.PhysicsEffectName,
			skillName = skillInstance.skillName,
			combatSeed = inputData.combatSeed or skillInstance.combatSeed,
			hitPolicy = HitPolicy.fromHitboxEntry(hitboxData),
		}
		local hitbox = Hitbox.new(fullHitboxData)
		hitboxRuntime.instances[hitboxData.HitboxIndex] = hitbox
	end
end

--[[
	启动指定 hitbox
	@param hitboxRuntime table
	@param index number HitboxIndex
	@param resetCheckedParts boolean? 默认 true
]]
function SkillHitboxRuntime.startHitbox(hitboxRuntime, index, resetCheckedParts)
	local h = hitboxRuntime.instances[index]
	if h and h.start then
		h:start(resetCheckedParts)
	end
end

--[[
	停止指定 hitbox
	@param hitboxRuntime table
	@param index number
]]
function SkillHitboxRuntime.stopHitbox(hitboxRuntime, index)
	local h = hitboxRuntime.instances[index]
	if h and h.stop then
		h:stop()
	end
end

--[[
	销毁所有 hitbox
	@param hitboxRuntime table
]]
function SkillHitboxRuntime.destroyAll(hitboxRuntime)
	for _, hitbox in hitboxRuntime.instances do
		if hitbox and hitbox.destroy then
			hitbox:destroy()
		end
	end
	hitboxRuntime.instances = {}
end

return SkillHitboxRuntime
