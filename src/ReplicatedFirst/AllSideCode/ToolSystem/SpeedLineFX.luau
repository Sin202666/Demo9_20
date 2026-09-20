--[[
	Module: SpeedLineFX
	Description: 全屏加速线表现（多层同序列 Swap 切帧 + 强度包络），仅客户端
	Author: LinAoyu
	Created: 2026-07-31
	Last Modified: 2026-07-31

	能力：
	- Show / SetIntensity / Hide：强度驱动各层透明度与播放速度
	- Preload：预加载 Assets/Sequence 下加速线序列
	- 2~3 层同素材错相叠加，伪造更长循环与景深（12 帧素材）
	- 出现/消失：强度包络淡入（Show）/ 淡出（Hide），结束后才停序列

	与 SequenceManager 的关系：
	- 序列播放全部委托 SequenceManager:PlaySequence（presentMode=Swap，短冲刺下硬切更易感知帧变化）
	- 本模块只负责全屏容器组装与强度包络
	- 调速 / 层透明度走 SetSpeed / SetLayerTransparency

	加载：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local SpeedLineFX = Utils.SpeedLineFX

	示例：
		SpeedLineFX.Preload()
		SpeedLineFX.Show(0.75, 0.1) -- 淡入到中等强度
		SpeedLineFX.SetIntensity(0.55)
		SpeedLineFX.Hide(0.22) -- 淡出后停层

	资源约定：
	- Assets/Sequence/加速线/ 下多图帧（StringValue，Name=帧序号）
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local Log = Utils.Log
local SequenceManager = Utils.SequenceManager

local SpeedLineFX = {}

type ImageLabel = typeof(workspace:FindFirstChildOfClass("ImageLabel"))
type ScreenGui = typeof(workspace:FindFirstChildOfClass("ScreenGui"))
type Connection = typeof(RunService.Heartbeat:Connect(function() end))

type LayerConfig = {
	name: string,
	-- 推荐 fps（短冲刺窗口内需多帧可见）
	fps: number,
	startFrame: number,
	-- 峰值可见度（intensity=1 时的 alpha；越小越透）
	baseAlpha: number,
	speedMul: number,
	scale: number,
	tint: Color3,
	zIndex: number,
	rotation: number,
}

type LayerRuntime = {
	config: LayerConfig,
	imageLabel: ImageLabel,
	uiScale: UIScale,
	-- PlaySequence 成功时的世代句柄；停播优先 StopHandle
	handle: { id: number, target: GuiObject }?,
}

-- ============================================================================
-- 常量（调参优先改这里）
-- ============================================================================

-- Assets/Sequence 下 Folder 名（12 帧加速线）
local SEQUENCE_NAME: string = "加速线"
local SCREEN_GUI_NAME: string = "SpeedLineFX"
local PLAYER_GUI_NAME: string = "PlayerGui"
local DISPLAY_ORDER: number = 80
-- 短冲刺用 Swap 硬切；若改 Crossfade 可调此值（秒）
local CROSSFADE_SEC: number = 0.02
local DEFAULT_FADE_IN_SEC: number = 0.1
local DEFAULT_FADE_OUT_SEC: number = 0.22
local SET_INTENSITY_FADE_SEC: number = 0.08
local BREATH_AMPLITUDE: number = 0.04
local BREATH_HZ: number = 0.55
-- 强度包络下的播放速率区间
local SPEED_SCALE_MIN: number = 0.85
local SPEED_SCALE_MAX: number = 1.2

SpeedLineFX.ErrorCode = table.freeze({
	NOT_CLIENT = "NOT_CLIENT",
	INVALID_ARG = "INVALID_ARG",
	NO_PLAYER_GUI = "NO_PLAYER_GUI",
	NOT_ACTIVE = "NOT_ACTIVE",
	PLAY_FAILED = "PLAY_FAILED",
})

-- 相位错开；baseAlpha / fps 取「可见但不糊屏、动但不闪」中间档
local LAYER_CONFIGS: { LayerConfig } = {
	{
		name = "Main",
		fps = 18,
		startFrame = 1,
		baseAlpha = 0.68,
		speedMul = 1,
		scale = 1,
		tint = Color3.fromRGB(255, 255, 255),
		zIndex = 1,
		rotation = 0,
	},
	{
		name = "Fast",
		fps = 24,
		startFrame = 7,
		baseAlpha = 0.55,
		speedMul = 1.1,
		scale = 1.02,
		tint = Color3.fromRGB(230, 250, 255),
		zIndex = 2,
		rotation = 0,
	},
	{
		name = "Slow",
		fps = 12,
		startFrame = 4,
		baseAlpha = 0.4,
		speedMul = 0.9,
		scale = 1.06,
		tint = Color3.fromRGB(255, 255, 255),
		zIndex = 3,
		rotation = 180,
	},
}

-- ============================================================================
-- 私有变量
-- ============================================================================

local _screenGui: ScreenGui? = nil
local _layers: { LayerRuntime } = {}
local _playing: boolean = false
local _targetIntensity: number = 0
local _currentIntensity: number = 0
local _fadeVel: number = 0
local _fadeRemaining: number = 0
local _fadeFrom: number = 0
local _fadeTo: number = 0
local _hiding: boolean = false
local _breathTime: number = 0
local _updateConnection: Connection? = nil

-- ============================================================================
-- 私有函数
-- ============================================================================

--[[
	线性插值
	@param a number - 起点
	@param b number - 终点
	@param t number - [0,1]
	@return number - 插值结果
]]
local function _lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

--[[
	确保 PlayerGui 下存在全屏 ScreenGui 与各层 ImageLabel
	@return boolean - 是否创建/获取成功
]]
local function _ensureUi(): boolean
	if _screenGui and _screenGui.Parent and #_layers > 0 then
		return true
	end

	local localPlayer: Player? = Players.LocalPlayer
	if not localPlayer then
		Log.warn("[SpeedLineFX] 无 LocalPlayer，无法创建 UI")
		return false
	end

	local playerGui: Instance? = localPlayer:FindFirstChild(PLAYER_GUI_NAME)
	if not playerGui then
		playerGui = localPlayer:WaitForChild(PLAYER_GUI_NAME, 5)
	end
	if not playerGui then
		Log.warn("[SpeedLineFX] 无 PlayerGui")
		return false
	end

	local existing: Instance? = playerGui:FindFirstChild(SCREEN_GUI_NAME)
	if existing then
		existing:Destroy()
	end

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = SCREEN_GUI_NAME
	screenGui.IgnoreGuiInset = true
	screenGui.ResetOnSpawn = false
	screenGui.DisplayOrder = DISPLAY_ORDER
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.Enabled = false
	screenGui.Parent = playerGui
	_screenGui = screenGui

	table.clear(_layers)

	for _, cfg in ipairs(LAYER_CONFIGS) do
		local imageLabel = Instance.new("ImageLabel")
		imageLabel.Name = cfg.name
		imageLabel.BackgroundTransparency = 1
		imageLabel.BorderSizePixel = 0
		imageLabel.Size = UDim2.fromScale(1, 1)
		imageLabel.Position = UDim2.fromScale(0.5, 0.5)
		imageLabel.AnchorPoint = Vector2.new(0.5, 0.5)
		imageLabel.ScaleType = Enum.ScaleType.Stretch
		imageLabel.ImageTransparency = 1
		imageLabel.ImageColor3 = cfg.tint
		imageLabel.ZIndex = cfg.zIndex
		imageLabel.Rotation = cfg.rotation
		imageLabel.Visible = false
		imageLabel.Parent = screenGui

		local uiScale = Instance.new("UIScale")
		uiScale.Scale = cfg.scale
		uiScale.Parent = imageLabel

		table.insert(_layers, {
			config = cfg,
			imageLabel = imageLabel,
			uiScale = uiScale,
			handle = nil,
		})
	end

	return true
end

--[[
	由强度计算呼吸后的有效强度
	@param intensity number - 基础强度 [0,1]
	@return number - 含呼吸调制的强度
]]
local function _effectiveIntensity(intensity: number): number
	if intensity <= 0 then
		return 0
	end
	local breath: number = 1 + BREATH_AMPLITUDE * math.sin(_breathTime * math.pi * 2 * BREATH_HZ)
	return math.clamp(intensity * breath, 0, 1)
end

--[[
	将当前强度应用到各层透明度与速度
]]
local function _applyIntensityToLayers(): ()
	local eff: number = _effectiveIntensity(_currentIntensity)
	local speedScale: number = _lerp(SPEED_SCALE_MIN, SPEED_SCALE_MAX, eff)

	for _, layer in ipairs(_layers) do
		local alpha: number = layer.config.baseAlpha * eff
		local transparency: number = 1 - alpha
		SequenceManager:SetLayerTransparency(layer.imageLabel, transparency)
		SequenceManager:SetSpeed(layer.imageLabel, speedScale * layer.config.speedMul)
	end
end

--[[
	启动各层序列播放（若尚未播放）
	@return boolean - true 全部开播成功
	@return string? - 失败时的 ErrorCode
]]
local function _startLayers(): (boolean, string?)
	if _playing then
		return true, nil
	end

	for _, layer in ipairs(_layers) do
		local imageLabel: ImageLabel = layer.imageLabel
		imageLabel.Visible = true
		imageLabel.ImageTransparency = 1
		local ok, err, handle = SequenceManager:PlaySequence(imageLabel, SEQUENCE_NAME, {
			fps = layer.config.fps,
			loop = true,
			startFrame = layer.config.startFrame,
			playMode = SequenceManager.PlayMode.PingPong,
			-- 短冲刺窗口：硬切比 Crossfade 更易看出帧变化
			presentMode = SequenceManager.PresentMode.Swap,
			crossfadeSec = CROSSFADE_SEC,
			speed = SPEED_SCALE_MIN * layer.config.speedMul,
			layerTransparency = 1,
			forceVisible = true,
			stopPolicy = SequenceManager.StopPolicy.Keep,
		})
		if not ok or not handle then
			Log.warn("[SpeedLineFX] 层播放失败:", layer.config.name, err)
			-- 回滚已开播层，避免半开状态
			for _, started in ipairs(_layers) do
				if started.handle then
					SequenceManager:StopHandle(started.handle, SequenceManager.StopPolicy.Keep)
					started.handle = nil
				else
					SequenceManager:StopSequence(started.imageLabel, SequenceManager.StopPolicy.Keep)
				end
				started.imageLabel.Visible = false
				started.imageLabel.ImageTransparency = 1
			end
			_playing = false
			return false, SpeedLineFX.ErrorCode.PLAY_FAILED
		end
		layer.handle = handle
	end

	_playing = true
	return true, nil
end

--[[
	停止各层并隐藏容器
]]
local function _stopLayers(): ()
	for _, layer in ipairs(_layers) do
		if layer.handle then
			SequenceManager:StopHandle(layer.handle, SequenceManager.StopPolicy.Keep)
			layer.handle = nil
		else
			SequenceManager:StopSequence(layer.imageLabel, SequenceManager.StopPolicy.Keep)
		end
		layer.imageLabel.Visible = false
		layer.imageLabel.ImageTransparency = 1
	end
	_playing = false

	if _screenGui then
		_screenGui.Enabled = false
	end
end

--[[
	断开强度更新连接
]]
local function _disconnectUpdate(): ()
	if _updateConnection then
		_updateConnection:Disconnect()
		_updateConnection = nil
	end
end

--[[
	强度包络更新（淡入淡出 + 呼吸 + 应用到层）
	@param deltaTime number - 帧间隔秒
]]
local function _onUpdate(deltaTime: number): ()
	_breathTime += deltaTime

	if _fadeRemaining > 0 then
		_fadeRemaining -= deltaTime
		local duration: number = math.max(_fadeVel, 1e-4)
		local elapsed: number = duration - math.max(_fadeRemaining, 0)
		local t: number = math.clamp(elapsed / duration, 0, 1)
		t = t * t * (3 - 2 * t)
		_currentIntensity = _lerp(_fadeFrom, _fadeTo, t)
		if _fadeRemaining <= 0 then
			_currentIntensity = _fadeTo
			_fadeRemaining = 0
			if _hiding and _currentIntensity <= 0 then
				_stopLayers()
				_hiding = false
				_disconnectUpdate()
				return
			end
		end
	else
		_currentIntensity = _targetIntensity
	end

	_applyIntensityToLayers()
end

--[[
	确保 Heartbeat 强度更新在跑
]]
local function _ensureUpdateConnection(): ()
	if _updateConnection then
		return
	end
	_updateConnection = RunService.Heartbeat:Connect(_onUpdate)
end

--[[
	开始向目标强度淡入/淡出
	@param toIntensity number - 目标强度 [0,1]
	@param fadeSec number - 过渡秒数
	@param hiding boolean - 结束后是否停止层
]]
local function _beginFade(toIntensity: number, fadeSec: number, hiding: boolean): ()
	_hiding = hiding
	_targetIntensity = math.clamp(toIntensity, 0, 1)
	_fadeFrom = _currentIntensity
	_fadeTo = _targetIntensity
	local duration: number = math.max(fadeSec, 0)
	_fadeVel = duration
	_fadeRemaining = duration

	if duration <= 0 then
		_currentIntensity = _targetIntensity
		_applyIntensityToLayers()
		if hiding and _currentIntensity <= 0 then
			_stopLayers()
			_hiding = false
			_disconnectUpdate()
		else
			_ensureUpdateConnection()
		end
		return
	end

	_ensureUpdateConnection()
end

-- ============================================================================
-- 公共 API
-- ============================================================================

--[[
	预加载加速线序列资源
	@return boolean - true 预载成功或已调度
	@return string? - 失败时的 ErrorCode
]]
function SpeedLineFX.Preload(): (boolean, string?)
	if not RunService:IsClient() then
		Log.warn("[SpeedLineFX] 仅客户端可用")
		return false, SpeedLineFX.ErrorCode.NOT_CLIENT
	end
	return SequenceManager:Preload(SEQUENCE_NAME)
end

--[[
	显示全屏加速线并淡入到指定强度
	@param intensity number? - 目标强度 [0,1]，默认 1
	@param fadeInSec number? - 淡入秒数，默认 0.12
	@return boolean - true 已开始显示
	@return string? - 失败时的 ErrorCode
]]
function SpeedLineFX.Show(intensity: number?, fadeInSec: number?): (boolean, string?)
	if not RunService:IsClient() then
		Log.warn("[SpeedLineFX] 仅客户端可用")
		return false, SpeedLineFX.ErrorCode.NOT_CLIENT
	end

	if not _ensureUi() then
		return false, SpeedLineFX.ErrorCode.NO_PLAYER_GUI
	end

	local target: number = if intensity == nil then 1 else math.clamp(intensity, 0, 1)
	local fadeSec: number = if fadeInSec == nil then DEFAULT_FADE_IN_SEC else math.max(fadeInSec, 0)

	if _screenGui then
		_screenGui.Enabled = true
	end

	local playOk, playErr = _startLayers()
	if not playOk then
		return false, playErr
	end

	_beginFade(target, fadeSec, false)
	return true, nil
end

--[[
	运行时设置目标强度（平滑过渡到新值）
	@param intensity number - 目标强度 [0,1]
	@return boolean - true 已接受
	@return string? - 失败时的 ErrorCode
]]
function SpeedLineFX.SetIntensity(intensity: number): (boolean, string?)
	if typeof(intensity) ~= "number" then
		return false, SpeedLineFX.ErrorCode.INVALID_ARG
	end
	if not _playing and not (_screenGui and _screenGui.Enabled) then
		return false, SpeedLineFX.ErrorCode.NOT_ACTIVE
	end

	local target: number = math.clamp(intensity, 0, 1)
	_beginFade(target, SET_INTENSITY_FADE_SEC, false)
	return true, nil
end

--[[
	淡出并停止全屏加速线
	@param fadeOutSec number? - 淡出秒数，默认 0.2
	@return boolean - true 已开始淡出或已停止
	@return string? - 失败时的 ErrorCode
]]
function SpeedLineFX.Hide(fadeOutSec: number?): (boolean, string?)
	if not RunService:IsClient() then
		Log.warn("[SpeedLineFX] 仅客户端可用")
		return false, SpeedLineFX.ErrorCode.NOT_CLIENT
	end

	if not _playing and _currentIntensity <= 0 then
		_stopLayers()
		_disconnectUpdate()
		return true, nil
	end

	local fadeSec: number = if fadeOutSec == nil then DEFAULT_FADE_OUT_SEC else math.max(fadeOutSec, 0)
	_beginFade(0, fadeSec, true)
	return true, nil
end

--[[
	查询当前显示强度（含淡入淡出过程值，不含呼吸）
	@return number - 当前强度 [0,1]
]]
function SpeedLineFX.GetIntensity(): number
	return _currentIntensity
end

--[[
	加速线序列资源名（Assets/Sequence Folder）
	@return string - 序列名
]]
function SpeedLineFX.GetSequenceName(): string
	return SEQUENCE_NAME
end

return SpeedLineFX
