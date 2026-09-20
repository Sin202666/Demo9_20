--[[
	Module: ObjectPoolUtil-Type
	Description: ObjectPoolUtil 类型声明（完整使用说明见 ToolSystem/ObjectPoolUtil.luau 文件头）
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-08-31
]]

local ObjectPoolUtil = {}

ObjectPoolUtil.CLEAR_IDLE_TIME = 60

ObjectPoolUtil.Err = {
	INVALID_INSTANCE = "INVALID_INSTANCE",
	CLONE_FAILED = "CLONE_FAILED",
	NOT_POOLED = "NOT_POOLED",
} :: {
	INVALID_INSTANCE: string,
	CLONE_FAILED: string,
	NOT_POOLED: string,
}

--[[
	初始化对象池（仅 Manager 启动时调用）
	@return Folder - ReplicatedStorage.ObjectPool
]]
function ObjectPoolUtil.Init(): Folder
end

--[[
	预热：Clone 模板入池，不借出
	@param instance Instance - 模板，Name 为池键
	@return boolean, string? - 成功 true；失败 false 与 Err.INVALID_INSTANCE / CLONE_FAILED
]]
function ObjectPoolUtil.addObjectToPool(instance: Instance): (boolean, string?)
end

--[[
	归还借出实例；无 ModelName 属性则销毁；已在池内则幂等
	@param instance Instance - 借出实例
	@return boolean, string? - 成功 true；失败 false 与 Err.INVALID_INSTANCE / NOT_POOLED
]]
function ObjectPoolUtil.backToPool(instance: Instance): (boolean, string?)
end

--[[
	借出实例；池空则自动 Clone；成功时 Parent=workspace
	@param instance Instance - 模板，Name 为池键
	@return Instance? - 借出实例；模板非法或 Clone 失败时为 nil
]]
function ObjectPoolUtil.getObjectFromPool(instance: Instance): Instance?
end

--[[
	销毁空闲超过 CLEAR_IDLE_TIME 的池内实例（Manager 周期调用）
	@return nil - 无返回值
]]
function ObjectPoolUtil.clearIdleObjects()
end

return ObjectPoolUtil
