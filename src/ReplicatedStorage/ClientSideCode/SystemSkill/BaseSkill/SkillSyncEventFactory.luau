--[[
	同步事件 payload 工厂
	统一 schema，避免字段拼错、多传少传、重命名遗漏

	多重雷跃路径打包不依赖 SkillModule.MultThunderTrample1（该技能属具体项目，框架可能未带）。
]]
local SkillEventConst = require(script.Parent.SkillEventConst)

local SkillSyncEventFactory = {}

local SYNC = SkillEventConst.SyncEventType

--[[
	将四点路径压成扁平 12 个数，便于 Remote 同步（与 MultThunderTramplePath.packPathPointsForSync 一致）
	@param points { Vector3 } - 至少 4 个路径点
	@return { number } - 长度 12 的扁平数组
]]
local function packPathPointsForSync(points: { Vector3 }): { number }
	local packed: { number } = {}
	for i = 1, 4 do
		local p = points[i]
		local base = (i - 1) * 3
		packed[base + 1] = p.X
		packed[base + 2] = p.Y
		packed[base + 3] = p.Z
	end
	return packed
end

--[[
	基础上下文（技能实例通用字段）
]]
function SkillSyncEventFactory.baseContext(skill)
	return {
		skillName = skill.skillName,
		skillCastId = skill.skillCastId,
		baseSkillInstanceId = skill.baseSkillInstanceId,
		activeBaseSkillIndex = skill.activeBaseSkillIndex,
		characterId = skill.characterId,
		characterType = skill.characterType,
		timelineTime = skill.nowTime,
	}
end

--[[
	ProjectileHitConfirmed payload
]]
function SkillSyncEventFactory.projectileHitConfirmed(skill, hitPosition, hitType, targetId)
	local data = SkillSyncEventFactory.baseContext(skill)
	data.eventType = SYNC.ProjectileHitConfirmed
	data.hitPosition = hitPosition
	data.hitType = hitType
	data.targetId = targetId
	return data
end

--[[
	BaseSkillStarted payload
]]
function SkillSyncEventFactory.baseSkillStarted(runtime, firstSkillConfig, clientObserverMaxDuration: number?)
	local owner = runtime.owner
	local firstBaseSkill = runtime.baseSkills[1]
	local snap = runtime.castInputSnapshot
	local mttPoints = snap and snap.multThunderPathPoints
	local mttPacked = nil
	if type(mttPoints) == "table" and #mttPoints >= 4 then
		mttPacked = packPathPointsForSync(mttPoints)
	end
	return {
		eventType = SYNC.BaseSkillStarted,
		skillCastId = runtime.skillCastId,
		baseSkillInstanceId = firstBaseSkill and firstBaseSkill.baseSkillInstanceId or (runtime.skillCastId .. "_B1"),
		activeBaseSkillIndex = 1,
		characterId = owner.characterId,
		characterType = owner.characterType,
		skillName = firstSkillConfig.baseSkillName,
		releaseCF = runtime.castInputSnapshot and runtime.castInputSnapshot.releaseCF,
		targetCF = runtime.castInputSnapshot and runtime.castInputSnapshot.targetCF,
		moveDirectionStr = runtime.castInputSnapshot and runtime.castInputSnapshot.moveDirectionStr,
		combatSeed = runtime.combatSeed,
		skillPower = owner.skillPower,
		skillPurity = owner.skillPurity,
		skillID = owner.skillID,
		mpTp = owner.mpTp,
		slotIndex = owner.slotIndex,
		groupSkillName = owner.skillName,
		trackTargetId = runtime.castInputSnapshot and runtime.castInputSnapshot.trackTargetId,
		skillTargetData = runtime.castInputSnapshot and runtime.castInputSnapshot.skillTargetData,
		moveFaceMode = runtime.castInputSnapshot and runtime.castInputSnapshot.moveFaceMode,
		moveFaceWorldPos = runtime.castInputSnapshot and runtime.castInputSnapshot.moveFaceWorldPos,
		multThunderPathPoints = mttPoints,
		multThunderPathPacked = mttPacked,
		multThunderSpawnGround = snap and snap.multThunderSpawnGround,
		approachLandWorldPos = snap and snap.approachLandWorldPos,
		clientObserverMaxDuration = clientObserverMaxDuration,
	}
end

