--[[
	Module: ResourceUtil-Type
	Description: ResourceUtil 类型声明（完整使用说明见 ToolSystem/ResourceUtil.luau 文件头）
	Author: 林奥宇
	Created: 2026-07-01
	Last Modified: 2026-09-01
]]

local ResourceUtil = {}

export type AcquireOptions = {
	scope: string?,
	clone: boolean?,
	restore: boolean?,
	usePool: boolean?,
	poolTemplate: Instance?,
}

export type ModelTypeEnum = {
	Anime: number,
	Enemy: number,
	Weapon: number,
	Pet: number,
	Effect: number,
	PetEgg: number,
}

export type ModelCategoryEnum = {
	Anime: string,
	Enemy: string,
	Weapon: string,
	Pet: string,
	Effect: string,
	PetEgg: string,
	Skill: string,
	Mount: string,
}

export type CatalogEnum = {
	ModelRes: string,
	UI: string,
	Sequence: string,
	Hatch: string,
	BUFF: string,
	UIanima: string,
	LightingConfig: string,
	LightingStates: string,
	Tips: string,
	AllGridients: string,
}

-- 实现侧复用 AssetRegistry / AssetPaths 的 freeze 表，此处仅作类型桩
ResourceUtil.ModelType = {} :: ModelTypeEnum
ResourceUtil.ModelCategory = {} :: ModelCategoryEnum
ResourceUtil.Catalog = {} :: CatalogEnum
ResourceUtil.Scope = {
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
function ResourceUtil.Get(relativePath: string, options: AcquireOptions?): Instance?
end

--[[
	从 ModelRes 获取模型；先校验模板 IsA("Model") 再 Clone / 借池
	@param category string - ModelCategory，如 Pet / Effect / Mount；非 string 或空串返回 nil
	@param modelName string - 模型名称；非 string 或空串返回 nil
	@param options AcquireOptions? - 获取选项；scope 为 Shared / Server / Auto，nil 时用默认
	@return Model? - 模型；路径无效、未找到、模板非 Model 或 Clone/借池失败时 nil
]]
function ResourceUtil.GetModel(category: string, modelName: string, options: AcquireOptions?): Model?
end

--[[
	从 UI catalog 获取资源
	@param relativePath string - UI 子路径，如 "Tips/BGTemp"；非 string 或空串返回 nil
	@param options AcquireOptions? - 获取选项；scope 为 Shared / Server / Auto，nil 时用默认
	@return Instance? - UI 实例；路径无效、未找到或 Clone/借池失败时 nil
]]
function ResourceUtil.GetUI(relativePath: string, options: AcquireOptions?): Instance?
end

--[[
	从 ServerStorage.Assets 获取 UI 并 Clone + Restore；客户端恒 nil
	@param relativePath string - 如 "排行榜/RankTemp"；非 string 或空串返回 nil
	@return Instance? - UI 克隆；客户端、路径无效或 Clone 失败时 nil
]]
function ResourceUtil.GetServerUI(relativePath: string): Instance?
end

--[[
	获取资源模板引用（不 Clone、不 Restore）
	@param relativePath string - 相对路径；非 string 或空串返回 nil
	@param scope string? - Shared / Server / Auto，默认 Shared
	@return Instance? - DataModel 模板活引用；路径无效或未找到时 nil
]]
function ResourceUtil.GetTemplate(relativePath: string, scope: string?): Instance?
end

--[[
	从对象池借出实例；池键为 template.Name；成功时 Parent=workspace
	@param template Instance - 对象模板（以其 Name 作为池键）
	@return Instance? - 借出实例；模板非法、Name 为空或 Clone 失败时 nil
]]
function ResourceUtil.GetPooledInstance(template: Instance): Instance?
end

--[[
	将实例归还对象池；无 ModelName 则销毁；已在池内则幂等
	@param instance Instance - 要归还的借出实例
	@return boolean, string? - 成功 true；失败 false 与 ObjectPoolUtil.Err.INVALID_INSTANCE / NOT_POOLED
]]
function ResourceUtil.BackToPool(instance: Instance): (boolean, string?)
end

--[[
	预加载基础技能资源
	@param baseSkillName string - 基础技能 ModuleScript 名称
	@return () - 无返回值；会话内同名只预热一次
]]
function ResourceUtil.PreloadBaseSkill(baseSkillName: string)
end

--[[
	预加载组技能资源
	@param skillName string - 组技能 ModuleScript 名称
	@return () - 无返回值；会话内同名只预热一次
]]
function ResourceUtil.PreloadSkill(skillName: string)
end

--[[
	预加载动作资源（按动作名称）
	@param animationNames { string } - 动作名称数组；空项跳过
	@return () - 无返回值
]]
function ResourceUtil.PreloadAnimations(animationNames: { string })
end

--[[
	预加载音频资源（按音频名称）
	@param soundNames { string } - 音频名称数组（SoundService 中 Sound.Name）；空项跳过
	@return () - 无返回值
]]
function ResourceUtil.PreloadSounds(soundNames: { string })
end

return ResourceUtil
