--[[
	Module: HatchEffect/HatchConfig
	Description: 抽蛋表现常量与惰性资源引用
	Author: 林奥宇
	Created: 2026-01-29
	Last Modified: 2026-09-01

	由 HatchEffect 子模块内部调用。常量表已 freeze；资源模板经 getter 惰性缓存。
	speedScale 乘在各阶段 duration 上（越大越慢），与 init 公共 API 约定一致。
]]

-- ============================================================================
-- 服务与依赖
-- ============================================================================

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local ResourceUtil = Utils.ResourceUtil
local Log = Utils.Log

-- ============================================================================
-- 常量
-- ============================================================================

local HatchConfig = {
	CAMERA_MIN_ZOOM_MAX = 30,
	CAMERA_MIN_ZOOM_MIN = 0.5,
	MAX_HATCH_TIME = 5,
	DEFAULT_SCALE = 0.2,
	DEFAULT_REWARD_SCALE = 0.5,

	FALL_TIME = 0.85,
	FALL_DISTANCE = 5,
	CONTAINER_DISTANCE_FROM_CAMERA = -7.5,
	SHAKE_COUNT = 3,
	SHAKE_RESTORE_STEP = 0.4,
	RESTORE_TIME = 0.4,
	ENLARGE_TIME = 0.075,
	END_TIME = 0.5,

	BOX_SHAKE_OFFSET_Z = -2,
	REWARD_SCREEN_RATIO = 0.5,
	REWARD_DEPTH_DIVISOR = 4,

	ROTATE_DURATION = 1,
	WAIT_DURATION = 1.5,
	REWARD_ROTATE_START_Z = -7.35,
	REWARD_ROTATE_MOVE_Z = 4,
	REWARD_WAIT_Z = -3.35,
	END_DROP_Y = -5,
	END_CAMERA_Z = -3.35,
	END_YAW = 180,
	ROTATE_DEGREES = 360,

	HATCH_FINISH_WAIT = 1.2,
	ITEM_FINISH_WAIT = 0.6,

	POINT_LIGHT_RANGE = 5,
	POINT_LIGHT_BRIGHTNESS = 5,

	SHAKE_ANGLE_MIN = 25,
	SHAKE_ANGLE_MAX = 45,
	SHAKE_POS_OFFSET = 0.1,
	SHAKE_SCALE_SHRINK = 0.8,
	SHAKE_DURATION_INDEX_MUL = 6,
	SHAKE_DURATION_MIN_DIV = 10,
	SHAKE_RESTORE_INDEX_MUL = 0.7,
	ENLARGE_SCALE_ADD = 1.5,

	SHOW_UI_TWEEN_TIME = 0.8,
	HIDE_UI_TWEEN_TIME = 0.5,

	PARTICLE_COLOR_CYCLE = 5,
	OPEN_PARTICLE_EMIT_DIV = 2,

	STAR_OFFSET = {
		[1] = CFrame.new(0, 0, 0),
		[2] = CFrame.new(1.5, 0, -1),
		[3] = CFrame.new(-1.5, 0, -1),
		[4] = CFrame.new(-3, 0, -2),
		[5] = CFrame.new(3, 0, -2),
	},

	REWARD_OFFSET = {
		[1] = CFrame.new(0, 0, 0),
		[2] = CFrame.new(1.8, 0, -1),
		[3] = CFrame.new(-1.8, 0, -1),
		[4] = CFrame.new(-3.8, 0, -2),
		[5] = CFrame.new(3.8, 0, -2),
	},

	SHAKE_SOUND_NAMES = {
		"抽蛋_左摇1",
		"抽蛋_右摇1",
		"抽蛋_左摇2",
		"抽蛋_右摇2",
	},
}

-- ============================================================================
-- 私有变量 / 私有函数
-- ============================================================================

local _assetCache: { [string]: Instance | false } = {}

--[[
	解析 Hatch / UIGradient 等资源模板（ResourceUtil 优先，迁移期回退 Assets）

	@param relativePath string - catalog 相对路径，以 / 分段（如 Hatch/star_particles）
	@return Instance? - 模板实例；路径无效或任一段缺失时 nil
]]
local function _resolveTemplate(relativePath: string): Instance?
	local template = ResourceUtil.GetTemplate(relativePath)
	if template then
		return template
	end

	local assets = ReplicatedStorage:FindFirstChild("Assets")
	if not assets then
		return nil
	end

	local current: Instance = assets
	for _, segment in string.split(relativePath, "/") do
		if segment == "" then
			continue
		end
		local child = current:FindFirstChild(segment)
		if not child then
			return nil
		end
		current = child
	end

	return current
end

--[[
	惰性读取并缓存资源模板。未命中时写入 false，避免重复查找。

	@param cacheKey string - 缓存键（与路径一一对应）
	@param relativePath string - catalog 相对路径
	@return Instance? - 模板实例；未找到时 nil
]]
local function _getCachedTemplate(cacheKey: string, relativePath: string): Instance?
	if _assetCache[cacheKey] == nil then
		_assetCache[cacheKey] = _resolveTemplate(relativePath) or false
	end

	local cached = _assetCache[cacheKey]
	return if cached == false then nil else cached
end

-- ============================================================================
-- 公共 API
-- ============================================================================

--[[
	获取容器星星粒子模板

	@return Instance? - Hatch/star_particles；缺失时 nil
]]
function HatchConfig.getStarParticles(): Instance?
	return _getCachedTemplate("starParticles", "Hatch/star_particles")
end

--[[
	获取开箱粒子模板

	@return Instance? - Hatch/OPEN_particles；缺失时 nil
]]
function HatchConfig.getOpenParticles(): Instance?
	return _getCachedTemplate("openParticles", "Hatch/OPEN_particles")
end

--[[
	获取奖励星星发射器模板

	@return Instance? - Hatch/StarParticle；缺失时 nil
]]
function HatchConfig.getStarEmitter(): Instance?
	return _getCachedTemplate("starEmitter", "Hatch/StarParticle")
end

--[[
	获取稀有度渐变文件夹

	@return Folder? - UIGradient 文件夹；缺失或非 Folder 时 nil
]]
function HatchConfig.getGradientFolder(): Folder?
	local folder = _getCachedTemplate("gradientFolder", "UIGradient")
	if folder and folder:IsA("Folder") then
		return folder
	end
	return nil
end

--[[
	将奖励 ID 列表限制在 MAX_HATCH_TIME 内，始终返回新表（不回传入参引用）。

	@param itemIds {number} - 原始宠物 / 奖励 ID 列表
	@return {number}, number - 截断后的 ID 副本与数量；超出时 Log.warn
]]
function HatchConfig.clampRewardIds(itemIds: {number}): ({number}, number)
	local count = #itemIds
	local limit = math.min(count, HatchConfig.MAX_HATCH_TIME)
	if count > HatchConfig.MAX_HATCH_TIME then
		Log.warn("奖励数量超过最大值", count, HatchConfig.MAX_HATCH_TIME)
	end

	local clamped: {number} = table.create(limit)
	for index = 1, limit do
		clamped[index] = itemIds[index]
	end

	return clamped, limit
end

return table.freeze(HatchConfig)
