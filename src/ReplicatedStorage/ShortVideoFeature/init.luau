--[[
	Module: ShortVideoFeature
	Description: 短视频功能包对外 API（Open/Close/TrainPreview）；场景底板或 2D ScreenGui + 推荐 + 播放 + 评论
	Author: 林奥宇
	Created: 2026-08-13
	Last Modified: 2026-08-14

	用法:
		local ShortVideo = require(game.ReplicatedStorage.ShortVideoFeature)
		ShortVideo.Open({ exitOnDeath = true, boardAnchor = "character" })
		ShortVideo.Open({ displayMode = "screen", exitOnCameraDisturb = false })
		ShortVideo.Close("manual")
		ShortVideo.ShowTrainPreview({ boardCFrame = cf, onTriggered = function() end })
		ShortVideo.HideTrainPreview()

	TrainPreview：克隆 ModelRes「视频传送门」，Screen(Left) 播预览；Hide 带 Back-In 缩放。
	Open 时若预览已在播：TakeVideoFrame 交接主槽（免首条冷启），Close 后 Ensure 重建预览帧。
	播放器：主槽 + PreloadVideo1/2/3（语义 +1/+2/−1），命中换槽提升。
	切集：用户导航节流 SWITCH_THROTTLE_SEC（默认 0.2s）；进度条 Heartbeat 约 10Hz 轮询。
	UI 图资源：改 Shared/Constants.UI，或 Open({ ui = { Action = { ImageLike = id, ... } } })
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ContextActionService = game:GetService("ContextActionService")
local SocialService = game:GetService("SocialService")
local UserInputService = game:GetService("UserInputService")
local ContentProvider = game:GetService("ContentProvider")

local Remotes = require(script.Shared.Remotes)
local Constants = require(script.Shared.Constants)
local SceneBoard = require(script.Client.SceneBoard)
local CameraSession = require(script.Client.CameraSession)
local Recommend = require(script.Client.Recommend)
local SocialClient = require(script.Client.SocialClient)
local PlayerController = require(script.Client.PlayerController)
local CommentDrawer = require(script.Client.CommentDrawer)
local AvatarCache = require(script.Client.AvatarCache)
local ButtonFeedback = require(script.Client.ButtonFeedback)
local UiAssets = require(script.Client.UiAssets)
local UiPrefabUtil = require(script.Client.UiPrefabUtil)
local BuildUI = require(script.Client.BuildUI)
local GameAudioDuck = require(script.Client.GameAudioDuck)

local ShortVideoFeature = {}

local _opened = false
local _handles: any = nil
local _controller: any = nil
local _drawer: any = nil
local _listConn: RBXScriptConnection? = nil
local _uiConns: { RBXScriptConnection } = {}
local _exitConns: { RBXScriptConnection } = {}
local _followCamConn: RBXScriptConnection? = nil
local _spinConn: RBXScriptConnection? = nil
local _progressConn: RBXScriptConnection? = nil
local _list: { any } = {}
local _watched: { [string]: boolean } = {}
local _feed: { any } = {}
local _onClosed: ((string?) -> ())? = nil
local _options = {
	exitOnDeath = true,
	exitOnCharacterRemove = true,
	exitOnCameraDisturb = true,
	lockCharacter = true,
	boardAnchor = "camera",
	followBoard = false,
	displayMode = "scene", -- "scene" | "screen"
}
local _locks: { [string]: boolean } = {}
local _uiCfg = Constants.UI
local TrainPreviewBoard = SceneBoard.TrainPreview
-- 刷新世代：切集 meta / 视频赞 互不覆盖错条
local _metaGen = 0
local _videoLikeState: { [string]: { liked: boolean, count: number } } = {}
-- 单飞同步：连点只改本地目标态，请求链追到与本地一致
local _videoLikeInflight: { [string]: boolean } = {}

local LOCK_ACTION = "ShortVideoLockMove"
local NAV_PREV_ACTION = "ShortVideoNavPrev"
local NAV_NEXT_ACTION = "ShortVideoNavNext"
local _mainUIHiddenByUs = false
-- 用户切集节流：上次成功受理切集的 os.clock
local _lastNavAt = 0

--[[
	浅合并 UI 配置表
	@param base table - 默认
	@param override table? - Open.ui 覆盖
	@return table
]]
local function mergeUiConfig(base: any, override: any?): any
	if typeof(override) ~= "table" then
		return base
	end
	local out = {}
	for k, v in pairs(base) do
		if typeof(v) == "table" and typeof(override[k]) == "table" then
			local child = table.clone(v)
			for ck, cv in pairs(override[k]) do
				child[ck] = cv
			end
			out[k] = child
		else
			out[k] = if override[k] ~= nil then override[k] else v
		end
	end
	for k, v in pairs(override) do
		if out[k] == nil then
			out[k] = v
		end
	end
	return out
end

--[[
	隐藏/恢复本游戏主界面（软依赖 UIMgr，迁移无 Utils 时跳过）
	@param visible boolean - 是否显示主界面
]]
local function setMainUIVisible(visible: boolean)
	local ok, Utils = pcall(function()
		return require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
	end)
	if not ok or not Utils then
		return
	end
	local UIMgr = Utils.UIMgr
	if not UIMgr or type(UIMgr.SetMainUIVisible) ~= "function" then
		return
	end
	UIMgr.SetMainUIVisible(visible)
end

--[[
	锁定/解锁角色移动
	@param enabled boolean - 是否锁定
]]
local function setCharacterLocked(enabled: boolean)
	local player = Players.LocalPlayer
	if not player then
		return
	end
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if enabled then
		ContextActionService:BindAction(LOCK_ACTION, function()
			return Enum.ContextActionResult.Sink
		end, false, Enum.PlayerActions.CharacterForward, Enum.PlayerActions.CharacterBackward, Enum.PlayerActions.CharacterLeft, Enum.PlayerActions.CharacterRight, Enum.PlayerActions.CharacterJump)
		if hum then
			_locks.walk = hum.WalkSpeed
			_locks.jump = hum.JumpPower
			hum.WalkSpeed = 0
			pcall(function()
				hum.JumpPower = 0
			end)
			pcall(function()
				hum.JumpHeight = 0
			end)
		end
	else
		pcall(function()
			ContextActionService:UnbindAction(LOCK_ACTION)
		end)
		if hum and _locks.walk then
			hum.WalkSpeed = _locks.walk
			pcall(function()
				hum.JumpPower = _locks.jump or 50
			end)
		end
		table.clear(_locks)
	end
end

--[[
	格式化赞/评数量（视觉稿 49.8k 风格）
	@param n number - 原始计数
	@return string - 展示文案
]]
local function formatCount(n: number): string
	local v = math.max(0, math.floor(tonumber(n) or 0))
	if v >= 1000 then
		local k = v / 1000
		if k >= 100 then
			return string.format("%dk", math.floor(k + 0.5))
		end
		local s = string.format("%.1fk", k)
		-- 去掉 .0k
		s = string.gsub(s, "%.0k$", "k")
		return s
	end
	return tostring(v)
end

--[[
	上报当前条 W3 进度
	@param ended boolean - 是否播完
]]
local function reportCurrent(ended: boolean)
	if not _controller then
		return
	end
	local item = _controller:getCurrent()
	if not item then
		return
	end
	local played = _controller:getPlayedSec()
	SocialClient.ReportWatchProgress(item.id, played, nil, ended)
	local pass = ended or played >= Constants.WATCH_FALLBACK_SEC
	if pass then
		_watched[item.id] = true
	end
end

--[[
	应用点赞按钮视觉
	@param likeBtn GuiButton - 赞按钮
	@param liked boolean - 是否已赞
]]
local function applyLikeVisual(likeBtn: GuiButton, liked: boolean)
	local action = _uiCfg.Action
	UiAssets.ApplyLikeState(
		likeBtn,
		liked,
		action.ImageLike,
		action.ImageLiked,
		action.FallbackLike,
		action.FallbackLiked
	)
end

--[[
	写入 ActionRail 视频赞 UI（须已确认当前条）
	@param root Frame - Root
	@param liked boolean - 是否已赞
	@param likeCount number - 赞数
	@param playPop boolean? - 是否播放点赞弹跳（乐观切图时传 true）
]]
local function applyVideoLikeUi(root: Frame, liked: boolean, likeCount: number, playPop: boolean?)
	local likeCountLabel = UiPrefabUtil.FindActionCount(root.ActionRail, "LikeBtn", "LikeCount")
	local likeBtn = root.ActionRail.LikeBtn :: GuiButton
	if likeCountLabel then
		likeCountLabel.Text = formatCount(likeCount)
	end
	applyLikeVisual(likeBtn, liked)
	if playPop then
		ButtonFeedback.PlayLikePop(likeBtn)
	end
end

--[[
	当前条是否仍是指定视频
	@param videoId string - 业务 id
	@return boolean
]]
local function isCurrentVideo(videoId: string): boolean
	if not _opened or not _controller then
		return false
	end
	local cur = _controller:getCurrent()
	return cur ~= nil and cur.id == videoId
end

--[[
	确保本地有可翻转的赞态（GetVideoState 未回前也可立刻反馈）
	@param videoId string - 业务 id
	@return { liked: boolean, count: number }
]]
local function ensureVideoLikeState(videoId: string): { liked: boolean, count: number }
	local state = _videoLikeState[videoId]
	if state then
		return state
	end
	state = { liked = false, count = 0 }
	_videoLikeState[videoId] = state
	return state
end

--[[
	单飞把服务端赞态追到与本地 _videoLikeState 一致（Toggle 语义下避免并发竞态）
	@param root Frame - Root
	@param videoId string - 业务 id
]]
local function syncVideoLikeToServer(root: Frame, videoId: string)
	if _videoLikeInflight[videoId] then
		return
	end
	_videoLikeInflight[videoId] = true
	task.spawn(function()
		while _opened do
			local desire = _videoLikeState[videoId]
			if not desire then
				break
			end
			-- 发出前快照：用于失败回滚；冷却等待中允许用户继续改目标态
			local issuedLiked = desire.liked
			while SocialClient.IsVideoLikeCooling() do
				task.wait(0.05)
				if not _opened or _videoLikeState[videoId] == nil then
					_videoLikeInflight[videoId] = nil
					return
				end
				desire = _videoLikeState[videoId]
				if not desire then
					_videoLikeInflight[videoId] = nil
					return
				end
				issuedLiked = desire.liked
			end

			local res = SocialClient.ToggleVideoLike(videoId)
			if not isCurrentVideo(videoId) then
				break
			end
			local current = _videoLikeState[videoId]
			if not current then
				break
			end

			if not res or not res.ok then
				-- Toggle 未生效：若用户未再改目标，回滚这一拍
				if current.liked == issuedLiked then
					local prevCount = math.max(0, current.count + (if issuedLiked then -1 else 1))
					_videoLikeState[videoId] = { liked = not issuedLiked, count = prevCount }
					applyVideoLikeUi(root, not issuedLiked, prevCount)
				end
				break
			end

			local serverLiked = res.liked == true
			local serverCount = math.max(0, tonumber(res.likeCount) or current.count)
			if current.liked == serverLiked then
				_videoLikeState[videoId] = { liked = serverLiked, count = serverCount }
				applyVideoLikeUi(root, serverLiked, serverCount)
				break
			end
			-- 本地目标已变：以服务端计数为基准修正展示，再 Toggle 追赶
			local chaseCount = math.max(0, serverCount + (if current.liked then 1 else -1))
			_videoLikeState[videoId] = { liked = current.liked, count = chaseCount }
			applyVideoLikeUi(root, current.liked, chaseCount)
		end
		_videoLikeInflight[videoId] = nil
	end)
end

--[[
	刷新赞评数 UI（带 metaGen；赞进行中不覆盖该视频赞态）
	@param root Frame - Root
	@param item any - 当前视频
]]
local function refreshMeta(root: Frame, item: any)
	local title = root.TopBar.TitleLabel :: TextLabel
	title.Text = item.title or ""
	_metaGen += 1
	local gen = _metaGen
	local videoId = item.id
	-- 先占位，避免 GetVideoState 未回时点击无反馈
	ensureVideoLikeState(videoId)
	task.spawn(function()
		local res = SocialClient.GetVideoState(videoId)
		if gen ~= _metaGen then
			return
		end
		if not isCurrentVideo(videoId) then
			return
		end
		if res and res.ok then
			local cmtCount = UiPrefabUtil.FindActionCount(root.ActionRail, "CommentBtn", "CommentCount")
			if cmtCount then
				cmtCount.Text = formatCount(res.commentCount or 0)
			end
			-- 本视频赞请求进行中：只更新评论数，避免盖掉乐观赞
			if not _videoLikeInflight[videoId] then
				local liked = res.liked == true
				local likeCount = math.max(0, tonumber(res.likeCount) or 0)
				_videoLikeState[videoId] = { liked = liked, count = likeCount }
				applyVideoLikeUi(root, liked, likeCount)
			end
			if _drawer then
				_drawer:setTotalCount(res.commentCount or 0)
			end
		end
	end)
	if _drawer then
		_drawer:setVideo(item.id)
	end
end

--[[
	显示/隐藏 Loading，并驱动转圈
	@param root Frame - Root
	@param loading boolean - 是否加载中
]]
local function setLoadingVisible(root: Frame, loading: boolean)
	local overlay = root:FindFirstChild("LoadingOverlay") :: Frame?
	if not overlay then
		return
	end
	overlay.Visible = loading
	if _spinConn then
		_spinConn:Disconnect()
		_spinConn = nil
	end
	if not loading then
		return
	end
	local spinner = overlay:FindFirstChild("Spinner") :: GuiObject?
	if not spinner then
		return
	end
	local speed = (_uiCfg.Loading and _uiCfg.Loading.SpinDegPerSec) or 270
	_spinConn = RunService.RenderStepped:Connect(function(dt)
		if not overlay.Parent or not overlay.Visible then
			return
		end
		spinner.Rotation = (spinner.Rotation + speed * dt) % 360
	end)
end

--[[
	弹出 Roblox 官方邀请好友
]]
local function promptShareInvite()
	local player = Players.LocalPlayer
	if not player then
		return
	end
	local options = Instance.new("ExperienceInviteOptions")
	options.PromptMessage = "Invite Friend"
	options.LaunchData = tostring(player.UserId)
	local ok, err = pcall(SocialService.PromptGameInvite, SocialService, player, options)
	if not ok then
		warn("[ShortVideoFeature] PromptGameInvite failed:", err)
	end
end

--[[
	确保 Root 下存在命名预载 VideoFrame
	@param root Frame - UI Root
	@param name string - 实例名
	@return VideoFrame
]]
local function ensurePreloadVideo(root: Frame, name: string): VideoFrame
	local existing = root:FindFirstChild(name)
	if existing and existing:IsA("VideoFrame") then
		return existing
	end
	local frame = Instance.new("VideoFrame")
	frame.Name = name
	frame.Size = UDim2.fromOffset(1, 1)
	frame.Position = UDim2.fromOffset(-100, -100)
	frame.Visible = false
	frame.Looped = true
	frame.Volume = 0
	frame.Parent = root
	return frame
end

--[[
	将训练预览 VideoFrame 交接为主槽（复用已解码帧，避免进场冷启）
	@param root Frame - UI Root
	@param mainVideo VideoFrame - 原主槽
	@return (VideoFrame, any?) - 主槽, 交接的 VideoItem
]]
local function tryHandoffPreviewMain(root: Frame, mainVideo: VideoFrame): (VideoFrame, any?)
	if not TrainPreviewBoard.IsShowing() then
		return mainVideo, nil
	end
	local item = TrainPreviewBoard.GetFirstItem()
	if typeof(item) ~= "table" or item.videoId == nil or item.id == nil then
		return mainVideo, nil
	end
	local taken = TrainPreviewBoard.TakeVideoFrameForHandoff()
	if not taken or not taken:IsA("VideoFrame") then
		return mainVideo, item
	end
	local container = mainVideo.Parent
	if not container then
		-- 无法挂载则交还语义：销毁 taken 会丢缓冲，改为仍用原主槽 + warm
		taken:Destroy()
		return mainVideo, item
	end
	taken.Name = "MainVideo"
	taken.Visible = true
	taken.ZIndex = 1
	taken.AnchorPoint = Vector2.new(0.5, 0.5)
	taken.Position = UDim2.fromScale(0.5, 0.5)
	taken.Size = UDim2.fromScale(1, 1)
	taken.Active = false
	taken.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	taken.BackgroundTransparency = 0
	-- 去掉传送门预览装饰（圆角/半透渐变），避免正式 UI 画面异常
	for _, child in ipairs(taken:GetChildren()) do
		if child:IsA("UICorner") or child:IsA("UIGradient") then
			child:Destroy()
		end
	end
	pcall(function()
		taken.Volume = 1
		taken.Looped = true
	end)
	taken:SetAttribute("VideoBizId", item.id)
	taken.Parent = container
	mainVideo:Destroy()
	return taken, item
end

--[[
	异步预热片源（与 VideoFrame 预载互补）
	@param videoId number - 资产 Id
]]
local function preloadAssetAsync(videoId: number)
	if typeof(videoId) ~= "number" then
		return
	end
	task.spawn(function()
		pcall(function()
			ContentProvider:PreloadAsync({ "rbxassetid://" .. tostring(videoId) })
		end)
	end)
end

--[[
	应用片单与 watched，重建 Feed（预览小屏首条优先置顶；中途刷新尽量保当前条）
]]
local function applyListPayload(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	_list = payload.list or {}
	if typeof(payload.watched) == "table" then
		_watched = payload.watched
	end
	local preferId = nil
	local previewFirst = TrainPreviewBoard.GetFirstItem()
	if previewFirst and typeof(previewFirst.id) == "string" then
		preferId = previewFirst.id
	end
	local keepId = nil
	if _opened and _controller then
		local cur = _controller:getCurrent()
		if cur and typeof(cur.id) == "string" then
			keepId = cur.id
		end
	end
	_feed = Recommend.BuildFeedPreferFirst(_list, _watched, preferId)
	if _controller then
		_controller:setFeed(_feed, keepId or preferId)
		-- 片单到达后预热当前及前方两条资产
		local idx = _controller:getIndex()
		local n = #_feed
		if n > 0 then
			for _, offset in ipairs({ 0, 1, 2 }) do
				local item = _feed[((idx - 1 + offset) % n) + 1]
				if item and item.videoId then
					preloadAssetAsync(item.videoId)
				end
			end
		end
	end
end

--[[
	用户切集是否已过节流间隔
	@return boolean - true 表示允许本次切集并已记账
]]
local function beginUserNav(): boolean
	local gap = tonumber(Constants.SWITCH_THROTTLE_SEC) or 0.2
	local now = os.clock()
	if now - _lastNavAt < gap then
		return false
	end
	_lastNavAt = now
	return true
end

--[[
	切到下一条（含整轮已看后重建推荐；避免 next + setFeed 双切）
]]
local function goNextVideo()
	if not _controller then
		return
	end
	if not beginUserNav() then
		return
	end
	reportCurrent(false)
	local before = _controller:getIndex()
	if before == #_feed and #_list > 0 then
		local allWatched = true
		for _, item in ipairs(_list) do
			if not _watched[item.id] then
				allWatched = false
				break
			end
		end
		if allWatched then
			_feed = Recommend.RebuildAfterRound(_list)
			-- false：强制新一轮第 1 条，只切一次
			_controller:setFeed(_feed, false)
			return
		end
	end
	_controller:next()
end

--[[
	绑定退出监听
]]
local function bindExitWatchers()
	for _, c in ipairs(_exitConns) do
		c:Disconnect()
	end
	table.clear(_exitConns)

	local player = Players.LocalPlayer
	if not player then
		return
	end

	local function hookCharacter(char: Model)
		local hum = char:FindFirstChildOfClass("Humanoid") or char:WaitForChild("Humanoid", 5)
		if hum and _options.exitOnDeath then
			table.insert(_exitConns, hum.Died:Connect(function()
				ShortVideoFeature.Close("death")
			end))
		end
	end

	if _options.exitOnCharacterRemove then
		table.insert(_exitConns, player.CharacterRemoving:Connect(function()
			ShortVideoFeature.Close("character_remove")
		end))
	end
	if player.Character then
		hookCharacter(player.Character)
	end
	table.insert(_exitConns, player.CharacterAdded:Connect(function(char)
		if _options.exitOnCharacterRemove and _opened then
			ShortVideoFeature.Close("character_added")
			return
		end
		hookCharacter(char)
	end))

	if _options.exitOnCameraDisturb and _handles and _handles.part then
		CameraSession.StartDisturbWatch(function()
			ShortVideoFeature.Close("camera_disturb")
		end)
	end
end

--[[
	驱动底部进度条（TimePosition 无 Changed，按 PROGRESS_POLL_INTERVAL_SEC 轮询）
	@param root Frame - Content Root
	@param mainVideo VideoFrame - 主槽
]]
local function bindProgressBar(root: Frame, mainVideo: VideoFrame)
	if _progressConn then
		_progressConn:Disconnect()
		_progressConn = nil
	end
	local bar = root:FindFirstChild("ProgressBar")
	if not bar or not bar:IsA("Frame") then
		return
	end
	local fill = bar:FindFirstChild("Fill")
	if not fill or not fill:IsA("Frame") then
		return
	end
	local interval = tonumber(Constants.PROGRESS_POLL_INTERVAL_SEC) or 0.1
	local acc = interval -- 首帧立刻刷一次
	_progressConn = RunService.Heartbeat:Connect(function(dt)
		if not _opened then
			return
		end
		acc += dt
		if acc < interval then
			return
		end
		acc = 0
		local frame = if _controller then _controller:getMainFrame() else mainVideo
		local len = 0
		local pos = 0
		pcall(function()
			len = (frame :: any).TimeLength or 0
			pos = frame.TimePosition or 0
		end)
		local alpha = if len > 0 then math.clamp(pos / len, 0, 1) else 0
		fill.Size = UDim2.new(alpha, 0, 1, 0)
	end)
end

--[[
	切到上一条
]]
local function goPrevVideo()
	if not _controller then
		return
	end
	if not beginUserNav() then
		return
	end
	reportCurrent(false)
	_controller:prev()
end

--[[
	收集需点击反馈的按钮
	@param root Frame - Root
	@return {GuiButton}
]]
local function collectFeedbackButtons(root: Frame): { GuiButton }
	local list: { GuiButton } = {}
	local function add(btn: Instance?)
		if btn and btn:IsA("GuiButton") then
			table.insert(list, btn)
		end
	end
	add(root.TopBar:FindFirstChild("CloseBtn"))
	add(root.ActionRail:FindFirstChild("LikeBtn"))
	add(root.ActionRail:FindFirstChild("CommentBtn"))
	add(root.ActionRail:FindFirstChild("ShareBtn"))
	if _handles then
		add(_handles.prevBtn)
		add(_handles.nextBtn)
	end
	return list
end

--[[
	绑定 UI 按钮
	@param root Frame - Root
]]
local function bindUi(root: Frame)
	for _, c in ipairs(_uiConns) do
		c:Disconnect()
	end
	table.clear(_uiConns)

	for _, c in ipairs(ButtonFeedback.BindMany(collectFeedbackButtons(root))) do
		table.insert(_uiConns, c)
	end

	table.insert(_uiConns, root.TopBar.CloseBtn.MouseButton1Click:Connect(function()
		ShortVideoFeature.Close("close_btn")
	end))

	local nextBtn = _handles and _handles.nextBtn
	local prevBtn = _handles and _handles.prevBtn
	if nextBtn then
		table.insert(_uiConns, nextBtn.MouseButton1Click:Connect(function()
			goNextVideo()
		end))
	end
	if prevBtn then
		table.insert(_uiConns, prevBtn.MouseButton1Click:Connect(function()
			goPrevVideo()
		end))
	end

	-- 键盘 Q/E + 手柄肩键切集（键位字由 BuildUI 按设备适配）
	pcall(function()
		ContextActionService:UnbindAction(NAV_PREV_ACTION)
	end)
	pcall(function()
		ContextActionService:UnbindAction(NAV_NEXT_ACTION)
	end)
	ContextActionService:BindAction(NAV_PREV_ACTION, function(_, inputState)
		if inputState == Enum.UserInputState.Begin and _opened then
			goPrevVideo()
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.Q, Enum.KeyCode.ButtonL1)
	ContextActionService:BindAction(NAV_NEXT_ACTION, function(_, inputState)
		if inputState == Enum.UserInputState.Begin and _opened then
			goNextVideo()
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.E, Enum.KeyCode.ButtonR1)

	-- PreferredInput 在 Studio 手机模拟器下会随点击在 Touch/键鼠间抖动；
	-- BuildUI 对移动端做会话锁存，刷新时不会把已隐藏的 Q/E 又拉回来。
	local function refreshNavKeyHints()
		if not _opened or not _handles then
			return
		end
		BuildUI.RefreshNavKeyLabels(_handles.prevBtn, _handles.nextBtn, _uiCfg)
	end
	refreshNavKeyHints()
	table.insert(_uiConns, UserInputService:GetPropertyChangedSignal("GamepadEnabled"):Connect(refreshNavKeyHints))
	table.insert(_uiConns, UserInputService:GetPropertyChangedSignal("PreferredInput"):Connect(refreshNavKeyHints))
	table.insert(_uiConns, UserInputService.GamepadConnected:Connect(refreshNavKeyHints))
	table.insert(_uiConns, UserInputService.GamepadDisconnected:Connect(refreshNavKeyHints))

	table.insert(_uiConns, root.ActionRail.LikeBtn.MouseButton1Click:Connect(function()
		local item = _controller and _controller:getCurrent()
		if not item then
			return
		end
		local videoId = item.id
		local likeBtn = root.ActionRail.LikeBtn :: GuiButton
		-- 无在途同步且仍在冷却：只播轻反馈，避免先翻后回滚
		if not _videoLikeInflight[videoId] and SocialClient.IsVideoLikeCooling() then
			ButtonFeedback.PlayLikePop(likeBtn)
			return
		end
		local state = ensureVideoLikeState(videoId)
		local nextLiked = not state.liked
		local nextCount = math.max(0, state.count + (if nextLiked then 1 else -1))
		_videoLikeState[videoId] = { liked = nextLiked, count = nextCount }
		applyVideoLikeUi(root, nextLiked, nextCount, true)
		syncVideoLikeToServer(root, videoId)
	end))
	table.insert(_uiConns, root.ActionRail.CommentBtn.MouseButton1Click:Connect(function()
		if _drawer then
			_drawer:toggle()
		end
	end))
	local shareBtn = root.ActionRail:FindFirstChild("ShareBtn")
	if shareBtn and shareBtn:IsA("GuiButton") then
		table.insert(_uiConns, shareBtn.MouseButton1Click:Connect(function()
			promptShareInvite()
		end))
	end

	-- 点击视频区：暂停 / 继续 + 居中暂停图标
	local tapLayer, pauseIcon = BuildUI.EnsurePauseControls(root, _uiCfg)
	if tapLayer and pauseIcon then
		table.insert(_uiConns, tapLayer.MouseButton1Click:Connect(function()
			if not _opened or not _controller then
				return
			end
			-- 评论抽屉打开时不抢点击（由抽屉处理）
			if _drawer and _drawer:isOpen() then
				return
			end
			local paused = _controller:togglePause()
			pauseIcon.Visible = paused
		end))
	end
end

--[[
	打开短视频会话
	@param options table? - OpenOptions（含 displayMode / boardAnchor / followBoard / ui）
]]
function ShortVideoFeature.Open(options: any?)
	if _opened then
		return
	end
	_lastNavAt = 0
	_options.exitOnDeath = true
	_options.exitOnCharacterRemove = true
	_options.exitOnCameraDisturb = true
	_options.lockCharacter = true
	_options.boardAnchor = "camera"
	_options.followBoard = false
	_options.displayMode = "scene"
	_onClosed = nil
	_uiCfg = Constants.UI

	if typeof(options) == "table" then
		for k, v in pairs(options) do
			if k == "onClosed" and typeof(v) == "function" then
				_onClosed = v
			elseif k == "ui" and typeof(v) == "table" then
				_uiCfg = mergeUiConfig(Constants.UI, v)
			elseif _options[k] ~= nil then
				_options[k] = v
			end
		end
	end

	local folder = Remotes.Wait()
	SocialClient.Bind(folder)

	local isScreen = _options.displayMode == "screen"
	if isScreen then
		_handles = SceneBoard.CreateScreen({
			ui = _uiCfg,
		})
	else
		_handles = SceneBoard.Create({
			boardAnchor = _options.boardAnchor,
			follow = _options.followBoard,
			ui = _uiCfg,
		})
	end
	if not _handles then
		warn("[ShortVideoFeature] SceneBoard create failed")
		return
	end

	if not isScreen and _handles.part then
		CameraSession.Acquire(_handles.part)
		if _options.followBoard then
			local acc = 0
			_followCamConn = RunService.Heartbeat:Connect(function(dt)
				acc += dt
				if acc < 0.1 then
					return
				end
				acc = 0
				if _handles and _handles.part and _handles.part.Parent then
					CameraSession.Relock(_handles.part)
				end
			end)
		end
	end

	if _options.lockCharacter then
		setCharacterLocked(true)
	end

	local root = _handles.root
	local mainVideo = root:FindFirstChild("MainVideo", true) :: VideoFrame
	local warmItem: any = nil
	mainVideo, warmItem = tryHandoffPreviewMain(root, mainVideo)

	local preload1 = ensurePreloadVideo(root, "PreloadVideo1")
	local preload2 = ensurePreloadVideo(root, "PreloadVideo2")
	local preload3 = ensurePreloadVideo(root, "PreloadVideo3")

	_controller = PlayerController.new(mainVideo, preload1, preload2, preload3)
	_controller.onIndexChanged = function(item)
		local pauseIcon = root:FindFirstChild("PauseIcon", true)
		if pauseIcon and pauseIcon:IsA("GuiObject") then
			pauseIcon.Visible = false
		end
		refreshMeta(root, item)
	end
	_controller.onLoadingChanged = function(loading)
		if _opened then
			setLoadingVisible(root, loading)
		end
	end

	-- 列表到达前先灌主槽：交接帧免重载；否则同 id 提前解码
	if warmItem then
		_controller:warmStart(warmItem)
		preloadAssetAsync(warmItem.videoId)
	elseif TrainPreviewBoard.IsShowing() then
		local previewFirst = TrainPreviewBoard.GetFirstItem()
		if previewFirst then
			_controller:warmStart(previewFirst)
			preloadAssetAsync(previewFirst.videoId)
		end
	end

	_drawer = CommentDrawer.new(root)
	_drawer:setOnTotalCountChanged(function(count: number)
		if not _opened or not _handles then
			return
		end
		local rail = _handles.root and _handles.root:FindFirstChild("ActionRail")
		if not rail then
			return
		end
		local cmtCount = UiPrefabUtil.FindActionCount(rail, "CommentBtn", "CommentCount")
		if cmtCount then
			cmtCount.Text = formatCount(count)
		end
	end)
	bindUi(root)
	bindProgressBar(root, mainVideo)

	_listConn = SocialClient.OnListUpdated(function(payload)
		applyListPayload(payload)
	end)

	_opened = true
	bindExitWatchers()
	setMainUIVisible(false)
	_mainUIHiddenByUs = true
	if isScreen then
		GameAudioDuck.Duck()
	end
	if TrainPreviewBoard.IsShowing() then
		TrainPreviewBoard.SetPlaying(false)
		TrainPreviewBoard.SetPromptEnabled(false)
	end
	SocialClient.RequestList()
end

--[[
	关闭会话并回收资源
	@param reason string? - 原因
]]
function ShortVideoFeature.Close(reason: string?)
	if not _opened then
		return
	end
	_opened = false
	_metaGen += 1
	table.clear(_videoLikeState)
	table.clear(_videoLikeInflight)
	reportCurrent(false)
	GameAudioDuck.Restore()

	if _listConn then
		_listConn:Disconnect()
		_listConn = nil
	end
	for _, c in ipairs(_uiConns) do
		c:Disconnect()
	end
	table.clear(_uiConns)
	for _, c in ipairs(_exitConns) do
		c:Disconnect()
	end
	table.clear(_exitConns)
	if _followCamConn then
		_followCamConn:Disconnect()
		_followCamConn = nil
	end
	if _spinConn then
		_spinConn:Disconnect()
		_spinConn = nil
	end
	if _progressConn then
		_progressConn:Disconnect()
		_progressConn = nil
	end
	pcall(function()
		ContextActionService:UnbindAction(NAV_PREV_ACTION)
	end)
	pcall(function()
		ContextActionService:UnbindAction(NAV_NEXT_ACTION)
	end)
	CameraSession.StopDisturbWatch()

	if _drawer then
		_drawer:destroy()
		_drawer = nil
	end
	if _controller then
		_controller:destroy()
		_controller = nil
	end

	SceneBoard.Destroy(_handles)
	_handles = nil
	CameraSession.Restore()
	setCharacterLocked(false)
	if _mainUIHiddenByUs then
		setMainUIVisible(true)
		_mainUIHiddenByUs = false
	end
	AvatarCache.Clear()
	_feed = {}

	if TrainPreviewBoard.IsShowing() and reason ~= "auto_train_end" then
		TrainPreviewBoard.SetPlaying(true)
		TrainPreviewBoard.SetPromptEnabled(true)
	end

	local cb = _onClosed
	_onClosed = nil
	if cb then
		task.defer(cb, reason)
	end
	if RunService:IsStudio() then
		print("[ShortVideoFeature] closed:", reason or "unknown")
	end
end

--[[
	是否打开中
	@return boolean
]]
function ShortVideoFeature.IsOpen(): boolean
	return _opened
end

--[[
	显示训练场预览传送门（单例）
	@param options { boardCFrame: CFrame, onTriggered: (() -> ())?, cfg: any? }
]]
function ShortVideoFeature.ShowTrainPreview(options: any)
	TrainPreviewBoard.Show(options)
end

--[[
	隐藏训练场预览传送门（缩放消失后销毁）
]]
function ShortVideoFeature.HideTrainPreview()
	TrainPreviewBoard.Destroy()
end

--[[
	预览传送门是否显示中
	@return boolean
]]
function ShortVideoFeature.IsTrainPreviewShowing(): boolean
	return TrainPreviewBoard.IsShowing()
end

return ShortVideoFeature
