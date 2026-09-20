--!strict
--[[
	Module: ObjectPoolUtil
	Description: 通用 Instance 对象池（借出、归还、空闲回收）；池键为模板 Name，存放于 ReplicatedStorage.ObjectPool
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-08-31

	功能：
	- 按模板 Name 分池，自动 Clone 首个实例
	- 借出时恢复延迟加载资源（ResRestore）
	- 归还时复位锚定/速度（VisibleMgr）并刷新空闲时间戳
	- 空闲超过 CLEAR_IDLE_TIME（60s）的实例由 Manager 定期销毁

	------------------------------------------------------------------------
	池键与存储
	------------------------------------------------------------------------
	池键（pool key）= 传入模板的 Instance.Name（区分大小写）。
	同一 Name 的模板共用一条池；不同路径但同名模板会混池，请保证模板 Name 唯一。

	物理存放：
		ReplicatedStorage/ObjectPool/{克隆实例...}

	实例 Attribute（入池时自动写入，勿手动删改）：
		ModelName  string  - 池键，与借出时模板 Name 一致
		FreshTime  number  - 最近一次归还的 os.time()，用于空闲清理

	------------------------------------------------------------------------
	生命周期
	------------------------------------------------------------------------
	1. 启动：ObjectPoolManager 调用 Init()，创建池文件夹并重建空闲索引
	2. 借出：getObjectFromPool(template) → 有闲置则取出，否则 Clone 模板入池再借出
	3. 使用：调用方将实例 Parent 到 UI / workspace / 特效容器等（借出默认 Parent=workspace）
	4. 归还：backToPool(instance) → 移回 ReplicatedStorage.ObjectPool；重复归还幂等
	5. 清理：Manager 每 CLEAR_IDLE_TIME 秒调用 clearIdleObjects()，销毁 FreshTime 超时实例

	------------------------------------------------------------------------
	何时使用本模块
	------------------------------------------------------------------------
	需要「同一模板反复 Clone / 销毁」的 UI、特效、模型 → 用对象池减少分配。
	已走资源获取链路（路径解析 + Restore）→ 优先 ResourceUtil / AssetAcquire：

		-- 推荐：资源门面 + 对象池一步完成
		local ResourceUtil = Utils.ResourceUtil
		local pooled = ResourceUtil.GetPooledInstance(template)
		ResourceUtil.BackToPool(instance)

		-- 或 AssetAcquire 选项
		local AssetAcquire = Utils.AssetAcquire
		local pooled = AssetAcquire.Get(relativePath, { usePool = true, poolTemplate = template })

	仅需借还、模板已在手（Tips 模板、FX 模板等）→ 可直接 Utils.ObjectPoolUtil。
	特效模型归还前需停粒子/恢复默认视觉 → 用 FXUtil.BackPool_Instance / ReturnPooledModelToPool
	（内部仍调用本模块 backToPool）。
	公共 API 保持历史 camelCase（getObjectFromPool 等），与 ResourceUtil 的 PascalCase 门面并存。

	加载方式：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local ObjectPoolUtil = Utils.ObjectPoolUtil

	------------------------------------------------------------------------
	使用示例
	------------------------------------------------------------------------
	-- 【UI Tips】从模板借出 Frame / TextLabel
	local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
	local ObjectPoolUtil = Utils.ObjectPoolUtil
	local bgTemplate: Frame = ... -- 模板，Name 即池键，如 "BGTemp"

	local bgFrame = ObjectPoolUtil.getObjectFromPool(bgTemplate) :: Frame
	bgFrame.Parent = tipsContainer
	-- ... 展示逻辑 ...
	ObjectPoolUtil.backToPool(bgFrame)

	-- 【资源 + 池】通过门面（内部解析路径并支持 usePool）
	local ResourceUtil = Utils.ResourceUtil
	local template = ResourceUtil.GetTemplate("UI/Tips/BGTemp")
	if template then
		local frame = ResourceUtil.GetPooledInstance(template)
		-- ...
		ResourceUtil.BackToPool(frame)
	end

	-- 【预热】提前 Clone 入池，避免首次使用时卡顿
	local ObjectPoolUtil = Utils.ObjectPoolUtil
	ObjectPoolUtil.addObjectToPool(effectTemplate)
	ObjectPoolUtil.addObjectToPool(effectTemplate) -- 可多次预热同一模板

	-- 【Manager 侧】客户端 ObjectPoolManager 已负责，业务一般无需调用
	ObjectPoolUtil.Init()
	-- 定时间隔请用 ObjectPoolUtil.CLEAR_IDLE_TIME，勿再抄写 60

	------------------------------------------------------------------------
	API 说明
	------------------------------------------------------------------------
	getObjectFromPool(template)  - 借出；池空则 Clone 模板；成功时 Parent=workspace；失败 nil
	backToPool(instance)         - 归还；成功 true；无 ModelName 则 Destroy 并 false, NOT_POOLED
	addObjectToPool(template)    - 仅预热：Clone 入池，不借出；成功 true；Clone 失败 false, CLONE_FAILED
	clearIdleObjects()           - 销毁空闲超过 CLEAR_IDLE_TIME 的实例；由 Manager 周期调用
	Init()                       - 创建池目录并重建索引；仅 Manager 在启动时调用一次
	CLEAR_IDLE_TIME              - 空闲回收秒数（当前 60）；Manager 与此对齐
	Err                          - INVALID_INSTANCE / CLONE_FAILED / NOT_POOLED

	------------------------------------------------------------------------
	注意事项
	------------------------------------------------------------------------
	- 借出实例必须有有效 ModelName 属性才能归还；否则 backToPool 会直接 Destroy。
	- getObjectFromPool 成功后将 Parent 设为 workspace；UI 场景需自行改 Parent。
	- 归还时 VisibleMgr.AnchoredAll / SpeedDown；模型类特效建议走 FXUtil 复位后再归还。
	- 池内实例会经 ResRestore.PrepareInstance 恢复 NoAssetID 延迟资源。
	- 不要手动 Parent 到 ObjectPool 文件夹以外长期悬挂而不归还，否则仍会占内存直至空闲清理。
	- Archivable=false 的模板无法 Clone，addObjectToPool / getObjectFromPool 会失败。
	- 服务端若需对象池，需自行在 InitGame Manager 中 Init 并定时 clearIdleObjects（当前仅客户端 Manager）。
	  索引是每端一份内存表，双端不要共用同一套借还。
]]

