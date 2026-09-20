--[[
	Module: HatchEffect/HatchRewardEffect
	Description: 抽蛋奖励展示、旋转与结束动画
	Author: 林奥宇
	Created: 2026-01-29
	Last Modified: 2026-09-01

	由 HatchEffect.init 内部调用。跳过输入只置位，结束动画在 play 主线程收口，避免与等待循环抢写 PivotTo。
]]

-- ============================================================================
-- 服务与依赖
-- ============================================================================

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local UserInputService = game:GetService("UserInputService")

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local VisibleMgr = Utils.VisibleMgr
local FXUtil = Utils.FXUtil
local EnumMgr = Utils.EnumMgr
local InsMgr = Utils.InsMgr
local AnimationModule = Utils.AnimationModule
local Log = Utils.Log

local HatchConfig = require(script.Parent.HatchConfig)
local HatchAnimUtil = require(script.Parent.HatchAnimUtil)
local HatchCamera = require(script.Parent.HatchCamera)
local HatchSound = require(script.Parent.HatchSound)

local HatchRewardEffect = {}

-- ============================================================================
-- 类型
-- ============================================================================

type PlayContext = {
	rewardModelTable: {Model},
	rewardOffsetTable: {CFrame},
	particleOfOpen: Model,
	speedScale: number,
	rotateSwitch: boolean,
	waitSwitch: boolean,
	ended: boolean,
	endRequested: boolean,
	quitEvent: RBXScriptConnection?,
}

-- ============================================================================
-- 私有函数
-- ============================================================================

--[[
	统计最高稀有度，并只给第一个最高稀有度模型打 VFX 标记（开场粒子跟随它）

	@param rewardModels {Model} - 已构建的奖励模型
	@return number - 本批最高 xyd，至少为 1
]]
local function _resolveMaxRarity(rewardModels: {Model}): number
	local maxXyd = 1
	for _, rewardModel in ipairs(rewardModels) do
		local xyd = rewardModel:GetAttribute("xyd")
		if xyd > maxXyd then
			maxXyd = xyd
		end
	end

	for _, rewardModel in ipairs(rewardModels) do
		if rewardModel:GetAttribute("xyd") == maxXyd then
			rewardModel:SetAttribute("VFX", 1)
			break
		end
	end

	return maxXyd
end

--[[
	按稀有度配置并克隆开场粒子（挂到 CurrentCamera）

	@param maxXyd number - 本批最高稀有度
	@return Model? - 开场粒子克隆；OPEN_particles 缺失时 nil
]]
local function _createOpenParticles(maxXyd: number): Model?
	local openParticlesTemplate = HatchConfig.getOpenParticles()
	if not openParticlesTemplate then
		Log.warn("缺少 Hatch/OPEN_particles 资源")
		return nil
	end

	local particleOfOpen = openParticlesTemplate:Clone()
	particleOfOpen.Parent = HatchCamera.getCamera()
	local gradientFolder = HatchConfig.getGradientFolder()

	for _, descendant in pairs(particleOfOpen:GetDescendants()) do
		if not descendant:IsA("ParticleEmitter") then
			continue
		end

		if maxXyd == EnumMgr.Rare.Xyd5 then
			VisibleMgr.RainBowParticle(descendant, HatchConfig.PARTICLE_COLOR_CYCLE)
		elseif maxXyd == EnumMgr.Rare.Xyd6 then
			VisibleMgr.SecretParticle(descendant, HatchConfig.PARTICLE_COLOR_CYCLE)
		else
			local gradient = gradientFolder and gradientFolder:FindFirstChild("稀有度底色" .. maxXyd)
			if gradient and gradient:IsA("UIGradient") then
				descendant.Color = gradient.Color
			end
		end

		descendant.Enabled = true
		descendant:Emit(math.max(1, descendant.Rate / HatchConfig.OPEN_PARTICLE_EMIT_DIV))
		task.wait()
	end

	return particleOfOpen
end

