local module = {}

module.Slot = {
	Upper = "Upper",
	FullBody = "FullBody",
	React = "React",
}

module.BlendPolicy = {
	Override = "Override",
	Overlay = "Overlay",
	FacingOnly = "FacingOnly",
	React = "React",
}

--[[
	在指定 Slot 播放动画
	@param character Model - 角色
	@param options table - { slot, animationName, ownerId?, speed?, fadeIn?, fadeOut?, weight?, blendPolicy?, priority?, looped?, acquireGate?, ... }
	@return table? - LayerHandle；失败 nil
]]
function module.Play(character: Model, options: any): any?
end

--[[
	停止 handle 对应播放
	@param handle table? - Play 返回值
	@param fadeOut number? - 淡出秒数
	@return boolean - 是否执行了停止
]]
function module.Stop(handle: any?, fadeOut: number?): boolean
end

--[[
	停止角色某 Slot 当前播放
	@param character Model - 角色
	@param slot string - Upper/FullBody/React
	@param fadeOut number? - 淡出秒数
	@return boolean - 是否有轨被停
]]
function module.StopSlot(character: Model, slot: string, fadeOut: number?): boolean
end

--[[
	调整当前 handle 权重
	@param handle table - Play 返回值
	@param weight number - 目标权重
	@param fade number? - 过渡秒数
	@return boolean - 是否成功
]]
function module.AdjustWeight(handle: any, weight: number, fade: number?): boolean
end

--[[
	Slot 是否有活跃播放
	@param character Model - 角色
	@param slot string - Slot 名
	@return boolean
]]
function module.IsSlotPlaying(character: Model, slot: string): boolean
end

--[[
	跳转 handle 轨时间（技能预测软合并）
	@param handle table - Play 返回值
	@param timePosition number - 秒
	@return boolean
]]
function module.SetTimePosition(handle: any, timePosition: number): boolean
end

--[[
	取 handle 缓存轨
	@param handle table - Play 返回值
	@return AnimationTrack?
]]
function module.GetTrack(handle: any): AnimationTrack?
end

return module