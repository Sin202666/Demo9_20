--[[
	Module: AnimationModule
	Description: 动画播放、停止、缓存与冻结控制
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-08-31

	================================================================================
	使用说明
	================================================================================

	【适用场景】
	客户端/服务端均可调用（动画资源在本地加载），统一通过配置表名称播放动画，
	避免各业务脚本重复 LoadAnimation、缓存轨道、绑定 Marker/Ended 事件。

	【与 Animate Jump/Land】
	- 装饰表情等用 Idle：盖不住 Land（Land=Action）；Idle 只留给装饰。
	- 取消落地/起跳：须 Priority≥Action，并传入 actionClaim（suppressLoco / pauseBaseTracks）；
	  禁止「Idle 攻击轨」偷盖落地。

	【获取模块】
	local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
	local AnimationModule = Utils.AnimationModule

	【动画配置 Animation.luau】
	所有 animationName 必须在子模块 Animation.luau 中注册：
	  ["Idle"] = 73017323943165,
	  ["Jump"] = 74574734044792,
	新增动作时在此表追加「名称 → rbx 动画 ID」即可；GetAnimID / GetPreloadTable 均读取此表。

	【快速开始 — 通过 Animator 播放】
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local animator = humanoid:FindFirstChildOfClass("Animator")
	local length = AnimationModule.PlayAnim(animator, "Idle")
	-- length 为动画时长（秒），加载失败返回 nil

	【快速开始 — 通过 Model 播放】
	-- 自动从 Model 下 Humanoid 或 AnimationController 查找 Animator
	AnimationModule.PlayAnimByModel(heroModel, "Idle")

	【PlayAnim 参数】
	PlayAnim(animator, animationName, animationSpeed?, keyframeNames?, keyframeFunctions?, priority?, fadeTime?, actionClaim?)
	同一 animator + animationName 再次 Play：若轨已在播则 Stop(0) 并从头 Play（技能同轨衔接，不继承上一段 TimePosition）。
	软合并续播请勿再调 Play，只 claim + SetAnimationTimePosition。
	- animator Animator - 目标动画器；不存在或已脱离层级树时静默失败
	- animationName string - Animation.luau 中的键名
	- animationSpeed number? - 播放倍速，默认 1
	- keyframeNames {string}? - 动画 Marker 名称列表（须与资源内 Marker 一致）
	- keyframeFunctions {() -> ()}? - 与 keyframeNames 一一对应的回调
	- priority Enum.AnimationPriority? - 如 Enum.AnimationPriority.Action
	- fadeTime number? - 淡入秒数，默认 0
	- actionClaim table? - **opt-in** 占用 ActionArbiter（默认不占闸）。须含：
	    character Model, ownerId string；可选 priority/suppressLoco/pauseBaseTracks/facingOwner/cameraOwner
	    轨道 Stopped 时自动 Release（releaseOnStopped=false 可关闭）
	  例：PlayAnim(animator, "Attack", 1, nil, nil, Enum.AnimationPriority.Action, 0.1, {
	    character = player.Character, ownerId = "Skill:Attack",
	    suppressLoco = true, pauseBaseTracks = true, facingOwner = "External",
	  })
	- @return number? - 轨道 Length（秒）

	【LoadAnimationTrack — 只加载不自动播放】
	local track = AnimationModule.LoadAnimationTrack(animator, "Attack", 1, {"Hit"}, {onHit})
	if track then
		track:Play(0.1)
	end
	与 PlayAnim 参数相同，但不会自动 Play；适合需要手动控制 Play/Stop 的场景。
	同一 animator + animationName 命中缓存时复用已有轨道，不会重复 LoadAnimation。

	【停止与速度】
	AnimationModule.StopAnim(animator, "Idle", fadeTime?)       -- 停止指定动画
	AnimationModule.StopAnimByModel(model, "Idle", fadeTime?) -- 通过 Model 停止
	AnimationModule.StopAll(animator)                          -- 停止该 Animator 全部缓存轨道
	AnimationModule.ChangeAnimSpeed(animator, "RunForward", 1.5)
	AnimationModule.StopAnimByID(animator, animationID)        -- 按 rbx 数字 ID 停止正在播放的轨道

	【状态查询】
	AnimationModule.IsAnimPlaying(animator, "Idle")            -- 单个
	AnimationModule.IsAnimsPlaying(animator, {"Idle", "Walk"}) -- 任意一个在播即 true
	AnimationModule.GetAnimID("Idle")                          -- 查配置表 ID，未找到 warn 并返回 nil

	【关键帧 Marker 回调】
	在 PlayAnim / LoadAnimationTrack 时传入 keyframeNames 与 keyframeFunctions：
	  AnimationModule.PlayAnim(animator, "Attack", 1,
	    {"WindUp", "Hit"},
	    {function() print("前摇") end, function() print("命中") end}
	  )
	每次调用会替换该动画已有的 Marker 连接；名称须与动画编辑器中 Marker 完全一致。

	【动画结束回调 BindEndFunc】
	AnimationModule.BindEndFunc(animator, "Attack", function()
		print("攻击结束")
	end)
	- 仅对非 Loop 动画有效；Looped 轨道不会触发 Ended
	- 须先 PlayAnim 或 LoadAnimationTrack 使轨道存在；也可绑定当前正在播放的同 ID 轨道
	- 回调触发一次后自动 Disconnect；传 nil 可清除已有绑定

	【时间轴跳转 SetAnimationTimePosition】
	AnimationModule.SetAnimationTimePosition(animator, "Attack", 0.35)
	将已缓存轨道跳到指定秒数（夹紧到 [0, Length)），未播放时会先 Play(0)。
	用于技能预测与正式表现的软合并：预测阶段 LoadAnimationTrack，确认后 SetAnimationTimePosition 对齐。

	【冻结模式 — 精确控制 TimePosition】
	冻结时将 Speed 置 0，由 Heartbeat 按 updateInterval 手动推进 TimePosition：
	  AnimationModule.PlayAnim(animator, "Idle")
	  AnimationModule.FreezeAnimationAtTime(animator, "Idle", 1/60)  -- 每帧更新
	  -- ... 外部逻辑控制暂停/步进 ...
	  AnimationModule.ResumeAnimation(animator, "Idle", 1)           -- 恢复正常播放

	批量操作（如过场暂停全部动作）：
	  AnimationModule.FreezeAllAnimations(animator, 1/60)
	  AnimationModule.ResumeAllAnimations(animator)  -- 恢复 FreezeAll 前记录的原始 Speed

	注意：Freeze 前须已 Play 过该动画；updateInterval 必须 > 0。

	【预加载】
	local ids = AnimationModule.GetPreloadTable()  -- {"rbxassetid://...", ...}
	ResRestore.PreloadAnimation(ids)               -- 见 ResPreloadManager 启动预热

	SkillPreloadUtil 亦通过 GetAnimID 将技能配置中的动作名转为 ID 预加载。

	【生命周期与缓存】
	- 每个 Animator 维护独立轨道缓存；Animator.Destroying 时自动 Stop、Destroy 轨道并 Disconnect 全部事件
	- 业务无需手动 Destroy AnimationTrack；角色/模型销毁后缓存自动清理
	- Humanoid 下若无 Animator，PlayAnimByModel 返回 nil；需自行 InsMgr 创建 Animator

	【子模块结构】
	- Animation.luau      动画 ID 配置表
	- AnimationState.luau 共享状态与销毁清理
	- TrackCache.luau     轨道缓存、加载与事件绑定
	- FreezeAnim.luau     冻结/恢复逻辑

	【项目内参考调用】
	- Animate/init.client：经 LocoStyle 绑定 locomotion 基轨（风格热换 → GetAnimID）
	- LocoStyle / LocoStyleSets：styleId → 逻辑名 → GetAnimID
	- ResPreloadManager：GetPreloadTable + ResRestore.PreloadAnimation 启动预热
	- ViewportFrameModule：PlayAnimByModel / StopAnimByModel 展示模型 Idle
	- HatchRewardEffect：PlayAnim(animator, model:GetAttribute("idle"))
	- SkillPreloadUtil：GetAnimID 按技能名预加载动作
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local ActionArbiter = Utils.ActionArbiter

local AnimationTable = require(script.Animation)
local AnimationState = require(script.AnimationState)
local TrackCache = require(script.TrackCache)
local FreezeAnim = require(script.FreezeAnim)

-- ========================================
-- 模块定义
-- ========================================
local AnimationModule = {}

debug.setmemorycategory(script.Name .. "-内存检测")

-- ========================================
-- 常量定义
-- ========================================
local DEFAULT_ANIM_SPEED = 1
local DEFAULT_FADE_TIME = 0
local DEFAULT_SOFT_FADE_TIME = 0.5
local DEFAULT_LOCO_BLEND_FADE_TIME = 0.25
local DEFAULT_DEMOTE_PRIORITY = Enum.AnimationPriority.Core

-- ========================================
-- 私有函数
-- ========================================

--[[
	opt-in 动作仲裁占用（须 Animate 已 Create Arbiter）
	@param actionClaim table? - nil 则跳过；否则须含：
	    character Model - 角色（PlayAnimByModel 可省略，由入口补全）
	    ownerId string - 占用方 ID，非空
	    priority number? - 仲裁优先级；nil 时 ActionArbiter.Priority.Skill
	    blendPolicy string? - Override/Overlay/FacingOnly/React
	    suppressLoco boolean? / pauseBaseTracks boolean?
	    facingOwner string? / cameraOwner string?
	    reason string? / ttlSeconds number?
	@return string? - Acquire token；校验失败或尚未 Create 时 nil
]]
local function _tryAcquireActionClaim(actionClaim: any): string?
	if type(actionClaim) ~= "table" then
		return nil
	end
	local character = actionClaim.character
	if typeof(character) ~= "Instance" or not character:IsA("Model") then
		warn("AnimationModule actionClaim.character 须为 Model")
		return nil
	end
	local ownerId = actionClaim.ownerId
	if type(ownerId) ~= "string" or ownerId == "" then
		warn("AnimationModule actionClaim.ownerId 必填")
		return nil
	end
	local arbiter = ActionArbiter.GetForCharacter(character)
	if not arbiter then
		warn("AnimationModule actionClaim：角色尚未 Create ActionArbiter，已忽略占用")
		return nil
	end
	local priority = actionClaim.priority
	if type(priority) ~= "number" then
		priority = ActionArbiter.Priority.Skill
	end
	return arbiter:Acquire({
		ownerId = ownerId,
		priority = priority,
		blendPolicy = actionClaim.blendPolicy,
		suppressLoco = actionClaim.suppressLoco,
		pauseBaseTracks = actionClaim.pauseBaseTracks,
		facingOwner = actionClaim.facingOwner,
		cameraOwner = actionClaim.cameraOwner,
		reason = actionClaim.reason or ("AnimationModule:" .. ownerId),
		ttlSeconds = actionClaim.ttlSeconds,
	})
end

--[[
	在轨道 Stopped 时 Release 占用（仅一次）；连接记入 AnimationState 以便销毁时断开
	@param animator Animator - 动画器
	@param animationName string - 动画配置键名
	@param character Model - 占用所属角色
	@param token string - Acquire 返回的 token
	@param track AnimationTrack - 播放中的轨道
]]
local function _releaseClaimOnTrackStopped(
	animator: Animator,
	animationName: string,
	character: Model,
	token: string,
	track: AnimationTrack
)
	if not AnimationState.actionClaimReleaseConnections[animator] then
		AnimationState.actionClaimReleaseConnections[animator] = {}
	end
	local prev = AnimationState.actionClaimReleaseConnections[animator][animationName]
	if prev then
		prev:Disconnect()
		AnimationState.actionClaimReleaseConnections[animator][animationName] = nil
	end

	local conn: RBXScriptConnection? = nil
	conn = track.Stopped:Connect(function()
		if conn then
			conn:Disconnect()
			conn = nil
		end
		if AnimationState.actionClaimReleaseConnections[animator] then
			AnimationState.actionClaimReleaseConnections[animator][animationName] = nil
		end
		local arbiter = ActionArbiter.GetForCharacter(character)
		if arbiter then
			arbiter:Release(token)
		end
	end)
	AnimationState.actionClaimReleaseConnections[animator][animationName] = conn
end

--[[
	解析已配置且已缓存的轨道（淡出/权重/降档 API 共用）
	@param animator Animator - 动画器；须仍在层级树中
	@param animationName string - Animation.luau 键名
	@return AnimationTrack? - 缓存轨道；参数非法或未加载时 nil
]]
local function _getConfiguredCachedTrack(animator: Animator, animationName: string): AnimationTrack?
	if not animator or not animator.Parent then
		return nil
	end
	if type(animationName) ~= "string" or animationName == "" then
		return nil
	end
	if not TrackCache.HasAnimationConfig(animationName) then
		return nil
	end
	return TrackCache.GetCachedTrack(animator, animationName)
end

-- ========================================
-- 公共函数 — 播放控制
-- ========================================

--[[
	播放动画
	@param animator Animator - 动画器
	@param animationName string - 动画名称
	@param animationSpeed number? - 播放速度（默认1）
	@param keyframeNames {string}? - 动画 Marker 名称列表；须与资源内 Marker 一致；nil 则不绑
	@param keyframeFunctions {() -> ()}? - 与 keyframeNames 一一对应的回调；nil 则不绑
	@param priority Enum.AnimationPriority? - 动画优先级；nil 则保持轨上已有档位
	@param fadeTime number? - 淡入秒数；nil 时为 0
	@param actionClaim table? - 可选占用 ActionArbiter；须含 character Model + ownerId string；
	    可选 priority / blendPolicy / suppressLoco / pauseBaseTracks / facingOwner / cameraOwner /
	    reason / ttlSeconds / releaseOnStopped（默认 true，Stopped 时自动 Release）
	@return number? - 轨道 Length（秒）；加载失败或 Animator 无效时 nil
]]
function AnimationModule.PlayAnim(
	animator: Animator,
	animationName: string,
	animationSpeed: number?,
	keyframeNames: {string}?,
	keyframeFunctions: {() -> ()}?,
	priority: Enum.AnimationPriority?,
	fadeTime: number?,
	actionClaim: any?
): number?
	if not animator then
		warn("Animator不存在")
		return nil
	end

	if not animator.Parent then
		return nil
	end

	local claimToken = _tryAcquireActionClaim(actionClaim)

	local animationTrack = TrackCache.LoadAndConfigureTrack(
		animator,
		animationName,
		animationSpeed or DEFAULT_ANIM_SPEED,
		keyframeNames,
		keyframeFunctions,
		priority,
		true,
		fadeTime or DEFAULT_FADE_TIME
	)

	if not animationTrack then
		if claimToken and actionClaim and typeof(actionClaim.character) == "Instance" and actionClaim.character:IsA("Model") then
			local arbiter = ActionArbiter.GetForCharacter(actionClaim.character)
			if arbiter then
				arbiter:Release(claimToken)
			end
		end
		return nil
	end

	if claimToken and actionClaim and actionClaim.character and actionClaim.releaseOnStopped ~= false then
		_releaseClaimOnTrackStopped(animator, animationName, actionClaim.character, claimToken, animationTrack)
	end

	return animationTrack.Length
end

--[[
	查询 animator 上已缓存的 AnimationTrack（未加载则 nil）
	@param animator Animator - 动画器
	@param animationName string - Animation 配置键名
	@return AnimationTrack? - 缓存轨道
]]
function AnimationModule.GetCachedTrack(animator: Animator, animationName: string): AnimationTrack?
	if not animator or not animationName then
		return nil
	end
	return TrackCache.GetCachedTrack(animator, animationName)
end

--[[
	将已加载并（可选）正在播放的轨道跳到指定时间，用于技能预测与正式表现的软合并
	@param animator Animator - 动画器
	@param animationName string - 动画名称
	@param timePosition number - 秒，会夹紧到 [0, Length)
	@return boolean - 是否成功找到轨道并写入
]]
function AnimationModule.SetAnimationTimePosition(animator: Animator, animationName: string, timePosition: number): boolean
	if not animator or not animationName or type(timePosition) ~= "number" then
		return false
	end

	local track = TrackCache.GetCachedTrack(animator, animationName)
	if not track then
		return false
	end

	local len = track.Length
	if type(len) == "number" and len > 0 then
		timePosition = math.clamp(timePosition, 0, math.max(0, len - TrackCache.TIME_POSITION_EPSILON))
	end

	if not track.IsPlaying then
		track:Play(0)
	end

	track.TimePosition = timePosition
	return true
end

--[[
	获取一个动作的 AnimationTrack
	@param animator Animator - 动画器
	@param animationName string - 动画名称
	@param animationSpeed number? - 播放速度（默认1）
	@param keyframeNames {string}? - 动画 Marker 名称列表；nil 则不绑
	@param keyframeFunctions {() -> ()}? - 与 keyframeNames 一一对应的回调；nil 则不绑
	@param priority Enum.AnimationPriority? - 动画优先级；nil 则保持轨上已有档位
	@param fadeTime number? - 淡入秒数；nil 时为 0
	@return AnimationTrack? - 动画轨道；加载失败时 nil
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
	if not animator then
		warn("Animator不存在")
		return nil
	end

	if not animator.Parent then
		return nil
	end

	return TrackCache.LoadAndConfigureTrack(
		animator,
		animationName,
		animationSpeed or DEFAULT_ANIM_SPEED,
		keyframeNames,
		keyframeFunctions,
		priority,
		false,
		fadeTime or DEFAULT_FADE_TIME
	)
end

--[[
	通过模型播放动画
	@param model Model - 模型；未显式传 actionClaim.character 时用作角色
	@param animationName string - 动画名称
	@param animationSpeed number? - 播放速度；nil 时为 1
	@param keyframeNames {string}? - 动画 Marker 名称列表；nil 则不绑
	@param keyframeFunctions {() -> ()}? - 与 keyframeNames 一一对应的回调；nil 则不绑
	@param priority Enum.AnimationPriority? - 动画优先级；nil 则保持轨上已有档位
	@param fadeTime number? - 淡入秒数；nil 时为 0
	@param actionClaim table? - 可选占用 ActionArbiter，字段同 PlayAnim.actionClaim；
	    character 缺省时补为 model
	@return number? - 动画长度（秒）；无 Animator 或加载失败时 nil
]]
function AnimationModule.PlayAnimByModel(
	model: Model,
	animationName: string,
	animationSpeed: number?,
	keyframeNames: {string}?,
	keyframeFunctions: {() -> ()}?,
	priority: Enum.AnimationPriority?,
	fadeTime: number?,
	actionClaim: any?
): number?
	local animator = TrackCache.FindAnimatorFromModel(model)
	if animator then
		-- 未显式传 character 时补全，便于 opt-in 占闸
		local claim = actionClaim
		if type(claim) == "table" and claim.character == nil then
			claim = table.clone(claim)
			claim.character = model
		end
		return AnimationModule.PlayAnim(
			animator,
			animationName,
			animationSpeed,
			keyframeNames,
			keyframeFunctions,
			priority,
			fadeTime,
			claim
		)
	end
	return nil
end

--[[
	停止播放动画
	@param animator Animator - 动画器
	@param animationName string - 动画名称
	@param fadeTime number? - 淡出时间（默认0）
]]
function AnimationModule.StopAnim(animator: Animator, animationName: string, fadeTime: number?)
	if not animator then
		warn("Animator不存在")
		return
	end

	if not animator.Parent then
		return
	end

	if not TrackCache.HasAnimationConfig(animationName) then
		return
	end

	local track = TrackCache.GetCachedTrack(animator, animationName)
	if track then
		track:Stop(fadeTime or DEFAULT_FADE_TIME)
	end
end

--[[
	调整正在播放轨道的权重（用于与 loco 权重过渡，避免 Action3 硬切）
	@param animator Animator - 动画器
	@param animationName string - 动画名称
	@param weight number - 目标权重（通常 0）
	@param fadeTime number? - 过渡秒数（默认 0）
	@return boolean - 是否找到轨道并调整
]]
function AnimationModule.AdjustAnimWeight(animator: Animator, animationName: string, weight: number, fadeTime: number?): boolean
	local track = _getConfiguredCachedTrack(animator, animationName)
	if not track or not track.IsPlaying then
		return false
	end
	local w = if type(weight) == "number" then weight else 0
	local fade = if type(fadeTime) == "number" then math.max(0, fadeTime) else DEFAULT_FADE_TIME
	track:AdjustWeight(w, fade)
	return true
end

--[[
	仅降 Priority，不 Stop / 不改权重。
	供控制解锁：先让 Jump(Movement) 能盖住业务轨，无操作时仍可播完尾段再淡出。
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
	local track = _getConfiguredCachedTrack(animator, animationName)
	if not track or not track.IsPlaying then
		return false
	end
	track.Priority = priority or DEFAULT_DEMOTE_PRIORITY
	return true
end

--[[
	软淡出业务轨：保持当前 Priority，仅权重→0 + Stop。
	供翻滚接 3C：勿立刻降到 Core，否则 Movement Idle/Walk 会瞬间盖住导致抽搐。
	@param animator Animator - 动画器
	@param animationName string - 动画名称
	@param fadeTime number? - 权重/停止淡出秒数；nil 时为 0.5
	@return boolean - 是否对轨道做了处理
]]
function AnimationModule.FadeOutSoftKeepPriority(animator: Animator, animationName: string, fadeTime: number?): boolean
	local track = _getConfiguredCachedTrack(animator, animationName)
	if not track then
		return false
	end
	local fade = if type(fadeTime) == "number" then math.max(0, fadeTime) else DEFAULT_SOFT_FADE_TIME
	if track.IsPlaying then
		track:AdjustWeight(0, fade)
	end
	track:Stop(fade)
	return true
end

--[[
	为交接 loco/Jump 淡出业务轨：先把 Priority 降到 Core（Jump=Movement 才能盖住），再权重→0 + Stop。
	仅 AdjustWeight 不够：Action3 在淡出全程仍压 Movement 的 Jump。
	有移向接走/Idle 时优先用 FadeOutSoftKeepPriority，避免降档抽搐。
	@param animator Animator - 动画器
	@param animationName string - 动画名称
	@param fadeTime number? - 权重/停止淡出秒数；nil 时为 0.25
	@return boolean - 是否对轨道做了处理
]]
function AnimationModule.FadeOutForLocoBlend(animator: Animator, animationName: string, fadeTime: number?): boolean
	local track = _getConfiguredCachedTrack(animator, animationName)
	if not track then
		return false
	end
	local fade = if type(fadeTime) == "number" then math.max(0, fadeTime) else DEFAULT_LOCO_BLEND_FADE_TIME
	-- 立刻让出档位：Jump/Walk 为 Movement，须低于它们
	if track.IsPlaying then
		track.Priority = DEFAULT_DEMOTE_PRIORITY
		track:AdjustWeight(0, fade)
	end
	track:Stop(fade)
	return true
end

--[[
	硬停指定动画（无淡出），供跳跃等立刻打断业务尾段。
	@param animator Animator - 动画器
	@param animationName string - 动画名称
]]
function AnimationModule.StopAnimHard(animator: Animator, animationName: string)
	AnimationModule.StopAnim(animator, animationName, 0)
end

--[[
	通过模型停止播放动画
	@param model Model - 模型
	@param animationName string - 动画名称
	@param fadeTime number? - 淡出时间
]]
function AnimationModule.StopAnimByModel(model: Model, animationName: string, fadeTime: number?)
	local animator = TrackCache.FindAnimatorFromModel(model)
	if animator then
		AnimationModule.StopAnim(animator, animationName, fadeTime)
	end
end

--[[
	调整动画播放速度
	@param animator Animator - 动画器
	@param animationName string - 动画名称
	@param animationSpeed number - 播放速度
]]
function AnimationModule.ChangeAnimSpeed(animator: Animator, animationName: string, animationSpeed: number)
	if not animator then
		warn("Animator不存在")
		return
	end

	if not animator.Parent then
		return
	end

	animationSpeed = animationSpeed or DEFAULT_ANIM_SPEED

	if not TrackCache.HasAnimationConfig(animationName) then
		warn("未找到动画配置:", animationName)
		return
	end

	local track = TrackCache.GetCachedTrack(animator, animationName)
	if track then
		track:AdjustSpeed(animationSpeed)
	end
end

--[[
	停止指定 Animator 的所有动画
	@param animator Animator - 动画器
]]
function AnimationModule.StopAll(animator: Animator)
	if not animator then
		warn("Animator不存在")
		return
	end

	FreezeAnim.ClearFreezeState(animator)

	local trackCache = TrackCache.GetAnimatorTrackCache(animator)
	if trackCache then
		for _, track: AnimationTrack in pairs(trackCache) do
			track:Stop()
		end
	end
end

--[[
	绑定动画结束回调
	@param animator Animator - 动画器
	@param animationName string - 动画名称
	@param endCallback (() -> ())? - 结束回调；nil 则清除已有绑定；仅非 Loop 轨触发一次
]]
function AnimationModule.BindEndFunc(animator: Animator, animationName: string, endCallback: (() -> ())?)
	if not animator then
		warn("Animator不存在")
		return
	end

	if not animator.Parent then
		return
	end

	TrackCache.BindEndFunc(animator, animationName, endCallback)
end

-- ========================================
-- 公共函数 — 查询与预加载
-- ========================================

--[[
	检查动画是否正在播放
	@param animator Animator - 动画器
	@param animationName string - 动画名称
	@return boolean - 是否正在播放
]]
function AnimationModule.IsAnimPlaying(animator: Animator, animationName: string): boolean
	if not animator then
		warn("Animator不存在")
		return false
	end

	if not TrackCache.HasAnimationConfig(animationName) then
		warn("未找到动画配置:", animationName)
		return false
	end

	local track = TrackCache.GetCachedTrack(animator, animationName)
	if track then
		return track.IsPlaying
	end

	return false
end

--[[
	检查是否有任意指定的动画正在播放
	@param animator Animator - 动画器
	@param animationNameTable {string} - 动画名称列表
	@return boolean - 是否有任意动画正在播放
]]
function AnimationModule.IsAnimsPlaying(animator: Animator, animationNameTable: {string}): boolean
	if not animator or type(animationNameTable) ~= "table" then
		return false
	end
	for _, animationName in ipairs(animationNameTable) do
		if AnimationModule.IsAnimPlaying(animator, animationName) then
			return true
		end
	end

	return false
end

--[[
	通过动画 ID 停止播放
	@param animator Animator - 动画器
	@param animationID number - 动画 ID
]]
function AnimationModule.StopAnimByID(animator: Animator, animationID: number)
	if not animator then
		warn("Animator不存在")
		return
	end

	local targetAnimationId = TrackCache.FormatAnimationAssetId(animationID)
	for _, track: AnimationTrack in pairs(animator:GetPlayingAnimationTracks()) do
		if track.Animation.AnimationId == targetAnimationId then
			track:Stop()
		end
	end
end

--[[
	获取动画 ID
	@param animationName string - 动画名称
	@return number? - 动画 ID
]]
function AnimationModule.GetAnimID(animationName: string): number?
	local animationID = TrackCache.GetConfiguredAnimID(animationName)
	if animationID then
		return animationID
	end

	warn("未找到动画:", animationName)
	return nil
end

--[[
	获取预加载动画 ID 列表
	@return {string} - 动画 ID 列表（rbxassetid 格式）
]]
function AnimationModule.GetPreloadTable(): {string}
	local preloadList = {}

	for _, animationData in pairs(AnimationTable) do
		if type(animationData) == "number" then
			table.insert(preloadList, TrackCache.RBX_ASSET_PREFIX .. animationData)
		end
	end

	return preloadList
end

-- ========================================
-- 公共函数 — 冻结模式
-- ========================================

--[[
	冻结指定动画：Speed 置 0，Heartbeat 按 updateInterval 推进 TimePosition
	@param animator Animator - 动画器
	@param animationName string - 动画名称（须已 Play 过）
	@param updateInterval number - 时间推进间隔（秒），须 > 0
]]
function AnimationModule.FreezeAnimationAtTime(animator: Animator, animationName: string, updateInterval: number)
	FreezeAnim.FreezeAnimationAtTime(animator, animationName, updateInterval)
end

--[[
	从冻结模式恢复指定动画播放
	@param animator Animator - 动画器
	@param animationName string - 动画名称
	@param animationSpeed number? - 恢复后的播放速度，默认 1
]]
function AnimationModule.ResumeAnimation(animator: Animator, animationName: string, animationSpeed: number?)
	FreezeAnim.ResumeAnimation(animator, animationName, animationSpeed)
end

--[[
	冻结 Animator 下所有正在播放的动画，并缓存原始 Speed
	@param animator Animator - 动画器
	@param updateInterval number - 时间推进间隔（秒），须 > 0
]]
function AnimationModule.FreezeAllAnimations(animator: Animator, updateInterval: number)
	FreezeAnim.FreezeAllAnimations(animator, updateInterval)
end

--[[
	恢复 Animator 下全部动画至 FreezeAll 前记录的 Speed
	@param animator Animator - 动画器
]]
function AnimationModule.ResumeAllAnimations(animator: Animator)
	FreezeAnim.ResumeAllAnimations(animator)
end

return AnimationModule
