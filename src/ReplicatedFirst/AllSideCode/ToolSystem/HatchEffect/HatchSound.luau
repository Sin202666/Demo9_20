--[[
	Module: HatchEffect/HatchSound
	Description: 抽蛋表现音效播放
	Author: 林奥宇
	Created: 2026-01-29
	Last Modified: 2026-09-01

	由 HatchBoxEffect / HatchRewardEffect 内部调用，勿经 Utils 直接使用。
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local SoundModule = Utils.SoundModule

local HatchSound = {}

local RESULT_SOUND_XYD_MIN = 1
local RESULT_SOUND_XYD_MAX = 5

--[[
	播放 2D 本地音效（SoundModule:PlaySoundLocal）

	@param soundName string - SoundModule 音效名（如「抽蛋_掉落」）
	@return nil - 无返回值
]]
function HatchSound.play(soundName: string)
	SoundModule:PlaySoundLocal({
		SoundName = soundName,
		Is2D = true,
	})
end

--[[
	按本批最高稀有度播放结果展示音效。
	xyd 会被 clamp 到 1~5 后拼接「音效-抽蛋-稀有度{n}」。

	@param maxXyd number - 本批最高稀有度（与 EnumMgr.Rare 对齐）
	@return nil - 无返回值
]]
function HatchSound.playResult(maxXyd: number)
	local xyd = math.clamp(maxXyd, RESULT_SOUND_XYD_MIN, RESULT_SOUND_XYD_MAX)
	HatchSound.play("音效-抽蛋-稀有度" .. xyd)
end

return HatchSound
