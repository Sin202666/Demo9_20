--[[
	Module: SkillBuffUtil
	Description: 技能 Buff RuntimeWindow 客户端 stub（权威写口在 ServerSideCode.System.SkillBuffUtil）
	Author: 林奥宇
	Created: 2026-07-29
	Last Modified: 2026-08-31

	功能：
	- GetRuntimeWindow：只读复制实例上的窗 NumberValue，返回未过期到期 ServerTime
	- Apply / ApplyFromSkillCfg / ApplyBuffsFromSkillForCaster / ApplySkillBuffsToDefender：客机 no-op
	- Clear / Init / destroy / TickSkillBuffRuntime：客机 no-op（Shutdown 为 destroy 别名）
	- TryProcCastTraitsOnSkillCast：一期保持 no-op（与服一致）

	Utils.SkillBuffUtil 服务端优先加载真模块；本文件仅非服回落。
	勿在客户端当写窗 / 控速权威。WalkSpeed 仍只经 CharacterMoveSpeed。

	加载方式：
		local SkillBuffUtil = Utils.SkillBuffUtil
		local expireAt = SkillBuffUtil.GetRuntimeWindow(player, "Stun")
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local SkillBuffUtil = {}

local WINDOW_PREFIX = "SkillBuff_"
local WINDOW_FOLDER = "技能Buff窗"

--[[
	解析 buff 宿主（Player 优先；否则 Model）
	@param target any - Player 或角色 Model；其它 Instance 返回 nil
	@return Instance? - Player 或 Model 宿主；无法解析为 nil
]]
local function _resolveHost(target: any): Instance?
	if typeof(target) ~= "Instance" then
		return nil
	end
	if target:IsA("Player") then
		return target
	end
	if target:IsA("Model") then
		local plr = Players:GetPlayerFromCharacter(target)
		return plr or target
	end
	return nil
end

--[[
	客户端 stub：不写窗
	@param _target any - Player 或 Model；客机忽略
	@param _buffIdOrList any - 条目或列表；客机忽略
	@param _ctx any? - 预留上下文；客机忽略
	@return boolean - 恒 false
]]
function SkillBuffUtil.Apply(_target: any, _buffIdOrList: any, _ctx: any?): boolean
	return false
end

--[[
	客户端 stub：不按配置写窗
	@param _target any - Player 或 Model；客机忽略
	@param _skillCfg any - skillConf 行；客机忽略
	@param _ctx any? - 预留上下文；客机忽略
	@return boolean - 恒 false
]]
function SkillBuffUtil.ApplyFromSkillCfg(_target: any, _skillCfg: any, _ctx: any?): boolean
	return false
end

--[[
	客户端 stub：不销毁服端窗实例
	@param _target any - Player 或 Model；客机忽略
]]
function SkillBuffUtil.Clear(_target: any)
end

--[[
	查询未过期 RuntimeWindow 到期时间（只读实例，不写）
	@param target any - Player 或 Model
	@param key any - WindowKey（tostring 后查 NumberValue）
	@return number? - 到期 ServerTime；过期/无则 nil
]]
function SkillBuffUtil.GetRuntimeWindow(target: any, key: any): number?
	local host = _resolveHost(target)
	if not host or key == nil then
		return nil
	end
	local windowKey = tostring(key)
	local folder = host:FindFirstChild(WINDOW_FOLDER)
	if not folder then
		return nil
	end
	local nv = folder:FindFirstChild(WINDOW_PREFIX .. windowKey)
	if nv and nv:IsA("NumberValue") then
		local now = Workspace:GetServerTimeNow()
		if nv.Value > now then
			return nv.Value
		end
	end
	return nil
end

--[[
	客户端 stub：施法者 Self 向叠窗仅服务端
	@param _plr Player? - 施法者；客机忽略
	@param _skillId number? - skillConf ID；客机忽略
	@param _casterCtx any? - 预留施法上下文；客机忽略
]]
function SkillBuffUtil.ApplyBuffsFromSkillForCaster(_plr: Player?, _skillId: number?, _casterCtx: any?)
end

--[[
	组技能 CastTrait（一期保持 no-op）
	@param _plr Player? - 施法者；本迭代忽略
	@param _skillId number? - 技能 ID；本迭代忽略
	@param _ctx any? - 预留上下文；本迭代忽略
]]
function SkillBuffUtil.TryProcCastTraitsOnSkillCast(_plr: Player?, _skillId: number?, _ctx: any?)
end

--[[
	客户端 stub：命中后 Enemy 向叠窗仅服务端
	@param _defenderModel Model? - 防御方角色；客机忽略
	@param _skillId number? - skillConf ID；客机忽略
	@param _casterCtx any? - 预留施法上下文；客机忽略
]]
function SkillBuffUtil.ApplySkillBuffsToDefender(_defenderModel: Model?, _skillId: number?, _casterCtx: any?)
end

--[[
	客户端 stub：不挂 CombatWorld
]]
function SkillBuffUtil.Init()
end

--[[
	客户端 stub：无 World 句柄可注销
]]
function SkillBuffUtil.destroy()
end

SkillBuffUtil.Shutdown = SkillBuffUtil.destroy

--[[
	客户端 stub：过期清理仅服务端
]]
function SkillBuffUtil.TickSkillBuffRuntime()
end

return SkillBuffUtil
