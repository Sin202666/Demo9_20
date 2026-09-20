--[[
	Module: MoonAniLighting
	Description: SystemMoonAni Lighting 开播快照与恢复
	Author: 林奥宇
	Created: 2026-08-25
	Last Modified: 2026-08-25

	仅由 SystemMoonAni 同目录模块 require(script.MoonAniLighting) 使用。
]]

local Lighting = game:GetService("Lighting")

local MoonAniLighting = {}

local LIGHTING_SERVICE_PROPS = {
	"Ambient",
	"Brightness",
	"ColorShift_Bottom",
	"ColorShift_Top",
	"EnvironmentDiffuseScale",
	"EnvironmentSpecularScale",
	"ExposureCompensation",
	"FogColor",
	"FogEnd",
	"FogStart",
	"GeographicLatitude",
	"GlobalShadows",
	"OutdoorAmbient",
	"ShadowSoftness",
	"ClockTime",
	"TimeOfDay",
}

local LIGHTING_CHILD_PROPS = {
	"Enabled",
	"Brightness",
	"Contrast",
	"Saturation",
	"TintColor",
	"Intensity",
	"Size",
	"Threshold",
	"FarIntensity",
	"FocusDistance",
	"InFocusRadius",
	"NearIntensity",
	"Spread",
	"Density",
	"Offset",
	"Color",
	"Decay",
	"Glare",
	"Haze",
}

export type LightingSnapshot = {
	props: { [string]: any },
	children: { [string]: { [string]: any } },
}

--[[
	模块内警告输出

	@param ... any - warn 参数
	@return nil
]]
local function _warn(...: any)
	warn("[SystemMoonAni]", ...)
end

--[[
	读取实例上若干属性（失败的属性跳过）

	@param inst Instance - 目标
	@param propNames { string } - 属性名列表
	@return { [string]: any } - 可读快照
]]
local function _readPropBag(inst: Instance, propNames: { string }): { [string]: any }
	local bag: { [string]: any } = {}
	for _, name in propNames do
		local ok, val = pcall(function()
			return (inst :: any)[name]
		end)
		if ok then
			bag[name] = val
		end
	end
	return bag
end

--[[
	把属性包写回实例；失败时 warn

	@param inst Instance - 目标
	@param bag { [string]: any } - 属性快照
	@return nil
]]
local function _writePropBag(inst: Instance, bag: { [string]: any })
	for name, val in bag do
		local ok, err = pcall(function()
			(inst :: any)[name] = val
		end)
		if not ok then
			_warn(string.format("恢复属性失败 %s.%s: %s", inst:GetFullName(), name, tostring(err)))
		end
	end
end

--[[
	开播前拍摄 Lighting 快照（服务属性 + 直接子效果）

	@return LightingSnapshot
]]
function MoonAniLighting.captureLightingSnapshot(): LightingSnapshot
	local children: { [string]: { [string]: any } } = {}
	for _, child in Lighting:GetChildren() do
		children[child.Name] = _readPropBag(child, LIGHTING_CHILD_PROPS)
	end
	return {
		props = _readPropBag(Lighting, LIGHTING_SERVICE_PROPS),
		children = children,
	}
end

--[[
	过场结束后恢复开播前 Lighting

	@param snapshot LightingSnapshot? - 开播快照
	@return nil
]]
function MoonAniLighting.restoreLightingSnapshot(snapshot: LightingSnapshot?)
	if not snapshot then
		return
	end
	_writePropBag(Lighting, snapshot.props)
	for childName, bag in snapshot.children do
		local child = Lighting:FindFirstChild(childName)
		if child then
			_writePropBag(child, bag)
		end
	end
end

return MoonAniLighting
