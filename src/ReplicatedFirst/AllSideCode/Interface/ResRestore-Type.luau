--[[
	Module: ResRestore-Type
	Description: ResRestore 模块类型定义，供 Interface 代码补全与类型检查
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-08-31
]]

local module = {}

--[[
	恢复模型中已保存的资源 ID
	支持 Model 及其后代、以及 Sound 实例
	@param instance Model | Sound - 要恢复的模型或音频
	@return nil - 无返回值
]]
function module.Restore(instance: Model | Sound)
end

--[[
	按需恢复实例上的延迟加载资源（Model / Sound）
	@param instance Instance - 模型或音频实例
	@return nil - 无返回值
]]
function module.PrepareInstance(instance: Instance)
end

--[[
	暂时卸载模型的贴图资源，将资源 ID 保存到 Attribute
	@param model Model - 要处理的模型
	@return nil - 无返回值
]]
function module.ClearAssert(model: Model)
end

--[[
	暂时卸载 Sound 的音频资源，将 SoundId 保存到 Attribute
	container 本身是 Sound 时处理该实例；否则处理其全体 Sound 后代
	@param container Instance - Sound 自身，或包含 Sound 的容器（Folder、Model 等）
	@return nil - 无返回值
]]
function module.ClearAssertSound(container: Instance)
end

--[[
	预加载指定资源 ID 列表
	@param assetIds { string } - 资源 ID 数组（rbxassetid://...）
	@return nil - 无返回值
]]
function module.PreloadAssets(assetIds: { string })
end

--[[
	PreloadAssets 的历史缩写别名，签名与语义相同
	@param assetIds { string } - 资源 ID 数组（rbxassetid://...）
	@return nil - 无返回值
]]
function module.PreloadAss(assetIds: { string })
end

--[[
	预加载动作资源
	@param animationIds { string } - 动作 ID 数组（rbxassetid://...）
	@return nil - 无返回值
]]
function module.PreloadAnimation(animationIds: { string })
end

--[[
	异步预加载模型：先 Restore 再 PreloadAsync
	@param model Model - 要预加载的模型实例
	@param onSuccess (() -> ())? - 预加载成功后的回调
	@return nil - 无返回值
]]
function module.DeferPreloadModel(model: Model, onSuccess: (() -> ())?)
end

--[[
	异步预加载动作 ID
	@param animIdStr string - rbxassetid:// 格式的动作 ID
	@param onSuccess (() -> ())? - 预加载成功后的回调
	@return nil - 无返回值
]]
function module.DeferPreloadAnimationId(animIdStr: string, onSuccess: (() -> ())?)
end

--[[
	异步预加载音频：先 Restore 再 PreloadAsync
	@param sound Sound - 要预加载的音频实例
	@param onSuccess (() -> ())? - 预加载成功后的回调
	@return nil - 无返回值
]]
function module.DeferPreloadSound(sound: Sound, onSuccess: (() -> ())?)
end

return module
