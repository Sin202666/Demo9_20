--[[
	Module: SystemGameConfig
	Description: 游戏全局配置访问层，封装 ToolBasic/GameConfig 的只读查询
	Author: 林奥宇
	Created: 2026-07-02
	Last Modified: 2026-08-31

	功能：
	- Get：返回 GameConfig 全表深拷贝
	- GetValue：按顶层键或嵌套路径取值；table 深拷贝，标量原样返回
	- ClearCache：丢掉本模块缓存指针，下次查询再读 Utils.GameConfig

	与相关模块的关系：
	- GameConfig：静态开关 / 阈值 / 默认键位的唯一数据源（加载后 freeze）
	- CfgFind / ConfigInstance：导表数据，不走本模块
	- 业务优先本模块；热路径可读 Utils.GameConfig，禁止写回

	约束：
	- 双端可用；无 Init、无 Remote、不改存档
	- 对外永不返回 GameConfig 内存原表
	- ClearCache 不能热替换 ModuleScript（Utils / require 仍持同一实例）

	加载方式：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local SystemGameConfig = Utils.SystemGameConfig

	使用示例：
		local version = SystemGameConfig.GetValue("版本号")
		local skillOn = SystemGameConfig.GetValue({ "技能系统", "启用" })
		local clockSlots = SystemGameConfig.GetValue({ "Clock", "时间段" })
]]

-- ============================================================================
-- 模块引用
-- ============================================================================

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local GameConfig = Utils.GameConfig
local Copy = Utils.Copy

-- ============================================================================
-- 模块定义
-- ============================================================================

local SystemGameConfig = {}

-- ============================================================================
-- 私有变量
-- ============================================================================

local _configData: any? = nil

-- ============================================================================
-- 私有函数
-- ============================================================================

--[[
	取内部缓存的 GameConfig 原表（已 freeze）；仅供本模块查询，禁止外泄

	@return table? - GameConfig 内存表；未加载成功为 nil
]]
local function _loadConfigData(): any?
	if _configData then
		return _configData
	end
	if type(GameConfig) ~= "table" then
		return nil
	end
	_configData = GameConfig
	return _configData
end

--[[
	标量原样返回；table 深拷贝，避免把 GameConfig 内存表交给调用方

	@param value any - 路径解析结果（含 nil / boolean / number / string / table）
	@return any - nil 与标量原值，或 table 的深拷贝
]]
local function _cloneConfigValue(value: any): any
	if type(value) ~= "table" then
		return value
	end
	return Copy.deepCopy(value)
end

-- ============================================================================
-- 公共 API
-- ============================================================================

--[[
	获取整个配置对象的深拷贝。只需单个键时用 GetValue，避免整表拷贝。

	@return table? - GameConfig 全表深拷贝（顶层含 版本号、DataStore、技能系统、怪物系统、战斗系统、Clock 等）；加载失败为 nil
]]
function SystemGameConfig.Get(): any?
	local config = _loadConfigData()
	if not config then
		return nil
	end
	return Copy.deepCopy(config)
end

--[[
	按路径取配置值。table 返回深拷贝，调用方可本地改，不影响 GameConfig。

	@param path string | {string} - 配置路径。字符串为顶层键（如 "版本号"）；字符串数组为嵌套键（如 {"每日签到", "每日签到最大天数"}）
	@return any? - nil 表示缺失或路径非法；boolean/number/string 原样返回；table 为深拷贝
]]
function SystemGameConfig.GetValue(path: string | { string }): any?
	local config = _loadConfigData()
	if not config then
		return nil
	end

	if type(path) == "string" then
		return _cloneConfigValue(config[path])
	end

	if type(path) == "table" then
		local current = config
		for _, key in ipairs(path) do
			if type(current) ~= "table" then
				return nil
			end
			current = current[key]
		end
		return _cloneConfigValue(current)
	end

	return nil
end

--[[
	清除本模块的配置指针。下次 Get / GetValue 会再读 Utils.GameConfig。
	不能热替换 GameConfig 源文件：Utils 与 require 仍缓存同一 ModuleScript 实例。
]]
function SystemGameConfig.ClearCache()
	_configData = nil
end

return SystemGameConfig
