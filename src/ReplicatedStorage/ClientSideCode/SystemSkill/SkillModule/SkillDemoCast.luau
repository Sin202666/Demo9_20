--[[
	Module: SkillDemoCast
	Description: 最小主动技样例（无 Hitbox）。验证槽位输入、服权 CF、跨槽打断、同轨衔接。
	Author: Dev-Framework
	Created: 2026-07-30
	Last Modified: 2026-07-30

	状态：Startup -> Active -> Recovery -> Finished
	Action：Animation(RollForward) + LockMovement(speedMultiplier=0)
	同轨约定：故意与 NewRoll 共用 RollForward，验证跨槽打断后冲刺可完整重播（TrackOwner + Play 强制重开）。
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local ElementTp = Utils.EnumMgr.ElementTp
local EVT = require(script.Parent.Parent.BaseSkill.SkillEventConst)

local module = {}

module.skillTotalTime = 0.9
module.visualFadeoutTime = 0.5
module.skillElementType = ElementTp.None

module.InitialState = "Startup"
module.ControlOpenState = "Recovery"

module.States = {
	Startup = {
		Duration = 0,
		OnEnterClient = nil,
		OnEnterServer = nil,
		OnExitClient = nil,
		OnExitServer = nil,
	},
	Active = {
		Duration = 0.45,
		OnEnterClient = nil,
		OnEnterServer = nil,
		OnExitClient = nil,
		OnExitServer = nil,
	},
	Recovery = {
		Duration = 0.35,
		OnEnterClient = nil,
		OnEnterServer = nil,
		OnExitClient = nil,
		OnExitServer = nil,
	},
	Finished = { Duration = 0, IsTerminal = true },
	Interrupted = { Duration = 0, IsTerminal = true },
}

module.Transitions = {
	{ From = "Startup", To = "Active", Event = EVT.StateTimeout },
	{ From = "Active", To = "Recovery", Event = EVT.StateTimeout },
	{ From = "Recovery", To = "Finished", Event = EVT.StateTimeout },
	{ From = "Startup", To = "Interrupted", Event = EVT.Interrupt },
	{ From = "Active", To = "Interrupted", Event = EVT.Interrupt },
	{ From = "Recovery", To = "Interrupted", Event = EVT.Interrupt },
	{ From = "Startup", To = "Finished", Event = EVT.ForceFinish },
	{ From = "Active", To = "Finished", Event = EVT.ForceFinish },
	{ From = "Recovery", To = "Finished", Event = EVT.ForceFinish },
}

module.hitboxConfig = {}

module.AnimateList = {
	"RollForward",
}

module.Action = {
	{
		action = "Animation",
		startTime = 0,
		overTime = 0.8,
		animationName = "RollForward",
		animationSpeed = 1,
		animationPriority = Enum.AnimationPriority.Action,
		animationFadeTime = 0.1,
	},
	{
		action = "LockMovement",
		startTime = 0,
		overTime = 0.8,
		speedMultiplier = 0,
	},
}

return module