--[[
	初始化奖励模型位置、缩放、阴影与星星粒子

	@param rewardModels {Model} - 已构建的奖励模型（最多 MAX_HATCH_TIME）
	@return {Model}, {CFrame} - 按槽位排列的模型与相对摄像机偏移
]]
local function _prepareRewardModels(rewardModels: {Model}): ({Model}, {CFrame})
	local rewardModelTable: {Model} = {}
	local rewardOffsetTable: {CFrame} = {}
	local camera = HatchCamera.getCamera()
	local starEmitterTemplate = HatchConfig.getStarEmitter()

	for rewardOrder, rewardModel in ipairs(rewardModels) do
		local rewardOffset = HatchConfig.REWARD_OFFSET[rewardOrder]
		if not rewardOffset then
			Log.warn("奖励偏移缺失，跳过序号", rewardOrder)
			continue
		end

		for _, descendant in pairs(rewardModel:GetDescendants()) do
			if descendant:IsA("BasePart") then
				descendant.CastShadow = false
				descendant.CanCollide = false
			end
		end

		local humanoid = rewardModel:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
			if humanoid.HumanoidRootPart then
				humanoid.HumanoidRootPart.Anchored = true
			end
		end

		if rewardOrder == 1 and rewardModel.PrimaryPart then
			local pointLight = Instance.new("PointLight")
			pointLight.Range = HatchConfig.POINT_LIGHT_RANGE
			pointLight.Brightness = HatchConfig.POINT_LIGHT_BRIGHTNESS
			pointLight.Parent = rewardModel.PrimaryPart
		end

		if rewardModel.PrimaryPart and starEmitterTemplate then
			local particleOfStar = starEmitterTemplate:Clone()
			particleOfStar.Parent = rewardModel.PrimaryPart
			FXUtil.Emit_Particles_GetDescendants(particleOfStar, true)
		end

		local cameraPos = HatchCamera.getCameraCFrame()
		rewardModel:PivotTo(cameraPos - rewardModel:GetExtentsSize().Z * cameraPos.LookVector)
		rewardModel.Parent = camera
		VisibleMgr.UnCollideAll(rewardModel)
		rewardModel:ScaleTo(HatchConfig.DEFAULT_REWARD_SCALE)

		local boxSize = rewardModel:GetExtentsSize()
		local screenHeight = boxSize.Y / HatchConfig.REWARD_SCREEN_RATIO
		local boxDistance = screenHeight / 2 / math.tan(math.rad(camera.FieldOfView) / 2)

		rewardModelTable[rewardOrder] = rewardModel
		rewardOffsetTable[rewardOrder] = rewardOffset
			+ Vector3.new(0, 0, -boxDistance / HatchConfig.REWARD_DEPTH_DIVISOR)
	end

	return rewardModelTable, rewardOffsetTable
end

--[[
	播放奖励 idle 动画（解锚非根部件，根部件保持锚定）

	@param rewardModelTable {Model} - 已入场的奖励模型
]]
local function _playIdleAnimations(rewardModelTable: {Model})
	for _, rewardModel in pairs(rewardModelTable) do
		local humanoid = rewardModel:FindFirstChildOfClass("Humanoid")
		if not humanoid then
			continue
		end

		VisibleMgr.UnAnchoredAll(rewardModel)
		if rewardModel.PrimaryPart then
			rewardModel.PrimaryPart.Anchored = true
		end

		local animator = InsMgr.GetIns("Animator", "Animator", humanoid)
		local idleAnim = rewardModel:GetAttribute("idle")
		if idleAnim then
			AnimationModule.PlayAnim(animator, idleAnim)
		end
	end
end

--[[
	同步奖励模型与开场粒子到摄像机相对位姿

	@param ctx PlayContext - 当前播放上下文
	@param postOffset CFrame - 叠在槽位偏移之后的额外变换（结束下落等）
]]
local function _syncRewardTransforms(ctx: PlayContext, postOffset: CFrame)
	for index, rewardModel in ipairs(ctx.rewardModelTable) do
		local offset = ctx.rewardOffsetTable[index]
		if not offset then
			continue
		end

		local cameraPos = HatchCamera.getCameraCFrame()
		local cameraCFrame = cameraPos * offset * postOffset

		rewardModel:PivotTo(cameraCFrame)
		if rewardModel:GetAttribute("VFX") then
			ctx.particleOfOpen:PivotTo(cameraCFrame)
		end
	end
