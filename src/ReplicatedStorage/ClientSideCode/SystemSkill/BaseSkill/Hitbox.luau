--[[
	命中检测（仅检测层）
	职责：实例创建、检测、报告命中结果 { [Model] = Part, ... }；服端另补逻辑怪 id → Position
	不负责：伤害、物理、飘字 → 由 HitResolver 处理

	分层：Hitbox 检测 → BaseSkill/SkillModule 决定 → HitResolver 结算

	L3：Player/Mirror 在 GetPartsInPart 之后，若存在 SystemEnemy.collectLogicalOverlapHits 则补纯数据 OBB
	（客 stub 返回空表）；结果以 number 键写入返回表，服 HitResolver 按逻辑 id 结算。
]]
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Class = require(game.ReplicatedFirst.AllSideCode.Class.Class)
local HitQueryContext = require(script.Parent.HitQueryContext)

type Hitbox = typeof(Class.Hitbox)
type HitboxData = typeof(Class.HitboxData)

local AssetPaths = Utils.AssetPaths
local SystemEnemy = Utils.SystemEnemy

-- Hitbox 预制体：ReplicatedStorage/Assets/ModelRes/Hitbox
local HitboxPrefabFolder: Folder? = AssetPaths.Resolve("ModelRes/Hitbox", AssetPaths.Scope.Shared) :: Folder?

-- GetPartsInPart 使用 Hitbox 组做 broad phase，再按 targetCollisionGroups 过滤
local HitboxOverlapParams = OverlapParams.new()
HitboxOverlapParams.CollisionGroup = "Hitbox"

local TARGET_GROUPS_BY_OWNER = {
	Player = { Enemy = true, Summon = true },
	Mirror = { Enemy = true, Summon = true },
	NPC = { Player = true, Summon = true },
	Summon = { Enemy = true },
}

local function matchesTargetGroup(targetGroups: { [string]: boolean }, collisionGroup: string): boolean
	return collisionGroup == "Broken" or targetGroups[collisionGroup] == true
end

local Hitbox = {}
Hitbox.__index = Hitbox

--[[
    初始化命中检测
    @param self: Hitbox 命中检测对象
    @param hitboxData: table 命中检测数据
    @return Hitbox 命中检测对象
]]
function Hitbox.new(hitboxData:HitboxData)

	if not HitboxPrefabFolder then
		error("hitbox预制体目录不存在: ModelRes/Hitbox")
	end
	local hitboxPrefab = HitboxPrefabFolder:FindFirstChild(hitboxData.PartName)
	if not hitboxPrefab then
		error("hitbox预制体不存在: " .. hitboxData.PartName)
	end
	local self:Hitbox = setmetatable({}, Hitbox)
	--用作检测的部件
	self.hitboxOwnerId = hitboxData.hitboxOwnerId
	self.hitboxOwnerType = hitboxData.hitboxOwnerType
	self.hitboxIndex = hitboxData.hitboxIndex
	self.skillName = hitboxData.skillName
	self.combatSeed = hitboxData.combatSeed
	self._hitCounter = 0
	-- 短期命中缓存：用于 HitPolicy.hitOncePerTarget / repeatHitCooldown
	self.hitHistory = {}
	self._activationHitCount = 0
	self.hitPolicy = hitboxData.hitPolicy or nil
	self.hitbox = hitboxPrefab:Clone()
	self.hitbox.Parent = workspace.Debris
	self.hitbox.Transparency = 1
	self.hitbox.CanCollide = false
	self.hitbox.CanTouch = false
	self.hitbox.CanQuery = true
	self.hitbox.Name = "Hitbox" .. hitboxData.hitboxIndex
	self.hitbox.CollisionGroup = "Hitbox"

	-- 可命中的目标碰撞组（GetPartsInPart 后再按组过滤）
	self.targetCollisionGroups = TARGET_GROUPS_BY_OWNER[self.hitboxOwnerType]
	if not self.targetCollisionGroups then
		error("不支持的 hitboxOwnerType: " .. tostring(self.hitboxOwnerType))
	end
	--记录已经检测过的对象
	self.checkedParts = {}
	--是否激活检测
	self.isActive = false
	--命中特效名字
	self.hitEffectName = hitboxData.EffectName
	--命中音效名字
	self.hitSoundName = hitboxData.SoundName
	--受击物理/逻辑位移预设名（如「中等力度受击物理效果」）
	self.hitPhysicsEffectName = hitboxData.PhysicsEffectName
	return self
end

