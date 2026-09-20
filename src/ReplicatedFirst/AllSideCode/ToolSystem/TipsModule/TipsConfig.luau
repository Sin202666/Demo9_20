--[[
	Module: TipsConfig
	Description: 提示系统常量、模板与资源引用
	Author: 林奥宇
	Created: 2026-07-02
	Last Modified: 2026-09-01

	功能：
	- 展示时长、对象池路径、样式模板名等常量
	- STACK_COUNT_PREFIX：短时同内容合并时的次数前缀（如「 x」→「文案 x3」）
	- copyTemplate：深拷贝样式模板，避免调用方改写内部表
	- getPoolTemplate：解析并缓存 Tips 资源模板

	【引入】
	local TipsConfig = Utils.TipsConfig
	-- 或同目录：require(script.Parent.TipsConfig)

	【示例】
	local style = TipsConfig.copyTemplate(TipsConfig.TEMPLATE_ERROR)
	local bg = TipsConfig.getPoolTemplate(TipsConfig.POOL_BG_TEMP)
]]

-- ========================================
-- Requires
-- ========================================

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local ResourceUtil = Utils.ResourceUtil
local Copy = Utils.Copy
local ReplicatedStorage = Utils.ReplicatedStorage

-- ========================================
-- Module definition
-- ========================================

local TipsConfig = {}

-- ========================================
-- Constants
-- ========================================

local TEMPLATE_NORMAL = "通用提示"
local TEMPLATE_ERROR = "通用警告"

TipsConfig.MAX_SHOW_NUMBER = 12
TipsConfig.DISPLAY_DURATION = 3
-- 短时重复同内容 Tip：展示为「原文案」+ STACK_COUNT_PREFIX + 次数（仅 count>=2）
TipsConfig.STACK_COUNT_PREFIX = " x"
TipsConfig.TEMPLATE_NORMAL = TEMPLATE_NORMAL
TipsConfig.TEMPLATE_ERROR = TEMPLATE_ERROR
TipsConfig.TWEEN_SHOW_DURATION = 0.5
TipsConfig.TWEEN_TEXT_DURATION = 0.4
TipsConfig.TEXT_BOUNDS = Vector2.new(1920, 1080)
TipsConfig.POOL_BG_TEMP = "Tips/BGTemp"
TipsConfig.POOL_TEXT_TEMP = "Tips/TextTemp"
TipsConfig.SERVER_TEMPLATE_VEHICLE_FUSE = "载具合成"
TipsConfig.SERVER_TEMPLATE_REWARD = "获得奖励"
TipsConfig.SOUND_ERROR = "音效-UI-通用消极点击"

-- 模板 / 渲染共用样式常量（避免魔法字符串与字号散落）
TipsConfig.GRADIENT_TIP_WHITE = "提示白"
TipsConfig.GRADIENT_TIP_RED = "提示红"
TipsConfig.GRADIENT_YELLOW = "黄"
TipsConfig.TEXT_SIZE_TEMPLATE = 40
TipsConfig.TEXT_SIZE_OBTAIN = 35
TipsConfig.TEXT_SIZE_ITEM = 40
TipsConfig.TEXT_SIZE_DEFAULT = 20
TipsConfig.BG_HEIGHT_SCALE = 0.05
TipsConfig.BG_WIDTH_SCALE = 0.3
TipsConfig.LIST_PADDING_PX = 5
TipsConfig.DEFAULT_FONT = Enum.Font.MontserratBold
TipsConfig.STROKE_COLOR = Color3.new(0, 0, 0)
TipsConfig.DEFAULT_STROKE_THICKNESS = 2

-- ========================================
-- Private variables
-- ========================================

local _TIP_TEMPLATES: { [string]: { [string]: any } } = {
	[TEMPLATE_NORMAL] = {
		Text = "",
		TextSize = TipsConfig.TEXT_SIZE_TEMPLATE,
		Font = TipsConfig.DEFAULT_FONT,
		UIGradientString = TipsConfig.GRADIENT_TIP_WHITE,
		UIStorke = 0,
		UIStorkeTransparency = 0,
		UIStorkeColor = TipsConfig.STROKE_COLOR,
	},
	[TEMPLATE_ERROR] = {
		Text = "",
		TextSize = TipsConfig.TEXT_SIZE_TEMPLATE,
		Font = TipsConfig.DEFAULT_FONT,
		UIGradientString = TipsConfig.GRADIENT_TIP_RED,
		UIStorke = 0,
		UIStorkeTransparency = 0,
		UIStorkeColor = TipsConfig.STROKE_COLOR,
	},
}

local _assetCache: { [string]: Instance | false } = {}

-- ========================================
-- Private functions
-- ========================================

--[[
	解析 Tips 资源模板（ResourceUtil 优先，迁移期回退 Assets）
	@param relativePath string - 资源相对路径，如 Tips/BGTemp、Tips/TextTemp
	@return Instance? - 模板实例；路径无效时 nil
]]
local function _resolveTemplate(relativePath: string): Instance?
	local template = ResourceUtil.GetTemplate(relativePath)
	if template then
		return template
	end

	local assets = ReplicatedStorage:FindFirstChild("Assets")
	if not assets then
		return nil
	end

	local current: Instance = assets
	for _, segment in string.split(relativePath, "/") do
		if segment == "" then
			continue
		end
		local child = current:FindFirstChild(segment)
		if not child then
			return nil
		end
		current = child
	end

	return current
end

-- ========================================
-- Public API
-- ========================================

--[[
	获取对象池模板（带缓存，避免重复 FindFirstChild）
	@param relativePath string - 资源相对路径，见 POOL_BG_TEMP / POOL_TEXT_TEMP
	@return Instance? - 可克隆的池模板；未找到时 nil 并缓存失败标记
]]
function TipsConfig.getPoolTemplate(relativePath: string): Instance?
	if _assetCache[relativePath] ~= nil then
		local cached = _assetCache[relativePath]
		if cached == false then
			return nil
		end
		return cached
	end

	local template = _resolveTemplate(relativePath)
	_assetCache[relativePath] = template or false
	return template
end

--[[
	复制提示样式模板，避免修改内部 _TIP_TEMPLATES
	@param templateName string - 模板名，如 TEMPLATE_NORMAL、TEMPLATE_ERROR
	@return { [string]: any }? - 模板深拷贝表；名称不存在时 nil
]]
function TipsConfig.copyTemplate(templateName: string): { [string]: any }?
	local template = _TIP_TEMPLATES[templateName]
	if not template then
		return nil
	end

	return Copy.deepCopy(template)
end

return TipsConfig