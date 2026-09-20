--[[
	Module: HatchEffect/HatchBoxEffect
	Description: 抽蛋容器掉落、抖动、放大表现
	Author: 林奥宇
	Created: 2026-01-29
	Last Modified: 2026-09-01

	由 HatchEffect.ShowHatchEffect 内部调用。资源缺失时 play 返回 false，调用方仍可继续奖励阶段。
]]

-- ============================================================================
-- 服务与依赖
-- ============================================================================

local Debris = game:GetService("Debris")

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local VisibleMgr = Utils.VisibleMgr
local FXUtil = Utils.FXUtil
local Log = Utils.Log

local HatchConfig = require(script.Parent.HatchConfig)
local HatchAnimUtil = require(script.Parent.HatchAnimUtil)
local HatchCamera = require(script.Parent.HatchCamera)
local HatchSound = require(script.Parent.HatchSound)

local rng = Random.new()

local HatchBoxEffect = {}

-- ============================================================================
-- 私有函数
-- ============================================================================

--[[
	初始化并克隆指定数量的容器模型（挂到 CurrentCamera）

	@param boxModel Model - GetModel 得到的宠物蛋克隆，本函数再 Clone 出 hatchTime 份
	@param hatchTime number - 容器数量，已 clamp 到 1~MAX_HATCH_TIME
	@return {Model}?, {CFrame}? - 模型表与相对偏移；缺 star_particles 时均为 nil
]]
local function _createStarModels(boxModel: Model, hatchTime: number): ({Model}?, {CFrame}?)
	local starParticlesTemplate = HatchConfig.getStarParticles()
	if not starParticlesTemplate then
		Log.warn("缺少 Hatch/star_particles 资源")
		return nil, nil
	end

	local starModelTable: {Model} = {}
	local starCFrameTable: {CFrame} = {}
	local camera = HatchCamera.getCamera()

	for boxOrder = 1, hatchTime do
		local starModel = boxModel:Clone()
		local starParticle = starParticlesTemplate:Clone()

		starModel.Parent = camera
		starParticle:PivotTo(starModel:GetPivot())
		starParticle.Parent = starModel
		VisibleMgr.UnCollideAll(starModel)
		VisibleMgr.AnchoredAll(starModel)
		starModel:ScaleTo(HatchConfig.DEFAULT_SCALE)
		starModel:SetAttribute("OriScale", starModel:GetScale())

		if boxOrder == 1 and starModel.PrimaryPart then
			local pointLight = Instance.new("PointLight")
			pointLight.Range = HatchConfig.POINT_LIGHT_RANGE
			pointLight.Brightness = HatchConfig.POINT_LIGHT_BRIGHTNESS
			pointLight.Parent = starModel.PrimaryPart
		end

		starModelTable[boxOrder] = starModel
		starCFrameTable[boxOrder] = HatchConfig.STAR_OFFSET[boxOrder] * CFrame.Angles(0, math.rad(180), 0)
	end

	return starModelTable, starCFrameTable
end

--[[
	播放容器掉落动画（阻塞）

	@param starModelTable {Model} - 已挂到摄像机的容器模型
	@param starCFrameTable {CFrame} - 与模型一一对应的相对偏移
	@param speedScale number - 时长倍率，越大越慢
]]
local function _playFall(starModelTable: {Model}, starCFrameTable: {CFrame}, speedScale: number)
	HatchSound.play("抽蛋_掉落")
	HatchAnimUtil.runEasingLoop(
		HatchConfig.FALL_TIME * speedScale,
		Enum.EasingStyle.Elastic,
		Enum.EasingDirection.Out,
		function(easingResult)
			local cameraPos = HatchCamera.getCameraCFrame()
			for index, starModel in ipairs(starModelTable) do
				starModel:PivotTo(
					cameraPos:ToWorldSpace(
						CFrame.new(
							0,
							HatchConfig.FALL_DISTANCE - easingResult * HatchConfig.FALL_DISTANCE,
							HatchConfig.CONTAINER_DISTANCE_FROM_CAMERA + easingResult * HatchConfig.FALL_DISTANCE
						) * starCFrameTable[index]
					)
				)
			end
		end
	)
end

