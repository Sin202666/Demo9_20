local module = {}

--[[
	Module: SpeedLineFX
	Description: 全屏加速线表现（多层 Crossfade + 强度包络），仅客户端

	引入：local SpeedLineFX = Utils.SpeedLineFX
	详见 ToolSystem/SpeedLineFX.luau 文件头
]]

module.ErrorCode = table.freeze({
	NOT_CLIENT = "NOT_CLIENT",
	INVALID_ARG = "INVALID_ARG",
	NO_PLAYER_GUI = "NO_PLAYER_GUI",
	NOT_ACTIVE = "NOT_ACTIVE",
	PLAY_FAILED = "PLAY_FAILED",
})

--[[
	预加载加速线序列资源
	@return boolean - true 预载成功
	@return string? - 失败时的 ErrorCode
]]
function module.Preload(): (boolean, string?)
	return false, nil
end

--[[
	显示全屏加速线并淡入到指定强度
	@param intensity number? - 目标强度 [0,1]，默认 1
	@param fadeInSec number? - 淡入秒数，默认 0.12
	@return boolean - true 已开始显示
	@return string? - 失败时的 ErrorCode
]]
function module.Show(intensity: number?, fadeInSec: number?): (boolean, string?)
	return false, nil
end

--[[
	运行时设置目标强度
	@param intensity number - 目标强度 [0,1]
	@return boolean - true 已接受
	@return string? - 失败时的 ErrorCode
]]
function module.SetIntensity(intensity: number): (boolean, string?)
	return false, nil
end

--[[
	淡出并停止全屏加速线
	@param fadeOutSec number? - 淡出秒数，默认 0.2
	@return boolean - true 已开始淡出或已停止
	@return string? - 失败时的 ErrorCode
]]
function module.Hide(fadeOutSec: number?): (boolean, string?)
	return false, nil
end

--[[
	查询当前显示强度（不含呼吸）
	@return number - 当前强度 [0,1]
]]
function module.GetIntensity(): number
	return 0
end

--[[
	加速线序列资源名（Assets/Sequence Folder）
	@return string - 序列名
]]
function module.GetSequenceName(): string
	return ""
end

return module
