--!strict
--[[
	Module: ResourceUtil
	Description: 业务资源门面（获取 / 对象池 / 技能预加载），统一委托 AssetAcquire、ObjectPoolUtil、SkillPreloadUtil
	Author: 林奥宇
	Created: 2026-07-01
	Last Modified: 2026-09-01

	功能：
	- 按相对路径或 Model/UI 分类获取资源（默认 Clone + Restore）
	- 服务端 UI 快捷入口 GetServerUI（Scope.Server + Clone + Restore）
	- 对象池借出 / 归还
	- 技能 / 动作 / 音频预加载
	- 再导出 Catalog / ModelCategory / ModelType / Scope（与源表同一 freeze 引用）

	------------------------------------------------------------------------
	与相关模块的关系
	------------------------------------------------------------------------
	ResourceUtil     — 业务首选门面（本模块）
	AssetAcquire     — 路径解析 + Clone / Restore / 对象池借出；需精细 options 时用
	AssetPaths       — 只 Resolve 模板，不 Clone
	AssetRegistry    — catalog / 分类常量与路径拼接
	ObjectPoolUtil   — 池实现；归还错误码见 ObjectPoolUtil.Err
	SkillPreloadUtil — 技能配置解析与预热编排

	推荐：业务侧优先 Utils.ResourceUtil；底层集成或自定义 AcquireOptions 时用 AssetAcquire。

	------------------------------------------------------------------------
	Scope（ResourceUtil.Scope = AssetPaths.Scope，已 freeze）
	------------------------------------------------------------------------
	Shared（默认）— 查 ReplicatedStorage，双端可见资源
	Server         — 查 ServerStorage；客户端调用恒 nil
	Auto           — 服务端先 SS 后 RS；客户端等同 Shared

	------------------------------------------------------------------------
	AcquireOptions（与 AssetAcquire 相同；均为可选）
	------------------------------------------------------------------------
		scope        string?    — Shared / Server / Auto，默认 Shared
		clone        boolean?   — 是否 Clone，默认 true
		restore      boolean?   — Clone 后 ResRestore，默认 true
		usePool      boolean?   — 从对象池借出，默认 false
		poolTemplate Instance?  — 池模板；省略时用 Resolve 结果

	Get 分支优先级（互斥，由 AssetAcquire 处理）：
		1. usePool=true  → 对象池借出（池内 Restore，忽略 restore）
		2. clone=false   → 返回模板活引用，不 Clone
		3. 默认          → Clone + 可选 Restore

	------------------------------------------------------------------------
	公共 API
	------------------------------------------------------------------------
	Get / GetModel / GetUI / GetTemplate — 委托 AssetAcquire
	GetServerUI                          — 仅本门面：Server scope + Clone + Restore
	GetPooledInstance / BackToPool       — 委托 ObjectPoolUtil
	PreloadBaseSkill / PreloadSkill /
	PreloadAnimations / PreloadSounds    — 委托 SkillPreloadUtil

	------------------------------------------------------------------------
	加载方式
	------------------------------------------------------------------------
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local ResourceUtil = Utils.ResourceUtil
		local Cat = ResourceUtil.ModelCategory

	------------------------------------------------------------------------
	使用示例
	------------------------------------------------------------------------
	-- 【模型】ModelRes/{category}/{name}，默认 Clone + Restore
	local pet = ResourceUtil.GetModel(Cat.Pet, "Cat1")
	local mount = ResourceUtil.GetModel(Cat.Mount, "Horse1")

	-- 【UI】双端 / 仅服务端
	local bg = ResourceUtil.GetUI("Tips/BGTemp")
	local rankTemp = ResourceUtil.GetServerUI("排行榜/RankTemp") -- 客户端恒 nil

	-- 【任意 catalog】
	local hatch = ResourceUtil.Get("Hatch/BoxModel")

	-- 【仅模板】不 Clone，可作对象池键
	local template = ResourceUtil.GetTemplate("UI/Tips/BGTemp")

	-- 【对象池】借出后须归还，勿 Destroy 池实例
	local pooled = ResourceUtil.GetPooledInstance(template)
	local ok, err = ResourceUtil.BackToPool(pooled)
	-- err 为 ObjectPoolUtil.Err.INVALID_INSTANCE / NOT_POOLED

	-- 【预加载】
	ResourceUtil.PreloadSkill("Meteor")
	ResourceUtil.PreloadAnimations({ "魔法弹1" })

	------------------------------------------------------------------------
	返回值与注意事项
	------------------------------------------------------------------------
	- 路径 / 分类 / 名为空或非 string → nil（由 AssetAcquire 守卫）
	- 未找到、Clone/借池失败 → nil，不抛错
	- GetModel 模板非 Model → nil（AssetAcquire 会弃置误借出实例）
	- GetTemplate / clone=false 返回 DataModel 模板活引用，不是配置拷贝
	- Catalog / ModelCategory / ModelType / Scope 为 freeze 表的同一引用，勿当可写配置
	- 特效归还前需停粒子 → FXUtil.BackPool_Instance / ReturnPooledModelToPool
	- 完整目录约定见 AssetPaths / AssetRegistry 文件头与 docs/ASSETS_MIGRATION.md
]]