--[[
	播放容器抖动与收缩（阻塞）

	@param starModelTable {Model} - 容器模型
	@param starCFrameTable {CFrame} - 相对偏移
	@param speedScale number - 时长倍率，越大越慢
]]
local function _playShake(starModelTable: {Model}, starCFrameTable: {CFrame}, speedScale: number)
	local offsetCFrame = CFrame.new(0, 0, HatchConfig.BOX_SHAKE_OFFSET_Z)

	for shakeIndex = 1, HatchConfig.SHAKE_COUNT do
		for _, starModel in pairs(starModelTable) do
			FXUtil.Emit_Particles_GetDescendants(starModel.star_particles, true)
		end

		local shakeSoundName = HatchConfig.SHAKE_SOUND_NAMES[shakeIndex]
		if shakeSoundName then
			HatchSound.play(shakeSoundName)
		end

		local offsetX = shakeIndex % 2 == 0
			and rng:NextNumber(-HatchConfig.SHAKE_ANGLE_MAX, -HatchConfig.SHAKE_ANGLE_MIN)
			or rng:NextNumber(HatchConfig.SHAKE_ANGLE_MIN, HatchConfig.SHAKE_ANGLE_MAX)
		local shakeDuration = 1
			/ math.max(shakeIndex * HatchConfig.SHAKE_DURATION_INDEX_MUL, HatchConfig.SHAKE_DURATION_MIN_DIV)
			* speedScale

		HatchAnimUtil.runEasingLoop(shakeDuration, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out, function(easingResult)
			local cameraPos = HatchCamera.getCameraCFrame()
			for index, starModel in ipairs(starModelTable) do
				starModel:PivotTo(
					cameraPos
						* offsetCFrame
						* starCFrameTable[index]
						* CFrame.new(HatchConfig.SHAKE_POS_OFFSET * easingResult, 0, 0)
						* CFrame.Angles(0, 0, math.rad(offsetX * easingResult))
				)
			end
		end)

		local restoreDuration = HatchConfig.SHAKE_RESTORE_STEP
			/ math.max(shakeIndex * HatchConfig.SHAKE_RESTORE_INDEX_MUL, 1)
			* speedScale
		HatchAnimUtil.runEasingLoop(restoreDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, function(easingResult)
			local cameraPos = HatchCamera.getCameraCFrame()
			for index, starModel in ipairs(starModelTable) do
				starModel:PivotTo(
					cameraPos
						* offsetCFrame
						* starCFrameTable[index]
						* CFrame.new(
							HatchConfig.SHAKE_POS_OFFSET - HatchConfig.SHAKE_POS_OFFSET * easingResult,
							0,
							0
						)
						* CFrame.Angles(0, 0, math.rad(offsetX - easingResult * offsetX))
				)
			end
		end)
	end

	HatchAnimUtil.runEasingLoop(HatchConfig.RESTORE_TIME * speedScale, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, function(easingResult)
		local cameraPos = HatchCamera.getCameraCFrame()
		for index, starModel in ipairs(starModelTable) do
			starModel:ScaleTo(starModel:GetAttribute("OriScale") * (1 - easingResult * HatchConfig.SHAKE_SCALE_SHRINK))
			starModel:PivotTo(cameraPos * offsetCFrame * starCFrameTable[index])
		end
	end)
end

--[[
	播放容器放大并 Debris 销毁（阻塞）

	@param starModelTable {Model} - 容器模型
	@param starCFrameTable {CFrame} - 相对偏移
	@param speedScale number - 时长倍率，越大越慢
]]
local function _playEnlargeAndDestroy(starModelTable: {Model}, starCFrameTable: {CFrame}, speedScale: number)
	local offsetCFrame = CFrame.new(0, 0, HatchConfig.BOX_SHAKE_OFFSET_Z)

	HatchSound.play("抽蛋_放大")
	HatchAnimUtil.runEasingLoop(HatchConfig.ENLARGE_TIME * speedScale, Enum.EasingStyle.Sine, Enum.EasingDirection.Out, function(easingResult)
		local cameraPos = HatchCamera.getCameraCFrame()
		for index, starModel in ipairs(starModelTable) do
			starModel:ScaleTo(starModel:GetAttribute("OriScale") * (1 + easingResult * HatchConfig.ENLARGE_SCALE_ADD))
			starModel:PivotTo(cameraPos * offsetCFrame * starCFrameTable[index])
		end
	end)

	for _, starModel in ipairs(starModelTable) do
		Debris:AddItem(starModel, 0)
	end
end

-- ============================================================================
-- 公共 API
-- ============================================================================

--[[
	播放抽蛋容器完整表现（掉落 → 抖动 → 放大销毁）。
	成功时保持 CameraMinZoomDistance 为抽蛋值，由后续奖励阶段 restore。

	@param boxModel Model - 宠物蛋克隆
	@param hatchTime number - 容器数量，内部再 clamp 到 1~MAX_HATCH_TIME
	@param speedScale number? - 时长倍率，默认 1，越大越慢
	@return boolean - 是否成功播放；star_particles 缺失时 false 并 restoreZoom
]]
function HatchBoxEffect.play(boxModel: Model, hatchTime: number, speedScale: number?): boolean
	speedScale = speedScale or 1
	hatchTime = math.clamp(hatchTime, 1, HatchConfig.MAX_HATCH_TIME)

	HatchCamera.setZoomForHatch()

	local starModelTable, starCFrameTable = _createStarModels(boxModel, hatchTime)
	if not starModelTable or not starCFrameTable then
		HatchCamera.restoreZoom()
		return false
	end

	_playFall(starModelTable, starCFrameTable, speedScale)
	_playShake(starModelTable, starCFrameTable, speedScale)
	_playEnlargeAndDestroy(starModelTable, starCFrameTable, speedScale)

	return true
end

return HatchBoxEffect
