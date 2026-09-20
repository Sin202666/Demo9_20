local module = {}

--[[
	创建并展示多段文本提示条
	@param tipData {any} - 有序文本段配置数组（Text、TextSize、Font、UIGradientString 等）
	@return nil - PlayerGui 或池模板不可用时静默 return
]]
function module.createTip(tipData: { any })
end

--[[
	套用 TipsConfig 模板创建单句提示
	@param text string - 展示文案（通常已翻译）
	@param templateName string - TipsConfig 模板名，如 TEMPLATE_NORMAL
	@return nil - 模板名不存在时静默 return
]]
function module.templateTip(text: string, templateName: string)
end

--[[
	根据服务端模板 Type 构建并展示提示
	@param data { [string]: any } - 须含 Type；载具合成 / 获得奖励均须 ID
	@return nil - Type 未知或字段缺失时静默 return
]]
function module.showFromServerTemplate(data: { [string]: any })
end

--[[
	释放客户端运行时状态并归还对象池
	@return nil - 可重复调用
]]
function module.destroy()
end

return module
