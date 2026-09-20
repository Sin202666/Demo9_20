--[[
	Module: BgmManager
	Description: 客户端背景音乐管理器，按 BGMArea 区域切换 BGM
	Author: 林奥宇
	Created: 2026-01-19
	Last Modified: 2026-09-01

	功能：
	- 检测本地玩家是否处于 CollectionService 标记的 BGMArea 内
	- 多区域重叠时选体积最小的 Part 对应 BGM
	- 无区域时使用默认 BGM；切换时经 SoundInstance 淡入淡出

	加载方式：
	- 本文件是 StarterPlayerScripts LocalScript，客户端自动运行
	- 不是 Utils 模块，禁止 require；不要写 Utils.BgmManager

	配置（GameConfig.Bgm）：
	- 启用：false 时本 Manager 不运行
	- 默认BGM / 区域标签 / 区域BGM属性 / 淡入淡出秒 / 检测间隔秒 / 区域边界容差
	- 上述字段类型无效或越界时回退到本文件 FALLBACK_*（与 GameConfig.Bgm 默认值对齐）

	区域 Part 约定：
	- CollectionService 标签名见 GameConfig.Bgm["区域标签"]（默认 BGMArea）
	- Part 上 Attribute「BGM」值为 SoundService 中 Sound 模板 Name
	- 非 BasePart 的标签实例会被忽略

	切换约定：
	- 先创建/取得新曲再停旧曲，避免新曲失败时先静音
	- 创建失败不写入 _lastBgmName；同一曲名只 warn 一次，模板补上后可重试
	- stopSound 保留实例（DestroyAfter=false），复进区域走 playSound 复播

	音量：
	- 玩家 Setting 的 BGM 音量由同目录 SettingManager 经 SoundGroup 调节，本模块不读取 Setting

	依赖：
	- Utils.SoundInstance：BGM 播放与淡入淡出（见 SoundModule 文档 BGM 章节）
	- Utils.HumanModule：取本地角色 HumanoidRootPart
	- Utils.CollectionService：启动时缓存 BGMArea，并用 Added/Removed 维护（Heartbeat 不 GetTagged）

	示例（场景布置）：
	- 给 Part 打标签 BGMArea，设置 Attribute BGM = "世界2野外1"
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local SystemGameConfig = Utils.SystemGameConfig

if SystemGameConfig.GetValue({ "Bgm", "启用" }) == false then
	return
end

local Log = Utils.Log
local SoundInstance = Utils.SoundInstance
local LocalPlayer = Utils.LocalPlayer
local HumanModule = Utils.HumanModule
local CollectionService = Utils.CollectionService
local RunService = Utils.RunService

-- ========================================
-- 常量
-- ========================================
local BGM_SOUND_TAG_PREFIX = "AreaBGM_"
local FALLBACK_DEFAULT_BGM = "BGM1"
local FALLBACK_AREA_TAG = "BGMArea"
local FALLBACK_ATTR_NAME = "BGM"
local FALLBACK_FADE_TIME = 2
local FALLBACK_CHECK_INTERVAL = 0.5
local FALLBACK_INSIDE_EPSILON = 0.001

-- ========================================
-- 私有变量
-- ========================================
local _lastBgmName = ""
local _elapsed = 0
local _areaParts: { [BasePart]: boolean } = {}
local _warnedMissingBgm: { [string]: boolean } = {}

-- ========================================
-- 私有函数
-- ========================================

--[[
	读取 GameConfig 非空字符串；类型不对或空串时回退并告警
	@param path { string } - SystemGameConfig.GetValue 路径（如 { "Bgm", "默认BGM" }）
	@param fallback string - 配置无效时的回退值
	@return string - 有效配置或 fallback
]]
local function _getConfigString(path: { string }, fallback: string): string
	local value = SystemGameConfig.GetValue(path)
	if typeof(value) == "string" and value ~= "" then
		return value
	end
	Log.warn("BgmManager: 配置无效，使用回退值", table.concat(path, "."), fallback)
	return fallback
end

--[[
	读取 GameConfig 数字；类型不对或小于 minValue 时回退并告警
	@param path { string } - SystemGameConfig.GetValue 路径
	@param fallback number - 配置无效时的回退值
	@param minValue number - 合法下限（含）；检测间隔应 > 0，淡入淡出/容差允许 0
	@return number - 有效配置或 fallback
]]
local function _getConfigNumber(path: { string }, fallback: number, minValue: number): number
	local value = SystemGameConfig.GetValue(path)
	if typeof(value) == "number" and value >= minValue then
		return value
	end
	Log.warn("BgmManager: 配置无效，使用回退值", table.concat(path, "."), fallback)
	return fallback
end

-- ========================================
-- 运行期配置（依赖上方读取函数，与 GameConfig.Bgm 对齐）
-- ========================================
local DEFAULT_BGM = _getConfigString({ "Bgm", "默认BGM" }, FALLBACK_DEFAULT_BGM)
local BGM_AREA_TAG = _getConfigString({ "Bgm", "区域标签" }, FALLBACK_AREA_TAG)
local BGM_ATTR_NAME = _getConfigString({ "Bgm", "区域BGM属性" }, FALLBACK_ATTR_NAME)
local BGM_FADE_TIME = _getConfigNumber({ "Bgm", "淡入淡出秒" }, FALLBACK_FADE_TIME, 0)
local CHECK_INTERVAL = _getConfigNumber({ "Bgm", "检测间隔秒" }, FALLBACK_CHECK_INTERVAL, 0.01)
local INSIDE_EPSILON = _getConfigNumber({ "Bgm", "区域边界容差" }, FALLBACK_INSIDE_EPSILON, 0)

--[[
	计算 Part 体积（用于多区域重叠时选最小区域）
	@param part BasePart - 区域 Part
	@return number - 体积（Stud³）
]]
local function _getPartVolume(part: BasePart): number
	local size = part.Size
	return size.X * size.Y * size.Z
end

--[[
	判断世界坐标点是否在 Part 的轴对齐包围盒内（局部空间）
	@param point Vector3 - 世界坐标
	@param regionPart BasePart - 区域 Part
	@return boolean - 点在 Part 内为 true
]]
local function _isPointInsidePart(point: Vector3, regionPart: BasePart): boolean
	local localPos = regionPart.CFrame:PointToObjectSpace(point)
	local sx = regionPart.Size.X / 2
	local sy = regionPart.Size.Y / 2
	local sz = regionPart.Size.Z / 2
	return math.abs(localPos.X) <= sx + INSIDE_EPSILON
		and math.abs(localPos.Y) <= sy + INSIDE_EPSILON
		and math.abs(localPos.Z) <= sz + INSIDE_EPSILON
end

--[[
	根据玩家位置解析应播放的 BGM 名
	@param rootPosition Vector3 - HumanoidRootPart 世界坐标
	@return string - Sound 模板 Name；无区域时返回默认 BGM
]]
local function _resolveTargetBgm(rootPosition: Vector3): string
	local targetBgm: string? = nil
	local smallestVolume = math.huge
	local hasBgmArea = false

	for areaPart in _areaParts do
		if not areaPart.Parent then
			_areaParts[areaPart] = nil
			continue
		end
		if not _isPointInsidePart(rootPosition, areaPart) then
			continue
		end

		local areaBgm = areaPart:GetAttribute(BGM_ATTR_NAME)
		if typeof(areaBgm) ~= "string" or areaBgm == "" then
			continue
		end

		hasBgmArea = true
		local volume = _getPartVolume(areaPart)
		if volume < smallestVolume then
			smallestVolume = volume
			targetBgm = areaBgm
		end
	end

	if not hasBgmArea then
		return DEFAULT_BGM
	end
	return targetBgm or DEFAULT_BGM
end

--[[
	切换背景音乐（SoundInstance 淡入淡出；新旧 BGM 可交叉淡变）
	按 AreaBGM_ 标签停旧曲，避免 GetSoundByName 误停同名非区域音效
	先取得新曲实例再停旧曲：新曲失败时保持当前播放，且不锁 _lastBgmName
	@param bgmName string - SoundService 中 Sound 模板 Name
	@return nil - 无返回值
]]
local function _playBgm(bgmName: string)
	if bgmName == "" or bgmName == _lastBgmName then
		return
	end

	local soundTag = BGM_SOUND_TAG_PREFIX .. bgmName
	local bgm = SoundInstance:GetSoundByTag(soundTag)
	if not bgm then
		bgm = SoundInstance:new({
			SoundName = bgmName,
			SoundTag = soundTag,
			Is2D = true,
		})
	end
	if not bgm then
		if not _warnedMissingBgm[bgmName] then
			_warnedMissingBgm[bgmName] = true
			Log.warn("BgmManager: SoundInstance 未找到，无法播放 BGM", bgmName)
		end
		return
	end

	if _lastBgmName ~= "" then
		local lastSound = SoundInstance:GetSoundByTag(BGM_SOUND_TAG_PREFIX .. _lastBgmName)
		if lastSound then
			lastSound:stopSound(BGM_FADE_TIME, false)
		end
	end

	bgm:playSound(BGM_FADE_TIME)
	_lastBgmName = bgmName
	_warnedMissingBgm[bgmName] = nil
end

--[[
	按当前角色位置更新 BGM（无角色时不处理）
	@return nil - 无返回值
]]
local function _updateBgm()
	local root = HumanModule.GetHumanoidRootPart(LocalPlayer)
	if not root then
		return
	end

	_playBgm(_resolveTargetBgm(root.Position))
end

--[[
	BGMArea 标签新增：仅缓存 BasePart
	@param instance Instance - CollectionService 新增的标签实例
	@return nil - 无返回值
]]
local function _onAreaAdded(instance: Instance)
	if instance:IsA("BasePart") then
		_areaParts[instance] = true
	end
end

--[[
	BGMArea 标签移除或实例销毁：从缓存剔除
	@param instance Instance - 被移除标签的实例
	@return nil - 无返回值
]]
local function _onAreaRemoved(instance: Instance)
	if instance:IsA("BasePart") then
		_areaParts[instance] = nil
	end
end

--[[
	Heartbeat：按检测间隔刷新当前区域 BGM
	@param dt number - 距上一帧间隔（秒）
	@return nil - 无返回值
]]
local function _onHeartbeat(dt: number)
	_elapsed += dt
	if _elapsed < CHECK_INTERVAL then
		return
	end
	_elapsed -= CHECK_INTERVAL
	_updateBgm()
end

--[[
	角色重生后立刻尝试刷新 BGM；RootPart 未就绪则靠下一帧 Heartbeat
	@param _character Model - 新角色，本函数不直接使用
	@return nil - 无返回值
]]
local function _onCharacterAdded(_character: Model)
	_elapsed = CHECK_INTERVAL
	_updateBgm()
end

-- ========================================
-- 初始化
-- ========================================
for _, instance in CollectionService:GetTagged(BGM_AREA_TAG) do
	_onAreaAdded(instance)
end
CollectionService:GetInstanceAddedSignal(BGM_AREA_TAG):Connect(_onAreaAdded)
CollectionService:GetInstanceRemovedSignal(BGM_AREA_TAG):Connect(_onAreaRemoved)
LocalPlayer.CharacterAdded:Connect(_onCharacterAdded)
RunService.Heartbeat:Connect(_onHeartbeat)
_updateBgm()
