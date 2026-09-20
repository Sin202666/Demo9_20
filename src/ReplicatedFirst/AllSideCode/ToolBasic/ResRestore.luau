--!strict
--[[
	Module: ResRestore
	Description: 延迟资源的恢复、卸载与 ContentProvider 预加载（无模块级业务状态）
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-08-31

	功能：
	- Restore / PrepareInstance：把 NoAssetID 标记的贴图、音频从 Attribute 写回实例属性
	- ClearAssert / ClearAssertSound：把资源 ID 挪到 Attribute，减少常驻内存；需要时再 Restore
	- PreloadAssets / PreloadAnimation / DeferPreload*：ContentProvider 预热

	模块关系（何时用哪个）：
	- ResMemoryManager：进服卸载技能模型贴图与 SoundService 音频
	- AssetAcquire / ObjectPoolUtil：Clone / 借出后 PrepareInstance
	- SkillPreloadUtil：DeferPreloadModel / DeferPreloadAnimationId / DeferPreloadSound
	- ResPreloadManager：PreloadAnimation 启动预热
	- FirstPreload/Preload：加载屏进度计数，与本模块无关，勿在此拨「已加载资源数」

	约束：
	- DeferPreloadModel / DeferPreloadSound 必须先 Restore 再 PreloadAsync。
	  ClearAssert 会把 Texture/SoundId 挪到 Attribute；若先 Preload 再 Restore，
	  ContentProvider 扫到的是空串，贴图预热形同虚设。
	- ClearAssert 为历史拼写（非 Asset），调用方已使用此名，保持不变。
	- PreloadAss 为 PreloadAssets 的历史缩写别名。

	加载方式：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local ResRestore = Utils.ResRestore

	示例：
		ResRestore.ClearAssert(skillModel)
		ResRestore.PrepareInstance(clone)
		ResRestore.DeferPreloadModel(model, onSuccess)
]]

-- ============================================================================
-- 服务与依赖
-- ============================================================================

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local ContentProvider = Utils.ContentProvider
local Debris = Utils.Debris
local ReplicatedFirst = Utils.ReplicatedFirst
local Log = Utils.Log

-- ============================================================================
-- 模块定义
-- ============================================================================

local ResRestore = {}

-- ============================================================================
-- 常量
-- ============================================================================

local ATTR_NO_ASSET_ID = "NoAssetID"
local ATTR_SOUND_ID = "SoundId"
local ATTR_TEXTURE_ID = "TextureID"
local ATTR_TEXTURE = "Texture"

local NO_ASSET_ID_MARKED = 1
local NO_ASSET_ID_CLEARED = 0

local PRELOAD_RETRY_DELAY_SEC = 2
local PRELOAD_ANIM_RETRY_DELAY_SEC = 0.5
local DEBRIS_DESTROY_NOW_SEC = 0

-- ============================================================================
-- 私有函数
-- ============================================================================

--[[
	对 ContentProvider 执行预加载，失败时打日志并可延迟重试一次
	@param targets { Instance | string } - 预加载目标列表
	@param label string - 日志标识
	@param retryDelaySec number? - 重试延迟秒数，nil 表示不重试
	@return boolean - 首次调用是否成功
]]
local function _preloadAsync(targets: { Instance | string }, label: string, retryDelaySec: number?): boolean
	local success, err = pcall(function()
		ContentProvider:PreloadAsync(targets :: { any })
	end)
	if success then
		return true
	end

	Log.warn("[ResRestore] Preload failed:", label, err)

	if retryDelaySec then
		task.delay(retryDelaySec, function()
			local retrySuccess, retryErr = pcall(function()
				ContentProvider:PreloadAsync(targets :: { any })
			end)
			if not retrySuccess then
				Log.warn("[ResRestore] Preload retry failed:", label, retryErr)
			end
		end)
	end

	return false
end

--[[
	在实例属性与 Attribute 之间挪动字符串资源 ID
	@param instance Instance - 目标实例
	@param attributeName string - 保存用 Attribute 名
	@param propertyName string - 实例上的字符串属性名（Texture / TextureID）
	@param shouldClear boolean - true 卸到 Attribute，false 从 Attribute 恢复
	@return nil - 无返回值
]]
local function _swapStringProp(instance: Instance, attributeName: string, propertyName: string, shouldClear: boolean)
	local inst = instance :: any
	if shouldClear then
		local current = inst[propertyName]
		if type(current) ~= "string" or current == "" then
			return
		end
		instance:SetAttribute(attributeName, current)
		inst[propertyName] = ""
		return
	end

	local saved = instance:GetAttribute(attributeName)
	if type(saved) == "string" and saved ~= "" then
		inst[propertyName] = saved
	end
