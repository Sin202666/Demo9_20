--[[
	Module: AssetAcquire-Type
	Description: AssetAcquire 类型声明（完整使用说明见 ToolSystem/AssetAcquire.luau 文件头）
	Author: 林奥宇
	Created: 2026-07-01
	Last Modified: 2026-09-01
]]

local AssetAcquire = {}

export type AcquireOptions = {
	scope: string?,
	clone: boolean?,
	restore: boolean?,
	usePool: boolean?,
	poolTemplate: Instance?,
}

-- 实现侧复用 AssetPaths.Scope（table.freeze），此处仅作类型桩
AssetAcquire.Scope = {
	Shared = "Shared",
	Server = "Server",
	Auto = "Auto",
} :: {
	Shared: string,
	Server: string,
	Auto: string,
}

--[[
	通用资源获取（usePool > clone=false > Clone + 可选 Restore）
	@param relativePath string - 相对路径，如 "ModelRes/Pet/Cat1"；非 string 或空串返回 nil
	@param options AcquireOptions? - 获取选项；scope 为 Shared / Server / Auto，nil 时用默认
	@return Instance? - 实例；路径无效、未找到或 Clone/借池失败时 nil
]]
function AssetAcquire.Get(relativePath: string, options: AcquireOptions?): Instance?
end

--[[
	获取 ModelRes 下的模型；先校验模板 IsA("Model") 再 Clone / 借池
	@param category string - 子目录，如 Pet / Effect；非 string 或空串返回 nil
	@param modelName string - 模型名；非 string 或空串返回 nil
	@param options AcquireOptions? - 获取选项；scope 为 Shared / Server / Auto，nil 时用默认
	@return Model? - 模型实例；路径无效、未找到、模板非 Model 或 Clone/借池失败时 nil
]]
function AssetAcquire.GetModel(category: string, modelName: string, options: AcquireOptions?): Model?
end

--[[
	获取 UI 目录下资源
	@param relativePath string - UI 子路径，如 "Tips/BGTemp"；非 string 或空串返回 nil
	@param options AcquireOptions? - 获取选项；scope 为 Shared / Server / Auto，nil 时用默认
	@return Instance? - UI 实例；路径无效、未找到或 Clone/借池失败时 nil
]]
function AssetAcquire.GetUI(relativePath: string, options: AcquireOptions?): Instance?
end

--[[
	获取资源模板引用（不 Clone、不 Restore）
	@param relativePath string - 相对路径；非 string 或空串返回 nil
	@param scope string? - Shared / Server / Auto，默认 Shared
	@return Instance? - 模板实例（DataModel 活引用）；路径无效或未找到时 nil
]]
function AssetAcquire.GetTemplate(relativePath: string, scope: string?): Instance?
end

return AssetAcquire