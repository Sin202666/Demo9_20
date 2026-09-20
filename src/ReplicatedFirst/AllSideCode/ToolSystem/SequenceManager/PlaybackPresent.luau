--[[
	Module: PlaybackPresent
	Description: 序列表现层（Swap / Crossfade / CloneAll）与层透明度
	Author: 林奥宇
	Created: 2026-07-31
	Last Modified: 2026-09-01

	与 playMode（Forward/PingPong）正交：只负责「这一帧怎么画到屏幕上」。
	- Swap：单控件硬切
	- Crossfade：bufferA=目标；bufferB=同级轻量 ImageLabel（拷布局+ImageColor3，不 Clone 子树）
	- CloneAll：每帧一个同级轻量控件，切 Visible（仅 Images；图集请用 Swap）
	Crossfade 叠化用墙钟 dt（不受 speed 影响）。
	注意：bufferB / Clone 均为 ImageLabel；主控件若为 ImageButton，点击命中仍在主控件（CloneAll 时主控件隐藏则不可点）。
	播放中通过 SyncPeersFromPrimary 跟随主控件 Size/Position/Rotation/ZIndex/ImageColor3 等布局变化。
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Log = Utils.Log

local Types = require(script.Parent.Types)
local PlaybackVisual = require(script.Parent.PlaybackVisual)
local PeerPool = require(script.Parent.PeerPool)

type ImageTarget = GuiObject
type PresentState = Types.PlaybackState

local PlaybackPresent = {}

-- ============================================================================
-- 私有函数
-- ============================================================================

--[[
	将源控件布局拷到轻量 ImageLabel（不含子树；含 ImageColor3）
	@param source GuiObject - 布局来源
	@param target ImageLabel - 写入目标
]]
local function _copyLayoutToImageLabel(source: GuiObject, target: ImageLabel): ()
	target.Size = source.Size
	target.Position = source.Position
	target.AnchorPoint = source.AnchorPoint
	target.Rotation = source.Rotation
	target.ZIndex = source.ZIndex
	target.LayoutOrder = source.LayoutOrder
	target.SizeConstraint = source.SizeConstraint
	target.BorderSizePixel = source.BorderSizePixel
	target.BackgroundTransparency = 1
	target.BackgroundColor3 = Color3.new(0, 0, 0)

	if source:IsA("ImageLabel") or source:IsA("ImageButton") then
		local img = source :: any
		target.ScaleType = img.ScaleType
		target.ResampleMode = img.ResampleMode
		target.SliceCenter = img.SliceCenter
		target.SliceScale = img.SliceScale
		target.TileSize = img.TileSize
		target.ImageColor3 = img.ImageColor3
	end
end

--[[
	同步副缓冲布局到主控件当前布局（叠化/切帧前调用）
	@param source GuiObject - 主控件
	@param target ImageLabel - 副缓冲或克隆帧
]]
local function _syncPeerLayout(source: GuiObject, target: ImageLabel): ()
	_copyLayoutToImageLabel(source, target)
end

--[[
	创建同级轻量 ImageLabel（优先对象池）
	@param source GuiObject - 布局与父级来源
	@param name string - 实例名
	@return ImageLabel? - 成功时非 nil
]]
local function _createPeerImageLabel(source: GuiObject, name: string): ImageLabel?
	return PeerPool.Acquire(source, name, _copyLayoutToImageLabel)
end

--[[
	确保 Crossfade 副缓冲存在（轻量 ImageLabel，同步布局；按 presentId 命名）
	@param imageTarget GuiObject - 主缓冲（bufferA）
	@param presentId string - 播世代唯一 id
	@return ImageLabel? - 副缓冲；父级无效时 nil
]]
local function _ensureCrossfadeBufferB(imageTarget: GuiObject, presentId: string): ImageLabel?
	local parent = imageTarget.Parent
	if not parent then
		return nil
	end

	local bufferName = Types.CROSSFADE_BUFFER_B_PREFIX .. "_" .. presentId
	local existing = parent:FindFirstChild(bufferName)
	if existing and existing:IsA("ImageLabel") then
		local bufferB = existing :: ImageLabel
		_syncPeerLayout(imageTarget, bufferB)
		return bufferB
	end

	return _createPeerImageLabel(imageTarget, bufferName)
end

--[[
	为 CloneAll 创建每帧轻量控件
	@param imageTarget GuiObject - 主控件（播时隐藏）
	@param state PresentState - 写入 clones
	@return boolean - true 就绪
	@return string? - 失败 ErrorCode
]]
local function _setupCloneAll(imageTarget: GuiObject, state: PresentState): (boolean, string?)
	if state.kind ~= Types.SequenceKind.Images then
		return false, Types.ErrorCode.PRESENT_FAILED
	end

	if #state.frames > Types.MAX_CLONE_ALL_FRAMES then
		Log.warn(
			"[SequenceManager] CloneAll 超过帧数上限",
			Types.MAX_CLONE_ALL_FRAMES,
			"请改用 Swap/Crossfade"
		)
		return false, Types.ErrorCode.PRESENT_FAILED
	end

	local parent = imageTarget.Parent
	if not parent then
		return false, Types.ErrorCode.PRESENT_FAILED
	end

	local clones: { ImageLabel } = {}
	for i, imageId in ipairs(state.frames) do
		local cloneName = Types.CLONE_NAME_PREFIX .. "_" .. state.presentId .. "_" .. tostring(i)
		local existing = parent:FindFirstChild(cloneName)
		local peer: ImageLabel?
		if existing and existing:IsA("ImageLabel") then
			peer = existing :: ImageLabel
			_syncPeerLayout(imageTarget, peer)
		else
			peer = _createPeerImageLabel(imageTarget, cloneName)
		end
		if not peer then
			for _, created in ipairs(clones) do
				PeerPool.Release(created)
			end
			return false, Types.ErrorCode.PRESENT_FAILED
		end
		peer.Image = imageId
		peer.ImageRectOffset = Vector2.zero
		peer.ImageRectSize = Vector2.zero
		peer.Visible = false
		peer.ImageTransparency = 1
		clones[i] = peer
	end

	state.clones = clones
	state.nowShow = nil
	imageTarget.Visible = false
	if imageTarget:IsA("ImageLabel") or imageTarget:IsA("ImageButton") then
		(imageTarget :: any).Image = ""
	end
	return true, nil
end

--[[
	CloneAll：显示指定帧克隆（先同步布局/色调到主控件）
	@param state PresentState - 播放状态
	@param frameIndex number - 1-based 帧
]]
local function _showCloneFrame(state: PresentState, frameIndex: number): ()
	local clones = state.clones
	if not clones then
		return
	end
	if state.nowShow then
		state.nowShow.Visible = false
	end
	local nextShow = clones[frameIndex]
	if not nextShow then
		return
	end
	local primary = state.bufferA
	if primary then
		_syncPeerLayout(primary, nextShow)
	end
	nextShow.ImageTransparency = state.layerTransparency
	nextShow.Visible = true
	state.nowShow = nextShow
end

--[[
	清理 CloneAll 克隆（归还对象池）
	@param state PresentState - 播放状态
]]
local function _cleanupClones(state: PresentState): ()
	local clones = state.clones
	if clones then
		for _, cloneImage in ipairs(clones) do
			PeerPool.Release(cloneImage)
		end
	end
	state.clones = nil
	state.nowShow = nil
end

-- ============================================================================
-- 公共函数
-- ============================================================================

--[[
	将主控件当前布局/ImageColor3 同步到 Crossfade bufferB 或 CloneAll 克隆
	Swap 无 peer，直接返回；暂停时也可调用（跟随 UI 缩放）
	@param imageTarget GuiObject - 主控件（bufferA）
	@param state PresentState - 播放状态
]]
function PlaybackPresent.SyncPeersFromPrimary(imageTarget: GuiObject, state: PresentState): ()
	if state.presentMode == Types.PresentMode.Swap then
		return
	end

	state.bufferA = imageTarget

	if state.presentMode == Types.PresentMode.Crossfade then
		local bufferB = state.bufferB
		if bufferB then
			_syncPeerLayout(imageTarget, bufferB)
		end
		return
	end

	if state.presentMode == Types.PresentMode.CloneAll then
		local clones = state.clones
		if not clones then
			return
		end
		-- 仅同步当前可见帧，避免每 tick 扫全部克隆
		if state.nowShow then
			_syncPeerLayout(imageTarget, state.nowShow)
		end
	end
end

--[[
	应用层透明度到当前非叠化显示体
	@param state PresentState - 播放状态
]]
function PlaybackPresent.ApplyLayerTransparency(state: PresentState): ()
	local transparency = state.layerTransparency

	if state.presentMode == Types.PresentMode.CloneAll then
		if state.nowShow then
			state.nowShow.ImageTransparency = transparency
		end
		return
	end

	if state.presentMode == Types.PresentMode.Swap then
		if state.bufferA and (state.bufferA:IsA("ImageLabel") or state.bufferA:IsA("ImageButton")) then
			(state.bufferA :: any).ImageTransparency = transparency
		end
		return
	end

	if state.crossfading then
		return
	end

	local active: GuiObject? = if state.activeIsA then state.bufferA else state.bufferB
	local inactive: GuiObject? = if state.activeIsA then state.bufferB else state.bufferA
	if active and (active:IsA("ImageLabel") or active:IsA("ImageButton")) then
		(active :: any).ImageTransparency = transparency
		active.Visible = true
	end
	if inactive then
		if inactive:IsA("ImageLabel") or inactive:IsA("ImageButton") then
			(inactive :: any).ImageTransparency = 1
		end
		inactive.Visible = false
	end
end

--[[
	若当前画面在 bufferB，先压回主控件再销毁副缓冲
	@param imageTarget GuiObject - 主控件（bufferA）
	@param state PresentState - 播放状态
]]
local function _flattenToPrimary(imageTarget: GuiObject, state: PresentState): ()
	if state.presentMode ~= Types.PresentMode.Crossfade then
		return
	end
	if state.activeIsA and not state.crossfading then
		return
	end

	PlaybackVisual.ApplyFrameContent(imageTarget, state, state.currentFrame)
	if imageTarget:IsA("ImageLabel") or imageTarget:IsA("ImageButton") then
		(imageTarget :: any).ImageTransparency = state.layerTransparency
	end
	if state.forceVisible or imageTarget.Visible or (state.bufferB and state.bufferB.Visible) then
		imageTarget.Visible = true
	end
end

--[[
	清理表现层副资源（Crossfade bufferB / CloneAll 克隆）
	@param imageTarget GuiObject - 主控件
	@param state PresentState - 播放状态
]]
function PlaybackPresent.Cleanup(imageTarget: GuiObject, state: PresentState): ()
	if state.presentMode == Types.PresentMode.CloneAll then
		-- 先压回主控件，避免 Keep 后主控件仍为空图
		PlaybackVisual.ApplyFrameContent(imageTarget, state, state.currentFrame)
		if imageTarget:IsA("ImageLabel") or imageTarget:IsA("ImageButton") then
			(imageTarget :: any).ImageTransparency = state.layerTransparency
		end
		if state.forceVisible or (state.nowShow and state.nowShow.Visible) then
			imageTarget.Visible = true
		end
		_cleanupClones(state)
	else
		_flattenToPrimary(imageTarget, state)
		local bufferB = state.bufferB
		if bufferB then
			PeerPool.Release(bufferB)
		end
	end

	state.bufferB = nil
	state.bufferA = nil
	state.crossfading = false
	state.crossfadeElapsed = 0
	state.activeIsA = true
end

--[[
	为播放准备表现层
	@param imageTarget GuiObject - 播放目标（兼 bufferA）
	@param state PresentState - 写入 buffer / clones
	@return boolean - true 就绪
	@return string? - 失败时的 ErrorCode
]]
function PlaybackPresent.Setup(imageTarget: GuiObject, state: PresentState): (boolean, string?)
	state.bufferA = imageTarget
	state.bufferB = nil
	state.clones = nil
	state.nowShow = nil
	state.crossfading = false
	state.crossfadeElapsed = 0
	state.activeIsA = true

	if state.presentMode == Types.PresentMode.CloneAll then
		return _setupCloneAll(imageTarget, state)
	end

	if state.presentMode ~= Types.PresentMode.Crossfade then
		return true, nil
	end

	local bufferB = _ensureCrossfadeBufferB(imageTarget, state.presentId)
	if not bufferB then
		return false, Types.ErrorCode.PRESENT_FAILED
	end

	state.bufferB = bufferB
	return true, nil
end

--[[
	是否处于 Crossfade 叠化中
	@param state PresentState - 播放状态
	@return boolean - true 表示忙
]]
function PlaybackPresent.IsBusy(state: PresentState): boolean
	return state.presentMode == Types.PresentMode.Crossfade and state.crossfading
end

--[[
	开始 Crossfade 切到目标帧
	@param state PresentState - 播放状态
	@param targetFrame number - 目标帧（1-based）
]]
local function _beginCrossfade(state: PresentState, targetFrame: number): ()
	local fromBuf: GuiObject? = if state.activeIsA then state.bufferA else state.bufferB
	local toBuf: GuiObject? = if state.activeIsA then state.bufferB else state.bufferA
	if not fromBuf or not toBuf then
		return
	end

	if state.bufferA and state.bufferB then
		_syncPeerLayout(state.bufferA, state.bufferB)
	end

	PlaybackVisual.ApplyFrameContent(toBuf, state, targetFrame)
	toBuf.Visible = true
	if toBuf:IsA("ImageLabel") or toBuf:IsA("ImageButton") then
		(toBuf :: any).ImageTransparency = 1
	end
	fromBuf.Visible = true
	if fromBuf:IsA("ImageLabel") or fromBuf:IsA("ImageButton") then
		(fromBuf :: any).ImageTransparency = state.layerTransparency
	end

	state.currentFrame = targetFrame
	state.crossfadeElapsed = 0
	state.crossfading = true

	if state.crossfadeSec <= 0 then
		if fromBuf:IsA("ImageLabel") or fromBuf:IsA("ImageButton") then
			(fromBuf :: any).ImageTransparency = 1
		end
		fromBuf.Visible = false
		if toBuf:IsA("ImageLabel") or toBuf:IsA("ImageButton") then
			(toBuf :: any).ImageTransparency = state.layerTransparency
		end
		state.activeIsA = not state.activeIsA
		state.crossfading = false
	end
end

--[[
	推进 Crossfade 叠化（墙钟秒，不受 playback speed 缩放）
	@param state PresentState - 播放状态
	@param deltaTime number - Heartbeat dt（未乘 speed）
	@return boolean - true 表示仍在叠化
]]
function PlaybackPresent.Tick(state: PresentState, deltaTime: number): boolean
	if not PlaybackPresent.IsBusy(state) then
		return false
	end

	-- 叠化期间跟随主控件布局/色调（bufferA 为权威）
	if state.bufferA and state.bufferB then
		_syncPeerLayout(state.bufferA, state.bufferB)
	end

	state.crossfadeElapsed += deltaTime
	local duration = math.max(state.crossfadeSec, Types.MIN_CROSSFADE_SEC)
	local t = math.clamp(state.crossfadeElapsed / duration, 0, 1)
	local layerT = state.layerTransparency

	local fromBuf: GuiObject? = if state.activeIsA then state.bufferA else state.bufferB
	local toBuf: GuiObject? = if state.activeIsA then state.bufferB else state.bufferA
	if fromBuf and (fromBuf:IsA("ImageLabel") or fromBuf:IsA("ImageButton")) then
		(fromBuf :: any).ImageTransparency = layerT + (1 - layerT) * t
	end
	if toBuf and (toBuf:IsA("ImageLabel") or toBuf:IsA("ImageButton")) then
		(toBuf :: any).ImageTransparency = 1 - (1 - layerT) * t
	end

	if t >= 1 then
		if fromBuf then
			if fromBuf:IsA("ImageLabel") or fromBuf:IsA("ImageButton") then
				(fromBuf :: any).ImageTransparency = 1
			end
			fromBuf.Visible = false
		end
		if toBuf then
			if toBuf:IsA("ImageLabel") or toBuf:IsA("ImageButton") then
				(toBuf :: any).ImageTransparency = layerT
			end
			toBuf.Visible = true
		end
		state.activeIsA = not state.activeIsA
		state.crossfading = false
		state.crossfadeElapsed = 0
		return false
	end

	return true
end

--[[
	展示当前帧：Swap / Crossfade / CloneAll
	@param imageTarget GuiObject - 播放目标
	@param state PresentState - 播放状态（currentFrame 已更新）
	@param isInitial boolean - true 表示开播首帧（不做叠化）
]]
function PlaybackPresent.ShowCurrentFrame(imageTarget: GuiObject, state: PresentState, isInitial: boolean): ()
	state.bufferA = imageTarget

	if state.presentMode == Types.PresentMode.CloneAll then
		_showCloneFrame(state, state.currentFrame)
		return
	end

	if state.presentMode == Types.PresentMode.Crossfade then
		if isInitial then
			PlaybackVisual.ApplyFrameContent(imageTarget, state, state.currentFrame)
			if imageTarget:IsA("ImageLabel") or imageTarget:IsA("ImageButton") then
				(imageTarget :: any).ImageTransparency = state.layerTransparency
			end
			if state.forceVisible then
				imageTarget.Visible = true
			end
			local bufferB = state.bufferB
			if bufferB then
				_syncPeerLayout(imageTarget, bufferB)
				bufferB.Visible = false
				bufferB.ImageTransparency = 1
			end
			state.activeIsA = true
			state.crossfading = false
			return
		end
		_beginCrossfade(state, state.currentFrame)
		return
	end

	PlaybackVisual.ApplyCurrentFrame(imageTarget, state)
end

return PlaybackPresent
