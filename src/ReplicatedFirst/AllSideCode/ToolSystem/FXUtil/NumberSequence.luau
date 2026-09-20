--[[
	Module: FXUtil/NumberSequence
	Description: NumberSequence 工具与 Beam 渐显
	Author: LinAoyu
	Created: 2024-01-01
	Last Modified: 2026-07-02
]]

return function(FXUtil)

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
-- ============================================
-- NumberSequence 工具 (NumberSequence Utilities)
-- ============================================

--[[
	深拷贝 NumberSequence
	@param seq NumberSequence
	@return NumberSequence
]]
function FXUtil.CloneNumberSequence(seq: NumberSequence): NumberSequence
	local t = {}
	for _, kp in seq.Keypoints do
		table.insert(t, NumberSequenceKeypoint.new(kp.Time, kp.Value, kp.Envelope or 0))
	end
	return NumberSequence.new(t)
end

--[[
	在 NumberSequence 上按 timePos 采样（线性插值）
	@param seq NumberSequence
	@param timePos number 0~1
	@return number
]]
function FXUtil.SampleNumberSequence(seq: NumberSequence, timePos: number): number
	local kps = seq.Keypoints
	local n = #kps
	if n == 0 then
		return 1
	end
	if timePos <= kps[1].Time then
		return kps[1].Value
	end
	if timePos >= kps[n].Time then
		return kps[n].Value
	end
	for i = 1, n - 1 do
		local a, b = kps[i], kps[i + 1]
		if timePos >= a.Time and timePos <= b.Time then
			local span = b.Time - a.Time
			if span <= 1e-8 then
				return b.Value
			end
			local alpha = (timePos - a.Time) / span
			return a.Value + (b.Value - a.Value) * alpha
		end
	end
	return kps[n].Value
end

--[[
	Beam 透明度从左端截断：[0, cutoff) 保持原序列值；cutoff 起向右强制透明 1。
	用于实现「沿梁方向逐渐揭开」的视觉效果。
	@param orig NumberSequence 原始 Transparency
	@param cutoff number 0~1，截断位置
	@return NumberSequence
]]
function FXUtil.BuildBeamTransparencyCut(orig: NumberSequence, cutoff: number): NumberSequence
	cutoff = math.clamp(cutoff, 0, 1)
	if cutoff >= 0.999 then
		return FXUtil.CloneNumberSequence(orig)
	end
	local src = orig.Keypoints
	local out: { NumberSequenceKeypoint } = {}
	for _, kp in ipairs(src) do
		if kp.Time < cutoff - 1e-5 then
			table.insert(out, NumberSequenceKeypoint.new(kp.Time, kp.Value, kp.Envelope or 0))
		end
	end
	local vSeam = FXUtil.SampleNumberSequence(orig, cutoff)
	table.insert(out, NumberSequenceKeypoint.new(cutoff, vSeam, 0))
	local t2 = math.min(cutoff + 0.003, 1)
	if t2 > cutoff + 1e-6 then
		table.insert(out, NumberSequenceKeypoint.new(t2, 1, 0))
	end
	for _, kp in ipairs(src) do
		if kp.Time > t2 + 1e-5 then
			table.insert(out, NumberSequenceKeypoint.new(kp.Time, 1, kp.Envelope or 0))
		end
	end
	if #out == 0 or out[#out].Time < 1 - 1e-5 then
		table.insert(out, NumberSequenceKeypoint.new(1, 1, 0))
	end
	table.sort(out, function(a, b)
		return a.Time < b.Time
	end)
	if #out < 2 then
		table.insert(out, NumberSequenceKeypoint.new(1, 1, 0))
	end
	return NumberSequence.new(out)
end

--[[
	Beam 渐显揭示：从左到右逐渐显现，用 Heartbeat 逐帧推进截断点。
	@param beams { Beam } 要揭示的 Beam 列表
	@param revealTime number 揭示时长（秒）
	@param easingStyle Enum.EasingStyle? 默认 Quad
	@param easingDir Enum.EasingDirection? 默认 Out
	@return RBXScriptConnection 可用于提前断开
]]
function FXUtil.Beam_Reveal_From_Left(
	beams: { Beam },
	revealTime: number,
	easingStyle: Enum.EasingStyle?,
	easingDir: Enum.EasingDirection?
): RBXScriptConnection?
	if #beams == 0 then
		return nil
	end
	local eStyle = easingStyle or Enum.EasingStyle.Quad
	local eDir = easingDir or Enum.EasingDirection.Out

	local entries: { { beam: Beam, ori: NumberSequence } } = {}
	for _, b in beams do
		local ori = FXUtil.CloneNumberSequence(b.Transparency)
		table.insert(entries, { beam = b, ori = ori })
		b.Enabled = true
		b.Transparency = FXUtil.BuildBeamTransparencyCut(ori, 0)
	end

	local t0 = os.clock()
	local conn: RBXScriptConnection
	conn = RunService.Heartbeat:Connect(function()
		local allGone = true
		for _, e in entries do
			if e.beam.Parent then
				allGone = false
				break
			end
		end
		if allGone then
			conn:Disconnect()
			return
		end
		local u = (os.clock() - t0) / revealTime
		if u >= 1 then
			for _, e in entries do
				if e.beam.Parent then
					e.beam.Transparency = e.ori
				end
			end
			conn:Disconnect()
			return
		end
		local eased = TweenService:GetValue(u, eStyle, eDir)
		for _, e in entries do
			if e.beam.Parent then
				e.beam.Transparency = FXUtil.BuildBeamTransparencyCut(e.ori, eased)
			end
		end
	end)
	return conn
end
end