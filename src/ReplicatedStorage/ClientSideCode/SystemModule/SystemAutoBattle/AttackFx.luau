--[[
	Module: AttackFx
	Description: 自动战斗攻击表现（攻方头顶火球抛物线 → 敌方站位 → 通用受击）
	Author: 程莘
	Created: 2026-09-22
	Last Modified: 2026-09-22

	触发：SystemAutoBattle.OnSyncState 携带 lastHit 时调用 PlayFromLastHit
	资源：ModelRes/Bullet/火球、ModelRes/Effect/通用受击
	目标：前排 1/3/5、后排 2/4/6 优先打对侧同排（同 slot 最先）
	仅客户端表现；不参与伤害/胜负结算
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local FXUtil = Utils.FXUtil
local Log = Utils.Log
local ResourceUtil = Utils.ResourceUtil
local Workspace = game:GetService("Workspace")

local AttackFx = {}

local SIDE_MY = "My"
local SIDE_ENEMY = "Enemy"
local BULLET_PATH = "ModelRes/Bullet/火球"
local HIT_EFFECT_NAME = "通用受击"
local FLIGHT_SEC = 0.45
local ARC_HEIGHT_RATIO = 0.35
local ARC_HEIGHT_MIN = 3
local HIT_EMIT_TIME = 1
-- PlayEffect 类型 3：单次 Emit，不把 ParticleEmitter.Enabled 常开
local HIT_EFFECT_TYPE = 3
-- 前排 1/3/5、后排 2/4/6：攻方优先打对侧同排
local FRONT_SLOTS = { 1, 3, 5 }
local BACK_SLOTS = { 2, 4, 6 }

local _getUnitModel: ((string, number) -> Model?)? = nil
local _fxGen = 0

--[[
	注册单位模型查询（由 Scene 提供）
	@param getter (side: string, slot: number) -> Model? - 查询函数
]]
function AttackFx.BindUnitResolver(getter: (side: string, slot: number) -> Model?)
	_getUnitModel = getter
end

--[[
	增代号：Leave 时调用，使飞行中的回调失效
]]
function AttackFx.Invalidate()
	_fxGen += 1
end

--[[
	取模型头顶世界坐标（优先 Head，否则包围盒顶）
	@param model Model - Anime 展示模型
	@return Vector3 - 世界坐标
]]
local function _getHeadPos(model: Model): Vector3
	local head = model:FindFirstChild("Head", true)
	if head and head:IsA("BasePart") then
		return head.Position
	end
	local bboxCf, size = model:GetBoundingBox()
	return bboxCf.Position + Vector3.new(0, size.Y * 0.5, 0)
end

--[[
	取模型受击点（包围盒中心）
	@param model Model - Anime 展示模型
	@return Vector3 - 世界坐标
]]
local function _getHitPos(model: Model): Vector3
	local bboxCf = model:GetBoundingBox()
	return bboxCf.Position
end

--[[
	对侧 side
	@param side string - My / Enemy
	@return string - 对侧
]]
local function _oppositeSide(side: string): string
	if side == SIDE_MY then
		return SIDE_ENEMY
	end
	return SIDE_MY
end

--[[
	站位所属排（前排 / 后排）
	@param slot number - 站位 1..6
	@return { number } - 同排 slot 列表（含自身）
	@return { number } - 另一排 slot 列表
]]
local function _rowSlots(slot: number): ({ number }, { number })
	for _, s in ipairs(FRONT_SLOTS) do
		if s == slot then
			return FRONT_SLOTS, BACK_SLOTS
		end
	end
	return BACK_SLOTS, FRONT_SLOTS
end

--[[
	在 slot 列表中取第一个仍挂载的单位模型
	@param targetSide string - 目标 side
	@param slots { number } - 候选 slot（按优先级）
	@param preferSlot number? - 若在列表中则提到最前
	@return Model? - 目标模型
]]
local function _firstAliveInSlots(targetSide: string, slots: { number }, preferSlot: number?): Model?
	if not _getUnitModel then
		return nil
	end
	if preferSlot then
		local preferred = _getUnitModel(targetSide, preferSlot)
		if preferred and preferred.Parent then
			return preferred
		end
	end
	for _, s in ipairs(slots) do
		if preferSlot and s == preferSlot then
			continue
		end
		local m = _getUnitModel(targetSide, s)
		if m and m.Parent then
			return m
		end
	end
	return nil
end

--[[
	解析目标模型：同 slot → 同排其余 → 另一排
	前排 1/3/5 优先打对方 1/3/5；后排 2/4/6 优先打对方 2/4/6
	@param attackerSide string - 攻方 side
	@param slot number - 攻方 slot
	@return Model? - 目标模型
]]
local function _resolveTargetModel(attackerSide: string, slot: number): Model?
	if not _getUnitModel then
		return nil
	end
	local targetSide = _oppositeSide(attackerSide)
	local preferRow, otherRow = _rowSlots(slot)
	local target = _firstAliveInSlots(targetSide, preferRow, slot)
	if target then
		return target
	end
	return _firstAliveInSlots(targetSide, otherRow, nil)
end

--[[
	确保 Debris 容器存在
	@return Instance - Debris Folder
]]
local function _getDebris(): Instance
	local debris = Workspace:FindFirstChild("Debris")
	if debris then
		return debris
	end
	local folder = Instance.new("Folder")
	folder.Name = "Debris"
	folder.Parent = Workspace
	return folder
end

--[[
	播放一次攻击表现
	@param lastHit { side: string, slot: number, damage: number } - 服快照 lastHit
]]
function AttackFx.PlayFromLastHit(lastHit: { [string]: any })
	if type(lastHit) ~= "table" or not _getUnitModel then
		return
	end
	local side = lastHit.side
	local slot = tonumber(lastHit.slot)
	if type(side) ~= "string" or not slot then
		return
	end

	local attacker = _getUnitModel(side, slot)
	if not attacker or not attacker.Parent then
		Log.warn("AttackFx: 攻方模型缺失", side, slot)
		return
	end
	local target = _resolveTargetModel(side, slot)
	if not target then
		Log.warn("AttackFx: 目标模型缺失", side, slot)
		return
	end

	local startPos = _getHeadPos(attacker)
	local endPos = _getHitPos(target)
	local bulletInst = ResourceUtil.Get(BULLET_PATH)
	if not bulletInst then
		Log.warn("AttackFx: 火球资源缺失", BULLET_PATH)
		return
	end

	local bullet: Model
	if bulletInst:IsA("Model") then
		bullet = bulletInst
	else
		local wrap = Instance.new("Model")
		wrap.Name = "AutoBattleBullet"
		bulletInst.Parent = wrap
		if bulletInst:IsA("BasePart") then
			wrap.PrimaryPart = bulletInst
		end
		bullet = wrap
	end

	local gen = _fxGen
	local startCf: CFrame
	if (endPos - startPos).Magnitude > 0.05 then
		startCf = CFrame.lookAt(startPos, endPos)
	else
		startCf = CFrame.new(startPos)
	end
	bullet:PivotTo(startCf)
	bullet.Parent = _getDebris()

	local chord = (endPos - startPos).Magnitude
	local arcH = math.max(chord * ARC_HEIGHT_RATIO, ARC_HEIGHT_MIN)
	local arc = Vector3.new(0, arcH, 0)
	local endCf: CFrame
	if (endPos - startPos).Magnitude > 0.05 then
		endCf = CFrame.lookAt(endPos, endPos + (endPos - startPos))
	else
		endCf = CFrame.new(endPos)
	end

	local scale = bullet:GetScale()
	FXUtil.Model_Parabola_Scale_Tween(
		bullet,
		FLIGHT_SEC,
		endCf,
		arc,
		scale,
		Enum.EasingStyle.Quad,
		Enum.EasingDirection.Out,
		function()
			if bullet.Parent then
				bullet:Destroy()
			end
			if gen ~= _fxGen then
				return
			end
			FXUtil.PlayEffect(HIT_EFFECT_NAME, CFrame.new(endPos), HIT_EMIT_TIME, HIT_EFFECT_TYPE)
		end
	)
end

return AttackFx
