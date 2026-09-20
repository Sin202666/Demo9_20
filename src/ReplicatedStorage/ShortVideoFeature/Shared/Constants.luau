--[[
	Module: Constants
	Description: ShortVideoFeature 共享常量（片单/社交/预载/评论窗/场景/UI/训练预览传送门/评论生命周期）
	Author: 林奥宇
	Created: 2026-08-13
	Last Modified: 2026-09-01

	UI 资源：将下方 Image / LikedImage 等填为 rbxassetid://数字；0 或空串时用文字占位。
	尺寸均为 SurfaceGui 像素（PixelsPerStud=50 时约 50px=1stud）。
	训练预览：改 TrainPreview.PortalModelPath / ScaleAnim / Prompt；位姿由调用方传入 boardCFrame。
	评论生命周期：见 COMMENT_LIFECYCLE；不变量 ProtectTopK << SoftCap <= HardCap；Enabled 验证后再开。
]]

local Constants = {}

Constants.CONFIG_KEY = "ShortVideoList"

Constants.DATASTORE = {
	Stats = "ShortVideoStats",
	Comments = "ShortVideoComments", -- 旧数组；迁移后写 { migrated=true, timeMigrated?=true }
	CommentBody = "ShortVideoCommentBody",
	CommentRank = "ShortVideoCommentRank", -- OrderedDataStore，scope=videoId；赞序
	CommentTime = "ShortVideoCommentTime", -- OrderedDataStore，scope=videoId；时间序
	Player = "ShortVideoPlayer",
}

-- 赞序分数：likeCount * SCORE_LIKE_MUL + createdAt % SCORE_LIKE_MUL
Constants.COMMENT_SCORE_LIKE_MUL = 1000000000
-- 评论列表排序：hot=赞序（默认）；newest=时间新→旧
Constants.COMMENT_SORT = {
	Hot = "hot",
	Newest = "newest",
}
Constants.DEFAULT_COMMENT_SORT = "hot"
-- 发评正文上限：按 UTF-8 字节长度（#text）计
Constants.COMMENT_MAX_LEN = 500
Constants.COMMENT_PAGE_SIZE = 20
Constants.COMMENT_BODY_FETCH_BATCH = 10
Constants.COMMENT_MEMORY_MAX = 200
Constants.COMMENT_ROW_POOL = 16
Constants.COMMENT_BODY_CACHE_TTL_SEC = 30
-- 评论分页预载：距底 ≤ 视口高度 * ratio 时触发 loadMore（避免贴底再干等）
Constants.COMMENT_PREFETCH_VIEWPORT_RATIO = 8
-- 首屏拉取成功后静默再拉一页（有下一页时）
Constants.COMMENT_AUTO_PREFETCH_FIRST = true

-- 评论行正文：Body 全程 TextScaled；≤MAX_LINES 扩高，超限锁高
Constants.COMMENT_BODY_MAX_LINES = 5
-- List.RowTemplate 单行稿高 = List.AbsoluteSize.Y * HEIGHT_SCALE（对齐预制体 Size.Y Scale）
Constants.COMMENT_ROW_HEIGHT_SCALE = 0.2
-- 子控件相对单行稿高的 Scale 比例（对齐 List.RowTemplate）
Constants.COMMENT_ROW_LAYOUT = {
	Name = { X = 0.18, Y = 0.12, W = 0.8, H = 0.28061226 },
	Body = { X = 0.185, Y = 0.45, W = 0.65, H = 0.263605446 },
	Time = { X = 0.185, Y = 0.72, W = 0.65, H = 0.255102038 },
	-- 头像 / 赞区按单行稿高锁 Offset，避免行增高时 Scale 放大
	Avatar = { X = 0.02, Y = 0.1, SizeScale = 0.7 },
	LikeBtn = { X = 0.87, Y = 0.5, W = 0.136, H = 0.68 },
	LikeCount = { X = 1, Y = 0.5, W = 0.1, H = 0.25 },
}
-- 旧赞序 → 时间 ODS 后台懒补（不阻塞首屏）
Constants.COMMENT_TIME_BACKFILL_PAGE = 50
Constants.COMMENT_TIME_BACKFILL_WAIT_SEC = 0.12
Constants.PLAYER_CACHE_TTL_SEC = 5
-- 调试：每次 EnsureMigrated 都重跑旧数组→Body/ODS；且不覆盖旧 key 为 migrated（便于反复测）
-- 上线前务必改回 false
Constants.DEBUG_COMMENT_ALWAYS_MIGRATE = false
Constants.AVATAR_LRU_MAX = 96
Constants.AVATAR_FAIL_COOLDOWN_SEC = 45
Constants.AVATAR_API_MAX_INFLIGHT = 3
Constants.AVATAR_API_MIN_GAP_SEC = 0.05
Constants.COMMENT_BODY_MISS_TTL_SEC = 15
Constants.STATS_CACHE_TTL_SEC = 3

