--[[
	Module: FXUtil/ColorCorrectionCurve
	Description: ColorCorrection MA2 风格 {t,v} 烘焙曲线播放（含 Contrast；窗口门控；租约）
	Author: LinAoyu
	Created: 2026-08-04
	Last Modified: 2026-08-04

	访问：Utils.FXUtil.PlayColorCorrectionCurve

	示例：
		-- 自计时：
		local handle = FXUtil.PlayColorCorrectionCurve(channels, { restoreOnEnd = true })
		-- 与技能/运镜共用绝对时间轴（MA2 对齐推荐）：
		local handle = FXUtil.PlayColorCorrectionCurve({
			-- 与 SpaceSkillKeys 一致：Saturation 约 -1~0；Contrast 约 ±0.25（已 /100 归一）
			saturation = { { t = 8.0833333, v = 0 }, { t = 8.1, v = -1 }, { t = 8.3666667, v = -1 }, { t = 8.3833333, v = 0 } },
			contrast = {
				{ t = 8.0833333, v = 0 }, { t = 8.1, v = -0.25 }, { t = 8.1833333, v = 0.25 },
				{ t = 8.2833333, v = -0.25 }, { t = 8.3666667, v = 0.25 }, { t = 8.3833333, v = 0 },
			},
		}, {
			manualUpdate = true,
			restoreOnEnd = false, -- MA2 末键停在 0，不立刻还原天气快照
		})
		handle.Update(skillElapsed)
		handle.Abort(true)

	窗口门控：仅在各通道键的 [minFirstT, maxLastT] 内写属性。
	与 Set/Tween/Reset 互斥；经 Lighting.FXUtilCcBusy 与 SystemLighting 租约协作。
]]

return function(FXUtil)

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local RunService = Utils.RunService
local KeyframeEval = Utils.KeyframeEval
local Log = Utils.Log
local CcSession = require(script.Parent.ColorCorrectionSession)

type NumberKey = {
	t: number,
	v: number,
	ease: string?,
	easeDir: string?,
}

export type ColorCorrectionCurveChannels = {
	saturation: { NumberKey }?,
	contrast: { NumberKey }?,
	brightness: { NumberKey }?,
}

export type ColorCorrectionCurveOpts = {
	restoreOnEnd: boolean?,
	onComplete: (() -> ())?,
	-- true：不自建 Heartbeat 计时，由 handle.Update(elapsed) 驱动（与技能绝对时间轴对齐）
	manualUpdate: boolean?,
}

export type ColorCorrectionCurveHandle = {
	Abort: (restore: boolean?) -> (),
	IsPlaying: () -> boolean,
	IsHolding: () -> boolean,
	-- manualUpdate 时由外部每帧传入绝对时间（秒）；非 manual 时为空操作
	Update: (elapsed: number) -> (),
}

