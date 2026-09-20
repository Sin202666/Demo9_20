--[[
	Module: ConfigPrepare
	Description: 对导表 ConfigInstance 做键名 remap 与深度 freeze；不修改生成物文件本身
	Author: LinAoyu
	Created: 2026-07-28
	Last Modified: 2026-07-28

	功能：
	- 按 ConfigInstance.key 将各配置行的数字列下标转为字段名（如 ZhName、tp）
	- 对配置根表、各子表、配置行及嵌套表递归 table.freeze，保证只读
	- Apply / Get 幂等：重复调用返回同一已处理表引用

	与相关模块的关系：
	- ConfigInstance：工具打包生成的纯数据，本模块不得也不应改其源文件
	- UtilsSystem：解析 Utils.ConfigInstance 时调用本模块 Get，业务侧始终拿到已处理表
	- CfgFind：只负责查询与索引，依赖 Utils.ConfigInstance 已完成 Prepare

	调用约束：
	- 业务代码不要直接 require 本模块；统一通过 Utils.ConfigInstance
	- 本模块直接 require 同目录 ConfigInstance，避免经 Utils 形成循环依赖
	- Apply 会原地改写导表表内容并 freeze；之后任何写入字段都会报错

	加载方式（框架内部，业务勿仿）：
		-- UtilsSystem 在加载 ConfigInstance 键时：
		local ConfigPrepare = require(...ToolBasic.ConfigPrepare)
		local config = ConfigPrepare.Get()

	使用示例：
		-- 业务侧（推荐）
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local ConfigInstance = Utils.ConfigInstance
		local row = ConfigInstance.itemdataConf[1]  -- 字段名为 ZhName 等，且只读

		-- 仅框架 / 测试：幂等再准备
		-- ConfigPrepare.Apply(rawConfigInstance)
]]

local ConfigPrepare = {}

local _applied = false
local _prepared: any = nil

--[[
	递归冻结表及其嵌套表（已冻结则跳过）
	@param value any - 任意值；非 table 直接返回
	@return any - 冻结后的同一引用，或原非 table 值
]]
local function _deepFreeze(value: any): any
	if type(value) ~= "table" then
		return value
	end
	if table.isfrozen(value) then
		return value
	end
	for _, v in pairs(value) do
		_deepFreeze(v)
	end
	return table.freeze(value)
end

--[[
	按 ConfigInstance.key 将各配置行的数字下标转为字段名，并深度 freeze
	@param configInstance table - 导表原始 ConfigInstance 表（会被原地改写）
	@return table - 处理后的同一表引用
]]
function ConfigPrepare.Apply(configInstance: { [any]: any }): { [any]: any }
	if _applied and _prepared ~= nil then
		return _prepared
	end

	local key = configInstance.key
	if type(key) == "table" then
		for confName, confTable in pairs(configInstance) do
			if confName ~= "key" and type(confTable) == "table" then
				local keyV = key[confName]
				if type(keyV) == "table" then
					for rowId, row in pairs(confTable) do
						if type(row) == "table" then
							local newCfg = {}
							for colIdx, colVal in pairs(row) do
								local fieldName = keyV[colIdx]
								if fieldName ~= nil then
									newCfg[tostring(fieldName)] = colVal
								else
									newCfg[colIdx] = colVal
								end
							end
							confTable[rowId] = newCfg
						end
					end
				end
			end
		end
	end

	_deepFreeze(configInstance)
	_applied = true
	_prepared = configInstance
	return configInstance
end

--[[
	加载并准备 ConfigInstance（幂等）
	@return table - remap + freeze 后的配置根表
]]
function ConfigPrepare.Get(): { [any]: any }
	if _applied and _prepared ~= nil then
		return _prepared
	end
	local raw = require(script.Parent.ConfigInstance)
	return ConfigPrepare.Apply(raw)
end

return ConfigPrepare
