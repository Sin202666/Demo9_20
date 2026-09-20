--!strict
--[[
	Module: AssetRegistry
	Description: 资源 catalog 与 ModelRes 子分类的配置表，并提供相对路径字符串拼接
	Author: 中台组
	Created: 2026-07-01
	Last Modified: 2026-08-27

	功能：
	- 定义 Assets 下一级 catalog 名称（Catalog）
	- 定义 ModelRes 下模型子目录名（ModelCategory）
	- 兼容 legacy ModelType 数值枚举（1–6）
	- 拼接 AssetPaths.Resolve 所需的相对路径字符串

	------------------------------------------------------------------------
	目录约定
	------------------------------------------------------------------------
	物理路径（由 AssetPaths 解析）：
		ReplicatedStorage/Assets/{catalog}/{子路径...}
		ServerStorage/Assets/{catalog}/{子路径...}

	相对路径格式（本模块产出、AssetPaths 入参）：
		"{catalog}/{子路径...}"
		示例："ModelRes/Pet/Cat1"、"UI/Tips/BGTemp"、"Hatch/BoxModel"

	------------------------------------------------------------------------
	Catalog / ModelCategory / ModelType 区别
	------------------------------------------------------------------------
	Catalog       — Assets 下一级目录名，如 ModelRes、UI、Hatch、Tips
	ModelCategory — ModelRes 下的子目录名，如 Pet、Effect、Skill
	ModelType     — legacy 数值枚举（1–6），供旧配置表兼容；
	                仅覆盖 Anime~PetEgg，不含 Skill

	ModelCategory.Skill 无对应 ModelType；请直接用 ModelCategory.Skill
	配合 BuildModelPath，勿经 GetModelCategoryByType。

	------------------------------------------------------------------------
	何时使用本模块
	------------------------------------------------------------------------
	需要 catalog / 分类常量           → AssetRegistry.Catalog / ModelCategory
	需要拼相对路径字符串              → BuildCatalogPath / BuildModelPath / BuildUIPath
	需要定位 Instance、Clone、遍历目录 → 用 AssetPaths（或 ResourceUtil / AssetAcquire）

	加载方式：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local AssetRegistry = Utils.AssetRegistry
		local Cat = AssetRegistry.Catalog
		local ModelCat = AssetRegistry.ModelCategory

	------------------------------------------------------------------------
	使用示例
	------------------------------------------------------------------------
	-- 拼 ModelRes 模型路径（交给 AssetPaths 解析）
	local petPath = AssetRegistry.BuildModelPath(ModelCat.Pet, "Cat1")
	-- 结果："ModelRes/Pet/Cat1"
	local petTemplate = Utils.AssetPaths.Resolve(petPath)

	-- 拼 UI 路径
	local tipsPath = AssetRegistry.BuildUIPath("Tips/BGTemp")
	-- 结果："UI/Tips/BGTemp"

	-- 拼任意 catalog 路径（Hatch、Sequence、Tips 等）
	local hatchPath = AssetRegistry.BuildCatalogPath(Cat.Hatch, "BoxModel")

	-- legacy ModelType 数值 → 子目录名
	local category = AssetRegistry.GetModelCategoryByType(AssetRegistry.ModelType.Pet)
	-- 结果："Pet"；无效 modelType 返回 nil

	-- Skill 模型（无 legacy ModelType）
	local skillPath = AssetRegistry.BuildModelPath(ModelCat.Skill, "FireBall")

	------------------------------------------------------------------------
	与 AssetPaths 的关系
	------------------------------------------------------------------------
	AssetRegistry 只产出字符串常量，不访问 ReplicatedStorage / ServerStorage。
	完整迁移说明见 docs/ASSETS_MIGRATION.md
]]

local AssetRegistry = {}

-- ============================================================================
-- 常量定义
-- ============================================================================

AssetRegistry.Catalog = table.freeze({
	ModelRes = "ModelRes",
	UI = "UI",
	Sequence = "Sequence",
	Hatch = "Hatch",
	BUFF = "BUFF",
	UIanima = "UIanima",
	LightingConfig = "LightingConfig",
	LightingStates = "LightingStates",
	Tips = "Tips",
	AllGridients = "AllGridients",
})

AssetRegistry.ModelCategory = table.freeze({
	Anime = "Anime",
	Enemy = "Enemy",
	Weapon = "Weapon",
	Pet = "Pet",
	Effect = "Effect",
	PetEgg = "PetEgg",
	Skill = "Skill", -- 无 legacy ModelType，请直接用 BuildModelPath
	Mount = "Mount", -- 无 legacy ModelType，请直接用 BuildModelPath
})

-- legacy ModelType 数值枚举（1–6）；Skill 不在此列
AssetRegistry.ModelType = table.freeze({
	Anime = 1,
	Enemy = 2,
	Weapon = 3,
	Pet = 4,
	Effect = 5,
	PetEgg = 6,
})

-- ============================================================================
-- 私有变量
-- ============================================================================

local MODEL_TYPE_TO_CATEGORY: { [number]: string } = {
	[AssetRegistry.ModelType.Anime] = AssetRegistry.ModelCategory.Anime,
	[AssetRegistry.ModelType.Enemy] = AssetRegistry.ModelCategory.Enemy,
	[AssetRegistry.ModelType.Weapon] = AssetRegistry.ModelCategory.Weapon,
	[AssetRegistry.ModelType.Pet] = AssetRegistry.ModelCategory.Pet,
	[AssetRegistry.ModelType.Effect] = AssetRegistry.ModelCategory.Effect,
	[AssetRegistry.ModelType.PetEgg] = AssetRegistry.ModelCategory.PetEgg,
}

-- ============================================================================
-- 公共 API
-- ============================================================================

--[[
	由 legacy ModelType 数值获取 ModelRes 子目录名
	@param modelType number - ModelType 枚举（1=Anime, 2=Enemy, 3=Weapon, 4=Pet, 5=Effect, 6=PetEgg）；未知值返回 nil
	@return string? - ModelCategory 子目录名，如 "Pet"
]]
function AssetRegistry.GetModelCategoryByType(modelType: number): string?
	return MODEL_TYPE_TO_CATEGORY[modelType]
end

--[[
	构建任意 catalog 下的相对路径
	@param catalog string - 一级 catalog，通常取 AssetRegistry.Catalog 中的值
	@param relativePath string - catalog 下的子路径，如 "Tips/BGTemp" 或 "Pet/Cat1"
	@return string - 如 "UI/Tips/BGTemp"、"Hatch/BoxModel"
]]
function AssetRegistry.BuildCatalogPath(catalog: string, relativePath: string): string
	return catalog .. "/" .. relativePath
end

--[[
	构建 ModelRes 下模型的相对路径
	@param category string - 模型分类目录，通常取 AssetRegistry.ModelCategory 中的值
	@param assetName string - 资源名称（ModelRes 子目录下的 Instance 名）
	@return string - 如 "ModelRes/Pet/Cat1"
]]
function AssetRegistry.BuildModelPath(category: string, assetName: string): string
	return AssetRegistry.BuildCatalogPath(AssetRegistry.Catalog.ModelRes, category .. "/" .. assetName)
end

--[[
	构建 UI 相对路径
	@param relativePath string - UI 子路径，如 "Tips/BGTemp"
	@return string - 如 "UI/Tips/BGTemp"
]]
function AssetRegistry.BuildUIPath(relativePath: string): string
	return AssetRegistry.BuildCatalogPath(AssetRegistry.Catalog.UI, relativePath)
end

return AssetRegistry
