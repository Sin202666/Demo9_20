--!strict
--[[
	Module: AssetAcquire
	Description: 统一资源获取（路径解析 → Clone → Restore → 可选对象池）
	Author: 林奥宇
	Created: 2026-07-01
	Last Modified: 2026-09-01

	功能：
	- 按相对路径或 Model/UI 分类获取资源实例
	- 默认 Clone 并 ResRestore（恢复延迟加载资源）
	- 可选对象池借出（内部委托 ObjectPoolUtil）
	- 导出 AssetPaths.Scope 供 options.scope 使用

	------------------------------------------------------------------------
	与 AssetPaths / ResourceUtil 的关系
	------------------------------------------------------------------------
	AssetPaths     — 仅解析模板 Instance，不 Clone、不 Restore
	AssetAcquire   — 在 AssetPaths 之上完成 Clone / Restore / 对象池（本模块）
	ResourceUtil   — 业务门面，封装 AssetAcquire + 对象池归还 + 预加载等

	推荐：业务侧优先 Utils.ResourceUtil；需精细控制 options 或底层集成时用本模块。

	路径格式与目录约定见 AssetPaths / AssetRegistry 文件头；相对路径示例：
		"ModelRes/Pet/Cat1"、"UI/Tips/BGTemp"、"Hatch/BoxModel"

	------------------------------------------------------------------------
	Scope（AssetAcquire.Scope = AssetPaths.Scope）
	------------------------------------------------------------------------
	Shared（默认）— 查 ReplicatedStorage，双端可见资源
	Server         — 查 ServerStorage；客户端调用恒 nil
	Auto           — 服务端先 SS 后 RS；客户端等同 Shared

	------------------------------------------------------------------------
	AcquireOptions 与分支优先级
	------------------------------------------------------------------------
	字段（均为可选，省略时用默认值）：
		scope        string?    — Shared / Server / Auto，默认 Shared
		clone        boolean?   — 是否 Clone，默认 true
		restore      boolean?   — Clone 后 ResRestore，默认 true
		usePool      boolean?   — 从对象池借出，默认 false
		poolTemplate Instance?  — 池模板；省略时用 Resolve 结果

	AssetAcquire.Get 分支优先级（互斥，按顺序命中）：
		1. usePool=true     → ObjectPoolUtil.getObjectFromPool（池内 Restore，忽略 restore）
		2. clone=false      → 返回模板引用，不 Clone、不 Restore
		3. 默认             → template:Clone() + 可选 ResRestore

	GetTemplate 等价于 AssetPaths.Resolve，不经过上述分支。

	------------------------------------------------------------------------
	公共 API
	------------------------------------------------------------------------
	Get(relativePath, options?)       — 通用入口，支持全部 options
	GetModel(category, modelName, ?)  — ModelRes/{category}/{modelName}
	GetUI(relativePath, ?)            — UI/{relativePath}
	GetTemplate(relativePath, scope?) — 仅模板引用，不 Clone

	------------------------------------------------------------------------
	加载方式
	------------------------------------------------------------------------
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local AssetAcquire = Utils.AssetAcquire

	------------------------------------------------------------------------
	使用示例
	------------------------------------------------------------------------
	-- 【默认】Clone + Restore（最常用）
	local pet = AssetAcquire.Get("ModelRes/Pet/Cat1")
	pet.Parent = workspace

	-- 【分类 API】ModelRes / UI 快捷路径
	local effect = AssetAcquire.GetModel("Effect", "Explosion")
	local tipFrame = AssetAcquire.GetUI("Tips/BGTemp")
	tipFrame.Parent = someGui

	-- 【仅模板】不 Clone，用于预读属性或作为对象池模板
	local template = AssetAcquire.GetTemplate("UI/Tips/BGTemp")
	-- 等价：AssetAcquire.Get(path, { clone = false })

	-- 【服务端 UI】ServerStorage.Assets 下资源
	local rankUi = AssetAcquire.GetUI("Rank/RankTemp", {
		scope = AssetAcquire.Scope.Server,
	})

	-- 【跳过 Restore】已知无延迟加载资源时
	local raw = AssetAcquire.Get("ModelRes/Pet/Cat1", { restore = false })

	-- 【对象池】路径解析 + 借出一步完成
	local pooled = AssetAcquire.Get("UI/Tips/BGTemp", { usePool = true })
	pooled.Parent = tipsContainer
	-- 用完后归还（业务侧负责，勿 Destroy 池实例）
	Utils.ObjectPoolUtil.backToPool(pooled)
	-- 或通过门面：Utils.ResourceUtil.BackToPool(pooled)

	-- 【对象池 + 自定义模板】Resolve 与池键模板不一致时
	local tpl = AssetAcquire.GetTemplate("UI/Tips/BGTemp")
	local fromPool = AssetAcquire.Get("UI/Tips/BGTemp", {
		usePool = true,
		poolTemplate = tpl,
	})

	-- 【Auto scope】服务端优先 SS（双端脚本共用一段逻辑时）
	local asset = AssetAcquire.Get("UI/SharedPanel", {
		scope = AssetAcquire.Scope.Auto,
	})

	------------------------------------------------------------------------
	返回值与注意事项
	------------------------------------------------------------------------
	- relativePath / category / modelName 为空或非 string → nil
	- 路径未找到 → nil，不抛错
	- GetModel 先校验模板 IsA("Model")；非 Model 不 Clone、不借池，Log.warn 后返回 nil
	- Clone 失败（含 Archivable=false）→ nil，并 Log.warn
	- usePool 借出实例默认 Parent=workspace，Parent 与归还逻辑见 ObjectPoolUtil
	- 特效模型归还前需停粒子/恢复视觉 → FXUtil.BackPool_Instance / ReturnPooledModelToPool
	- 资源热重载后路径缓存由 AssetPaths.ClearCache() 清理，本模块无独立缓存
	- clone=false / GetTemplate 返回 DataModel 模板活引用（与 AssetPaths 一致），不是配置表拷贝
]]

