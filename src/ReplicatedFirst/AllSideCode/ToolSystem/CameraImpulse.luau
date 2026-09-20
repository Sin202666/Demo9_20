--[[
	Module: CameraImpulse
	Description: 客户端镜头脉冲总线（本期仅 FovPulse）。技能/业务只 emit；AnimateFov bind 后消费。
	Author: 林奥宇
	Created: 2026-07-30
	Last Modified: 2026-08-28

	边界（与 CameraModule 所有权约定）：
	- 不注册 CameraModule Helper；FOV 仍由 AnimateFov 唯一 Helper「移速影响相机FOV」输出。
	- 禁止业务平行注册 FOV Helper；脉冲只经本总线 emit → AnimateFov。
	- 服务端调用一律 no-op。
	- soft-merge：emit(..., adoptIfActive=true) 且 isFovPulseActive 时不重开，避免二次放大。
	- Shake 仍走 CameraModule.CameraShakeOnce，不并入本总线。
	- 不写 CurrentCamera.CFrame / FieldOfView（绝对 FOV 仅 CameraModule 写）。

	加载：
		local CameraImpulse = Utils.CameraImpulse

	示例：
		-- Animate/init（LocalPlayer 角色）
		CameraImpulse.bind(character, {
			playFovPulse = fovCtrl.playDashImpulse,
			cancelFovPulse = fovCtrl.cancelDashImpulse,
			isFovPulseActive = fovCtrl.isDashActive,
		})
		-- DashStyleRoll
		CameraImpulse.emit(character, {
		kind = KIND_FOV_PULSE,
			id = "Dash:Forward",
			adoptIfActive = true,
		})
		CameraImpulse.cancel(character)
]]

local RunService = game:GetService("RunService")

local CameraImpulse = {}

export type FovPulseOpts = {
	addFov: number?,
	riseSec: number?,
	downSec: number?,
}

export type CameraImpulseBindHandlers = {
	playFovPulse: (opts: FovPulseOpts?) -> (),
	cancelFovPulse: () -> (),
	isFovPulseActive: (() -> boolean)?,
}

export type CameraImpulseEmitSpec = {
	kind: string,
	id: string?,
	addFov: number?,
	riseSec: number?,
	downSec: number?,
	adoptIfActive: boolean?,
}

local KIND_FOV_PULSE = "FovPulse"
-- Character 弱键：重生/销毁后可 GC
local _binds: { [Model]: CameraImpulseBindHandlers } = setmetatable({}, { __mode = "k" })
local _isClient = RunService:IsClient()

--[[
	是否已为该角色 bind 消费者
	@param character Model - 角色
	@return boolean - 客户端且已 bind 该角色时为 true
]]
function CameraImpulse.hasBind(character: Model): boolean
	if not _isClient or not character then
		return false
	end
	return _binds[character] ~= nil
end

--[[
	注册角色的 FOV 脉冲消费者（通常 AnimateFov 在 create 后调用）
	@param character Model - 本地玩家角色
	@param handlers CameraImpulseBindHandlers - play/cancel/isActive
]]
function CameraImpulse.bind(character: Model, handlers: CameraImpulseBindHandlers)
	if not _isClient or not character or type(handlers) ~= "table" then
		return
	end
	if type(handlers.playFovPulse) ~= "function" or type(handlers.cancelFovPulse) ~= "function" then
		warn("[CameraImpulse] bind 需要 playFovPulse 与 cancelFovPulse")
		return
	end
	_binds[character] = handlers
end

--[[
	解除消费者（角色销毁 / Animate destroy）
	@param character Model - 角色
]]
function CameraImpulse.unbind(character: Model)
	if not character then
		return
	end
	_binds[character] = nil
end

--[[
	发射脉冲；无 bind 或非客户端静默 return
	@param character Model - 目标角色
	@param spec CameraImpulseEmitSpec - kind=FovPulse；adoptIfActive 时活跃则不重开
]]
function CameraImpulse.emit(character: Model, spec: CameraImpulseEmitSpec)
	if not _isClient or not character or type(spec) ~= "table" then
		return
	end
	if spec.kind ~= KIND_FOV_PULSE then
		return
	end
	local handlers = _binds[character]
	if not handlers then
		return
	end
	if spec.adoptIfActive == true then
		local isActive = handlers.isFovPulseActive
		if type(isActive) == "function" and isActive() == true then
			return
		end
	end
	handlers.playFovPulse({
		addFov = spec.addFov,
		riseSec = spec.riseSec,
		downSec = spec.downSec,
	})
end

--[[
	取消当前 FOV 脉冲（本期忽略 id，等价 cancelFovPulse）
	@param character Model - 目标角色
	@param _id string? - 预留；本期未按 id 过滤
]]
function CameraImpulse.cancel(character: Model, _id: string?)
	if not _isClient or not character then
		return
	end
	local handlers = _binds[character]
	if not handlers then
		return
	end
	handlers.cancelFovPulse()
end

return CameraImpulse