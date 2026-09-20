local module = {}

--[[
	生成普通残影
	@param _oriModel: Model - 原始模型
	@param _color: Color3? - 颜色（可选）
	@param _transPercent: number? - 透明度百分比（可选）
	@param _lifeTime: number? - 生命周期（可选）
]]
function module.Spawn_Normal_Ghost(_oriModel: Model, _color: Color3?, _transPercent: number?, _lifeTime: number?)
end

--[[
	生成多个残影
	@param _oriModel: Model - 原始模型
	@param _count: number - 数量
	@param _color: Color3? - 颜色（可选）
	@param _transPercent: number? - 透明度百分比（可选）
	@param _lifeTime: number? - 生命周期（可选）
]]
function module.Spawn_Several_Ghosts(_oriModel: Model, _count: number, _color: Color3?, _transPercent: number?, _lifeTime: number?)
end

--[[
	开启残影效果
	@param _oriModel: Model - 原始模型
	@param _color: Color3? - 颜色（可选）
	@param _transPercent: number? - 透明度百分比（可选）
	@param _lifeTime: number? - 生命周期（可选）
	@param _interval: number? - 间隔时间（可选）
]]
function module.Ghost_Shadow_On(_oriModel: Model, _color: Color3?, _transPercent: number?, _lifeTime: number?, _interval: number?)
end

--[[
	关闭残影效果
	@param _oriModel: Model - 原始模型
]]
function module.Ghost_Shadow_Off(_oriModel: Model)
end

return module