--[[
	评论生命周期（服务端懒清理；硬删）
	优先级：HardCap > SoftCap 压力 > 近 N 天尽量保留；神评保护集（TopK∧赞≥T）永不删。
	不变量：ProtectTopK << SoftCap <= HardCap。
	Enabled 默认 false，Studio 验证后再开。
]]
Constants.COMMENT_LIFECYCLE = {
	Enabled = false,
	RetainDays = 30,
	ProtectTopK = 80,
	ProtectMinLikes = 5,
	SoftCap = 1500,
	HardCap = 3000,
	-- 同步 HardCap 腾槽（发评路径）；宜小，避免卡 Post
	MaxDeleteSync = 8,
	-- 异步收尾 / Fetch 首页
	MaxDeleteAsync = 40,
	ScanPageSize = 50,
	CooldownSec = 300,
}

Constants.POST_COMMENT_CD_SEC = 3
Constants.LIKE_WINDOW_SEC = 2
Constants.LIKE_WINDOW_MAX = 5
-- 拉评滑动窗口（防 DataStore 打爆；略放宽避免滚底静默失败）
Constants.FETCH_COMMENT_WINDOW_SEC = 3
Constants.FETCH_COMMENT_WINDOW_MAX = 12

-- 客户端交互冷却（视频赞 / 评论赞分开，避免互挡）
Constants.CLIENT_LIKE_CD_SEC = 1 -- 兼容旧名：视频赞
Constants.CLIENT_VIDEO_LIKE_CD_SEC = 1
Constants.CLIENT_COMMENT_LIKE_CD_SEC = 1
Constants.CLIENT_POST_COMMENT_CD_SEC = 3

-- 停稳后再确认一遍邻接预载（+1/+2/−1 已立即预载）
Constants.WATCH_FALLBACK_SEC = 15
Constants.PRELOAD_IDLE_SEC = 0.25
-- 预载槽数量语义：1=+1，2=+2，3=−1（缺省由 PlayerController / Open 补齐）
Constants.PRELOAD_SLOT_COUNT = 3
-- 用户切集最短间隔（防连刷打满多路 VideoFrame 解码）
Constants.SWITCH_THROTTLE_SEC = 0.2
-- 进度条轮询间隔（TimePosition 无 Changed；约 10Hz 足够）
Constants.PROGRESS_POLL_INTERVAL_SEC = 0.1

Constants.BOARD_DISTANCE = 8
Constants.BOARD_HEIGHT = 50
-- 手机竖屏短视频底座 9:16（Part.Size X=宽 Y=高，Front 面）
Constants.BOARD_ASPECT = 9 / 16
Constants.BOARD_SIZE = Vector3.new(9, 16, 0.2)

Constants.COLORS = {
	Bg = Color3.fromRGB(10, 10, 10),
	Drawer = Color3.fromRGB(22, 22, 22),
	Text = Color3.fromRGB(245, 245, 245),
	Muted = Color3.fromRGB(163, 163, 163),
	Accent = Color3.fromRGB(255, 45, 85),
	Line = Color3.fromRGB(42, 42, 42),
	-- 进度条填充（视觉稿 #26d956）
	Progress = Color3.fromRGB(38, 217, 86),
	-- 评论排序按钮：选中 #a5a5a5 / 未选中 #2c2c2c
	SortSelectedBg = Color3.fromRGB(165, 165, 165),
	SortUnselectedBg = Color3.fromRGB(44, 44, 44),
	SortSelectedText = Color3.fromRGB(0, 0, 0),
	SortUnselectedText = Color3.fromRGB(255, 255, 255),
}

