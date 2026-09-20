--[[
	Module: LocoStyleSets
	Description: LocoStyle 动画集配置：styleId → 逻辑槽 → Animation 逻辑名；缺槽回退 Default。
	Author: 林奥宇
	Created: 2026-08-05
	Last Modified: 2026-08-28

	能力：
	- 定义全套 loco 槽位（与 Animate BaseAnimation / BasePos 对齐）
	- Default：映射到 AnimationModule/Animation.luau 现有逻辑名
	- 示例风格 Heavy：当前无独立资源时缺槽回退 Default（切换路径可验收）
	- ResolveAnimName / ListAnimNamesForStyle / HasStyle 供 LocoStyle 热换与预热

	与 LocoStyle：
	- 本表只提供资源映射，不播轨、不持有角色状态
	- 业务 Driver 只 Push/Set styleId；勿直接改本表运行时内容

	标准加载：
	local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
	local LocoStyleSets = Utils.LocoStyleSets
	local name = LocoStyleSets.ResolveAnimName("Heavy", "Idle")

	示例：
	1) 查 Idle 资源名：LocoStyleSets.ResolveAnimName("Default", "Idle") → "Idle"
	2) 预热列表：LocoStyleSets.ListAnimNamesForStyle("Heavy")
	3) 扩展风格：在 Styles 增加 styleId，只填需覆盖的槽；其余自动 Fallback Default
]]

local LocoStyleSets = {}

-- 缺省 / 回退风格 ID
LocoStyleSets.DEFAULT_STYLE_ID = "Default"

--[[
	BasePos 槽 → Animation.luau 逻辑名（Default 全集）
	键名须与 Animate:bindBaseAction 槽一致。
]]
local DEFAULT_SLOT_ANIMS: { [string]: string } = {
	Walk = "WalkForward",
	Walk_Left = "WalkLeft",
	Walk_Right = "WalkRight",
	Walk_Back = "WalkBack",
	Run = "RunForward",
	Run_Left = "RunLeft",
	Run_Right = "RunRight",
	Run_Back = "RunBack",
	Swim = "Swim",
	SwimIdle = "SwimIdle",
	Idle = "Idle",
	StartRun = "StartRun",
	StopRun = "StopRun",
	StartWalk = "StartWalk",
	StopWalk = "StopWalk",
	Jump = "Jump",
	Fall = "Fall",
	Land = "Land",
	LightLand = "LightLand",
	Climb = "Climb",
}

--[[
	风格覆盖表：styleId → { 槽 → 逻辑名 }
	未列出的槽回退 Default；Heavy 为空表表示整集 Fallback（占位验收）。
	新增真实资源时：在 Animation.luau 登记逻辑名，再在此填覆盖即可。
]]
local Styles: { [string]: { [string]: string } } = {
	Default = DEFAULT_SLOT_ANIMS,
	Heavy = {
		-- 示例：Idle = "Heavy_Idle",
	},
}

-- ========================================
-- 槽序（只读）
-- ========================================

LocoStyleSets.SLOT_ORDER = table.freeze({
	"Walk",
	"Walk_Left",
	"Walk_Right",
	"Walk_Back",
	"Run",
	"Run_Left",
	"Run_Right",
	"Run_Back",
	"Swim",
	"SwimIdle",
	"Idle",
	"StartRun",
	"StopRun",
	"StartWalk",
	"StopWalk",
	"Jump",
	"Fall",
	"Land",
	"LightLand",
	"Climb",
})

-- ========================================
-- 查询 API
-- ========================================

--[[
	是否已注册风格（含仅 Fallback、无覆盖的风格）
	@param styleId string - 风格 ID
	@return boolean - 已注册为 true
]]
function LocoStyleSets.HasStyle(styleId: string): boolean
	if type(styleId) ~= "string" or styleId == "" then
		return false
	end
	return Styles[styleId] ~= nil
end

--[[
	解析风格在指定槽的 Animation 逻辑名（缺槽 / 未知风格回退 Default）
	@param styleId string - 风格 ID；未知时按 Default
	@param slot string - BasePos 槽名（如 Idle、Walk、Run_Left）
	@return string? - Animation.luau 逻辑名；槽非法时 nil
]]
function LocoStyleSets.ResolveAnimName(styleId: string, slot: string): string?
	if type(slot) ~= "string" or slot == "" then
		return nil
	end
	local defaultName = DEFAULT_SLOT_ANIMS[slot]
	if not defaultName then
		return nil
	end

	local resolvedStyle = styleId
	if type(resolvedStyle) ~= "string" or resolvedStyle == "" or Styles[resolvedStyle] == nil then
		resolvedStyle = LocoStyleSets.DEFAULT_STYLE_ID
	end

	local overrides = Styles[resolvedStyle]
	if overrides then
		local overrideName = overrides[slot]
		if type(overrideName) == "string" and overrideName ~= "" then
			return overrideName
		end
	end

	return defaultName
end

--[[
	列出风格全部槽解析后的逻辑名（去重，顺序稳定），供预热
	@param styleId string - 风格 ID
	@return { string } - 逻辑名列表
]]
function LocoStyleSets.ListAnimNamesForStyle(styleId: string): { string }
	local names: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, slot in ipairs(LocoStyleSets.SLOT_ORDER) do
		local animName = LocoStyleSets.ResolveAnimName(styleId, slot)
		if animName and not seen[animName] then
			seen[animName] = true
			table.insert(names, animName)
		end
	end
	return names
end

--[[
	只读：Default 槽映射表的浅拷贝（勿依赖可变引用）
	@return { [string]: string } - 槽 → 逻辑名
]]
function LocoStyleSets.GetDefaultSlotAnims(): { [string]: string }
	local copy: { [string]: string } = {}
	for slot, animName in pairs(DEFAULT_SLOT_ANIMS) do
		copy[slot] = animName
	end
	return copy
end

return LocoStyleSets