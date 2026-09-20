--[[
	Module: DualPathBallRuntime
	Description: 双球轨迹运行时——施法者烘焙相对锚点 / 旁观者直觉轨迹，共享同一相位时钟
	Author: 中台组
	Created: 2026-08-03
	Last Modified: 2026-08-03

	决策对齐：
	- CasterBaked：EvalCFrame(烘焙 local keys) → AnchorRelative.ToWorld
	- ObserverIntuitive：相对施法者 HRP 的出场/环绕/合一/缓扩/冲刺；相位边界与施法者相同
	- Trail/Enable 开关时刻由同一 phaseTimeline 秒表驱动（调用方可读 GetPhase / IsTrailWindow）

	领域专用（空间技能类双球表现），不挂 Utils 顶层。
	仅客户端驱动视觉；通用求值仍用 Utils.KeyframeEval / Utils.AnchorRelative。

	加载（技能模块内相对路径）：
		local DualPathBallRuntime = require(script.Parent.Parent.Presentation.DualPathBallRuntime)
		-- 若本文件在 Presentation 下的兄弟技能脚本：require(script.Parent.DualPathBallRuntime)
		local rt = DualPathBallRuntime.new(config)
		rt:Start("CasterBaked", context)
		rt:Update(tFromCastStart)
		rt:Stop()
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local KeyframeEval = Utils.KeyframeEval
local AnchorRelative = Utils.AnchorRelative

local DualPathBallRuntime = {}
DualPathBallRuntime.__index = DualPathBallRuntime

export type BallMode = "CasterBaked" | "ObserverIntuitive"

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

export type PhaseTimeline = {
	appearStart: number,
	orbitStart: number,
	mergeStart: number,
	expandStart: number,
	rushStart: number,
	endTime: number,
	trailEnableAt: number?,
	trailDisableAt: number?,
}

export type BallContext = {
	-- 烘焙锚点（Caster）；也可每帧刷新
	getAnchorCF: () -> CFrame,
	-- 旁观者用的施法者朝向/位置（通常 HRP）
	getCasterCF: (() -> CFrame)?,
	lightBall: BasePart,
	darkBall: BasePart,
	bakedLightKeys: { CFrameKey }?,
	bakedDarkKeys: { CFrameKey }?,
	-- 共享节奏：缩放（两模式共用）
	scaleKeys: { NumberKey }?,
	-- 旁观者环绕半径节奏（缺省用内置常数曲线）
	orbitRadiusKeys: { NumberKey }?,
	-- 旁观者高度偏移节奏
	heightKeys: { NumberKey }?,
}

export type DualPathBallConfig = {
	phaseTimeline: PhaseTimeline,
	-- 旁观者默认水平半径（无 orbitRadiusKeys 时）
	defaultOrbitRadius: number?,
	-- 旁观者出场左右半距
	appearSideOffset: number?,
	-- 旁观者前方偏移
	appearForwardOffset: number?,
}

export type DualPathBallRuntime = typeof(setmetatable({} :: {
	_config: DualPathBallConfig,
	_mode: BallMode?,
	_ctx: BallContext?,
	_running: boolean,
	_lastPhase: string?,
}, DualPathBallRuntime))

local DEFAULT_ORBIT_RADIUS = 8
local DEFAULT_SIDE = 4
local DEFAULT_FORWARD = 6
local DEFAULT_HEIGHT = 3

--[[
	根据 t 解析当前相位名
	@param tl PhaseTimeline - 相位表
	@param t number - 相对施法起点的秒
	@return string - Appear/Orbit/Merge/Expand/Rush/Ended
]]
local function _phaseAt(tl: PhaseTimeline, t: number): string
	if t < tl.appearStart then
		return "Idle"
	end
	if t < tl.orbitStart then
		return "Appear"
	end
	if t < tl.mergeStart then
		return "Orbit"
	end
	if t < tl.expandStart then
		return "Merge"
	end
	if t < tl.rushStart then
		return "Expand"
	end
	if t < tl.endTime then
		return "Rush"
	end
	return "Ended"
end

--[[
	相位内 0~1 进度
	@param t0 number - 相位起点
	@param t1 number - 相位终点
	@param t number - 当前时间
	@return number - 0~1
]]
local function _phaseAlpha(t0: number, t1: number, t: number): number
	if t1 <= t0 then
		return 1
	end
	return math.clamp((t - t0) / (t1 - t0), 0, 1)
end

--[[
	创建双球运行时
	@param config DualPathBallConfig - 相位时间轴与旁观默认几何
	@return DualPathBallRuntime - 实例
]]
function DualPathBallRuntime.new(config: DualPathBallConfig): DualPathBallRuntime
	local self = setmetatable({
		_config = config,
		_mode = nil :: BallMode?,
		_ctx = nil :: BallContext?,
		_running = false,
		_lastPhase = nil :: string?,
	}, DualPathBallRuntime)
	return self
end

--[[
	开始驱动
	@param mode BallMode - CasterBaked 或 ObserverIntuitive
	@param context BallContext - 球实例与曲线/锚点回调
]]
function DualPathBallRuntime:Start(mode: BallMode, context: BallContext)
	self._mode = mode
	self._ctx = context
	self._running = true
	self._lastPhase = nil
	if context.lightBall then
		context.lightBall.Anchored = true
	end
	if context.darkBall then
		context.darkBall.Anchored = true
	end
end

--[[
	停止驱动（不销毁球实例）
]]
function DualPathBallRuntime:Stop()
	self._running = false
	self._mode = nil
	self._ctx = nil
	self._lastPhase = nil
end

--[[
	当前是否处于 Trail 开窗
	@param t number - 相对施法起点秒
	@return boolean - 是否应开 Trail
]]
function DualPathBallRuntime:IsTrailWindow(t: number): boolean
	local tl = self._config.phaseTimeline
	local enableAt = tl.trailEnableAt
	local disableAt = tl.trailDisableAt
	if enableAt == nil then
		return false
	end
	if t < enableAt then
		return false
	end
	if disableAt ~= nil and t >= disableAt then
		return false
	end
	return true
end

--[[
	查询相位名
	@param t number - 相对施法起点秒
	@return string - 相位
]]
function DualPathBallRuntime:GetPhase(t: number): string
	return _phaseAt(self._config.phaseTimeline, t)
end

--[[
	施法者烘焙路径：local 关键帧 → 世界
	@param ctx BallContext - 上下文
	@param t number - 时间秒
]]
local function _updateCasterBaked(ctx: BallContext, t: number)
	local anchor = ctx.getAnchorCF()
	if ctx.bakedLightKeys and ctx.lightBall then
		local localCF = KeyframeEval.EvalCFrame(ctx.bakedLightKeys, t)
		ctx.lightBall.CFrame = AnchorRelative.ToWorld(anchor, localCF)
	end
	if ctx.bakedDarkKeys and ctx.darkBall then
		local localCF = KeyframeEval.EvalCFrame(ctx.bakedDarkKeys, t)
		ctx.darkBall.CFrame = AnchorRelative.ToWorld(anchor, localCF)
	end
	if ctx.scaleKeys then
		local s = KeyframeEval.EvalNumber(ctx.scaleKeys, t)
		if ctx.lightBall then
			ctx.lightBall.Size = Vector3.new(s, s, s)
		end
		if ctx.darkBall then
			ctx.darkBall.Size = Vector3.new(s, s, s)
		end
	end
end

--[[
	旁观者直觉路径（与相位时钟对齐）
	@param self DualPathBallRuntime
	@param ctx BallContext - 上下文
	@param t number - 时间秒
]]
local function _updateObserverIntuitive(self: DualPathBallRuntime, ctx: BallContext, t: number)
	local getCaster = ctx.getCasterCF
	if not getCaster then
		return
	end
	local casterCF = getCaster()
	local tl = self._config.phaseTimeline
	local phase = _phaseAt(tl, t)
	local radiusDefault = self._config.defaultOrbitRadius or DEFAULT_ORBIT_RADIUS
	local side = self._config.appearSideOffset or DEFAULT_SIDE
	local forward = self._config.appearForwardOffset or DEFAULT_FORWARD

	local radius = radiusDefault
	if ctx.orbitRadiusKeys and #ctx.orbitRadiusKeys > 0 then
		radius = KeyframeEval.EvalNumber(ctx.orbitRadiusKeys, t)
	end
	local height = DEFAULT_HEIGHT
	if ctx.heightKeys and #ctx.heightKeys > 0 then
		height = KeyframeEval.EvalNumber(ctx.heightKeys, t)
	end

	local origin = casterCF.Position + Vector3.new(0, height, 0)
	local look = casterCF.LookVector
	local right = casterCF.RightVector
	look = Vector3.new(look.X, 0, look.Z)
	right = Vector3.new(right.X, 0, right.Z)
	if look.Magnitude < 1e-3 then
		look = Vector3.new(0, 0, -1)
	else
		look = look.Unit
	end
	if right.Magnitude < 1e-3 then
		right = Vector3.new(1, 0, 0)
	else
		right = right.Unit
	end

	local lightPos = origin
	local darkPos = origin

	if phase == "Appear" then
		local a = _phaseAlpha(tl.appearStart, tl.orbitStart, t)
		local base = origin + look * forward
		lightPos = base + right * side * a
		darkPos = base - right * side * a
	elseif phase == "Orbit" then
		local a = _phaseAlpha(tl.orbitStart, tl.mergeStart, t)
		local angle = a * math.pi * 2
		local center = origin + look * forward
		lightPos = center + (right * math.cos(angle) + look * math.sin(angle)) * radius
		darkPos = center + (right * math.cos(angle + math.pi) + look * math.sin(angle + math.pi)) * radius
	elseif phase == "Merge" then
		local a = _phaseAlpha(tl.mergeStart, tl.expandStart, t)
		local center = origin + look * forward
		local angle = math.pi * 2 -- 环绕结束角
		local lightStart = center + (right * math.cos(angle) + look * math.sin(angle)) * radius
		local darkStart = center + (right * math.cos(angle + math.pi) + look * math.sin(angle + math.pi)) * radius
		lightPos = lightStart:Lerp(center, a)
		darkPos = darkStart:Lerp(center, a)
	elseif phase == "Expand" then
		local a = _phaseAlpha(tl.expandStart, tl.rushStart, t)
		local center = origin + look * forward
		local expandR = radius * (0.15 + 0.35 * a)
		lightPos = center + right * expandR
		darkPos = center - right * expandR
	elseif phase == "Rush" or phase == "Ended" then
		local a = if phase == "Ended" then 1 else _phaseAlpha(tl.rushStart, tl.endTime, t)
		local center = origin + look * forward
		local rush = center + look * (forward * (0.5 + a * 2))
		lightPos = rush
		darkPos = rush
	else
		-- Idle：藏在锚点
		lightPos = origin
		darkPos = origin
	end

	if ctx.lightBall then
		ctx.lightBall.CFrame = CFrame.new(lightPos, lightPos + look)
	end
	if ctx.darkBall then
		ctx.darkBall.CFrame = CFrame.new(darkPos, darkPos + look)
	end
	if ctx.scaleKeys then
		local s = KeyframeEval.EvalNumber(ctx.scaleKeys, t)
		if ctx.lightBall then
			ctx.lightBall.Size = Vector3.new(s, s, s)
		end
		if ctx.darkBall then
			ctx.darkBall.Size = Vector3.new(s, s, s)
		end
	end
end

--[[
	按相对施法起点的时间更新两球
	@param t number - 秒（与运镜/Cue 同一时钟）
]]
function DualPathBallRuntime:Update(t: number)
	if not self._running or not self._ctx or not self._mode then
		return
	end
	local phase = _phaseAt(self._config.phaseTimeline, t)
	self._lastPhase = phase
	if self._mode == "CasterBaked" then
		_updateCasterBaked(self._ctx, t)
	else
		_updateObserverIntuitive(self, self._ctx, t)
	end
end

--[[
	销毁运行时引用（不 Destroy 球 Part）
]]
function DualPathBallRuntime:destroy()
	self:Stop()
end

return DualPathBallRuntime
