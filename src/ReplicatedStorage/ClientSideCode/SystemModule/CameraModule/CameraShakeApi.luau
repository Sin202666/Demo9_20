--[[
	Module: CameraModule.CameraShakeApi
	Description: CameraModule 公开震动 API（Once / At / Impulse / Sustain / Cancel / Scale）。由 init 在客户端路径 bind 后挂到 CameraModule 表；业务不要直接 require。
	Author: 林奥宇
	Created: 2026-08-31
	Last Modified: 2026-08-31

	功能：
	- 参数校验与错误码（NOT_INITIALIZED / INVALID_SHAKE_TYPE / INVALID_ARGUMENT / LAYER_FULL）
	- 委托 ShakePresets.Get + ShakeRuntime 推层 / Kick / Sustain
	- 层满拒绝瞬时层时返回 false, LAYER_FULL（过远未播放仍 true 且 handle 为 nil）

	与 init：客户端 require 后调用 bind(deps)，再把函数赋到 CameraModule。
]]

local ShakePresets = require(script.Parent.ShakePresets)
local ShakeRuntime = require(script.Parent.ShakeRuntime)

local WORLD_DIR_EPS = 1e-5

local CameraShakeApi = {}

type ErrorCodeMap = {
	NOT_INITIALIZED: string,
	INVALID_SHAKE_TYPE: string,
	INVALID_ARGUMENT: string,
	LAYER_FULL: string,
	EVENT_NOT_FOUND: string,
}

type ShakeApiDeps = {
	isReady: () -> boolean,
	errorCode: ErrorCodeMap,
	logWarn: (...any) -> (),
}

local _isReady: (() -> boolean)? = nil
local _errorCode: ErrorCodeMap? = nil
local _logWarn: ((...any) -> ())? = nil

--[[
	注入就绪检查、错误码与日志（init 客户端路径调用一次）
	@param deps ShakeApiDeps - isReady / errorCode / logWarn
	@return () - 无返回值
]]
function CameraShakeApi.bind(deps: ShakeApiDeps)
	_isReady = deps.isReady
	_errorCode = deps.errorCode
	_logWarn = deps.logWarn
end

--[[
	未 bind 或未 Init 时的错误码
	@return string - NOT_INITIALIZED
]]
local function _notReadyCode(): string
	if _errorCode then
		return _errorCode.NOT_INITIALIZED
	end
	return "NOT_INITIALIZED"
end

--[[
	校验已 bind 且 CameraModule.Init 已完成
	@return boolean - 可执行震动 API 时为 true
	@return string? - 失败时错误码
]]
local function _guard(): (boolean, string?)
	if not _isReady or not _errorCode then
		return false, _notReadyCode()
	end
	if not _isReady() then
		return false, _errorCode.NOT_INITIALIZED
	end
	return true
end

--[[
	按类型取预设；非法类型打日志并返回错误码
	@param apiName string - 调用方 API 名（仅用于日志）
	@param shakeType number - EnumMgr.CameraShakeType 1-8
	@return ShakePresets.ShakeTypeConfig? - 合法预设；失败为 nil
	@return string? - 失败时 INVALID_SHAKE_TYPE
]]
local function _getPresetOrError(apiName: string, shakeType: number): (ShakePresets.ShakeTypeConfig?, string?)
	local cfg = ShakePresets.Get(shakeType)
	if cfg then
		return cfg, nil
	end
	local logWarn = _logWarn
	if logWarn then
		logWarn(apiName .. ": 震动类型不存在", shakeType, "见 EnumMgr.CameraShakeType")
	end
	local err = if _errorCode then _errorCode.INVALID_SHAKE_TYPE else "INVALID_SHAKE_TYPE"
	return nil, err
end

--[[
	执行单次相机震动（推入一层 Trauma）
	@param shakeType number - 震动类型（EnumMgr.CameraShakeType，1-8）
	@param intensityMul number? - 强度乘子，缺省 1，clamp 0~2；0 视为成功空操作
	@return boolean - 是否成功（层满为 false）
	@return string? - 错误码
	@return number? - 震动句柄；空操作或层满时为 nil
]]
function CameraShakeApi.CameraShakeOnce(shakeType: number, intensityMul: number?): (boolean, string?, number?)
	local ok, err = _guard()
	if not ok then
		return false, err
	end
	local cfg, typeErr = _getPresetOrError("CameraShakeOnce", shakeType)
	if not cfg then
		return false, typeErr
	end
	local mul = ShakeRuntime.ResolveIntensityMul(intensityMul)
	if mul <= 0 then
		return true, nil, nil
	end
	local handle = ShakeRuntime.PushLayer(cfg, nil, mul)
	if not handle then
		return false, (_errorCode :: ErrorCodeMap).LAYER_FULL
	end
	return true, nil, handle
