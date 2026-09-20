local module = {}

--[[
	创建冲击波效果
	@param _SpawnCF: CFrame - 初始位置
	@param _ShockLenth: number - 冲击波长度
	@param _SideOffset: number - 向两侧的位置偏移量
	@param _AngleOffset: number - 向两边的角度偏移量
	@param _StoneNum: number - 石头数量
	@param _WholeRiseTime: number - 生成时间
	@param _RiseTime: number? - 石头上升时间，默认 0.3
	@param _StayTime: number? - 石头停留时间，默认 2
	@param _DisapearTime: number? - 石头消失时间，默认 0.1
]]
function module.CreateShock(
	_SpawnCF: CFrame,
	_ShockLenth: number,
	_SideOffset: number,
	_AngleOffset: number,
	_StoneNum: number,
	_WholeRiseTime: number,
	_RiseTime: number?,
	_StayTime: number?,
	_DisapearTime: number?
)
end

--[[
	创建单侧冲击波效果
	@param _SpawnCF: CFrame - 初始位置
	@param _ShockType: string - 冲击波类型
	@param _Scale: number? - 整体尺寸缩放，默认 1
]]
function module.CreateShockOneSide(_SpawnCF: CFrame, _ShockType: string, _Scale: number?)
end

--[[
	创建石头飞行效果
	@param _SpawnCF: CFrame - 初始位置
	@param _StoneFlyType: string? - 石头飞行类型
	@param _Scale: number? - 整体尺寸缩放，默认 1
]]
function module.CreateStoneFly(_SpawnCF: CFrame, _StoneFlyType: string?, _Scale: number?)
end

--[[
	创建地裂效果
	@param _SpawnCF: CFrame - 初始位置
	@param _LandBreakType: string? - 地裂类型
	@param _Scale: number? - 整体尺寸缩放，默认 1
]]
function module.CreateLandBreak(_SpawnCF: CFrame, _LandBreakType: string?, _Scale: number?)
end

return module
