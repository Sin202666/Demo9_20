--[[
	Module: SystemSummon
	Description: 召唤物伤害权威空壳（一期）
	Author: 林奥宇
	Created: 2026-07-29
	Last Modified: 2026-08-28

	一期 Hit / HitFromNpc 恒返回 0。落地真伤害须走 ServerSide 权威模块 + Utils 分流，禁止客侧定伤记账。
]]

local SystemSummon = {}

--[[
	召唤物对目标造成伤害（一期空壳）
	@param _ownerId any - 召唤物所有者标识；本迭代忽略
	@param _name string - 召唤物配置名；本迭代忽略
	@param _hitData any - 命中数据；本迭代忽略
	@return number - 恒 0（尚未接入服端结算）
]]
function SystemSummon.Hit(_ownerId: any, _name: string, _hitData: any): number
	return 0
end

--[[
	NPC 来源召唤物伤害（一期空壳）
	@param _name string - 召唤物配置名；本迭代忽略
	@param _hitData any - 命中数据；本迭代忽略
	@return number - 恒 0（尚未接入服端结算）
]]
function SystemSummon.HitFromNpc(_name: string, _hitData: any): number
	return 0
end

return SystemSummon
