--[[
	Module: SkillBuffUtil
	Description: 技能 Buff 最小 RuntimeWindow（标记窗 + 可选控速 Attribute；无 DoT/附着）
	Author: 林奥宇
	Created: 2026-07-29
	Last Modified: 2026-08-31

	功能：
	- Apply / ApplyFromSkillCfg：按条目或 skillConf.buffs 写 NumberValue 窗
	- ApplyBuffsFromSkillForCaster / ApplySkillBuffsToDefender：Self / Enemy 向叠窗
	- Clear / TickSkillBuffRuntime：清窗与过期；SlowMove 只写 RELEASE_SKILL_STATE
	- destroy：从 CombatWorld 注销（Shutdown 为别名）
	- GetRuntimeWindow：读未过期到期 ServerTime
	- Init：只向 CombatWorld Phase.StatusEffect register（不互调 Init）

	与同类模块：
	- 权威写口仅本文件。客户端 Utils.SkillBuffUtil 回落 ToolSystem stub（查询窗实例；Apply/Clear/Init/Tick 为 no-op）
	- WalkSpeed 只经 CharacterMoveSpeed 合成；本模块禁止写 WalkSpeed / CFrame / 速度
	- 技能 Action speedType 不得占用 RELEASE_SKILL_STATE（现网用 RELEASE_SKILL_STATE_HALF）
	- 存档型 SystemBUFF 不经此 World；不绑 Remote、不写 DataStore

	门控：GameConfig「战斗系统.启用」—— false 时不写窗 / Tick 早退。
	buffs 条目最小 schema（skillConf.buffs 数组）：
	  { EffectTarget = EnumMgr.SkillEffectTarget.*, Duration = number, WindowKey = string, SlowMove = boolean? }

	加载方式：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local SkillBuffUtil = Utils.SkillBuffUtil
		-- UpdateManager：CombatWorld.Init() → SkillBuffUtil.Init()（只 register）
		SkillBuffUtil.ApplySkillBuffsToDefender(defenderModel, skillId)
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local InsMgr = Utils.InsMgr
local CfgFind = Utils.CfgFind
local EnumMgr = Utils.EnumMgr
local GetData = Utils.GetData
local CombatWorld = Utils.CombatWorld

local SkillBuffUtil = {}

-- ============================================================================
-- 常量
-- ============================================================================

local SkillEffectTarget = EnumMgr.SkillEffectTarget

local WINDOW_PREFIX = "SkillBuff_"
local SLOW_ATTR = "RELEASE_SKILL_STATE"
local WINDOW_FOLDER = "技能Buff窗"

-- ============================================================================
-- 私有变量
-- ============================================================================

-- target Instance → { [windowKey] = { expireAt, slowMove, character, nv } }
local _active: { [Instance]: { [string]: any } } = {}
local _worldHandle: any = nil
local _worldTickId: string? = nil

-- ============================================================================
-- 私有函数
-- ============================================================================

--[[
	战斗系统是否启用（Buff 写窗依赖）
	@return boolean - true 表示战斗系统启用，可写窗 / Tick
]]
local function _combatEnabled(): boolean
	if GetData and GetData.IsCombatEnabled then
		return GetData.IsCombatEnabled()
	end
	return true
end

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
	解析角色 Model（控速 Attribute 写在 LocalPlayer 复制侧：写 Player Attribute）
	@param host Instance - Player 或 Model 宿主
	@param defenderModel Model? - 命中方角色；优先于 host.Character
	@return Model? - 用于写 Attribute 的角色；无法解析为 nil
]]
local function _resolveCharacter(host: Instance, defenderModel: Model?): Model?
	if defenderModel and defenderModel:IsA("Model") then
		return defenderModel
	end
	if host:IsA("Player") then
		return host.Character
	end
	if host:IsA("Model") then
		return host
	end
	return nil
end

--[[
	确保窗 Folder
	@param host Instance - Player 或 Model 宿主
	@return Folder - host 下「技能Buff窗」Folder
]]
local function _ensureWindowFolder(host: Instance): Folder
	return InsMgr.GetIns(WINDOW_FOLDER, "Folder", host) :: Folder
end

