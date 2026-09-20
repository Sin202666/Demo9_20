--[[
	Module: RayCast
	Description: 射线检测门面：预设过滤 + 两点/方向检测；可选穿透全透明 BasePart
	Author: 林奥宇
	Created: 2026-03-02
	Last Modified: 2026-09-01

	功能：
	- 静态预设：Player / Enemy / Ground / All / CollisionGroup
	- RayCast（两点）、RayCastDirection（方向 + 距离）
	- customConfig 按字段覆盖预设；GetRayCastParams 返回独立 RaycastParams

	------------------------------------------------------------------------
	与相关模块
	------------------------------------------------------------------------
	本模块只做 Workspace:Raycast 封装，不写位姿/速度、不结算伤害。
	地面/挡墙探测：LogicEntityMotion、PathFindUtil、CharacterMotion 走预设 Ground 或 All。
	技能落地特效：Meteor1 / NewRoll / FXUtil 走 Ground。
	需要长期持有过滤参数时用 GetRayCastParams，不要缓存 RayCast/RayCastDirection 内部的共享实例。

	------------------------------------------------------------------------
	预设与 customConfig
	------------------------------------------------------------------------
	Player          — Include workspace.Characters
	Enemy           — Include workspace.Monster
	Ground          — Include workspace.场景，IgnoreWater=true
	All             — Exclude 空列表（检测全部）
	CollisionGroup  — 按碰撞组 Default 过滤

	customConfig 字段（均可选，有值则覆盖预设）：
		filterType              Enum.RaycastFilterType
		collisionGroup          string
		instances               { Instance }
		ignoreWater             boolean
		ignoreTransparentParts  boolean（仅 RayCast / RayCastDirection 生效）

	互斥：只要最终配置带 collisionGroup，即强制 FilterType=Exclude 且 instances 置空，
	filterType / instances 会被忽略（与 Roblox CollisionGroup 射线语义一致）。

	GetRayCastParams 只填充引擎 RaycastParams，不会穿透透明件；
	ignoreTransparentParts 仅同步检测 API 内部循环处理。

	RayCastDirection 的 maxDistance 必须 > 0；<=0 或非数字直接 nil。
	共享 RaycastParams 仅用于 RayCast / RayCastDirection 同步路径；
	跨 yield 持有同一引用会与后续调用互相覆盖。

	------------------------------------------------------------------------
	加载方式
	------------------------------------------------------------------------
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local RayCast = Utils.RayCast

	------------------------------------------------------------------------
	使用示例
	------------------------------------------------------------------------
	local hit = RayCast.RayCastDirection(origin, Vector3.new(0, -1, 0), 100, "Ground")
	local params = RayCast.GetRayCastParams("Player", { ignoreWater = true })
]]

-- ============================================================================
-- 服务引用
-- ============================================================================

local Workspace = game:GetService("Workspace")

-- ============================================================================
-- 模块引用
-- ============================================================================

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Log = Utils.Log

-- ============================================================================
-- 模块定义
-- ============================================================================

local RayCast = {}

-- ============================================================================
-- 常量
-- ============================================================================

local PRESET_PLAYER = "Player"
local PRESET_ENEMY = "Enemy"
local PRESET_GROUND = "Ground"
local PRESET_ALL = "All"
local PRESET_COLLISION_GROUP = "CollisionGroup"
local DEFAULT_PRESET = PRESET_ALL

local FOLDER_CHARACTERS = "Characters"
local FOLDER_MONSTER = "Monster"
local FOLDER_SCENE = "场景"

local DEFAULT_COLLISION_GROUP = "Default"
local TRANSPARENT_RAY_EPSILON = 0.01

-- ============================================================================
-- 类型
-- ============================================================================

export type RayCastConfig = {
	filterType: Enum.RaycastFilterType?,
	collisionGroup: string?,
	instances: { Instance }?,
	ignoreWater: boolean?,
	ignoreTransparentParts: boolean?,
}

type RayCastPresetDef = {
	filterType: Enum.RaycastFilterType?,
	collisionGroup: string?,
	workspaceFolder: string?,
	instances: { Instance }?,
	ignoreWater: boolean?,
	ignoreTransparentParts: boolean?,
}

-- ============================================================================
-- 私有变量
-- ============================================================================

local _sharedRaycastParams = RaycastParams.new()
local _workspaceFolderCache: { [string]: Instance } = {}

