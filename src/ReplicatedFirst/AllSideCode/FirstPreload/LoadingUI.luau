--[[
	Module: LoadingUI
	Description: FirstPreload 加载界面：进度条、Logo 动画、跳过按钮与关闭过渡
	Author: 中台组
	Created: 2026-07-03
	Last Modified: 2026-09-01

	功能：
	- 挂载 PreloadGui 到 PlayerGui，传送场景下按 TeleportCfg 换肤
	- 加载期间隐藏其他 ScreenGui，关闭后按 Attribute 恢复
	- 平滑进度条、Logo 药水动画、超时显示跳过、手柄/按钮跳过
	- Logo 序列持 PlaybackHandle；关闭前 StopHandle，Destroy 作兜底

	依赖：
	- Utils.RunService / TweenService / UserInputService / SoundService / Players
	- Utils.TranslationHelper / SequenceManager

	示例：
	```lua
	local LoadingUI = require(script.LoadingUI)
	LoadingUI.Start({
		preloadGui = preloadGui,
		teleportCfg = teleportCfg,
		resTotal = resTotal,
		resLoaded = resLoaded,
		resLoadTime = resLoadTime,
		isCloseLoading = isCloseLoading,
		onFinished = function()
			script:Destroy()
		end,
	})
	```
]]

-- ============================================================================
-- 服务与依赖
-- ============================================================================

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local RunService = Utils.RunService
local TweenService = Utils.TweenService
local UserInputService = Utils.UserInputService
local SoundService = Utils.SoundService
local Players = Utils.Players
local TranslationHelper = Utils.TranslationHelper
local SequenceManager = Utils.SequenceManager
local Log = Utils.Log

-- ============================================================================
-- 模块定义
-- ============================================================================

local LoadingUI = {}

export type StartConfig = {
	preloadGui: ScreenGui,
	teleportCfg: any?,
	resTotal: NumberValue,
	resLoaded: NumberValue,
	resLoadTime: NumberValue,
	isCloseLoading: BoolValue,
	onFinished: (() -> ())?,
}

-- ============================================================================
-- 常量
-- ============================================================================

local PRELOAD_GUI_SHOW_NAME = "PreloadGuiNowShow"
local DISPLAY_SMOOTH_TAU = 0.1
local SKIP_SHOW_TIME_SEC = 5
local SKIP_SHOW_TIME_STUDIO_SEC = 0.5
local LOGO_CAP_TWEEN_SEC = 0.15
local LOGO_STAND_TWEEN_SEC = 0.2
local CLOSE_FADE_SEC = 0.5
local SEQUENCE_LOADING_POTION = "Loading_药水流动"

-- ============================================================================
-- 私有函数
-- ============================================================================

--[[
	传送加载界面按配置设置背景、标题渐变与文案
	@param frame Frame - PreloadGui.CanvasGroup
	@param cfg table - TeleportService 传入的配置（BigZhName / Colors / TeleBG）
	@return nil - 无返回值
]]
local function _applyTeleportSkin(frame: Frame, cfg: any)
	local worldName = frame:FindFirstChild("WorldName")
	local bgImg = frame:FindFirstChild("BGImg")
	local nameBg = frame:FindFirstChild("NameBg")

	if worldName then
		worldName.Visible = false
		task.defer(function()
			worldName.Visible = true
			TranslationHelper.SetText(worldName, cfg.BigZhName)
		end)

		local gradient = worldName:FindFirstChild("UIGradient") :: UIGradient?
		if gradient and cfg.Colors then
			gradient.Color = ColorSequence.new(
				Color3.fromHex(cfg.Colors[1]),
				Color3.fromHex(cfg.Colors[2])
			)
		end
	end

	if bgImg and cfg.TeleBG then
		bgImg.Image = "rbxassetid://" .. cfg.TeleBG
	end

	if nameBg and cfg.Colors then
		local gradient = nameBg:FindFirstChild("UIGradient") :: UIGradient?
		if gradient then
			gradient.Color = ColorSequence.new(
				Color3.fromHex(cfg.Colors[1]),
				Color3.fromHex(cfg.Colors[2])
			)
		end
	end