--[[
	取通道首/末键时间。
	@param keys { NumberKey }? - 关键帧
	@return number? - firstT
	@return number? - lastT
]]
local function _ccKeysSpan(keys: { NumberKey }?): (number?, number?)
	if not keys or #keys == 0 then
		return nil, nil
	end
	return keys[1].t, keys[#keys].t
end

--[[
	计算已提供通道的写入窗口 [windowStart, windowEnd]。
	@param sat { NumberKey }? - Saturation 键
	@param contrast { NumberKey }? - Contrast 键
	@param brightness { NumberKey }? - Brightness 键
	@return number? - windowStart；无有效键时 nil
	@return number? - windowEnd
]]
local function _ccComputeWindow(
	sat: { NumberKey }?,
	contrast: { NumberKey }?,
	brightness: { NumberKey }?
): (number?, number?)
	local windowStart = math.huge
	local windowEnd = -math.huge
	local found = false
	for _, keys in { sat, contrast, brightness } do
		local firstT, lastT = _ccKeysSpan(keys)
		if firstT ~= nil and lastT ~= nil then
			found = true
			windowStart = math.min(windowStart, firstT)
			windowEnd = math.max(windowEnd, lastT)
		end
	end
	if not found then
		return nil, nil
	end
	return windowStart, windowEnd
end

--[[
	播放 ColorCorrection 烘焙曲线（KeyframeEval {t,v}；含 Contrast）。
	默认自 Play 起算 elapsed；manualUpdate 时由 Update(绝对秒) 驱动，与技能/运镜同轴。
	仅在键窗口内写属性；窗口结束后按 restoreOnEnd 决定是否还原快照。
	@param channels ColorCorrectionCurveChannels - saturation / contrast / brightness（至少一路非空）
	@param opts ColorCorrectionCurveOpts? - restoreOnEnd 默认 true；manualUpdate；onComplete
	@return ColorCorrectionCurveHandle? - 无有效通道时 nil
]]
function FXUtil.PlayColorCorrectionCurve(
	channels: ColorCorrectionCurveChannels,
	opts: ColorCorrectionCurveOpts?
): ColorCorrectionCurveHandle?
	if type(channels) ~= "table" then
		return nil
	end

	local satKeys = channels.saturation
	local contrastKeys = channels.contrast
	local brightnessKeys = channels.brightness
	if satKeys and #satKeys == 0 then
		satKeys = nil
	end
	if contrastKeys and #contrastKeys == 0 then
		contrastKeys = nil
	end
	if brightnessKeys and #brightnessKeys == 0 then
		brightnessKeys = nil
	end

	local windowStart, windowEnd = _ccComputeWindow(satKeys, contrastKeys, brightnessKeys)
	if windowStart == nil or windowEnd == nil then
		return nil
	end

	local restoreOnEnd = if opts and opts.restoreOnEnd ~= nil then opts.restoreOnEnd else true
	local onComplete = if opts then opts.onComplete else nil
	local manualUpdate = opts ~= nil and opts.manualUpdate == true

	local effect, snap, ownedTemp = CcSession.BeginWriteSession(true)
	effect.Enabled = true

	local mySeq = CcSession.keyframeSeq
	local elapsed = 0
	local completed = false

	CcSession.curvePlaying = true
	CcSession.curveHolding = false
	CcSession.curveOnComplete = onComplete
	CcSession.curveSnap = snap
	CcSession.curveOwnedTemp = ownedTemp
	CcSession.curveEffect = effect

	--[[
		结束并按策略收口。
		@param restore boolean? - true 显式还原进 FX 前快照；nil 跟 restoreOnEnd（自然结束走 Manager reconcile）；false 不还原
	]]
	local function abort(restore: boolean?)
		-- 自然结束后仍允许 Abort(true) 还原（技能 teardown）
		if completed and not CcSession.curvePlaying and not CcSession.curveConn then
			if restore == true then
				CcSession.RestoreHolding(effect, snap)
			end
			return
		end
		if not CcSession.curvePlaying and not CcSession.curveConn then
			return
		end
		if mySeq ~= CcSession.keyframeSeq then
			return
		end
		CcSession.keyframeSeq += 1

		if restore == true then
			-- 显式 Abort：写回进 FX 前快照（与自然结束 reconcile 路径区分）
			if CcSession.curveConn then
				CcSession.curveConn:Disconnect()
				CcSession.curveConn = nil
			end
			CcSession.curvePlaying = false
			CcSession.curveOnComplete = nil
			CcSession.ApplyRestore(effect, snap, ownedTemp)
			if CcSession.targetEffect == effect then
				CcSession.ClearWriteTarget()
			end
			CcSession.curveSnap = nil
			CcSession.curveEffect = nil
			CcSession.curveOwnedTemp = false
			CcSession.curveHolding = false
			CcSession.SetBusy(false)
			return
		end

		local doReconcile = restore == nil and restoreOnEnd
		CcSession.FinishCurve(doReconcile, false, false)
		if not doReconcile then
			-- 中断且不还原：仍占租约直至 Reset / 新会话 / 显式 Holding Abort
			CcSession.curveHolding = false
		end
	end

	--[[
		采样并写入当前窗口内通道。
		@param t number - 绝对时间秒
	]]
	local function applyAt(t: number)
		if satKeys then
			effect.Saturation = KeyframeEval.EvalNumber(satKeys, t)
		end
		if contrastKeys then
			effect.Contrast = KeyframeEval.EvalNumber(contrastKeys, t)
		end
		if brightnessKeys then
			effect.Brightness = KeyframeEval.EvalNumber(brightnessKeys, t)
		end
	end

	--[[
		按绝对时间推进一帧（窗口门控 + 结束收口）。
		@param t number - 技能/自计时绝对秒
	]]
	local function stepAt(t: number)
		if mySeq ~= CcSession.keyframeSeq or completed then
			return
		end
		if not effect.Parent then
			completed = true
			CcSession.keyframeSeq += 1
			CcSession.FinishCurve(false, false, false)
			CcSession.ClearWriteTarget()
			CcSession.SetBusy(false)
			return
		end

		if t < windowStart then
			return
		end

		if t >= windowEnd then
			applyAt(windowEnd)
			completed = true
			CcSession.keyframeSeq += 1
			-- restoreOnEnd=false：保持末键（MA2 归零）；仍清 Heartbeat，快照留到 Abort
			if restoreOnEnd then
				CcSession.FinishCurve(true, true, false)
			else
				if CcSession.curveConn then
					CcSession.curveConn:Disconnect()
					CcSession.curveConn = nil
				end
				CcSession.curvePlaying = false
				CcSession.curveHolding = true
				local cb = CcSession.curveOnComplete
				CcSession.curveOnComplete = nil
				if type(cb) == "function" then
					task.defer(function()
						local ok, err = pcall(cb)
						if not ok then
							Log.warn("[FXUtil] PlayColorCorrectionCurve onComplete:", err)
						end
					end)
				end
			end
			return
		end

		applyAt(t)
	end

	if not manualUpdate then
		CcSession.curveConn = RunService.Heartbeat:Connect(function(dt: number)
			if mySeq ~= CcSession.keyframeSeq or completed then
				return
			end
			elapsed += dt
			stepAt(elapsed)
		end)
	end

	return {
		-- 兼容 h.Abort(true) 与 h:Abort(true)（后者首参为 self）
		Abort = function(a: any?, b: any?)
			local restore: boolean?
			if type(a) == "boolean" or a == nil then
				restore = a
			else
				restore = b
			end
			abort(restore)
		end,
		IsPlaying = function()
			return CcSession.curvePlaying and mySeq == CcSession.keyframeSeq and not completed
		end,
		IsHolding = function()
			-- 自然结束会 bump seq；Holding 只看会话标志
			return CcSession.curveHolding == true
		end,
		Update = function(a: any?, b: any?)
			if not manualUpdate or completed then
				return
			end
			local t: number?
			if type(a) == "number" then
				t = a
			elseif type(b) == "number" then
				t = b
			end
			if type(t) ~= "number" then
				return
			end
			stepAt(t)
		end,
	}
end

end
