--[[
	Module: CameraModule-Type
	Description: CameraModule 类型声明（完整使用说明见 SystemModule/CameraModule/init.luau 文件头）
	Author: 林奥宇
	Created: 2026-01-01
	Last Modified: 2026-08-31

	说明：
	- 主事件栈空时一帧切回开镜前轨道（不做 CFrame tween）；下一帧同步 Zoom 后交还 Custom
	- FocusPlayer 强制跟角色，不读开镜快照
	- 主事件生效期间 Helper 被 mute；opts.suppressShake=true 时不叠加震动
	- 主事件回调可返回 (CFrame?, fov?)；fov 为绝对视野，nil 则用注册时的 fov
	- CFrame/FOV 仅经 CameraModule；Zoom 见 HatchCamera；FOV 脉冲见 CameraImpulse
	- CameraMode：PushMode/PopMode/GetActiveMode；引擎 ShiftLock → Engine:MouseLock
]]

local CameraModule = {}

export type CameraEventOpts = {
	suppressShake: boolean?,
}

export type CameraEvent = {
	EventTime: number,
	EventName: string,
	EventPriority: number?,
	Fov: number?,
	Seq: number?,
	SuppressShake: boolean?,
	Function: (time: number, dt: number?) -> (CFrame?, number?),
}

export type ShakeTypeConfig = {
	name: string,
	trauma: number,
	roughness: number,
	posInfluence: Vector3,
	rotInfluence: Vector3,
	decayPerSec: number,
	attackSec: number,
}

CameraModule.ERROR_CODE = {
	DUPLICATE_EVENT = "DUPLICATE_EVENT",
	EVENT_NOT_FOUND = "EVENT_NOT_FOUND",
	NOT_INITIALIZED = "NOT_INITIALIZED",
	NOT_CLIENT = "NOT_CLIENT",
	INVALID_SHAKE_TYPE = "INVALID_SHAKE_TYPE",
	INVALID_ARGUMENT = "INVALID_ARGUMENT",
	LAYER_FULL = "LAYER_FULL",
	CHARACTER_NOT_READY = "CHARACTER_NOT_READY",
	SOURCE_NOT_FOUND = "SOURCE_NOT_FOUND",
}

CameraModule.Mode = {
	Default = "Default",
	ShiftLock = "ShiftLock",
	OTS = "OTS",
	LockOn = "LockOn",
	Aim = "Aim",
}

function CameraModule.Init(): (boolean, string?)
end

function CameraModule.destroy()
end

function CameraModule.GetCamera(): Camera?
end

--[[
	获取震动类型配置表（只读）
	@return { [number]: ShakeTypeConfig }
]]
function CameraModule.GetShakePresets(): { [number]: ShakeTypeConfig }
end

--[[
	启用相机事件控制（主事件）
	@param eventName string - 事件唯一名称
	@param priority number - 事件优先级（数字越大优先级越高；同级后注册胜出）
	@param fov number? - 回调未返回 FOV 时的回退视野角度
	@param func (number, number?) -> (CFrame?, number?) - 每帧变换；第二返回值为本帧绝对 FOV
	@param opts CameraEventOpts? - suppressShake 等；运镜大招建议 { suppressShake = true }
	@return boolean, string? - 是否成功 / 错误码
]]
function CameraModule.EnableCameraEvent(
	eventName: string,
	priority: number,
	fov: number?,
	func: (number, number?) -> (CFrame?, number?),
	opts: CameraEventOpts?
): (boolean, string?)
end

--[[
	将相机视角聚焦到玩家身上，恢复跟随角色（不读开镜快照；供补救）
	@return boolean, string? - 是否成功 / 错误码
]]
function CameraModule.FocusPlayer(): (boolean, string?)
end

--[[
	禁用相机事件控制；若为主事件栈最后一项则按开镜前快照归还
	@param eventName string - 要禁用的事件名称
	@return boolean, string? - 是否成功 / 错误码
]]
function CameraModule.DisableCameraEvent(eventName: string): (boolean, string?)
end

--[[
	执行单次相机震动（推入一层 Trauma）
	@param shakeType number - 震动类型（EnumMgr.CameraShakeType，1-8）
	@param intensityMul number? - 强度乘子，缺省 1，clamp 0~2
	@return boolean - 是否成功
	@return string? - 错误码
	@return number? - 震动句柄（可供 CameraShakeCancel）；层满拒绝时为 nil
]]
function CameraModule.CameraShakeOnce(shakeType: number, intensityMul: number?): (boolean, string?, number?)
end

--[[
	在世界坐标播放单次震动（按与听点距离衰减；默认叠方向 Kick）
	@param shakeType number - 震动类型（EnumMgr.CameraShakeType，1-8）
	@param worldPos Vector3 - 事件世界坐标
	@param maxDistance number? - 衰减到 0 的距离（默认 GameConfig）
	@param directionalKick boolean? - 是否叠「事件→听点」方向 Kick；缺省 true
	@param intensityMul number? - 强度乘子，缺省 1，clamp 0~2
	@return boolean - 是否成功
	@return string? - 错误码
	@return number? - 震动句柄；过远未播放或层满时为 nil
]]
function CameraModule.CameraShakeAt(
	shakeType: number,
	worldPos: Vector3,
	maxDistance: number?,
	directionalKick: boolean?,
	intensityMul: number?
): (boolean, string?, number?)
end

