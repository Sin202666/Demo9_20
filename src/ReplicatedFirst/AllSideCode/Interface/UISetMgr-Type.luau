local module = {}

export type RegisterOptions = {
	designSize: Vector2?,
	userScale: number?,
	adaptPopups: boolean?,
	syncTipsGui: boolean?,
	adaptStrokes: boolean?,
}

export type LayerRegisterOptions = {
	adaptStrokes: boolean?,
}

--[[
	注册 ScreenGui 自适应缩放（幂等：已注册则更新选项并立即刷新，不重复绑监听）
	@param screenGui ScreenGui - 目标 ScreenGui（需已有 UIScale 子节点）
	@param options RegisterOptions? - designSize / userScale / adaptPopups（弹窗 contain + Main 下一层 HUD 直写） / syncTipsGui / adaptStrokes
]]
function module.RegisterScreenGui(screenGui: ScreenGui, options: RegisterOptions?)
end

--[[
	注销 ScreenGui：断开监听并从注册表移除
	@param screenGui ScreenGui - 已注册的 ScreenGui
]]
function module.UnregisterScreenGui(screenGui: ScreenGui)
end

--[[
	注册 BillboardGui / SurfaceGui 的描边适配（幂等；不写 UIScale / Size / Adornee）
	@param gui LayerCollector - BillboardGui 或 SurfaceGui
	@param options LayerRegisterOptions? - adaptStrokes，默认 true
]]
function module.RegisterLayerCollector(gui: LayerCollector, options: LayerRegisterOptions?)
end

--[[
	注销 BillboardGui / SurfaceGui 描边适配
	@param gui LayerCollector - 已注册的世界空间 Gui
]]
function module.UnregisterLayerCollector(gui: LayerCollector)
end

--[[
	监听 PlayerGui，自动注册其中的 BillboardGui / SurfaceGui（幂等；不自动 ScreenGui）
	@param playerGui PlayerGui - 本地玩家 PlayerGui
]]
function module.WatchPlayerGui(playerGui: PlayerGui)
end

--[[
	监听 CollectionService 标签 StrokeAdapt，注册 BillboardGui / SurfaceGui（含 workspace；幂等）。标签可打在 Gui 自身、子节点或父级 Model/Part，不要打在 workspace 根或超大地图 Model 上。
]]
function module.WatchTaggedCollectors()
end

--[[
	强制刷新；gui 为 nil 时刷新全部已注册项。
	ScreenGui 立即写根 Scale / 弹窗 AdaptScale / HUD 直写 Scale；Thickness 异步分片，返回后不要立刻当最终值。
	@param gui LayerCollector? - 指定根；nil 表示全部
]]
function module.Refresh(gui: LayerCollector?)
end

--[[
	设置单个 ScreenGui 的用户倍率（乘在根 contain Scale 上）并立即刷新
	@param screenGui ScreenGui - 已注册的 ScreenGui
	@param userScale number - 用户倍率，通常 0~1 或 0.75~1
]]
function module.SetUserScale(screenGui: ScreenGui, userScale: number)
end

--[[
	查询已注册 ScreenGui 当前根 UIScale.Scale
	@param screenGui ScreenGui - 已注册的 ScreenGui
	@return number? - 根 Scale；未注册或无 UIScale 时 nil
]]
function module.GetRootScale(screenGui: ScreenGui): number?
end

--[[
	按祖先 UIScale 积更新 UIStroke 粗细；内部再乘屏幕档/设备倍率并钳下限。
	自动 Refresh 路径异步分片且已剔除窗口层（弹窗 AdaptScale 与 HUD 直写）；本函数本身同步写入（值未变则跳过）。
	@param obj UIStroke - 目标描边
	@param uiScale number - 祖先 UIScale 积（不要预乘设备倍率）；直接调用不会再乘 ViewportContain、也不会跳过窗口层
]]
function module.UpdateUIStroke(obj: UIStroke, uiScale: number)
end

return module
