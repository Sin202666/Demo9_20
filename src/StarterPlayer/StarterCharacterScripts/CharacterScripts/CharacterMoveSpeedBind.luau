--[[
	Module: CharacterMoveSpeedBind
	Description: 角色移速 Bindable 单次注册桥接 + MoveSynthesis Modifier 栈。
	Author: 林奥宇
	Created: 2026-07-03
	Last Modified: 2026-09-03

	功能：
	- 注册 NetMsg.UPDATE_CHARACTER_SPEED（replace=true）：本 Module 随角色克隆，环境是新的，
	  NetWork 登记表是进程级；重生必须覆盖 handler
	- Modifier 栈（技能锁速、Sprint、坐骑加减速覆盖）；禁止业务裸写 WalkSpeed

	与相关模块：
	- 写口只在 CharacterMoveSpeed（CMS）；本模块只合成目标速并通知重算
	- CharacterControl / LockMovement 经 pushModifier / popModifier 接入

	加载方式（角色脚本，非 Utils 键）：
		local Bind = require(script.Parent:WaitForChild("CharacterMoveSpeedBind"))

	使用示例：
		Bind.setHandler(onUpdate)
		Bind.pushModifier("LockMovement:NewRoll:0", { mul = 0 })
		Bind.pushModifier("Control:Sprint", { add = runAdd })
		Bind.clearHandler(onUpdate)

	合成顺序：pairs 遍历栈，逐条 speed = speed * mul + add；任一条 hardLock（或 mul=0）则最终为 0。
	accelDuration / decelDuration：可选覆盖 CMS MoveDirection 加减速时长（取栈内最大值）。
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local NetWork = Utils.NetWork
local NetMsg = Utils.NetMsg
local Log = Utils.Log

export type MoveModifierSpec = {
	mul: number?,
	add: number?,
	hardLock: boolean?,
	accelDuration: number?,
	decelDuration: number?,
}

export type MoveModifier = {
	mul: number,
	add: number,
	hardLock: boolean,
	accelDuration: number?,
	decelDuration: number?,
}

-- ========================================
-- 模块定义
-- ========================================
local CharacterMoveSpeedBind = {}

-- ========================================
-- 私有变量
-- ========================================
local _handler: ((number?, Enum.EasingStyle?, Enum.EasingDirection?) -> ())? = nil
local _modifiers: { [string]: MoveModifier } = {}

-- ========================================
-- 私有函数
-- ========================================

--[[
	通知 CMS 立即按当前合成结果重算移速
]]
local function _notifyRecompute()
	if _handler then
		_handler(0)
	end
end

--[[
	规范化 Modifier 字段
	@param spec MoveModifierSpec? - 原始声明
	@return MoveModifier - 规范化结果
]]
local function _normalizeSpec(spec: MoveModifierSpec?): MoveModifier
	local s = spec or {}
	local mul = if type(s.mul) == "number" and s.mul == s.mul then s.mul else 1
	local add = if type(s.add) == "number" and s.add == s.add then s.add else 0
	local accelDuration = if type(s.accelDuration) == "number"
			and s.accelDuration == s.accelDuration
			and s.accelDuration > 0
		then s.accelDuration
		else nil
	local decelDuration = if type(s.decelDuration) == "number"
			and s.decelDuration == s.decelDuration
			and s.decelDuration > 0
		then s.decelDuration
		else nil
	return {
		mul = mul,
		add = add,
		hardLock = s.hardLock == true or mul == 0,
		accelDuration = accelDuration,
		decelDuration = decelDuration,
	}
end

--[[
	向 NetWork 安装/覆盖本克隆的转发闭包。
	角色每次重生都是新 Module 环境；必须 replace，否则会 error 重复注册，
	且旧闭包仍读上一角色已清空的 _handler。
]]
local function _ensureRegistered()
	NetWork.RegisterBindableEvent(NetMsg.UPDATE_CHARACTER_SPEED, function(
		duration: number?,
		easingStyle: Enum.EasingStyle?,
		easingDirection: Enum.EasingDirection?
	)
		if _handler then
			_handler(duration, easingStyle, easingDirection)
		end
	end, { replace = true })
end

-- ========================================
-- 公共函数
-- ========================================

--[[
	设置当前角色的移速更新回调；首次调用会注册 Bindable。替换不同 handler 时清空 Modifier。

	@param handler (number?, Enum.EasingStyle?, Enum.EasingDirection?) -> () - 移速更新回调；duration 为过渡秒，nil/0 为瞬间
]]
function CharacterMoveSpeedBind.setHandler(handler: (number?, Enum.EasingStyle?, Enum.EasingDirection?) -> ())
	_ensureRegistered()
	-- 仅在「替换已有不同 handler」时清空；首次从 nil 注册不得清掉 CharacterControl 等已推 Modifier
	if _handler ~= nil and _handler ~= handler then
		table.clear(_modifiers)
	end
	_handler = handler
	if handler then
		handler(0)
	end
end

--[[
	清除回调（仅当与当前 handler 相同时）；同时清空 Modifier 栈

	@param handler (number?, Enum.EasingStyle?, Enum.EasingDirection?) -> () - 与 setHandler 传入的同一函数引用
]]
function CharacterMoveSpeedBind.clearHandler(handler: (number?, Enum.EasingStyle?, Enum.EasingDirection?) -> ())
	if _handler == handler then
		_handler = nil
		table.clear(_modifiers)
	end
end

--[[
	压入/覆盖一条移速 Modifier（同 ownerId 覆盖）
	@param ownerId string - 占用方 ID（须稳定，预测 handoff 可续）
	@param spec MoveModifierSpec? - mul/add/hardLock/accelDuration/decelDuration；nil 按默认 1/0/false；mul=0 视为 hardLock
]]
function CharacterMoveSpeedBind.pushModifier(ownerId: string, spec: MoveModifierSpec?)
	if type(ownerId) ~= "string" or ownerId == "" then
		Log.warn("CharacterMoveSpeedBind.pushModifier: ownerId 必填")
		return
	end
	_modifiers[ownerId] = _normalizeSpec(spec)
	_notifyRecompute()
end

--[[
	移除一条移速 Modifier；不存在则 no-op
	@param ownerId string - 占用方 ID
]]
function CharacterMoveSpeedBind.popModifier(ownerId: string)
	if type(ownerId) ~= "string" or ownerId == "" then
		return
	end
	if _modifiers[ownerId] == nil then
		return
	end
	_modifiers[ownerId] = nil
	_notifyRecompute()
end

--[[
	是否存在指定 owner 的 Modifier
	@param ownerId string - 占用方 ID
	@return boolean - 是否存在
]]
function CharacterMoveSpeedBind.hasModifier(ownerId: string): boolean
	if type(ownerId) ~= "string" or ownerId == "" then
		return false
	end
	return _modifiers[ownerId] ~= nil
end

--[[
	清空全部 Modifier（角色销毁 / handler 切换时）
]]
function CharacterMoveSpeedBind.clearAllModifiers()
	if next(_modifiers) == nil then
		return
	end
	table.clear(_modifiers)
	_notifyRecompute()
end

--[[
	将 Attribute 合成后的基础目标速再套用 Modifier 栈。
	遍历顺序为 pairs（无稳定序）；公式 speed = speed * mul + add；任一条 hardLock 则返回 0。

	@param baseSpeed number - Attribute 加成/乘算后的目标速
	@return number - 最终合成目标速（≥ 0）；任一条 hardLock 则 0
]]
function CharacterMoveSpeedBind.applyModifiers(baseSpeed: number): number
	local speed = if type(baseSpeed) == "number" and baseSpeed == baseSpeed then baseSpeed else 0
	local hardLock = false
	for _, mod in pairs(_modifiers) do
		if mod.hardLock then
			hardLock = true
		end
		speed = speed * mod.mul + mod.add
	end
	if hardLock then
		return 0
	end
	return math.max(0, speed)
end

--[[
	取 Modifier 栈内加减速时长覆盖（各取最大值；无覆盖返回 nil）
	@return number? - accel 秒
	@return number? - decel 秒
]]
function CharacterMoveSpeedBind.getMotionDurationOverrides(): (number?, number?)
	local accel: number? = nil
	local decel: number? = nil
	for _, mod in pairs(_modifiers) do
		if mod.accelDuration and (accel == nil or mod.accelDuration > accel) then
			accel = mod.accelDuration
		end
		if mod.decelDuration and (decel == nil or mod.decelDuration > decel) then
			decel = mod.decelDuration
		end
	end
	return accel, decel
end

return CharacterMoveSpeedBind
