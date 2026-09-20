--[[
	任务管理器模块
	用于管理动画播放过程中的任务调度
]]

local module = {}
module.__index = module

type remove = () -> nil

export type manager = {
	register: (self, frame: number | boolean, fn: () -> nil) -> remove,
	onEnd: (self, fn: () -> nil) -> remove,
}

--[[
	创建新的任务管理器
	@return manager - 任务管理器实例
]]
function module.new(): manager
	return setmetatable({tasks = {}}, module)
end

--[[
	克隆任务列表（用于重新播放）
	@return table - 克隆的任务列表
]]
function module:clone()
	self.cloned = {}
	for i, v in self.tasks do
		self.cloned[i] = v
	end
	
	return self.cloned
end

--[[
	注册任务
	@param frame: number | boolean - 执行帧数（true 表示在动画结束时执行）
	@param fn: () -> nil - 要执行的函数
	@param cloneOnly: boolean? - 是否只添加到克隆列表
	@return remove - 用于移除任务的函数
]]
function module:register(frame: number | boolean, fn: () -> nil, cloneOnly: boolean?)
	if not cloneOnly then
		self.tasks[frame] = self.tasks[frame] or {}
		table.insert(self.tasks[frame], fn)
	end
	
	if self.cloned then
		self.cloned[frame] = self.cloned[frame] or {}
		table.insert(self.cloned[frame], fn)
	end

	return function()
		if not cloneOnly then
			table.remove(self.tasks, table.find(self.tasks, fn))
		end
		
		if self.cloned then
			table.remove(self.cloned[frame], table.find(self.cloned[frame], fn))
		end
	end
end

--[[
	注册动画结束时的任务
	@param ... - 传递给 register 的参数
	@return remove - 用于移除任务的函数
]]
function module:onEnd(...)
	return self:register(true, ...)
end

--[[
	执行任务列表中的所有任务
	@param tasks: {[number]: () -> nil}? - 任务列表
]]
function module.run(tasks)
	for _, fn: () -> nil in tasks or {} do
		task.spawn(fn)
	end
end

return module