--[[
	Module: HatchEffect/HatchAnimUtil
	Description: 抽蛋表现通用 Easing 逐帧循环
	Author: 林奥宇
	Created: 2026-07-02
	Last Modified: 2026-09-01

	由 HatchBoxEffect / HatchRewardEffect 内部调用，勿经 Utils 直接使用。
]]

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local HatchAnimUtil = {}

--[[
	按 Easing 曲线逐帧回调，直到 duration 结束或 shouldContinue 返回 false。
	阻塞当前线程（RenderStepped:Wait）。

	@param duration number - 动画时长（秒）；<=0 时仍会跑完至少一帧
	@param easingStyle Enum.EasingStyle - TweenService:GetValue 的缓动风格
	@param easingDir Enum.EasingDirection - 缓动方向
	@param onStep (easingResult: number) -> () - 每帧回调，easingResult 为 0~1 的缓动值
	@param shouldContinue (() -> boolean)? - 可选中断条件；返回 false 时提前结束；nil 表示不中断
	@return nil - 无返回值
]]
function HatchAnimUtil.runEasingLoop(
	duration: number,
	easingStyle: Enum.EasingStyle,
	easingDir: Enum.EasingDirection,
	onStep: (number) -> (),
	shouldContinue: (() -> boolean)?
)
	local startClock = os.clock()
	while true do
		if shouldContinue and not shouldContinue() then
			break
		end

		local easingTime = math.clamp((os.clock() - startClock) / duration, 0, 1)
		local easingResult = TweenService:GetValue(easingTime, easingStyle, easingDir)
		onStep(easingResult)
		RunService.RenderStepped:Wait()

		if easingTime >= 1 then
			break
		end
	end
end

return HatchAnimUtil
