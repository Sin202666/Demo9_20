--[[
	Module: Preload
	Description: 序列图片预载、批量预载、异步预载与暖场
	Author: 林奥宇
	Created: 2026-07-31
	Last Modified: 2026-09-01

	约定：
	- onReady 仅在预载（及可选暖场）成功路径触发；失败 / 取消不调用
	- PreloadAsync 的 cancel：抑制 onComplete/onReady，并 Stop 已启动的暖场播放
	- ContentProvider:PreloadAsync 无法中断（引擎限制）
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local Log = Utils.Log
local RunService = Utils.RunService
local ContentProvider = Utils.ContentProvider
local Players = Utils.Players

local Types = require(script.Parent.Types)
local Catalog = require(script.Parent.Catalog)
local Playback = require(script.Parent.Playback)

type ImageLabel = typeof(workspace:FindFirstChildOfClass("ImageLabel"))
type SequenceFrameData = Types.SequenceFrameData
type PreloadOptions = Types.PreloadOptions
type PlaybackHandle = Types.PlaybackHandle

-- 异步预载会话：cancel 可停暖场
type PreloadSession = {
	cancelled: boolean,
	handle: PlaybackHandle?,
	image: ImageLabel?,
}

local Preload = {}

local preloadedImages: { [string]: boolean } = {}

--[[
	是否为客户端运行环境
	@return boolean - true 表示客户端
]]
local function _isClient(): boolean
	return RunService:IsClient()
end

--[[
	停止并销毁暖场实例（cancel / 失败共用）
	@param session PreloadSession? - 异步会话
]]
local function _abortWarmup(session: PreloadSession?): ()
	if not session then
		return
	end
	local handle = session.handle
	local image = session.image
	session.handle = nil
	session.image = nil
	if handle then
		Playback.StopHandle(handle, Types.StopPolicy.Keep)
	elseif image then
		Playback.StopSequence(image, Types.StopPolicy.Keep)
	end
	if image and image.Parent then
		image:Destroy()
	end
end

--[[
	清空已预载 ImageId 标记（目录热更后须调用，避免跳过新资源）
]]
function Preload.ClearImageCache(): ()
	table.clear(preloadedImages)
end

--[[
	销毁临时 SequencePreloadGui（Shutdown / 热重载可选）
]]
function Preload.DestroyPreloadGui(): ()
	local localPlayer: Player? = Players.LocalPlayer
	if not localPlayer then
		return
	end
	local playerGui: Instance? = localPlayer:FindFirstChild(Types.PLAYER_GUI_NAME)
	if not playerGui then
		return
	end
	local gui = playerGui:FindFirstChild(Types.PRELOAD_GUI_NAME)
	if gui then
		gui:Destroy()
	end
end

--[[
	获取预载用父节点（任意 ScreenGui；不存在则创建临时 Gui）
	@return Instance? - 可挂临时 ImageLabel 的父级
]]
local function _getPreloadParent(): Instance?
	local localPlayer: Player? = Players.LocalPlayer
	if not localPlayer then
		return nil
	end

	local playerGui: Instance? = localPlayer:FindFirstChild(Types.PLAYER_GUI_NAME)
	if not playerGui then
		return nil
	end

	local existing: Instance? = playerGui:FindFirstChildOfClass("ScreenGui")
	if existing then
		return existing
	end

	local preloadGui: ScreenGui = Instance.new("ScreenGui")
	preloadGui.Name = Types.PRELOAD_GUI_NAME
	preloadGui.ResetOnSpawn = false
	preloadGui.Enabled = false
	preloadGui.Parent = playerGui
	return preloadGui
end

--[[
	创建隐藏暖场 ImageLabel 并 PlaySequence（播完 Destroy；失败不调 onReady）
	@param sequenceName string - 序列名
	@param opts PreloadOptions - 已默认化选项
	@param session PreloadSession? - 异步会话
	@param onReady (() -> ())? - 成功回调
	@return boolean - true 暖场已开播
	@return string? - 失败时的 ErrorCode
]]
local function _startWarmup(
	sequenceName: string,
	opts: PreloadOptions,
	session: PreloadSession?,
	onReady: (() -> ())?
): (boolean, string?)
	local preloadParent: Instance? = _getPreloadParent()
	if not preloadParent then
		Log.warn("[SequenceManager] 未找到 PlayerGui，跳过暖场")
		if opts.strictWarmup then
			-- 严格暖场失败：不触发 onReady（避免假就绪）
			return false, Types.ErrorCode.NO_PLAYER_GUI
		end
		if onReady then
			task.spawn(onReady)
		end
		return true, nil
	end

	local warmupFps = if opts.fps and opts.fps > 0 then opts.fps else Types.DEFAULT_WARMUP_FPS
	local preloadImage: ImageLabel = Instance.new("ImageLabel")
	preloadImage.Name = Types.WARMUP_IMAGE_NAME
	preloadImage.BackgroundTransparency = 1
	preloadImage.ImageTransparency = 1
	preloadImage.Visible = false
	preloadImage.Size = UDim2.fromOffset(1, 1)
	preloadImage.Parent = preloadParent

	if session then
		session.image = preloadImage
	end

	-- forceVisible=false：避免 ApplyCurrentFrame 每帧把 Visible 拉回 true
	local playOk, playErr, handle = Playback.PlaySequence(preloadImage, sequenceName, {
		fps = warmupFps,
		loop = false,
		forceVisible = false,
		stopPolicy = Types.StopPolicy.Keep,
		onComplete = function()
			if session and session.cancelled then
				if preloadImage.Parent then
					preloadImage:Destroy()
				end
				return
			end
			if preloadImage.Parent then
				preloadImage:Destroy()
			end
			if session then
				session.handle = nil
				session.image = nil
			end
			if onReady then
				task.spawn(onReady)
			end
		end,
	})

	if session then
		session.handle = handle
	end

	if session and session.cancelled then
		_abortWarmup(session)
		return false, Types.ErrorCode.ABORTED
	end

	-- 成功必须有 handle；失败不调 onReady
	if not playOk or not handle then
		if preloadImage.Parent then
			preloadImage:Destroy()
		end
		if session then
			session.handle = nil
			session.image = nil
		end
		return false, playErr or Types.ErrorCode.PRELOAD_FAILED
	end

	return true, nil
end

--[[
	通过 ContentProvider 预加载序列内图片资源（同步等待）
	@param sequenceName string - 序列名称
	@return boolean - true 预载成功或无需预载；false 失败
	@return string? - 失败时的 ErrorCode
]]
function Preload.PreloadImages(sequenceName: string): (boolean, string?)
	if not _isClient() then
		Log.warn("[SequenceManager] 仅客户端可用")
		return false, Types.ErrorCode.NOT_CLIENT
	end

	local sequenceData: SequenceFrameData? = Catalog.GetSequenceData(sequenceName)
	if not sequenceData or sequenceData.count == 0 then
		Log.warn("[SequenceManager] 不存在资源:", sequenceName)
		return false, Types.ErrorCode.NOT_FOUND
	end

	local imagesToPreload: { string } = {}
	if sequenceData.kind == Types.SequenceKind.Sheet and sequenceData.sheet then
		local imageId = sequenceData.sheet.imageId
		if imageId ~= "" and not preloadedImages[imageId] then
			table.insert(imagesToPreload, imageId)
		end
	else
		for _, imageId: string in ipairs(sequenceData.frames) do
			if imageId ~= "" and not preloadedImages[imageId] then
				table.insert(imagesToPreload, imageId)
			end
		end
	end

	if #imagesToPreload == 0 then
		return true, nil
	end

	local ok, err = pcall(function()
		ContentProvider:PreloadAsync(imagesToPreload)
	end)

	if not ok then
		Log.warn("[SequenceManager] PreloadAsync 失败:", sequenceName, err)
		return false, Types.ErrorCode.PRELOAD_FAILED
	end

	for _, imageId: string in ipairs(imagesToPreload) do
		preloadedImages[imageId] = true
	end

	return true, nil
end

--[[
	预加载序列资源（同步等待 ContentProvider）；可选播完即停的暖场
	@param sequenceName string - 序列名称
	@param options PreloadOptions? - warmup / fps / onReady / strictWarmup
	@param session PreloadSession? - 仅 PreloadAsync 传入；用于 cancel 停暖场
	@return boolean - true 预载成功；false 失败或已取消
	@return string? - 失败时的 ErrorCode
]]
function Preload.Preload(
	sequenceName: string,
	options: PreloadOptions?,
	session: PreloadSession?
): (boolean, string?)
	if not _isClient() then
		Log.warn("[SequenceManager] 仅客户端可用")
		return false, Types.ErrorCode.NOT_CLIENT
	end

	if typeof(sequenceName) ~= "string" or sequenceName == "" then
		return false, Types.ErrorCode.INVALID_ARG
	end

	if session and session.cancelled then
		return false, Types.ErrorCode.ABORTED
	end

	local preloadOk, preloadErr = Preload.PreloadImages(sequenceName)
	if not preloadOk then
		return false, preloadErr
	end

	if session and session.cancelled then
		return false, Types.ErrorCode.ABORTED
	end

	local opts = options or {}
	local onReady = opts.onReady

	if not opts.warmup then
		if onReady then
			task.spawn(onReady)
		end
		return true, nil
	end

	return _startWarmup(sequenceName, opts, session, onReady)
end

--[[
	异步预载（立即返回；完成后回调 onComplete / onReady）
	@param sequenceName string - 序列名称
	@param options PreloadOptions? - 同 Preload，另支持 onComplete(ok, err)
	@return boolean - true 已调度；false 参数/环境无效
	@return string? - 失败时的 ErrorCode（仅调度失败）
	@return (() -> ())? - 取消函数；抑制回调，并 Stop 已启动的暖场（ContentProvider 无法中断）
]]
function Preload.PreloadAsync(sequenceName: string, options: PreloadOptions?): (boolean, string?, (() -> ())?)
	if not _isClient() then
		Log.warn("[SequenceManager] 仅客户端可用")
		return false, Types.ErrorCode.NOT_CLIENT, nil
	end

	if typeof(sequenceName) ~= "string" or sequenceName == "" then
		return false, Types.ErrorCode.INVALID_ARG, nil
	end

	local opts = options or {}
	local session: PreloadSession = {
		cancelled = false,
		handle = nil,
		image = nil,
	}

	task.spawn(function()
		local ok, err = Preload.Preload(sequenceName, opts, session)
		if session.cancelled then
			return
		end
		if opts.onComplete then
			opts.onComplete(ok, err)
		end
	end)

	--[[
		抑制回调并 Stop 已启动的暖场（ContentProvider:PreloadAsync 无法中断）
	]]
	local function _cancel(): ()
		if session.cancelled then
			return
		end
		session.cancelled = true
		_abortWarmup(session)
	end

	return true, nil, _cancel
end

--[[
	批量同步预载多个序列的图片（不含暖场）
	@param sequenceNames { string } - 序列名列表
	@param options PreloadOptions? - onProgress(done, total, name)
	@return boolean - true 全部成功
	@return string? - 失败时的 ErrorCode
]]
function Preload.PreloadMany(sequenceNames: { string }, options: PreloadOptions?): (boolean, string?)
	if not _isClient() then
		Log.warn("[SequenceManager] 仅客户端可用")
		return false, Types.ErrorCode.NOT_CLIENT
	end

	if typeof(sequenceNames) ~= "table" then
		return false, Types.ErrorCode.INVALID_ARG
	end

	local opts = options or {}
	local total = #sequenceNames
	for index, sequenceName in ipairs(sequenceNames) do
		if typeof(sequenceName) ~= "string" or sequenceName == "" then
			return false, Types.ErrorCode.INVALID_ARG
		end
		local ok, err = Preload.PreloadImages(sequenceName)
		if not ok then
			return false, err
		end
		if opts.onProgress then
			task.spawn(opts.onProgress, index, total, sequenceName)
		end
	end

	return true, nil
end

return Preload
