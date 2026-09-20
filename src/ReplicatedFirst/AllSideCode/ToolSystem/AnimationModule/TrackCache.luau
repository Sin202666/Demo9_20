--[[
	Module: TrackCache
	Description: 动画轨道缓存、加载与事件绑定
	Author: 林奥宇
	Created: 2026-07-02
	Last Modified: 2026-08-31

	================================================================================
	使用说明
	================================================================================

	仅供 AnimationModule / FreezeAnim 使用，不经 Utils 单独导出。

	【职责】
	- 按 Animator + 动画名缓存 AnimationTrack；命中则复用，不重复 LoadAnimation
	- 绑定 Marker / Ended；Animator.Destroying 时交给 AnimationState.CleanupAnimator
	- FindAnimatorFromModel：Humanoid 或 AnimationController 下找 Animator

	【注意】
	GetAnimatorTrackCache 返回内部缓存原表，仅本目录迭代 Stop/Freeze，禁止增删键。
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local InsMgr = Utils.InsMgr

local AnimationTable = require(script.Parent.Animation)
local AnimationState = require(script.Parent.AnimationState)

local TrackCache = {}

local ANIMATION_ASSET_PREFIX = "http://www.roblox.com/asset/?id="
local RBX_ASSET_PREFIX = "rbxassetid://"
local TIME_POSITION_EPSILON = 1e-3

TrackCache.RBX_ASSET_PREFIX = RBX_ASSET_PREFIX
TrackCache.TIME_POSITION_EPSILON = TIME_POSITION_EPSILON

-- ========================================
-- 私有函数
-- ========================================

--[[
	将动画 ID 格式化为 Roblox 资源 URL
	@param animationID number - 动画 ID
	@return string - 资源 URL
]]
local function _formatAnimationAssetId(animationID: number): string
	return ANIMATION_ASSET_PREFIX .. animationID
end

--[[
	从配置表获取动画 ID
	@param animationName string - 动画名称
	@return number? - 动画 ID
]]
local function _getConfiguredAnimID(animationName: string): number?
	local animationData = AnimationTable[animationName]
	if type(animationData) == "number" then
		return animationData
	end
	return nil
end

--[[
	清理动画的关键帧事件连接
	@param animator Animator - 动画器
	@param animationName string - 动画名称
]]
local function _cleanupAnimationMarkerEvents(animator: Animator, animationName: string)
	if not AnimationState.animationMarkerConnections[animator] then
		AnimationState.animationMarkerConnections[animator] = {}
	end

	if AnimationState.animationMarkerConnections[animator][animationName] then
		for eventName, connection: RBXScriptConnection in pairs(AnimationState.animationMarkerConnections[animator][animationName]) do
			connection:Disconnect()
			AnimationState.animationMarkerConnections[animator][animationName][eventName] = nil
		end
	else
		AnimationState.animationMarkerConnections[animator][animationName] = {}
	end
end

--[[
	获取或创建动画轨道（缓存命中时不清理已有事件连接）
	@param animator Animator - 动画器
	@param animationName string - 动画名称
	@return AnimationTrack? - 动画轨道
]]
local function _getAnimationTrack(animator: Animator, animationName: string): AnimationTrack?
	if not AnimationState.animationTrackCache[animator] then
		AnimationState.animationTrackCache[animator] = {}
		AnimationState.animatorDestroyConnections[animator] = animator.Destroying:Connect(function()
			AnimationState.CleanupAnimator(animator)
		end)
	end

	if AnimationState.animationTrackCache[animator][animationName] then
		return AnimationState.animationTrackCache[animator][animationName]
	end

	local animationID = _getConfiguredAnimID(animationName)
	if not animationID then
		warn("动画配置中未找到", animationName, "的 ID")
		return nil
	end

	local newAnimation: Animation = InsMgr.GetIns(animationName, "Animation", animator) :: Animation
	newAnimation.AnimationId = _formatAnimationAssetId(animationID)

	AnimationState.animationTrackCache[animator][animationName] = animator:LoadAnimation(newAnimation)
	return AnimationState.animationTrackCache[animator][animationName]
end

--[[
	绑定关键帧 Marker 回调
	@param animator Animator - 动画器
	@param animationName string - 动画名称
	@param animationTrack AnimationTrack - 动画轨道
	@param keyframeNames {string}? - 关键帧名称列表
	@param keyframeFunctions {() -> ()}? - 回调列表
]]
local function _bindKeyframeEvents(
	animator: Animator,
	animationName: string,
	animationTrack: AnimationTrack,
	keyframeNames: {string}?,
	keyframeFunctions: {() -> ()}?
)
	if not keyframeNames or not keyframeFunctions then
		return
	end

	_cleanupAnimationMarkerEvents(animator, animationName)

	for index, keyframeName in ipairs(keyframeNames) do
		local callback = keyframeFunctions[index]
		if callback then
			AnimationState.animationMarkerConnections[animator][animationName][keyframeName] =
				animationTrack:GetMarkerReachedSignal(keyframeName):Connect(function(_paramString: string)
					callback()
				end)
		end
	end
end

-- ========================================
-- 公共函数
-- ========================================

--[[
	配置表中是否存在该动画（值为数字 AssetId）
	@param animationName string - 动画名称
	@return boolean - 是否存在有效 ID
]]
function TrackCache.HasAnimationConfig(animationName: string): boolean
	return type(AnimationTable[animationName]) == "number"
end

--[[
	获取配置表中的动画 ID
	@param animationName string - 动画名称
	@return number? - 动画 ID
]]
function TrackCache.GetConfiguredAnimID(animationName: string): number?
	return _getConfiguredAnimID(animationName)
end

--[[
	将动画 ID 格式化为资源 URL
	@param animationID number - 动画 ID
	@return string - 资源 URL
]]
function TrackCache.FormatAnimationAssetId(animationID: number): string
	return _formatAnimationAssetId(animationID)
end

--[[
	从模型中查找 Animator
	@param model Model - 模型
	@return Animator? - 动画器
]]
function TrackCache.FindAnimatorFromModel(model: Model): Animator?
	local humanoid = model:FindFirstChildOfClass("Humanoid")
		or model:FindFirstChildOfClass("AnimationController")

	if humanoid then
		return humanoid:FindFirstChildOfClass("Animator")
	end

	return nil
end

--[[
	获取已缓存的动画轨道
	@param animator Animator - 动画器
	@param animationName string - 动画名称
	@return AnimationTrack? - 动画轨道
]]
function TrackCache.GetCachedTrack(animator: Animator, animationName: string): AnimationTrack?
	local cache = AnimationState.animationTrackCache[animator]
	return cache and cache[animationName]
end

--[[
	获取 Animator 下全部已缓存轨道（内部缓存原表，仅本目录迭代；禁止增删键）
	@param animator Animator - 动画器
	@return {[string]: AnimationTrack}? - 轨道表；无缓存时 nil
]]
function TrackCache.GetAnimatorTrackCache(animator: Animator): { [string]: AnimationTrack }?
	return AnimationState.animationTrackCache[animator]
end

--[[
	加载并配置动画轨道
	@param animator Animator - 动画器
	@param animationName string - 动画名称
	@param animationSpeed number - 播放速度
	@param keyframeNames {string}? - 关键帧名称列表
	@param keyframeFunctions {() -> ()}? - 回调列表
	@param priority Enum.AnimationPriority? - 优先级
	@param shouldPlay boolean - 是否播放
	@param fadeTime number - 淡入时间
	@return AnimationTrack? - 动画轨道
]]
function TrackCache.LoadAndConfigureTrack(
	animator: Animator,
	animationName: string,
	animationSpeed: number,
	keyframeNames: {string}?,
	keyframeFunctions: {() -> ()}?,
	priority: Enum.AnimationPriority?,
	shouldPlay: boolean,
	fadeTime: number
): AnimationTrack?
	if not TrackCache.HasAnimationConfig(animationName) then
		warn("未找到动画配置:", animationName)
		return nil
	end

	local success, result = pcall(_getAnimationTrack, animator, animationName)
	if not success then
		warn("加载动画轨道失败:", animationName, result)
		return nil
	end

	local animationTrack = result :: AnimationTrack?
	if not animationTrack then
		warn("加载动画轨道失败:", animationName)
		return nil
	end

	_bindKeyframeEvents(animator, animationName, animationTrack, keyframeNames, keyframeFunctions)

	if priority then
		animationTrack.Priority = priority
	end

	-- 技能同轨衔接：Play 请求 = 从头播；禁止因 IsPlaying 跳过 Play 而继承上一段 TimePosition
	-- soft-merge「轨已在播则不碰」路径不调用本函数 Play 分支，不受影响
	if shouldPlay then
		-- 上次 FadeOutForLocoBlend 可能留下 Weight=0 / Priority=Core，必须复位
		animationTrack:AdjustWeight(1, 0)
		if priority then
			animationTrack.Priority = priority
		end
		if animationTrack.IsPlaying then
			animationTrack:Stop(0)
			animationTrack.TimePosition = 0
		end
		animationTrack:Play(fadeTime)
	end

	animationTrack:AdjustSpeed(animationSpeed)
	return animationTrack
end

--[[
	绑定动画结束回调
	@param animator Animator - 动画器
	@param animationName string - 动画名称
	@param endCallback (() -> ())? - 结束回调
]]
function TrackCache.BindEndFunc(animator: Animator, animationName: string, endCallback: (() -> ())?)
	if not TrackCache.HasAnimationConfig(animationName) then
		warn("未找到动画配置:", animationName)
		return
	end

	if not AnimationState.animationEndConnections[animator] then
		AnimationState.animationEndConnections[animator] = {}
	end

	if AnimationState.animationEndConnections[animator][animationName] then
		AnimationState.animationEndConnections[animator][animationName]:Disconnect()
		AnimationState.animationEndConnections[animator][animationName] = nil
	end

	if not endCallback then
		return
	end

	local animationTrack: AnimationTrack? = TrackCache.GetCachedTrack(animator, animationName)
	if not animationTrack then
		local animationID = _getConfiguredAnimID(animationName)
		if not animationID then
			return
		end

		local targetAnimationId = _formatAnimationAssetId(animationID)
		for _, track: AnimationTrack in pairs(animator:GetPlayingAnimationTracks()) do
			if track.Animation.AnimationId == targetAnimationId or track.Name == animationName then
				animationTrack = track
				break
			end
		end
	end

	if animationTrack then
		if not animationTrack.Looped then
			AnimationState.animationEndConnections[animator][animationName] = animationTrack.Ended:Connect(function()
				if AnimationState.animationEndConnections[animator] and AnimationState.animationEndConnections[animator][animationName] then
					AnimationState.animationEndConnections[animator][animationName]:Disconnect()
					AnimationState.animationEndConnections[animator][animationName] = nil
				end

				if endCallback then
					endCallback()
				end
			end)
		end
	else
		warn("未找到动画轨道:", animationName, "，请确保动画已播放")
	end
end

return TrackCache
