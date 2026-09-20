--[[
	Module: PlayOptionsUtil
	Description: PlaySequence 选项与时间参数解析
	Author: 林奥宇
	Created: 2026-07-31
	Last Modified: 2026-09-01
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local Log = Utils.Log

local Types = require(script.Parent.Types)

type StopPolicyValue = Types.StopPolicyValue
type PlayModeValue = Types.PlayModeValue
type PresentModeValue = Types.PresentModeValue
type CallbackModeValue = Types.CallbackModeValue
type PlayOptions = Types.PlayOptions
type SheetLayout = Types.SheetLayout
type SheetPlayOptions = Types.SheetPlayOptions

local PlayOptionsUtil = {}

--[[
	规范化 stopPolicy，非法值回退 HideClear
	@param policy string? - 调用方传入的策略
	@return StopPolicyValue - 有效策略
]]
function PlayOptionsUtil.NormalizeStopPolicy(policy: string?): StopPolicyValue
	if policy == Types.StopPolicy.Restore or policy == Types.StopPolicy.Keep then
		return policy
	end
	return Types.StopPolicy.HideClear
end

--[[
	规范化 playMode
	@param mode string? - Forward | PingPong | Reverse
	@return PlayModeValue - 有效模式
]]
function PlayOptionsUtil.NormalizePlayMode(mode: string?): PlayModeValue
	if mode == Types.PlayMode.PingPong then
		return Types.PlayMode.PingPong
	end
	if mode == Types.PlayMode.Reverse then
		return Types.PlayMode.Reverse
	end
	return Types.PlayMode.Forward
end

--[[
	规范化 presentMode（表现层）；非法值回退 Swap
	@param mode string? - Swap | Crossfade | CloneAll
	@return PresentModeValue - 有效表现模式
]]
function PlayOptionsUtil.NormalizePresentMode(mode: string?): PresentModeValue
	if mode == Types.PresentMode.Crossfade then
		return Types.PresentMode.Crossfade
	end
	if mode == Types.PresentMode.CloneAll then
		return Types.PresentMode.CloneAll
	end
	return Types.PresentMode.Swap
end

--[[
	规范化 Crossfade 时长（秒）；无效时用默认
	@param sec number? - 调用方时长
	@return number - >= 0 的秒数
]]
function PlayOptionsUtil.NormalizeCrossfadeSec(sec: number?): number
	if typeof(sec) == "number" and sec >= 0 then
		return sec
	end
	return Types.DEFAULT_CROSSFADE_SEC
end

--[[
	规范化层透明度到 [0, 1]
	@param value number? - 调用方透明度
	@return number - 钳制后的透明度
]]
function PlayOptionsUtil.NormalizeLayerTransparency(value: number?): number
	if typeof(value) ~= "number" then
		return Types.DEFAULT_LAYER_TRANSPARENCY
	end
	return math.clamp(value, 0, 1)
end

--[[
	规范化帧回调调度模式；非法值回退 Sync
	@param mode string? - Sync | Deferred
	@return CallbackModeValue - 有效模式
]]
function PlayOptionsUtil.NormalizeCallbackMode(mode: string?): CallbackModeValue
	if mode == Types.CallbackMode.Deferred then
		return Types.CallbackMode.Deferred
	end
	return Types.CallbackMode.Sync
end

--[[
	将帧下标钳制到 [1, frameCount]
	@param frame number - 原始帧下标
	@param frameCount number - 总帧数（须 > 0）
	@return number - 有效帧下标
]]
function PlayOptionsUtil.ClampFrame(frame: number, frameCount: number): number
	return math.clamp(math.floor(frame), 1, frameCount)
end

--[[
	校验并规范化图集布局
	@param sheet SheetPlayOptions - 调用方图集参数
	@return SheetLayout? - 有效布局
	@return number? - frameCount（若传入）
	@return string? - 失败时的 ErrorCode
]]
function PlayOptionsUtil.ResolveSheet(
	sheet: SheetPlayOptions
): (SheetLayout?, number?, string?)
	if typeof(sheet) ~= "table" then
		return nil, nil, Types.ErrorCode.INVALID_SHEET
	end
	if typeof(sheet.imageId) ~= "string" or sheet.imageId == "" then
		return nil, nil, Types.ErrorCode.INVALID_SHEET
	end
	if not sheet.cellWidth or sheet.cellWidth <= 0 then
		return nil, nil, Types.ErrorCode.INVALID_SHEET
	end
	if not sheet.cellHeight or sheet.cellHeight <= 0 then
		return nil, nil, Types.ErrorCode.INVALID_SHEET
	end
	if not sheet.columns or sheet.columns <= 0 then
		return nil, nil, Types.ErrorCode.INVALID_SHEET
	end

	local padding = 0
	if sheet.padding ~= nil then
		if typeof(sheet.padding) ~= "number" or sheet.padding < 0 then
			return nil, nil, Types.ErrorCode.INVALID_SHEET
		end
		padding = sheet.padding
	end
	local spacing = 0
	if sheet.spacing ~= nil then
		if typeof(sheet.spacing) ~= "number" or sheet.spacing < 0 then
			return nil, nil, Types.ErrorCode.INVALID_SHEET
		end
		spacing = sheet.spacing
	end

	local layout: SheetLayout = {
		imageId = sheet.imageId,
		cellWidth = sheet.cellWidth,
		cellHeight = sheet.cellHeight,
		columns = math.floor(sheet.columns),
		padding = padding,
		spacing = spacing,
	}

	local frameCount: number? = nil
	if sheet.frameCount ~= nil then
		if typeof(sheet.frameCount) ~= "number" or sheet.frameCount <= 0 then
			return nil, nil, Types.ErrorCode.INVALID_SHEET
		end
		frameCount = math.floor(sheet.frameCount)
	end

	local rows: number? = nil
	if sheet.rows ~= nil then
		if typeof(sheet.rows) ~= "number" or sheet.rows <= 0 then
			return nil, nil, Types.ErrorCode.INVALID_SHEET
		end
		rows = math.floor(sheet.rows)
	end
	if frameCount then
		local neededRows = math.ceil(frameCount / layout.columns)
		if rows and neededRows > rows then
			return nil, nil, Types.ErrorCode.INVALID_SHEET
		end
	end
	layout.rows = rows

	return layout, frameCount, nil
end

--[[
	由选项解析每帧秒数
	优先级：secondsPerFrame > fps；不再接受 frameDuration / 位置数字参数
	@param options PlayOptions - 选项表
	@return number? - 每帧秒数；无效时 nil
	@return string? - 失败 ErrorCode（INVALID_TIMING）
]]
function PlayOptionsUtil.ResolveFrameStep(options: PlayOptions): (number?, string?)
	if typeof(options) ~= "table" then
		return nil, Types.ErrorCode.INVALID_ARG
	end
	if options.secondsPerFrame and options.secondsPerFrame > 0 then
		return options.secondsPerFrame, nil
	end
	if options.fps and options.fps > 0 then
		return 1 / options.fps, nil
	end
	if options.frameDuration and options.frameDuration > 0 then
		Log.warn(
			"[SequenceManager] 已移除 frameDuration，请改用 fps 或 secondsPerFrame（旧换算：secondsPerFrame = "
				.. tostring(Types.LEGACY_FRAME_TIME_SEC)
				.. " * frameDuration）"
		)
		return nil, Types.ErrorCode.INVALID_TIMING
	end
	return nil, Types.ErrorCode.INVALID_TIMING
end

--[[
	解析 PlaySequence 选项表（第三参必须为 table）
	@param options PlayOptions - 选项表
	@return PlayOptions? - 归一化后的选项
	@return string? - 失败 ErrorCode
]]
function PlayOptionsUtil.ResolvePlayOptions(options: PlayOptions): (PlayOptions?, string?)
	if typeof(options) ~= "table" then
		Log.warn(
			"[SequenceManager] PlaySequence 第三参须为 options 表，例如 { fps = 12, loop = true }"
		)
		return nil, Types.ErrorCode.INVALID_ARG
	end

	local direction = 1
	if options.direction and options.direction < 0 then
		direction = -1
	end
	return {
		fps = options.fps,
		secondsPerFrame = options.secondsPerFrame,
		loop = if options.loop == nil then false else options.loop,
		loopInterval = options.loopInterval or 0,
		speed = if options.speed and options.speed > 0 then options.speed else Types.DEFAULT_SPEED,
		stopPolicy = PlayOptionsUtil.NormalizeStopPolicy(options.stopPolicy),
		startFrame = options.startFrame,
		endFrame = options.endFrame,
		playMode = PlayOptionsUtil.NormalizePlayMode(options.playMode),
		presentMode = PlayOptionsUtil.NormalizePresentMode(options.presentMode),
		crossfadeSec = PlayOptionsUtil.NormalizeCrossfadeSec(options.crossfadeSec),
		layerTransparency = PlayOptionsUtil.NormalizeLayerTransparency(options.layerTransparency),
		direction = direction,
		forceVisible = if options.forceVisible == nil then true else options.forceVisible,
		callbackMode = PlayOptionsUtil.NormalizeCallbackMode(options.callbackMode),
		sheet = options.sheet,
		onComplete = options.onComplete,
		onLoop = options.onLoop,
		onFrame = options.onFrame,
		markers = options.markers,
	}, nil
end

--[[
	解析最终用于播放的序列数据（目录 + 可选 sheet 覆盖 / 临构图集）
	@param options PlayOptions - 已归一化选项
	@param catalogData SequenceFrameData? - 目录数据（可 nil）
	@return SequenceFrameData? - 可播放数据
	@return string? - 失败 ErrorCode
]]
function PlayOptionsUtil.ResolvePlayData(
	options: PlayOptions,
	catalogData: Types.SequenceFrameData?
): (Types.SequenceFrameData?, string?)
	if options.sheet then
		local layout, sheetFrameCount, sheetErr = PlayOptionsUtil.ResolveSheet(options.sheet)
		if not layout then
			return nil, sheetErr or Types.ErrorCode.INVALID_SHEET
		end

		local count = sheetFrameCount
		if not count and catalogData and catalogData.count > 0 then
			count = catalogData.count
		end
		if not count or count <= 0 then
			return nil, Types.ErrorCode.INVALID_SHEET
		end

		return table.freeze({
			kind = Types.SequenceKind.Sheet,
			frames = table.freeze({ layout.imageId }),
			count = count,
			sheet = table.freeze({
				imageId = layout.imageId,
				cellWidth = layout.cellWidth,
				cellHeight = layout.cellHeight,
				columns = layout.columns,
				padding = layout.padding or 0,
				spacing = layout.spacing or 0,
				rows = layout.rows,
			}),
			rejectCode = nil,
		}), nil
	end

	if catalogData and catalogData.count > 0 then
		return catalogData, nil
	end

	if catalogData and catalogData.rejectCode then
		return nil, catalogData.rejectCode
	end

	return nil, Types.ErrorCode.NOT_FOUND
end

return PlayOptionsUtil