end

--[[
	在世界坐标播放单次震动（按与听点距离衰减）
	@param shakeType number - 震动类型（EnumMgr.CameraShakeType，1-8）
	@param worldPos Vector3 - 事件世界坐标
	@param maxDistance number? - 衰减到 0 的距离；缺省 GameConfig PlayAt默认最大距离
	@param directionalKick boolean? - 是否叠「事件→听点」方向 Kick；缺省 true
	@param intensityMul number? - 强度乘子，缺省 1，clamp 0~2
	@return boolean - 是否成功（过远未播放仍 true；层满为 false）
	@return string? - 错误码
	@return number? - 震动句柄；过远未播放或层满时为 nil
]]
function CameraShakeApi.CameraShakeAt(
	shakeType: number,
	worldPos: Vector3,
	maxDistance: number?,
	directionalKick: boolean?,
	intensityMul: number?
): (boolean, string?, number?)
	local ok, err = _guard()
	if not ok then
		return false, err
	end
	local codes = _errorCode :: ErrorCodeMap
	if typeof(worldPos) ~= "Vector3" then
		return false, codes.INVALID_ARGUMENT
	end
	local cfg, typeErr = _getPresetOrError("CameraShakeAt", shakeType)
	if not cfg then
		return false, typeErr
	end

	local mul = ShakeRuntime.ResolveIntensityMul(intensityMul)
	local maxDist = if type(maxDistance) == "number" then maxDistance else ShakeRuntime.GetPlayAtDefaultMaxDistance()
	local listenerPos = ShakeRuntime.GetListenerPosition()
	local factor = ShakeRuntime.GetDistanceFactor(worldPos, maxDist)
	if factor <= 0 or mul <= 0 then
		return true, nil, nil
	end

	local handle = ShakeRuntime.PushLayer(cfg, factor, mul)
	if not handle then
		return false, codes.LAYER_FULL
	end

	local kickScale = ShakeRuntime.GetPlayAtKickScale()
	local applyKick = directionalKick ~= false and kickScale > 0
	if applyKick then
		local toListener = listenerPos - worldPos
		ShakeRuntime.AddCameraLocalKick(handle, toListener, cfg.trauma * factor * mul * kickScale)
	end

	return true, nil, handle
end

--[[
	带世界方向的瞬时冲击（Trauma 层 + 相机局部 Kick）
	@param shakeType number - 震动类型（EnumMgr.CameraShakeType，1-8）
	@param worldDir Vector3 - 冲击方向（世界空间，不必单位化）
	@param distanceFactor number? - 0~1 额外强度系数，缺省 1
	@param intensityMul number? - 强度乘子，缺省 1，clamp 0~2
	@return boolean - 是否成功（层满为 false）
	@return string? - 错误码
	@return number? - 震动句柄；空操作或层满时为 nil
]]
function CameraShakeApi.CameraShakeImpulse(
	shakeType: number,
	worldDir: Vector3,
	distanceFactor: number?,
	intensityMul: number?
): (boolean, string?, number?)
	local ok, err = _guard()
	if not ok then
		return false, err
	end
	local codes = _errorCode :: ErrorCodeMap
	if typeof(worldDir) ~= "Vector3" then
		return false, codes.INVALID_ARGUMENT
	end
	if worldDir.Magnitude < WORLD_DIR_EPS then
		return false, codes.INVALID_ARGUMENT
	end
	local cfg, typeErr = _getPresetOrError("CameraShakeImpulse", shakeType)
	if not cfg then
		return false, typeErr
	end

	local factor = if type(distanceFactor) == "number" then math.clamp(distanceFactor, 0, 1) else 1
	local mul = ShakeRuntime.ResolveIntensityMul(intensityMul)
	if factor <= 0 or mul <= 0 then
		return true, nil, nil
	end
	local handle = ShakeRuntime.PushLayer(cfg, factor, mul)
	if not handle then
		return false, codes.LAYER_FULL
	end
	ShakeRuntime.AddCameraLocalKick(handle, worldDir, cfg.trauma * factor * mul)

	return true, nil, handle
