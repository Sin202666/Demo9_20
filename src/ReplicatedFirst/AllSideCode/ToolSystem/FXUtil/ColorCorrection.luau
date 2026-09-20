--[[
	Module: FXUtil/ColorCorrection
	Description: ColorCorrection 瞬时设置与旧版 Tween（Deprecated）
	Author: LinAoyu
	Created: 2024-01-01
	Last Modified: 2026-08-04

	访问：Utils.FXUtil（不占 Utils 顶层键）

	@deprecated 新演出请用 FXUtil.PlayColorCorrectionCurve（见 ColorCorrectionCurve）。
	本文件仅保留瞬时 / 旧 Tween（{time,value}+Enum easing，无 Contrast 通道）：
		FXUtil.Set_ColorCorrection(brightness, tintColor, saturation?)
		FXUtil.Tween_ColorCorrection(data)
		FXUtil.Reset_ColorCorrection()
		FXUtil.IsColorCorrectionBusy()

	与 SystemLighting 经 Lighting.FXUtilCcBusy 租约互斥写 Instance。
]]

return function(FXUtil)

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local TweenService = Utils.TweenService
local RunService = Utils.RunService
local Log = Utils.Log
local CcSession = require(script.Parent.ColorCorrectionSession)

CcSession.Install(FXUtil)

--[[
	设置滤镜 ColorCorrection（无动画）。与关键帧 Tween / Reset / Play 共用快照与临时实例状态。
	@deprecated 优先 PlayColorCorrectionCurve
	@param brightness number - 亮度
	@param tintColor Color3 - 色调
	@param saturation number? - 饱和度；nil 则不改
]]
function FXUtil.Set_ColorCorrection(brightness: number, tintColor: Color3, saturation: number?)
	local effect, _snap, _owned, _created = CcSession.BeginWriteSession(true)

	effect.Brightness = brightness
	effect.TintColor = tintColor
	if saturation ~= nil then
		effect.Saturation = saturation
	end
end

--[[
	恢复滤镜或销毁 Set/Tween/Play 创建的临时 ColorCorrectionEffect；释放租约。
]]
function FXUtil.Reset_ColorCorrection()
	CcSession.AbortKeyframeAnim()

	local effect = CcSession.targetEffect
	if not effect or not effect.Parent then
		CcSession.ClearWriteTarget()
		CcSession.SetBusy(false)
		return
	end

	CcSession.ReleaseWriteSession(true)
end

--[[
	从关键帧数据表提取并排序指定通道的关键帧数组
	@param d table - 数据表
	@param key string - 通道名
	@return { any }? - 排序后关键帧；无则 nil
]]
local function _ccExtractKeyframes(d: { [string]: any }, key: string): { any }?
	local v = d[key]
	if type(v) ~= "table" then
		return nil
	end
	local arr = {}
	for _, kf in ipairs(v) do
		if type(kf) == "table" and type(kf.time) == "number" and kf.time >= 0 then
			table.insert(arr, kf)
		end
	end
	table.sort(arr, function(a, b)
		return a.time < b.time
	end)
	return #arr > 0 and arr or nil
end

--[[
	关键帧通道的最大时间
	@param kfs { any } - 关键帧数组
	@return number - 最大 time
]]
local function _ccChannelMaxTime(kfs: { any }): number
	local m = 0
	for _, kf in ipairs(kfs) do
		if kf.time > m then
			m = kf.time
		end
	end
	return m
end

--[[
	数值通道关键帧采样
	@param nowT number - 当前时间
	@param keyframes { any } - 关键帧
	@param startVal number - 起始值
	@return number - 采样值
]]
local function _ccSampleNumeric(nowT: number, keyframes: { any }, startVal: number): number
	local prevT = 0
	local prevV = startVal
	for _, kf in ipairs(keyframes) do
		local t1 = kf.time
		local v1 = kf.value
		if type(v1) ~= "number" then
			continue
		end
		if nowT <= t1 then
			local dur = t1 - prevT
			if dur <= 1e-5 then
				return v1
			end
			local alpha = TweenService:GetValue(
				math.clamp((nowT - prevT) / dur, 0, 1),
				kf.easingStyle or Enum.EasingStyle.Linear,
				kf.easingDir or Enum.EasingDirection.In
			)
			return prevV + (v1 - prevV) * alpha
		end
		prevT = t1
		prevV = v1
	end
	return prevV