end

--[[
	将贴图类后代实例的资源 ID 恢复或卸载到 Attribute
	MeshPart 用 TextureID；ParticleEmitter / Beam / Decal（含 Texture 子类）用 Texture
	@param descendant Instance - 模型后代
	@param shouldClear boolean - true 卸载到 Attribute，false 从 Attribute 恢复
	@return nil - 无返回值
]]
local function _applyTextureDescendant(descendant: Instance, shouldClear: boolean)
	if descendant:IsA("MeshPart") then
		_swapStringProp(descendant, ATTR_TEXTURE_ID, "TextureID", shouldClear)
		return
	end
	if descendant:IsA("ParticleEmitter") or descendant:IsA("Beam") or descendant:IsA("Decal") then
		_swapStringProp(descendant, ATTR_TEXTURE, "Texture", shouldClear)
	end
end

--[[
	卸载单个 Sound：SoundId 写入 Attribute 并清空；已标记或空 ID 跳过，避免二次调用覆盖原 ID
	@param sound Sound - 目标音频
	@return nil - 无返回值
]]
local function _clearSound(sound: Sound)
	if sound:GetAttribute(ATTR_NO_ASSET_ID) == NO_ASSET_ID_MARKED then
		return
	end
	if sound.SoundId == "" then
		return
	end
	sound:SetAttribute(ATTR_NO_ASSET_ID, NO_ASSET_ID_MARKED)
	sound:SetAttribute(ATTR_SOUND_ID, sound.SoundId)
	sound.SoundId = ""
end

--[[
	从 Attribute 恢复单个 Sound 的 SoundId，并清除 NoAssetID 标记
	@param sound Sound - 目标音频
	@return nil - 无返回值
]]
local function _restoreSound(sound: Sound)
	local savedSoundId = sound:GetAttribute(ATTR_SOUND_ID)
	if type(savedSoundId) == "string" and savedSoundId ~= "" then
		sound.SoundId = savedSoundId
	end
end

-- ============================================================================
-- 公共 API — 资源恢复与卸载
-- ============================================================================

--[[
	恢复模型中已保存的资源 ID
	将 NoAssetID 标记的贴图、音频等资源从 Attribute 恢复回实例属性
	支持 Model 及其后代、以及 Sound 实例
	@param instance Model | Sound - 要恢复的模型或音频
	@return nil - 无返回值
]]
function ResRestore.Restore(instance: Model | Sound)
	if instance:GetAttribute(ATTR_NO_ASSET_ID) ~= NO_ASSET_ID_MARKED then
		return
	end

	instance:SetAttribute(ATTR_NO_ASSET_ID, NO_ASSET_ID_CLEARED)

	if instance:IsA("Sound") then
		_restoreSound(instance)
		return
	end

	for _, descendant in (instance :: Model):GetDescendants() do
		_applyTextureDescendant(descendant, false)
	end
end

--[[
	按需恢复实例上的延迟加载资源（Model / Sound）
	无 NoAssetID 标记时为空操作，供 AssetAcquire、ObjectPoolUtil 等统一调用
	@param instance Instance - 模型或音频实例
	@return nil - 无返回值
]]
function ResRestore.PrepareInstance(instance: Instance)
	if instance:IsA("Model") or instance:IsA("Sound") then
		ResRestore.Restore(instance :: Model | Sound)
	end
end

--[[
	暂时卸载模型的贴图资源，将资源 ID 保存到 Attribute
	用于减少内存占用，需要时可通过 Restore 恢复
	@param model Model - 要处理的模型
	@return nil - 无返回值
]]
function ResRestore.ClearAssert(model: Model)
	if model:GetAttribute(ATTR_NO_ASSET_ID) == NO_ASSET_ID_MARKED then
		return
	end

	model:SetAttribute(ATTR_NO_ASSET_ID, NO_ASSET_ID_MARKED)

	for _, descendant in model:GetDescendants() do
		_applyTextureDescendant(descendant, true)
	end
end

--[[
	暂时卸载 Sound 的音频资源，将 SoundId 保存到 Attribute
	container 本身是 Sound 时处理该实例；否则处理其全体 Sound 后代
	已标记或空 SoundId 跳过，避免二次调用把已保存 ID 覆盖成空串
	@param container Instance - Sound 自身，或包含 Sound 的容器（Folder、Model 等）
	@return nil - 无返回值
]]
function ResRestore.ClearAssertSound(container: Instance)
	if container:IsA("Sound") then
		_clearSound(container)
		return
	end
	for _, descendant in container:GetDescendants() do
		if descendant:IsA("Sound") then
			_clearSound(descendant)
		end
	end