-- ============================================================================
-- 服务引用 / 模块引用
-- ============================================================================

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local ReplicatedStorage = Utils.ReplicatedStorage
local VisibleMgr = Utils.VisibleMgr
local ResRestore = Utils.ResRestore
local Log = Utils.Log

-- ============================================================================
-- 模块定义
-- ============================================================================

local ObjectPoolUtil = {}

-- ============================================================================
-- 常量
-- ============================================================================

local POOL_FOLDER_NAME = "ObjectPool"
local ATTR_MODEL_NAME = "ModelName"
local ATTR_FRESH_TIME = "FreshTime"
local CLEAR_IDLE_TIME = 60

local ERR = table.freeze({
	INVALID_INSTANCE = "INVALID_INSTANCE",
	CLONE_FAILED = "CLONE_FAILED",
	NOT_POOLED = "NOT_POOLED",
})

ObjectPoolUtil.CLEAR_IDLE_TIME = CLEAR_IDLE_TIME
ObjectPoolUtil.Err = ERR

-- ============================================================================
-- 私有变量
-- ============================================================================

-- 按 ModelName 索引空闲对象，避免每次 Get 遍历文件夹
local _idlePoolIndex: { [string]: { Instance } } = {}

-- ============================================================================
-- 私有函数
-- ============================================================================

--[[
	确保对象池根文件夹存在（内部懒创建，不重建索引）
	@return Folder - 对象池文件夹
]]
local function _ensurePoolFolder(): Folder
	local objectPool: Folder? = ReplicatedStorage:FindFirstChild(POOL_FOLDER_NAME) :: Folder?

	if not objectPool then
		local newFolder = Instance.new("Folder")
		newFolder.Name = POOL_FOLDER_NAME
		newFolder.Parent = ReplicatedStorage
		objectPool = newFolder :: Folder
	end

	return objectPool :: Folder
