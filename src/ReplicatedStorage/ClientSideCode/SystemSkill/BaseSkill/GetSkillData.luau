--[[
    获取技能数据
    Description: 获取技能数据
    Author: 中台组 林奥宇
    Date: 2026-02-28
    LastUpdate: 2026-02-28
    获取技能数据
    1.获取技能角色模型的方法
    2.获取技能输入数据的方法
]]
local module = {}
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local ElementTp = Utils.EnumMgr.ElementTp
local PlrAttr = Utils.EnumMgr.PlrAttr
local EnumMgr = Utils.EnumMgr
local HumanModule = Utils.HumanModule
local DeviceType = Utils.DeviceType
local GetData = Utils.GetData
local CfgFind = Utils.CfgFind
local SystemGameConfig = Utils.SystemGameConfig
local Class = require(game.ReplicatedFirst.AllSideCode.Class.Class)
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GroupSkillFolder = ReplicatedStorage.ClientSideCode.SystemSkill.GroupSkillModule
local BaseSkillFolder = ReplicatedStorage.ClientSideCode.SystemSkill.SkillModule

type SkillAttackData = typeof(Class.SkillAttackData)
type SkillDefendData = typeof(Class.SkillDefendData)

-- 元素种类与数值统一使用 Utils.EnumMgr.ElementTp（勿再维护重复枚举）
-- 克制规则与 GetData.GetDmg 中 strongMap 一致：强克 2×，被克或同元素 0.5×，其余 1×
local function elementCounterMult(atk: number, def: number): number
	if atk == ElementTp.None or def == ElementTp.None then
		return 1
	end
	local strongMap = {
		[ElementTp.Fire] = ElementTp.Wind,
		[ElementTp.Wind] = ElementTp.Earth,
		[ElementTp.Earth] = ElementTp.Water,
		[ElementTp.Water] = ElementTp.Fire,
		[ElementTp.Light] = ElementTp.Dark,
		[ElementTp.Dark] = ElementTp.Light,
		[ElementTp.Thunder] = ElementTp.Water,
		[ElementTp.Ice] = ElementTp.Wind,
		[ElementTp.Space] = ElementTp.Dark,
		[ElementTp.Poison] = ElementTp.Earth,
	}
	if strongMap[atk] == def then
		return 2
	end
	if strongMap[def] == atk or atk == def then
		return 0.5
	end
	return 1
end

local elemList = {
	ElementTp.Wind,
	ElementTp.Fire,
	ElementTp.Water,
	ElementTp.Earth,
	ElementTp.Dark,
	ElementTp.Light,
	ElementTp.Thunder,
	ElementTp.Ice,
	ElementTp.Poison,
	ElementTp.Space,
}

--元素克制伤害倍率（键均为 EnumMgr.ElementTp），由 strongMap 生成，与通用伤害 GetDmg 对齐
module.ElementCounterDamage = {}
do
	module.ElementCounterDamage[ElementTp.None] = {
		[ElementTp.None] = 1,
	}
	for _, d in ipairs(elemList) do
		module.ElementCounterDamage[ElementTp.None][d] = 1
	end
	for _, a in ipairs(elemList) do
		local row = {
			[ElementTp.None] = 1,
		}
		for _, d in ipairs(elemList) do
			row[d] = elementCounterMult(a, d)
		end
		module.ElementCounterDamage[a] = row
	end
end

--[[
    获取攻击者数据
    取决于角色数据结构
    @param characterId: number 角色ID
    @param characterType: string 角色类型
    @return attackerData: SkillAttackData 攻击者数据
]]
local function buildAttackerDataFromInstance(inst: Player | Model)
	local atk = GetData.GetPlrAttr(inst, PlrAttr.Atk)
	local atkP = GetData.GetPlrAttr(inst, PlrAttr.Atk_P)
	return {
		attackPower = atk * (1 + atkP),
		criticalRate = GetData.GetPlrAttr(inst, PlrAttr.Crit_Rate),
		criticalDamage = GetData.GetPlrAttr(inst, PlrAttr.Crit_Dmg),
		elementEnhancement = ElementTp.None,
		finalDamageBonus = GetData.GetPlrAttr(inst, PlrAttr.Dmg_Bonus),
	}