local RAYCAST_PRESETS: { [string]: RayCastPresetDef } = {
	[PRESET_PLAYER] = {
		filterType = Enum.RaycastFilterType.Include,
		workspaceFolder = FOLDER_CHARACTERS,
		ignoreWater = false,
		ignoreTransparentParts = false,
	},
	[PRESET_ENEMY] = {
		filterType = Enum.RaycastFilterType.Include,
		workspaceFolder = FOLDER_MONSTER,
		ignoreWater = false,
		ignoreTransparentParts = false,
	},
	[PRESET_GROUND] = {
		filterType = Enum.RaycastFilterType.Include,
		workspaceFolder = FOLDER_SCENE,
		ignoreWater = true,
		ignoreTransparentParts = false,
	},
	[PRESET_ALL] = {
		filterType = Enum.RaycastFilterType.Exclude,
		instances = {},
		ignoreWater = false,
		ignoreTransparentParts = false,
	},
	[PRESET_COLLISION_GROUP] = {
		collisionGroup = DEFAULT_COLLISION_GROUP,
		ignoreWater = false,
		ignoreTransparentParts = false,
	},
}

local DEFAULT_PRESET_CONFIG: RayCastConfig = {
	filterType = Enum.RaycastFilterType.Exclude,
	instances = {},
	ignoreWater = false,
	ignoreTransparentParts = false,
}

for _, presetDef in RAYCAST_PRESETS do
	if presetDef.instances then
		presetDef.instances = table.freeze(table.clone(presetDef.instances))
	end
	table.freeze(presetDef)
end
table.freeze(RAYCAST_PRESETS)
if DEFAULT_PRESET_CONFIG.instances then
	DEFAULT_PRESET_CONFIG.instances = table.freeze(table.clone(DEFAULT_PRESET_CONFIG.instances))
end
table.freeze(DEFAULT_PRESET_CONFIG)

-- ============================================================================
-- 私有函数
-- ============================================================================

