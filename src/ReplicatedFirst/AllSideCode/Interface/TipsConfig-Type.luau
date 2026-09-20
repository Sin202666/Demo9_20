local module = {}

module.MAX_SHOW_NUMBER = 12
module.DISPLAY_DURATION = 3
module.STACK_COUNT_PREFIX = " x"
module.TEMPLATE_NORMAL = "通用提示"
module.TEMPLATE_ERROR = "通用警告"
module.TWEEN_SHOW_DURATION = 0.5
module.TWEEN_TEXT_DURATION = 0.4
module.TEXT_BOUNDS = Vector2.new(1920, 1080)
module.POOL_BG_TEMP = "Tips/BGTemp"
module.POOL_TEXT_TEMP = "Tips/TextTemp"
module.SERVER_TEMPLATE_VEHICLE_FUSE = "载具合成"
module.SERVER_TEMPLATE_REWARD = "获得奖励"
module.SOUND_ERROR = "音效-UI-通用消极点击"
module.GRADIENT_TIP_WHITE = "提示白"
module.GRADIENT_TIP_RED = "提示红"
module.GRADIENT_YELLOW = "黄"
module.TEXT_SIZE_TEMPLATE = 40
module.TEXT_SIZE_OBTAIN = 35
module.TEXT_SIZE_ITEM = 40
module.TEXT_SIZE_DEFAULT = 20
module.BG_HEIGHT_SCALE = 0.05
module.BG_WIDTH_SCALE = 0.3
module.LIST_PADDING_PX = 5
module.DEFAULT_FONT = Enum.Font.MontserratBold
module.STROKE_COLOR = Color3.new(0, 0, 0)
module.DEFAULT_STROKE_THICKNESS = 2

--[[
	获取对象池模板（带缓存）
	@param relativePath string - 资源相对路径，如 Tips/BGTemp
	@return Instance? - 池模板实例；未找到时 nil
]]
function module.getPoolTemplate(relativePath: string): Instance?
end

--[[
	复制提示样式模板
	@param templateName string - TipsConfig 模板名
	@return { [string]: any }? - 模板深拷贝；名称不存在时 nil
]]
function module.copyTemplate(templateName: string): { [string]: any }?
end

return module
