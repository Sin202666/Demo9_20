--!strict
--[[
	Module: DeviceType
	Description: 客户端输入设备类型查询（移动 / PC / 手柄）；不做输入绑定或权威结算
	Author: 林奥宇
	Created: 2026-07-03
	Last Modified: 2026-09-01

	功能：
	- IsMobile()   是否为移动设备（手机/平板，触控为主）
	- IsPc()       是否为 PC（键鼠为主）
	- IsGamepad()  当前是否启用手柄输入
	- IsGamePad()  IsGamepad 的历史别名（RP17 / 技能系统）

	------------------------------------------------------------------------
	何时使用本模块
	------------------------------------------------------------------------
	只问「当前是什么设备」→ Utils.DeviceType。
	要做 Action / Context / 按键绑定 → 用 SystemInput，不要在本模块扩展输入逻辑。
	本模块不写位姿、速度、伤害或奖励。

	------------------------------------------------------------------------
	端侧约束
	------------------------------------------------------------------------
	仅客户端有意义。UserInputService 在服务端不能代表玩家设备。
	禁止用本模块结果做服务端权威结算（伤害、掉落、任务完成等）。
	AllSide 可加载，但服务端调用会得到无意义的默认值。

	------------------------------------------------------------------------
	判定规则
	------------------------------------------------------------------------
	- 移动 / PC：模块加载时按 PreferredInput 缓存；纯触摸（无键鼠/手柄）兜底为移动。
	- PreferredInput == Gamepad 时 IsMobile / IsPc 均为 false，请用 IsGamepad()。
	- 手柄：IsGamepad() 每次读 UserInputService.GamepadEnabled（可热插拔）。
	- 三者可以同时为 false（例如首选手柄且尚未 GamepadEnabled），调用方须兜底布局。

	加载方式：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local DeviceType = Utils.DeviceType

	示例：
		if DeviceType.IsMobile() then
			-- 触控布局
		elseif DeviceType.IsGamepad() then
			-- 手柄提示
		elseif DeviceType.IsPc() then
			-- 键鼠布局
		end
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local UserInputService = Utils.UserInputService

-- ========================================
-- 模块定义
-- ========================================
local DeviceType = {}

-- ========================================
-- 私有变量
-- ========================================
local _isMobile = false
local _isPc = false

-- ========================================
-- 私有函数
-- ========================================

--[[
	在模块加载时解析并写入移动/PC 标志（副作用：改写 _isMobile / _isPc）
	优先 PreferredInput；纯触摸设备（无键鼠/手柄）兜底为移动，并清掉 PC 标志
	@return nil - 无返回值
]]
local function _resolveDeviceFlags()
	local preferredInput = UserInputService.PreferredInput

	_isMobile = preferredInput == Enum.PreferredInput.Touch
	_isPc = preferredInput == Enum.PreferredInput.KeyboardAndMouse

	if UserInputService.TouchEnabled
		and not UserInputService.MouseEnabled
		and not UserInputService.KeyboardEnabled
		and not UserInputService.GamepadEnabled
	then
		_isMobile = true
	end

	if _isMobile then
		_isPc = false
	end
end

_resolveDeviceFlags()

-- ========================================
-- 公共 API
-- ========================================

--[[
	检测当前是否为移动设备（手机/平板）
	返回模块加载时缓存的标志，不随 PreferredInput 热切换更新
	@return boolean - 移动设备为 true，否则 false
]]
function DeviceType.IsMobile(): boolean
	return _isMobile
end

--[[
	检测当前是否为 PC 设备（键鼠为主）
	返回模块加载时缓存的标志；首选手柄时为 false
	@return boolean - PC 设备为 true，否则 false
]]
function DeviceType.IsPc(): boolean
	return _isPc
end

--[[
	检测当前是否启用手柄输入
	每次实时读取 GamepadEnabled，可反映热插拔
	@return boolean - 已启用手柄输入为 true，否则 false
]]
function DeviceType.IsGamepad(): boolean
	return UserInputService.GamepadEnabled
end

--[[
	IsGamepad 的历史别名（RP17 / 技能系统）
	新代码请调用 IsGamepad()
	@return boolean - 已启用手柄输入为 true，否则 false
]]
DeviceType.IsGamePad = DeviceType.IsGamepad

return DeviceType
