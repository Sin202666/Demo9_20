--[[
	Module: CharacterMotion.PlanarImpulse
	Description: Drive 令牌门面（Find/Start/Adopt/Destroy）；实际速度合成见 VelocityMotor
	Author: 林奥宇
	Created: 2026-08-05
	Last Modified: 2026-08-31

	与兄弟模块：
	- 业务入口请用 Utils.CharacterMotion（Begin / AddImpulse / ApplyKnockback）
	- 本文件仅为旧 PlanarImpulse API 兼容转发，勿单独挂 Utils 键
	- 速度合成与碰撞扫掠在 VelocityMotor

	兼容旧 API 名（IsImpulseActive / EndImpulseKeepMarker / ScheduleEnd）。
	业务新代码优先经 CharacterMotion.Begin / AddImpulse，勿直写 AssemblyLinearVelocity。

	加载：
		local CharacterMotion = Utils.CharacterMotion
		-- 仅兼容：CharacterMotion.PlanarImpulse.Start(...)
]]

local VelocityMotor = require(script.Parent.VelocityMotor)

local PlanarImpulse = {}

PlanarImpulse.FindToken = VelocityMotor.FindToken
PlanarImpulse.IsImpulseActive = VelocityMotor.IsDriveActive
PlanarImpulse.IsDriveActive = VelocityMotor.IsDriveActive
PlanarImpulse.EndImpulseKeepMarker = VelocityMotor.EndDriveKeepMarker
PlanarImpulse.EndDriveKeepMarker = VelocityMotor.EndDriveKeepMarker
PlanarImpulse.ScheduleEnd = VelocityMotor.ScheduleDriveEnd
PlanarImpulse.DestroyAll = VelocityMotor.DestroyAll

--[[
	在 HRP 上启动 Drive（需传入 character 时走完整电机；仅 HRP 时从 Parent 解析）
	@param HRP BasePart - 角色 HumanoidRootPart
	@param directionWorld Vector3 - 世界空间平面方向（电机会归一化）
	@param recipe table - PlanarRecipe 字段表（planeSpeed / tweenDuration 等，见 Types）
	@param sessionId string? - 可选会话 ID，供仲裁/调试
	@return Attachment? - Drive 附着点；失败为 nil
	@return LinearVelocity? - Drive 约束；失败为 nil
]]
function PlanarImpulse.Start(HRP: BasePart, directionWorld: Vector3, recipe: any, sessionId: string?): (Attachment?, LinearVelocity?)
	local character = HRP and HRP.Parent
	if not (character and character:IsA("Model")) then
		return nil, nil
	end
	return VelocityMotor.StartDrive(character, HRP, directionWorld, recipe, sessionId)
end

--[[
	接管既有 Drive 令牌
	@param attach Attachment - 既有 Drive Attachment
	@param lv LinearVelocity - 既有 LinearVelocity
	@param tweenDur number - 剩余/总曲线时长（秒）
	@param elapsedSec number - 已推进秒数
	@param recipe any? - 可选配方覆盖；字段见 Types.PlanarRecipe
	@return boolean - 是否接管成功
]]
function PlanarImpulse.Adopt(attach: Attachment, lv: LinearVelocity, tweenDur: number, elapsedSec: number, recipe: any?): boolean
	local HRP = attach and attach.Parent
	local character = HRP and HRP.Parent
	if not (character and character:IsA("Model")) then
		return false
	end
	return VelocityMotor.AdoptDrive(character :: Model, attach, lv, tweenDur, elapsedSec, recipe)
end

return PlanarImpulse