--[[
	BaseSkillDerived payload
]]
function SkillSyncEventFactory.baseSkillDerived(runtime, fromIndex, toIndex, nextBaseSkill, nextSkillConfig)
	local owner = runtime.owner
	return {
		eventType = SYNC.BaseSkillDerived,
		skillCastId = runtime.skillCastId,
		fromBaseSkillIndex = fromIndex,
		toBaseSkillIndex = toIndex,
		breakLastSkill = nextSkillConfig.breakLastSkill,
		releaseCF = runtime.castInputSnapshot and runtime.castInputSnapshot.releaseCF,
		targetCF = runtime.castInputSnapshot and runtime.castInputSnapshot.targetCF,
		moveDirectionStr = runtime.castInputSnapshot and runtime.castInputSnapshot.moveDirectionStr,
		combatSeed = runtime.combatSeed,
		characterId = owner.characterId,
		characterType = owner.characterType,
		skillName = nextSkillConfig.baseSkillName,
		baseSkillInstanceId = nextBaseSkill.baseSkillInstanceId,
		activeBaseSkillIndex = toIndex,
		nextBaseSkillName = nextSkillConfig.baseSkillName,
		skillPower = owner.skillPower,
		skillPurity = owner.skillPurity,
		skillID = owner.skillID,
		mpTp = owner.mpTp,
		trackTargetId = runtime.castInputSnapshot and runtime.castInputSnapshot.trackTargetId,
		skillTargetData = runtime.castInputSnapshot and runtime.castInputSnapshot.skillTargetData,
	}
end

--[[
	近身追加落雷波次：服务端检测到的落点与采样中心，客户端据此播预警/落雷（不再本地重算目标）
]]
function SkillSyncEventFactory.proximityStrikeWave(skill, waveIndex: number, centerPos: Vector3, positions: { Vector3 })
	local data = SkillSyncEventFactory.baseContext(skill)
	data.eventType = SYNC.ProximityStrikeWave
	data.waveIndex = waveIndex
	data.centerPos = centerPos
	data.positions = positions
	return data
end

--[[
	太阳耀斑单颗陨石：服务端开飞时裁决 start/end，客户端据此播太阳坠落（不再本地重算落点）
]]
function SkillSyncEventFactory.solarFlareMeteorShot(
	skill,
	meteorIndex: number,
	startPos: Vector3,
	endPos: Vector3
)
	local data = SkillSyncEventFactory.baseContext(skill)
	data.eventType = SYNC.SolarFlareMeteorShot
	data.meteorIndex = meteorIndex
	data.startPos = startPos
	data.endPos = endPos
	return data
end

--[[
	直线弹道：服务端裁决 start/end/flyDir，客户端子弹表现与 Hitbox 对齐
]]
function SkillSyncEventFactory.projectilePathConfirmed(
	skill,
	projectileIndex: number,
	startPos: Vector3,
	endPos: Vector3,
	flyDir: Vector3
)
	local data = SkillSyncEventFactory.baseContext(skill)
	data.eventType = SYNC.ProjectilePathConfirmed
	data.projectileIndex = projectileIndex
	data.startPos = startPos
	data.endPos = endPos
	data.flyDir = flyDir
	return data
end

--[[
	基础技能状态机单次转移（客户端与观战统一 TryTransition 同一事件名）
]]
--[[
	由 BaseSkillServer 实例直接构造（无 GroupSkillInstanceRuntime 时，如跳跃打断同步）
]]
function SkillSyncEventFactory.baseSkillStateTransitionFromSkill(
	baseSkill: any,
	transitionEventName: string,
	groupSkillName: string?
)
	local sid = baseSkill.skillInputData
	local data = SkillSyncEventFactory.baseContext(baseSkill)
	data.eventType = SYNC.BaseSkillStateTransition
	data.transitionEvent = transitionEventName
	data.groupSkillName = groupSkillName or baseSkill.skillName
	data.skillPower = baseSkill.skillPower
	data.skillPurity = baseSkill.skillPurity
	data.skillID = baseSkill.skillID
	data.mpTp = baseSkill.mpTp
	if sid then
		data.releaseCF = sid.releaseCF
		data.targetCF = sid.targetCF
		data.moveDirectionStr = sid.moveDirectionStr
		data.trackTargetId = sid.trackTargetId
		data.skillTargetData = sid.skillTargetData
	end
	return data
end

function SkillSyncEventFactory.baseSkillStateTransition(runtime, baseSkill, transitionEventName: string)
	local owner = runtime.owner
	return {
		eventType = SYNC.BaseSkillStateTransition,
		skillCastId = runtime.skillCastId,
		baseSkillInstanceId = baseSkill.baseSkillInstanceId,
		activeBaseSkillIndex = runtime.activeBaseSkillIndex,
		characterId = owner.characterId,
		characterType = owner.characterType,
		skillName = baseSkill.skillName,
		groupSkillName = owner.skillName,
		slotIndex = owner.slotIndex,
		transitionEvent = transitionEventName,
		timelineTime = baseSkill.nowTime,
		combatSeed = runtime.combatSeed,
		skillPower = owner.skillPower,
		skillPurity = owner.skillPurity,
		skillID = owner.skillID,
		mpTp = owner.mpTp,
		releaseCF = runtime.castInputSnapshot and runtime.castInputSnapshot.releaseCF,
		targetCF = runtime.castInputSnapshot and runtime.castInputSnapshot.targetCF,
		moveDirectionStr = runtime.castInputSnapshot and runtime.castInputSnapshot.moveDirectionStr,
		trackTargetId = runtime.castInputSnapshot and runtime.castInputSnapshot.trackTargetId,
		skillTargetData = runtime.castInputSnapshot and runtime.castInputSnapshot.skillTargetData,
	}
end

return SkillSyncEventFactory