end

function module.getAttackerData(characterId: number, characterType: string)
	if characterType == "Summon" then
		local summonModel = module.getCharacter("Summon", characterId)
		if summonModel then
			return buildAttackerDataFromInstance(summonModel)
		end
	elseif characterType == "Player" then
		local player = Players:GetPlayerByUserId(characterId)
		if player then
			return buildAttackerDataFromInstance(player)
		end
	elseif characterType == "NPC" then
		local npcModel = module.getCharacter("NPC", characterId)
		if npcModel then
			return buildAttackerDataFromInstance(npcModel)
		end
	end

	-- 占位：找不到实体时回退
	return {
		attackPower = 1,
		criticalRate = 0,
		criticalDamage = 0,
		elementEnhancement = ElementTp.None,
		finalDamageBonus = 0,
	}
end

--[[
    获取被攻击者数据
    @param character: Model 角色模型
    @return defenderData: SkillDefendData 被攻击者数据
]]
function module.getDefenderData(character: Model)
	if character then
		return {
			elementResistance = 0,
			elementType = GetData.GetPlrAttr(character, PlrAttr.Ele) or ElementTp.None,
			finalDamageReduction = GetData.GetPlrAttr(character, PlrAttr.Dmg_Reduction),
		}
	end
	return {
		elementResistance = 0,
		elementType = ElementTp.None,
		finalDamageReduction = 0,
	}
end

--[[
    计算技能造成伤害
    1.技能伤害（直接伤害-可暴击）
    攻击者属性：攻击力面板、暴击率、暴击伤害、元素强化值、最终伤害加成 、技能名称 、Hitbox索引
    被攻击者属性：元素抗性、元素种类、最终伤害减免
    技能属性(由技能配置提供)：技能元素种类、技能伤害倍率

    技能伤害 = 攻击力面板 * 技能伤害倍率 * 元素克制伤害倍率 * 暴击伤害倍率 * 最终伤害加成 * 最终伤害减免 * 数值偏移

    @param attackerData: SkillAttackData 攻击者数据
    @param defenderData: SkillDefendData 被攻击者数据
    @return skillDamage: number 技能伤害

]]
--[[
	计算技能伤害（fallback：skillConf.DamageRate + 技能模块元素）
	需 attackerData.skillID（由 HitResolver 从 BaseSkillServer 写入）
]]
function module.calculateSkillDamage(attackerData: SkillAttackData, defenderData: SkillDefendData)
	if not attackerData or not defenderData then
		warn("计算技能伤害失败 攻击者或被攻击者数据为空")
		return 0, false
	end

	local skillConfig = BaseSkillFolder:FindFirstChild(attackerData.skillName)
	if not skillConfig then
		warn("计算技能伤害失败 技能配置为空")
		return 0, false
	end

	local skillConfigModule = require(skillConfig)
	local SkillDamageRateFromCfg = require(script.Parent.SkillDamageRateFromCfg)
	local damageRate = SkillDamageRateFromCfg.get(attackerData.skillID, attackerData.hitboxIndex)

	local elementType = skillConfigModule.skillElementType or ElementTp.None

	local DamageResolver = require(script.Parent.DamageResolver)
	local result = DamageResolver.resolveDamage({
		attackerData = attackerData,
		defenderData = defenderData,
		damageRate = damageRate,
		mpTp = attackerData.mpTp,
		powerMult = 1,
		canCritical = true,
		hitIndex = attackerData.hitIndex,
		hitboxIndex = attackerData.hitboxIndex,
		combatSeed = attackerData.combatSeed,
		elementType = elementType,
		randomOffset = 0.05,
	})
	return result.finalDamage, result.isCritical
end
--[[
    TODO计算Dot伤害
    1.Dot伤害（间接伤害-不可暴击）
]]