--[[
	UI 可配置资源与尺寸（切集在底板外；动作栏在底板内右侧）
	Image 填 rbxassetid://xxx 或纯数字；0 / "" 则显示 Text 占位。
	视觉对齐：赞评数字 28/描2/透0.5；切集键位字号 42；进度条高 12、底边 0。
]]
Constants.UI = {
	-- 主底板：内缩露白边；Part 用 Neon 白（不加 Light）
	Board = {
		PaddingPx = 6,
		StrokeThickness = 2,
		StrokeColor = Color3.fromRGB(255, 255, 255),
		StrokeTransparency = 0,
		NeonColor = Color3.fromRGB(255, 255, 255),
	},
	-- 底板外左右切集按钮（键位：PC=Q/E；手柄=L1/R1 或 LB/RB；移动隐藏）
	Nav = {
		ImagePrev = "rbxassetid://132451742814499", -- 左滑
		ImageNext = "rbxassetid://123677403592763", -- 右滑
		-- SurfaceGui / Screen 像素尺寸
		BtnSize = Vector2.new(124, 124),
		-- 世界侧板 Part 尺寸（Stud）；厚度与主底板一致
		PartSize = Vector3.new(1.4, 2.2, 0.2),
		-- 与主底板边缘的空隙（Stud）
		GapStuds = 0.35,
		FallbackPrevText = "<",
		FallbackNextText = ">",
		KeyPrev = "Q",
		KeyNext = "E",
		KeyPrevGamepadPS = "L1",
		KeyNextGamepadPS = "R1",
		KeyPrevGamepadXbox = "LB",
		KeyNextGamepadXbox = "RB",
		KeyPrevGamepadBoth = "L1/LB",
		KeyNextGamepadBoth = "R1/RB",
		KeyTextSize = 42,
		KeyTextColor = Color3.fromRGB(20, 20, 20),
		KeyStrokeColor = Color3.fromRGB(255, 255, 255),
		KeyStrokeThickness = 2,
	},
	-- 顶栏关闭
	TopBar = {
		ImageClose = "rbxassetid://96025426685747",
		FallbackCloseText = "X",
	},
	-- 右侧动作栏：赞 / 评 / 分享
	Action = {
		BtnSize = Vector2.new(86, 86),
		IconSize = Vector2.new(86, 86),
		CountHeight = 32,
		Spacing = 4,
		RailWidth = 106,
		-- 相对底板右侧内边距 / 垂直锚点
		MarginRight = 10,
		AnchorY = 0.68,
		-- 视觉稿：字号 28、描边 2、透明度 0.5
		CountTextSize = 28,
		CountTextTransparency = 0.5,
		CountStrokeThickness = 2,
		CountStrokeColor = Color3.fromRGB(0, 0, 0),
		CountTextColor = Color3.fromRGB(255, 255, 255),
		ImageLike = "rbxassetid://78679205107484",
		ImageLiked = "rbxassetid://94833484560380",
		ImageComment = "rbxassetid://121926633978676",
		ImageShare = "rbxassetid://87003655801504",
		FallbackLike = "Like",
		FallbackLiked = "Liked",
		FallbackComment = "Cmt",
		FallbackShare = "Share",
	},
	-- 底部播放进度条（宽随 Content；高 12；底边偏移 0）
	Progress = {
		Height = 12,
		OffsetY = 0,
		FillColor = Color3.fromRGB(38, 217, 86),
		TrackColor = Color3.fromRGB(255, 255, 255),
		TrackTransparency = 0,
		ZIndex = 7,
	},
	-- 视频未就绪时的转圈 Loading
	Loading = {
		Image = "rbxassetid://109425645158038",
		Size = Vector2.new(72, 72),
		SpinDegPerSec = 270,
		FallbackText = "",
	},
	-- 评论行点赞（与主界面 Action 图标分开）
	CommentLike = {
		ImageLike = "rbxassetid://76227429347918",
		ImageLiked = "rbxassetid://113851341223184",
		FallbackLike = "Like",
		FallbackLiked = "Liked",
	},
	-- 点击视频区暂停；图标居中 130x130
	Pause = {
		Image = "rbxassetid://106210266817414",
		Size = Vector2.new(130, 130),
	},
	-- 评论发送按钮（图标；文字清空）
	Send = {
		Image = "rbxassetid://120464506588283",
	},
	-- 与项目 UIanima.ButtonDown/Up、BtnScaleAnimEnter/Leave 一致的缩放反馈
	ButtonFeedback = {
		DownScale = 0.9,
		TweenTime = 0.1,
		HoverScale = 1.1,
		HoverTweenTime = 0.2,
		-- 点赞态切换弹跳（乐观 UI 立刻可感）
		LikePopScale = 1.28,
		LikePopUpSec = 0.08,
		LikePopDownSec = 0.16,
	},
}

--[[
	2D 短视频打开时压制游戏内 SoundGroup 音量（BGM/EFFECT 等），退出恢复
	FadeSec 对齐 GameConfig.Setting[音量渐变秒] 默认 0.5
]]
Constants.AudioDuck = {
	FadeSec = 0.5,
}

--[[
	自动训练旁预览传送门（水晶位置 + Orientation；SurfaceGui 挂 Screen.Left；E 同场景商店 Custom Prompt）
]]
Constants.TrainPreview = {
	-- Assets.ModelRes 下模型相对路径（AssetAcquire.Get）
	PortalModelPath = "ModelRes/视频传送门",
	ScreenPartName = "Screen",
	SurfaceFace = Enum.NormalId.Left,
	-- 传送门预览轨静音（正式 2D/3D UI 不受此影响）
	Volume = 0,
	-- 世界朝向（度）：CFrame.fromOrientation(radX, radY, radZ)
	OrientationDegrees = Vector3.new(0, 90, 0),
	ScaleAnim = {
		Duration = 0.3,
		AppearFrom = 0.1,
		AppearTo = 1,
		HideFrom = 1,
		HideTo = 0.1,
	},
	-- Style=Custom + HoldDuration=0.1 对齐 OpenUI/场景商店；Action 文案由 SceneBoard SetText「观看」
	Prompt = {
		MaxActivationDistance = 12,
		HoldDuration = 0.1,
		RequiresLineOfSight = false,
		KeyboardKeyCode = Enum.KeyCode.E,
	},
}

Constants.ERROR = {
	OK = "OK",
	INVALID = "INVALID",
	TOO_LONG = "TOO_LONG",
	RATE_LIMIT = "RATE_LIMIT",
	FILTER_FAIL = "FILTER_FAIL",
	NOT_FOUND = "NOT_FOUND",
	BUSY = "BUSY",
}

return Constants