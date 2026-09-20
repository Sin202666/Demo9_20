local module = {}

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

--[[
	求值标量关键帧曲线
	@param keys { NumberKey } - 按 t 升序的关键帧；空表返回 0
	@param t number - 时间（秒）
	@return number - 插值结果
]]
function module.EvalNumber(keys: { NumberKey }, t: number): number
end

--[[
	求值 CFrame 关键帧曲线（位置 lerp + 旋转 slerp）
	@param keys { CFrameKey } - 按 t 升序；空表返回 Identity
	@param t number - 时间（秒）
	@return CFrame - 插值结果
]]
function module.EvalCFrame(keys: { CFrameKey }, t: number): CFrame
end

return module
