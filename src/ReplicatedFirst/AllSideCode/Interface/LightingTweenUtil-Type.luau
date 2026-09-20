--[[
	Module: LightingTweenUtil-Type
	Description: LightingTweenUtil 类型声明（完整说明见 ToolBasic/LightingTweenUtil.luau）
	Author: 中台组 林奥宇
	Created: 2026-08-04
	Last Modified: 2026-08-04
]]

local module = {}

--[[
	将过渡时间规范为非负秒数

	@param transitionTime number? - 原始过渡时间；nil 视为 0
	@return number - max(0, transitionTime)
]]
function module.normalizeTransitionTime(transitionTime: number?): number
end

--[[
	取消并销毁 Tween（优先 Cancel，避免 Completed 误触发）

	@param tween Tween? - 待取消的 Tween；nil 则无操作
	@return nil - 无返回值
]]
function module.cancelTween(tween: Tween?)
end

--[[
	先取消旧 Tween；transitionTime>0 则创建并播放新 Tween，否则执行即时写

	@param oldTween Tween? - 进行中的旧 Tween
	@param instance Instance - Tween 目标
	@param transitionTime number - 过渡秒数（应已 normalize）
	@param goals {[string]: any} - Tween 目标属性表
	@param applyNow (() -> ())? - 即时写入回调；transitionTime==0 时调用
	@param onComplete (() -> ())? - 仅自然 Completed 时回调（Cancelled 不调）
	@param tweenInfo TweenInfo? - 可选覆盖；nil 时用 GameConfig.LightingTween
	@return Tween? - 新创建的 Tween；即时写时为 nil
]]
function module.playOrApply(
	oldTween: Tween?,
	instance: Instance,
	transitionTime: number,
	goals: { [string]: any },
	applyNow: (() -> ())?,
	onComplete: (() -> ())?,
	tweenInfo: TweenInfo?
): Tween?
end

return module
