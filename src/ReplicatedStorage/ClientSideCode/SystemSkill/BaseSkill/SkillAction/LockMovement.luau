--[[
	锁定移动行为（MoveSynthesis）
	在技能释放时禁止或限制角色移动；经 CharacterMoveSpeedBind.pushModifier/popModifier，禁止裸写 WalkSpeed。
	支持 directionConfig 按朝向单独配置。
	预测 handoff：OnOver 不 pop，正式段 Start 若 hasModifier 则只接管生命周期。
	NewRoll：方向 overTime = Travel；若 Start 时 cumulativeTime 已过窗则不推 CMS（防 Create 顶层 overTime 偏长）。
]]
local SkillActionControl = require(script.Parent.Parent.SkillActionControl)

local module = {}

module.isReleasePlayerOnly = true

local RollDirection = { Forward = "Forward", Backward = "Backward", Left = "Left", Right = "Right" }

--[[
	从角色 CharacterScripts 取 MoveSpeed Bind（与 CMS 同 ModuleScript 实例）
	@param character Model - 技能主体
	@return any? - CharacterMoveSpeedBind 或 nil
]]
local function _getMoveSpeedBind(character: Model): any?
	local folder = character:FindFirstChild("CharacterScripts")
	if not folder then
		return nil
	end
	local mod = folder:FindFirstChild("CharacterMoveSpeedBind")
	if not mod or not mod:IsA("ModuleScript") then
		return nil
	end
	local ok, bind = pcall(require, mod)
	if ok then
		return bind
	end
	return nil
end

--[[
	稳定 ownerId：跨预测→正式 soft-merge 可续同一 Modifier
	@param self any - LockMovement Action 实例
	@return string - Modifier ownerId
]]
local function _modifierOwnerId(self): string
	local bs = self.baseSkill
	local skillName = if bs and type(bs.skillName) == "string" then bs.skillName else "Skill"
	local info = self.actionInfo or {}
	local startTime = info.startTime or 0
	local overTime = info.overTime or 0
	return string.format("LockMovement:%s:%s:%s", tostring(skillName), tostring(startTime), tostring(overTime))
end

function module:Create(actionInfo: any)
	self.actionInfo = actionInfo

	self.state = SkillActionControl.StateEnum.NoStart
	self.startTime = self.actionInfo.startTime
	self.overTime = self.actionInfo.overTime

	-- 移动速度倍率（0表示完全禁止移动，0.5表示50%速度）
	self.speedMultiplier = self.actionInfo.speedMultiplier or 0
	-- 按方向单独配置（可选）
	self.directionConfig = self.actionInfo.directionConfig or {}
	self._modifierOwnerId = nil
	self._handoffKeepModifier = false
end

--[[
	获取当前方向的配置（合并 directionConfig 与默认值）
]]
local function getDirectionParams(self, direction: string)
	local defaults = {
		overTime = self.actionInfo.overTime,
		speedMultiplier = self.actionInfo.speedMultiplier or 0,
	}
	local dirCfg = self.directionConfig[direction]
	if dirCfg then
		for k, v in pairs(dirCfg) do
			if v ~= nil then
				defaults[k] = v
			end
		end
	end
	return defaults
end

function module:Init()
	self.state = SkillActionControl.StateEnum.NoStart
	self._modifierOwnerId = nil
	self._handoffKeepModifier = false
end

function module:Run(cumulativeTime: number)
	-- 锁定移动不需要在Run中更新
end

function module:Start(cumulativeTime: number)
	local character = self.baseSkill.character
	if not character then
		return
	end

	local bind = _getMoveSpeedBind(character)
	if not bind then
		warn("LockMovement: CharacterMoveSpeedBind 未找到，跳过锁速")
		return
	end

	-- 从 baseSkill.skillInputData 获取方向（与技能表现同步）
	local directionStr = self.baseSkill.skillInputData and self.baseSkill.skillInputData.moveDirectionStr
	if type(directionStr) ~= "string" then
		directionStr = RollDirection.Forward
	end

	local params = getDirectionParams(self, directionStr)

	-- 应用方向相关的 overTime（Travel 从属窗）
	self.overTime = params.overTime
	local speedMultiplier = params.speedMultiplier
	if type(speedMultiplier) ~= "number" or speedMultiplier ~= speedMultiplier then
		speedMultiplier = 0
	end

	local ownerId = _modifierOwnerId(self)
	self._modifierOwnerId = ownerId
	self._handoffKeepModifier = false

	-- soft-merge / 晚 Start：已过方向 overTime，勿再推锁速（Create 顶层 overTime 可能长于 Travel）
	if type(cumulativeTime) == "number" and cumulativeTime >= self.overTime then
		if bind.hasModifier(ownerId) then
			bind.popModifier(ownerId)
		end
		self._modifierOwnerId = nil
		return
	end

	-- 预测 handoff 后正式段：modifier 已在，只接管生命周期，勿二次语义冲突
	if bind.hasModifier(ownerId) then
		-- 覆盖同 owner 以刷新 mul（与当前方向配置对齐）
		bind.pushModifier(ownerId, { mul = speedMultiplier })
		return
	end

	bind.pushModifier(ownerId, { mul = speedMultiplier })
end

function module:OnOver(cumulativeTime: number)
	-- 预测 handoff：保持 Modifier，由正式段接管
	if self.baseSkill and self.baseSkill._presentationPredictAnimHandoff then
		self._handoffKeepModifier = true
		return
	end

	local ownerId = self._modifierOwnerId or _modifierOwnerId(self)
	local character = self.baseSkill and self.baseSkill.character
	if not character then
		return
	end
	local bind = _getMoveSpeedBind(character)
	if not bind then
		return
	end
	bind.popModifier(ownerId)
	self._modifierOwnerId = nil
end

--[[
	软合并切入时已超过 overTime：释放预测段留下的 Modifier，避免永久锁速
	@param _cumulativeTime number - 切入累积时间（未用）
]]
function module:softMergeCatchUpPastOver(_cumulativeTime: number)
	local ownerId = self._modifierOwnerId or _modifierOwnerId(self)
	self._modifierOwnerId = ownerId
	local character = self.baseSkill and self.baseSkill.character
	if not character then
		return
	end
	local bind = _getMoveSpeedBind(character)
	if not bind then
		return
	end
	bind.popModifier(ownerId)
	self._modifierOwnerId = nil
end

return module
