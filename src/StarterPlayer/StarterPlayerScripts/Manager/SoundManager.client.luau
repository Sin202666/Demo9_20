--[[
	Module: SoundManager
	Description: 客户端音效事件路由（Remote / Bindable → SoundInstance）
	Author: 林奥宇
	Created: 2026-01-19
	Last Modified: 2026-07-02

	功能：
	- 监听 PLAY_SOUND / STOP_SOUND 事件
	- 创建 SoundInstance 并播放 / 停止
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local NetMsg = Utils.NetMsg
local NetWork = Utils.NetWork
local SoundInstance = Utils.SoundInstance
local Log = Utils.Log

--[[
	将停止参数规范为 StopData 表（兼容旧版 string + fadeTime 传参）
	@param stopDataOrName any - StopData 表，或旧版音效名 string
	@param fadeTime number? - 旧版淡出秒数；stopDataOrName 为表时忽略
	@return table - 规范化后的 StopData（SoundName / FadeTime 等字段）
]]
local function _normalizeStopData(stopDataOrName: any, fadeTime: number?)
	if type(stopDataOrName) == "table" then
		return stopDataOrName
	end
	return {
		SoundName = stopDataOrName,
		FadeTime = fadeTime,
	}
end

--[[
	播放音效：创建实例并播放
	@param playSoundData any - SoundData（SoundName / SoundTag 等播放字段）
]]
local function _playSound(playSoundData: any)
	local sound = SoundInstance:new(playSoundData)
	if sound then
		sound:playSound()
	else
		Log.warn("SoundInstance 未找到，无法播放音效")
	end
end

--[[
	停止音效：按 SoundTag 优先，否则按 SoundName 批量停止
	@param stopSoundData any - StopData 或旧版音效名；内部再走 _normalizeStopData
]]
local function _stopSound(stopSoundData: any)
	local stopData = _normalizeStopData(stopSoundData)
	local soundName = stopData.SoundName
	local soundTag = stopData.SoundTag
	local fadeTime = stopData.FadeTime
	local destroyAfter = stopData.DestroyAfter

	local sound = SoundInstance:GetSoundByTag(soundTag)
	if sound then
		sound:stopSound(fadeTime, destroyAfter)
		return
	end

	if not soundName then
		return
	end

	local soundList = SoundInstance:GetSoundByName(soundName)
	for _, instance in soundList do
		instance:stopSound(fadeTime, destroyAfter)
	end
end

--[[
	Remote / Bindable 停止回调（兼容旧版多参数）
	@param stopDataOrName any - StopData 表或旧版音效名
	@param _legacyArg boolean? - 旧版占位参数，忽略
	@param legacyFadeTime number? - 旧版淡出秒数
]]
local function _onStopSound(stopDataOrName: any, _legacyArg: boolean?, legacyFadeTime: number?)
	_stopSound(_normalizeStopData(stopDataOrName, legacyFadeTime))
end

NetWork.RegisterClientRemoteEvent(NetMsg.PLAY_SOUND, _playSound)
NetWork.RegisterBindableEvent(NetMsg.PLAY_SOUND, _playSound)

NetWork.RegisterClientRemoteEvent(NetMsg.STOP_SOUND, _onStopSound)
NetWork.RegisterBindableEvent(NetMsg.STOP_SOUND, _onStopSound)
