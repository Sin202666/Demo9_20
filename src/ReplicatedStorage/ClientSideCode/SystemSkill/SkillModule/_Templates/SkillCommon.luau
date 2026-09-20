--[[
	Module: SkillCommon
	Description: 技能模块通用工具（Meteor 等样板依赖的最小集：体量缩放、魔杖尖、本地 3D 音效）
	Author: Dev-Framework
	Created: 2026-07-30
	Last Modified: 2026-08-12

	功能：
	- scaleBandFromData / bandScaleOptsFromSkillData：按 skillPower(1～10) 与 skillConf.Size×Band 算视觉/判定缩放
	- resolveWandTipFromCharacter：解析角色「当前手持」下「魔杖尖端」
	- playSoundLocal3D：本地 3D 点源音效

	与完整 RP17 SkillCommon 的关系：
	- 本文件仅为框架样板所需子集
	- 直线弹道运动请用 `_Templates/Projectile/ProjectileLinearRuntime`（见 SkillDemoProjectile）
	- 勿在业务里直接 require 长路径；SkillModule 用 require(script.Parent._Templates.SkillCommon)

	帧循环禁令（一期 A / CombatWorld）：
	- 禁止：SkillModule 内 RunService.Heartbeat:Connect 做逻辑 Tick
	- 允许：Utils.CombatWorld.register(id, fn, CombatWorld.Phase.*)；句柄写入 runData.runEvent[key]
	- 允许：纯表现 RenderStepped（尾迹跟随等），勿承载 Hitbox/伤害
	- 样板：Meteor1（Fall/Hitbox）、SpaceSkill1（Presentation）、SkillDemoProjectile（Linear）

	加载方式：
		local SC = require(script.Parent._Templates.SkillCommon)
		local CombatWorld = Utils.CombatWorld

	示例：
		local scale = SC.scaleBandFromData(Data, SC.bandScaleOptsFromSkillData(Data))
		SC.playSoundLocal3D("音效-技能-陨石术-爆炸", pos)
		-- local h = CombatWorld.register(CombatWorld.allocId("MySkillTick"), function(dt) end, CombatWorld.Phase.SkillRuntime)
		-- runData.runEvent["MyTick"] = h
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local CfgFind = Utils.CfgFind
local EnumMgr = Utils.EnumMgr
local SoundModule = Utils.SoundModule

local SkillCommon = {}

export type BandScaleOpts = {
	min: number?,
	max: number?,
}

local MAGIC_POWER_MIN = 1
local MAGIC_POWER_MAX = 10

--[[
	skillPower 1→0、10→1 的线性归一；非法/缺省按 1
	@param skillPower number? - 魔法强度
	@return number - ∈ [0, 1]
]]
local function _bandNorm01FromSkillPower(skillPower: number?): number
	local p = tonumber(skillPower)
	if p == nil then
		p = MAGIC_POWER_MIN
	end
	p = math.clamp(p, MAGIC_POWER_MIN, MAGIC_POWER_MAX)
	return (p - MAGIC_POWER_MIN) / (MAGIC_POWER_MAX - MAGIC_POWER_MIN)
end

--[[
	skillConf.Size：number 或 {s}/{sMin,sMax}
	@param sizeAny any - Size 字段
	@return number?, number? - lo, hi；非法 nil
]]
local function _skillConfSizeExtents(sizeAny: any): (number?, number?)
	if sizeAny == nil then
		return nil, nil
	end
	local n = tonumber(sizeAny :: any)
	if n and n == n then
		return n, n
	end
	if type(sizeAny) == "table" then
		local s1 = tonumber((sizeAny :: any)[1])
		local s2 = tonumber((sizeAny :: any)[2])
		if s1 and s1 == s1 then
			if s2 and s2 == s2 then
				return s1, s2
			end
			return s1, s1
		end
	end
	return nil, nil
end

--[[
	按魔法强度在 [min,max] 上线性插值体量缩放
	@param Data any - BaseSkill 实例（读 skillPower）
	@param opts BandScaleOpts? - min/max，缺省均为 1
	@return number - 最终缩放
]]
function SkillCommon.scaleBandFromData(Data: any, opts: BandScaleOpts?): number
	local o = opts or {}
	local minS = o.min or 1
	local maxS = o.max or 1
	local t = _bandNorm01FromSkillPower(Data and Data.skillPower)
	return minS + (maxS - minS) * t
end

--[[
	从 skillConf 读 Size×Band 得到 scaleBandFromData 的 min/max
	Band 非法按 {1,1}；无 Size 按 1
	@param Data any - 含 skillID
	@return BandScaleOpts
]]
function SkillCommon.bandScaleOptsFromSkillData(Data: any): BandScaleOpts
	local id = tonumber(Data and Data.skillID)
	if not id or id <= 0 then
		return { min = 1, max = 1 }
	end
	local cfg = CfgFind.FindCfgByID(id, EnumMgr.ItemType.Skill)
	if not cfg then
		return { min = 1, max = 1 }
	end
	local szLo, szHi = _skillConfSizeExtents(cfg.Size)
	if not szLo then
		szLo = 1
		szHi = 1
	elseif not szHi then
		szHi = szLo
	end
	local bandAny = cfg.Band
	local b1, b2 = 1, 1
	if type(bandAny) == "table" then
		b1 = tonumber(bandAny[1]) or 1
		b2 = tonumber(bandAny[2]) or b1
	end
	return { min = b1 * szLo, max = b2 * szHi }
end

--[[
	解析角色当前手持武器的魔杖尖端（无则 nil，尾迹等表现跳过）
	@param character Model? - 施法者模型
	@return Instance? - 「魔杖尖端」实例
]]
function SkillCommon.resolveWandTipFromCharacter(character: Model?): Instance?
	if not character then
		return nil
	end
	local weaponFolder = character:FindFirstChild("当前手持")
	local weapon = weaponFolder and weaponFolder:FindFirstChildOfClass("Model")
	if not weapon then
		return nil
	end
	return weapon:FindFirstChild("魔杖尖端")
end

--[[
	在世界坐标播放本地 3D 音效
	@param soundName string - 音效名
	@param position Vector3 - 世界坐标
]]
function SkillCommon.playSoundLocal3D(soundName: string, position: Vector3)
	if not soundName or not position then
		return
	end
	if SoundModule then
		SoundModule:PlaySoundLocal({
			SoundName = soundName,
			PlayPosition = position,
			Is2D = false,
		})
	end
end

return SkillCommon