--[[
	Module: KeyframeEval
	Description: 无状态关键帧求值（标量 / CFrame）— 框架级通用工具
	Author: 中台组
	Created: 2026-08-03
	Last Modified: 2026-08-03

	挂载：Utils.KeyframeEval（ToolBasic，跨技能/运镜/FX 复用）。

	能力：
	- 按时间 t（秒）在有序关键帧上求值；越界钳制到首/末关键帧
	- Ease 名对齐 MA2 常见写法（Quad/Cubic/Back/… + In/Out/InOut），未知则 Linear
	- CFrame：位置线性插值 + 旋转 slerp

	与 AnchorRelative：
	- 本模块只求「局部位姿/标量」曲线；世界坐标用 AnchorRelative.ToWorld(anchorCF, localCF)

	加载：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local KeyframeEval = Utils.KeyframeEval

	示例：
		local fov = KeyframeEval.EvalNumber({
			{ t = 0, v = 70 },
			{ t = 1.5, v = 30, ease = "Quad", easeDir = "In" },
			{ t = 2.7, v = 110, ease = "Back", easeDir = "Out" },
		}, nowSec)
		local localCF = KeyframeEval.EvalCFrame(camKeys, nowSec)
]]

local TweenService = game:GetService("TweenService")

local KeyframeEval = {}

export type NumberKey = {
	t: number,
	v: number,
	ease: string?,
	easeDir: string?,
}

export type CFrameKey = {
	t: number,
	v: CFrame,
	ease: string?,
	easeDir: string?,
}

local EASE_STYLE: { [string]: Enum.EasingStyle } = {
	Linear = Enum.EasingStyle.Linear,
	Sine = Enum.EasingStyle.Sine,
	Quad = Enum.EasingStyle.Quad,
	Cubic = Enum.EasingStyle.Cubic,
	Quart = Enum.EasingStyle.Quart,
	Quint = Enum.EasingStyle.Quint,
	Back = Enum.EasingStyle.Back,
	Bounce = Enum.EasingStyle.Bounce,
	Elastic = Enum.EasingStyle.Elastic,
	Exponential = Enum.EasingStyle.Exponential,
	Expo = Enum.EasingStyle.Exponential,
	Circular = Enum.EasingStyle.Circular,
	Circ = Enum.EasingStyle.Circular,
}

local EASE_DIR: { [string]: Enum.EasingDirection } = {
	In = Enum.EasingDirection.In,
	Out = Enum.EasingDirection.Out,
	InOut = Enum.EasingDirection.InOut,
}

--[[
	解析 ease 名称为 TweenService 枚举；未知则 Linear / Out
	@param easeName string? - MA2/自定义 ease 名
	@param easeDir string? - In / Out / InOut
	@return Enum.EasingStyle, Enum.EasingDirection - 样式与方向
]]
local function _resolveEase(easeName: string?, easeDir: string?): (Enum.EasingStyle, Enum.EasingDirection)
	local style = Enum.EasingStyle.Linear
	if type(easeName) == "string" then
		local mapped = EASE_STYLE[easeName]
		if mapped then
			style = mapped
		end
	end
	local dir = Enum.EasingDirection.Out
	if type(easeDir) == "string" then
		local mappedDir = EASE_DIR[easeDir]
		if mappedDir then
			dir = mappedDir
		end
	end
	return style, dir
end

--[[
	将线性 alpha 经 easing 变换
	@param alpha number - 0~1 线性进度
	@param easeName string? - ease 名（取自段起点关键帧）
	@param easeDir string? - ease 方向
	@return number - 缓动后的 0~1
]]
local function _applyEase(alpha: number, easeName: string?, easeDir: string?): number
	local a = math.clamp(alpha, 0, 1)
	local style, dir = _resolveEase(easeName, easeDir)
	if style == Enum.EasingStyle.Linear then
		return a
	end
	return TweenService:GetValue(a, style, dir)
end

--[[
	在已按 t 升序的关键帧中定位插值段
	@param keys { { t: number } } - 关键帧列表
	@param t number - 查询时间（秒）
	@return number, number - 左/右下标（1-based，可相同）
]]
local function _findSegment(keys: { { t: number } }, t: number): (number, number)
	local n = #keys
	if n <= 1 then
		return 1, 1
	end
	if t <= keys[1].t then
		return 1, 1
	end
	if t >= keys[n].t then
		return n, n
	end
	for i = 1, n - 1 do
		if t >= keys[i].t and t <= keys[i + 1].t then
			return i, i + 1
		end
	end
	return n, n
end

--[[
	求值标量关键帧曲线
	@param keys { NumberKey } - 按 t 升序的关键帧；空表返回 0
	@param t number - 时间（秒）
	@return number - 插值结果
]]
function KeyframeEval.EvalNumber(keys: { NumberKey }, t: number): number
	if type(keys) ~= "table" or #keys == 0 then
		return 0
	end
	local i0, i1 = _findSegment(keys, t)
	local a = keys[i0]
	local b = keys[i1]
	if i0 == i1 or a.t == b.t then
		return a.v
	end
	local alpha = (t - a.t) / (b.t - a.t)
	local eased = _applyEase(alpha, a.ease, a.easeDir)
	return a.v + (b.v - a.v) * eased
end

--[[
	求值 CFrame 关键帧曲线（位置 lerp + 旋转 slerp）
	@param keys { CFrameKey } - 按 t 升序；空表返回 Identity
	@param t number - 时间（秒）
	@return CFrame - 插值结果
]]
function KeyframeEval.EvalCFrame(keys: { CFrameKey }, t: number): CFrame
	if type(keys) ~= "table" or #keys == 0 then
		return CFrame.new()
	end
	local i0, i1 = _findSegment(keys, t)
	local a = keys[i0]
	local b = keys[i1]
	if i0 == i1 or a.t == b.t then
		return a.v
	end
	local alpha = (t - a.t) / (b.t - a.t)
	local eased = _applyEase(alpha, a.ease, a.easeDir)
	return a.v:Lerp(b.v, eased)
end

return KeyframeEval
