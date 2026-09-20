--[[
	Module: HumanModule-Type
	Description: HumanModule 接口桩（查询、本机 CMS 入口、NPC 遗留移速）
]]

local HumanModule = {}

--[[
	获取玩家角色

	@param plr Player - 玩家对象
	@return Model? - 角色模型，不存在时返回 nil
]]
function HumanModule.GetCharacter(plr: Player): Model?
end

--[[
	获取玩家角色的 HumanoidRootPart

	@param plr Player - 玩家对象
	@return Part? - HumanoidRootPart，不存在时返回 nil
]]
function HumanModule.GetHumanoidRootPart(plr: Player): Part?
end

--[[
	获取玩家角色的头部

	@param plr Player - 玩家对象
	@return Part? - 头部部件，不存在时返回 nil
]]
function HumanModule.GetHeadPart(plr: Player): Part?
end

--[[
	获取玩家角色的 Humanoid

	@param plr Player - 玩家对象
	@return Humanoid? - Humanoid 对象，不存在时返回 nil
]]
function HumanModule.GetHumanoid(plr: Player): Humanoid?
end

--[[
	玩家角色是否存活（有 Character 且 Humanoid.Health > 0）

	@param plr Player - 玩家对象
	@return boolean - 存活为 true；玩家/角色/Humanoid 缺失为 false
]]
function HumanModule.IsPlrCharAlive(plr: Player): boolean
end

--[[
	是否处于 ShiftLock（Player Attribute IsShiftLocked）

	@param plr Player? - 省略时用 LocalPlayer（仅客户端）
	@return boolean - Attribute 为 true 时返回 true
]]
function HumanModule.GetIsShiftLocked(plr: Player?): boolean
end

--[[
	CharacterControl Look 锁是否生效（Attribute IsControlLookLocked）

	@param plr Player? - 省略时用 LocalPlayer
	@return boolean - Attribute 为 true 时返回 true
]]
function HumanModule.GetIsControlLookLocked(plr: Player?): boolean
end

--[[
	CharacterControl Interact 锁是否生效（Attribute IsControlInteractLocked）

	@param plr Player? - 省略时用 LocalPlayer
	@return boolean - Attribute 为 true 时返回 true
]]
function HumanModule.GetIsControlInteractLocked(plr: Player?): boolean
end

--[[
	当前持有物品类型（一期占位，恒返回 nil）

	@param _plr Player - 玩家（未使用）
	@return string? - 如 "Weapon"；当前无实现，恒为 nil
]]
function HumanModule.GetHeldItemType(_plr: Player): string?
end

--[[
	设置本机移速状态 Attribute（CharacterMoveSpeed 乘算层）
	仅客户端有效；服务端返回 false。

	@param attr string - Attribute 键（非空字符串）
	@param value boolean - 是否启用
	@return boolean - 已写入返回 true
	@return string? - 失败错误码 CLIENT_ONLY / INVALID_PARAM；成功为 nil
]]
function HumanModule.SetLocalPlayerSpeedAttribute(attr: string, value: boolean): (boolean, string?)
end

--[[
	触发本机 CharacterMoveSpeed 重算（经 UPDATE_CHARACTER_SPEED Bindable）
	仅客户端有效；服务端返回 false。

	@param duration number? - 过渡秒数；nil/0 为瞬间
	@param easingStyle Enum.EasingStyle? - 缓动样式
	@param easingDirection Enum.EasingDirection? - 缓动方向
	@return boolean - 已 FireBindable 返回 true
	@return string? - 失败错误码 CLIENT_ONLY；成功为 nil
]]
function HumanModule.UpdateLocalPlayerSpeed(
	duration: number?,
	easingStyle: Enum.EasingStyle?,
	easingDirection: Enum.EasingDirection?
): (boolean, string?)
end

--[[
	临时改变非玩家 Humanoid 移速，到期后恢复 oldWalkSpeed
	玩家角色拒绝（WalkSpeed 归 CharacterMoveSpeed）。

	@param humanoid Humanoid - Humanoid 对象
	@param walkSpeed number - 目标移动速度
	@param duration number - 持续时间（秒，≥0）
	@return boolean - 已写入返回 true
	@return string? - 失败错误码；成功为 nil
]]
function HumanModule.PhysicChangeHumanWalkSpeed(humanoid: Humanoid, walkSpeed: number, duration: number): (boolean, string?)
end

--[[
	按百分比临时改变非玩家 Humanoid 移速（相对 oldWalkSpeed）

	@param humanoid Humanoid - Humanoid 对象
	@param percent number - 速度百分比（如 0.5 表示 50%）
	@param duration number - 持续时间（秒，≥0）
	@return boolean - 已写入返回 true
	@return string? - 失败错误码；成功为 nil
]]
function HumanModule.PhysicChangeHumanWalkSpeedPercent(humanoid: Humanoid, percent: number, duration: number): (boolean, string?)
end

--[[
	设置非玩家 Humanoid 的移动速度（写入 oldWalkSpeed 并乘增益）
	玩家角色拒绝。

	@param humanoid Humanoid - Humanoid 对象
	@param walkSpeed number - 基础移动速度
	@return boolean - 已写入返回 true
	@return string? - 失败错误码；成功为 nil
]]
function HumanModule.SetHumanWalkSpeed(humanoid: Humanoid, walkSpeed: number): (boolean, string?)
end

--[[
	根据 NPC「属性」文件夹下 Speed 设置移动速度（仅非玩家）

	@param humanoid Humanoid - Humanoid 对象
	@return boolean - 已写入返回 true
	@return string? - 失败错误码；成功为 nil
]]
function HumanModule.SetNPCWalkSpeed(humanoid: Humanoid): (boolean, string?)
end

--[[
	根据英雄「属性」文件夹下 Speed 设置移动速度（仅非玩家）

	@param humanoid Humanoid - Humanoid 对象
	@return boolean - 已写入返回 true
	@return string? - 失败错误码；成功为 nil
]]
function HumanModule.SetHeroWalkSpeed(humanoid: Humanoid): (boolean, string?)
end

--[[
	按记录的 oldWalkSpeed 重新应用增益（仅非玩家）

	@param humanoid Humanoid - Humanoid 对象
	@return boolean - 已写入返回 true
	@return string? - 失败错误码；成功为 nil
]]
function HumanModule.RefreshHumanWalkSpeed(humanoid: Humanoid): (boolean, string?)
end

return HumanModule