-- ============================================================================
-- 模块引用
-- ============================================================================

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local AssetPaths = Utils.AssetPaths
local AssetRegistry = Utils.AssetRegistry
local ResRestore = Utils.ResRestore
local ObjectPoolUtil = Utils.ObjectPoolUtil
local Log = Utils.Log

-- ============================================================================
-- 模块定义
-- ============================================================================

local AssetAcquire = {}

-- ============================================================================
-- 类型
-- ============================================================================

--[[
	Acquire 选项字段说明：
	- scope: AssetPaths.Scope.Shared / Server / Auto，默认 Shared
	- clone: 是否 Clone，默认 true；false 时返回模板引用且不 Restore
	- restore: Clone 后是否 ResRestore，默认 true
	- usePool: 是否从对象池借出，默认 false；为 true 时由 ObjectPoolUtil Restore，忽略 restore
	- poolTemplate: 对象池模板 Instance，省略时使用 Resolve 结果
]]
export type AcquireOptions = {
	scope: string?,
	clone: boolean?,
	restore: boolean?,
	usePool: boolean?,
	poolTemplate: Instance?,
}

-- ============================================================================
-- 私有函数
-- ============================================================================

--[[
	合并默认 Acquire 选项
	@param options AcquireOptions? - 调用方选项
	@return AcquireOptions - 合并后的选项
]]
local function _normalizeOptions(options: AcquireOptions?): AcquireOptions
	local merged: AcquireOptions = {
		scope = AssetPaths.Scope.Shared,
		clone = true,
		restore = true,
		usePool = false,
		poolTemplate = nil,
	}
	if not options then
		return merged
	end
	if options.scope ~= nil then
		merged.scope = options.scope
	end
	if options.clone ~= nil then
		merged.clone = options.clone
	end
	if options.restore ~= nil then
		merged.restore = options.restore
	end
	if options.usePool ~= nil then
		merged.usePool = options.usePool
	end
	if options.poolTemplate ~= nil then
		merged.poolTemplate = options.poolTemplate
	end
	return merged
end

--[[
	对实例执行 Restore（若启用）
	@param instance Instance - 目标实例
	@param shouldRestore boolean - 是否恢复延迟加载资源
	@return () - 无返回值
]]
local function _maybeRestore(instance: Instance, shouldRestore: boolean)
	if shouldRestore then
		ResRestore.PrepareInstance(instance)
	end
end

--[[
	安全 Clone 模板；失败不抛错
	@param template Instance - 已解析的模板
	@return Instance? - 克隆实例；pcall 失败或 Archivable=false 时 nil
]]
local function _tryClone(template: Instance): Instance?
	local ok, clone = pcall(function()
		return template:Clone()
	end)
	if not ok then
		Log.warn("AssetAcquire: Clone 异常", template, clone)
		return nil
	end
	if clone == nil then
		Log.warn("AssetAcquire: Clone 返回 nil（Archivable=false?）", template)
		return nil
	end
	return clone
end

--[[
	按已合并选项从模板借出 / 取引用 / Clone
	@param template Instance - AssetPaths.Resolve 得到的模板
	@param opts AcquireOptions - _normalizeOptions 结果；usePool / clone / restore / poolTemplate 已填默认
	@return Instance? - 借出或克隆实例；clone=false 时为模板本身；失败 nil
]]
local function _acquireFromTemplate(template: Instance, opts: AcquireOptions): Instance?
	if opts.usePool then
		local poolTemplate = opts.poolTemplate or template
		return ObjectPoolUtil.getObjectFromPool(poolTemplate)
	end
	if opts.clone == false then
		return template
	end
	local clone = _tryClone(template)
	if not clone then
		return nil
	end
	_maybeRestore(clone, opts.restore == true)
	return clone