end

--[[
	开始命名源持续相机震动（同源引用计数 +1）
	@param sourceId string - 非空源名（如 "Vehicle" / "Charge"）
	@param shakeType number - 震动类型（EnumMgr.CameraShakeType，1-8）
	@return boolean - 是否成功（层满为 false）
	@return string? - 错误码
	@return number? - 该源层句柄
]]
function CameraShakeApi.CameraShakeSustain(sourceId: string, shakeType: number): (boolean, string?, number?)
	local ok, err = _guard()
	if not ok then
		return false, err
	end
	local codes = _errorCode :: ErrorCodeMap
	if type(sourceId) ~= "string" or sourceId == "" then
		return false, codes.INVALID_ARGUMENT
	end
	local cfg, typeErr = _getPresetOrError("CameraShakeSustain", shakeType)
	if not cfg then
		return false, typeErr
	end

	local handle = ShakeRuntime.Sustain(sourceId, cfg)
	if not handle then
		return false, codes.LAYER_FULL
	end
	return true, nil, handle
end

--[[
	停止一层命名源持续震动（引用计数 -1）；源不存在视为成功（幂等）
	@param sourceId string - 与 CameraShakeSustain 对应的非空源名
	@param fadeOutTime number? - 引用归零时：缺省自然衰减；>0 加速该源层衰减；<=0 立即移除
	@return boolean - 是否成功
	@return string? - 错误码
]]
function CameraShakeApi.CameraShakeStop(sourceId: string, fadeOutTime: number?): (boolean, string?)
	local ok, err = _guard()
	if not ok then
		return false, err
	end
	local codes = _errorCode :: ErrorCodeMap
	if type(sourceId) ~= "string" or sourceId == "" then
		return false, codes.INVALID_ARGUMENT
	end
	ShakeRuntime.StopSustain(sourceId, fadeOutTime)
	return true
end

--[[
	取消指定句柄的震动（Trauma 层 + 同 id Kick）
	@param handle number - Once/At/Impulse/Sustain 返回的句柄
	@param fadeOutTime number? - 缺省或 >0：Kick 立即移除，层加速/自然衰减；<=0：层与 Kick 立即移除
	@return boolean - 是否成功
	@return string? - 错误码；句柄不存在为 EVENT_NOT_FOUND
]]
function CameraShakeApi.CameraShakeCancel(handle: number, fadeOutTime: number?): (boolean, string?)
	local ok, err = _guard()
	if not ok then
		return false, err
	end
	local codes = _errorCode :: ErrorCodeMap
	if type(handle) ~= "number" then
		return false, codes.INVALID_ARGUMENT
	end
	if not ShakeRuntime.Cancel(handle, fadeOutTime) then
		return false, codes.EVENT_NOT_FOUND
	end
	return true
end

--[[
	设置全局震动强度（与 Setting.Shake 滑条正交，相乘）
	@param scale number - 0~1，内部 clamp
	@return boolean - 是否成功
	@return string? - 错误码
]]
function CameraShakeApi.SetShakeScale(scale: number): (boolean, string?)
	local ok, err = _guard()
	if not ok then
		return false, err
	end
	local codes = _errorCode :: ErrorCodeMap
	if type(scale) ~= "number" then
		return false, codes.INVALID_ARGUMENT
	end
	ShakeRuntime.SetShakeScale(scale)
	return true
end

--[[
	获取全局震动强度（不含 Setting 滑条）
	@return number - 0~1；未 bind 时为 0
]]
function CameraShakeApi.GetShakeScale(): number
	if not _isReady then
		return 0
	end
	return ShakeRuntime.GetShakeScale()
end

--[[
	停止全部震动（含 Sustain 与 Kick）
	@param fadeOutTime number? - 淡出秒数；缺省 0.1；<=0 立即清空
	@return boolean - 是否成功
	@return string? - 错误码
]]
function CameraShakeApi.StopAllShakes(fadeOutTime: number?): (boolean, string?)
	local ok, err = _guard()
	if not ok then
		return false, err
	end
	ShakeRuntime.StopAll(fadeOutTime)
	return true
end

return CameraShakeApi
