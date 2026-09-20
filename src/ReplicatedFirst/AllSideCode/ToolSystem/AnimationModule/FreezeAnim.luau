--[[
	Module: FreezeAnim
	Description: 动画冻结与恢复（Heartbeat 驱动时间推进）
	Author: 林奥宇
	Created: 2026-07-02
	Last Modified: 2026-08-31

	================================================================================
	使用说明
	================================================================================

	仅供 AnimationModule 公共冻结 API 转发，不经 Utils 单独导出。

	【行为】
	- Freeze：Speed 置 0，Heartbeat 按 updateInterval 累加 TimePosition（可循环）
	- Resume：断开 Heartbeat，恢复 Speed 并保证轨道在播
	- FreezeAll 只冻当前 IsPlaying 的缓存轨，并记下原始 Speed
	- ResumeAll 只恢复曾冻结的轨，不会把未播轨强行 Play
	- ClearFreezeState：只断 Heartbeat、清 Speed 缓存，不恢复播放（供 StopAll）

	【前提】
	单轨 Freeze 前须已 Play / Load 出缓存轨；updateInterval 必须 > 0。
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local RunService = Utils.RunService

local AnimationState = require(script.Parent.AnimationState)
local TrackCache = require(script.Parent.TrackCache)

local FreezeAnim = {}

-- ========================================
-- 常量定义
-- ========================================
local DEFAULT_RESUME_SPEED = 1

-- ========================================
-- 私有函数
-- ========================================

--[[
	断开指定动画的冻结 Heartbeat 连接
	@param animator Animator - 动画器
	@param animationName string - 动画名称
]]
local function _disconnectTimeUpdate(animator: Animator, animationName: string)
	if AnimationState.animationTimeUpdateConnections[animator] and AnimationState.animationTimeUpdateConnections[animator][animationName] then
		AnimationState.animationTimeUpdateConnections[animator][animationName]:Disconnect()
		AnimationState.animationTimeUpdateConnections[animator][animationName] = nil
	end
end

--[[
	为动画轨道建立冻结模式下的 Heartbeat 时间推进
	@param animator Animator - 动画器
	@param animationName string - 动画名称
	@param animationTrack AnimationTrack - 动画轨道
	@param updateInterval number - 更新间隔（秒），须 > 0
]]
local function _connectFreezeTimeUpdate(
	animator: Animator,
	animationName: string,
	animationTrack: AnimationTrack,
	updateInterval: number
)
	_disconnectTimeUpdate(animator, animationName)

	if not AnimationState.animationTimeUpdateConnections[animator] then
		AnimationState.animationTimeUpdateConnections[animator] = {}
	end

	if not animationTrack.IsPlaying then
		animationTrack:Play()
	end

	animationTrack:AdjustSpeed(0)

	local currentTime = animationTrack.TimePosition
	local accumulatedTime = 0

	AnimationState.animationTimeUpdateConnections[animator][animationName] = RunService.Heartbeat:Connect(function(deltaTime: number)
		accumulatedTime += deltaTime

		if accumulatedTime >= updateInterval then
			currentTime += accumulatedTime

			local length = animationTrack.Length
			if type(length) == "number" and length > 0 and currentTime > length then
				currentTime = currentTime % length
			elseif type(length) ~= "number" or length <= 0 then
				currentTime = 0
			end

			animationTrack.TimePosition = currentTime
			accumulatedTime = 0
		end
	end)
end

-- ========================================
-- 公共函数
-- ========================================

--[[
	冻结动画并持续更新时间位置
	@param animator Animator - 动画器
	@param animationName string - 动画名称（须已在缓存中）
	@param updateInterval number - 更新时间间隔（秒），须 > 0
]]
function FreezeAnim.FreezeAnimationAtTime(animator: Animator, animationName: string, updateInterval: number)
	if not animator then
		warn("Animator不存在")
		return
	end

	if not animator.Parent then
		return
	end

	if not TrackCache.HasAnimationConfig(animationName) then
		warn("未找到动画配置:", animationName)
		return
	end

	if not updateInterval or updateInterval <= 0 then
		warn("更新时间间隔必须大于0")
		return
	end

	local animationTrack = TrackCache.GetCachedTrack(animator, animationName)
	if not animationTrack then
		warn("动画轨道不存在，请先播放动画:", animationName)
		return
	end

	_connectFreezeTimeUpdate(animator, animationName, animationTrack, updateInterval)
end

--[[
	恢复动画播放
	@param animator Animator - 动画器
	@param animationName string - 动画名称
	@param animationSpeed number? - 播放速度；nil 时为 1
]]
function FreezeAnim.ResumeAnimation(animator: Animator, animationName: string, animationSpeed: number?)
	if not animator then
		warn("Animator不存在")
		return
	end

	if not animator.Parent then
		return
	end

	if not TrackCache.HasAnimationConfig(animationName) then
		warn("未找到动画配置:", animationName)
		return
	end

	_disconnectTimeUpdate(animator, animationName)

	local animationTrack = TrackCache.GetCachedTrack(animator, animationName)
	if not animationTrack then
		warn("动画轨道不存在:", animationName)
		return
	end

	animationTrack:AdjustSpeed(animationSpeed or DEFAULT_RESUME_SPEED)

	if not animationTrack.IsPlaying then
		animationTrack:Play()
	end
end

--[[
	冻结 Animator 的所有正在播放的缓存动画，并记下原始 Speed
	@param animator Animator - 动画器
	@param updateInterval number - 更新时间间隔（秒），须 > 0
]]
function FreezeAnim.FreezeAllAnimations(animator: Animator, updateInterval: number)
	if not animator then
		warn("Animator不存在")
		return
	end

	if not animator.Parent then
		return
	end

	if not updateInterval or updateInterval <= 0 then
		warn("更新时间间隔必须大于0")
		return
	end

	if not AnimationState.animationOriginalSpeedCache[animator] then
		AnimationState.animationOriginalSpeedCache[animator] = {}
	end

	local trackCache = TrackCache.GetAnimatorTrackCache(animator)
	if trackCache then
		for animationName, animationTrack: AnimationTrack in pairs(trackCache) do
			if animationTrack.IsPlaying then
				AnimationState.animationOriginalSpeedCache[animator][animationName] = animationTrack.Speed
				_connectFreezeTimeUpdate(animator, animationName, animationTrack, updateInterval)
			end
		end
	end
end

--[[
	仅断开冻结 Heartbeat 并清空原始 Speed 缓存，不恢复播放
	供 StopAll：避免停轨后 Heartbeat 仍写 TimePosition
	@param animator Animator - 动画器
]]
function FreezeAnim.ClearFreezeState(animator: Animator)
	if not animator then
		return
	end

	local timeUpdateConnections = AnimationState.animationTimeUpdateConnections[animator]
	if timeUpdateConnections then
		for animationName, connection: RBXScriptConnection in pairs(timeUpdateConnections) do
			connection:Disconnect()
			timeUpdateConnections[animationName] = nil
		end
	end

	AnimationState.animationOriginalSpeedCache[animator] = nil
end

--[[
	恢复 Animator 下曾冻结的动画至 FreezeAll 前记录的 Speed
	只处理有冻结连接或原始 Speed 记录的轨，不会 Play 从未冻结的缓存轨
	@param animator Animator - 动画器
]]
function FreezeAnim.ResumeAllAnimations(animator: Animator)
	if not animator then
		warn("Animator不存在")
		return
	end

	if not animator.Parent then
		return
	end

	local frozenNames: { [string]: boolean } = {}
	local timeConns = AnimationState.animationTimeUpdateConnections[animator]
	if timeConns then
		for animationName in pairs(timeConns) do
			frozenNames[animationName] = true
		end
	end
	local speedCache = AnimationState.animationOriginalSpeedCache[animator]
	if speedCache then
		for animationName in pairs(speedCache) do
			frozenNames[animationName] = true
		end
	end

	local trackCache = TrackCache.GetAnimatorTrackCache(animator)
	for animationName in pairs(frozenNames) do
		_disconnectTimeUpdate(animator, animationName)

		local animationTrack = trackCache and trackCache[animationName]
		if not animationTrack then
			if speedCache then
				speedCache[animationName] = nil
			end
			continue
		end

		if speedCache and speedCache[animationName] then
			animationTrack:AdjustSpeed(speedCache[animationName])
			speedCache[animationName] = nil
		else
			animationTrack:AdjustSpeed(DEFAULT_RESUME_SPEED)
		end

		if not animationTrack.IsPlaying then
			animationTrack:Play()
		end
	end
end

return FreezeAnim
