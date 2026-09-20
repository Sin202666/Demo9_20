--[[
	Module: PlaybackVisual
	Description: 帧画面写入、停止外观恢复、帧回调触发（与表现层 Present 解耦）
	Author: 林奥宇
	Created: 2026-07-31
	Last Modified: 2026-09-01
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local Log = Utils.Log

local Types = require(script.Parent.Types)
local PlaybackRegistry = require(script.Parent.PlaybackRegistry)

type ImageTarget = GuiObject
type StopPolicyValue = Types.StopPolicyValue
type VisualState = Types.PlaybackState

local PlaybackVisual = {}

--[[
	安全执行用户回调（失败只打日志，不向外抛）
	@param fn () -> () - 回调体
]]
local function _safeFire(fn: () -> ()): ()
	local ok, err = pcall(fn)
	if not ok then
		Log.warn("[SequenceManager] 帧回调异常:", err)
	end
end

--[[
	触发帧回调与 markers（切到该帧时）
	Sync：同帧同步执行（默认）；Deferred：task.spawn
	Deferred / Sync 均在执行前校验世代，避免停播或重播后旧回调误操作
	@param imageTarget GuiObject - 播放目标（世代校验）
	@param state VisualState - 播放状态
	@param frame number - 当前帧
]]
function PlaybackVisual.FireFrameCallbacks(imageTarget: ImageTarget, state: VisualState, frame: number): ()
	local function fire(): ()
		if not PlaybackRegistry.IsActive(imageTarget, state) then
			return
		end
		if state.onFrame then
			state.onFrame(frame)
		end
		local markers = state.markers
		if markers then
			local markerFn = markers[frame]
			if markerFn then
				markerFn()
			end
		end
	end

	if state.callbackMode == Types.CallbackMode.Deferred then
		task.spawn(_safeFire, fire)
	else
		_safeFire(fire)
	end
end

--[[
	将指定帧的 Image / ImageRect 写入任意 ImageLabel / ImageButton（不含 Visible / Transparency）
	@param target GuiObject - 写入目标（可为 Crossfade 副缓冲）
	@param state VisualState - 含 kind / frames / sheet
	@param frame number - 1-based 帧下标
]]
function PlaybackVisual.ApplyFrameContent(target: ImageTarget, state: VisualState, frame: number): ()
	if not (target:IsA("ImageLabel") or target:IsA("ImageButton")) then
		return
	end
	local img = target :: any

	if state.kind == Types.SequenceKind.Sheet and state.sheet then
		local sheet = state.sheet
		local index0 = frame - 1
		local col = index0 % sheet.columns
		local row = math.floor(index0 / sheet.columns)
		local padding = sheet.padding or 0
		local spacing = sheet.spacing or 0
		img.Image = sheet.imageId
		img.ImageRectOffset = Vector2.new(
			padding + col * (sheet.cellWidth + spacing),
			padding + row * (sheet.cellHeight + spacing)
		)
		img.ImageRectSize = Vector2.new(sheet.cellWidth, sheet.cellHeight)
	else
		img.Image = state.frames[frame] or ""
		img.ImageRectOffset = Vector2.zero
		img.ImageRectSize = Vector2.zero
	end
end

--[[
	将当前帧写入主控件（Swap 路径；含 forceVisible 与层透明度）
	@param imageTarget GuiObject - 目标
	@param state VisualState - 播放状态
]]
function PlaybackVisual.ApplyCurrentFrame(imageTarget: ImageTarget, state: VisualState): ()
	PlaybackVisual.ApplyFrameContent(imageTarget, state, state.currentFrame)
	if imageTarget:IsA("ImageLabel") or imageTarget:IsA("ImageButton") then
		(imageTarget :: any).ImageTransparency = state.layerTransparency
	end
	if state.forceVisible then
		imageTarget.Visible = true
	end
end

--[[
	按策略恢复或清理目标外观（含 ImageTransparency）
	@param imageTarget GuiObject - 目标
	@param state VisualState - 播放状态（含播前快照）
	@param policy StopPolicyValue - 最终策略
]]
function PlaybackVisual.ApplyStopVisual(imageTarget: ImageTarget, state: VisualState, policy: StopPolicyValue): ()
	if policy == Types.StopPolicy.Keep then
		return
	end

	local isImage = imageTarget:IsA("ImageLabel") or imageTarget:IsA("ImageButton")
	if policy == Types.StopPolicy.Restore then
		if isImage then
			local img = imageTarget :: any
			img.Image = state.savedImage
			img.ImageRectOffset = state.savedRectOffset
			img.ImageRectSize = state.savedRectSize
			img.ImageTransparency = state.savedTransparency
			img.ImageColor3 = state.savedImageColor
		end
		imageTarget.Visible = state.savedVisible
		return
	end

	if isImage then
		local img = imageTarget :: any
		img.Image = ""
		img.ImageRectOffset = Vector2.zero
		img.ImageRectSize = Vector2.zero
		img.ImageTransparency = state.savedTransparency
		img.ImageColor3 = state.savedImageColor
	end
	imageTarget.Visible = false
end

return PlaybackVisual