--[[
    通过角色类型和角色ID 来获取角色的模型
    @param characterType: string 角色类型
    @param characterId: number 角色ID
    @return character: Model 角色模型
]]
function module.getCharacter(characterType: string, characterId: number)
	if characterType == "Player" then
		local player = Players:GetPlayerByUserId(characterId)
		if player then
			return player.Character
		end
	elseif characterType == "NPC" then
		local NPCFolder = workspace:FindFirstChild("Monster")
		if NPCFolder then
			local NPC = NPCFolder:FindFirstChild(tostring(characterId))
			if NPC then
				return NPC
			end
		end
	elseif characterType == "Summon" then
		local summonFolder = workspace:FindFirstChild("Summons")
		if summonFolder then
			local summon = summonFolder:FindFirstChild(tostring(characterId))
			if summon then
				return summon
			end
		end
	elseif characterType == "Mirror" then
		local mirrorFolder = workspace:FindFirstChild("SpaceMirrors")
		if mirrorFolder then
			local mirror = mirrorFolder:FindFirstChild(tostring(characterId))
			if mirror and mirror:IsA("Model") then
				return mirror
			end
		end
	end
	return nil
end

--[[
    仅限本地客户端
    获取本地玩家当前的技能开始位置和目标位置
]]


local function CastAllButPlayer(_startPos:Vector3, _dir:Vector3, _lenth:number)

	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Include


	local desvt = {
		workspace["场景"],
		workspace["Monster"]
	}


	raycastParams.FilterDescendantsInstances = desvt
	raycastParams.IgnoreWater = true

	local raycastResult = workspace:Raycast(_startPos, _dir * _lenth, raycastParams)

	if raycastResult then
		return raycastResult
	else
		return nil
	end
end

--[[
	本地是否处于自瞄锁敌（与 GroupSkillClient.updateSkillInput 中 trackTargetId 条件一致）
]]
function module.isLocalPlayerAutoAimActive(): boolean
	local LocalPlayer = Players.LocalPlayer
	if GetData.GetSetting(LocalPlayer, "AILock") ~= 1 then
		return false
	end
	if HumanModule.GetIsShiftLocked() and not DeviceType.IsGamepad() then
		return false
	end
	local NowTargetCurrent: ObjectValue? = ReplicatedStorage:FindFirstChild("NowTargetCurrent") :: ObjectValue?
	if not NowTargetCurrent or not NowTargetCurrent.Value then
		return false
	end
	return true
end

--[[
	仅鼠标/触屏射线瞄准落点，不应用 AILock 锁敌覆盖（供 PlayerAimSync 与手动 getTargetCF）
]]
function module.getLocalPlayerManualAimCFrame(): CFrame?
	local LocalPlayer = Players.LocalPlayer
	local character = LocalPlayer.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return nil
	end

	if HumanModule.GetIsShiftLocked and HumanModule.GetIsShiftLocked() and DeviceType.IsMobile() then
		local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
		local mobieMouse = playerGui and playerGui:FindFirstChild("MobieMouse")
		local Icon = mobieMouse and mobieMouse:FindFirstChild("mouseIcon")
		if Icon and Icon:IsA("GuiObject") then
			local playpos = Icon.AbsolutePosition + Icon.AbsoluteSize / 2
			local Camera = workspace.CurrentCamera
			if Camera then
				local unitRay = Camera:ScreenPointToRay(playpos.X, playpos.Y, 1000)
				local lenth = 1000
				local unit = unitRay.Direction.Unit
				local selectCF = CFrame.new(Camera.CFrame.Position + lenth * unit, Camera.CFrame.Position + (lenth + 1) * unit)
				local Ray = CastAllButPlayer(Camera.CFrame.Position, unit, lenth)
				if Ray then
					selectCF = selectCF.Rotation + Ray.Position
				end
				return selectCF
			end
		end
	end

	local Mouse = LocalPlayer:GetMouse()
	return Mouse.Hit
end