-- ============================================================================
-- 模块引用
-- ============================================================================

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local AssetAcquire = Utils.AssetAcquire
local AssetRegistry = Utils.AssetRegistry
local AssetPaths = Utils.AssetPaths
local ObjectPoolUtil = Utils.ObjectPoolUtil
local SkillPreloadUtil = Utils.SkillPreloadUtil

-- ============================================================================
-- 模块定义
-- ============================================================================

local ResourceUtil = {}

export type AcquireOptions = {
	scope: string?,
	clone: boolean?,
	restore: boolean?,
	usePool: boolean?,
	poolTemplate: Instance?,
}

-- ============================================================================
-- 兼容 / 配置导出（freeze 源表的同一引用，调用方不可改键）
-- ============================================================================

ResourceUtil.ModelType = AssetRegistry.ModelType
ResourceUtil.ModelCategory = AssetRegistry.ModelCategory
ResourceUtil.Catalog = AssetRegistry.Catalog
ResourceUtil.Scope = AssetPaths.Scope

-- ============================================================================
-- 公共 API — 资源获取
-- ============================================================================

--[[
	通用资源获取（委托 AssetAcquire.Get）

	分支优先级：usePool > clone=false > 默认 Clone + 可选 Restore

	@param relativePath string - 相对路径，如 "Hatch/BoxModel" 或 "ModelRes/Pet/Cat1"；非 string 或空串返回 nil
	@param options AcquireOptions? - 获取选项；scope 为 Scope.Shared / Server / Auto，nil 时用 AssetAcquire 默认
	@return Instance? - 实例；路径无效、未找到或 Clone/借池失败时 nil
]]
function ResourceUtil.Get(relativePath: string, options: AcquireOptions?): Instance?
	return AssetAcquire.Get(relativePath, options)
end

--[[
	从 ModelRes 克隆可直接使用的模型（委托 AssetAcquire.GetModel）

	@param category string - ModelCategory，如 Pet / Effect / Mount / Skill；非 string 或空串返回 nil
	@param modelName string - 模型名称；非 string 或空串返回 nil
	@param options AcquireOptions? - 获取选项；scope 为 Scope.Shared / Server / Auto，nil 时用默认
	@return Model? - 模型；路径无效、未找到、模板非 Model 或 Clone/借池失败时 nil
]]
function ResourceUtil.GetModel(category: string, modelName: string, options: AcquireOptions?): Model?
	return AssetAcquire.GetModel(category, modelName, options)
end

--[[
	从 UI catalog 获取资源（委托 AssetAcquire.GetUI）

	@param relativePath string - UI 子路径，如 "Tips/BGTemp"；非 string 或空串返回 nil
	@param options AcquireOptions? - 获取选项；scope 为 Scope.Shared / Server / Auto，nil 时用默认
	@return Instance? - UI 实例；路径无效、未找到或 Clone/借池失败时 nil
]]
function ResourceUtil.GetUI(relativePath: string, options: AcquireOptions?): Instance?
	return AssetAcquire.GetUI(relativePath, options)
