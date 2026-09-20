--[[
	Module: AnimationModule-Type
	Description: AnimationModule 类型声明（完整使用说明见 ToolSystem/AnimationModule/init.luau 文件头）
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-08-31
]]

local AnimationModule = {}

export type ActionClaim = {
	character: Model?,
	ownerId: string,
	priority: number?,
	blendPolicy: string?,
	suppressLoco: boolean?,
	pauseBaseTracks: boolean?,
	facingOwner: string?,
	cameraOwner: string?,
	reason: string?,
	ttlSeconds: number?,
	releaseOnStopped: boolean?,
}

--[[
	播放动画
	@param animator Animator - 动画器
	@param animationName string - Animation.luau 键名
	@param animationSpeed number? - 播放倍速；nil 时为 1
	@param keyframeNames {string}? - Marker 名称列表；须与资源内 Marker 一致
	@param keyframeFunctions {() -> ()}? - 与 keyframeNames 一一对应的回调
	@param priority Enum.AnimationPriority? - 动画优先级
	@param fadeTime number? - 淡入秒数；nil 时为 0
	@param actionClaim ActionClaim? - 可选占用 ActionArbiter；须含 character+ownerId
	@return number? - 轨道 Length（秒）；失败 nil
]]
function AnimationModule.PlayAnim(
	animator: Animator,
	animationName: string,
	animationSpeed: number?,
	keyframeNames: {string}?,
	keyframeFunctions: {() -> ()}?,
	priority: Enum.AnimationPriority?,
	fadeTime: number?,
	actionClaim: ActionClaim?
): number?
end

--[[
	查询 animator 上已缓存的 AnimationTrack（未加载则 nil）
	@param animator Animator - 动画器
	@param animationName string - Animation.luau 键名
	@return AnimationTrack? - 缓存轨道
]]
function AnimationModule.GetCachedTrack(animator: Animator, animationName: string): AnimationTrack?
end

--[[
	只加载不自动播放
	@param animator Animator - 动画器
	@param animationName string - 动画名称
	@param animationSpeed number? - 播放速度；nil 时为 1
	@param keyframeNames {string}? - Marker 名称列表
	@param keyframeFunctions {() -> ()}? - 对应回调
	@param priority Enum.AnimationPriority? - 动画优先级
	@param fadeTime number? - 淡入秒数；nil 时为 0
	@return AnimationTrack? - 动画轨道；失败 nil
]]
function AnimationModule.LoadAnimationTrack(
	animator: Animator,
	animationName: string,
	animationSpeed: number?,
	keyframeNames: {string}?,
	keyframeFunctions: {() -> ()}?,
	priority: Enum.AnimationPriority?,
	fadeTime: number?
): AnimationTrack?
end

--[[
	将已加载轨道跳到指定时间位置
	@param animator Animator - 动画器
	@param animationName string - 动画名称
	@param timePosition number - 秒，会夹紧到 [0, Length)
	@return boolean - 是否成功找到轨道并写入
]]
function AnimationModule.SetAnimationTimePosition(animator: Animator, animationName: string, timePosition: number): boolean
end

--[[
	停止动画
	@param animator Animator - 动画器
	@param animationName string - 动画名称
	@param fadeTime number? - 淡出秒数；nil 时为 0
]]
function AnimationModule.StopAnim(animator: Animator, animationName: string, fadeTime: number?)
end

--[[
	硬停指定动画（无淡出）
	@param animator Animator - 动画器
	@param animationName string - 动画名称
]]
function AnimationModule.StopAnimHard(animator: Animator, animationName: string)
end

--[[
	调整正在播放轨道的权重
	@param animator Animator - 动画器
	@param animationName string - 动画名称
	@param weight number - 目标权重
	@param fadeTime number? - 过渡秒数；nil 时为 0
	@return boolean - 是否找到轨道并调整
]]
function AnimationModule.AdjustAnimWeight(animator: Animator, animationName: string, weight: number, fadeTime: number?): boolean
end

--[[
	仅降 Priority，不 Stop / 不改权重
	@param animator Animator - 动画器
	@param animationName string - 动画名称
	@param priority Enum.AnimationPriority? - 目标档位；nil 时为 Core
	@return boolean - 是否找到轨道并降档
]]
function AnimationModule.DemoteAnimPriority(
	animator: Animator,
	animationName: string,
	priority: Enum.AnimationPriority?
): boolean
end

--[[
	软淡出业务轨：保持当前 Priority，仅权重→0 + Stop
	@param animator Animator - 动画器
	@param animationName string - 动画名称
	@param fadeTime number? - 淡出秒数；nil 时为 0.5
	@return boolean - 是否对轨道做了处理
]]
function AnimationModule.FadeOutSoftKeepPriority(animator: Animator, animationName: string, fadeTime: number?): boolean
end

