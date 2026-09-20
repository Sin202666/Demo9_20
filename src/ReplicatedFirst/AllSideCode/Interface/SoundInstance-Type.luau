local SoundModuleType = require(script.Parent["SoundModule-Type"])

local module = {}

export type SoundData = SoundModuleType.SoundData

--[[
	创建新声音实例（类方法）；同一 SoundTag 已存在则复用
	@param soundData SoundData - 须含非空 SoundName；SoundTag 缺省时自动生成
	@return typeof(module)? - 声音实例；客户端未就绪 / 缺名 / 无模板时 nil
]]
function module:new(soundData: SoundData): typeof(module)?
end

--[[
	播放声音（非循环音效播放结束后自动结束实例并归还池）
	@param fadeInTime number? - 渐入时间（秒，默认 0.1）
	@return nil
]]
function module:playSound(fadeInTime: number?)
end

--[[
	停止声音（渐隐后可选销毁；循环音效默认保留实例）
	@param fadeTime number? - 渐出时间（秒，默认 0.1）
	@param destroyAfter boolean? - 停止后是否销毁（nil 时非循环 true、循环 false）
	@return nil
]]
function module:stopSound(fadeTime: number?, destroyAfter: boolean?)
end

--[[
	结束声音实例（停播并从标签表移除；非循环音归还 Sound / 3D 宿主池）
	@return nil
]]
function module:destroy()
end

--[[
	兼容旧 API：等价于 destroy()
	@return nil
]]
function module:destroySound()
end

--[[
	根据标签查找声音实例（模块方法）
	@param soundTag string - 创建时指定或自动生成的 SoundTag
	@return typeof(module)? - 活跃实例；无标签或未找到时 nil
]]
function module:GetSoundByTag(soundTag: string): typeof(module)?
end

--[[
	根据声音名称查找所有声音实例（模块方法）
	@param soundName string - 与 SoundData.SoundName 一致
	@return { typeof(module) } - 匹配的活跃实例列表
]]
function module:GetSoundByName(soundName: string): { typeof(module) }
end

--[[
	设置当前实例播放速度
	@param playSpeed number - 绝对播放速度，1 为模板原速
	@return nil
]]
function module:setPlaySpeed(playSpeed: number)
end

--[[
	设置音效组音量（模块方法，支持渐变；同组未完成渐变会被取消）
	@param soundGroupName string - SoundService 下 SoundGroup.Name（如 BGM / EFFECT）
	@param volume number - 目标音量
	@param fadeTime number? - 渐变秒数；nil 或 <=0 时立即设置
	@return nil
]]
function module:SetSoundGroupVolume(soundGroupName: string, volume: number, fadeTime: number?)
end

--[[
	设置音效组内活跃实例播放速度倍率（相对各实例原始速度，避免累乘）
	@param soundGroupName string - SoundService 下 SoundGroup.Name
	@param playSpeed number - 播放速度倍率
	@return nil
]]
function module:SetSoundGroupPlaySpeed(soundGroupName: string, playSpeed: number)
end

return module
