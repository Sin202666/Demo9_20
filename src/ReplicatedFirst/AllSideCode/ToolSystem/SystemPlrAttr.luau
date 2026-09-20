--[[
	Module: SystemPlrAttr
	Description: 玩家战斗属性/受击客户端 stub（权威实现在 ServerSideCode.System.SystemPlrAttr）
	Author: 林奥宇
	Created: 2026-07-29
	Last Modified: 2026-08-28

	Utils.SystemPlrAttr 服务端优先加载真模块；本文件仅非服回落。
	HitPlr 恒返回 0；InitPlr / ChangeHP / WudiPlr 为 no-op。勿在客户端当结算权威。
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local SystemGameConfig = Utils.SystemGameConfig

local SystemPlrAttr = {}

--[[
	战斗系统总开关（读 GameConfig；与服端同键）
	@return boolean - true 表示战斗系统启用
]]
function SystemPlrAttr.IsEnabled(): boolean
	return SystemGameConfig.GetValue({ "战斗系统", "启用" }) ~= false
end

--[[
	客户端 stub：不初始化会话属性
	@param _plr Player - 玩家；本侧忽略
]]
function SystemPlrAttr.InitPlr(_plr: Player)
end

--[[
	客户端 stub：不结算承伤
	@param _attackerModel any - 攻击方 Model；本侧忽略
	@param _beHitPlr Player - 受击玩家；本侧忽略
	@param _hitData any - GetDmg 用 hitData；本侧忽略
	@return number - 恒 0（权威在服端 SystemPlrAttr.HitPlr）
]]
function SystemPlrAttr.HitPlr(_attackerModel: any, _beHitPlr: Player, _hitData: any): number
	return 0
end

--[[
	客户端 stub：不改生命
	@param _plr Player - 玩家；本侧忽略
	@param _dmg number - 生命增量；本侧忽略
	@param _isCrit boolean? - 是否暴击；本侧忽略
	@param _attacker any? - 攻击方；本侧忽略
]]
function SystemPlrAttr.ChangeHP(_plr: Player, _dmg: number, _isCrit: boolean?, _attacker: any?)
end

--[[
	客户端 stub：不写无敌窗
	@param _userId number - UserId 或与服端对齐的 Player；本侧忽略
	@param _duration number? - 秒；本侧忽略
]]
function SystemPlrAttr.WudiPlr(_userId: number, _duration: number?)
end

return SystemPlrAttr