--[[
	先把 Priority 降到 Core，再权重→0 + Stop（交接 loco/Jump）
	@param animator Animator - 动画器
	@param animationName string - 动画名称
	@param fadeTime number? - 淡出秒数；nil 时为 0.25
	@return boolean - 是否对轨道做了处理
]]
function AnimationModule.FadeOutForLocoBlend(animator: Animator, animationName: string, fadeTime: number?): boolean
end

--[[
	通过模型播放动画
	@param model Model - 模型
	@param animationName string - 动画名称
	@param animationSpeed number? - 播放速度；nil 时为 1
	@param keyframeNames {string}? - Marker 名称列表
	@param keyframeFunctions {() -> ()}? - 对应回调
	@param priority Enum.AnimationPriority? - 动画优先级
	@param fadeTime number? - 淡入秒数；nil 时为 0
	@param actionClaim ActionClaim? - 可选占用；character 缺省时补为 model
	@return number? - 动画长度（秒）；失败 nil
]]
function AnimationModule.PlayAnimByModel(
	model: Model,
	animationName: string,
	animationSpeed: number?,
	keyframeNames: {string}?,
	keyframeFunctions: {() -> ()}?,
	priority: Enum.AnimationPriority?,
	fadeTime: number?,
	actionClaim: ActionClaim?
): number?
end

--[[
	通过模型停止动画
	@param model Model - 模型
	@param animationName string - 动画名称
	@param fadeTime number? - 淡出秒数；nil 时为 0
]]
function AnimationModule.StopAnimByModel(model: Model, animationName: string, fadeTime: number?)
end

--[[
	改变动画速度
	@param animator Animator - 动画器
	@param animationName string - 动画名称
	@param animationSpeed number - 新的播放速度
]]
function AnimationModule.ChangeAnimSpeed(animator: Animator, animationName: string, animationSpeed: number)
end

--[[
	停止所有已缓存动画（并清除冻结 Heartbeat）
	@param animator Animator - 动画器
]]
function AnimationModule.StopAll(animator: Animator)
end

--[[
	绑定动画结束回调
	@param animator Animator - 动画器
	@param animationName string - 动画名称
	@param endCallback (() -> ())? - 结束回调；nil 则清除；仅非 Loop 轨触发一次
]]
function AnimationModule.BindEndFunc(animator: Animator, animationName: string, endCallback: (() -> ())?)
end

--[[
	检查动画是否正在播放
	@param animator Animator - 动画器
	@param animationName string - 动画名称
	@return boolean - 是否正在播放
]]
function AnimationModule.IsAnimPlaying(animator: Animator, animationName: string): boolean
end

--[[
	检查多个动画是否有任意一个正在播放
	@param animator Animator - 动画器
	@param animationNameTable {string} - 动画名称数组
	@return boolean - 是否有动画正在播放
]]
function AnimationModule.IsAnimsPlaying(animator: Animator, animationNameTable: {string}): boolean
end

--[[
	通过动画 ID 停止正在播放的轨道
	@param animator Animator - 动画器
	@param animationID number - rbx 数字 ID
]]
function AnimationModule.StopAnimByID(animator: Animator, animationID: number)
end

--[[
	获取动画 ID
	@param animationName string - 动画名称
	@return number? - 动画 ID；未找到时 nil
]]
function AnimationModule.GetAnimID(animationName: string): number?
end

--[[
	获取预加载表
	@return {string} - rbxassetid:// 格式的 ID 列表
]]
function AnimationModule.GetPreloadTable(): {string}
end

--[[
	冻结指定动画：Speed 置 0，Heartbeat 按间隔推进 TimePosition
	@param animator Animator - 动画器
	@param animationName string - 动画名称（须已 Play 过）
	@param updateInterval number - 更新间隔（秒），须 > 0
]]
function AnimationModule.FreezeAnimationAtTime(animator: Animator, animationName: string, updateInterval: number)
end

--[[
	恢复动画播放
	@param animator Animator - 动画器
	@param animationName string - 动画名称
	@param animationSpeed number? - 恢复后的播放速度；nil 时为 1
]]
function AnimationModule.ResumeAnimation(animator: Animator, animationName: string, animationSpeed: number?)
end

--[[
	冻结 Animator 下所有正在播放的缓存动画
	@param animator Animator - 动画器
	@param updateInterval number - 更新间隔（秒），须 > 0
]]
function AnimationModule.FreezeAllAnimations(animator: Animator, updateInterval: number)
end

--[[
	恢复 Animator 下曾冻结的动画至 FreezeAll 前记录的 Speed
	@param animator Animator - 动画器
]]
function AnimationModule.ResumeAllAnimations(animator: Animator)
end

return AnimationModule
