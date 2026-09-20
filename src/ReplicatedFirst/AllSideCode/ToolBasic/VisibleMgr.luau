--[[
	Module: VisibleMgr
	Description: Instance 可见性、透明度、碰撞、物理属性与对象池默认视觉快照工具
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-09-01

	功能：
	- 阴影 / 粒子 / 轨迹等效果开关
	- 透明度、锚定、碰撞、速度复位（对象池 / 特效）
	- 碰撞组与业务 Attribute 标记
	- 对象池默认视觉快照（Init* Attribute）与恢复

	------------------------------------------------------------------------
	与相关模块
	------------------------------------------------------------------------
	ObjectPoolUtil / FXUtil.ObjectPool
		归还时 AnchoredAll + SpeedDown；入池/归还对齐 Snapshot / Restore。
		业务侧优先走 ResourceUtil / AssetAcquire 的对象池门面。
	FXUtil / HatchEffect
		特效与孵化模型的锚定、碰撞、质量、粒子变色。
	HumanModule / CharacterMotion
		玩家 WalkSpeed 与平面速度不归本模块。SpeedDown / SpeedDownY
		对玩家角色子树拒绝直写（结构 §1.7）。
	PlayerManager
		入服角色碰撞组走 SetPlayerCollideID。

	------------------------------------------------------------------------
	调用约束
	------------------------------------------------------------------------
	- 本模块是 ToolBasic 视觉 / 物理属性助手，不结算奖励、不写存档、不绑 Remote。
	- SpeedDown / SpeedDownY 只用于池化实例与非玩家模型；玩家角色会 Log.warn 并 return。
	- fadeAll / fadeAllTween / showAll 历史小写名保留（HitResolver 等已调用），不要改名。
	- TransparencyAll 设为完全不透明（0）；UnTransparencyAll 设为完全透明（1）。名称与语义相反，属历史 API。
	- SetTransparency / SetStandinTransparency 按当前 Transparency 乘算百分比，不是绝对值赋值。
	- RainBowParticle / SecretParticle 无独立 Cancel；Destroy 或收入 Folder 后循环停止。同一发射器重复调用不会叠第二条循环。
	- SelfWeld 使用旧版 Weld（依赖 C0/C1），不要改成 WeldConstraint。

	------------------------------------------------------------------------
	加载方式
	------------------------------------------------------------------------
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local VisibleMgr = Utils.VisibleMgr

	------------------------------------------------------------------------
	使用示例
	------------------------------------------------------------------------
		VisibleMgr.AnchoredAll(effect)
		VisibleMgr.UnCollideAll(effect)
		VisibleMgr.fadeAllTween(brokenModel, 1)
		VisibleMgr.SnapshotDefaultVisualState(template)
		VisibleMgr.RestoreDefaultVisualState(pooled)
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local TweenService = Utils.TweenService
local RunService = Utils.RunService
local Players = Utils.Players
local Log = Utils.Log

-- ========================================
-- 模块定义
-- ========================================
local VisibleMgr = {}

-- ========================================
-- 常量定义
-- ========================================
local ATTR_INIT_TRANSPARENCY = "InitTransparency"
local ATTR_INIT_ENABLED = "InitEnabled"
local ATTR_LAST_TRANSPARENCY = "LastTransparency"
local ATTR_WAS_ENABLED = "WasEnabled"
local ATTR_COLOR_LOOP = "VisibleMgrColorLoop"
local ATTR_ITEM_TYPE = "type"
local ATTR_ONLY_ID = "onlyID"
local ATTR_OWNER_ID = "OwnerID"

local COLLISION_GROUP_PLAYER = "Player"
local COLLISION_GROUP_DEFAULT = "Default"
local PART_NAME_HUMANOID_ROOT_PART = "HumanoidRootPart"
local PART_NAME_TOUCH = "touchPart"
local PART_NAME_LIGHT = "灯光"
local PART_NAME_COLLIDER = "碰撞体"

local FADE_TWEEN_DURATION = 0.8
local DEFAULT_CHARACTER_TWEEN_TIME = 0.5
local DEFAULT_CHARACTER_EASING_STYLE = Enum.EasingStyle.Quad
local DEFAULT_CHARACTER_EASING_DIR = Enum.EasingDirection.Out
local PARTICLE_COLOR_STEP = 0.1
local PARTICLE_HSV_SATURATION = 0.8
local PARTICLE_HSV_VALUE = 1
local PARTICLE_HUE_SPAN = 0.6
local PARTICLE_SECRET_VALUE_MOD = 0.3
local TRANSPARENCY_PERCENT_SCALE = 100
local DEFAULT_TRANSPARENCY_PERCENT = 100
local FULLY_TRANSPARENT = 1
local FULLY_OPAQUE = 0

local SHOW_SKIP_PART_NAMES = {
	[PART_NAME_TOUCH] = true,
	[PART_NAME_HUMANOID_ROOT_PART] = true,
	[PART_NAME_LIGHT] = true,
	[PART_NAME_COLLIDER] = true,
}
table.freeze(SHOW_SKIP_PART_NAMES)

local FADE_DISABLE_CLASSES = {
	"Beam",
	"ProximityPrompt",
	"Trail",
	"RopeConstraint",
	"SurfaceGui",
	"PointLight",
	"ParticleEmitter",
	"BillboardGui",
}
table.freeze(FADE_DISABLE_CLASSES)

local CHARACTER_FADE_EFFECT_CLASSES = {
	"ParticleEmitter",
	"Trail",
	"Beam",
	"SurfaceGui",
	"BillboardGui",
}
table.freeze(CHARACTER_FADE_EFFECT_CLASSES)

local STANDIN_TRANSPARENCY_GROUPS = {
	{
		percent = 100,
		names = {
			"LeftHand",
			"LeftLowerArm",
			"LeftUpperArm",
			"RightHand",
			"RightLowerArm",
			"RightUpperArm",
			"UpperTorso",
			"Head",
		},
	},
	{
		percent = 60,
		names = {
			"LeftUpperLeg",
			"LowerTorso",
			"RightUpperLeg",
		},
	},
	{
		percent = 30,
		names = {
			"LeftFoot",
			"LeftLowerLeg",
			"RightFoot",
			"RightLowerLeg",
		},
	},
}
for _, group in STANDIN_TRANSPARENCY_GROUPS do
	table.freeze(group.names)
	table.freeze(group)
end
table.freeze(STANDIN_TRANSPARENCY_GROUPS)

-- ========================================
-- 私有函数
-- ========================================

--[[
	保存对象原始透明度到 LastTransparency Attribute（仅首次写入）

	@param obj Instance - 支持 Transparency 的对象（BasePart、Decal、Texture 等）
	@return nil - 无返回值
]]
local function _setLastTransparency(obj: Instance)
	if obj:GetAttribute(ATTR_LAST_TRANSPARENCY) == nil then
		obj:SetAttribute(ATTR_LAST_TRANSPARENCY, (obj :: any).Transparency)
	end
end

--[[
	获取 instance 相对 root 的路径（以 / 分隔子级 Name）

	@param root Instance - 根节点
	@param target Instance - 目标节点
	@return string? - 相对路径；target 不在 root 子树内时返回 nil
]]
local function _getRelativePath(root: Instance, target: Instance): string?
	local segments: { string } = {}
	local current: Instance? = target
	while current and current ~= root do
		table.insert(segments, 1, current.Name)
		current = current.Parent
	end
	if current ~= root then
		return nil
	end
	return table.concat(segments, "/")
end

--[[
	按相对路径在 root 下查找子 Instance

	@param root Instance - 根节点
	@param relativePath string - 由 _getRelativePath 生成的路径
	@return Instance? - 找到的节点，不存在时 nil
]]
local function _findByRelativePath(root: Instance, relativePath: string): Instance?
	if relativePath == "" then
		return root
	end
	local current: Instance = root
	for segment in string.gmatch(relativePath, "[^/]+") do
		local child = current:FindFirstChild(segment)
		if not child then
			return nil
		end
		current = child
	end
	return current
end

--[[
	判断 Instance 是否支持 Transparency 属性

	@param instance Instance - 待检测实例
	@return boolean - BasePart / Decal / Texture 为 true
]]
local function _hasTransparencyProperty(instance: Instance): boolean
	return instance:IsA("BasePart") or instance:IsA("Decal") or instance:IsA("Texture")
end

--[[
	判断 Instance 是否支持 Enabled 属性（表现类）

	@param instance Instance - 待检测实例
	@return boolean - 粒子 / 轨迹 / Gui / 灯 / 提示 / 绳为 true
]]
local function _hasEnabledProperty(instance: Instance): boolean
	return instance:IsA("ParticleEmitter")
		or instance:IsA("Trail")
		or instance:IsA("Beam")
		or instance:IsA("SurfaceGui")
		or instance:IsA("BillboardGui")
		or instance:IsA("PointLight")
		or instance:IsA("ProximityPrompt")
		or instance:IsA("RopeConstraint")
end

--[[
	将当前视觉状态写入 Init* Attribute（overwrite 为 false 时仅补缺失项）

	@param instance Instance - 目标 Instance
	@param overwrite boolean? - 为 true 时覆盖已有 Init* 值
	@return nil - 无返回值
]]
local function _captureInitVisualAttributes(instance: Instance, overwrite: boolean?)
	if _hasTransparencyProperty(instance) then
		if overwrite or instance:GetAttribute(ATTR_INIT_TRANSPARENCY) == nil then
			instance:SetAttribute(ATTR_INIT_TRANSPARENCY, (instance :: any).Transparency)
		end
	end
	if _hasEnabledProperty(instance) then
		if overwrite or instance:GetAttribute(ATTR_INIT_ENABLED) == nil then
			instance:SetAttribute(ATTR_INIT_ENABLED, (instance :: any).Enabled)
		end
	end
end

--[[
	复制 Init* Attribute 自 fromInst 到 toInst

	@param fromInst Instance - 源 Instance
	@param toInst Instance - 目标 Instance
	@return nil - 无返回值
]]
local function _copyInitVisualAttributes(fromInst: Instance, toInst: Instance)
	local initTransparency = fromInst:GetAttribute(ATTR_INIT_TRANSPARENCY)
	if initTransparency ~= nil then
		toInst:SetAttribute(ATTR_INIT_TRANSPARENCY, initTransparency)
	end
	local initEnabled = fromInst:GetAttribute(ATTR_INIT_ENABLED)
	if initEnabled ~= nil then
		toInst:SetAttribute(ATTR_INIT_ENABLED, initEnabled)
	end
end

--[[
	按 Init* Attribute 恢复 Transparency / Enabled

	@param instance Instance - 目标 Instance
	@return nil - 无返回值
]]
local function _restoreInitVisualProperties(instance: Instance)
	if _hasTransparencyProperty(instance) then
		local initTransparency = instance:GetAttribute(ATTR_INIT_TRANSPARENCY)
		if initTransparency ~= nil then
			(instance :: any).Transparency = initTransparency
		end
	end
	if _hasEnabledProperty(instance) then
		local initEnabled = instance:GetAttribute(ATTR_INIT_ENABLED)
		if initEnabled ~= nil then
			(instance :: any).Enabled = initEnabled
		end
	end
end

--[[
	粒子 Heartbeat 循环是否应终止（对象已移入 Folder 收纳时停止）

	@param particle ParticleEmitter - 粒子发射器
	@return boolean - 应停止时 true
]]
local function _shouldStopParticleLoop(particle: ParticleEmitter): boolean
	local parent = particle.Parent
	if not parent then
		return true
	end
	local grandParent = parent.Parent
	if not grandParent then
		return false
	end
	local greatGrandParent = grandParent.Parent
	return greatGrandParent ~= nil and greatGrandParent:IsA("Folder")
end

--[[
	Heartbeat 驱动粒子 Color 渐变；同一发射器已有循环时不再开第二条

	@param particle ParticleEmitter - 粒子发射器
	@param speed number - 色相变化速度倍率
	@param buildColorSequence (number) -> ColorSequence - 根据 changeValue 构建 ColorSequence
	@return nil - 无返回值
]]
local function _runParticleColorLoop(
	particle: ParticleEmitter,
	speed: number,
	buildColorSequence: (changeValue: number) -> ColorSequence
)
	if particle:GetAttribute(ATTR_COLOR_LOOP) then
		return
	end
	particle:SetAttribute(ATTR_COLOR_LOOP, true)
	task.spawn(function()
		while particle.Parent do
			if _shouldStopParticleLoop(particle) then
				break
			end
			local changeValue = os.clock() * PARTICLE_COLOR_STEP * speed % 1
			particle.Color = buildColorSequence(changeValue)
			RunService.Heartbeat:Wait()
		end
		if particle.Parent then
			particle:SetAttribute(ATTR_COLOR_LOOP, nil)
		end
	end)
end

--[[
	遍历 root 子树并对每个节点执行 callback（含 root）

	@param root Instance - 根节点
	@param callback (Instance) -> () - 对每个节点执行的回调
	@return nil - 无返回值
]]
local function _forEachInSubtree(root: Instance, callback: (instance: Instance) -> ())
	callback(root)
	for _, descendant in root:GetDescendants() do
		callback(descendant)
	end
end

--[[
	对 root 及其后代中的 BasePart 执行 callback

	@param root Instance - 根节点
	@param callback (BasePart) -> () - 对每个 BasePart 执行的回调
	@return nil - 无返回值
]]
local function _forEachBasePart(root: Instance, callback: (part: BasePart) -> ())
	if root:IsA("BasePart") then
		callback(root)
	end
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BasePart") then
			callback(descendant)
		end
	end
end

--[[
	obj 或其祖先是否为玩家角色（速度写口归 CharacterMotion）

	@param obj Instance - 待检测实例
	@return boolean - 属于玩家角色子树时 true
]]
local function _isPlayerCharacterTree(obj: Instance): boolean
	local current: Instance? = obj
	while current do
		if current:IsA("Model") and Players:GetPlayerFromCharacter(current) then
			return true
		end
		current = current.Parent
	end
	return false
end

--[[
	玩家角色子树拒绝直写 Assembly 速度

	@param obj Instance - 待写入实例
	@param apiName string - 调用方 API 名，用于日志
	@return boolean - 应拒绝时 true
]]
local function _refusePlayerCharacterVelocity(obj: Instance, apiName: string): boolean
	if _isPlayerCharacterTree(obj) then
		Log.warn("VisibleMgr." .. apiName .. ": 玩家角色速度只经 CharacterMotion 写入，已拒绝直写")
		return true
	end
	return false
end

--[[
	按百分比乘算当前透明度：new = 1 - (1 - current) * (percent / 100)

	@param part BasePart - 目标部件
	@param percent number - 0–100；100 表示完全透明
	@return nil - 无返回值
]]
local function _applyTransparencyPercent(part: BasePart, percent: number)
	part.Transparency = 1 - (1 - part.Transparency) * (percent / TRANSPARENCY_PERCENT_SCALE)
end

--[[
	fadeAll / fadeAllTween / showAll 共用的表现类 Enabled 开关

	@param obj Instance - 当前节点
	@param enabled boolean - 目标 Enabled
	@return nil - 无返回值
]]
local function _setFadeEffectEnabled(obj: Instance, enabled: boolean)
	for _, className in FADE_DISABLE_CLASSES do
		if obj:IsA(className) then
			(obj :: any).Enabled = enabled
			return
		end
	end
end

--[[
	历史 fade 目标：UnionOperation / Part / MeshPart（不含 WedgePart 等其它 BasePart）

	@param obj Instance - 待检测实例
	@return boolean - 属于历史 fade 部件类型时 true
]]
local function _isLegacyFadePart(obj: Instance): boolean
	return obj:IsA("UnionOperation") or obj:IsA("Part") or obj:IsA("MeshPart")
end

--[[
	从 LastTransparency 恢复；无记录时回落到 fallback

	@param obj Instance - 支持 Transparency 的对象
	@param fallback number - Attribute 缺失时的透明度
	@return nil - 无返回值
]]
local function _restoreLastTransparency(obj: Instance, fallback: number)
	_setLastTransparency(obj)
	local lastTransparency = obj:GetAttribute(ATTR_LAST_TRANSPARENCY)
	if lastTransparency ~= nil then
		(obj :: any).Transparency = lastTransparency
	else
		(obj :: any).Transparency = fallback
	end
end

--[[
	对单个节点执行 fadeAll / fadeAllTween 的效果关闭与透明度

	@param obj Instance - 当前节点
	@param tran number - 目标透明度
	@param useTween boolean - true 时对 Part/Mesh/Union/Decal 播 Tween
	@return nil - 无返回值
]]
local function _applyFadeNode(obj: Instance, tran: number, useTween: boolean)
	_setFadeEffectEnabled(obj, false)
	if obj:IsA("Texture") then
		_setLastTransparency(obj)
		obj.Transparency = tran
		return
	end
	if useTween and (_isLegacyFadePart(obj) or obj:IsA("Decal")) then
		_setLastTransparency(obj)
		local tween = TweenService:Create(obj, TweenInfo.new(FADE_TWEEN_DURATION), { Transparency = tran })
		tween:Play()
		return
	end
	if _isLegacyFadePart(obj) or obj:IsA("Decal") then
		_setLastTransparency(obj)
		local fadeObj = obj :: any
		fadeObj.Transparency = tran
	end
end

--[[
	对单个节点执行 showAll 的效果开启与透明度恢复

	@param obj Instance - 当前节点
	@return nil - 无返回值
]]
local function _applyShowNode(obj: Instance)
	_setFadeEffectEnabled(obj, true)
	if obj:IsA("Texture") then
		_restoreLastTransparency(obj, FULLY_OPAQUE)
		return
	end
	if _isLegacyFadePart(obj) then
		if not SHOW_SKIP_PART_NAMES[obj.Name] then
			_restoreLastTransparency(obj, FULLY_OPAQUE)
		end
		return
	end
	if obj:IsA("Decal") then
		_restoreLastTransparency(obj, FULLY_OPAQUE)
	end
end

--[[
	保存并关闭角色渐隐用的表现类 Enabled

	@param descendant Instance - 当前后代
	@return boolean - 已按效果类处理后 true
]]
local function _saveAndDisableCharacterEffect(descendant: Instance): boolean
	for _, className in CHARACTER_FADE_EFFECT_CLASSES do
		if descendant:IsA(className) then
			if descendant:GetAttribute(ATTR_WAS_ENABLED) == nil then
				descendant:SetAttribute(ATTR_WAS_ENABLED, (descendant :: any).Enabled)
			end
			(descendant :: any).Enabled = false
			return true
		end
	end
	return false
end

--[[
	按 WasEnabled 恢复角色表现类，并清掉 Attribute

	@param descendant Instance - 当前后代
	@return boolean - 已按效果类处理后 true
]]
local function _restoreCharacterEffect(descendant: Instance): boolean
	for _, className in CHARACTER_FADE_EFFECT_CLASSES do
		if descendant:IsA(className) then
			local wasEnabled = descendant:GetAttribute(ATTR_WAS_ENABLED)
			if wasEnabled ~= nil then
				(descendant :: any).Enabled = wasEnabled
				descendant:SetAttribute(ATTR_WAS_ENABLED, nil)
			end
			return true
		end
	end
	return false
end

--[[
	对可设透明度的对象播 Tween；无 LastTransparency 时回落到 fallback

	@param descendant Instance - BasePart / Decal / Texture
	@param tweenInfo TweenInfo - 动画参数
	@param target number? - 目标透明度；nil 时读 LastTransparency 或 fallback
	@param fallback number - Attribute 缺失时的目标透明度
	@return nil - 无返回值
]]
local function _tweenTransparency(descendant: Instance, tweenInfo: TweenInfo, target: number?, fallback: number)
	local goal = target
	if goal == nil then
		local lastTransparency = descendant:GetAttribute(ATTR_LAST_TRANSPARENCY)
		goal = if lastTransparency ~= nil then lastTransparency :: number else fallback
	end
	local tween = TweenService:Create(descendant, tweenInfo, { Transparency = goal })
	tween:Play()
end

--[[
	渐隐角色模型的单个后代（跳过 HumanoidRootPart）

	@param descendant Instance - 当前后代
	@param transparency number - 目标透明度
	@param tweenInfo TweenInfo - 动画参数
	@return nil - 无返回值
]]
local function _fadeCharacterDescendant(descendant: Instance, transparency: number, tweenInfo: TweenInfo)
	if descendant.Name == PART_NAME_HUMANOID_ROOT_PART then
		return
	end
	if _saveAndDisableCharacterEffect(descendant) then
		return
	end
	if _hasTransparencyProperty(descendant) then
		_setLastTransparency(descendant)
		_tweenTransparency(descendant, tweenInfo, transparency, transparency)
	end
end

--[[
	从渐隐恢复角色模型的单个后代（跳过 HumanoidRootPart）

	@param descendant Instance - 当前后代
	@param tweenInfo TweenInfo - 动画参数
	@return nil - 无返回值
]]
local function _unfadeCharacterDescendant(descendant: Instance, tweenInfo: TweenInfo)
	if descendant.Name == PART_NAME_HUMANOID_ROOT_PART then
		return
	end
	if _restoreCharacterEffect(descendant) then
		return
	end
	if _hasTransparencyProperty(descendant) then
		_tweenTransparency(descendant, tweenInfo, nil, FULLY_OPAQUE)
	end
end

--[[
	按站立透明度分组乘算指定部位

	@param model Model - 角色模型
	@param names {string} - 部位 Name 列表
	@param percent number - 透明度百分比
	@return nil - 无返回值
]]
local function _applyStandinGroup(model: Model, names: { string }, percent: number)
	for _, partName in names do
		local part = model:FindFirstChild(partName)
		if part and part:IsA("BasePart") then
			_applyTransparencyPercent(part, percent)
		end
	end
end

--[[
	创建 WeldConstraint，把 part 焊到 primary（先设 Part0/Part1 再 Parent）

	@param part BasePart - 被焊接部件
	@param primary BasePart - 焊接锚点
	@return nil - 无返回值
]]
local function _weldPartToPrimary(part: BasePart, primary: BasePart)
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = part
	weld.Part1 = primary
	weld.Parent = part
end

-- ========================================
-- 阴影和效果控制
-- ========================================

--[[
	关闭模型子树所有 BasePart 阴影

	@param obj Model - 目标模型
	@return nil - 无返回值；obj 无效时不执行
]]
function VisibleMgr.CloseShade(obj: Model)
	if not obj then
		return
	end
	_forEachBasePart(obj, function(part: BasePart)
		part.CastShadow = false
	end)
end

--[[
	开启模型子树所有 BasePart 阴影

	@param obj Model - 目标模型
	@return nil - 无返回值；obj 无效时不执行
]]
function VisibleMgr.OpenShade(obj: Model)
	if not obj then
		return
	end
	_forEachBasePart(obj, function(part: BasePart)
		part.CastShadow = true
	end)
end

--[[
	禁用模型子树所有 Trail

	@param obj Model - 目标模型
	@return nil - 无返回值；obj 无效时不执行
]]
function VisibleMgr.DisableTrail(obj: Model)
	if not obj then
		return
	end
	_forEachInSubtree(obj, function(instance: Instance)
		if instance:IsA("Trail") then
			instance.Enabled = false
		end
	end)
end

--[[
	禁用模型子树所有 ProximityPrompt

	@param obj Model - 目标模型
	@return nil - 无返回值；obj 无效时不执行
]]
function VisibleMgr.DisableProximityPrompt(obj: Model)
	if not obj then
		return
	end
	_forEachInSubtree(obj, function(instance: Instance)
		if instance:IsA("ProximityPrompt") then
			instance.Enabled = false
		end
	end)
end

--[[
	禁用模型子树所有 ParticleEmitter

	@param obj Model - 目标模型
	@return nil - 无返回值；obj 无效时不执行
]]
function VisibleMgr.DisableParticle(obj: Model)
	if not obj then
		return
	end
	_forEachInSubtree(obj, function(instance: Instance)
		if instance:IsA("ParticleEmitter") then
			instance.Enabled = false
		end
	end)
end

-- ========================================
-- 物理属性控制
-- ========================================

--[[
	将对象及其后代 BasePart 设为无质量

	@param obj Instance - 目标对象（历史标注 BasePart，实际按 Instance 递归）
	@return nil - 无返回值；obj 无效时不执行
]]
function VisibleMgr.MasslessAll(obj: Instance)
	if not obj then
		return
	end
	_forEachBasePart(obj, function(part: BasePart)
		part.Massless = true
	end)
end

--[[
	关闭对象及其后代 BasePart 的 CanQuery

	@param obj Instance - 目标对象
	@return nil - 无返回值；obj 无效时不执行
]]
function VisibleMgr.UnQueryAll(obj: Instance)
	if not obj then
		return
	end
	_forEachBasePart(obj, function(part: BasePart)
		part.CanQuery = false
	end)
end

--[[
	取消锚定对象及其后代 BasePart

	@param obj Instance - 目标对象
	@return nil - 无返回值；obj 无效时不执行
]]
function VisibleMgr.UnAnchoredAll(obj: Instance)
	if not obj then
		return
	end
	_forEachBasePart(obj, function(part: BasePart)
		part.Anchored = false
	end)
end

--[[
	锚定对象及其后代 BasePart

	@param obj Instance - 目标对象
	@return nil - 无返回值；obj 无效时不执行
]]
function VisibleMgr.AnchoredAll(obj: Instance)
	if not obj then
		return
	end
	_forEachBasePart(obj, function(part: BasePart)
		part.Anchored = true
	end)
end

-- ========================================
-- 透明度控制
-- ========================================

--[[
	按 R15 部位分组乘算站立透明度（100 / 60 / 30）

	@param obj Model - 角色模型
	@return nil - 无返回值；obj 无效时不执行
]]
function VisibleMgr.SetStandinTransparency(obj: Model)
	if not obj then
		return
	end
	for _, group in STANDIN_TRANSPARENCY_GROUPS do
		_applyStandinGroup(obj, group.names, group.percent)
	end
end

--[[
	按百分比乘算对象及其后代 BasePart 的当前透明度（不是绝对值赋值）

	@param obj Instance - 目标对象
	@param pst number? - 透明度百分比 0–100；nil 时默认 100（完全透明）
	@return nil - 无返回值；obj 无效时不执行
]]
function VisibleMgr.SetTransparency(obj: Instance, pst: number?)
	if not obj then
		return
	end
	local percent = pst or DEFAULT_TRANSPARENCY_PERCENT
	_forEachBasePart(obj, function(part: BasePart)
		_applyTransparencyPercent(part, percent)
	end)
end

--[[
	将对象及其后代 BasePart 设为完全透明（历史名 UnTransparencyAll）

	@param obj Instance - 目标对象
	@return nil - 无返回值；obj 无效时不执行
]]
function VisibleMgr.UnTransparencyAll(obj: Instance)
	if not obj then
		return
	end
	_forEachBasePart(obj, function(part: BasePart)
		part.Transparency = FULLY_TRANSPARENT
	end)
end

--[[
	将对象及其后代 BasePart 设为完全不透明（历史名 TransparencyAll）

	@param obj Instance - 目标对象
	@return nil - 无返回值；obj 无效时不执行
]]
function VisibleMgr.TransparencyAll(obj: Instance)
	if not obj then
		return
	end
	_forEachBasePart(obj, function(part: BasePart)
		part.Transparency = FULLY_OPAQUE
	end)
end

-- ========================================
-- 速度控制
-- ========================================

--[[
	将模型子树 Assembly 线速度 / 角速度清零。
	玩家角色子树拒绝写入（CharacterMotion 唯一速度写口）。

	@param obj Instance - 目标模型或池化实例
	@return boolean - 已写入 true；obj 无效或玩家角色拒绝时 false
]]
function VisibleMgr.SpeedDown(obj: Instance): boolean
	if not obj then
		return false
	end
	if _refusePlayerCharacterVelocity(obj, "SpeedDown") then
		return false
	end
	_forEachBasePart(obj, function(part: BasePart)
		part.AssemblyLinearVelocity = Vector3.zero
		part.AssemblyAngularVelocity = Vector3.zero
	end)
	return true
end

--[[
	仅保留模型子树 Y 轴速度。玩家角色子树拒绝写入。

	@param obj Instance - 目标模型
	@return boolean - 已写入 true；obj 无效或玩家角色拒绝时 false
]]
function VisibleMgr.SpeedDownY(obj: Instance): boolean
	if not obj then
		return false
	end
	if _refusePlayerCharacterVelocity(obj, "SpeedDownY") then
		return false
	end
	_forEachBasePart(obj, function(part: BasePart)
		part.AssemblyLinearVelocity = Vector3.new(0, part.AssemblyLinearVelocity.Y, 0)
		part.AssemblyAngularVelocity = Vector3.new(0, part.AssemblyAngularVelocity.Y, 0)
	end)
	return true
end

-- ========================================
-- 碰撞和查询控制
-- ========================================

--[[
	关闭对象及其后代 BasePart 的 CanTouch

	@param obj Instance - 目标对象
	@return nil - 无返回值；obj 无效时不执行
]]
function VisibleMgr.UnTouchAll(obj: Instance)
	if not obj then
		return
	end
	_forEachBasePart(obj, function(part: BasePart)
		part.CanTouch = false
	end)
end

--[[
	关闭对象及其后代 BasePart 的 CanCollide 与 CanQuery

	@param obj Instance - 目标对象
	@return nil - 无返回值；obj 无效时不执行
]]
function VisibleMgr.UnCollideAll(obj: Instance)
	if not obj then
		return
	end
	_forEachBasePart(obj, function(part: BasePart)
		part.CanCollide = false
		part.CanQuery = false
	end)
end

--[[
	开启对象及其后代 BasePart 的 CanQuery

	@param obj Instance - 目标对象
	@return nil - 无返回值；obj 无效时不执行
]]
function VisibleMgr.QueryAll(obj: Instance)
	if not obj then
		return
	end
	_forEachBasePart(obj, function(part: BasePart)
		part.CanQuery = true
	end)
end

--[[
	仅开启对象自身及其直接子级 BasePart 的 CanQuery（不递归后代）

	@param obj Instance - 目标对象
	@return nil - 无返回值；obj 无效时不执行
]]
function VisibleMgr.QueryChildren(obj: Instance)
	if not obj then
		return
	end
	if obj:IsA("BasePart") then
		obj.CanQuery = true
	end
	for _, child in obj:GetChildren() do
		if child:IsA("BasePart") then
			child.CanQuery = true
		end
	end
end

--[[
	开启对象及其后代 BasePart 的 CanCollide

	@param obj Instance - 目标对象
	@return nil - 无返回值；obj 无效时不执行
]]
function VisibleMgr.CollideAll(obj: Instance)
	if not obj then
		return
	end
	_forEachBasePart(obj, function(part: BasePart)
		part.CanCollide = true
	end)
end

-- ========================================
-- 淡入淡出和显示
-- ========================================

--[[
	递归淡出对象子树（Tween 时长 FADE_TWEEN_DURATION）。
	历史小写名，调用方请继续用 fadeAllTween。

	@param obj Instance - 目标对象
	@param tran number? - 目标透明度；nil 时默认 1
	@return nil - 无返回值；obj 无效时不执行
]]
function VisibleMgr.fadeAllTween(obj: Instance, tran: number?)
	if not obj then
		return
	end
	local target = tran or FULLY_TRANSPARENT
	_forEachInSubtree(obj, function(instance: Instance)
		_applyFadeNode(instance, target, true)
	end)
end

--[[
	递归淡出对象子树（立即设透明度，无动画）。
	与 fadeAllTween 关闭同一组表现类（含 Beam / ProximityPrompt）。

	@param obj Instance - 目标对象
	@param tran number? - 目标透明度；nil 时默认 1
	@return nil - 无返回值；obj 无效时不执行
]]
function VisibleMgr.fadeAll(obj: Instance, tran: number?)
	if not obj then
		return
	end
	local target = tran or FULLY_TRANSPARENT
	_forEachInSubtree(obj, function(instance: Instance)
		_applyFadeNode(instance, target, false)
	end)
end

--[[
	递归显示对象子树：恢复 LastTransparency 并重新启用表现类。
	touchPart / HumanoidRootPart / 灯光 / 碰撞体 不改透明度。

	@param obj Instance - 目标对象
	@return nil - 无返回值；obj 无效时不执行
]]
function VisibleMgr.showAll(obj: Instance)
	if not obj then
		return
	end
	_forEachInSubtree(obj, function(instance: Instance)
		_applyShowNode(instance)
	end)
end

-- ========================================
-- 属性与碰撞组
-- ========================================

--[[
	将对象及其后代 BasePart 设为宠物物理（无质量、无碰撞、无触摸）

	@param obj Instance - 目标对象
	@return nil - 无返回值；obj 无效时不执行
]]
function VisibleMgr.SetPetMass(obj: Instance)
	if not obj then
		return
	end
	_forEachBasePart(obj, function(part: BasePart)
		part.CanCollide = false
		part.CanTouch = false
		part.Massless = true
	end)
end

--[[
	为对象及其全部后代写入 type Attribute

	@param obj Instance - 目标对象
	@param tp number - 类型编号
	@return nil - 无返回值；obj 无效时不执行
]]
function VisibleMgr.AddItemType(obj: Instance, tp: number)
	if not obj then
		return
	end
	_forEachInSubtree(obj, function(instance: Instance)
		instance:SetAttribute(ATTR_ITEM_TYPE, tp)
	end)
end

--[[
	设置对象的 onlyID Attribute（不递归）

	@param obj Instance - 目标对象
	@param onlyID number - 唯一 ID
	@return nil - 无返回值；obj 无效时不执行
]]
function VisibleMgr.SetOnlyID(obj: Instance, onlyID: number)
	if not obj then
		return
	end
	obj:SetAttribute(ATTR_ONLY_ID, onlyID)
end

--[[
	读取对象的 onlyID Attribute

	@param obj Instance - 目标对象
	@return number? - 唯一 ID；obj 无效或未设置时 nil
]]
function VisibleMgr.GetOnlyID(obj: Instance): number?
	if not obj then
		return nil
	end
	return obj:GetAttribute(ATTR_ONLY_ID) :: number?
end

--[[
	为对象及其全部后代写入 OwnerID Attribute

	@param obj Instance - 目标对象
	@param ownerID number - 所有者 ID
	@return nil - 无返回值；obj 无效时不执行
]]
function VisibleMgr.AddOwnerID(obj: Instance, ownerID: number)
	if not obj then
		return
	end
	_forEachInSubtree(obj, function(instance: Instance)
		instance:SetAttribute(ATTR_OWNER_ID, ownerID)
	end)
end

--[[
	设置对象及其后代 BasePart 的 CollisionGroup

	@param obj Instance - 目标对象
	@param collideID string - 碰撞组名
	@return nil - 无返回值；obj 无效时不执行
]]
function VisibleMgr.SetCollideID(obj: Instance, collideID: string)
	if not obj then
		return
	end
	_forEachBasePart(obj, function(part: BasePart)
		part.CollisionGroup = collideID
	end)
end

--[[
	设置对象及其后代 BasePart 的碰撞组为 Player

	@param obj Instance - 目标对象（入服角色由 PlayerManager 调用）
	@return nil - 无返回值；obj 无效时不执行
]]
function VisibleMgr.SetPlayerCollideID(obj: Instance)
	if not obj then
		return
	end
	_forEachBasePart(obj, function(part: BasePart)
		part.CollisionGroup = COLLISION_GROUP_PLAYER
	end)
end

--[[
	设置对象及其后代 BasePart 的碰撞组为 Default

	@param obj Instance - 目标对象
	@return nil - 无返回值；obj 无效时不执行
]]
function VisibleMgr.SetCollideIDDefault(obj: Instance)
	if not obj then
		return
	end
	_forEachBasePart(obj, function(part: BasePart)
		part.CollisionGroup = COLLISION_GROUP_DEFAULT
	end)
end

--[[
	焊接模型内部 BasePart 到指定 PrimaryPart（WeldConstraint）

	@param model Instance - 目标模型或单个 BasePart
	@param primary BasePart - 焊接锚点
	@return nil - 无返回值；primary / model 无效时不执行
]]
function VisibleMgr.Weld(model: Instance, primary: BasePart)
	if not model or not primary then
		return
	end

	if model:IsA("Model") then
		for _, part in model:GetDescendants() do
			if part:IsA("BasePart") then
				_weldPartToPrimary(part, primary)
			end
		end
	elseif model:IsA("BasePart") then
		_weldPartToPrimary(model, primary)
	end
end

--[[
	焊接模型自身：所有 BasePart 用旧版 Weld 焊到 PrimaryPart（保留 C0/C1）

	@param model Model - 目标模型
	@return nil - 无返回值；无 PrimaryPart 时不执行
]]
function VisibleMgr.SelfWeld(model: Model)
	if not model then
		return
	end
	local primary = model.PrimaryPart
	if not primary then
		return
	end

	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			local weld = Instance.new("Weld")
			weld.Part0 = primary
			weld.Part1 = part
			weld.C1 = part.CFrame:Inverse() * primary.CFrame * weld.C0
			weld.Parent = part
		end
	end
end

--[[
	彩虹粒子 Heartbeat 色相渐变

	@param particle ParticleEmitter - 粒子发射器
	@param speed number? - 色相变化速度倍率，默认 1
	@return nil - 无返回值；已在跑循环时忽略
]]
function VisibleMgr.RainBowParticle(particle: ParticleEmitter, speed: number?)
	if not particle then
		return
	end
	local hueSpeed = speed or 1
	_runParticleColorLoop(particle, hueSpeed, function(changeValue: number): ColorSequence
		local colorKeyTable: { ColorSequenceKeypoint } = {}
		for i = 0, 1, PARTICLE_COLOR_STEP do
			table.insert(
				colorKeyTable,
				ColorSequenceKeypoint.new(
					i,
					Color3.fromHSV((changeValue + i * PARTICLE_HUE_SPAN) % 1, PARTICLE_HSV_SATURATION, PARTICLE_HSV_VALUE)
				)
			)
		end
		return ColorSequence.new(colorKeyTable)
	end)
end

--[[
	秘密粒子 Heartbeat 色相渐变（饱和度 / 明度随色相变化）

	@param particle ParticleEmitter - 粒子发射器
	@param speed number? - 色相变化速度倍率，默认 1
	@return nil - 无返回值；已在跑循环时忽略
]]
function VisibleMgr.SecretParticle(particle: ParticleEmitter, speed: number?)
	if not particle then
		return
	end
	local hueSpeed = speed or 1
	_runParticleColorLoop(particle, hueSpeed, function(changeValue: number): ColorSequence
		local colorKeyTable: { ColorSequenceKeypoint } = {}
		for i = 0, 1, PARTICLE_COLOR_STEP do
			local hue = (changeValue + i * PARTICLE_HUE_SPAN) % 1
			table.insert(colorKeyTable, ColorSequenceKeypoint.new(i, Color3.fromHSV(hue, hue, hue % PARTICLE_SECRET_VALUE_MOD)))
		end
		return ColorSequence.new(colorKeyTable)
	end)
end

--[[
	渐隐角色模型（跳过 HumanoidRootPart）。可选透明度 / 时长 / 缓动。

	@param model Model - 角色模型
	@param transparency number? - 目标透明度，默认 1
	@param tweenTime number? - 变化时间（秒），默认 0.5
	@param easingStyle Enum.EasingStyle? - 缓动曲线，默认 Quad
	@param easingDir Enum.EasingDirection? - 缓动方向，默认 Out
	@return nil - 无返回值；model 无效或已无 Parent 时不执行
]]
function VisibleMgr.FadeCharacterModel(
	model: Model,
	transparency: number?,
	tweenTime: number?,
	easingStyle: Enum.EasingStyle?,
	easingDir: Enum.EasingDirection?
)
	if not model or not model.Parent then
		return
	end
	local target = transparency or FULLY_TRANSPARENT
	local tweenInfo = TweenInfo.new(
		tweenTime or DEFAULT_CHARACTER_TWEEN_TIME,
		easingStyle or DEFAULT_CHARACTER_EASING_STYLE,
		easingDir or DEFAULT_CHARACTER_EASING_DIR
	)
	for _, descendant in model:GetDescendants() do
		_fadeCharacterDescendant(descendant, target, tweenInfo)
	end
end

--[[
	从渐隐恢复角色模型（跳过 HumanoidRootPart）

	@param model Model - 角色模型
	@param tweenTime number? - 变化时间（秒），默认 0.5
	@param easingStyle Enum.EasingStyle? - 缓动曲线，默认 Quad
	@param easingDir Enum.EasingDirection? - 缓动方向，默认 Out
	@return nil - 无返回值；model 无效或已无 Parent 时不执行
]]
function VisibleMgr.UnFadeCharacterModel(
	model: Model,
	tweenTime: number?,
	easingStyle: Enum.EasingStyle?,
	easingDir: Enum.EasingDirection?
)
	if not model or not model.Parent then
		return
	end
	local tweenInfo = TweenInfo.new(
		tweenTime or DEFAULT_CHARACTER_TWEEN_TIME,
		easingStyle or DEFAULT_CHARACTER_EASING_STYLE,
		easingDir or DEFAULT_CHARACTER_EASING_DIR
	)
	for _, descendant in model:GetDescendants() do
		_unfadeCharacterDescendant(descendant, tweenInfo)
	end
end

-- ========================================
-- 对象池默认视觉快照
-- ========================================

--[[
	将 root 子树当前 Transparency / Enabled 写入 Init* Attribute（仅补缺失项）

	@param root Instance - 模型或特效根节点
	@return nil - 无返回值
]]
function VisibleMgr.SnapshotDefaultVisualState(root: Instance)
	if not root then
		return
	end
	_forEachInSubtree(root, function(instance: Instance)
		_captureInitVisualAttributes(instance, false)
	end)
end

--[[
	从 template 同步 Init* Attribute 到 model 对应路径节点（供对象池对齐模板默认态）

	@param model Instance - 池化实例
	@param template Instance - 资源模板
	@return nil - 无返回值
]]
function VisibleMgr.SyncDefaultVisualSnapshotFromTemplate(model: Instance, template: Instance)
	if not model or not template then
		return
	end
	VisibleMgr.SnapshotDefaultVisualState(template)
	_copyInitVisualAttributes(template, model)
	for _, templateDesc in template:GetDescendants() do
		local relativePath = _getRelativePath(template, templateDesc)
		if relativePath then
			local modelInst = _findByRelativePath(model, relativePath)
			if modelInst then
				_copyInitVisualAttributes(templateDesc, modelInst)
			end
		end
	end
end

--[[
	按 Init* Attribute 恢复 root 子树默认 Transparency / Enabled

	@param root Instance - 模型或特效根节点
	@return nil - 无返回值
]]
function VisibleMgr.RestoreDefaultVisualState(root: Instance)
	if not root then
		return
	end
	_forEachInSubtree(root, function(instance: Instance)
		_restoreInitVisualProperties(instance)
	end)
end

return VisibleMgr
