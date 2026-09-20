--[[
	Module: FXUtil/BeamWidthCurve
	Description: Beam Width0/Width1 关键帧曲线播放（通用；可对齐 MA2 Width 轨道，可中断）
	Author: 中台组
	Created: 2026-08-03
	Last Modified: 2026-08-03

	泛用：任意 Beam Width 动画。与 Beam_Reveal_From_Left 并存（揭示用透明度，严格 Width 用本模块）。
	访问：Utils.FXUtil.PlayBeamWidthCurve（不占 Utils 顶层键）。

	示例：
		local handle = FXUtil.PlayBeamWidthCurve(beams, width0Keys, width1Keys, {
			restoreOnEnd = true,
			keepWidth1 = true, -- 仅驱动 Width0（MA2 裂隙）
			onComplete = function() end,
		})
		handle.Abort(true)
]]

return function(FXUtil)

local RunService = game:GetService("RunService")
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local KeyframeEval = Utils.KeyframeEval

type NumberKey = {
	t: number,
	v: number,
	ease: string?,
	easeDir: string?,
}

export type BeamWidthCurveOpts = {
	restoreOnEnd: boolean?,
	-- true：不改 Width1（对齐 MA2 仅驱动 Width0、Width1 保持资源值）
	keepWidth1: boolean?,
	onComplete: (() -> ())?,
}

export type BeamWidthCurveHandle = {
	Abort: (restore: boolean?) -> (),
	IsPlaying: () -> boolean,
}

type _BeamSnap = {
	beam: Beam,
	width0: number,
	width1: number,
}

local _nextSeq = 0
local _active: { [number]: { conn: RBXScriptConnection?, snaps: { _BeamSnap } } } = {}

--[[
	收集 Beam 列表（支持单 Beam 或数组）
	@param beams Beam | { Beam } - 目标 Beam
	@return { Beam } - 规范化列表
]]
local function _normalizeBeams(beams: Beam | { Beam }): { Beam }
	if typeof(beams) == "Instance" and (beams :: Instance):IsA("Beam") then
		return { beams :: Beam }
	end
	local out: { Beam } = {}
	if type(beams) == "table" then
		for _, b in beams do
			if typeof(b) == "Instance" and b:IsA("Beam") then
				table.insert(out, b)
			end
		end
	end
	return out
end

--[[
	计算关键帧总时长（末关键帧 t）
	@param keys { NumberKey }? - 关键帧
	@return number - 时长秒
]]
local function _keysDuration(keys: { NumberKey }?): number
	if not keys or #keys == 0 then
		return 0
	end
	return keys[#keys].t
end

--[[
	恢复快照 Width
	@param snaps { _BeamSnap } - 开始前快照
]]
local function _restoreSnaps(snaps: { _BeamSnap })
	for _, snap in snaps do
		if snap.beam.Parent then
			snap.beam.Width0 = snap.width0
			snap.beam.Width1 = snap.width1
		end
	end
end

--[[
	播放 Beam Width0/Width1 关键帧曲线
	@param beams Beam | { Beam } - 目标 Beam（同曲线批量驱动）
	@param width0Keys { NumberKey } - Width0 关键帧（秒）
	@param width1Keys { NumberKey }? - Width1 关键帧；nil 时与 Width0 共用（keepWidth1 时忽略）
	@param opts BeamWidthCurveOpts? - restoreOnEnd / keepWidth1 / onComplete
	@return BeamWidthCurveHandle? - 句柄；无有效 Beam 或空关键帧时 nil
]]
function FXUtil.PlayBeamWidthCurve(
	beams: Beam | { Beam },
	width0Keys: { NumberKey },
	width1Keys: { NumberKey }?,
	opts: BeamWidthCurveOpts?
): BeamWidthCurveHandle?
	local list = _normalizeBeams(beams)
	if #list == 0 then
		return nil
	end
	if type(width0Keys) ~= "table" or #width0Keys == 0 then
		return nil
	end

	local keepWidth1 = opts ~= nil and opts.keepWidth1 == true
	local w1Keys = width1Keys
	if not keepWidth1 then
		if not w1Keys or #w1Keys == 0 then
			w1Keys = width0Keys
		end
	end

	local duration = _keysDuration(width0Keys)
	if not keepWidth1 and w1Keys then
		duration = math.max(duration, _keysDuration(w1Keys))
	end
	local restoreOnEnd = if opts and opts.restoreOnEnd ~= nil then opts.restoreOnEnd else false
	local onComplete = if opts then opts.onComplete else nil

	local snaps: { _BeamSnap } = {}
	for _, beam in list do
		table.insert(snaps, {
			beam = beam,
			width0 = beam.Width0,
			width1 = beam.Width1,
		})
	end

	_nextSeq += 1
	local seq = _nextSeq
	local elapsed = 0
	local playing = true

	local function abort(restore: boolean?)
		local entry = _active[seq]
		if not entry then
			return
		end
		if entry.conn then
			entry.conn:Disconnect()
			entry.conn = nil
		end
		_active[seq] = nil
		playing = false
		if restore == true or (restore == nil and restoreOnEnd) then
			_restoreSnaps(entry.snaps)
		end
	end

	local conn = RunService.Heartbeat:Connect(function(dt: number)
		local entry = _active[seq]
		if not entry then
			return
		end
		elapsed += dt
		local t = math.min(elapsed, duration)
		local w0 = KeyframeEval.EvalNumber(width0Keys, t)
		local w1 = if keepWidth1 or not w1Keys then nil else KeyframeEval.EvalNumber(w1Keys, t)
		for _, snap in entry.snaps do
			if snap.beam.Parent then
				snap.beam.Width0 = w0
				if w1 ~= nil then
					snap.beam.Width1 = w1
				end
			end
		end
		if elapsed >= duration then
			abort(restoreOnEnd)
			if onComplete then
				onComplete()
			end
		end
	end)

	_active[seq] = { conn = conn, snaps = snaps }

	return {
		Abort = function(restore: boolean?)
			abort(restore)
		end,
		IsPlaying = function()
			return playing and _active[seq] ~= nil
		end,
	}
end

--[[
	中断所有由本模块启动的 Width 曲线（可选还原）
	@param restore boolean? - true 时还原快照 Width
]]
function FXUtil.AbortAllBeamWidthCurves(restore: boolean?)
	local ids = {}
	for seq in pairs(_active) do
		table.insert(ids, seq)
	end
	for _, seq in ids do
		local entry = _active[seq]
		if entry and entry.conn then
			entry.conn:Disconnect()
		end
		if restore and entry then
			_restoreSnaps(entry.snaps)
		end
		_active[seq] = nil
	end
end

end
