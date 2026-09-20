--[[
	Module: SequenceManager（推荐别名 Utils.UISequence，同实例）
	Description: 客户端 UI 图片序列播放器（单控件切 Image / 图集 ImageRect）
	Author: 林奥宇
	Created: 2026-07-02
	Last Modified: 2026-09-01

	功能：
	- 从 Assets.Sequence（经 AssetPaths.GetCatalog）读取帧配置
	- 多图帧（StringValue）或图集（Folder Attribute + ImageRect；可选 Padding/Spacing）
	- 目标：ImageLabel 或 ImageButton
	- 控制：Play / Pause / Resume / PauseAll / ResumeAll / Stop / StopHandle / StopAll /
	  SetSpeed / Seek / SeekTime / SetLayerTransparency / GetLayerTransparency / GetDuration
	- 查询：IsPlaying / IsPaused / IsHandleActive / GetCurrentFrame / GetProgress /
	  GetFrameProgress / GetTimeProgress / GetFrameCount / GetSequenceDuration /
	  HasSequence / ValidateSequence / GetSequenceNames / GetActiveCount / GetDebugSnapshot /
	  ReloadCatalog / Shutdown
	- 时间：须 options.fps 或 options.secondsPerFrame（已移除 frameDuration / 位置参数签名）
	- 区间：startFrame / endFrame（含端点）
	- 播放模式 playMode：Forward（默认）/ Reverse / PingPong；可选 direction / onFrame / markers
	- 表现层 presentMode：Swap（默认）/ Crossfade / CloneAll；与 playMode 正交
	- Crossfade/CloneAll peer 经 PeerPool 租还；共享时钟 CollectTargetsInto 复用缓冲
	- 旧 API：PreLoad 已弃用（warn-once）；frameDuration 与位置参数签名已移除
	- PingPong + loop：loopInterval 在越过首帧（完成一轮往返）时生效；越过末帧仅掉头
	- 帧回调：callbackMode = Sync（默认，同帧执行）| Deferred（task.spawn）；均 pcall 隔离 + 世代校验
	- 共享 Heartbeat：全部在播实例共用一条连接；同 tick 最多推进 MAX_CATCHUP_CALLBACKS（默认 32）帧；Crossfade 限 1；单实例异常不影响其它
	- Destroy 或脱离 DataModel（非 game 后代）自动停播；换父瞬时 Parent=nil 不误停
	- Preload（同步）/ PreloadAsync（可取消：停暖场并抑制回调）/ PreloadMany / PreloadImages；ReloadCatalog（默认停在播）/ Shutdown
	- PlaySequence 成功第三返回值 PlaybackHandle（必有）；Sync 回调内停播且无后继 → false, ABORTED
	- Seek / SeekTime：PingPong 同步写入 direction（ResolveSeekPhase / DirectionForSeekFrame）
	- RunContractSelfTest：纯逻辑 + 轻量客户端集成（Stop nil / Sync-Stop ABORTED）
	- Sync 帧回调内 Stop/Play 同控件：时钟与装配均做世代校验，避免写已清理状态
	- Deferred onFrame/markers 执行前校验世代；Play 装配失败会 Restore 播前快照

	子模块：
	- Types — 常量与枚举（含 PlaybackState / SeekPhase）
	- PlayOptionsUtil — 播放选项解析
	- Catalog — 目录扫描与查询（多图帧序号须连续；rejectCode 区分 FRAME_GAP/INVALID_SHEET/EMPTY_SEQUENCE）
	- CatalogImages — 多图帧扫描（由 Catalog 调用）
	- PlaybackRegistry — 播放状态表与世代 id（封装，无公开 byLabel）
	- PlaybackLifecycle — 停播 / 共享时钟 / Seek 相位 / 生命周期
	- Playback — 播放装配 + 时钟推进
	- PlaybackControl — Stop / Pause / Seek / Speed 等控制
	- PlaybackQuery — 只读查询
	- PlaybackStep — Forward / PingPong 逻辑帧推进
	- PlaybackPresent — Swap / Crossfade / CloneAll 表现层
	- PlaybackVisual — 画面写入与帧回调
	- Preload — 预载与暖场
	- PeerPool — Crossfade/CloneAll 轻量控件对象池
	- Contract — 行为契约自检

	行为约定：
	- 仅客户端可用
	- Play 默认显示目标并切 Image/Rect；Stop 默认清空并隐藏（可配 stopPolicy）；StopSequence(nil) 与「未在播」均为无操作（不改控件外观）
	- CloneAll 仅多图帧；图集请用 Swap/Crossfade
	- 暖场请用 forceVisible=false（Preload warmup 已内置）；失败 / 取消不触发 onReady
	- 同一控件重播时保留首次播前的 Restore 快照（含 ImageRect / ImageTransparency / ImageColor3）
	- Crossfade 叠化用墙钟时间（不受 speed 影响）；Seek/SeekTime 会中断叠化并硬切
	- 变更类 API 返回 true，或 false, ErrorCode；PlaySequence 另返回 PlaybackHandle?
	- CloneAll 帧数上限 Types.MAX_CLONE_ALL_FRAMES（默认 64），超出 PRESENT_FAILED
	- IsPlaying：存在状态且未暂停（含循环间隔等待）；IsPaused：存在且已暂停
	- 空 ImageId 帧在扫描时跳过；帧序号不连续 → rejectCode=FRAME_GAP；Validate/Play 返回对应 ErrorCode
	- 逻辑帧 1..N 与目录连续帧名一一对应（可从非 1 起，但中间无空洞）
	- 卡顿追帧：非 Crossfade 同 tick 最多推进 MAX_CATCHUP_CALLBACKS（默认 32）帧并触发回调，画面只刷最终帧；超出保留到后续 tick
	- ReloadCatalog(stopActive?) 默认 stopActive=true（Keep 停播）；Shutdown 供会话清理

	------------------------------------------------------------------------
	调用方强制约定
	------------------------------------------------------------------------
	1. 必须接收 PlaySequence 的 ok, err, handle（成功时 handle 必有）
	2. ok == false 时打日志并走失败分支；勿假装在播（勿写「已开播」状态/属性）
	3. 主动停播优先 StopHandle(handle)；无 handle 时才退回 StopSequence(label)
	4. onFrame / onComplete / markers 等回调内停播必须用 StopHandle（防误停同控件新播）
	5. 长循环特效：业务关闭路径须显式 StopHandle；Destroy/出树由 Lifecycle 自动停作兜底，不可只靠兜底代替业务停播

		local ok, err, handle = SequenceManager:PlaySequence(label, name, options)
		if not ok or not handle then
			Log.warn("[Caller] PlaySequence failed:", err)
			return
		end
		-- 业务结束 / 回调内：
		SequenceManager:StopHandle(handle)

	------------------------------------------------------------------------
	rp18 迁移对照
	------------------------------------------------------------------------
	- PlaySequenceEx(...)           → PlaySequence(label, name, options)
	- options.mode                  → options.presentMode（含 CloneAll）
	- options.speedScale            → options.speed
	- options.pingPong = true       → options.playMode = PlayMode.PingPong
	- SetPlaybackSpeed              → SetSpeed
	- SetLayerTransparency          → 同名（现返回 true/false, ErrorCode）

	------------------------------------------------------------------------
	加载方式
	------------------------------------------------------------------------
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local SequenceManager = Utils.UISequence -- 或 Utils.SequenceManager

	------------------------------------------------------------------------
	配置约定 — 多图帧
	------------------------------------------------------------------------
	Assets/Sequence/{序列名}/ 下 StringValue，Name 为数字帧序号，Value 为 rbxassetid
	- 帧名须从最小序号起连续无空洞（如 1,2,3 或 2,3,4）；不连续则拒绝加载
	- 播放逻辑帧 1..N 与连续帧名一一对应（onFrame / markers / Seek 均用逻辑帧）

	------------------------------------------------------------------------
	配置约定 — 图集（Sprite Sheet）
	------------------------------------------------------------------------
	Assets/Sequence/{序列名}/ Folder Attribute：
	- SheetImage (string) 或子 StringValue「SheetImage」
	- CellWidth / CellHeight / Columns / FrameCount (number)
	- Rows (number，可选；须 >= ceil(FrameCount/Columns)，否则扫描失败不降级)
	- Padding / Spacing (number，可选，默认 0)
	播放时切换 ImageRectOffset/Size；也可在 PlayOptions.sheet 覆盖或临构：
		sheet = { imageId, cellWidth, cellHeight, columns, frameCount?, padding?, spacing?, rows? }

	------------------------------------------------------------------------
	时间参数（优先级：secondsPerFrame > fps）
	------------------------------------------------------------------------
	- secondsPerFrame：每帧秒数（推荐）
	- fps：帧率（推荐）
	- 迁移：旧 frameDuration=N → secondsPerFrame = 0.016 * N（约 60Hz 倍率）
	- 迁移：旧 PlaySequence(label, name, N, loop) → PlaySequence(label, name, { secondsPerFrame = 0.016*N, loop = loop })

	------------------------------------------------------------------------
	使用示例
	------------------------------------------------------------------------
	-- 推荐：持有 handle，回调内用 StopHandle 防误停新播
	local ok, err, handle = SequenceManager:PlaySequence(imageLabel, "彩虹框", {
		fps = 12,
		loop = true,
		playMode = SequenceManager.PlayMode.PingPong,
		presentMode = SequenceManager.PresentMode.CloneAll,
		stopPolicy = SequenceManager.StopPolicy.Restore,
		onFrame = function(frame) end,
		markers = { [3] = function() end },
	})
	if ok and handle then
		-- SequenceManager:StopHandle(handle)
	end

	-- 图集（目录已配 Attribute，或运行时覆盖）
	SequenceManager:PlaySequence(imageLabel, "爆炸图集", {
		fps = 24,
		sheet = {
			imageId = "rbxassetid://123",
			cellWidth = 128,
			cellHeight = 128,
			columns = 4,
			frameCount = 8,
		},
	})

	-- Crossfade（全屏加速线等柔和切帧）
	SequenceManager:PlaySequence(imageLabel, "加速线", {
		fps = 20,
		loop = true,
		playMode = SequenceManager.PlayMode.PingPong,
		presentMode = SequenceManager.PresentMode.Crossfade,
		crossfadeSec = 0.04,
		layerTransparency = 0.3,
	})
	SequenceManager:SetLayerTransparency(imageLabel, 0.7)

	SequenceManager:StopAll()
	print(SequenceManager:GetActiveCount())
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local Log = Utils.Log
local RunService = Utils.RunService

local Types = require(script.Types)
local Catalog = require(script.Catalog)
local Playback = require(script.Playback)
local PlaybackQuery = require(script.PlaybackQuery)
local PlaybackLifecycle = require(script.PlaybackLifecycle)
local PlayOptionsUtil = require(script.PlayOptionsUtil)
local PreloadMod = require(script.Preload)
local Contract = require(script.Contract)
local PeerPool = require(script.PeerPool)

local SequenceManager = {}

SequenceManager.StopPolicy = Types.StopPolicy
SequenceManager.PlayMode = Types.PlayMode
SequenceManager.PresentMode = Types.PresentMode
SequenceManager.SequenceKind = Types.SequenceKind
SequenceManager.CallbackMode = Types.CallbackMode
SequenceManager.ErrorCode = Types.ErrorCode

-- ============================================================================
-- 私有变量
-- ============================================================================
-- 兼容旧 API 命名（弃用：请改用 Preload；进程内 warn-once）
local _warnedPreLoadAlias = false

-- ============================================================================
-- 公共 API（冒号调用兼容；内部转接到子模块）
-- ============================================================================

--[[
	停止指定 ImageLabel 上的序列播放
	@param imageLabel ImageLabel? - 要停止的目标，nil 时无操作
	@param policy string? - 覆盖该次停止策略；默认用播放时 stopPolicy；未在播时不改外观
	@param handle Types.PlaybackHandle? - 可选；与当前世代不一致时返回 STALE_HANDLE
	@return boolean - true 已停止或目标本无播放；false 参数/环境无效
	@return string? - 失败时的 ErrorCode
]]
function SequenceManager:StopSequence(
	imageLabel: any,
	policy: string?,
	handle: Types.PlaybackHandle?
): (boolean, string?)
	return Playback.StopSequence(imageLabel, policy, handle)
end

--[[
	按 PlaybackHandle 停止（推荐在 onFrame/onComplete 内使用，防误停新播）
	@param handle Types.PlaybackHandle - PlaySequence 成功时的第三返回值
	@param policy string? - 覆盖停止策略
	@return boolean - true 成功或已无对应播放
	@return string? - 失败时的 ErrorCode
]]
function SequenceManager:StopHandle(handle: Types.PlaybackHandle, policy: string?): (boolean, string?)
	return Playback.StopHandle(handle, policy)
end

--[[
	停止全部在播序列
	@param policy string? - 统一覆盖停止策略；默认各自 stopPolicy
	@return number - 实际停止的数量
]]
function SequenceManager:StopAll(policy: string?): number
	return Playback.StopAll(policy)
end

--[[
	暂停播放（保持当前帧与连接）
	@param imageLabel ImageLabel - 目标
	@param handle Types.PlaybackHandle? - 可选世代校验
	@return boolean - true 成功；false 未在播放或环境无效
	@return string? - 失败时的 ErrorCode
]]
function SequenceManager:PauseSequence(imageLabel: any, handle: Types.PlaybackHandle?): (boolean, string?)
	return Playback.PauseSequence(imageLabel, handle)
end

--[[
	恢复已暂停的播放
	@param imageLabel ImageLabel - 目标
	@param handle Types.PlaybackHandle? - 可选世代校验
	@return boolean - true 成功；false 未在播放或环境无效
	@return string? - 失败时的 ErrorCode
]]
function SequenceManager:ResumeSequence(imageLabel: any, handle: Types.PlaybackHandle?): (boolean, string?)
	return Playback.ResumeSequence(imageLabel, handle)
end

--[[
	暂停全部在播实例（已暂停的跳过）
	@return number - 新置为暂停的数量
]]
function SequenceManager:PauseAll(): number
	return Playback.PauseAll()
end

--[[
	恢复全部已暂停实例（未暂停的跳过）
	@return number - 新恢复的数量
]]
function SequenceManager:ResumeAll(): number
	return Playback.ResumeAll()
end

--[[
	跳转到指定帧（1-based），重置帧内计时；不改变暂停状态
	@param imageLabel ImageLabel|ImageButton - 目标
	@param frame number - 目标帧（越界钳制到 startFrame..endFrame）
	@param handle Types.PlaybackHandle? - 可选世代校验
	@return boolean - true 成功；false 未在播放或参数无效
	@return string? - 失败时的 ErrorCode
]]
function SequenceManager:Seek(imageLabel: any, frame: number, handle: Types.PlaybackHandle?): (boolean, string?)
	return Playback.Seek(imageLabel, frame, handle)
end

--[[
	按时间跳转（秒，相对区间起点相位；保留帧内 elapsed）
	@param imageLabel ImageLabel|ImageButton - 目标
	@param timeSec number - 秒，须 >= 0
	@param handle Types.PlaybackHandle? - 可选世代校验
	@return boolean - true 成功
	@return string? - 失败时的 ErrorCode
]]
function SequenceManager:SeekTime(imageLabel: any, timeSec: number, handle: Types.PlaybackHandle?): (boolean, string?)
	return Playback.SeekTime(imageLabel, timeSec, handle)
end

--[[
	当前在播实例在 speed=1 下的区间总时长（秒；PingPong 按往返）
	@param imageLabel ImageLabel|ImageButton - 目标
	@return number? - 秒；未在播放时 nil
]]
function SequenceManager:GetDuration(imageLabel: any): number?
	return PlaybackQuery.GetDuration(imageLabel)
end

--[[
	设置播放速率（1 为原速，可在播放中动态修改）
	@param imageLabel ImageLabel - 目标
	@param speed number - 速率，须 > 0
	@param handle Types.PlaybackHandle? - 可选世代校验
	@return boolean - true 成功；false 参数无效或未在播放
	@return string? - 失败时的 ErrorCode
]]
function SequenceManager:SetSpeed(imageLabel: any, speed: number, handle: Types.PlaybackHandle?): (boolean, string?)
	return Playback.SetSpeed(imageLabel, speed, handle)
end

--[[
	设置层 ImageTransparency（0 不透明～1 全透明；叠化进行中由下一完成帧对齐）
	@param imageLabel ImageLabel - 目标
	@param transparency number - 透明度
	@param handle Types.PlaybackHandle? - 可选世代校验
	@return boolean - true 成功
	@return string? - 失败时的 ErrorCode
]]
function SequenceManager:SetLayerTransparency(
	imageLabel: any,
	transparency: number,
	handle: Types.PlaybackHandle?
): (boolean, string?)
	return Playback.SetLayerTransparency(imageLabel, transparency, handle)
end

--[[
	当前层透明度；未在播放时 nil
	@param imageLabel ImageLabel - 目标
	@return number? - [0, 1]
]]
function SequenceManager:GetLayerTransparency(imageLabel: any): number?
	return PlaybackQuery.GetLayerTransparency(imageLabel)
end

--[[
	是否正在播放（存在状态且未暂停；含循环间隔等待中）
	@param imageLabel ImageLabel - 目标
	@return boolean - true 正在播
]]
function SequenceManager:IsPlaying(imageLabel: any): boolean
	return PlaybackQuery.IsPlaying(imageLabel)
end

--[[
	是否已暂停（存在播放状态且 paused）
	@param imageLabel ImageLabel - 目标
	@return boolean - true 已暂停
]]
function SequenceManager:IsPaused(imageLabel: any): boolean
	return PlaybackQuery.IsPaused(imageLabel)
end

--[[
	handle 是否仍指向当前在播世代
	@param handle Types.PlaybackHandle - PlaySequence 返回的句柄
	@return boolean - true 仍有效
]]
function SequenceManager:IsHandleActive(handle: Types.PlaybackHandle): boolean
	return PlaybackQuery.IsHandleActive(handle)
end

--[[
	当前帧下标（1-based）；未在播放时 nil
	@param imageLabel ImageLabel - 目标
	@return number? - 当前帧
]]
function SequenceManager:GetCurrentFrame(imageLabel: any): number?
	return PlaybackQuery.GetCurrentFrame(imageLabel)
end

--[[
	播放进度 [0, 1]（按当前帧/总帧，兼容旧名）
	@param imageLabel ImageLabel - 目标
	@return number? - 帧进度
]]
function SequenceManager:GetProgress(imageLabel: any): number?
	return PlaybackQuery.GetProgress(imageLabel)
end

--[[
	按当前帧/总帧的进度 [0, 1]
	@param imageLabel ImageLabel - 目标
	@return number? - 帧进度
]]
function SequenceManager:GetFrameProgress(imageLabel: any): number?
	return PlaybackQuery.GetFrameProgress(imageLabel)
end

--[[
	按已播放时间估算动画相位进度 [0, 1]（不含 loopInterval；等待期间不累加 playedTime）
	@param imageLabel ImageLabel - 目标
	@return number? - 时间进度
]]
function SequenceManager:GetTimeProgress(imageLabel: any): number?
	return PlaybackQuery.GetTimeProgress(imageLabel)
end

--[[
	查询目录中序列的总帧数；不存在或未加载时 nil
	@param sequenceName string - 序列名称
	@return number? - 帧数
]]
function SequenceManager:GetFrameCount(sequenceName: string): number?
	return Catalog.GetFrameCount(sequenceName)
end

--[[
	按目录帧数与时间选项估算序列时长（speed=1；不启动播放）
	@param sequenceName string - 序列名称
	@param options PlayOptions? - fps/secondsPerFrame/playMode/startFrame/endFrame
	@return number? - 秒；序列不存在或时间参数无效时 nil
]]
function SequenceManager:GetSequenceDuration(sequenceName: string, options: Types.PlayOptions?): number?
	local data = Catalog.GetSequenceData(sequenceName)
	if not data or data.count <= 0 then
		return nil
	end

	local opts = options or {}
	local frameStep = PlayOptionsUtil.ResolveFrameStep(opts)
	if not frameStep then
		return nil
	end

	local rangeStart = 1
	if opts.startFrame then
		rangeStart = PlayOptionsUtil.ClampFrame(opts.startFrame, data.count)
	end
	local rangeEnd = data.count
	if opts.endFrame then
		rangeEnd = PlayOptionsUtil.ClampFrame(opts.endFrame, data.count)
	end
	if rangeEnd < rangeStart then
		rangeStart, rangeEnd = rangeEnd, rangeStart
	end

	local n = math.max(1, rangeEnd - rangeStart + 1)
	local playMode = PlayOptionsUtil.NormalizePlayMode(opts.playMode)
	local steps = if playMode == Types.PlayMode.PingPong then math.max(1, (n - 1) * 2) else n
	return steps * frameStep
end

--[[
	序列是否存在且可播放
	@param sequenceName string - 序列名称
	@return boolean - true 表示存在且帧数 > 0
]]
function SequenceManager:HasSequence(sequenceName: string): boolean
	return Catalog.HasSequence(sequenceName)
end

--[[
	校验序列是否可安全播放（图集几何 / 空帧等）
	@param sequenceName string - 序列名称
	@return boolean - true 无问题且可播放
	@return { Types.CatalogIssue } - 问题列表
]]
function SequenceManager:ValidateSequence(sequenceName: string): (boolean, { Types.CatalogIssue })
	return Catalog.ValidateSequence(sequenceName)
end

--[[
	目录中全部可播放序列名（浅拷贝）
	@return { string } - 名称列表
]]
function SequenceManager:GetSequenceNames(): { string }
	return Catalog.GetSequenceNames()
end

--[[
	当前活跃播放实例数（含暂停）
	@return number - 数量
]]
function SequenceManager:GetActiveCount(): number
	return PlaybackQuery.GetActiveCount()
end

--[[
	活跃播放诊断快照（排障用；返回新建表）
	@return { Types.DebugPlaybackEntry } - id / 序列名 / 帧 / presentMode 等
]]
function SequenceManager:GetDebugSnapshot(): { Types.DebugPlaybackEntry }
	return PlaybackQuery.GetDebugSnapshot()
end

--[[
	重新扫描 Sequence 目录（Studio 热更资源后调用）
	@param stopActive boolean? - 是否先停掉全部在播（默认 true，避免新旧帧表混用）；false 则在播继续持旧帧
	@return boolean - true 目录存在并已重载；false 未找到目录或非客户端
	@return string? - 失败时的 ErrorCode
	@return number - 因 stopActive 实际停止的实例数（未停则为 0）
]]
function SequenceManager:ReloadCatalog(stopActive: boolean?): (boolean, string?, number)
	if not RunService:IsClient() then
		Log.warn("[SequenceManager] 仅客户端可用")
		return false, Types.ErrorCode.NOT_CLIENT, 0
	end
	local stopped = 0
	if stopActive ~= false then
		stopped = Playback.StopAll(Types.StopPolicy.Keep)
	end
	local ok, err = Catalog.ReloadCatalog()
	if ok then
		PreloadMod.ClearImageCache()
		PeerPool.Clear()
	end
	return ok, err, stopped
end

--[[
	客户端会话清理：StopAll → 断时钟 → 清 PeerPool / 预载标记 / 临时 PreloadGui
	供 Manager 在换服、热重载或 PlayerRemoving 时调用
	@return number - 停止的在播实例数
]]
function SequenceManager:Shutdown(): number
	if not RunService:IsClient() then
		return 0
	end
	local stopped = Playback.StopAll(Types.StopPolicy.Keep)
	PlaybackLifecycle.DisconnectSharedClock()
	PreloadMod.ClearImageCache()
	PreloadMod.DestroyPreloadGui()
	PeerPool.Clear()
	return stopped
end

--[[
	通过 ContentProvider 预加载序列内图片资源（同步等待）
	@param sequenceName string - 序列名称
	@return boolean - true 预载成功或无需预载；false 失败
	@return string? - 失败时的 ErrorCode
]]
function SequenceManager:PreloadImages(sequenceName: string): (boolean, string?)
	return PreloadMod.PreloadImages(sequenceName)
end

--[[
	预加载序列资源（同步等待 ContentProvider）；可选播完即停的暖场
	@param sequenceName string - 序列名称
	@param options PreloadOptions? - warmup / fps / onReady / strictWarmup；失败不调 onReady
	@return boolean - true 预载成功；false 失败
	@return string? - 失败时的 ErrorCode
]]
function SequenceManager:Preload(sequenceName: string, options: Types.PreloadOptions?): (boolean, string?)
	return PreloadMod.Preload(sequenceName, options)
end

--[[
	异步预载（立即返回；完成后回调 onComplete）
	@param sequenceName string - 序列名称
	@param options PreloadOptions? - 同 Preload，另支持 onComplete(ok, err)
	@return boolean - true 已调度；false 参数/环境无效
	@return string? - 失败时的 ErrorCode
	@return (() -> ())? - 取消：抑制回调并 Stop 暖场（ContentProvider 无法中断）
]]
function SequenceManager:PreloadAsync(
	sequenceName: string,
	options: Types.PreloadOptions?
): (boolean, string?, (() -> ())?)
	return PreloadMod.PreloadAsync(sequenceName, options)
end

--[[
	批量同步预载多个序列的图片（不含暖场）
	@param sequenceNames { string } - 序列名列表
	@param options PreloadOptions? - onProgress(done, total, name)
	@return boolean - true 全部成功
	@return string? - 失败时的 ErrorCode
]]
function SequenceManager:PreloadMany(sequenceNames: { string }, options: Types.PreloadOptions?): (boolean, string?)
	return PreloadMod.PreloadMany(sequenceNames, options)
end

--[[
	在 ImageLabel / ImageButton 上播放图片序列（Swap / Crossfade / CloneAll）
	@param imageLabel ImageLabel|ImageButton - 播放目标（Crossfade 时兼作 bufferA）
	@param sequenceName string - 序列名称
	@param options Types.PlayOptions - 须含 fps 或 secondsPerFrame
	@return boolean - true 开始播放（必含 handle）；false 失败或 Sync 回调内 ABORTED
	@return string? - 失败时的 ErrorCode
	@return Types.PlaybackHandle? - 成功时非 nil（回调内停播请优先 StopHandle）
]]
function SequenceManager:PlaySequence(
	imageLabel: any,
	sequenceName: string,
	options: Types.PlayOptions
): (boolean, string?, Types.PlaybackHandle?)
	return Playback.PlaySequence(imageLabel, sequenceName, options)
end

--[[
	运行行为契约自检（Seek 相位 / 帧连续性 / 客户端 Stop nil 与 Sync-Stop ABORTED）
	会向 Output 打印 PASS/FAIL 摘要（命令栏直接调用即可看到）
	@return boolean - true 全部通过
	@return { string } - 失败说明列表（通过时为空表）
]]
function SequenceManager:RunContractSelfTest(): (boolean, { string })
	return Contract.RunSelfTest()
end

--[[
	兼容旧名：等价 Preload（进程内 warn-once 后转发；请改用 Preload）
	@param self any - 冒号或点号调用时的接收者（内容忽略）
	@param ... any - 原样转发给 Preload 的 sequenceName 与 options
	@return boolean - true 预载成功
	@return string? - 失败时的 ErrorCode
]]
function SequenceManager.PreLoad(self: any, ...: any): (boolean, string?)
	if not _warnedPreLoadAlias then
		_warnedPreLoadAlias = true
		Log.warn("[SequenceManager] PreLoad 已弃用并将移除，请改用 Preload")
	end
	return SequenceManager.Preload(self, ...)
end

return SequenceManager