end

--[[
	从索引中登记空闲对象；已在对应列表中则跳过，避免重复归还导致同一实例被借出两次
	@param instance Instance - 池内实例
	@return nil - 无返回值
]]
local function _registerInIndex(instance: Instance)
	local modelName = instance:GetAttribute(ATTR_MODEL_NAME)
	if type(modelName) ~= "string" or modelName == "" then
		return
	end

	local list = _idlePoolIndex[modelName]
	if not list then
		list = {}
		_idlePoolIndex[modelName] = list
	end
	for _, existing in list do
		if existing == instance then
			return
		end
	end
	table.insert(list, instance)
end

--[[
	从索引中取出一个有效空闲对象（跳过已被外部销毁的残留引用）
	@param modelName string - 模板名称
	@return Instance? - 空闲实例
]]
local function _takeFromIndex(modelName: string): Instance?
	local list = _idlePoolIndex[modelName]
	if not list then
		return nil
	end

	while #list > 0 do
		local pooled = table.remove(list) :: Instance
		if pooled and pooled.Parent ~= nil then
			return pooled
		end
	end

	return nil
end

--[[
	扫描对象池文件夹，重建空闲索引
	@param folder Folder - 对象池根目录
	@return nil - 无返回值
]]
local function _rebuildIndexFromFolder(folder: Folder)
	table.clear(_idlePoolIndex)
	for _, child in folder:GetChildren() do
		_registerInIndex(child)
	end
end

--[[
	刷新对象的时间戳
	@param instance Instance - 要刷新的实例
	@return nil - 无返回值
]]
local function _refreshFreshTimeAttribute(instance: Instance)
	instance:SetAttribute(ATTR_FRESH_TIME, os.time())
end

--[[
	设置对象的属性（模型名称和时间戳）
	@param instance Instance - 要设置的实例
	@return nil - 无返回值
]]
local function _setObjectAttributes(instance: Instance)
	instance:SetAttribute(ATTR_MODEL_NAME, instance.Name)
	instance:SetAttribute(ATTR_FRESH_TIME, os.time())
end

--[[
	归还时复位锚定与速度。
	VisibleMgr 标注为 Part/Model，实际按 Instance 递归，UI 模板也走此路径。
	@param instance Instance - 归还实例
	@return nil - 无返回值
]]
local function _resetPooledPhysics(instance: Instance)
	VisibleMgr.AnchoredAll(instance :: any)
	VisibleMgr.SpeedDown(instance :: any)
end

--[[
	Clone 模板并挂入池文件夹、写入索引（不借出）
	@param template Instance - 模板，Name 为池键
	@return Instance? - 入池后的克隆；Clone 失败时为 nil
]]
local function _addCloneToPool(template: Instance): Instance?
	local ok, instanceClone = pcall(function()
		return template:Clone()
	end)
	if not ok then
		Log.warn("ObjectPoolUtil: Clone 异常", template, instanceClone)
		return nil
	end
	if instanceClone == nil then
		Log.warn("ObjectPoolUtil: Clone 返回 nil（Archivable=false?）", template)
		return nil
	end

	ResRestore.PrepareInstance(instanceClone)
	_setObjectAttributes(instanceClone)

	local folder = _ensurePoolFolder()
	instanceClone.Parent = folder
	_registerInIndex(instanceClone)
	return instanceClone
end

--[[
	借出后挂到 workspace（UI 调用方需再改 Parent）
	@param pooled Instance - 已从索引取出的实例
	@return Instance - 同一实例
]]
local function _lendToWorkspace(pooled: Instance): Instance
	pooled.Parent = workspace
	return pooled
end

-- ============================================================================
-- 公共 API
-- ============================================================================

--[[
	向对象池添加对象（Clone 后恢复延迟加载资源），用于预热池，不借出
	@param instance Instance - 要添加的模板实例，以其 Name 作为池键
	@return boolean, string? - 成功 true；失败 false 与 Err.INVALID_INSTANCE / CLONE_FAILED
]]
function ObjectPoolUtil.addObjectToPool(instance: Instance): (boolean, string?)
	if typeof(instance) ~= "Instance" then
		Log.warn("addObjectToPool: 模板不是 Instance")
		return false, ERR.INVALID_INSTANCE
	end
	if instance.Name == "" then
		Log.warn("addObjectToPool: 模板 Name 为空，无法作为池键")
		return false, ERR.INVALID_INSTANCE
	end
	if not _addCloneToPool(instance) then
		return false, ERR.CLONE_FAILED
	end
	return true