function module.getLocalPlayerSkillInputData()
	local LocalPlayer = Players.LocalPlayer
	local character = LocalPlayer.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return CFrame.new(), CFrame.new()
	end

	local characterCF = hrp:GetPivot()
	local selectCF = module.getLocalPlayerManualAimCFrame() or characterCF

	if module.isLocalPlayerAutoAimActive() then
		local NowTargetCurrent: ObjectValue = ReplicatedStorage:FindFirstChild("NowTargetCurrent") :: ObjectValue
		if NowTargetCurrent and NowTargetCurrent.Value then
			selectCF = NowTargetCurrent.Value:GetPivot()
		end
	end

	return characterCF, selectCF
end

--[[
    获取角色朝向 如果角色没有移动方向 则用摄像机水平方向作为移动方向
	如果角色有移动方向 且没有ShiftLock 默认使用前方 如果有ShiftLock 则使用ShiftLock方向
    @param character Model 角色模型
    @return DirectionStr String 角色朝向方向
    @return moveDir2D Vector3? 角色朝向角度
]]
function module.getCharacterDirectionStr(character: Model): string
	local moveDir2D = Vector3.new(0, 0, 0)
	local moveDir2DMagnitude = 0
	if not character then
		return "Forward"
	end
	local HRP = character:FindFirstChild("HumanoidRootPart")
	if not HRP then
		return "Forward"
	end
	local Humanoid = character:FindFirstChildOfClass("Humanoid")
	if not Humanoid then
		return "Forward"
	end
	-- 获取角色的 CFrame（包含位置和朝向信息）
	local characterCFrame = HRP:GetPivot()

	-- 获取角色朝向向量（前方方向，在局部坐标系中是 -Z 轴方向）
	local lookVector = characterCFrame.LookVector

	-- 获取移动方向向量（世界坐标系）
	local moveDirection = Humanoid.MoveDirection

	-- 将移动方向投影到 XZ 平面（忽略 Y 轴，只考虑水平移动）
	moveDir2D = Vector3.new(moveDirection.X, 0, moveDirection.Z)
	moveDir2DMagnitude = moveDir2D.Magnitude

	-- 获取ShiftLock方向 如果角色有移动方向 且没有ShiftLock 默认使用前方 如果有ShiftLock 则使用ShiftLock方向
	if game["Run Service"]:IsClient() then
		if Players.LocalPlayer == Players:GetPlayerFromCharacter(character) then
			local IsShiftLocked = Players.LocalPlayer:GetAttribute("IsShiftLocked")
			if not IsShiftLocked and moveDir2DMagnitude>0 then
				return "Forward", moveDir2D
			end
		end

		-- 如果移动向量长度太小（角色没有移动），返回默认的前滚方向
		local MOVE_THRESHOLD = 0.1
		if moveDir2DMagnitude < MOVE_THRESHOLD then
			--仅限本地玩家 如果角色没有移动方向 则用摄像机水平方向作为移动方向
			if Players.LocalPlayer == Players:GetPlayerFromCharacter(character) then
				local cameraLookVector = workspace.CurrentCamera.CFrame.LookVector
				moveDir2D = Vector3.new(cameraLookVector.X, 0, cameraLookVector.Z)
				moveDir2DMagnitude = moveDir2D.Magnitude
				return "Forward",  moveDir2D
			end
			return "Forward"
		end
	end

	local lookDir2D = Vector3.new(lookVector.X, 0, lookVector.Z)

	-- 归一化向量（确保长度为 1）
	local moveDir2DNormalized = moveDir2D.Unit
	local lookDir2DNormalized = lookDir2D.Magnitude > 0 and lookDir2D.Unit or lookDir2D

	-- 计算两个向量在 XZ 平面上的夹角（使用点积）
	-- dot = cos(angle)，所以 angle = acos(dot)
	local dot = moveDir2DNormalized:Dot(lookDir2DNormalized)
	-- 限制 dot 在 [-1, 1] 范围内，避免数值误差
	dot = math.clamp(dot, -1, 1)
	local angle = math.acos(dot)

	-- 使用叉积判断角度方向（顺时针还是逆时针）
	-- 在 XZ 平面，叉积的 Y 分量表示旋转方向
	local cross = moveDir2DNormalized:Cross(lookDir2DNormalized)
	local angleDegrees = math.deg(angle)

	-- 如果叉积 Y < 0，角度为负（逆时针，左侧）
	-- 如果叉积 Y > 0，角度为正（顺时针，右侧）
	if cross.Y < 0 then
		angleDegrees = -angleDegrees
	end

	-- 根据夹角范围判断方向
	-- 角度范围：
	-- -45° 到 45°：Forward（前方）
	-- 45° 到 135°：Right（右侧）
	-- 135° 到 -135°（或 180° 到 -180°）：Back（后方）
	-- -135° 到 -45°：Left（左侧）
	local direction = "Forward"

	if angleDegrees >= -45 and angleDegrees < 45 then
		-- 前方（-45° 到 45°）
		direction = "Forward"
	elseif angleDegrees >= 45 and angleDegrees < 135 then
		-- 右侧（45° 到 135°）
		direction = "Right"
	elseif angleDegrees >= 135 or angleDegrees < -135 then
		-- 后方（135° 到 -135°）
		direction = "Backward"
	elseif angleDegrees >= -135 and angleDegrees < -45 then
		-- 左侧（-135° 到 -45°）
		direction = "Left"
	end

	return direction
