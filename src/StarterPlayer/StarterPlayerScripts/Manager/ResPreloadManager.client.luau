--[[
	Module: ResPreloadManager
	Description: 客户端资源预加载管理器，启动后异步预热通用动画与配置技能
	Author: 中台组 林奥宇
	Created: 2026-07-02
	Last Modified: 2026-07-31

	功能：
	- 启动时 defer 预热 AnimationModule.GetPreloadTable 中的通用动画
	- 按 SKILL_PRELOAD_LIST 预热组技能相关资源（模型/动画/特效等）
	- 启用冲刺时额外预热 SpeedLineFX（Assets/Sequence/加速线）

	配置：
	- SKILL_PRELOAD_LIST：进入场景前需预热的组技能名称列表，可按项目追加

	依赖：
	- Utils.AnimationModule：GetPreloadTable 读取预加载动画 ID 表
	- Utils.ResRestore：PreloadAnimation 批量预热动画
	- Utils.ResourceUtil：PreloadSkill 门面，内部走 SkillPreloadUtil
	- Utils.SpeedLineFX：冲刺全屏加速线序列预载

	说明：
	- 业务侧临时预热请直接调用 ResourceUtil.PreloadSkill / PreloadAnimations
	- 本 Manager 仅负责启动阶段通用资源，不阻塞其他 Manager 初始化

	示例（追加启动预热技能）：
	```lua
	local SKILL_PRELOAD_LIST: { string } = {
		"Meteor",
		"Tornado",
	}
	```
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local AnimationModule = Utils.AnimationModule
local ResRestore = Utils.ResRestore
local ResourceUtil = Utils.ResourceUtil
local SystemGameConfig = Utils.SystemGameConfig
local SpeedLineFX = Utils.SpeedLineFX

-- ========================================
-- 常量
-- ========================================
-- 可按项目需要追加组技能名称，进入场景前预热
local SKILL_PRELOAD_LIST: { string } = {}
local PRELOAD_SPEED_LINE: boolean = false
if SystemGameConfig.GetValue({ "技能系统", "启用" }) ~= false then
	if SystemGameConfig.GetValue({ "技能系统", "启用冲刺技能" }) ~= false then
		table.insert(SKILL_PRELOAD_LIST, "NewRoll")
		PRELOAD_SPEED_LINE = true
	end
	table.insert(SKILL_PRELOAD_LIST, "SkillDemoCast")
	table.insert(SKILL_PRELOAD_LIST, "Meteor")
	table.insert(SKILL_PRELOAD_LIST, "SpaceSkill")
end

-- ========================================
-- 私有函数
-- ========================================

--[[
	预热 AnimationModule 配置表中的通用动画
	@return nil - 无返回值；无待预热 ID 时直接返回
]]
local function _preloadAnimations()
	local animationIds = AnimationModule.GetPreloadTable()
	if #animationIds == 0 then
		return
	end
	ResRestore.PreloadAnimation(animationIds)
end

--[[
	预热 SKILL_PRELOAD_LIST 中配置的组技能资源
	@return nil - 无返回值；跳过空字符串与非 string 项
]]
local function _preloadConfiguredSkills()
	for _, skillName in SKILL_PRELOAD_LIST do
		if type(skillName) == "string" and skillName ~= "" then
			ResourceUtil.PreloadSkill(skillName)
		end
	end
end

--[[
	预热冲刺全屏加速线序列（与 NewRoll 同开关）
	@return nil - 无返回值
]]
local function _preloadSpeedLine()
	if not PRELOAD_SPEED_LINE then
		return
	end
	SpeedLineFX.Preload()
end

-- ========================================
-- 初始化
-- ========================================
task.defer(function()
	_preloadAnimations()
	_preloadConfiguredSkills()
	_preloadSpeedLine()
end)
