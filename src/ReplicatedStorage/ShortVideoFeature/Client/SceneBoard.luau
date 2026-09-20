--[[
	Module: SceneBoard
	Description: 客户端视频底板（3D SurfaceGui / 2D ScreenGui）+ 训练预览传送门单例
	Author: 林奥宇
	Created: 2026-08-13
	Last Modified: 2026-09-01

	主底板仅承载视频与动作栏；Prev/Next 在主底板左右外侧独立 Part，避免遮挡画面。
	2D：优先克隆 ReplicatedStorage.Assets.ScreenGui.ShortVideoScreen；缺失时回退 BuildUI 代码创建。
	TrainPreview：克隆 ModelRes「视频传送门」，SurfaceGui 挂 Screen（Face=Left），预览静音，Custom E 开 2D。
	支持 TakeVideoFrameForHandoff / EnsureVideoFrame：正式 UI 复用已解码帧，Close 后重建预览。
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Constants = require(script.Parent.Parent.Shared.Constants)
local Remotes = require(script.Parent.Parent.Shared.Remotes)
local BuildUI = require(script.Parent.BuildUI)
local UiAssets = require(script.Parent.UiAssets)
local UiPrefabUtil = require(script.Parent.UiPrefabUtil)
local Recommend = require(script.Parent.Recommend)
local SocialClient = require(script.Parent.SocialClient)

local SceneBoard = {}

export type BoardCreateOptions = {
	boardAnchor: string?, -- "camera" | "character"
	follow: boolean?,
	distance: number?,
	ui: any?, -- 覆盖 Constants.UI 的局部配置
}

export type BoardHandles = {
	part: BasePart?,
	surfaceGui: SurfaceGui?,
	screenGui: ScreenGui?,
	root: Frame,
	folder: Instance?,
	prevBtn: ImageButton,
	nextBtn: ImageButton,
	leftPart: BasePart?,
	rightPart: BasePart?,
	displayMode: string?, -- "scene" | "screen"
	stopFollow: (() -> ())?,
}

local PIXELS_PER_STUD = 50

--[[
	计算底板 CFrame
	@param anchor string - camera | character
	@param distance number - 相机锚点时的前方距离（角色锚点改用高度）
	@return CFrame? - 板位姿
]]
local function resolveBoardCFrame(anchor: string, distance: number): CFrame?
	if anchor == "character" then
		local player = Players.LocalPlayer
		local char = player and player.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if not hrp or not hrp:IsA("BasePart") then
			return nil
		end
		-- 玩家正上方固定高度，板正面朝下对着角色
		local height = Constants.BOARD_HEIGHT
		local pos = hrp.Position + Vector3.new(0, height, 0)
		return CFrame.lookAt(pos, hrp.Position)
	end
	local camera = Workspace.CurrentCamera
	if not camera then
		return nil
	end
	local cf = camera.CFrame * CFrame.new(0, 0, -distance)
	return CFrame.lookAt(cf.Position, camera.CFrame.Position)
end

--[[
	按主底板 CFrame 放置左右切集侧板（本地 X：左负右正）
	@param boardPart BasePart - 主底板
	@param leftPart BasePart - 左侧板
	@param rightPart BasePart - 右侧板
	@param uiCfg any - UI 配置
]]
local function placeNavParts(boardPart: BasePart, leftPart: BasePart, rightPart: BasePart, uiCfg: any)
	local nav = uiCfg.Nav
	local halfW = boardPart.Size.X * 0.5
	local halfNav = nav.PartSize.X * 0.5
	local gap = nav.GapStuds
	local offset = halfW + gap + halfNav
	leftPart.CFrame = boardPart.CFrame * CFrame.new(-offset, 0, 0)
	rightPart.CFrame = boardPart.CFrame * CFrame.new(offset, 0, 0)
end

--[[
	创建侧板 Part + SurfaceGui + 切集按钮
	@param folder Folder - 父级
	@param player Player - 本地玩家
	@param name string - Part 名
	@param side "prev" | "next" - 侧
	@return (BasePart, SurfaceGui, ImageButton)
]]
local function createNavSide(
	folder: Folder,
	player: Player,
	name: string,
	side: string,
	uiCfg: any
): (BasePart, SurfaceGui, ImageButton)
	local nav = uiCfg.Nav
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = true
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.SmoothPlastic
	part.Color = Color3.fromRGB(20, 20, 20)
	part.Transparency = 1
	part.Size = nav.PartSize
	part.Parent = folder

	local gui = Instance.new("SurfaceGui")
	gui.Name = name .. "Gui"
	gui.Adornee = part
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = PIXELS_PER_STUD
	gui.LightInfluence = 0
	gui.Active = true
	gui.AlwaysOnTop = true
	gui.Parent = player:WaitForChild("PlayerGui")

	local btn = BuildUI.BuildNavButton(gui, side, uiCfg)
	return part, gui, btn
end

--[[
	创建底板与 UI
	@param options BoardCreateOptions? - 锚点等
	@return BoardHandles? - 句柄
]]
function SceneBoard.Create(options: BoardCreateOptions?): BoardHandles?
	local opts = options or {}
	local anchor = if opts.boardAnchor == "character" then "character" else "camera"
	local distance = tonumber(opts.distance) or Constants.BOARD_DISTANCE
	local follow = opts.follow == true
	local uiCfg = opts.ui or Constants.UI

	local player = Players.LocalPlayer
	if not player then
		return nil
	end

	local boardCf = resolveBoardCFrame(anchor, distance)
	if not boardCf then
		-- 角色锚点失败时回退相机
		boardCf = resolveBoardCFrame("camera", distance)
	end
	if not boardCf then
		return nil
	end

	local folder = Instance.new("Folder")
	folder.Name = "ShortVideoBoardLocal"
	folder.Parent = Workspace

	local part = Instance.new("Part")
	part.Name = "ShortVideoBoard"
	part.Anchored = true
	part.CanCollide = false
	-- SurfaceGui 点击依赖鼠标射线打中 Adornee，必须可 Query
	part.CanQuery = true
	part.CanTouch = false
	part.CastShadow = false
	-- 白色 Neon 自发光边框感（不加 Light，靠材质 bloom）
	part.Material = Enum.Material.Neon
	local boardUi = uiCfg.Board or {}
	part.Color = boardUi.NeonColor or Color3.fromRGB(255, 255, 255)
	part.Size = Constants.BOARD_SIZE
	part.CFrame = boardCf
	part.Parent = folder

	local surfaceGui = Instance.new("SurfaceGui")
	surfaceGui.Name = "ShortVideoSurface"
	surfaceGui.Adornee = part
	surfaceGui.Face = Enum.NormalId.Front
	surfaceGui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	surfaceGui.PixelsPerStud = PIXELS_PER_STUD
	surfaceGui.LightInfluence = 0
	surfaceGui.Active = true
	surfaceGui.AlwaysOnTop = true
	surfaceGui.Parent = player:WaitForChild("PlayerGui")

	local root = BuildUI.Build(surfaceGui, uiCfg)

	local leftPart, leftGui, prevBtn = createNavSide(folder, player, "ShortVideoNavLeft", "prev", uiCfg)
	local rightPart, rightGui, nextBtn = createNavSide(folder, player, "ShortVideoNavRight", "next", uiCfg)
	placeNavParts(part, leftPart, rightPart, uiCfg)

	local followConn: RBXScriptConnection? = nil
	local acc = 0
	if follow and anchor == "character" then
		followConn = RunService.Heartbeat:Connect(function(dt)
			acc += dt
			if acc < 0.1 then
				return
			end
			acc = 0
			local cf = resolveBoardCFrame("character", distance)
			if cf and part.Parent then
				part.CFrame = cf
				placeNavParts(part, leftPart, rightPart, uiCfg)
			end
		end)
	end

	return {
		part = part,
		surfaceGui = surfaceGui,
		screenGui = nil,
		root = root,
		folder = folder,
		prevBtn = prevBtn,
		nextBtn = nextBtn,
		leftPart = leftPart,
		rightPart = rightPart,
		displayMode = "scene",
		_leftGui = leftGui,
		_rightGui = rightGui,
		stopFollow = function()
			if followConn then
				followConn:Disconnect()
				followConn = nil
			end
		end,
	}
end

--[[
	创建 2D ScreenGui 短视频界面（内容与 3D SurfaceGui 一致：顶栏/视频/赞评/切集）
	@param options BoardCreateOptions? - ui 配置
	@return BoardHandles? - 句柄（part 为 nil）
]]
function SceneBoard.CreateScreen(options: BoardCreateOptions?): BoardHandles?
	local opts = options or {}
	local uiCfg = opts.ui or Constants.UI
	local player = Players.LocalPlayer
	if not player then
		return nil
	end

	local playerGui = player:WaitForChild("PlayerGui")
	local nav = uiCfg.Nav
	local navGap = 12

	-- 优先：Assets.ScreenGui.ShortVideoScreen 预制体；缺失则代码生成
	local prefabGui, prefabContent, prefabPrev, prefabNext, prefabPhone, prefabStage = UiPrefabUtil.CloneScreen()
	if prefabGui and prefabContent and prefabPrev and prefabNext and prefabPhone and prefabStage then
		if RunService:IsStudio() then
			print("[ShortVideoFeature] UI source: ScreenGui prefab clone (Assets.ScreenGui.ShortVideoScreen)")
		end
		prefabGui.Parent = playerGui
		local function layoutPrefab()
			local stageSize = prefabStage.AbsoluteSize
			if stageSize.X < 2 or stageSize.Y < 2 then
				return
			end
			local navW = math.max(prefabPrev.AbsoluteSize.X, nav.BtnSize.X)
			local maxH = stageSize.Y * 0.92
			local maxW = math.max(80, stageSize.X - (navW + navGap) * 2 - 24)
			local aspect = Constants.BOARD_ASPECT
			local w: number
			local h: number
			if maxW / maxH > aspect then
				h = maxH
				w = h * aspect
			else
				w = maxW
				h = w / aspect
			end
			w = math.floor(w + 0.5)
			h = math.floor(h + 0.5)
			prefabPhone.Size = UDim2.fromOffset(w, h)
			local halfW = w * 0.5
			local sideX = halfW + navGap + navW * 0.5
			prefabPrev.Position = UDim2.new(0.5, -sideX, 0.5, 0)
			prefabNext.Position = UDim2.new(0.5, sideX, 0.5, 0)
		end
		local sizeConn = prefabStage:GetPropertyChangedSignal("AbsoluteSize"):Connect(layoutPrefab)
		task.defer(layoutPrefab)
		-- 预制体 KeyLabel 默认 Q/E，按当前设备刷新一次
		BuildUI.RefreshNavKeyLabels(prefabPrev, prefabNext, uiCfg)
		return {
			part = nil,
			surfaceGui = nil,
			screenGui = prefabGui,
			root = prefabContent,
			folder = prefabGui,
			prevBtn = prefabPrev,
			nextBtn = prefabNext,
			leftPart = nil,
			rightPart = nil,
			displayMode = "screen",
			_screenSizeConn = sizeConn,
			stopFollow = nil,
		}
	end

	if RunService:IsStudio() then
		print("[ShortVideoFeature] UI source: code build (BuildUI fallback)")
	end
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "ShortVideoScreen"
	screenGui.IgnoreGuiInset = true
	screenGui.ResetOnSpawn = false
	screenGui.DisplayOrder = 120
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.Parent = playerGui

	local dimmer = Instance.new("Frame")
	dimmer.Name = "Dimmer"
	dimmer.Size = UDim2.fromScale(1, 1)
	dimmer.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	dimmer.BackgroundTransparency = 0.35
	dimmer.BorderSizePixel = 0
	dimmer.ZIndex = 1
	dimmer.Parent = screenGui

	local stage = Instance.new("Frame")
	stage.Name = "Stage"
	stage.Size = UDim2.fromScale(1, 1)
	stage.BackgroundTransparency = 1
	stage.BorderSizePixel = 0
	stage.ZIndex = 2
	stage.Parent = screenGui

	local function makeScreenNav(side: string): ImageButton
		local isPrev = side == "prev"
		local btn = Instance.new("ImageButton")
		btn.Name = if isPrev then "PrevBtn" else "NextBtn"
		btn.AutoButtonColor = false
		btn.Active = true
		btn.Selectable = true
		btn.AnchorPoint = Vector2.new(0.5, 0.5)
		btn.Size = UDim2.fromOffset(nav.BtnSize.X, nav.BtnSize.Y)
		btn.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
		btn.BackgroundTransparency = 0.25
		btn.BorderSizePixel = 0
		btn.ScaleType = Enum.ScaleType.Fit
		btn.ZIndex = 4
		btn.Parent = stage
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 10)
		corner.Parent = btn
		UiAssets.ApplyButtonImage(
			btn,
			if isPrev then nav.ImagePrev else nav.ImageNext,
			if isPrev then nav.FallbackPrevText else nav.FallbackNextText
		)
		BuildUI.AttachNavKeyLabel(btn, side, uiCfg)
		return btn
	end

	local prevBtn = makeScreenNav("prev")
	local nextBtn = makeScreenNav("next")

	-- 手机框按 Stage 像素显式算 9:16（避免 AutomaticSize + Scale(0,1) 循环坍缩成细条）
	local phone = Instance.new("Frame")
	phone.Name = "Phone"
	phone.AnchorPoint = Vector2.new(0.5, 0.5)
	phone.Position = UDim2.fromScale(0.5, 0.5)
	phone.Size = UDim2.fromOffset(270, 480)
	phone.BackgroundColor3 = (uiCfg.Board and uiCfg.Board.NeonColor) or Color3.fromRGB(255, 255, 255)
	phone.BorderSizePixel = 0
	phone.ClipsDescendants = true
	phone.ZIndex = 3
	phone.Parent = stage

	local function layoutScreen()
		local stageSize = stage.AbsoluteSize
		if stageSize.X < 2 or stageSize.Y < 2 then
			return
		end
		local navW = nav.BtnSize.X
		local maxH = stageSize.Y * 0.92
		local maxW = math.max(80, stageSize.X - (navW + navGap) * 2 - 24)
		local aspect = Constants.BOARD_ASPECT -- 宽/高 = 9/16
		local w: number
		local h: number
		if maxW / maxH > aspect then
			h = maxH
			w = h * aspect
		else
			w = maxW
			h = w / aspect
		end
		w = math.floor(w + 0.5)
		h = math.floor(h + 0.5)
		phone.Size = UDim2.fromOffset(w, h)

		local halfW = w * 0.5
		local sideX = halfW + navGap + navW * 0.5
		prevBtn.Position = UDim2.new(0.5, -sideX, 0.5, 0)
		nextBtn.Position = UDim2.new(0.5, sideX, 0.5, 0)
	end

	local sizeConn = stage:GetPropertyChangedSignal("AbsoluteSize"):Connect(layoutScreen)
	task.defer(layoutScreen)

	local root = BuildUI.Build(phone, uiCfg)

	return {
		part = nil,
		surfaceGui = nil,
		screenGui = screenGui,
		root = root,
		folder = screenGui,
		prevBtn = prevBtn,
		nextBtn = nextBtn,
		leftPart = nil,
		rightPart = nil,
		displayMode = "screen",
		_screenSizeConn = sizeConn,
		stopFollow = nil,
	}
end

--[[
	销毁底板与 Gui
	@param handles BoardHandles? - 句柄
]]
function SceneBoard.Destroy(handles: BoardHandles?)
	if not handles then
		return
	end
	if handles.stopFollow then
		handles.stopFollow()
	end
	local anyHandles = handles :: any
	if anyHandles._screenSizeConn then
		anyHandles._screenSizeConn:Disconnect()
		anyHandles._screenSizeConn = nil
	end
	if anyHandles._leftGui then
		anyHandles._leftGui:Destroy()
	end
	if anyHandles._rightGui then
		anyHandles._rightGui:Destroy()
	end
	if handles.surfaceGui then
		handles.surfaceGui:Destroy()
	end
	if handles.screenGui then
		handles.screenGui:Destroy()
	elseif handles.folder then
		handles.folder:Destroy()
	elseif handles.part then
		handles.part:Destroy()
	end
end
--------------------------------------------------------------------------------
-- TrainPreview：自动训练旁预览传送门（单例，挂在 SceneBoard 避免新增未同步 ModuleScript）
--------------------------------------------------------------------------------

local PREVIEW_PIXELS_PER_STUD = 50
local PREVIEW_FOLDER_NAME = "ShortVideoTrainPreviewLocal"
local PREVIEW_MIN_SCALE = 0.01

local _previewAlive = false
local _previewHiding = false
local _previewFolder: Folder? = nil
local _previewModel: Model? = nil
local _previewSurfaceGui: SurfaceGui? = nil
local _previewVideo: VideoFrame? = nil
local _previewPrompt: ProximityPrompt? = nil
local _previewListConn: RBXScriptConnection? = nil
local _previewPromptConn: RBXScriptConnection? = nil
local _previewScaleConn: RBXScriptConnection? = nil
local _previewAnimToken = 0
local _previewFirstItem: any = nil
local _previewOnTriggered: (() -> ())? = nil
local _previewPlaying = true

local TrainPreview = {}

--[[
	软依赖 UtilsSystem（AssetAcquire / AddListen / TranslationHelper）
	@return any?
]]
local function tryGetUtils(): any?
	local ok, utils = pcall(function()
		return require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
	end)
	if ok then
		return utils
	end
	return nil
end

--[[
	克隆视频传送门模型
	@param path string - AssetAcquire 相对路径
	@return Model?
]]
local function clonePortalModel(path: string): Model?
	local utils = tryGetUtils()
	local AssetAcquire = utils and utils.AssetAcquire
	if AssetAcquire and type(AssetAcquire.Get) == "function" then
		local inst = AssetAcquire.Get(path)
		if inst and inst:IsA("Model") then
			return inst
		end
	end
	return nil
end

--[[
	准备传送门物理属性（锚定、不碰撞；不改 Screen/各 Part 透明度）
	@param model Model - 传送门
	@param screen BasePart - Screen
]]
local function preparePortalParts(model: Model, screen: BasePart)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanTouch = false
			d.CastShadow = false
			-- 保留资源里配置的 Transparency（Screen 底板保持透明）
		end
	end
	screen.CanQuery = true
end

--[[
	停止缩放动画
]]
local function stopScaleAnim()
	if _previewScaleConn then
		_previewScaleConn:Disconnect()
		_previewScaleConn = nil
	end
end

--[[
	Model:ScaleTo 缩放动画（Back 曲线）
	@param model Model - 传送门
	@param fromScale number - 起始缩放
	@param toScale number - 目标缩放
	@param duration number - 秒
	@param easingDir Enum.EasingDirection - Out=出现 / In=消失
	@param onDone (() -> ())? - 结束回调
]]
local function animateScale(
	model: Model,
	fromScale: number,
	toScale: number,
	duration: number,
	easingDir: Enum.EasingDirection,
	onDone: (() -> ())?
)
	stopScaleAnim()
	_previewAnimToken += 1
	local token = _previewAnimToken
	local dur = math.max(0.01, duration)
	pcall(function()
		model:ScaleTo(math.max(PREVIEW_MIN_SCALE, fromScale))
	end)
	local elapsed = 0
	_previewScaleConn = RunService.Heartbeat:Connect(function(dt)
		if token ~= _previewAnimToken or not model.Parent then
			stopScaleAnim()
			return
		end
		elapsed += dt
		local alpha = math.clamp(elapsed / dur, 0, 1)
		local t = TweenService:GetValue(alpha, Enum.EasingStyle.Back, easingDir)
		local scale = fromScale + (toScale - fromScale) * t
		pcall(function()
			model:ScaleTo(math.max(PREVIEW_MIN_SCALE, scale))
		end)
		if alpha >= 1 then
			stopScaleAnim()
			if onDone then
				onDone()
			end
		end
	end)
end

--[[
	播放单条视频（循环）
	@param item any - VideoItem
]]
local function playPreviewItem(item: any)
	_previewFirstItem = item
	local video = _previewVideo
	if not video or not item or not item.videoId then
		return
	end
	local uri = "rbxassetid://" .. tostring(item.videoId)
	pcall(function()
		(video :: any).Video = uri
	end)
	if _previewPlaying then
		pcall(function()
			video:Play()
		end)
	else
		pcall(function()
			video:Pause()
		end)
	end
end

--[[
	应用片单：取推荐首条
	@param payload any - ListUpdated
]]
local function onPreviewListPayload(payload: any)
	if not _previewAlive or typeof(payload) ~= "table" then
		return
	end
	local list = payload.list or {}
	local watched = if typeof(payload.watched) == "table" then payload.watched else {}
	local feed = Recommend.BuildFeed(list, watched)
	if #feed > 0 then
		playPreviewItem(feed[1])
	end
end

--[[
	销毁预览内部实例（幂等，立即）
]]
local function destroyPreviewInternal()
	_previewAlive = false
	_previewHiding = false
	_previewPlaying = true
	_previewFirstItem = nil
	_previewOnTriggered = nil
	_previewAnimToken += 1
	stopScaleAnim()
	if _previewListConn then
		_previewListConn:Disconnect()
		_previewListConn = nil
	end
	if _previewPromptConn then
		_previewPromptConn:Disconnect()
		_previewPromptConn = nil
	end
	if _previewSurfaceGui then
		_previewSurfaceGui:Destroy()
		_previewSurfaceGui = nil
	end
	if _previewFolder then
		_previewFolder:Destroy()
		_previewFolder = nil
	end
	_previewModel = nil
	_previewVideo = nil
	_previewPrompt = nil
end

--[[
	是否已显示
	@return boolean
]]
function TrainPreview.IsShowing(): boolean
	return _previewAlive and not _previewHiding
end

--[[
	当前预览首条（供正式 UI 置顶）
	@return any?
]]
function TrainPreview.GetFirstItem(): any?
	return _previewFirstItem
end

--[[
	当前预览 VideoFrame（未交接时）
	@return VideoFrame?
]]
function TrainPreview.GetVideoFrame(): VideoFrame?
	return _previewVideo
end

--[[
	取出预览 VideoFrame 交给正式 UI（暂停并清空引用；调用方负责 Parent / 销毁）
	Close 后需 EnsureVideoFrame 重建预览帧。
	@return VideoFrame?
]]
function TrainPreview.TakeVideoFrameForHandoff(): VideoFrame?
	local video = _previewVideo
	if not video then
		return nil
	end
	pcall(function()
		video:Pause()
	end)
	_previewVideo = nil
	return video
end

--[[
	在 Root 下创建预览 VideoFrame（含圆角/渐变）
	@param root Frame - SurfaceGui.Root
	@return VideoFrame
]]
local function createPreviewVideoOnRoot(root: Frame): VideoFrame
	local video = Instance.new("VideoFrame")
	video.Name = "PreviewVideo"
	video.Size = UDim2.fromScale(1, 1)
	video.BackgroundTransparency = 1
	video.BorderSizePixel = 0
	video.Looped = true
	video.Active = false
	local previewVol = Constants.TrainPreview.Volume
	video.Volume = if typeof(previewVol) == "number" then math.clamp(previewVol, 0, 1) else 0
	video.Parent = root

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = video

	local gradient = Instance.new("UIGradient")
	gradient.Transparency = NumberSequence.new(0.5)
	gradient.Parent = video

	return video
end

--[[
	正式 UI Close 后：若预览帧被交接走则重建，并按首条重新灌片
	@return VideoFrame?
]]
function TrainPreview.EnsureVideoFrame(): VideoFrame?
	if not _previewAlive or _previewHiding then
		return nil
	end
	if _previewVideo and _previewVideo.Parent then
		return _previewVideo
	end
	if not _previewSurfaceGui then
		return nil
	end
	local root = _previewSurfaceGui:FindFirstChild("Root")
	if not root or not root:IsA("Frame") then
		return nil
	end
	local existing = root:FindFirstChild("PreviewVideo")
	if existing and existing:IsA("VideoFrame") then
		_previewVideo = existing
	else
		_previewVideo = createPreviewVideoOnRoot(root)
	end
	if _previewFirstItem then
		playPreviewItem(_previewFirstItem)
	end
	return _previewVideo
end

--[[
	暂停/恢复预览播放
	@param playing boolean - 是否播放
]]
function TrainPreview.SetPlaying(playing: boolean)
	_previewPlaying = playing == true
	if _previewPlaying then
		-- Close 恢复：帧可能已被正式 UI 交接走，需重建
		local video = _previewVideo
		if not video or not video.Parent then
			video = TrainPreview.EnsureVideoFrame()
		end
		if video then
			pcall(function()
				video:Play()
			end)
		end
		return
	end
	-- 暂停：帧已交接则不重建，避免与正式 UI 抢带宽
	local video = _previewVideo
	if video then
		pcall(function()
			video:Pause()
		end)
	end
end

--[[
	设置 Prompt 是否可用
	@param enabled boolean - 是否可用
]]
function TrainPreview.SetPromptEnabled(enabled: boolean)
	if _previewPrompt then
		_previewPrompt.Enabled = enabled == true
	end
end

--[[
	挂载 SurfaceGui + VideoFrame 到 Screen（不 AlwaysOnTop；背景全透明）
	@param player Player - 本地玩家
	@param screen BasePart - Screen
	@param face Enum.NormalId - SurfaceGui 朝向
]]
local function attachPreviewSurface(player: Player, screen: BasePart, face: Enum.NormalId)
	local surfaceGui = Instance.new("SurfaceGui")
	surfaceGui.Name = "ShortVideoTrainPreviewGui"
	surfaceGui.Adornee = screen
	surfaceGui.Face = face
	surfaceGui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	surfaceGui.PixelsPerStud = PREVIEW_PIXELS_PER_STUD
	surfaceGui.LightInfluence = 0
	surfaceGui.Active = false
	surfaceGui.AlwaysOnTop = false
	surfaceGui.Parent = player:WaitForChild("PlayerGui")
	_previewSurfaceGui = surfaceGui

	local root = Instance.new("Frame")
	root.Name = "Root"
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	root.Parent = surfaceGui

	-- 交互入口只做吸引，不放声音；正式 Open 的 VideoFrame 默认有声
	_previewVideo = createPreviewVideoOnRoot(root)
end

--[[
	创建场景商店同款 Custom ProximityPrompt（E）
	@param screen BasePart - 挂载点
	@param player Player - 本地玩家
	@param promptCfg any - Prompt 配置
]]
local function attachPreviewPrompt(screen: BasePart, player: Player, promptCfg: any)
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "WatchShortVideo"
	prompt.MaxActivationDistance = tonumber(promptCfg.MaxActivationDistance) or 12
	prompt.HoldDuration = tonumber(promptCfg.HoldDuration) or 0.1
	prompt.RequiresLineOfSight = promptCfg.RequiresLineOfSight == true
	prompt.KeyboardKeyCode = promptCfg.KeyboardKeyCode or Enum.KeyCode.E
	prompt.Style = Enum.ProximityPromptStyle.Custom
	prompt.Parent = screen
	_previewPrompt = prompt

	local utils = tryGetUtils()
	local TranslationHelper = utils and utils.TranslationHelper
	local AddListen = utils and utils.AddListen
	if TranslationHelper and type(TranslationHelper.SetText) == "function" then
		TranslationHelper.SetText(prompt, "观看")
	else
		prompt.ActionText = "观看"
		prompt.ObjectText = ""
	end

	local function onTriggered(who: Player)
		if who ~= player then
			return
		end
		local cb = _previewOnTriggered
		if cb then
			cb()
		end
	end

	if AddListen and type(AddListen.AddProximityPrompt) == "function" then
		_previewPromptConn = AddListen.AddProximityPrompt(prompt, onTriggered)
	else
		_previewPromptConn = prompt.Triggered:Connect(onTriggered)
	end
end

--[[
	显示预览传送门（单例：已存在则只更新位姿与回调）
	@param options { boardCFrame: CFrame, onTriggered: (() -> ())?, cfg: any? }
]]
function TrainPreview.Show(options: any)
	if typeof(options) ~= "table" or typeof(options.boardCFrame) ~= "CFrame" then
		warn("[SceneBoard.TrainPreview] Show requires boardCFrame")
		return
	end
	local player = Players.LocalPlayer
	if not player then
		return
	end

	local cfg = options.cfg or Constants.TrainPreview
	local onTriggered = if typeof(options.onTriggered) == "function" then options.onTriggered else nil
	_previewOnTriggered = onTriggered

	local scaleAnim = cfg.ScaleAnim or {}
	local appearFrom = tonumber(scaleAnim.AppearFrom) or 0.1
	local appearTo = tonumber(scaleAnim.AppearTo) or 1
	local duration = tonumber(scaleAnim.Duration) or 0.3

	if _previewAlive and _previewModel and _previewModel.Parent and not _previewHiding then
		_previewModel:PivotTo(options.boardCFrame)
		TrainPreview.SetPromptEnabled(true)
		TrainPreview.SetPlaying(true)
		return
	end

	-- 隐藏动画中再次 Show：打断并重建
	destroyPreviewInternal()
	_previewAlive = true
	_previewHiding = false
	_previewPlaying = true
	_previewOnTriggered = onTriggered

	local portalPath = tostring(cfg.PortalModelPath or "ModelRes/视频传送门")
	local model = clonePortalModel(portalPath)
	if not model then
		warn("[SceneBoard.TrainPreview] portal model missing:", portalPath)
		destroyPreviewInternal()
		return
	end

	local screenName = tostring(cfg.ScreenPartName or "Screen")
	local screen = model:FindFirstChild(screenName, true)
	if not screen or not screen:IsA("BasePart") then
		warn("[SceneBoard.TrainPreview] Screen part missing:", screenName)
		model:Destroy()
		destroyPreviewInternal()
		return
	end

	local folder = Instance.new("Folder")
	folder.Name = PREVIEW_FOLDER_NAME
	folder.Parent = Workspace
	_previewFolder = folder

	preparePortalParts(model, screen)
	model.Name = "视频传送门"
	model:PivotTo(options.boardCFrame)
	pcall(function()
		model:ScaleTo(appearFrom)
	end)
	model.Parent = folder
	_previewModel = model

	local face = cfg.SurfaceFace or Enum.NormalId.Left
	attachPreviewSurface(player, screen, face)
	attachPreviewPrompt(screen, player, cfg.Prompt or {})

	animateScale(model, appearFrom, appearTo, duration, Enum.EasingDirection.Out, nil)

	local folderRemotes = Remotes.Wait()
	SocialClient.Bind(folderRemotes)
	_previewListConn = SocialClient.OnListUpdated(onPreviewListPayload)
	SocialClient.RequestList()
end

--[[
	销毁预览传送门（先 Back-In 缩放到 HideTo，再清理）
]]
function TrainPreview.Destroy()
	if not _previewAlive then
		destroyPreviewInternal()
		return
	end
	if _previewHiding then
		return
	end
	_previewHiding = true
	TrainPreview.SetPromptEnabled(false)
	TrainPreview.SetPlaying(false)

	local model = _previewModel
	local cfg = Constants.TrainPreview
	local scaleAnim = cfg.ScaleAnim or {}
	local hideTo = tonumber(scaleAnim.HideTo) or 0.1
	local duration = tonumber(scaleAnim.Duration) or 0.3
	if not model or not model.Parent then
		destroyPreviewInternal()
		return
	end

	local fromScale = hideTo
	local ok, cur = pcall(function()
		return model:GetScale()
	end)
	if ok and typeof(cur) == "number" then
		fromScale = cur
	else
		fromScale = tonumber(scaleAnim.HideFrom) or 1
	end

	animateScale(model, fromScale, hideTo, duration, Enum.EasingDirection.In, function()
		destroyPreviewInternal()
	end)
end

SceneBoard.TrainPreview = TrainPreview

return SceneBoard