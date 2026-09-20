--[[
	Module: TypeRegistry
	Description: Part-Icles 类型 schema 读写门面；类型表在 TypeData / TypeDataScreen，本文件做通用读/写
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-09-01

	枚举按 Name 字符串序列化，反序列化走 Enum[enumType][name]。
	不向上依赖 Pool：_bumpPoolGen 内联刷新 RenderTemplate._PoolGen。
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Log = Utils.Log

local TypeData = require(script.TypeData)

export type TypeDef = {
	classCheck: (Instance) -> boolean,
	pDataType: string,
	uiSection: string,
	properties: {[string]: {[string]: any}},
	resize: {[string]: any}?,
	retime: {[string]: any}?,
	clipboard: {any}?,
	directAccess: boolean?,
}

local TypeRegistry = {}

TypeRegistry.CONFIG_NAME = "PartIcleProperties"
TypeRegistry.Types = TypeData.Types

--[[
	按 classCheck 匹配类型定义
	@param item Instance - 待识别的发射器或原生实例
	@return TypeDef? - 匹配的类型定义；无匹配为 nil
	@return string? - 类型名（如 "Part" / "Beam"）；无匹配为 nil
]]
function TypeRegistry.getTypeFor(item): (TypeDef?, string?)
	for typeName, typeDef in pairs(TypeRegistry.Types) do
		if typeDef.classCheck(item) then
			return typeDef, typeName
		end
	end
	return nil, nil
end

--[[
	只返回类型名
	@param item Instance - 待识别实例
	@return string? - 类型名；无法识别为 nil
]]
function TypeRegistry.getTypeName(item): string?
	local _, name = TypeRegistry.getTypeFor(item)
	return name
end

--[[
	查找 PartIcleProperties Configuration 子节点
	@param item Instance - 发射器实例
	@return Configuration? - 配置节点；不存在为 nil
]]
function TypeRegistry.getConfig(item)
	return item:FindFirstChild(TypeRegistry.CONFIG_NAME)
end

--[[
	解析属性 Attribute 名覆盖（BeamBrightness、PLRange 等），无覆盖则用 propName
	@param typeDef TypeDef - 类型定义
	@param propName string - 逻辑属性名
	@return string - 实际 Attribute / 属性名
]]
function TypeRegistry.getAttrName(typeDef, propName): string
	local propDef = typeDef.properties[propName]
	if propDef and propDef.attrName then
		return propDef.attrName
	end
	return propName
end

--[[
	读单个属性；enum 返回 EnumItem 而非 Name 字符串
	@param item Instance - 发射器或 directAccess 实例
	@param propName string - 逻辑属性名
	@return any - 属性值（NumberSequence / ColorSequence / EnumItem / 标量等）；无法识别或无定义为 nil
]]
function TypeRegistry.read(item, propName): any
	local typeDef = TypeRegistry.getTypeFor(item)
	if not typeDef then return nil end
	local propDef = typeDef.properties[propName]
	if not propDef then return nil end

	if typeDef.directAccess then
		if propDef.attribute then
			local attrName = propDef.attrName or propName
			local raw = item:GetAttribute(attrName)
			-- Explicit nil-check so stored `false` round-trips correctly.
			if raw ~= nil then return raw end
			return propDef.default
		end
		local ok, val = pcall(function() return item[propName] end)
		if ok and val ~= nil then return val end
		return propDef.default
	end

	local config = TypeRegistry.getConfig(item)
	if not config then return nil end

	local attrName = TypeRegistry.getAttrName(typeDef, propName)
	local raw = config:GetAttribute(attrName)

	if raw == nil then return propDef.default end

	if propDef.type == "enum" and type(raw) == "string" then
		-- Enum[type][name] raises on invalid names; pcall-wrap.
		local ok, enumVal = pcall(function() return Enum[propDef.enumType][raw] end)
		if ok and enumVal then return enumVal end
		return propDef.default
	end

	return raw
end

--[[
	递增 RenderTemplate._PoolGen，使下次 Pool.acquire 丢弃过期外观；内联以免依赖 Pool
	@param item Instance - 已 Transform 的发射器
]]
local function _bumpPoolGen(item)
	local rt = item:FindFirstChild("RenderTemplate")
	if not rt then return end
	local cur = rt:GetAttribute("_PoolGen") or 0
	pcall(function() rt:SetAttribute("_PoolGen", cur + 1) end)
end

--[[
	公开刷新池代次；UI 直接改 RT（Material / Beam Texture / Attachment0/1）时调用
	@param item Instance? - 发射器；nil 直接返回
]]
function TypeRegistry.bumpPoolGen(item)
	if not item then return end
	_bumpPoolGen(item)
end

--[[
	钳制 NumberSequence：每个关键点 Value >= 0 且 Envelope <= Value
	@param value any - 待钳制值；非 NumberSequence 原样返回
	@return any - 钳制后的 NumberSequence，或原 value
]]
local function _clampNonNegativeSeq(value)
	if typeof(value) ~= "NumberSequence" then return value end
	local kps = value.Keypoints
	local needsClamp = false
	for _, kp in ipairs(kps) do
		if kp.Value < 0 or kp.Envelope > kp.Value then needsClamp = true; break end
	end
	if not needsClamp then return value end
	local clamped = {}
	for _, kp in ipairs(kps) do
		local v = math.max(0, kp.Value)
		local e = math.max(0, math.min(kp.Envelope, v))
		table.insert(clamped, NumberSequenceKeypoint.new(kp.Time, v, e))
	end
	return NumberSequence.new(clamped)
end

--[[
	判断数字是否为 NaN / ±Inf（写边界拒绝，避免脏 Attribute 跨会话残留）
	@param n any - 待检查值
	@return boolean - 是无效数字则为 true
]]
local function _isInvalidNumber(n)
	return type(n) == "number" and (n ~= n or n == math.huge or n == -math.huge)
end

--[[
	判断写入值是否含 NaN/Inf 或畸形 NumberSequence（Time 越出 [0,1]）
	@param value any - number / NumberRange / NumberSequence 或其他
	@return boolean - 应拒绝写入则为 true
]]
local function _isInvalidValue(value)
	if type(value) == "number" then return _isInvalidNumber(value) end
	if typeof(value) == "NumberRange" then return _isInvalidNumber(value.Min) or _isInvalidNumber(value.Max) end
	if typeof(value) == "NumberSequence" then
		for _, kp in ipairs(value.Keypoints) do
			if _isInvalidNumber(kp.Time) or _isInvalidNumber(kp.Value) or _isInvalidNumber(kp.Envelope) then
				return true
			end
			if kp.Time < 0 or kp.Time > 1 then return true end
		end
	end
	return false
end

--[[
	写单个属性；enum 在 config 存 Name 字符串，directAccess 存 EnumItem
	@param item Instance - 发射器或 directAccess 实例
	@param propName string - 逻辑属性名
	@param value any - 新值（NumberSequence / ColorSequence / EnumItem / 标量等）；无效值拒绝并打日志
]]
function TypeRegistry.write(item, propName, value)
	if _isInvalidValue(value) then
		Log.warn("[Part-Icles] TypeRegistry.write rejected invalid value for " .. tostring(propName))
		return
	end
	local typeDef = TypeRegistry.getTypeFor(item)
	if not typeDef then return end
	local propDef = typeDef.properties[propName]
	if not propDef then return end

	if typeDef.directAccess then
		if propDef.nonNegative then
			value = _clampNonNegativeSeq(value)
		end
		if propDef.attribute then
			local attrName = propDef.attrName or propName
			item:SetAttribute(attrName, value)
		else
			pcall(function() item[propName] = value end)
		end
		_bumpPoolGen(item)
		return
	end

	local config = TypeRegistry.getConfig(item)
	if not config then return end

	local attrName = TypeRegistry.getAttrName(typeDef, propName)

	if propDef.type == "enum" then
		if typeof(value) == "EnumItem" then
			config:SetAttribute(attrName, value.Name)
		else
			config:SetAttribute(attrName, tostring(value))
		end
	else
		-- nonNegative: clamp NumberSequence Value AND Envelope so Value + rand[-E,+E] >= 0.
		if propDef.nonNegative and typeof(value) == "NumberSequence" then
			local kps = value.Keypoints
			local needsClamp = false
			for _, kp in ipairs(kps) do
				if kp.Value < 0 or kp.Envelope > kp.Value then needsClamp = true; break end
			end
			if needsClamp then
				local clamped = {}
				for _, kp in ipairs(kps) do
					local v = math.max(0, kp.Value)
					local e = math.max(0, math.min(kp.Envelope, v))
					table.insert(clamped, NumberSequenceKeypoint.new(kp.Time, v, e))
				end
				value = NumberSequence.new(clamped)
			end
		end
		config:SetAttribute(attrName, value)
	end
	_bumpPoolGen(item)
end

--[[
	读出该类型全部属性为扁平表（通用 GetData）
	@param item Instance - 已 Transform 的发射器
	@return {[string]: any}? - { [propName]=value }；无法识别或无 config 为 nil
]]
function TypeRegistry.readAll(item): {[string]: any}?
	local typeDef = TypeRegistry.getTypeFor(item)
	if not typeDef then return nil end
	local config = TypeRegistry.getConfig(item)
	if not config then return nil end

	local data = {}
	for propName, propDef in pairs(typeDef.properties) do
		local attrName = TypeRegistry.getAttrName(typeDef, propName)
		local raw = config:GetAttribute(attrName)
		if raw == nil then
			data[propName] = propDef.default
		elseif propDef.type == "enum" and type(raw) == "string" then
			data[propName] = Enum[propDef.enumType][raw]
		else
			data[propName] = raw
		end
	end
	return data
end

--[[
	把类型全部默认属性盖到 Configuration 上；Transform 调用
	@param config Configuration - PartIcleProperties
	@param typeDef TypeDef - 类型定义
]]
function TypeRegistry.writeDefaults(config, typeDef)
	for propName, propDef in pairs(typeDef.properties) do
		local attrName = propDef.attrName or propName
		local value = propDef.default
		if propDef.type == "enum" then
			config:SetAttribute(attrName, value.Name)
		else
			config:SetAttribute(attrName, value)
		end
	end
end

--[[
	新建已盖默认值的 PartIcleProperties，并挂到 item 下
	@param item Instance - 发射器
	@param typeDef TypeDef - 类型定义
	@return Configuration - 新配置节点
]]
function TypeRegistry.createConfig(item, typeDef)
	local config = Instance.new("Configuration")
	config.Name = TypeRegistry.CONFIG_NAME
	TypeRegistry.writeDefaults(config, typeDef)
	config.Parent = item
	return config
end

--[[
	是否为图属性（NumberSequence / ColorSequence）
	@param propDef table - 属性描述 { type, default, ... }
	@return boolean - 是图属性则为 true
]]
function TypeRegistry.isGraph(propDef): boolean
	return propDef.type == "NumberSequence" or propDef.type == "ColorSequence"
end

--[[
	属性是否要求非负 NumberSequence
	@param propDef table - 属性描述
	@return boolean - nonNegative==true 则为 true
]]
function TypeRegistry.isNonNegative(propDef): boolean
	return propDef.nonNegative == true
end

--[[
	按类型名取属性描述
	@param typeName string - 类型名（如 "Part"）
	@param propName string - 逻辑属性名
	@return table? - 属性描述 { type, default, attrName?, ... }；未知为 nil
]]
function TypeRegistry.getPropDef(typeName, propName)
	local typeDef = TypeRegistry.Types[typeName]
	if not typeDef then return nil end
	return typeDef.properties[propName]
end

--[[
	按类型名取属性默认值（pairs(Types) 无序，必须按名查找）
	@param typeName string - 类型名
	@param propName string - 逻辑属性名
	@return any - 默认值；未知类型或属性为 nil
]]
function TypeRegistry.getDefault(typeName, propName)
	local typeDef = TypeRegistry.Types[typeName]
	if not typeDef then return nil end
	local propDef = typeDef.properties[propName]
	if not propDef then return nil end
	return propDef.default
end

return TypeRegistry
