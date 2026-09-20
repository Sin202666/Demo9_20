--[[
	Module: HumanModule
	Description: 角色查询与本机 CMS 移速入口；NPC 遗留 WalkSpeed 仅非玩家 Humanoid
	Author: 林奥宇
	Created: 2026-07-02
	Last Modified: 2026-08-31

	功能：
	- 查询玩家 Character / Humanoid / Root / Head、存活、ShiftLock / Control 锁
	- 本机移速：只写 Player Attribute + 触发 CharacterMoveSpeed 重算（不写 WalkSpeed）
	- NPC 遗留：非玩家 Humanoid 可读「属性」下 Speed 并直写 WalkSpeed

	与相关模块：
	- 玩家 WalkSpeed 唯一写口是 CharacterMoveSpeed（Attribute 乘算 + Bind Modifier）。
	  SetHumanWalkSpeed / PhysicChange* 对玩家角色拒绝直写（结构 §1.7）。
	- 技能减速走 SetLocalPlayerSpeedAttribute + UpdateLocalPlayerSpeed（见 LookAt）。
	- GetIsControlLookLocked / GetIsControlInteractLocked 只读封装 CharacterControl 聚合 Attribute。
	- 逻辑怪位姿走 LogicEntityMotion / EnemySim，不要对本模块写玩家位姿。

	加载方式：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local HumanModule = Utils.HumanModule

	示例：
		if HumanModule.IsPlrCharAlive(player) then
			local root = HumanModule.GetHumanoidRootPart(player)
		end
		HumanModule.SetLocalPlayerSpeedAttribute("RELEASE_SKILL_STATE_HALF", true)
		HumanModule.UpdateLocalPlayerSpeed(0.1)
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Log = Utils.Log
local NetWork = Utils.NetWork
local NetMsg = Utils.NetMsg
local LocalPlayer = Utils.LocalPlayer
local Players = Utils.Players

-- ========================================
-- 模块定义
-- ========================================
local HumanModule = {}

-- ========================================
-- 常量定义
-- ========================================
local ATTR_PHYSIC_END_TIME = "PhysicEndTime"
local ATTR_OLD_WALK_SPEED = "oldWalkSpeed"
local ATTR_CONTROL = "Control"
local ATTR_SLOW = "Slow"
local ATTR_SHIFT_LOCKED = "IsShiftLocked"
local ATTR_CONTROL_LOOK_LOCKED = "IsControlLookLocked"
local ATTR_CONTROL_INTERACT_LOCKED = "IsControlInteractLocked"
local CHILD_PROPERTY = "属性"
local PART_ROOT = "HumanoidRootPart"
local PART_HEAD = "Head"
local SPEED_CHILD_NAME = "Speed"
local CONTROL_DISABLED_VALUE = 1
local PHYSIC_END_CHECK_BUFFER = 0.5

local ERR_INVALID_HUMANOID = "INVALID_HUMANOID"
local ERR_INVALID_PARAM = "INVALID_PARAM"
local ERR_PLAYER_CMS_OWNED = "PLAYER_WALKSPEED_CMS"
local ERR_CLIENT_ONLY = "CLIENT_ONLY"

-- ========================================
-- 私有函数
-- ========================================

--[[
	检查 Humanoid 是否仍挂载在场景中

	@param humanoid Humanoid - Humanoid 对象
	@return boolean - 仍有效返回 true
]]
local function _isHumanoidAlive(humanoid: Humanoid): boolean
	return humanoid.Parent ~= nil
end

--[[
	Humanoid 是否属于玩家角色（玩家 WalkSpeed 归 CharacterMoveSpeed）

	@param humanoid Humanoid - Humanoid 对象
	@return boolean - 属于玩家角色返回 true
]]
local function _isPlayerCharacterHumanoid(humanoid: Humanoid): boolean
	local character = humanoid.Parent
	if not character or not character:IsA("Model") then
		return false
	end
	return Players:GetPlayerFromCharacter(character) ~= nil
end

--[[
	非玩家 Humanoid 才直写 WalkSpeed；玩家角色拒绝（CMS 唯一写口）

	@param humanoid Humanoid - Humanoid 对象
	@param walkSpeed number - 目标移速
	@return boolean - 已写入返回 true；拒绝或无效返回 false
	@return string? - 失败错误码；成功为 nil
]]
local function _tryWriteWalkSpeed(humanoid: Humanoid, walkSpeed: number): (boolean, string?)
	if not _isHumanoidAlive(humanoid) then
		return false, ERR_INVALID_HUMANOID
	end
	if _isPlayerCharacterHumanoid(humanoid) then
		Log.warn("HumanModule: 玩家 WalkSpeed 只经 CharacterMoveSpeed 写入，已拒绝直写")
		return false, ERR_PLAYER_CMS_OWNED
	end
	humanoid.WalkSpeed = walkSpeed
	return true, nil
end

--[[
	检查物理移速效果是否已结束，结束时恢复原始移速并清理 Attribute

	@param humanoid Humanoid - Humanoid 对象
	@return boolean - 效果已结束或 Humanoid 无效时返回 true
]]
local function _checkPhysicEnd(humanoid: Humanoid): boolean
	if not _isHumanoidAlive(humanoid) then
		return true
	end

	local physicEndTime: number? = humanoid:GetAttribute(ATTR_PHYSIC_END_TIME) :: number?
	if not physicEndTime then
		return true
	end

	if tick() >= physicEndTime then
		local oldWalkSpeed: number? = humanoid:GetAttribute(ATTR_OLD_WALK_SPEED) :: number?
		if oldWalkSpeed then
			_tryWriteWalkSpeed(humanoid, oldWalkSpeed)
		end
		humanoid:SetAttribute(ATTR_PHYSIC_END_TIME, nil)
		return true
	end

	return false
end

--[[
	获取移速增益乘数

	@param humanoid Humanoid - Humanoid 对象
	@return number - 被控制时返回 0，否则返回 Slow 属性值或 1
]]
local function _getSpeedBuffValue(humanoid: Humanoid): number
	if humanoid:GetAttribute(ATTR_CONTROL) == CONTROL_DISABLED_VALUE then
		return 0
	end

	local slowValue: number? = humanoid:GetAttribute(ATTR_SLOW) :: number?
	return slowValue or 1
end

--[[
	从 Humanoid 下属性文件夹读取速度并设置移速（仅非玩家）

	@param humanoid Humanoid - Humanoid 对象
	@param speedKey string - 属性子节点名（如 Speed）
	@return boolean - 已写入返回 true
	@return string? - 失败错误码；成功为 nil
]]
local function _setWalkSpeedFromProperty(humanoid: Humanoid, speedKey: string): (boolean, string?)
	local property: Instance? = humanoid:FindFirstChild(CHILD_PROPERTY)
	if not property then
		return false, ERR_INVALID_PARAM
	end

	local speed: Instance? = property:FindFirstChild(speedKey)
	if speed and speed:IsA("NumberValue") then
		return HumanModule.SetHumanWalkSpeed(humanoid, speed.Value)
	end
	return false, ERR_INVALID_PARAM
end

--[[
	解析查询目标玩家：显式传入优先，否则本机 LocalPlayer

	@param plr Player? - 显式玩家；nil 时用 LocalPlayer
	@return Player? - 可查询的玩家；服务端且未传入时为 nil
]]
local function _resolvePlayer(plr: Player?): Player?
	if plr then
		return plr
	end
	return LocalPlayer
end

--[[
	读取玩家布尔 Attribute（缺省本机）

	@param plr Player? - 显式玩家；nil 时用 LocalPlayer
	@param attrName string - Attribute 名
	@return boolean - 值为 true 时返回 true，其余为 false
]]
local function _getPlayerBoolAttr(plr: Player?, attrName: string): boolean
	local target = _resolvePlayer(plr)
	if not target then
		return false
	end
	return target:GetAttribute(attrName) == true
end

-- ========================================
-- 查询 API
-- ========================================

--[[
	获取玩家的角色模型

	@param plr Player - 玩家对象
	@return Model? - 角色模型，不存在时返回 nil
]]
function HumanModule.GetCharacter(plr: Player): Model?
	return plr.Character
end

--[[
	获取玩家的 HumanoidRootPart

	@param plr Player - 玩家对象
	@return Part? - HumanoidRootPart，不存在时返回 nil
]]
function HumanModule.GetHumanoidRootPart(plr: Player): Part?
	local character: Model? = plr.Character
	if not character then
		return nil
	end
	return character:FindFirstChild(PART_ROOT) :: Part?
end

--[[
	获取玩家的头部部件

	@param plr Player - 玩家对象
	@return Part? - 头部部件，不存在时返回 nil
]]
function HumanModule.GetHeadPart(plr: Player): Part?
	local character: Model? = plr.Character
	if not character then
		return nil
	end
	return character:FindFirstChild(PART_HEAD) :: Part?
end

--[[
	获取玩家的 Humanoid

	@param plr Player - 玩家对象
	@return Humanoid? - Humanoid 对象，不存在时返回 nil
]]
function HumanModule.GetHumanoid(plr: Player): Humanoid?
	local character: Model? = plr.Character
	if not character then
		return nil
	end
	return character:FindFirstChildOfClass("Humanoid")
end

--[[
	玩家角色是否存活（有 Character 且 Humanoid.Health > 0）

	@param plr Player - 玩家对象
	@return boolean - 存活为 true；玩家/角色/Humanoid 缺失为 false
]]
function HumanModule.IsPlrCharAlive(plr: Player): boolean
	if not plr then
		return false
	end
	local character = plr.Character
	if not character then
		return false
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return false
	end
	return humanoid.Health > 0
end

--[[
	是否处于 ShiftLock（Player Attribute IsShiftLocked）

	@param plr Player? - 省略时用 LocalPlayer（仅客户端）
	@return boolean - Attribute 为 true 时返回 true
]]
function HumanModule.GetIsShiftLocked(plr: Player?): boolean
	return _getPlayerBoolAttr(plr, ATTR_SHIFT_LOCKED)
end

--[[
	CharacterControl Look 锁是否生效（Attribute IsControlLookLocked）

	@param plr Player? - 省略时用 LocalPlayer
	@return boolean - Attribute 为 true 时返回 true
]]
function HumanModule.GetIsControlLookLocked(plr: Player?): boolean
	return _getPlayerBoolAttr(plr, ATTR_CONTROL_LOOK_LOCKED)
end

--[[
	CharacterControl Interact 锁是否生效（Attribute IsControlInteractLocked）

	@param plr Player? - 省略时用 LocalPlayer
	@return boolean - Attribute 为 true 时返回 true
]]
function HumanModule.GetIsControlInteractLocked(plr: Player?): boolean
	return _getPlayerBoolAttr(plr, ATTR_CONTROL_INTERACT_LOCKED)
end

--[[
	当前持有物品类型（一期占位，恒返回 nil）

	@param _plr Player - 玩家（未使用）
	@return string? - 如 "Weapon"；当前无实现，恒为 nil
]]
function HumanModule.GetHeldItemType(_plr: Player): string?
	return nil
end

-- ========================================
-- 本机 CMS 移速入口（不写 WalkSpeed）
-- ========================================

--[[
	设置本机移速状态 Attribute（CharacterMoveSpeed 乘算层，如 RELEASE_SKILL_STATE_HALF）
	仅客户端有效；服务端返回 false。

	@param attr string - Attribute 键（非空字符串）
	@param value boolean - 是否启用
	@return boolean - 已写入返回 true
	@return string? - 失败错误码 CLIENT_ONLY / INVALID_PARAM；成功为 nil
]]
function HumanModule.SetLocalPlayerSpeedAttribute(attr: string, value: boolean): (boolean, string?)
	if type(attr) ~= "string" or attr == "" then
		return false, ERR_INVALID_PARAM
	end
	if not LocalPlayer then
		return false, ERR_CLIENT_ONLY
	end
	LocalPlayer:SetAttribute(attr, value == true)
	return true, nil
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
	if not LocalPlayer then
		return false, ERR_CLIENT_ONLY
	end
	NetWork.FireBindable(NetMsg.UPDATE_CHARACTER_SPEED, duration, easingStyle, easingDirection)
	return true, nil
end

-- ========================================
-- NPC 遗留移速（禁止用于玩家角色）
-- ========================================

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
	if not humanoid or not _isHumanoidAlive(humanoid) then
		return false, ERR_INVALID_HUMANOID
	end
	if type(walkSpeed) ~= "number" or type(duration) ~= "number" or duration < 0 then
		return false, ERR_INVALID_PARAM
	end
	if _isPlayerCharacterHumanoid(humanoid) then
		Log.warn("HumanModule.PhysicChangeHumanWalkSpeed: 玩家 WalkSpeed 只经 CharacterMoveSpeed")
		return false, ERR_PLAYER_CMS_OWNED
	end

	if humanoid:GetAttribute(ATTR_OLD_WALK_SPEED) == nil then
		humanoid:SetAttribute(ATTR_OLD_WALK_SPEED, humanoid.WalkSpeed)
	end

	local endTime: number = tick() + duration
	humanoid:SetAttribute(ATTR_PHYSIC_END_TIME, endTime)
	humanoid.WalkSpeed = walkSpeed

	task.delay(duration, function()
		if _isHumanoidAlive(humanoid) then
			_checkPhysicEnd(humanoid)
		end
	end)
	task.delay(duration + PHYSIC_END_CHECK_BUFFER, function()
		if _isHumanoidAlive(humanoid) then
			_checkPhysicEnd(humanoid)
		end
	end)
	return true, nil
end

--[[
	按百分比临时改变非玩家 Humanoid 移速（相对 oldWalkSpeed，缺则用当前 WalkSpeed）

	@param humanoid Humanoid - Humanoid 对象
	@param percent number - 速度百分比（如 0.5 表示 50%）
	@param duration number - 持续时间（秒，≥0）
	@return boolean - 已写入返回 true
	@return string? - 失败错误码；成功为 nil
]]
function HumanModule.PhysicChangeHumanWalkSpeedPercent(humanoid: Humanoid, percent: number, duration: number): (boolean, string?)
	if not humanoid or not _isHumanoidAlive(humanoid) then
		return false, ERR_INVALID_HUMANOID
	end
	if type(percent) ~= "number" or type(duration) ~= "number" then
		return false, ERR_INVALID_PARAM
	end

	local oldWalkSpeed: number? = humanoid:GetAttribute(ATTR_OLD_WALK_SPEED) :: number?
	if not oldWalkSpeed then
		oldWalkSpeed = humanoid.WalkSpeed
		humanoid:SetAttribute(ATTR_OLD_WALK_SPEED, oldWalkSpeed)
	end

	return HumanModule.PhysicChangeHumanWalkSpeed(humanoid, oldWalkSpeed * percent, duration)
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
	if not humanoid or not _isHumanoidAlive(humanoid) then
		return false, ERR_INVALID_HUMANOID
	end
	if type(walkSpeed) ~= "number" then
		return false, ERR_INVALID_PARAM
	end

	local ok, err = _tryWriteWalkSpeed(humanoid, walkSpeed * _getSpeedBuffValue(humanoid))
	if not ok then
		return false, err
	end
	humanoid:SetAttribute(ATTR_OLD_WALK_SPEED, walkSpeed)
	return true, nil
end

--[[
	根据 NPC「属性」文件夹下 Speed 设置移动速度（仅非玩家）

	@param humanoid Humanoid - Humanoid 对象
	@return boolean - 已写入返回 true
	@return string? - 失败错误码；成功为 nil
]]
function HumanModule.SetNPCWalkSpeed(humanoid: Humanoid): (boolean, string?)
	if not humanoid or not _isHumanoidAlive(humanoid) then
		return false, ERR_INVALID_HUMANOID
	end
	return _setWalkSpeedFromProperty(humanoid, SPEED_CHILD_NAME)
end

--[[
	根据英雄「属性」文件夹下 Speed 设置移动速度（仅非玩家；子节点名与 NPC 相同）

	@param humanoid Humanoid - Humanoid 对象
	@return boolean - 已写入返回 true
	@return string? - 失败错误码；成功为 nil
]]
function HumanModule.SetHeroWalkSpeed(humanoid: Humanoid): (boolean, string?)
	if not humanoid or not _isHumanoidAlive(humanoid) then
		return false, ERR_INVALID_HUMANOID
	end
	return _setWalkSpeedFromProperty(humanoid, SPEED_CHILD_NAME)
end

--[[
	按记录的 oldWalkSpeed 重新应用增益（仅非玩家）

	@param humanoid Humanoid - Humanoid 对象
	@return boolean - 已写入返回 true
	@return string? - 失败错误码；成功为 nil
]]
function HumanModule.RefreshHumanWalkSpeed(humanoid: Humanoid): (boolean, string?)
	if not humanoid or not _isHumanoidAlive(humanoid) then
		return false, ERR_INVALID_HUMANOID
	end

	local oldSpeed: number = humanoid:GetAttribute(ATTR_OLD_WALK_SPEED) :: number? or humanoid.WalkSpeed
	return HumanModule.SetHumanWalkSpeed(humanoid, oldSpeed)
end

return HumanModule