end

--[[
	初始化 Logo 区默认可见性
	@param preloadFrame Frame - 主内容 Frame
	@return nil - 无返回值
]]
local function _initLogoFrame(preloadFrame: Frame)
	local logoFrame = preloadFrame:FindFirstChild("Logo") :: Frame?
	if not logoFrame then
		return
	end

	logoFrame["PotionCap"].Visible = true
	logoFrame["PotionLie"].Visible = false
	logoFrame["PotionStand"].Visible = true
	logoFrame["Effect"].Visible = false
end

--[[
	根据 0~1 进度更新进度条渐变与光点位置
	@param progressGradient UIGradient - 进度条渐变
	@param lightIcon ImageLabel - 光点图标
	@param percent number - 0~1 显示进度
	@return nil - 无返回值
]]
local function _applyProgressVisual(
	progressGradient: UIGradient,
	lightIcon: ImageLabel,
	percent: number
)
	percent = math.clamp(percent, 0, 1)
	lightIcon.Position = UDim2.new(math.clamp(percent, 0.01, 0.99), 0, 0.5, 0)

	local p1 = math.clamp(percent - 0.001, 0.001, 0.998)
	local p2 = math.clamp(percent + 0.001, 0.002, 0.999)

	progressGradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(p1, 0),
		NumberSequenceKeypoint.new(p2, 1),
		NumberSequenceKeypoint.new(1, 1),
	})
end

--[[
	播放 Logo 药水倾倒序列并在完成后显示进度条
	@param preloadFrame Frame - 主内容 Frame
	@param progressFrame Frame - 进度条容器
	@return { id: number, target: GuiObject }? - 药水特效序列 handle；未开播或失败为 nil
]]
local function _playLogoIntro(
	preloadFrame: Frame,
	progressFrame: Frame
): { id: number, target: GuiObject }?
	local effectHandle: { id: number, target: GuiObject }? = nil
	local logoFrame = preloadFrame:FindFirstChild("Logo") :: Frame?
	if logoFrame then
		local potionCap = logoFrame["PotionCap"] :: ImageLabel
		local potionLie = logoFrame["PotionLie"] :: ImageLabel
		local potionStand = logoFrame["PotionStand"] :: ImageLabel
		local effect = logoFrame["Effect"] :: ImageLabel

		local capAnim = TweenService:Create(potionCap, TweenInfo.new(LOGO_CAP_TWEEN_SEC), {
			Position = UDim2.new(0.656, 0, 0.3, 0),
		})
		capAnim:Play()
		capAnim.Completed:Wait()

		local standAnim = TweenService:Create(potionStand, TweenInfo.new(LOGO_STAND_TWEEN_SEC), {
			Rotation = 40,
		})
		standAnim:Play()
		standAnim.Completed:Wait()

		potionStand.Visible = false
		potionCap.Visible = false
		potionLie.Visible = true
		effect.Visible = true
		local ok, err, handle = SequenceManager:PlaySequence(effect, SEQUENCE_LOADING_POTION, {
			-- 旧签名 frameDuration=1 → 约 0.016s/帧
			secondsPerFrame = 0.016,
			loop = true,
		})
		if not ok or not handle then
			Log.warn("[LoadingUI] 药水流动序列播放失败:", err)
			effect.Visible = false
		else
			effectHandle = handle
		end
	end

	progressFrame.Visible = true
	return effectHandle
end