--[[
    进行一次检测
    @param self Hitbox - 命中检测对象
    @return { [Model | number]: BasePart | Vector3 }? - Model→Part；服逻辑怪为 id→中心 Position；未激活返回 nil
]]
function Hitbox.check(self:Hitbox)

	local _result = {}

	if not self.isActive then
		return nil
	end
	--进行检测

	local _checkParts = workspace:GetPartsInPart(self.hitbox,HitboxOverlapParams)

	-- MagicBlock 完美弹反：将攻击方 Model 的 PrimaryPart 与同帧 GetPartsInPart 结果一并参与检测（同源碰撞组/父级规则）
	local injectAttackerModel = self.parryInjectAttackerModel
	if injectAttackerModel then
		if injectAttackerModel.Parent then
			local part = injectAttackerModel.PrimaryPart
			if part and part:IsA("BasePart") then
				table.insert(_checkParts, part)
			end
		end
		self.parryInjectAttackerModel = nil
	end

	for _,part in _checkParts do 


		if matchesTargetGroup(self.targetCollisionGroups, part.CollisionGroup) then

			-- 查找检测 part 的父级 Model：先查一层 Parent，不是 Model 再查两层
			local _partParent = part.Parent
			if not _partParent then
				continue
			end
			if not _partParent:IsA("Model") then
				_partParent = _partParent.Parent
				if not _partParent or not _partParent:IsA("Model") then
					continue
				end
			end

			-- 可破坏物体再向上取一层父 Model
			if part.CollisionGroup == "Broken" then
				_partParent = _partParent.Parent
				if not _partParent or not _partParent:IsA("Model") then
					continue
				end
			end


			--检查是不是已经检查过这个Model
			if self.checkedParts[_partParent] then
				continue
			end

			-- 友方/己方（含主人召唤物）不参与检测，且不写入 checkedParts，弹道可穿透
			local hitQueryCtx = HitQueryContext.create(self, _partParent, nil)
			if not HitQueryContext.isDetectableTarget(hitQueryCtx) then
				continue
			end

			--print("检测到Model", _partParent.Name)
			self.checkedParts[_partParent] = true
			_result[_partParent] = part

		end


	end

	-- Player/Mirror 打逻辑怪时 workspace 扫不到纯数据体，补 OBB 相交（客 stub 返回空表）
	if (self.hitboxOwnerType == "Player" or self.hitboxOwnerType == "Mirror")
		and SystemEnemy
		and SystemEnemy.collectLogicalOverlapHits
		and self.hitbox
	then
		local shape = "Block"
		if self.hitbox.Shape == Enum.PartType.Ball then
			shape = "Ball"
		end
		local logicalHits = SystemEnemy.collectLogicalOverlapHits(
			self.hitbox:GetPivot(),
			self.hitbox.Size,
			shape,
			self.checkedParts
		)
		for enemyId, hitPos in logicalHits do
			if not self.checkedParts[enemyId] then
				self.checkedParts[enemyId] = true
				_result[enemyId] = hitPos
			end
		end
	end

	return _result
end

--[[
    开始检测
    @param self: Hitbox 命中检测对象
    @param resetCheckedParts: boolean? 为 true 时重置 checkedParts（停用再启用时建议传 true，避免二段打不到已命中目标）
]]
function Hitbox.start(self:Hitbox, resetCheckedParts: boolean?)
	-- 默认重置，避免停用再启用时二段打不到已命中目标；传 false 可保留
	if resetCheckedParts ~= false then
		self:resetCheckedParts()
	end
	self._activationHitCount = 0
	self.hitHistory = {}
	self.isActive = true
end

--[[
    停止检测
    @param self: Hitbox 命中检测对象
]]
function Hitbox.stop(self:Hitbox)
	self.isActive = false
	self.parryInjectAttackerModel = nil
end

--[[
    重置检查记录
    @param self: Hitbox 命中检测对象
]]
function Hitbox.resetCheckedParts(self:Hitbox)
	self.checkedParts = {}
end

--[[
    记录命中（供 HitResolver 在结算后调用，用于 HitPolicy.hitOncePerTarget / repeatHitCooldown）
    @param self: Hitbox
    @param targetModel: Model 命中的目标 Model
    @param nowTime: number 当前时间
]]
function Hitbox.recordHit(self:Hitbox, targetModel: Model, nowTime: number)
	if targetModel then
		self.hitHistory[targetModel] = nowTime
	end
	self._activationHitCount = (self._activationHitCount or 0) + 1
end

--[[
    销毁
    @param self: Hitbox 命中检测对象
]]
function Hitbox.destroy(self:Hitbox)
	self:resetCheckedParts()
	self.parryInjectAttackerModel = nil
	self.hitbox:Destroy()
	self = nil
end

return Hitbox