--[[
	写入 RuntimeWindow（不写 WalkSpeed / 位姿；SlowMove 只写 RELEASE_SKILL_STATE）
	@param host Instance - Player 或 Model 宿主
	@param windowKey string - 窗键（NumberValue 名后缀）
	@param duration number - 持续秒；≤0 则跳过
	@param slowMove boolean - true 时写 RELEASE_SKILL_STATE Attribute
	@param character Model? - 非玩家时写 Attribute 的角色
]]
local function _applyWindow(host: Instance, windowKey: string, duration: number, slowMove: boolean, character: Model?)
	if type(windowKey) ~= "string" or windowKey == "" then
		return
	end
	local sec = tonumber(duration) or 0
	if sec <= 0 then
		return
	end

	local expireAt = Workspace:GetServerTimeNow() + sec
	local folder = _ensureWindowFolder(host)
	local nvName = WINDOW_PREFIX .. windowKey
	local nv = InsMgr.GetIns(nvName, "NumberValue", folder) :: NumberValue
	if nv.Value < expireAt then
		nv.Value = expireAt
	end

	_active[host] = _active[host] or {}
	_active[host][windowKey] = {
		expireAt = expireAt,
		slowMove = slowMove == true,
		character = character,
		nv = nv,
	}

	if slowMove == true then
		-- 玩家：写 Player Attribute（CMS 读 LocalPlayer）；NPC：写 Model Attribute
		if host:IsA("Player") then
			host:SetAttribute(SLOW_ATTR, true)
		elseif character then
			character:SetAttribute(SLOW_ATTR, true)
		elseif host:IsA("Model") then
			host:SetAttribute(SLOW_ATTR, true)
		end
	end
end

--[[
	按 skillConf.buffs 应用匹配 EffectTarget 的窗
	@param target any - Player 或 Model
	@param skillId number - skillConf 技能 ID
	@param effectTarget number - SkillEffectTarget.Self / Enemy
	@param defenderModel Model? - 防御方角色；Self 向可传施法者 Character
]]
local function _applyBuffsForTarget(target: any, skillId: number, effectTarget: number, defenderModel: Model?)
	if not _combatEnabled() then
		return
	end
	local host = _resolveHost(target)
	if not host then
		return
	end
	local sid = tonumber(skillId)
	if not sid or sid <= 0 then
		return
	end

	local skillCfg = CfgFind.GetCfgByNameAndID("skillConf", sid)
	if not skillCfg then
		return
	end

	local buffs = skillCfg.buffs
	if type(buffs) ~= "table" then
		return
	end

	local character = _resolveCharacter(host, defenderModel)

	for _, entry in buffs do
		if type(entry) == "table" then
			local et = tonumber(entry.EffectTarget) or entry.EffectTarget
			if et == effectTarget then
				local windowKey = entry.WindowKey or entry.windowKey or ("Skill" .. tostring(sid))
				local duration = tonumber(entry.Duration) or tonumber(entry.duration) or 0
				local slowMove = entry.SlowMove == true or entry.slowMove == true
				_applyWindow(host, tostring(windowKey), duration, slowMove, character)
			end
		end
	end
end

-- ============================================================================
-- 公共函数
-- ============================================================================

--[[
	应用技能 Buff（通用入口：按列表写窗）
	@param target any - Player 或 Model
	@param buffIdOrList any - 条目 table 或 { WindowKey, Duration, SlowMove? } 列表
	@param _ctx any? - 预留上下文；本迭代忽略
	@return boolean - 是否至少写了一窗
]]
function SkillBuffUtil.Apply(target: any, buffIdOrList: any, _ctx: any?): boolean
	if not _combatEnabled() then
		return false
	end
	local host = _resolveHost(target)
	if not host or type(buffIdOrList) ~= "table" then
		return false
	end
	local applied = false
	local list = buffIdOrList
	-- 单条目包一层
	if list.WindowKey or list.Duration then
		list = { list }
	end
	for _, entry in list do
		if type(entry) == "table" then
			local windowKey = entry.WindowKey or entry.windowKey
			local duration = tonumber(entry.Duration) or tonumber(entry.duration) or 0
			if windowKey and duration > 0 then
				_applyWindow(host, tostring(windowKey), duration, entry.SlowMove == true, _resolveCharacter(host, nil))
				applied = true
			end
		end
	end
	return applied
end

