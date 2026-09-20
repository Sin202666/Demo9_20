local module = {}

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

export type ModelTypeEnum = {
	Anime: number,
	Enemy: number,
	Weapon: number,
	Pet: number,
	Effect: number,
	PetEgg: number,
}

module.Catalog = {} :: CatalogEnum
module.ModelCategory = {} :: ModelCategoryEnum
module.ModelType = {} :: ModelTypeEnum

function module.GetModelCategoryByType(modelType: number): string?
end

function module.BuildCatalogPath(catalog: string, relativePath: string): string
end

function module.BuildModelPath(category: string, assetName: string): string
end

function module.BuildUIPath(relativePath: string): string
end

return module
