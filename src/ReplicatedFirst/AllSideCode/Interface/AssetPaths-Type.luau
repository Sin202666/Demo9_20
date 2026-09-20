--[[
	Module: AssetPaths-Type
	Description: AssetPaths 类型声明（完整使用说明见 ToolBasic/AssetPaths.luau 文件头）
	Author: 林奥宇
	Created: 2026-07-01
	Last Modified: 2026-08-31
]]

local AssetPaths = {}

AssetPaths.ASSETS_ROOT_NAME = "Assets"

-- 实现侧为 table.freeze，此处仅作类型桩
AssetPaths.Scope = {
	Shared = "Shared",
	Server = "Server",
	Auto = "Auto",
} :: {
	Shared: string,
	Server: string,
	Auto: string,
}

--[[
	获取 Assets 根目录（ReplicatedStorage.Assets 或 ServerStorage.Assets）
	@param scope string? - AssetPaths.Scope.Shared / Server / Auto，默认 Shared
	@return Folder? - Assets 根 Folder；不存在或客户端查 Server 时返回 nil
]]
function AssetPaths.GetAssetsRoot(scope: string?): Folder?
end

--[[
	获取一级 catalog 目录（如 ModelRes、UI）
	@param catalog string - 一级目录名；非字符串或空串返回 nil
	@param scope string? - AssetPaths.Scope.Shared / Server / Auto，默认 Shared
	@return Folder? - catalog 目录；不存在时返回 nil
]]
function AssetPaths.GetCatalog(catalog: string, scope: string?): Folder?
end

--[[
	按相对路径解析资源实例（路径以 catalog 开头，用 "/" 分段）
	@param relativePath string - 如 "ModelRes/Pet/Cat1"；非字符串或空串返回 nil
	@param scope string? - AssetPaths.Scope.Shared / Server / Auto，默认 Shared
	@return Instance? - 目标实例；路径无效或未找到时返回 nil
]]
function AssetPaths.Resolve(relativePath: string, scope: string?): Instance?
end

--[[
	清除路径查找缓存（不影响已 Clone 实例，不重置非法 scope 警告标记）
	@return () - 无返回值
]]
function AssetPaths.ClearCache()
end

return AssetPaths