--[[
	按技能配置行 buffs 应用（Self+Enemy 全写到 target；调用方应保证目标正确）
	@param target any - Player 或 Model
	@param skillCfg any - skillConf 行（须含 buffs 数组：WindowKey/Duration/SlowMove）
	@param _ctx any? - 预留上下文；本迭代忽略
	@return boolean - 是否至少写了一窗
]]
function SkillBuffUtil.ApplyFromSkillCfg(target: any, skillCfg: any, _ctx: any?): boolean
	if type(skillCfg) ~= "table" then
		return false
	end
	if not _combatEnabled() then
		return false
	end
	local buffs = skillCfg.buffs
	if type(buffs) ~= "table" then
		return false
	end
	local host = _resolveHost(target)
	if not host then
		return false
	end
	local applied = false
	for _, entry in buffs do
		if type(entry) == "table" then
			local windowKey = entry.WindowKey or entry.windowKey or "FromCfg"
			local duration = tonumber(entry.Duration) or 0
			if duration > 0 then
				_applyWindow(host, tostring(windowKey), duration, entry.SlowMove == true, _resolveCharacter(host, nil))
				applied = true
			end
		end
	end
	return applied
end

--[[
	清理目标上技能 Buff 窗与控速 Attribute
	@param target any - Player 或 Model
]]
function SkillBuffUtil.Clear(target: any)
	local host = _resolveHost(target)
	if not host then
		return
	end
	local folder = host:FindFirstChild(WINDOW_FOLDER)
	if folder then
		folder:Destroy()
	end
	local map = _active[host]
	if map then
		for _, info in pairs(map) do
			if info.slowMove then
				if host:IsA("Player") then
					host:SetAttribute(SLOW_ATTR, nil)
				elseif info.character then
					info.character:SetAttribute(SLOW_ATTR, nil)
				elseif host:IsA("Model") then
					host:SetAttribute(SLOW_ATTR, nil)
				end
			end
		end
	end
	_active[host] = nil
end

--[[
	查询未过期 RuntimeWindow 到期时间
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
	施法者进入 ControlOpenState：叠 Self 向 buffs
	@param plr Player? - 施法者；nil 则跳过
	@param skillId number? - skillConf ID；nil 则跳过
	@param _casterCtx any? - 预留施法上下文；本迭代忽略
]]
function SkillBuffUtil.ApplyBuffsFromSkillForCaster(plr: Player?, skillId: number?, _casterCtx: any?)
	if not plr or not skillId then
		return
	end
	_applyBuffsForTarget(plr, skillId, SkillEffectTarget.Self, plr.Character)
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
	命中后对防御方叠 Enemy 向 buffs
	@param defenderModel Model? - 防御方角色；nil 则跳过
	@param skillId number? - skillConf ID；nil 则跳过
	@param _casterCtx any? - 预留施法上下文；本迭代忽略
]]
function SkillBuffUtil.ApplySkillBuffsToDefender(defenderModel: Model?, skillId: number?, _casterCtx: any?)
	if not defenderModel or not skillId then
		return
	end
	_applyBuffsForTarget(defenderModel, skillId, SkillEffectTarget.Enemy, defenderModel)
end

--[[
	从 CombatWorld 注销（幂等；一般仅测试）
]]
function SkillBuffUtil.destroy()
	if _worldHandle then
		_worldHandle:Disconnect()
		_worldHandle = nil
	end
	_worldTickId = nil
end

-- 兼容旧名
SkillBuffUtil.Shutdown = SkillBuffUtil.destroy

--[[
	清理过期 RuntimeWindow 与控速 Attribute（由 CombatWorld Phase.StatusEffect 每帧调用）
]]
function SkillBuffUtil.TickSkillBuffRuntime()
	if not _combatEnabled() then
		return
	end
	local now = Workspace:GetServerTimeNow()
	for host, map in pairs(_active) do
		if not host or not host.Parent then
			_active[host] = nil
		else
			local stillSlow = false
			for windowKey, info in pairs(map) do
				if type(info) == "table" and (info.expireAt or 0) <= now then
					local nv = info.nv
					if nv and nv.Parent then
						nv:Destroy()
					end
					map[windowKey] = nil
				elseif type(info) == "table" and info.slowMove then
					stillSlow = true
				end
			end
			if not stillSlow then
				if host:IsA("Player") then
					host:SetAttribute(SLOW_ATTR, nil)
				elseif host:IsA("Model") then
					host:SetAttribute(SLOW_ATTR, nil)
				end
			end
			if next(map) == nil then
				_active[host] = nil
			end
		end
	end
end

--[[
	挂接 CombatWorld StatusEffect Tick（幂等）。只 register，不调用 CombatWorld.Init。
]]
function SkillBuffUtil.Init()
	if _worldHandle then
		return
	end
	local tickId = CombatWorld.allocId("SkillBuffRuntime")
	_worldTickId = tickId
	_worldHandle = CombatWorld.register(tickId, function(_deltaTime: number)
		SkillBuffUtil.TickSkillBuffRuntime()
	end, CombatWorld.Phase.StatusEffect)
end

return SkillBuffUtil
