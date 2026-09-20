local module = {}

--[[
	声音数据表
	@field SoundName string - 声音名称（必需，对应 SoundService 下 Sound 模板 Name）
	@field SoundTag string? - 声音标签（可选，默认按名称+序号生成）
	@field Is2D boolean? - 是否是 2D 声音（默认 true）
	@field Volume number? - 音量（可选，默认取模板音量）
	@field AttachPart BasePart? - 父部件（3D 跟随播放）
	@field PlayPosition Vector3? - 播放位置（3D 固定位置播放）
]]
export type SoundData = {
	SoundName: string,
	SoundTag: string?,
	Is2D: boolean?,
	Volume: number?,
	AttachPart: BasePart?,
	PlayPosition: Vector3?,
}

--[[
	停止音效数据表
	@field SoundName string? - 按名称停止（停止所有同名实例）
	@field SoundTag string? - 按标签停止（优先于 SoundName）
	@field FadeTime number? - 渐出时间（秒，默认 0.1）
	@field DestroyAfter boolean? - 停止后是否销毁实例（循环音效默认 false）
]]
export type StopData = {
	SoundName: string?,
	SoundTag: string?,
	FadeTime: number?,
	DestroyAfter: boolean?,
}

--[[
	向指定玩家发送播放音效事件（仅服务端）
	@param player Player - 目标玩家；须仍在游戏中
	@param soundData SoundData - 播放载荷，须含非空 SoundName
	@return nil
]]
function module:PlaySound(player: Player, soundData: SoundData)
end

--[[
	向指定玩家发送停止音效事件（仅服务端）
	@param player Player - 目标玩家；须仍在游戏中
	@param stopData StopData - 停止载荷，须含非空 SoundTag 或 SoundName
	@return nil
]]
function module:StopSound(player: Player, stopData: StopData)
end

--[[
	播放本地音效（仅客户端 Bindable）
	@param soundData SoundData - 播放载荷，须含非空 SoundName
	@return nil
]]
function module:PlaySoundLocal(soundData: SoundData)
end

--[[
	停止本地音效（仅客户端 Bindable）
	@param stopData StopData - 停止载荷，须含非空 SoundTag 或 SoundName
	@return nil
]]
function module:StopSoundLocal(stopData: StopData)
end

return module