end

--[[
	丢弃误借出的实例，避免 GetModel 类型不符时泄漏克隆或池对象
	@param instance Instance - Get / 借池得到但类型不符的实例
	@param fromPool boolean - true 时归还对象池
	@param didClone boolean - true 时 Destroy 本次克隆；false 表示模板引用，只放弃不销毁
	@return () - 无返回值
]]
local function _abandonAcquire(instance: Instance, fromPool: boolean, didClone: boolean)
	if fromPool then
		ObjectPoolUtil.backToPool(instance)
		return
	end
	if didClone then
		instance:Destroy()
	end
end

-- ============================================================================
-- 公共 API
-- ============================================================================

AssetAcquire.Scope = AssetPaths.Scope

--[[
	通用资源获取

	分支优先级：usePool > clone=false > 默认 Clone + 可选 Restore

	@param relativePath string - 相对路径，如 "ModelRes/Pet/Cat1"；非 string 或空串返回 nil
	@param options AcquireOptions? - 获取选项；scope 为 AssetPaths.Scope.Shared / Server / Auto，nil 时用默认
	@return Instance? - 实例；路径无效、未找到或 Clone/借池失败时 nil
]]
function AssetAcquire.Get(relativePath: string, options: AcquireOptions?): Instance?
	if type(relativePath) ~= "string" or relativePath == "" then
		return nil
	end

	local opts = _normalizeOptions(options)
	local template = AssetPaths.Resolve(relativePath, opts.scope)
	if not template then
		return nil
	end
	return _acquireFromTemplate(template, opts)
end

--[[
	获取 ModelRes 下的模型

	先 Resolve 并校验模板 IsA("Model")，再 Clone / 借池，避免非 Model 路径泄漏实例。

	@param category string - 子目录，如 Pet / Effect；非 string 或空串返回 nil
	@param modelName string - 模型名；非 string 或空串返回 nil
	@param options AcquireOptions? - 获取选项；scope 为 AssetPaths.Scope.Shared / Server / Auto，nil 时用默认
	@return Model? - 模型实例；路径无效、未找到、模板或 poolTemplate 非 Model、Clone/借池失败时 nil
]]
function AssetAcquire.GetModel(category: string, modelName: string, options: AcquireOptions?): Model?
	if type(category) ~= "string" or category == "" then
		return nil
	end
	if type(modelName) ~= "string" or modelName == "" then
		return nil
	end

	local opts = _normalizeOptions(options)
	local relativePath = AssetRegistry.BuildModelPath(category, modelName)
	local template = AssetPaths.Resolve(relativePath, opts.scope)
	if not template then
		return nil
	end
	if not template:IsA("Model") then
		Log.warn("AssetAcquire.GetModel: 模板不是 Model", relativePath, template.ClassName)
		return nil
	end
	if opts.usePool and opts.poolTemplate ~= nil and not opts.poolTemplate:IsA("Model") then
		Log.warn("AssetAcquire.GetModel: poolTemplate 不是 Model", opts.poolTemplate.ClassName)
		return nil
	end

	local instance = _acquireFromTemplate(template, opts)
	if instance and instance:IsA("Model") then
		return instance
	end
	if instance then
		_abandonAcquire(instance, opts.usePool == true, opts.clone ~= false)
	end
	return nil
end

--[[
	获取 UI 目录下资源
	@param relativePath string - UI 子路径，如 "Tips/BGTemp"；非 string 或空串返回 nil
	@param options AcquireOptions? - 获取选项；scope 为 AssetPaths.Scope.Shared / Server / Auto，nil 时用默认
	@return Instance? - UI 实例；路径无效、未找到或 Clone/借池失败时 nil
]]
function AssetAcquire.GetUI(relativePath: string, options: AcquireOptions?): Instance?
	if type(relativePath) ~= "string" or relativePath == "" then
		return nil
	end
	return AssetAcquire.Get(AssetRegistry.BuildUIPath(relativePath), options)
end

--[[
	获取资源模板引用（不 Clone、不 Restore）
	@param relativePath string - 相对路径；非 string 或空串返回 nil
	@param scope string? - AssetPaths.Scope.Shared / Server / Auto，默认 Shared
	@return Instance? - 模板实例（DataModel 活引用）；路径无效或未找到时 nil
]]
function AssetAcquire.GetTemplate(relativePath: string, scope: string?): Instance?
	if type(relativePath) ~= "string" or relativePath == "" then
		return nil
	end
	return AssetPaths.Resolve(relativePath, scope or AssetPaths.Scope.Shared)
end

return AssetAcquire