--[[
	加载期间仅保留 PreloadGui，其他 ScreenGui 暂存 Enabled 到 Attribute
	@param localPlayer Player - 本地玩家
	@param loadEndRef { boolean } - 关闭标志引用，true 时退出循环
	@return nil - 无返回值
]]
local function _runGuiIsolationLoop(localPlayer: Player, loadEndRef: { boolean })
	local currentCamera = workspace.CurrentCamera

	while true do
		if loadEndRef[1] then
			currentCamera.CameraType = Enum.CameraType.Custom
			return
		end

		local playerGui = localPlayer:FindFirstChild("PlayerGui") :: PlayerGui?
		if playerGui then
			for _, child in playerGui:GetChildren() do
				if child:IsA("ScreenGui") then
					if child.Name == PRELOAD_GUI_SHOW_NAME and not child.Enabled then
						child:SetAttribute("Enabled", false)
						child.Enabled = true
					elseif child.Name ~= PRELOAD_GUI_SHOW_NAME and child.Enabled then
						child:SetAttribute("Enabled", true)
						child.Enabled = false
					end
				end
			end
		end

		if loadEndRef[1] then
			currentCamera.CameraType = Enum.CameraType.Custom
			return
		end

		task.wait()
	end
end

--[[
	恢复 PlayerGui 内被隔离的 ScreenGui Enabled 状态
	@param localPlayer Player - 本地玩家
	@return nil - 无返回值
]]
local function _restorePlayerGui(localPlayer: Player)
	local playerGui = localPlayer:FindFirstChild("PlayerGui") :: PlayerGui?
	if not playerGui then
		return
	end

	for _, child in playerGui:GetChildren() do
		if child:IsA("ScreenGui") then
			local enabled = child:GetAttribute("Enabled")
			if enabled ~= nil then
				child.Enabled = enabled
				child:SetAttribute("Enabled", nil)
			end
		end
	end
end

-- ============================================================================
-- 公共 API
-- ============================================================================