--[[
	浅拷贝 Instance 数组，避免调用方或引擎持有预设内部表

	@param source { Instance }? - 原数组；nil 当空表
	@return { Instance } - 新数组
]]
local function _copyInstances(source: { Instance }?): { Instance }
	if not source then
		return {}
	end
	local copied = table.create(#source)
	for i = 1, #source do
		copied[i] = source[i]
	end
	return copied
end

--[[
	复制一份 RayCastConfig（instances 浅拷贝）

	@param config RayCastConfig - 源配置
	@return RayCastConfig - 独立副本
]]
local function _copyConfig(config: RayCastConfig): RayCastConfig
	return {
		filterType = config.filterType,
		collisionGroup = config.collisionGroup,
		instances = _copyInstances(config.instances),
		ignoreWater = config.ignoreWater,
		ignoreTransparentParts = config.ignoreTransparentParts,
	}
end

--[[
	按 workspace 子文件夹名解析 Include/Exclude 用的实例列表。
	命中后缓存；文件夹被移除后再 FindFirstChild，避免运动热路径每帧查找。

	@param folderName string - Workspace 下文件夹 Instance.Name
	@return { Instance } - 文件夹存在时单元素数组，否则空表
]]
local function _resolveWorkspaceFolder(folderName: string): { Instance }
	local cached = _workspaceFolderCache[folderName]
	if cached and cached.Parent == Workspace then
		return { cached }
	end

	local folder = Workspace:FindFirstChild(folderName)
	if folder then
		_workspaceFolderCache[folderName] = folder
		return { folder }
	end

	_workspaceFolderCache[folderName] = nil
	return {}
end

--[[
	将预设定义转为可应用的 RayCastConfig（instances 在调用时解析并拷贝）

	@param presetDef RayCastPresetDef - 预设定义
	@return RayCastConfig - 含已解析 instances 的配置副本
]]
local function _presetDefToConfig(presetDef: RayCastPresetDef): RayCastConfig
	local instances = presetDef.instances
	if not instances and presetDef.workspaceFolder then
		instances = _resolveWorkspaceFolder(presetDef.workspaceFolder)
	end
	return {
		filterType = presetDef.filterType,
		collisionGroup = presetDef.collisionGroup,
		instances = _copyInstances(instances),
		ignoreWater = presetDef.ignoreWater,
		ignoreTransparentParts = presetDef.ignoreTransparentParts,
	}
end

--[[
	合并预设与 customConfig 得到最终检测配置

	@param rayType string - 预设名称
	@param customConfig RayCastConfig? - 覆盖字段；nil 时仅用预设
	@return RayCastConfig - 合并后的新表，不暴露内部预设引用
]]
local function _resolveFinalConfig(rayType: string, customConfig: RayCastConfig?): RayCastConfig
	local presetDef = RAYCAST_PRESETS[rayType]
	local preset: RayCastConfig
	if presetDef then
		preset = _presetDefToConfig(presetDef)
	else
		Log.warn("未找到射线检测预设类型:", rayType, "，使用默认配置")
		preset = _copyConfig(DEFAULT_PRESET_CONFIG)
	end

	if not customConfig then
		return preset
	end

	return {
		filterType = customConfig.filterType or preset.filterType,
		collisionGroup = customConfig.collisionGroup or preset.collisionGroup,
		instances = if customConfig.instances then _copyInstances(customConfig.instances) else preset.instances,
		ignoreWater = if customConfig.ignoreWater ~= nil then customConfig.ignoreWater else preset.ignoreWater,
		ignoreTransparentParts = if customConfig.ignoreTransparentParts ~= nil
			then customConfig.ignoreTransparentParts
			else preset.ignoreTransparentParts,
	}
end

--[[
	将 RayCastConfig 写入指定 RaycastParams。
	带 collisionGroup 时强制 Exclude + 空列表，避免与 Include 列表混用。

	@param params RaycastParams - 目标参数对象
	@param config RayCastConfig - 射线过滤配置
	@return () - 无返回值
]]
local function _applyConfigToParams(params: RaycastParams, config: RayCastConfig)
	if config.collisionGroup then
		params.CollisionGroup = config.collisionGroup
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = {}
	else
		params.CollisionGroup = ""
		params.FilterType = config.filterType or Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = config.instances or {}
	end

	params.IgnoreWater = if config.ignoreWater ~= nil then config.ignoreWater else false
end

--[[
	更新模块内共享 RaycastParams（仅 RayCast / RayCastDirection 同步路径使用）

	@param config RayCastConfig - 射线过滤配置
	@return RaycastParams - 已更新的 _sharedRaycastParams 引用
]]
local function _updateSharedRaycastParams(config: RayCastConfig): RaycastParams
	_applyConfigToParams(_sharedRaycastParams, config)
	return _sharedRaycastParams
end

--[[
	透明件穿透：Exclude 把该件加入过滤后原地再打；Include 沿射线步进越过命中点。
	同一件被连续命中时加大步进，避免卡在体积内反复 Raycast。

	@param params RaycastParams - 当前检测参数（Exclude 时会改 FilterDescendantsInstances）
	@param hitPart BasePart - 本次命中的全透明件
	@param currentOrigin Vector3 - 本段射线起点
	@param unitDirection Vector3 - 单位方向
	@param hitPosition Vector3 - 命中点
	@param ignored { [Instance]: boolean } - 本轮已跳过的透明件
	@return Vector3 - 下一段起点
	@return number - 计入 traveled 的步进；Exclude 原地再打时为 0
]]
local function _skipTransparentHit(
	params: RaycastParams,
	hitPart: BasePart,
	currentOrigin: Vector3,
	unitDirection: Vector3,
	hitPosition: Vector3,
	ignored: { [Instance]: boolean }
): (Vector3, number)
	if params.FilterType == Enum.RaycastFilterType.Exclude then
		local list = table.clone(params.FilterDescendantsInstances)
		table.insert(list, hitPart)
		params.FilterDescendantsInstances = list
		ignored[hitPart] = true
		return currentOrigin, 0
	end

	local step = (hitPosition - currentOrigin).Magnitude + TRANSPARENT_RAY_EPSILON
	if ignored[hitPart] then
		step += TRANSPARENT_RAY_EPSILON
	end
	ignored[hitPart] = true
	return hitPosition + unitDirection * TRANSPARENT_RAY_EPSILON, step
end

--[[
	执行单次 Workspace 射线，可选穿透全透明 BasePart

	@param origin Vector3 - 射线起点
	@param direction Vector3 - 方向向量（含长度）
	@param params RaycastParams - 检测参数
	@param ignoreTransparentParts boolean? - true 时跳过 Transparency >= 1 的 BasePart
	@return RaycastResult? - 命中结果；无命中 nil
]]
local function _performRaycast(
	origin: Vector3,
	direction: Vector3,
	params: RaycastParams,
	ignoreTransparentParts: boolean?
): RaycastResult?
	local maxDistance = direction.Magnitude
	if maxDistance <= 0 then
		return nil
	end

	local unitDirection = direction / maxDistance
	local currentOrigin = origin
	local traveled = 0
	local ignored: { [Instance]: boolean } = {}

	while traveled < maxDistance do
		local remaining = unitDirection * (maxDistance - traveled)
		local result = Workspace:Raycast(currentOrigin, remaining, params)
		if not result then
			return nil
		end

		local hitPart = result.Instance
		if ignoreTransparentParts and hitPart:IsA("BasePart") and hitPart.Transparency >= 1 then
			local nextOrigin, step = _skipTransparentHit(
				params,
				hitPart,
				currentOrigin,
				unitDirection,
				result.Position,
				ignored
			)
			if step <= 0 then
				continue
			end
			traveled += step
			if traveled >= maxDistance then
				return nil
			end
			currentOrigin = nextOrigin
			continue
		end

		return result
	end

	return nil
end

-- ============================================================================
-- 公共 API
-- ============================================================================

--[[
	根据预设名构建独立的 RaycastParams 实例。
	不处理 ignoreTransparentParts（该字段只作用于 RayCast / RayCastDirection）。

	@param rayType string - 预设名称（Player / Enemy / Ground / All / CollisionGroup）
	@param customConfig RayCastConfig? - 覆盖预设字段；nil 时仅用预设
	@return RaycastParams - 新创建的参数对象，可安全持有与修改
]]
function RayCast.GetRayCastParams(rayType: string, customConfig: RayCastConfig?): RaycastParams
	local finalConfig = _resolveFinalConfig(rayType, customConfig)
	local params = RaycastParams.new()
	_applyConfigToParams(params, finalConfig)
	return params
end

--[[
	两点间射线检测

	@param startPos Vector3 - 射线起点
	@param endPos Vector3 - 射线终点
	@param rayType string? - 预设名称；nil 时使用 All
	@param customConfig RayCastConfig? - 覆盖预设字段
	@return RaycastResult? - 命中结果；起终点重合或无命中时 nil
]]
function RayCast.RayCast(
	startPos: Vector3,
	endPos: Vector3,
	rayType: string?,
	customConfig: RayCastConfig?
): RaycastResult?
	local direction = endPos - startPos
	if direction.Magnitude <= 0 then
		Log.warn("射线起点和终点相同，无法进行检测")
		return nil
	end

	local finalConfig = _resolveFinalConfig(rayType or DEFAULT_PRESET, customConfig)
	local params = _updateSharedRaycastParams(finalConfig)
	return _performRaycast(startPos, direction, params, finalConfig.ignoreTransparentParts)
end

--[[
	按方向向量与最大距离射线检测

	@param origin Vector3 - 射线起点
	@param direction Vector3 - 方向向量（勿为零向量）
	@param maxDistance number - 最大检测距离（stud），必须 > 0
	@param rayType string? - 预设名称；nil 时使用 All
	@param customConfig RayCastConfig? - 覆盖预设字段
	@return RaycastResult? - 命中结果；零方向、距离非法或无命中时 nil
]]
function RayCast.RayCastDirection(
	origin: Vector3,
	direction: Vector3,
	maxDistance: number,
	rayType: string?,
	customConfig: RayCastConfig?
): RaycastResult?
	if direction.Magnitude <= 0 then
		Log.warn("射线方向为零向量，无法进行检测")
		return nil
	end
	if type(maxDistance) ~= "number" or maxDistance <= 0 then
		Log.warn("射线最大距离无效，无法进行检测")
		return nil
	end

	local finalConfig = _resolveFinalConfig(rayType or DEFAULT_PRESET, customConfig)
	local params = _updateSharedRaycastParams(finalConfig)
	local castDirection = direction.Unit * maxDistance
	return _performRaycast(origin, castDirection, params, finalConfig.ignoreTransparentParts)
end

--[[
	获取所有可用预设名称（已排序）

	@return { string } - 新数组，调用方可持有
]]
function RayCast.GetAvailablePresets(): { string }
	local presets = {}
	for name in RAYCAST_PRESETS do
		table.insert(presets, name)
	end
	table.sort(presets)
	return presets
end

return RayCast
