--[[
	Module: AnimationState
	Description: AnimationModule 内部共享状态与 Animator 销毁清理
	Author: 林奥宇
	Created: 2026-07-02
	Last Modified: 2026-08-31

	================================================================================
	使用说明
	================================================================================

	仅供本目录子模块（TrackCache / FreezeAnim / init）使用，不经 Utils 对外导出。

	【职责】
	- 按 Animator 持有轨道缓存、Marker / Ended / 冻结 Heartbeat / 占闸 Release 连接
	- CleanupAnimator：Animator.Destroying 时 Stop+Destroy 轨并 Disconnect 全部连接

	【调用约定】
	- 由 TrackCache 在首次为某 Animator 建缓存时绑定 Destroying → CleanupAnimator
	- 各子模块只通过本表读写对应槽，勿另起平行缓存
]]

local AnimationState = {}

-- [Animator] = { [AnimationName] = AnimationTrack }
AnimationState.animationTrackCache = {}
-- [Animator] = RBXScriptConnection
AnimationState.animatorDestroyConnections = {}
-- [Animator] = { [AnimationName] = { [EventName] = RBXScriptConnection } }
AnimationState.animationMarkerConnections = {}
-- [Animator] = { [AnimationName] = RBXScriptConnection }
AnimationState.animationTimeUpdateConnections = {}
-- [Animator] = { [AnimationName] = number }
AnimationState.animationOriginalSpeedCache = {}
-- [Animator] = { [AnimationName] = RBXScriptConnection }
AnimationState.animationEndConnections = {}
-- [Animator] = { [AnimationName] = RBXScriptConnection }  PlayAnim actionClaim 的 Stopped → Release
AnimationState.actionClaimReleaseConnections = {}

--[[
	断开 map 中全部连接并清空键
	@param connectionMap {[any]: RBXScriptConnection}? - 连接表；nil 则跳过
]]
local function _disconnectConnectionMap(connectionMap: { [any]: RBXScriptConnection }?)
	if not connectionMap then
		return
	end
	for key, connection in pairs(connectionMap) do
		connection:Disconnect()
		connectionMap[key] = nil
	end
end

--[[
	Animator 销毁时清理关联的全部缓存与连接
	先 Stop 再断占闸连接，确保 Stopped 能 Release；再 Destroy 轨道并断剩余连接
	@param animator Animator - 动画器
]]
function AnimationState.CleanupAnimator(animator: Animator)
	local destroyConn = AnimationState.animatorDestroyConnections[animator]
	if destroyConn then
		destroyConn:Disconnect()
		AnimationState.animatorDestroyConnections[animator] = nil
	end

	local trackCache = AnimationState.animationTrackCache[animator]
	if trackCache then
		for _, track: AnimationTrack in pairs(trackCache) do
			track:Stop()
		end
	end

	_disconnectConnectionMap(AnimationState.actionClaimReleaseConnections[animator])
	AnimationState.actionClaimReleaseConnections[animator] = nil

	if trackCache then
		for _, track: AnimationTrack in pairs(trackCache) do
			track:Destroy()
		end
		AnimationState.animationTrackCache[animator] = nil
	end

	local markerByAnim = AnimationState.animationMarkerConnections[animator]
	if markerByAnim then
		for _, eventMap in pairs(markerByAnim) do
			_disconnectConnectionMap(eventMap)
		end
		AnimationState.animationMarkerConnections[animator] = nil
	end

	_disconnectConnectionMap(AnimationState.animationTimeUpdateConnections[animator])
	AnimationState.animationTimeUpdateConnections[animator] = nil

	AnimationState.animationOriginalSpeedCache[animator] = nil

	_disconnectConnectionMap(AnimationState.animationEndConnections[animator])
	AnimationState.animationEndConnections[animator] = nil
end

return AnimationState