--[[
	启动加载界面全流程（进度监听、跳过、关闭动画）
	@param config StartConfig - 界面实例、计数器与完成回调
	@return nil - 无返回值
]]
function LoadingUI.Start(config: StartConfig)
	local preloadGui = config.preloadGui
	local canvasGroup = preloadGui.CanvasGroup :: CanvasGroup
	local preloadFrame = canvasGroup.Frame :: Frame
	local progressFrame = preloadFrame["进度条"] :: Frame
	local progressGradient = progressFrame["Bar"]["ProgressGradient"] :: UIGradient
	local lightIcon = progressFrame["Bar"]["闪光"] :: ImageLabel
	local buttonFrame = preloadFrame["跳过按钮"] :: Frame
	local blackBg = preloadGui["半透明屏蔽层"] :: ImageButton
	local localPlayer = Players.LocalPlayer :: Player

	preloadGui.Name = PRELOAD_GUI_SHOW_NAME
	buttonFrame.Visible = false
	progressFrame.Visible = false
	canvasGroup.GroupTransparency = 0
	preloadGui.Enabled = true

	local playerGui = localPlayer:WaitForChild("PlayerGui") :: PlayerGui
	preloadGui.Parent = playerGui

	_initLogoFrame(preloadFrame)

	if config.teleportCfg then
		_applyTeleportSkin(canvasGroup, config.teleportCfg)
	end

	task.defer(function()
		TranslationHelper.SetText(buttonFrame.Frame["跳过"], "跳过")
		TranslationHelper.SetText(preloadFrame.Loading, "加载中")
	end)

	SequenceManager:Preload(SEQUENCE_LOADING_POTION)

	local loadEndRef = { false }
	task.spawn(function()
		_runGuiIsolationLoop(localPlayer, loadEndRef)
	end)

	local progressConn: RBXScriptConnection? = nil
	local skipShowConn: RBXScriptConnection? = nil
	local skipInputConn: RBXScriptConnection? = nil
	local displayPercent = 0
	local potionEffectHandle: { id: number, target: GuiObject }? = nil

	local skipThreshold = RunService:IsStudio() and SKIP_SHOW_TIME_STUDIO_SEC or SKIP_SHOW_TIME_SEC
	local skipShown = false

	--[[
		预加载时间达到阈值：显示跳过按钮
		@return nil - 无返回值
	]]
	local function _onSkipThresholdReached()
		if skipShown or not preloadGui.Parent then
			return
		end
		skipShown = true

		if skipShowConn then
			skipShowConn:Disconnect()
			skipShowConn = nil
		end

		buttonFrame.Visible = true
		local showTween = TweenService:Create(
			buttonFrame,
			TweenInfo.new(CLOSE_FADE_SEC, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Size = UDim2.new(0.175, 0, 0.05, 0) }
		)
		showTween:Play()
	end

	--[[
		关闭加载界面：断开事件、淡出、恢复 GUI、标记 IsCloseLoading
		@return nil - 无返回值
	]]
	local function closeUI()
		if not progressConn then
			return
		end

		if skipInputConn then
			skipInputConn:Disconnect()
			skipInputConn = nil
		end
		if skipShowConn then
			skipShowConn:Disconnect()
			skipShowConn = nil
		end
		progressConn:Disconnect()
		progressConn = nil

		task.spawn(function()
			SoundService:WaitForChild("UI"):WaitForChild("loading加载完毕"):Play()
		end)

		local closeTween = TweenService:Create(canvasGroup, TweenInfo.new(CLOSE_FADE_SEC), {
			GroupTransparency = 1,
		})
		closeTween:Play()
		closeTween.Completed:Wait()

		loadEndRef[1] = true
		_restorePlayerGui(localPlayer)

		local blackBgTween = TweenService:Create(blackBg, TweenInfo.new(CLOSE_FADE_SEC), {
			BackgroundTransparency = 1,
		})
		blackBgTween:Play()
		blackBgTween.Completed:Wait()

		if potionEffectHandle then
			SequenceManager:StopHandle(potionEffectHandle, SequenceManager.StopPolicy.Keep)
			potionEffectHandle = nil
		end

		preloadGui.Enabled = false
		preloadGui:Destroy()
		config.isCloseLoading.Value = true

		if config.onFinished then
			config.onFinished()
		end
	end

	local function playSkipSound()
		task.spawn(function()
			SoundService:WaitForChild("UI"):WaitForChild("UI_跳过加载点击"):Play()
		end)
	end

	skipInputConn = UserInputService.InputEnded:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		if input.KeyCode == Enum.KeyCode.ButtonX then
			closeUI()
			playSkipSound()
		end
	end)

	_applyProgressVisual(progressGradient, lightIcon, 0)

	task.defer(function()
		potionEffectHandle = _playLogoIntro(preloadFrame, progressFrame)

		progressConn = RunService.Heartbeat:Connect(function(deltaTime: number)
			if config.resTotal.Value <= 0 then
				return
			end

			local targetPercent = math.clamp(config.resLoaded.Value / config.resTotal.Value, 0, 1)
			local k = 1 - math.exp(-deltaTime / DISPLAY_SMOOTH_TAU)
			displayPercent += (targetPercent - displayPercent) * k

			if math.abs(targetPercent - displayPercent) < 1e-5 then
				displayPercent = targetPercent
			end

			_applyProgressVisual(progressGradient, lightIcon, displayPercent)

			-- 资源加载完成后需等显示进度追上，避免进度条未走完就关闭
			if targetPercent >= 1 and displayPercent >= 1 - 1e-5 then
				closeUI()
			end
		end)

		buttonFrame.Button.MouseButton1Click:Once(function()
			closeUI()
			playSkipSound()
		end)
	end)

	buttonFrame.Size = UDim2.new(0, 0, 0, 0)

	skipShowConn = config.resLoadTime.Changed:Connect(function(elapsed: number)
		if elapsed > skipThreshold then
			_onSkipThresholdReached()
		end
	end)

	if config.resLoadTime.Value > skipThreshold then
		_onSkipThresholdReached()
	end
end

return LoadingUI