end

--[[
	从 ServerStorage.Assets 获取 UI 并 Clone + Restore

	仅服务端有效；客户端无 ServerStorage，恒返回 nil。

	@param relativePath string - 如 "排行榜/RankTemp" 或 "Rank/RankTemp"；非 string 或空串返回 nil
	@return Instance? - UI 克隆；客户端、路径无效、未找到或 Clone 失败时 nil
]]
function ResourceUtil.GetServerUI(relativePath: string): Instance?
	return AssetAcquire.GetUI(relativePath, {
		scope = AssetPaths.Scope.Server,
		clone = true,
		restore = true,
	})
end

--[[
	获取资源模板引用（不 Clone、不 Restore；委托 AssetAcquire.GetTemplate）

	@param relativePath string - 相对路径；非 string 或空串返回 nil
	@param scope string? - Scope.Shared / Server / Auto，默认 Shared
	@return Instance? - DataModel 模板活引用；路径无效或未找到时 nil
]]
function ResourceUtil.GetTemplate(relativePath: string, scope: string?): Instance?
	return AssetAcquire.GetTemplate(relativePath, scope)
end

-- ============================================================================
-- 公共 API — 对象池
-- ============================================================================

--[[
	从对象池借出实例（委托 ObjectPoolUtil.getObjectFromPool）

	池键为 template.Name；借出成功时 Parent=workspace。用完须 BackToPool，勿 Destroy。

	@param template Instance - 对象模板（以其 Name 作为池键）
	@return Instance? - 借出实例；模板非法、Name 为空或 Clone 失败时 nil
]]
function ResourceUtil.GetPooledInstance(template: Instance): Instance?
	return ObjectPoolUtil.getObjectFromPool(template)
end

--[[
	将实例归还对象池（委托 ObjectPoolUtil.backToPool）

	无 ModelName 则销毁；已在池内则幂等成功。

	@param instance Instance - 要归还的借出实例
	@return boolean, string? - 成功 true；失败 false 与 ObjectPoolUtil.Err.INVALID_INSTANCE / NOT_POOLED
]]
function ResourceUtil.BackToPool(instance: Instance): (boolean, string?)
	return ObjectPoolUtil.backToPool(instance)
end

-- ============================================================================
-- 公共 API — 预加载
-- ============================================================================

--[[
	预加载基础技能资源（委托 SkillPreloadUtil.PreloadBaseSkill）

	@param baseSkillName string - 基础技能 ModuleScript 名称
	@return () - 无返回值；会话内同名只预热一次
]]
function ResourceUtil.PreloadBaseSkill(baseSkillName: string)
	SkillPreloadUtil.PreloadBaseSkill(baseSkillName)
end

--[[
	预加载组技能资源（委托 SkillPreloadUtil.PreloadSkill）

	@param skillName string - 组技能 ModuleScript 名称
	@return () - 无返回值；会话内同名只预热一次
]]
function ResourceUtil.PreloadSkill(skillName: string)
	SkillPreloadUtil.PreloadSkill(skillName)
end

--[[
	预加载动作资源（委托 SkillPreloadUtil.PreloadAnimations）

	@param animationNames { string } - 动作名称数组；空项跳过
	@return () - 无返回值
]]
function ResourceUtil.PreloadAnimations(animationNames: { string })
	SkillPreloadUtil.PreloadAnimations(animationNames)
end

--[[
	预加载音频资源（委托 SkillPreloadUtil.PreloadSounds）

	@param soundNames { string } - 音频名称数组（SoundService 中 Sound.Name）；空项跳过
	@return () - 无返回值
]]
function ResourceUtil.PreloadSounds(soundNames: { string })
	SkillPreloadUtil.PreloadSounds(soundNames)
end

return ResourceUtil