end

--[[
	断开手动跳过输入连接

	@param ctx PlayContext - 当前播放上下文
]]
local function _disconnectSkipInput(ctx: PlayContext)
	if ctx.quitEvent then
		ctx.quitEvent:Disconnect()
		ctx.quitEvent = nil
	end
end

--[[
	请求结束：只置位并断开输入，不写模型。结束动画由 play 主线程收口。

	@param ctx PlayContext - 当前播放上下文
]]
local function _requestEnd(ctx: PlayContext)
	if ctx.ended or ctx.endRequested then
		return
	end
	ctx.endRequested = true
	ctx.rotateSwitch = false
	ctx.waitSwitch = false
	_disconnectSkipInput(ctx)
end

--[[
	播放结束下落动画并 Debris 清理（仅主线程调用）

	@param ctx PlayContext - 当前播放上下文
]]
local function _playEndPhase(ctx: PlayContext)
	if ctx.ended then
		return
	end

	_disconnectSkipInput(ctx)
	ctx.ended = true
	ctx.waitSwitch = false
	ctx.rotateSwitch = false

	HatchAnimUtil.runEasingLoop(
		HatchConfig.END_TIME,
		Enum.EasingStyle.Back,
		Enum.EasingDirection.In,
		function(easingResult)
			_syncRewardTransforms(
				ctx,
				CFrame.new(0, easingResult * HatchConfig.END_DROP_Y, HatchConfig.END_CAMERA_Z)
					* CFrame.Angles(0, math.rad(HatchConfig.END_YAW), 0)
			)
		end
	)

	HatchCamera.restoreZoom()

	for _, rewardModel in pairs(ctx.rewardModelTable) do
		Debris:AddItem(rewardModel, 0)
	end
	if ctx.particleOfOpen then
		Debris:AddItem(ctx.particleOfOpen, 0)
	end
end

--[[
	绑定手动跳过输入（点击 / 触摸 / 手柄 / Q）。回调只应调用 _requestEnd。

	@param ctx PlayContext - 当前播放上下文
	@param onSkip () -> () - 跳过回调；须无阻塞、不写模型
]]
local function _bindSkipInput(ctx: PlayContext, onSkip: () -> ())
	ctx.quitEvent = UserInputService.InputBegan:Connect(function(input, gameProcessedEvent)
		if gameProcessedEvent then
			return
		end
		if ctx.ended or ctx.endRequested then
			return
		end

		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
			or input.UserInputType == Enum.UserInputType.Gamepad1
			or (input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode == Enum.KeyCode.Q)
		then
			onSkip()
		end
	end)
end