end

--[[
	用于限制 技能的施法距离
	@param _releaseCF : CFrame 施法位置
	@param _targetCF : CFrame 目标位置
	@param _limitedDistance : number? 施法距离限制为nil时 没有距离限制
]]
function module.getLimitedTargetCF(_releaseCF:CFrame,_targetCF:CFrame,_limitedDistance:number?)

	if not _limitedDistance then
		return _targetCF
	end

	local _distanceVec = _targetCF.Position - _releaseCF.Position

	if _distanceVec.Magnitude <= _limitedDistance then
		return _targetCF
	else
		return _targetCF.Rotation + _releaseCF.Position + _distanceVec.Unit * _limitedDistance
	end

end

--[[
	解析玩家施法 targetCF 最大距离：skillConf.Range > 0 优先，否则 GameConfig 默认瞄准距离上限
	@param skillID number? - 技能配置 ID
	@return number - 钳制距离（studs）
]]
function module.resolveCastAimMaxRange(skillID: number?): number
	local fallback = SystemGameConfig.GetValue({ "技能系统", "默认瞄准距离上限" })
	if type(fallback) ~= "number" or fallback <= 0 then
		fallback = 80
	end
	if type(skillID) == "number" and skillID > 0 then
		local skillCfg = CfgFind.FindCfgByID(skillID, EnumMgr.ItemType.Skill)
		local range = skillCfg and skillCfg.Range
		if type(range) == "number" and range > 0 then
			return range
		end
	end
	return fallback
end

--[[
	服务端玩家施法输入钳制：releaseCF 用角色 Pivot，targetCF 按 maxRange 限制；不信任客户端落点。
	@param character Model - 玩家角色
	@param skillInputData table - 可变输入表（就地写回）
	@param maxRange number? - 瞄准距离上限；nil 时不钳制 target 距离（仍重写 releaseCF）
	@return table - 同一 skillInputData
]]
function module.sanitizePlayerCastInput(character: Model, skillInputData: any, maxRange: number?): any
	if not character or type(skillInputData) ~= "table" then
		return skillInputData
	end
	local releaseCF = character:GetPivot()
	skillInputData.releaseCF = releaseCF
	local clientTarget = skillInputData.targetCF
	if typeof(clientTarget) ~= "CFrame" then
		clientTarget = releaseCF
	end
	if type(maxRange) == "number" and maxRange > 0 then
		skillInputData.targetCF = module.getLimitedTargetCF(releaseCF, clientTarget, maxRange)
	else
		skillInputData.targetCF = clientTarget
	end
	return skillInputData
end

return module