--[[
	带世界方向的瞬时冲击（Trauma 层 + 相机局部 Kick）
	@param shakeType number - 震动类型（EnumMgr.CameraShakeType，1-8）
	@param worldDir Vector3 - 冲击方向（世界空间，不必单位化）
	@param distanceFactor number? - 0~1 额外强度系数，缺省 1
	@param intensityMul number? - 强度乘子，缺省 1，clamp 0~2
	@return boolean - 是否成功
	@return string? - 错误码
	@return number? - 震动句柄
]]
function CameraModule.CameraShakeImpulse(
	shakeType: number,
	worldDir: Vector3,
	distanceFactor: number?,
	intensityMul: number?
): (boolean, string?, number?)
end

--[[
	开始命名源持续相机震动（同源引用计数 +1）
	@param sourceId string - 非空源名（如 "Vehicle" / "Charge"）；不同源可并行
	@param shakeType number - 震动类型（EnumMgr.CameraShakeType，1-8）
	@return boolean - 是否成功
	@return string? - 错误码
	@return number? - 该源层句柄（亦可 CameraShakeCancel）
]]
function CameraModule.CameraShakeSustain(sourceId: string, shakeType: number): (boolean, string?, number?)
end

--[[
	停止一层命名源持续震动（引用计数 -1）；仅作用于该源 Sustain，不误伤 Once / Kick / 其他源
	@param sourceId string - 与 CameraShakeSustain 对应的非空源名
	@param fadeOutTime number? - 引用归零时：缺省自然衰减；>0 加速该源层衰减；<=0 立即移除该源层
	@return boolean - 是否成功
	@return string? - 错误码
]]
function CameraModule.CameraShakeStop(sourceId: string, fadeOutTime: number?): (boolean, string?)
end

--[[
	取消指定句柄的震动（Trauma 层 + 同 id Kick）
	@param handle number - Once/At/Impulse/Sustain 返回的句柄
	@param fadeOutTime number? - 缺省或 >0：Kick 立即移除，层加速/自然衰减；<=0：层与 Kick 立即移除
	@return boolean - 是否成功
	@return string? - 错误码；句柄不存在为 EVENT_NOT_FOUND
]]
function CameraModule.CameraShakeCancel(handle: number, fadeOutTime: number?): (boolean, string?)
end

--[[
	设置全局震动强度
	@param scale number - 0~1
	@return boolean, string? - 是否成功 / 错误码
]]
function CameraModule.SetShakeScale(scale: number): (boolean, string?)
end

--[[
	获取全局震动强度
	@return number - 0~1
]]
function CameraModule.GetShakeScale(): number
end

--[[
	停止全部震动
	@param fadeOutTime number? - 淡出秒数；缺省 0.1；<=0 立即清空
	@return boolean, string? - 是否成功 / 错误码
]]
function CameraModule.StopAllShakes(fadeOutTime: number?): (boolean, string?)
end

--[[
	启用摄像机辅助表现事件，与主规则相机样式叠加（主事件期间 mute）
	@param eventName string - 事件唯一名称
	@param func function - 相机变换函数，返回 CFrame 偏移与 FOV 增量
	@return boolean, string? - 是否成功 / 错误码
]]
function CameraModule.EnableCameraEvent_Helper(
	eventName: string,
	func: (number, number?) -> (CFrame?, number?)
): (boolean, string?)
end

--[[
	禁用摄像机辅助表现事件
	@param eventName string - 事件唯一名称
	@return boolean, string? - 是否成功 / 错误码
]]
function CameraModule.DisableCameraEvent_Helper(eventName: string): (boolean, string?)
end

--[[
	启用摄像机辅助表现事件（EnableCameraEvent_Helper 别名）
	@param eventName string - 事件唯一名称
	@param func (number, number?) -> (CFrame?, number?) - 返回 CFrame 偏移与 FOV 增量
	@return boolean, string? - 是否成功 / 错误码
]]
function CameraModule.EnableCameraHelperEvent(
	eventName: string,
	func: (number, number?) -> (CFrame?, number?)
): (boolean, string?)
end

--[[
	禁用摄像机辅助表现事件（DisableCameraEvent_Helper 别名）
	@param eventName string - 事件唯一名称
	@return boolean, string? - 是否成功 / 错误码
]]
function CameraModule.DisableCameraHelperEvent(eventName: string): (boolean, string?)
end

--[[
	压入相机模式（OTS / LockOn / Aim / ShiftLock）；栈空为 Default
	@param sourceId string - 稳定来源 ID
	@param mode string - EnumMgr.CameraMode / CameraModule.Mode
	@param priority number? - 缺省按模式默认优先级
	@return boolean, string? - 是否成功 / 错误码
]]
function CameraModule.PushMode(sourceId: string, mode: string, priority: number?): (boolean, string?)
end

--[[
	弹出相机模式来源
	@param sourceId string - 与 PushMode 对应
	@return boolean, string? - 是否成功 / 错误码
]]
function CameraModule.PopMode(sourceId: string): (boolean, string?)
end

--[[
	当前优胜相机模式名
	@return string - Default / ShiftLock / OTS / LockOn / Aim
]]
function CameraModule.GetActiveMode(): string
end

return CameraModule
