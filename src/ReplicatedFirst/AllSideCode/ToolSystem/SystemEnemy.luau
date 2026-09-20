--[[
	Module: SystemEnemy
	Description: 敌人伤害权威客户端 stub（权威实现在 ServerSideCode.System.SystemEnemy）
	Author: 林奥宇
	Created: 2026-07-29
	Last Modified: 2026-08-28

	功能：
	- IsEnabled：与服同路径读 GameConfig「怪物系统.启用」
	- Init / Register / Unregister / Hit / CreateLogicalEnemy / DespawnById：客机 no-op
	- collectLogicalOverlapHits / PauseMoveAi / ResumeMoveAi / SetMoveGoal / SetMoveDir / GetMoveDriveMode：客机恒空/false/nil

	加载：
		local SystemEnemy = Utils.SystemEnemy
		-- 客机请勿依赖本 stub 的创建/受击返回值
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local SystemGameConfig = Utils.SystemGameConfig

local SystemEnemy = {}

--[[
	怪物系统总开关（与服务端 SystemEnemy.IsEnabled 同路径）
	@return boolean - true 表示启用
]]
function SystemEnemy.IsEnabled(): boolean
	return SystemGameConfig.GetValue({ "怪物系统", "启用" }) ~= false
end

--[[
	客户端 stub：初始化无操作（权威 Init 仅服务端）
]]
function SystemEnemy.Init()
end

--[[
	客户端 stub：假人注册仅服务端
	@param _model Model - 带 Humanoid 的模型；客机忽略
]]
function SystemEnemy.Register(_model: Model)
end

--[[
	客户端 stub：取消注册仅服务端
	@param _model Model - 已注册模型；客机忽略
]]
function SystemEnemy.Unregister(_model: Model)
end

--[[
	客户端 stub：逻辑怪创建仅服务端权威
	@param _cfgId number - enemyConf 行 ID
	@param _cframe CFrame - 初始位姿
	@param _opts any? - allowedPlayerIds / combatReady / bboxSize / maxHp；客机忽略
	@return number? - 恒 nil
]]
function SystemEnemy.CreateLogicalEnemy(_cfgId: number, _cframe: CFrame, _opts: any?): number?
	return nil
end

--[[
	客户端 stub：逻辑怪销毁仅服务端权威
	@param _id number - 运行时 id
	@return boolean - 恒 false
]]
function SystemEnemy.DespawnById(_id: number): boolean
	return false
end

--[[
	客户端 stub：逻辑体积相交仅服务端权威
	@param _cf CFrame - Hitbox 位姿
	@param _size Vector3 - Hitbox 全尺寸
	@param _shape string - "Ball" | "Block"
	@param _alreadyHit { [number]: any }? - 已命中逻辑 id 表
	@return { [number]: Vector3 } - 恒空表
]]
function SystemEnemy.collectLogicalOverlapHits(
	_cf: CFrame,
	_size: Vector3,
	_shape: string,
	_alreadyHit: { [number]: any }?
): { [number]: Vector3 }
	return {}
end

--[[
	客户端 stub：受击结算仅服务端权威
	@param _ownerId any - 攻击者 UserId
	@param _enemyName string - 目标 Model.Name 或逻辑怪 id 字符串
	@param _hitData any? - 伤害载荷
	@return number - 恒 0
]]
function SystemEnemy.Hit(_ownerId: any, _enemyName: string, _hitData: any): number
	return 0
end

--[[
	客户端 stub：移动命令仅服务端权威
	@param _id number - 运行时 id
	@return boolean - 恒 false
]]
function SystemEnemy.PauseMoveAi(_id: number): boolean
	return false
end

--[[
	@param _id number - 运行时 id
	@return boolean - 恒 false
]]
function SystemEnemy.ResumeMoveAi(_id: number): boolean
	return false
end

--[[
	@param _id number - 运行时 id
	@param _worldPos Vector3 - 世界目标
	@param _opts any? - timeoutSec / arriveEps / usePath；客机忽略
	@return boolean - 恒 false
]]
function SystemEnemy.SetMoveGoal(_id: number, _worldPos: Vector3, _opts: any?): boolean
	return false
end

--[[
	@param _id number - 运行时 id
	@param _flatDir Vector3 - 平面方向
	@param _durationSec number - 持续秒
	@return boolean - 恒 false
]]
function SystemEnemy.SetMoveDir(_id: number, _flatDir: Vector3, _durationSec: number): boolean
	return false
end

--[[
	@param _id number - 运行时 id
	@return string? - 恒 nil
]]
function SystemEnemy.GetMoveDriveMode(_id: number): string?
	return nil
end

return SystemEnemy
