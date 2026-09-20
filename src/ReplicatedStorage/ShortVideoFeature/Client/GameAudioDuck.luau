--[[
	Module: GameAudioDuck
	Description: 2D 短视频期间将 SoundService 下各 SoundGroup 音量淡出到 0，退出后淡回原值
	Author: 林奥宇
	Created: 2026-08-13
	Last Modified: 2026-08-13

	不依赖 Utils：直接 Tween SoundGroup.Volume，与 SettingManager 同走音效组模型。
	仅应在 displayMode=screen 时 Duck；Close 时 Restore。
]]

local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local Constants = require(script.Parent.Parent.Shared.Constants)

local GameAudioDuck = {}

local _active = false
local _savedVolumes: { [SoundGroup]: number } = {}
local _tweens: { Tween } = {}

--[[
	取消进行中的音量 Tween
]]
local function cancelTweens()
	for _, tw in ipairs(_tweens) do
		pcall(function()
			tw:Cancel()
		end)
	end
	table.clear(_tweens)
end

--[[
	对指定 SoundGroup 渐变到目标音量
	@param group SoundGroup - 音效组
	@param volume number - 目标 Volume
	@param fadeSec number - 时长秒
]]
local function tweenGroup(group: SoundGroup, volume: number, fadeSec: number)
	if fadeSec <= 0 then
		group.Volume = volume
		return
	end
	local tw = TweenService:Create(group, TweenInfo.new(fadeSec, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Volume = volume,
	})
	table.insert(_tweens, tw)
	tw:Play()
end

--[[
	是否正在压制游戏音效
	@return boolean
]]
function GameAudioDuck.IsActive(): boolean
	return _active
end

--[[
	淡出所有 SoundGroup 到 0（保存当前音量以便恢复）
	@param fadeSec number? - 覆盖默认淡变秒
]]
function GameAudioDuck.Duck(fadeSec: number?)
	local fade = if typeof(fadeSec) == "number" then fadeSec else (Constants.AudioDuck and Constants.AudioDuck.FadeSec) or 0.5
	cancelTweens()
	if not _active then
		table.clear(_savedVolumes)
		for _, child in ipairs(SoundService:GetChildren()) do
			if child:IsA("SoundGroup") then
				_savedVolumes[child] = child.Volume
			end
		end
		_active = true
	end
	for group, _ in pairs(_savedVolumes) do
		if group.Parent then
			tweenGroup(group, 0, fade)
		end
	end
end

--[[
	淡回 Duck 前保存的各组音量
	@param fadeSec number? - 覆盖默认淡变秒
]]
function GameAudioDuck.Restore(fadeSec: number?)
	if not _active then
		return
	end
	local fade = if typeof(fadeSec) == "number" then fadeSec else (Constants.AudioDuck and Constants.AudioDuck.FadeSec) or 0.5
	cancelTweens()
	for group, vol in pairs(_savedVolumes) do
		if group.Parent then
			tweenGroup(group, vol, fade)
		end
	end
	table.clear(_savedVolumes)
	_active = false
end

return GameAudioDuck
