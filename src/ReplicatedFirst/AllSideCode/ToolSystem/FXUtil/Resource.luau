--[[
	Module: FXUtil/Resource
	Description: Debris 与音效播放
	Author: LinAoyu
	Created: 2024-01-01
	Last Modified: 2026-07-02
]]

return function(FXUtil)

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")

local SoundModule = Utils.SoundModule
-- ============================================
-- 资源管理函数 (Resource Management Functions)
-- ============================================

--[[
	清除资源（延迟销毁）
	
	@param instance Instance - 要销毁的实例
	@param delay number? - 延迟时间（可选，默认0）
--]]
function FXUtil.Debris(instance: Instance, delayTime: number?)
	delayTime = delayTime or 0

	task.delay(delayTime, function()
		Debris:AddItem(instance, 0)
	end)
end

-- ============================================
-- 音效播放函数 (Sound Playback Functions)
-- ============================================

--[[
	播放音效（支持服务器和客户端）
	
	@param data {[string]: any} - 数据表（包含Releaser等信息）
	@param soundName string - 音效名称
	@param playTimes number? - 播放次数（可选）
	@param playDis number? - 播放距离（可选）
	@param pos Vector3? - 位置（可选）
	@param isFadeIn boolean? - 是否淡入（可选）
	@param fadeTime number? - 淡入时间（可选）
	@param maxNum number? - 最大数量（可选）
--]]
function FXUtil.PlaySound(data: {[string]: any}, soundName: string, playTimes: number?, playDis: number?, pos: Vector3?, isFadeIn: boolean?, fadeTime: number?, maxNum: number?)
	local soundData = {
		SoundName = soundName,
		Is2D = pos == nil,
		PlayPosition = pos,
	}

	if RunService:IsServer() then
		for _, player in pairs(Players:GetPlayers()) do
			SoundModule:PlaySound(player, soundData)
		end
	else
		if data["Releaser"] and data["Releaser"] ~= Players.LocalPlayer then
			return
		end

		SoundModule:PlaySoundLocal(soundData)
	end
end
end