--[[
	Module: Scene
	Description: 自动战斗客户端场景（FightArea 克隆、Anime 站位、相机/锁控）
	Author: 程莘
	Created: 2026-09-22
	Last Modified: 2026-09-22

	位姿写口：仅本模块对战场展示模型 PivotTo；不写 CharacterMotion
	相机写口：战斗期间本模块唯一写 CurrentCamera（Scriptable + CameraPos）
	站位 Y：GetBoundingBox 底边对齐槽位 Part 顶面，随模型高度抬升
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local CfgFind = Utils.CfgFind
local CharacterControl = Utils.CharacterControl
local EnumMgr = Utils.EnumMgr
local LocalPlayer = Utils.LocalPlayer
local Log = Utils.Log
local ResourceUtil = Utils.ResourceUtil
local RunService = Utils.RunService
local CameraModule = Utils.CameraModule
local Workspace = game:GetService("Workspace")

local Scene = {}

local CONTROL_SOURCE = "AutoBattle"
local FIGHT_AREA_PATH = "ModelRes/FightArea/默认"
local SCENE_OFFSET = Vector3.new(0, 500, 0)
local TEAM_MY = "我方"
local TEAM_ENEMY = "敌方"
local SIDE_MY = "My"
local SIDE_ENEMY = "Enemy"

local _map: Model? = nil
local _spawnedModels: { Model } = {}
local _unitModels: { [string]: { [number]: Model } } = {
	[SIDE_MY] = {},
	[SIDE_ENEMY] = {},
}
local _cameraConn: RBXScriptConnection? = nil
local _cameraCf: CFrame? = nil
local _lockedCharacter: Model? = nil
local _activeBattleId: string? = nil

--[[
	释放角色锁
]]
local function _releaseControl()
	local character = _lockedCharacter
	_lockedCharacter = nil
	if not character then
		return
	end
	local ctrl = CharacterControl.GetForCharacter(character)
	if ctrl then
		ctrl:PopLock(CONTROL_SOURCE)
	end
end

--[[
	应用角色锁
]]
local function _applyControl()
	local character = LocalPlayer and LocalPlayer.Character
	if not character then
		return
	end
	local ctrl = CharacterControl.GetForCharacter(character)
	if not ctrl then
		return
	end
	ctrl:PushLock(CONTROL_SOURCE, {
		Move = true,
		Jump = true,
		Sprint = true,
		Interact = true,
		MovePolicy = "DisableControls",
	})
	_lockedCharacter = character
end

--[[
	停止相机跟踪并归还
]]
local function _stopCamera()
	if _cameraConn then
		_cameraConn:Disconnect()
		_cameraConn = nil
	end
	_cameraCf = nil
	local camera = Workspace.CurrentCamera
	if camera then
		camera.CameraType = Enum.CameraType.Custom
	end
	if CameraModule and CameraModule.FocusPlayer then
		CameraModule.FocusPlayer()
	end
end

--[[
	开始固定相机于 CameraPos
	@param cameraPos BasePart - 相机位置
]]
local function _startCamera(cameraPos: BasePart)
	_stopCamera()
	_cameraCf = cameraPos.CFrame
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = _cameraCf
	camera.Focus = _cameraCf
	_cameraConn = RunService.RenderStepped:Connect(function()
		local cam = Workspace.CurrentCamera
		local cf = _cameraCf
		if not cam or not cf then
			return
		end
		cam.CameraType = Enum.CameraType.Scriptable
		cam.CFrame = cf
		cam.Focus = cf
	end)
end

--[[
	清空站位模型表
]]
local function _clearUnitModels()
	table.clear(_unitModels[SIDE_MY])
	table.clear(_unitModels[SIDE_ENEMY])
end

--[[
	销毁已刷模型
]]
local function _clearModels()
	for _, model in ipairs(_spawnedModels) do
		if model and model.Parent then
			model:Destroy()
		end
	end
	table.clear(_spawnedModels)
	_clearUnitModels()
end

--[[
	销毁场景 map
]]
local function _destroyMap()
	_clearModels()
	if _map and _map.Parent then
		_map:Destroy()
	end
	_map = nil
end

--[[
	计算站位朝向 CFrame（水平朝向对面）
	@param basePos Vector3 - 站位基准点（尚未按模型高度抬升）
	@param faceToward Vector3 - 朝向目标
	@param slotPart BasePart - 槽位 Part（无朝向时回退其旋转）
	@return CFrame - 仅含水平朝向的位姿
]]
local function _facingAt(basePos: Vector3, faceToward: Vector3, slotPart: BasePart): CFrame
	local look = Vector3.new(faceToward.X, basePos.Y, faceToward.Z)
	local delta = look - basePos
	if delta.Magnitude < 0.05 then
		return CFrame.new(basePos) * (slotPart.CFrame - slotPart.CFrame.Position)
	end
	return CFrame.lookAt(basePos, look)
end

--[[
	按模型包围盒把底边对齐到槽位顶面（Y 随模型高度抬升）
	@param model Model - 已 PivotTo 朝向的展示模型
	@param slotPart BasePart - 站位 Part
]]
local function _alignModelBottomToSlotTop(model: Model, slotPart: BasePart)
	local bboxCf, size = model:GetBoundingBox()
	local bottomY = bboxCf.Position.Y - size.Y * 0.5
	local groundY = slotPart.Position.Y + slotPart.Size.Y * 0.5
	local lift = groundY - bottomY
	if math.abs(lift) < 1e-4 then
		return
	end
	model:PivotTo(model:GetPivot() + Vector3.new(0, lift, 0))
end

--[[
	在站位刷 Anime 模型
	@param side string - My / Enemy（与服 lastHit.side 对齐）
	@param teamFolder Instance - 我方 / 敌方
	@param units { any } - { slot, animeId }
	@param faceToward Vector3 - 朝向目标（用于 LookAt）
]]
local function _spawnTeam(side: string, teamFolder: Instance, units: { any }, faceToward: Vector3)
	local sideMap = _unitModels[side]
	if not sideMap then
		sideMap = {}
		_unitModels[side] = sideMap
	end
	for _, unit in ipairs(units) do
		local slot = tonumber(unit.slot)
		local animeId = tonumber(unit.animeId)
		if not slot or not animeId then
			continue
		end
		local slotPart = teamFolder:FindFirstChild(tostring(slot))
		if not slotPart or not slotPart:IsA("BasePart") then
			Log.warn("AutoBattle.Scene: 站位缺失", teamFolder.Name, slot)
			continue
		end
		local cfg = CfgFind.FindCfgByID(animeId, EnumMgr.ItemType.Anime)
		if type(cfg) ~= "table" then
			Log.warn("AutoBattle.Scene: anime 配置缺失", animeId)
			continue
		end
		local modelName = tostring(cfg.Model or "")
		if modelName == "" then
			Log.warn("AutoBattle.Scene: Model 为空", animeId)
			continue
		end
		local model = ResourceUtil.GetModel(ResourceUtil.ModelCategory.Anime, modelName)
		if not model then
			Log.warn("AutoBattle.Scene: 模型加载失败", modelName)
			continue
		end
		model.Name = string.format("%s_%d_%d", teamFolder.Name, slot, animeId)
		-- 先落到槽位中心再 Parent，GetBoundingBox 后按底边抬到槽位顶面
		model:PivotTo(_facingAt(slotPart.Position, faceToward, slotPart))
		model.Parent = _map
		_alignModelBottomToSlotTop(model, slotPart)
		sideMap[slot] = model
		table.insert(_spawnedModels, model)
	end
end

--[[
	进入战斗场景（同 battleId 幂等）
	@param snapshot table - SyncState 快照
	@return boolean - 是否成功
]]
function Scene.Enter(snapshot: { [string]: any }): boolean
	local battleId = snapshot and snapshot.battleId
	if type(battleId) ~= "string" or battleId == "" then
		return false
	end
	if _activeBattleId == battleId and _map and _map.Parent then
		return true
	end

	Scene.Leave()
	_activeBattleId = battleId

	-- ResourceUtil.Get 默认已 Clone，勿再 Clone
	local map = ResourceUtil.Get(FIGHT_AREA_PATH)
	if not map then
		Log.warn("AutoBattle.Scene: FightArea 模板缺失", FIGHT_AREA_PATH)
		_activeBattleId = nil
		return false
	end
	if not map:IsA("Model") then
		map:Destroy()
		Log.warn("AutoBattle.Scene: FightArea 不是 Model")
		_activeBattleId = nil
		return false
	end

	map.Name = "AutoBattleFightArea"
	local pivot = map:GetPivot()
	map:PivotTo(pivot + SCENE_OFFSET)
	map.Parent = Workspace
	_map = map

	local myFolder = map:FindFirstChild(TEAM_MY)
	local enemyFolder = map:FindFirstChild(TEAM_ENEMY)
	local cameraPos = map:FindFirstChild("CameraPos")

	if myFolder and enemyFolder and myFolder:IsA("Model") and enemyFolder:IsA("Model") then
		local myCenter = myFolder:GetPivot().Position
		local enemyCenter = enemyFolder:GetPivot().Position
		local myUnits = snapshot.my and snapshot.my.units or {}
		local enemyUnits = snapshot.enemy and snapshot.enemy.units or {}
		_spawnTeam(SIDE_MY, myFolder, myUnits, enemyCenter)
		_spawnTeam(SIDE_ENEMY, enemyFolder, enemyUnits, myCenter)
	else
		Log.warn("AutoBattle.Scene: 缺少我方/敌方 Model")
	end

	if cameraPos and cameraPos:IsA("BasePart") then
		_startCamera(cameraPos)
	end
	_applyControl()
	return true
end

--[[
	离开并清理战斗场景
]]
function Scene.Leave()
	_stopCamera()
	_releaseControl()
	_destroyMap()
	_activeBattleId = nil
end

--[[
	按 side + slot 取展示模型
	@param side string - My / Enemy
	@param slot number - 站位 1..N
	@return Model? - 展示模型；不存在返回 nil
]]
function Scene.GetUnitModel(side: string, slot: number): Model?
	local sideMap = _unitModels[side]
	if not sideMap then
		return nil
	end
	return sideMap[slot]
end

--[[
	当前是否在场景中
	@return boolean - true 表示在场
]]
function Scene.IsActive(): boolean
	return _map ~= nil and _map.Parent ~= nil
end

return Scene
