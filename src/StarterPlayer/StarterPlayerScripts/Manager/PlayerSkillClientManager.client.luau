--[[
	Module: PlayerSkillClientManager
	Description: 客户端玩家技能启动编排（SystemInput + Remote 转发 SystemPlayerSkill；击退走 CharacterMotion）
	Author: 林奥宇
	Created: 2026-07-29
	Last Modified: 2026-09-01

	职责：
	- 门控 GameConfig「技能系统.启用」
	- CombatWorld.Init（客侧目前仅此处启动）
	- SystemInput 默认技能键 + OnAction → SystemPlayerSkill.OnSlotPressed
	- Register RELEASE / FIX_SKILL_TIME / STOP_SKILL / SYN_SKILL_EFFECT → System
	- SYN_PLAYER_CFRAME → CharacterMotion.ApplyKnockback / RubberbandTo（不进 SystemPlayerSkill）
	- PlayerAimSync.initClient；脚本加载时同步 SystemPlayerSkill.Init

	配置（GameConfig.技能系统）：
	- 启用：false 时本 Manager 不运行
	- 启用冲刺技能：false 时不监听冲刺槽/冲刺键
	- 技能默认快捷键：槽 1/2（默认 e/r）；写入 SystemInput.SetBinding
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local SystemGameConfig = Utils.SystemGameConfig
local CombatWorld = Utils.CombatWorld

if SystemGameConfig.GetValue({ "技能系统", "启用" }) == false then
	return
end

CombatWorld.Init()

local EnumMgr = Utils.EnumMgr
local NetWork = Utils.NetWork
local NetMsg = Utils.NetMsg
local LocalPlayer = Utils.LocalPlayer
local CharacterMotion = Utils.CharacterMotion
local SystemInput = Utils.SystemInput
local SystemPlayerSkill = Utils.SystemPlayerSkill
local PlayerAimSync = Utils.PlayerAimSync

local DASH_ENABLED = SystemGameConfig.GetValue({ "技能系统", "启用冲刺技能" }) ~= false
local SkillSlot = EnumMgr.SkillSlot

PlayerAimSync.initClient()
script.AncestryChanged:Connect(function()
	if not script.Parent then
		PlayerAimSync.destroyClient()
	end
end)

local globalConfig = SystemGameConfig.Get()
local skillConfig = globalConfig and globalConfig["技能系统"]
local dashKeyName = (skillConfig and skillConfig["冲刺快捷键"]) or "q"
local dashKeyCode = Enum.KeyCode[string.upper(dashKeyName)] or Enum.KeyCode.Q

local GAMEPAD_SLOT_KEYS: { Enum.KeyCode } = {
	Enum.KeyCode.ButtonB,
	Enum.KeyCode.ButtonX,
	Enum.KeyCode.DPadUp,
	Enum.KeyCode.DPadRight,
	Enum.KeyCode.DPadDown,
	Enum.KeyCode.DPadLeft,
}

local rawSlotKeys = skillConfig and skillConfig["技能默认快捷键"]

--[[
	写入技能域默认绑定（供 Init 与 ResetBindingsToDefault）
	@param schemeFilter string? - 仅重放该 Scheme；nil 为全部
]]
local function _applySkillDefaultBindings(schemeFilter: string?)
	local applyKbm = schemeFilter == nil or schemeFilter == SystemInput.Scheme.KeyboardMouse
	local applyPad = schemeFilter == nil or schemeFilter == SystemInput.Scheme.Gamepad

	if type(rawSlotKeys) == "table" then
		for slotIndex, keyName in pairs(rawSlotKeys) do
			if type(slotIndex) == "number" and type(keyName) == "string" then
				if applyKbm then
					local kc = Enum.KeyCode[string.upper(keyName)]
					if kc then
						SystemInput.SetBinding(
							SystemInput.SkillSlotActionId(slotIndex),
							kc,
							SystemInput.Scheme.KeyboardMouse
						)
					end
				end
				if applyPad then
					local padKey = GAMEPAD_SLOT_KEYS[slotIndex]
					if padKey then
						SystemInput.SetBinding(
							SystemInput.SkillSlotActionId(slotIndex),
							padKey,
							SystemInput.Scheme.Gamepad
						)
					end
				end
			end
		end
	end
	if DASH_ENABLED then
		if applyKbm then
			SystemInput.SetBinding(SystemInput.ActionIds.SkillDash, dashKeyCode, SystemInput.Scheme.KeyboardMouse)
		end
		if applyPad then
			SystemInput.SetBinding(SystemInput.ActionIds.SkillDash, Enum.KeyCode.ButtonL2, SystemInput.Scheme.Gamepad)
		end
	end
end

_applySkillDefaultBindings(nil)
SystemInput.RegisterDefaultProvider(_applySkillDefaultBindings)

if type(rawSlotKeys) == "table" then
	for slotIndex, keyName in pairs(rawSlotKeys) do
		if type(slotIndex) == "number" and type(keyName) == "string" then
			local capturedSlot = slotIndex
			SystemInput.OnAction(SystemInput.SkillSlotActionId(capturedSlot), function(phase: string)
				if phase ~= SystemInput.Phase.Started then
					return
				end
				SystemPlayerSkill.OnSlotPressed(capturedSlot)
			end)
		end
	end
end
if DASH_ENABLED then
	SystemInput.OnAction(SystemInput.ActionIds.SkillDash, function(phase: string)
		if phase ~= SystemInput.Phase.Started then
			return
		end
		SystemPlayerSkill.OnSlotPressed(SkillSlot.Dash)
	end)
end

NetWork.RegisterClientRemoteEvent(NetMsg.RELEASE_GROUP_SKILL, function(slotIndex: number, accepted: boolean)
	SystemPlayerSkill.OnReleaseAck(slotIndex, accepted)
end)

NetWork.RegisterClientRemoteEvent(NetMsg.SYN_PLAYER_CFRAME, function(payload: any)
	if type(payload) ~= "table" then
		return
	end
	local character = LocalPlayer.Character
	if not character then
		return
	end
	if payload.kind == "ApplyKnockback" then
		CharacterMotion.ApplyKnockback(character, {
			id = payload.id,
			direction = payload.direction,
			planarVelocity = payload.planarVelocity,
			speed = payload.speed,
			durationSec = payload.durationSec,
			decay = payload.decay,
			massScale = payload.massScale,
			collisionPolicy = payload.collisionPolicy,
			airMultiplier = payload.airMultiplier,
			interruptDrive = payload.interruptDrive,
			maxDistance = payload.maxDistance,
			composeCap = payload.composeCap,
		})
		return
	end
	if typeof(payload.targetPos) ~= "Vector3" then
		return
	end
	CharacterMotion.RubberbandTo(character, payload.targetPos, payload.durationSec)
end)

NetWork.RegisterClientRemoteEvent(NetMsg.FIX_SKILL_TIME, function(slotIndex: number, serverTime: number, _unused: any?, skillCastId: string?)
	SystemPlayerSkill.OnFixSkillTime(slotIndex, serverTime, _unused, skillCastId)
end)

NetWork.RegisterClientRemoteEvent(NetMsg.STOP_SKILL, function(payload: any)
	SystemPlayerSkill.OnStopSkill(payload)
end)

NetWork.RegisterClientRemoteEvent(NetMsg.SYN_SKILL_EFFECT, function(payload: any)
	SystemPlayerSkill.OnSynSkillEffect(payload)
end)

SystemPlayerSkill.Init()
