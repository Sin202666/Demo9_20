local AddListen = {}

-- ============================================================================
-- AddListen 类型定义
-- 客户端 UI / Value 事件绑定：数值变化、鼠标点击、悬停、通行证显隐
-- ============================================================================

--[[
	监听 ValueBase 的 Value 变化（NumberValue / StringValue / BoolValue 等）
	注册时立即以当前 Value 回调一次，随后在 Changed 时回调。

	@param valueObject ValueBase - 任意带 Value/Changed 的值对象
	@param listen (value: any) -> () - 变化回调；参数类型随 ValueBase 子类变化
	@return RBXScriptConnection? - 变化监听连接；参数无效时返回 nil
]]
function AddListen.NumValueAdd(valueObject: ValueBase, listen: (value: any) -> ()): RBXScriptConnection?
end

--[[
	为 GuiButton 添加点击监听：Down 可选缩放动画，抬起（含指针已离开）还原，Click 播放音效并执行回调

	@param btn GuiButton - ImageButton 或 TextButton
	@param callback () -> () - 点击回调；在音效之后调用
	@param scaleBtn GuiObject? - 缩放目标；nil 时不播放按下/抬起动画
	@return {RBXScriptConnection} - Down/Up/Click 连接；传入 scaleBtn 时额外含 InputEnded；参数无效时返回空表
]]
function AddListen.AddMouseClick(btn: GuiButton, callback: () -> (), scaleBtn: GuiObject?): { RBXScriptConnection }
end

--[[
	AddMouseClick 的历史拼写别名，行为相同
	@param btn GuiButton - ImageButton 或 TextButton
	@param callback () -> () - 点击回调；在音效之后调用
	@param scaleBtn GuiObject? - 缩放目标；nil 时不播放按下/抬起动画
	@return {RBXScriptConnection} - Down/Up/Click 连接；传入 scaleBtn 时额外含 InputEnded；参数无效时返回空表
]]
function AddListen.AddMouseCLick(btn: GuiButton, callback: () -> (), scaleBtn: GuiObject?): { RBXScriptConnection }
end

--[[
	断开连接数组中的全部监听并清空表项
	@param connections {RBXScriptConnection}? - 连接对象数组；nil 或非表时直接返回
	@return nil - 无返回值
]]
function AddListen.DisconnectAll(connections: { RBXScriptConnection }?)
end

--[[
	移除鼠标点击监听（DisconnectAll 的语义别名）
	@param connections {RBXScriptConnection}? - AddMouseClick 返回的连接数组
	@return nil - 无返回值
]]
function AddListen.RemoveMouseClick(connections: { RBXScriptConnection }?)
end

--[[
	按玩家 GamePass 文件夹下的 NumberValue 切换 UI 可见性
	会 WaitForChild，最长 30 秒。

	@param plr Player - 玩家对象（通常为 LocalPlayer）
	@param frame GuiObject - 待切换 Visible 的节点
	@param tag string - GamePass 文件夹下 NumberValue 子节点名称
	@param isFade boolean - true：拥有（Value>=1）则显示；false：拥有则隐藏
	@return RBXScriptConnection? - 数值监听连接；失败时返回 nil
]]
function AddListen.EnableByGamePass(plr: Player, frame: GuiObject, tag: string, isFade: boolean): RBXScriptConnection?
end

--[[
	添加鼠标悬停监听（有鼠标用 Enter/Leave，触屏用 Down/Up/Leave）
	@param btn GuiButton - ImageButton 或 TextButton
	@param onEnter () -> () - 进入（或触屏按下）回调
	@param onLeave () -> () - 离开（或触屏抬起）回调
	@return {RBXScriptConnection} - 连接数组；参数无效时返回空表
]]
function AddListen.AddMouseHover(btn: GuiButton, onEnter: () -> (), onLeave: () -> ()): { RBXScriptConnection }
end

return AddListen