end

--[[
	将对象归还对象池；无 ModelName 属性的实例会被 Destroy
	归还时复位锚定/速度并刷新 FreshTime。已在池内则只刷新时间戳（幂等）。
	@param instance Instance - 要归还的借出实例
	@return boolean, string? - 成功 true；失败 false 与 Err.INVALID_INSTANCE / NOT_POOLED
]]
function ObjectPoolUtil.backToPool(instance: Instance): (boolean, string?)
	if typeof(instance) ~= "Instance" then
		Log.warn("backToPool: 不是 Instance")
		return false, ERR.INVALID_INSTANCE
	end
	if instance.Parent == nil then
		return false, ERR.INVALID_INSTANCE
	end

	local folder = _ensurePoolFolder()
	if instance.Parent == folder then
		_refreshFreshTimeAttribute(instance)
		_registerInIndex(instance)
		return true
	end

	local modelName = instance:GetAttribute(ATTR_MODEL_NAME)
	if type(modelName) ~= "string" or modelName == "" then
		Log.warn("backToPool: 无 ModelName，已销毁非池对象", instance.Name)
		instance:Destroy()
		return false, ERR.NOT_POOLED
	end

	instance.Name = modelName
	_refreshFreshTimeAttribute(instance)
	_resetPooledPhysics(instance)

	instance.Parent = folder
	_registerInIndex(instance)
	return true
end

--[[
	从对象池借出实例；池空时自动 Clone 模板入池再借出
	成功时 Parent 设为 workspace，UI 等场景需自行改 Parent
	@param instance Instance - 对象模板（以其 Name 作为池键）
	@return Instance? - 借出实例；模板非法、Name 为空或 Clone 失败时为 nil
]]
function ObjectPoolUtil.getObjectFromPool(instance: Instance): Instance?
	if typeof(instance) ~= "Instance" then
		Log.warn("getObjectFromPool: 模板不是 Instance")
		return nil
	end
	local modelName = instance.Name
	if modelName == "" then
		Log.warn("getObjectFromPool: 模板 Name 为空，无法作为池键")
		return nil
	end

	local pooled = _takeFromIndex(modelName)
	if pooled then
		ResRestore.PrepareInstance(pooled)
		return _lendToWorkspace(pooled)
	end

	if not _addCloneToPool(instance) then
		return nil
	end

	pooled = _takeFromIndex(modelName)
	if pooled then
		return _lendToWorkspace(pooled)
	end

	Log.warn("getObjectFromPool: 入池后未能取出", modelName)
	return nil
end

--[[
	清理空闲超过 CLEAR_IDLE_TIME 的池内实例，并丢掉已销毁的残留索引
	由 ObjectPoolManager 定期调用，业务侧一般无需直接调用
	@return nil - 无返回值
]]
function ObjectPoolUtil.clearIdleObjects()
	local nowTick = os.time()

	for _, list in _idlePoolIndex do
		local i = 1
		while i <= #list do
			local model = list[i]
			if not model or model.Parent == nil then
				table.remove(list, i)
			else
				local freshTime = model:GetAttribute(ATTR_FRESH_TIME)
				if type(freshTime) == "number" and (nowTick - freshTime) > CLEAR_IDLE_TIME then
					table.remove(list, i)
					model:Destroy()
				else
					i += 1
				end
			end
		end
	end
end

-- ============================================================================
-- 初始化
-- ============================================================================

--[[
	初始化对象池文件夹并重建空闲索引
	仅由 ObjectPoolManager 在客户端启动时调用一次
	@return Folder - 对象池根文件夹（ReplicatedStorage.ObjectPool）
]]
function ObjectPoolUtil.Init(): Folder
	local objectPool = _ensurePoolFolder()
	_rebuildIndexFromFolder(objectPool)
	return objectPool
end

return ObjectPoolUtil