--[[
	播放旋转展示阶段（阻塞至转完或 endRequested）

	@param ctx PlayContext - 当前播放上下文
]]
local function _playRotatePhase(ctx: PlayContext)
	local rotateStartClock = os.clock()
	local rotateDuration = HatchConfig.ROTATE_DURATION * ctx.speedScale

	while ctx.rotateSwitch do
		local rotateTime = math.clamp((os.clock() - rotateStartClock) / rotateDuration, 0, 1)
		local rotateResult = TweenService:GetValue(rotateTime, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
		local moveResult = TweenService:GetValue(rotateTime, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out)

		for index, rewardModel in ipairs(ctx.rewardModelTable) do
			local offset = ctx.rewardOffsetTable[index]
			if not offset then
				continue
			end

			local cameraPos = HatchCamera.getCameraCFrame()
			local cameraCFrame = cameraPos
				* CFrame.new(0, 0, HatchConfig.REWARD_ROTATE_START_Z + HatchConfig.REWARD_ROTATE_MOVE_Z * moveResult)
				* offset
				* CFrame.Angles(0, math.rad(rotateResult * HatchConfig.ROTATE_DEGREES), 0)
				* CFrame.Angles(0, math.pi, 0)

			rewardModel:PivotTo(cameraCFrame)
			if rewardModel:GetAttribute("VFX") then
				ctx.particleOfOpen:PivotTo(cameraCFrame)
			end
		end

		RunService.RenderStepped:Wait()
		if rotateTime >= 1 then
			FXUtil.Emit_Particles_GetDescendants(ctx.particleOfOpen, false)
			break
		end
	end
end

--[[
	播放等待展示阶段（阻塞至跳过或自动超时）

	@param ctx PlayContext - 当前播放上下文
	@param isAutoSkip boolean - true 时 WAIT_DURATION 到点后请求结束
	@param onEnd () -> () - 超时回调；须无阻塞（_requestEnd）
]]
local function _playWaitPhase(ctx: PlayContext, isAutoSkip: boolean, onEnd: () -> ())
	local waitStartClock = os.clock()
	local waitDuration = HatchConfig.WAIT_DURATION * ctx.speedScale

	while ctx.waitSwitch do
		local waitTime = math.clamp((os.clock() - waitStartClock) / waitDuration, 0, 1)

		for index, rewardModel in ipairs(ctx.rewardModelTable) do
			local offset = ctx.rewardOffsetTable[index]
			if not offset then
				continue
			end

			local cameraPos = HatchCamera.getCameraCFrame()
			local cameraCFrame = cameraPos
				* CFrame.new(0, 0, HatchConfig.REWARD_WAIT_Z)
				* offset
				* CFrame.Angles(0, math.rad(HatchConfig.END_YAW), 0)

			rewardModel:PivotTo(cameraCFrame)
			if rewardModel:GetAttribute("VFX") then
				ctx.particleOfOpen:PivotTo(cameraCFrame)
			end
		end

		RunService.RenderStepped:Wait()

		if isAutoSkip and waitTime >= 1 then
			onEnd()
		end
	end
end

-- ============================================================================
-- 公共 API
-- ============================================================================

--[[
	播放抽蛋奖励展示完整表现（粒子 → 入场 → 旋转 → 等待/跳过 → 结束下落）。
	阻塞至结束；OPEN_particles 缺失或无可用模型时 restoreZoom 后返回。

	@param rewardModels {Model} - 已构建的奖励模型，空表直接返回
	@param speedScale number? - 时长倍率，默认 1，越大越慢
	@param isAutoSkip boolean? - true 自动结束；false 等待点击/触摸/Q；默认 false
	@return nil - 无返回值
]]
function HatchRewardEffect.play(rewardModels: {Model}, speedScale: number?, isAutoSkip: boolean?)
	if #rewardModels == 0 then
		return
	end

	speedScale = speedScale or 1
	isAutoSkip = isAutoSkip or false

	HatchCamera.setZoomForHatch()

	local maxXyd = _resolveMaxRarity(rewardModels)
	local particleOfOpen = _createOpenParticles(maxXyd)
	if not particleOfOpen then
		HatchCamera.restoreZoom()
		return
	end

	local rewardModelTable, rewardOffsetTable = _prepareRewardModels(rewardModels)
	if #rewardModelTable == 0 then
		Debris:AddItem(particleOfOpen, 0)
		HatchCamera.restoreZoom()
		return
	end

	_playIdleAnimations(rewardModelTable)
	HatchSound.playResult(maxXyd)

	local ctx: PlayContext = {
		rewardModelTable = rewardModelTable,
		rewardOffsetTable = rewardOffsetTable,
		particleOfOpen = particleOfOpen,
		speedScale = speedScale,
		rotateSwitch = true,
		waitSwitch = true,
		ended = false,
		endRequested = false,
		quitEvent = nil,
	}

	if not isAutoSkip then
		_bindSkipInput(ctx, function()
			_requestEnd(ctx)
		end)
	end

	_playRotatePhase(ctx)

	if not ctx.ended then
		_playWaitPhase(ctx, isAutoSkip, function()
			_requestEnd(ctx)
		end)
	end

	if not ctx.ended then
		_playEndPhase(ctx)
	end
end

return HatchRewardEffect