end

-- ============================================================================
-- 公共 API — 资源预加载
-- ============================================================================

--[[
	预加载指定资源 ID 列表
	失败时会在 PRELOAD_RETRY_DELAY_SEC 秒后重试一次
	@param assetIds { string } - 资源 ID 数组（rbxassetid://...）；非 string / 空串跳过
	@return nil - 无返回值
]]
function ResRestore.PreloadAssets(assetIds: { string })
	if type(assetIds) ~= "table" then
		return
	end
	for _, assetId in assetIds do
		if type(assetId) == "string" and assetId ~= "" then
			task.defer(function()
				_preloadAsync({ assetId }, assetId, PRELOAD_RETRY_DELAY_SEC)
			end)
		end
	end
end

-- 历史缩写，与 PreloadAssets 同一实现
ResRestore.PreloadAss = ResRestore.PreloadAssets

--[[
	预加载动作资源
	创建临时 Animation 实例进行预加载，完成后销毁
	首次失败时延迟重试，须等重试结束再销毁，避免 PreloadAsync 打在已销毁实例上
	@param animationIds { string } - 动作 ID 数组（rbxassetid://...）；非 string / 空串跳过
	@return nil - 无返回值
]]
function ResRestore.PreloadAnimation(animationIds: { string })
	if type(animationIds) ~= "table" then
		return
	end
	task.defer(function()
		for _, animationId in animationIds do
			if type(animationId) ~= "string" or animationId == "" then
				continue
			end
			task.defer(function()
				local animation = Instance.new("Animation")
				animation.AnimationId = animationId
				animation.Parent = ReplicatedFirst

				local success = _preloadAsync({ animation }, animationId, nil)
				if success then
					Debris:AddItem(animation, DEBRIS_DESTROY_NOW_SEC)
					return
				end

				task.delay(PRELOAD_ANIM_RETRY_DELAY_SEC, function()
					_preloadAsync({ animation }, animationId, nil)
					Debris:AddItem(animation, DEBRIS_DESTROY_NOW_SEC)
				end)
			end)
		end
	end)
end

--[[
	异步预加载模型：先 Restore 写回贴图 ID，再 PreloadAsync（否则 ClearAssert 后 ID 为空，预热无效）。
	@param model Model - 要预加载的模型实例
	@param onSuccess (() -> ())? - 预加载成功后的回调
	@return nil - 无返回值
]]
function ResRestore.DeferPreloadModel(model: Model, onSuccess: (() -> ())?)
	task.defer(function()
		-- ClearAssert 模板：Texture 在 Attribute；必须先 Restore，PreloadAsync 才能扫到真实 ID
		ResRestore.Restore(model)
		local success = _preloadAsync({ model }, "model:" .. model.Name, PRELOAD_RETRY_DELAY_SEC)
		if success and onSuccess then
			onSuccess()
		end
	end)
end

--[[
	异步预加载动作 ID
	@param animIdStr string - rbxassetid:// 格式的动作 ID
	@param onSuccess (() -> ())? - 预加载成功后的回调
	@return nil - 无返回值
]]
function ResRestore.DeferPreloadAnimationId(animIdStr: string, onSuccess: (() -> ())?)
	if type(animIdStr) ~= "string" or animIdStr == "" then
		return
	end
	task.defer(function()
		local animation = Instance.new("Animation")
		animation.AnimationId = animIdStr
		animation.Parent = ReplicatedFirst

		local success = _preloadAsync({ animation }, animIdStr, nil)
		if success and onSuccess then
			onSuccess()
		end

		Debris:AddItem(animation, DEBRIS_DESTROY_NOW_SEC)
	end)
end

--[[
	异步预加载音频：先 Restore 写回 SoundId，再 PreloadAsync（与 DeferPreloadModel 同序）。
	@param sound Sound - 要预加载的音频实例
	@param onSuccess (() -> ())? - 预加载成功后的回调
	@return nil - 无返回值
]]
function ResRestore.DeferPreloadSound(sound: Sound, onSuccess: (() -> ())?)
	task.defer(function()
		ResRestore.Restore(sound)
		local success = _preloadAsync({ sound }, "sound:" .. sound.Name, PRELOAD_RETRY_DELAY_SEC)
		if success and onSuccess then
			onSuccess()
		end
	end)
end

return ResRestore