end

--[[
	Color3 通道关键帧采样
	@param nowT number - 当前时间
	@param keyframes { any } - 关键帧
	@param startVal Color3 - 起始色
	@return Color3 - 采样色
]]
local function _ccSampleColor3(nowT: number, keyframes: { any }, startVal: Color3): Color3
	local prevT = 0
	local prevV = startVal
	for _, kf in ipairs(keyframes) do
		local t1 = kf.time
		local v1 = kf.value
		if typeof(v1) ~= "Color3" then
			continue
		end
		if nowT <= t1 then
			local dur = t1 - prevT
			if dur <= 1e-5 then
				return v1
			end
			local alpha = TweenService:GetValue(
				math.clamp((nowT - prevT) / dur, 0, 1),
				kf.easingStyle or Enum.EasingStyle.Linear,
				kf.easingDir or Enum.EasingDirection.In
			)
			return Color3.new(
				prevV.R + (v1.R - prevV.R) * alpha,
				prevV.G + (v1.G - prevV.G) * alpha,
				prevV.B + (v1.B - prevV.B) * alpha
			)
		end
		prevT = t1
		prevV = v1
	end
	return prevV
end

--[[
	旧版关键帧 Tween；结束后还原并释放租约。
	@deprecated 优先 PlayColorCorrectionCurve
	@param data {[string]: any} - brightness/tintColor/saturation 通道；可选 onComplete
]]
function FXUtil.Tween_ColorCorrection(data: { [string]: any })
	if not data then
		return
	end

	local kfBrightness = _ccExtractKeyframes(data, "brightness")
	local kfTint = _ccExtractKeyframes(data, "tintColor")
	local kfSaturation = _ccExtractKeyframes(data, "saturation")

	if not kfBrightness and not kfTint and not kfSaturation then
		return
	end

	local duration = 0
	if kfBrightness then
		duration = math.max(duration, _ccChannelMaxTime(kfBrightness))
	end
	if kfTint then
		duration = math.max(duration, _ccChannelMaxTime(kfTint))
	end
	if kfSaturation then
		duration = math.max(duration, _ccChannelMaxTime(kfSaturation))
	end
	if duration <= 0 then
		return
	end

	local effect, _snap, ownedTemp = CcSession.BeginWriteSession(true)

	local startB = effect.Brightness
	local startS = effect.Saturation
	local startC = effect.TintColor

	local onComplete = data.onComplete
	local targetRef = effect

	local mySeq = CcSession.keyframeSeq
	local tAccum = 0

	local function finishAndCleanup()
		if mySeq ~= CcSession.keyframeSeq then
			return
		end
		if CcSession.keyframeConn then
			CcSession.keyframeConn:Disconnect()
			CcSession.keyframeConn = nil
		end
		CcSession.keyframeSeq += 1

		-- 自然结束：毁 Temp、不写过期 snap；SetBusy(false) 后由 LightingManager reconcile
		if ownedTemp and targetRef.Parent then
			targetRef:Destroy()
		end
		CcSession.ClearWriteTarget()
		CcSession.SetBusy(false)

		if type(onComplete) == "function" then
			task.defer(function()
				local ok, err = pcall(onComplete)
				if not ok then
					Log.warn("[FXUtil] Tween_ColorCorrection onComplete:", err)
				end
			end)
		end
	end

	CcSession.keyframeConn = RunService.Heartbeat:Connect(function(dt: number)
		if mySeq ~= CcSession.keyframeSeq then
			return
		end
		if not effect.Parent then
			finishAndCleanup()
			return
		end

		tAccum += dt
		local nowT = math.min(tAccum, duration)

		if kfBrightness then
			effect.Brightness = _ccSampleNumeric(nowT, kfBrightness, startB)
		end
		if kfTint then
			effect.TintColor = _ccSampleColor3(nowT, kfTint, startC)
		end
		if kfSaturation then
			effect.Saturation = _ccSampleNumeric(nowT, kfSaturation, startS)
		end

		if tAccum >= duration then
			finishAndCleanup()
		end
	end)
end

end
